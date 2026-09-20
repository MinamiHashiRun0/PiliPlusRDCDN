// 本地并发代理的**纯逻辑核心**：不碰网络、不碰 Flutter，因此可以在任何环境离线单测。
//
// 背景：mpv 拉分片时是单连接，而实测表明跨境单连接常被压在 13–25 Mbps（并发 8 条却能到
// 62–77 Mbps）。所以做法是：mpv → 127.0.0.1 的本地 HTTP 代理 → 代理内部用 N 条并发
// Range 去取同一段字节 → 拼好按序回给 mpv。
//
// 本文件只负责三件容易写错的事：
//   1. 解析/构造 HTTP Range 与 Content-Range
//   2. 把"想要的一段"切成 N 个互不重叠的块（并发取）
//   3. 滚动字节缓冲：记录已有哪些字节、缺哪些、该丢哪些
// 网络与 HTTP 服务器在 cdn_proxy.dart。

/// 闭区间字节范围 [start, end]（含两端），与 HTTP Range 语义一致。
class ByteRange {
  const ByteRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  final int start;
  final int end;

  int get length => end - start + 1;

  bool contains(int offset) => offset >= start && offset <= end;

  bool overlaps(ByteRange other) =>
      start <= other.end && other.start <= end;

  @override
  String toString() => '$start-$end';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// 解析 Range 请求头。只支持单区间（mpv/ffmpeg 只会发单区间）。
///
/// 支持三种形态：`bytes=a-b`、`bytes=a-`（到结尾）、`bytes=-n`（最后 n 字节）。
/// [total] 已知时用于把开区间收成闭区间。
class RangeRequest {
  const RangeRequest({this.start, this.end, this.suffixLength});

  final int? start;
  final int? end;

  /// `bytes=-n` 形态。
  final int? suffixLength;

  static RangeRequest? parse(String? header) {
    if (header == null) return null;
    final value = header.trim();
    if (!value.toLowerCase().startsWith('bytes=')) return null;
    final spec = value.substring(6).trim();
    if (spec.contains(',')) return null; // 多区间不支持：按"无 Range"处理更安全
    final dash = spec.indexOf('-');
    if (dash == -1) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final n = int.tryParse(right);
      if (n == null || n <= 0) return null;
      return RangeRequest(suffixLength: n);
    }
    final a = int.tryParse(left);
    if (a == null || a < 0) return null;
    if (right.isEmpty) return RangeRequest(start: a);
    final b = int.tryParse(right);
    if (b == null || b < a) return null;
    return RangeRequest(start: a, end: b);
  }

  /// 收敛成闭区间。总长未知且是开区间时返回 null（需要先探测长度）。
  ByteRange? resolve(int? total) {
    final suffix = suffixLength;
    if (suffix != null) {
      if (total == null || total <= 0) return null;
      final start = total - suffix < 0 ? 0 : total - suffix;
      return ByteRange(start, total - 1);
    }
    final s = start;
    if (s == null) return null;
    var e = end;
    if (e == null) {
      if (total == null) return null;
      e = total - 1;
    }
    if (total != null && e > total - 1) e = total - 1;
    if (e < s) return null; // 越界：调用方应回 416
    return ByteRange(s, e);
  }
}

/// 解析上游的 `Content-Range: bytes a-b/total`。
class ContentRange {
  const ContentRange({required this.start, required this.end, this.total});

  final int start;
  final int end;
  final int? total;

  static ContentRange? parse(String? header) {
    if (header == null) return null;
    final m = RegExp(
      r'bytes\s+(\d+)\s*-\s*(\d+)\s*/\s*(\d+|\*)',
      caseSensitive: false,
    ).firstMatch(header);
    if (m == null) return null;
    return ContentRange(
      start: int.parse(m.group(1)!),
      end: int.parse(m.group(2)!),
      total: m.group(3) == '*' ? null : int.parse(m.group(3)!),
    );
  }

  static String format(ByteRange range, int? total) =>
      'bytes ${range.start}-${range.end}/${total ?? '*'}';
}

/// 把 [want] 切成最多 [connections] 个互不重叠的块，用于并发拉取。
///
/// [perConn] 是每块的期望大小；给 null 就按均分。返回的块按 offset 升序，
/// 合起来正好覆盖 [want]（不重不漏）。
List<ByteRange> planChunks(
  ByteRange want, {
  required int connections,
  int? perConn,
}) {
  if (want.length <= 0 || connections <= 1) return [want];
  final size = perConn != null && perConn > 0
      ? perConn
      : (want.length / connections).ceil();
  if (size >= want.length) return [want];

  final chunks = <ByteRange>[];
  var offset = want.start;
  while (offset <= want.end && chunks.length < connections) {
    final remaining = want.end - offset + 1;
    // 最后一块吃掉剩下全部，避免留下尾巴
    final take = chunks.length == connections - 1
        ? remaining
        : (size < remaining ? size : remaining);
    chunks.add(ByteRange(offset, offset + take - 1));
    offset += take;
  }
  return chunks;
}

