// 段调度核心：按 SIDX 段表排布下载，替代原来的"按字节窗口预取"。
//
// 为什么换掉字节窗口（实测依据）：
//   * 旧实现有两处 O(n) 热点：ByteBufferIndex._evict 每写入一块就全量排序，
//     add() 每块全量重建 range 列表。缓存涨到 64MB 时这是持续 CPU 开销。
//   * 旧实现的预取窗口是按"字节数"给的，而它的播放时长含量随码率变化
//     （8MiB 对 1080P60 约 9.5s，对 4K 只约 1.9s），必须按码率反算才准。
//   * 旧实现的重试粒度是"整个字节窗口"（可达 4MiB），失败一次代价极大。
//
// 换成段调度后：
//   * 数据按"段"为单位存放，每段就是 5 秒左右的媒体，边界天然对齐；
//   * 预取按"段数"给，与码率无关（N 段永远等于 N×5 秒）；
//   * 重试粒度降到单段（实测中位约 250KiB），比 4MiB 小一个数量级；
//   * 内存窗口是"当前段 + 前向 N 段"，天然有界，不需要滚动淘汰与排序。
//
// 本文件是纯逻辑：不碰网络、不碰 Flutter，可离线单测。
// 网络取段与 HTTP 服务在 cdn_proxy.dart。

import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/sidx_index.dart';

/// 一个已下载（或正在下载）的段。
class SegmentSlot {
  SegmentSlot(this.segment);

  final SidxSegment segment;

  /// 数据；null 表示还没下载完。
  Uint8List? data;

  /// 下载失败原因；非 null 表示这一段当前不可用。
  String? failure;

  bool get ready => data != null;
  int get offset => segment.offset;
  int get endOffset => segment.endOffset;
  int get size => segment.size;

  @override
  String toString() =>
      'seg#${segment.index} ${ready ? '已下载' : (failure ?? '待下载')}';
}

/// 段窗口：只保留"当前位置附近"的段，其余丢弃。
///
/// 与旧的 ByteBufferIndex 的关键差别：这里**不合并、不排序、不逐块淘汰**。
/// 段本身是固定边界，槽位用 map 按段序号索引，命中是 O(1)；
/// 丢弃只发生在窗口滑动时（一次一批），不是每写一块都算一遍。
class SegmentWindow {
  SegmentWindow({this.forwardSegments = 8, this.backSegments = 2});

  /// 向前保留多少段（预取目标）。
  final int forwardSegments;

  /// 向后保留多少段（允许小幅回拖而不重下）。0 表示不留。
  final int backSegments;

  final Map<int, SegmentSlot> _slots = {};

  /// 当前绑定的段索引（[slide] 时一并更新）。段查找走它的二分实现。
  SidxIndex? _index;

  /// 窗口左边界（含）。低于它的段已被丢弃。
  int _windowStart = 0;

  int get slotCount => _slots.length;

  /// 已下好的段数（窗口内）。
  int get readyCount => _slots.values.where((s) => s.ready).length;

  int get cachedBytes =>
      _slots.values.fold(0, (sum, s) => sum + (s.data?.length ?? 0));

  Iterable<SegmentSlot> get slots => _slots.values;

  int get windowStart => _windowStart;

  /// 取（必要时创建）某段的槽位。
  SegmentSlot? slot(int index) => _slots[index];

  /// 把段索引登记进窗口，并按 [center] 滑动窗口。
  ///
  /// [center] 通常是播放器最近请求命中的段序号。窗口覆盖
  /// `[center - backSegments, center + forwardSegments]`，范围外的段被丢弃
  /// （丢弃是安全的：需要时能重下）。
  void slide(SidxIndex index, int center) {
    if (index.isEmpty) return;
    _index = index; // take() 的二分查找依赖它
    final segments = index.segments;
    final from = (center - backSegments).clamp(0, segments.length - 1);
    final to = (center + forwardSegments).clamp(0, segments.length - 1);

    // 先丢范围外的（一次遍历，不重复计算），再补齐范围内的槽位
    _slots.removeWhere((entry, _) => entry < from || entry > to);
    _windowStart = from;
    for (var i = from; i <= to; i++) {
      _slots.putIfAbsent(i, () => SegmentSlot(segments[i]));
    }
  }

