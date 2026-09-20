// m4s 的 SIDX 分段索引解析：纯逻辑、无 I/O、无 Flutter 依赖，可离线单测。
//
// 为什么要解析它：B 站 m4s 文件开头带一个标准 SIDX 盒，里面是**每个分段的字节范围与
// 时长**。拿到它，代理就能把"按字节窗口猜预取"换成"按段精确调度"——这正是浏览器端
// thread-ripper 靠 dash.js 拿到的信息，也是它"段级重试/换线路"的前提。
//
// 真实数据（实测某个 qn=64 视频轨，取前 65536 字节）：
//   ftyp@0 size=32 / moov@32 size=904 / sidx@936 size=4564
//   SIDX v1, timescale=16000, 377 段, 每段 5.000s
//   段大小示例：353078 / 190475 / 373435 字节
// 音频轨：sidx@837 size=4552, timescale=48000, 376 段, 每段 5.013s
//
// 设计约束：
//   * 不信任输入 —— 所有读取都过边界检查，任何异常返回 null（调用方回落直通）
//   * 只做解析，不做网络 —— 头部字节从哪来由调用方决定
//   * size==0（延伸到文件尾）与 size==1（64 位 largesize）都要处理

import 'dart:typed_data';

/// 一个子分段（subsegment）。
class SidxSegment {
  const SidxSegment({
    required this.index,
    required this.offset,
    required this.size,
    required this.startMs,
    required this.durationMs,
  });

  /// 在索引里的序号（从 0 开始）。
  final int index;

  /// 该段在文件里的**绝对起始字节**。
  final int offset;

  /// 该段字节数。
  final int size;

  /// 该段起点相对媒体起点的毫秒数。
  final int startMs;

  /// 该段时长（毫秒）。
  final int durationMs;

  int get endOffset => offset + size - 1;

  @override
  String toString() =>
      'seg#$index [$offset-$endOffset] ${size}B +${startMs}ms/${durationMs}ms';
}

/// 解析结果：一条完整的段表。
class SidxIndex {
  SidxIndex({
    required this.timescale,
    required this.earliestPresentationMs,
    required this.segments,
  });

  /// 媒体时间基（每秒多少 tick）。
  final int timescale;

  final int earliestPresentationMs;
  final List<SidxSegment> segments;

  bool get isEmpty => segments.isEmpty;
  int get segmentCount => segments.length;

  /// 索引覆盖的总字节数（首段起点到末段终点）。
  int get coveredBytes => segments.isEmpty
      ? 0
      : segments.last.endOffset - segments.first.offset + 1;

  /// 索引覆盖的总时长（毫秒）。
  int get coveredMs {
    if (segments.isEmpty) return 0;
    final first = segments.first;
    final last = segments.last;
    return (last.startMs + last.durationMs) - first.startMs;
  }

  /// 找出包含字节 [offset] 的段；越界返回 null。
  ///
  /// 段表按 offset 升序（SIDX 的规范保证），用二分查找而不是线性扫描 ——
  /// 旧实现里"每个块都全量扫一遍 range 列表"正是性能故障的来源，这里不再重复。
  SidxSegment? segmentAt(int offset) {
    var lo = 0;
    var hi = segments.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final s = segments[mid];
      if (offset < s.offset) {
        hi = mid - 1;
      } else if (offset > s.endOffset) {
        lo = mid + 1;
      } else {
        return s;
      }
    }
    return null;
  }

  /// [start, end] 覆盖到的段列表（闭区间，含部分覆盖的首尾段）。
  ///
  /// 返回升序列表；与索引无交集时返回空列表。
  List<SidxSegment> segmentsCovering(int start, int end) {
    if (segments.isEmpty || end < start) return const [];
    final out = <SidxSegment>[];
    final first = segmentAt(start);
    // 起点落在索引之前（如 init 段区域）时，从第一段开始
    var i = first?.index ?? (start < segments.first.offset ? 0 : segments.length);
    for (; i < segments.length; i++) {
      final s = segments[i];
      if (s.offset > end) break;
      if (s.endOffset < start) continue;
      out.add(s);
    }
    return out;
  }

  @override
  String toString() =>
      'SidxIndex(timescale=$timescale, ${segments.length} 段, '
      '${coveredMs}ms, ${coveredBytes}B)';
}