/// 已缓存的连续段集合。刻意保持"按 offset 升序、两两不重叠且不相邻合并"的不变式，
/// 这样求缺口、求连续末尾都只是线性扫描。
class ByteBufferIndex {
  ByteBufferIndex({this.limit = 64 * 1024 * 1024});

  /// 保留上限（字节）。超出时优先丢弃离 [center] 最远的数据。
  final int limit;

  final List<ByteRange> _ranges = [];

  /// "当前关注的位置"，通常是播放器最近一次请求的起点。裁剪以它为参照。
  int center = 0;

  List<ByteRange> get ranges => List.unmodifiable(_ranges);

  int get cachedBytes => _ranges.fold(0, (sum, r) => sum + r.length);

  bool has(int offset) => _ranges.any((r) => r.contains(offset));

  /// 记录"这段字节有了"，并做合并与裁剪。
  void add(ByteRange range) {
    if (range.length <= 0) return;
    final merged = <ByteRange>[];
    var current = range;
    var inserted = false;
    for (final r in _ranges) {
      if (r.end + 1 < current.start) {
        merged.add(r);
      } else if (current.end + 1 < r.start) {
        if (!inserted) {
          merged.add(current);
          inserted = true;
        }
        merged.add(r);
      } else {
        // 有重叠或相邻：合并成一段
        current = ByteRange(
          r.start < current.start ? r.start : current.start,
          r.end > current.end ? r.end : current.end,
        );
      }
    }
    if (!inserted) merged.add(current);
    _ranges
      ..clear()
      ..addAll(merged);
    _evict();
  }

  /// 从 [from] 开始连续可用的最后一个字节位置；[from] 本身没缓存则返回 from-1。
  int contiguousEndFrom(int from) {
    for (final r in _ranges) {
      if (r.start <= from && from <= r.end) return r.end;
      if (r.start > from) break;
    }
    return from - 1;
  }

  /// [want] 里还没缓存的缺口（升序、不重叠）。
  List<ByteRange> gaps(ByteRange want) {
    final out = <ByteRange>[];
    var cursor = want.start;
    for (final r in _ranges) {
      if (r.end < cursor) continue;
      if (r.start > want.end) break;
      if (r.start > cursor) {
        final end = r.start - 1 < want.end ? r.start - 1 : want.end;
        out.add(ByteRange(cursor, end));
      }
      if (r.end + 1 > cursor) cursor = r.end + 1;
      if (cursor > want.end) break;
    }
    if (cursor <= want.end) out.add(ByteRange(cursor, want.end));
    return out;
  }

  @override
  String toString() =>
      'ByteBufferIndex(${_ranges.length} 段, ${cachedBytes}B/$limit, center=$center)';

  /// 超出上限时，按"离 [center] 的距离"从远到近丢，直到降到上限以内。
  /// 最坏情况会丢到只剩一段——这没关系：数据本来就是可重取的。
  void _evict() {
    if (cachedBytes <= limit) return;

    int distance(ByteRange r) {
      if (r.contains(center)) return 0;
      return r.start > center ? r.start - center : center - r.end;
    }

    // 远的先丢，直到剩下的不超过上限
    final ordered = [..._ranges]..sort((a, b) => distance(b).compareTo(distance(a)));
    var remaining = cachedBytes;
    final dropped = <ByteRange>{};
    for (final r in ordered) {
      if (remaining <= limit) break;
      dropped.add(r);
      remaining -= r.length;
    }
    if (dropped.isEmpty) return;

    // 横跨 center 的那段不整段丢，改成只保留 center 两侧各一半配额
    final kept = <ByteRange>[];
    for (final r in _ranges) {
      if (!dropped.contains(r)) {
        kept.add(r);
        continue;
      }
      if (r.contains(center)) {
        // 闭区间 [center-half, center+half] 的长度是 2*half+1，所以两侧各留
        // half-1 才能保证总长 <= limit。
        final half = (limit ~/ 2) - 1;
        if (half < 0) continue;
        final s = center - half < r.start ? r.start : center - half;
        final e = center + half > r.end ? r.end : center + half;
        kept.add(ByteRange(s, e));
      }
    }
    _ranges
      ..clear()
      ..addAll(kept);
  }

  void clear() {
    _ranges.clear();
    center = 0;
  }
}