  /// 需要下载的段（窗口内、未就绪、且没有记录失败），按序号升序。
  ///
  /// [limit] 限制返回数量，避免一次性铺开太多并发。
  List<SegmentSlot> pending({int? limit}) {
    final out = _slots.values
        .where((s) => !s.ready && s.failure == null)
        .toList()
      ..sort((a, b) => a.segment.index.compareTo(b.segment.index));
    return limit == null || out.length <= limit ? out : out.sublist(0, limit);
  }

  /// 取出 [start, end] 的字节。缺任何一段就返回 null（调用方需先补段）。
  ///
  /// 只处理窗口内的段；与窗口无交集的请求返回 null，由调用方决定直通。
  Uint8List? take(int start, int end) {
    if (start > end) return Uint8List(0);
    final index = _index;
    if (index == null) return null;
    final out = BytesBuilder(copy: false);
    var cursor = start;
    while (cursor <= end) {
      final hit = index.segmentAt(cursor); // 二分
      if (hit == null) return null; // 落在段表之外（init 段区域等）
      final s = _slots[hit.index];
      if (s == null || !s.ready) return null; // 该段不在窗口内或还没下好
      final data = s.data!;
      final from = cursor - s.offset;
      if (from < 0 || from >= data.length) return null;
      final want = (end - cursor + 1).clamp(0, data.length - from);
      if (want <= 0) return null; // 防御：避免死循环
      out.add(Uint8List.sublistView(data, from, from + want));
      cursor += want;
    }
    return out.takeBytes();
  }

  /// 记录失败（该段在本次窗口内不再重试，滑出窗口后会被重新创建）。
  void markFailure(int index, String reason) {
    _slots[index]?.failure = reason;
  }

  void clear() {
    _slots.clear();
    _index = null;
    _windowStart = 0;
  }
}

/// 下载调度：决定"下一批该下哪几段"，并限制并发。
///
/// 刻意做成"播放器不要也继续下"：旧实现只在 mpv 发起请求时预取，
/// 而 mpv 缓冲够了就不再读 → 预取随之停手。段调度按播放进度主动推进，
/// 这才是 thread-ripper 那种"下载器主导节奏"的关键差别。
class SegmentScheduler {
  SegmentScheduler({
    required this.window,
    this.maxConcurrent = 6,
    this.maxRetryPerSegment = 2,
  });

  final SegmentWindow window;

  /// 同时在下载的段数上限。
  final int maxConcurrent;

  /// 单段最大重试次数（换线路重试也算一次）。
  final int maxRetryPerSegment;

  final Set<int> _inFlight = {};
  final Map<int, int> _attempts = {};

  int get inFlightCount => _inFlight.length;

  /// 取出这一轮要下载的段（跳过已在下载中的）。
  List<SegmentSlot> nextBatch() {
    final free = maxConcurrent - _inFlight.length;
    if (free <= 0) return const [];
    final pending = window.pending()..removeWhere((s) => _inFlight.contains(s.segment.index));
    if (pending.isEmpty) return const [];
    return pending.length <= free ? pending : pending.sublist(0, free);
  }

  void markStarted(int index) => _inFlight.add(index);

  /// 结束一段的下载。
  ///
  /// 约定：**成功路径必须先往 slot 里 put 数据，再调本方法**。
  /// 本方法只负责"在飞计数 + 重试计数"，"这一段已就绪"由 `slot.data` 表达；
  /// 只调本方法而不落数据，该段会重新出现在 [SegmentWindow.pending] 里被重复下载。
  void markFinished(int index, {String? failure}) {
    _inFlight.remove(index);
    if (failure == null) {
      _attempts.remove(index);
      return;
    }
    final n = (_attempts[index] ?? 0) + 1;
    _attempts[index] = n;
    if (n >= maxRetryPerSegment) {
      window.markFailure(index, failure);
    }
    // 未达上限则保留 failure=null，下一轮 nextBatch 会再取到它
  }

  int attemptsOf(int index) => _attempts[index] ?? 0;

  void reset() {
    _inFlight.clear();
    _attempts.clear();
  }
}