/// 一个已识别的 ISO BMFF 盒。
class BmffBox {
  const BmffBox({
    required this.type,
    required this.headerSize,
    required this.contentStart,
    required this.contentEnd,
  });

  /// 4 字节类型（如 'ftyp' / 'moov' / 'sidx'）。
  final String type;

  /// 盒头长度（普通 8，64 位 largesize 为 16）。
  final int headerSize;

  /// 内容区（不含盒头）的绝对起止，闭区间。
  final int contentStart;
  final int contentEnd;

  int get contentLength => contentEnd - contentStart + 1;

  @override
  String toString() => "BmffBox($type hdr=$headerSize content=$contentStart-$contentEnd)";
}

/// SIDX 解析器。整个类都是静态方法，无状态。
abstract final class SidxParser {
  /// 建议一次取多少字节的头部。
  ///
  /// 实测某视频轨 sidx 盒 4564 字节、377 段；取 64KiB 足够覆盖 init 段与整个索引。
  /// （377 段的引用表是 377×12 = 4524 字节，索引自身很小。）
  static const int recommendedHeaderBytes = 64 * 1024;

  /// 在 [data] 里依次读出顶层盒。
  ///
  /// [data] 必须是从文件**偏移 0** 开始的字节。[limit] 为可解析的最大绝对偏移
  /// （默认整个 buffer 长度）；只读到了文件中间时用它防止把截断的盒当成完整的。
  ///
  /// 遇到无法解析的盒头就停止（返回已解析的部分）——不抛异常。
  static List<BmffBox> readTopLevelBoxes(Uint8List data, {int? limit}) {
    final boxes = <BmffBox>[];
    final end = limit == null || limit > data.length ? data.length : limit;
    var offset = 0;
    while (offset + 8 <= end) {
      final size32 = _u32(data, offset);
      if (size32 == null) break;
      final type = _type(data, offset + 4);
      if (type == null) break;

      var headerSize = 8;
      int boxSize;
      if (size32 == 1) {
        // largesize：真实长度在紧接着的 8 字节里
        final large = _u64(data, offset + 8);
        if (large == null) break;
        headerSize = 16;
        boxSize = large;
      } else if (size32 == 0) {
        // 表示"延伸到文件末尾"；读到的 buffer 可能被截断，只能按已读长度处理
        boxSize = end - offset;
      } else {
        boxSize = size32;
      }

      if (boxSize < headerSize) break;
      final contentStart = offset + headerSize;
      final contentEnd = offset + boxSize - 1;
      // 内容超出已读范围 → 这是被截断的盒，不记入结果
      if (contentEnd > end - 1) {
        boxes.add(
          BmffBox(
            type: type,
            headerSize: headerSize,
            contentStart: contentStart,
            contentEnd: contentEnd,
          ),
        );
        break;
      }
      boxes.add(
        BmffBox(
          type: type,
          headerSize: headerSize,
          contentStart: contentStart,
          contentEnd: contentEnd,
        ),
      );
      offset += boxSize;
    }
    return boxes;
  }

  /// 从**文件开头**的字节里解析 SIDX。
  ///
  /// 返回 null 表示：没有 sidx 盒、索引被截断、或结构非法 —— 调用方应回落到
  /// "不理解分段"的直通模式，而不是报错。
  static SidxIndex? parse(Uint8List data) {
    if (data.length < 16) return null;
    final boxes = readTopLevelBoxes(data);
    BmffBox? sidx;
    for (final b in boxes) {
      if (b.type == 'sidx') {
        sidx = b;
        break;
      }
    }
    if (sidx == null) return null;
    // sidx 内容必须完整落在已读字节里，否则引用表可能被截断
    if (sidx.contentEnd > data.length - 1) return null;

    return _parseSidxContent(data, sidx);
  }

  static SidxIndex? _parseSidxContent(Uint8List data, BmffBox box) {
    var p = box.contentStart;
    final end = box.contentEnd;

    final version = _u8(data, p);
    if (version == null) return null;
    p += 4; // version(1) + flags(3)

    // reference_ID（4 字节），解析时用不到但必须跳过
    if (p + 4 > end + 1) return null;
    p += 4;

    final timescale = _u32(data, p);
    if (timescale == null || timescale == 0) return null;
    p += 4;

    int earliest;
    int firstOffset;
    if (version == 0) {
      final e = _u32(data, p);
      if (e == null) return null;
      p += 4;
      final f = _u32(data, p);
      if (f == null) return null;
      p += 4;
      earliest = e;
      firstOffset = f;
    } else if (version == 1) {
      final e = _u64(data, p);
      if (e == null) return null;
      p += 8;
      final f = _u64(data, p);
      if (f == null) return null;
      p += 8;
      earliest = e > 0x7fffffffffffffff ? 0 : e;
      firstOffset = f;
    } else {
      // 未知版本，不猜
      return null;
    }

    p += 2; // reserved
    final count = _u16(data, p);
    if (count == null) return null;
    p += 2;

    // 引用表完整性检查：每条 12 字节
    if (p + count * 12 - 1 > end) return null;

    // 第一段的绝对起点：sidx 盒末尾 + first_offset
    var cursor = (box.contentEnd + 1) + firstOffset;
    var elapsedTicks = 0;
    final segments = <SidxSegment>[];

    for (var i = 0; i < count; i++) {
      final word = _u32(data, p);
      final duration = _u32(data, p + 4);
      if (word == null || duration == null) return null;
      p += 12;

      // 引用类型位（word 的 bit31）语义：**1 = 层级引用**（指向另一个 sidx），
      // 0 = 直接引用（媒体分段）。实测 B 站两条轨的 377/376 条全部为 0，且
      // word 的低 31 位正好等于该段字节数（353078 / 190475 / …），可交叉验证。
      // 之前把这一位判反，导致所有条目被当成层级引用跳过、整个索引解析为 null。
      final isHierarchical = (word & 0x80000000) != 0;
      final size = word & 0x7fffffff;
      if (isHierarchical || size <= 0) continue;

      final startMs = _ticksToMs(elapsedTicks, timescale);
      final durationMs = _ticksToMs(duration, timescale);
      elapsedTicks += duration;

      segments.add(
        SidxSegment(
          index: segments.length,
          offset: cursor,
          size: size,
          startMs: startMs,
          durationMs: durationMs,
        ),
      );
      cursor += size;
    }

    if (segments.isEmpty) return null;
    return SidxIndex(
      timescale: timescale,
      earliestPresentationMs: _ticksToMs(earliest, timescale),
      segments: segments,
    );
  }

  /// 实际验证用：把索引摘要成一行，便于肉眼核对与日志。
  static String describe(SidxIndex index) {
    final s = index.segments;
    final b = StringBuffer()
      ..write('${index.segmentCount} 段 @ timescale=${index.timescale} · ')
      ..write('覆盖 ${index.coveredMs}ms / ${index.coveredBytes}B');
    if (s.isNotEmpty) {
      b
        ..write(' · 首段 ${s.first.offset}~${s.first.endOffset}')
        ..write(' (${s.first.durationMs}ms)')
        ..write(' · 末段 ${s.last.offset}~${s.last.endOffset}');
    }
    return b.toString();
  }

  // ---- 底层读取：全部带边界检查，越界返回 null ------------------------------

  static int _ticksToMs(int ticks, int timescale) =>
      timescale == 0 ? 0 : (ticks * 1000 / timescale).round();

  static int? _u8(Uint8List d, int i) => (i < 0 || i >= d.length) ? null : d[i];

  static int? _u16(Uint8List d, int i) {
    if (i < 0 || i + 1 >= d.length) return null;
    return (d[i] << 8) | d[i + 1];
  }

  static int? _u32(Uint8List d, int i) {
    if (i < 0 || i + 3 >= d.length) return null;
    return (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3];
  }

  static int? _u64(Uint8List d, int i) {
    if (i < 0 || i + 7 >= d.length) return null;
    var v = 0;
    for (var k = 0; k < 8; k++) {
      v = (v << 8) | d[i + k];
    }
    return v;
  }

  static String? _type(Uint8List d, int i) {
    if (i < 0 || i + 3 >= d.length) return null;
    // box type 是 4 个可打印 ASCII
    for (var k = 0; k < 4; k++) {
      final c = d[i + k];
      if (c < 0x20 || c > 0x7e) return null;
    }
    return String.fromCharCodes(d, i, i + 4);
  }
}
