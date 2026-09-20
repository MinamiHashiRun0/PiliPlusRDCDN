// 本地并发代理：mpv → 127.0.0.1 → 上游 CDN。
//
// 为什么要有它：mpv/ffmpeg 拉媒体时是单连接，而实测跨境单连接常被压在 13–25 Mbps，
// 同一台节点用 8 条并发能到 62–77 Mbps。代理接住 mpv 的 Range 请求，内部用 N 条并发
// Range 去取，拼好按序回给 mpv —— 这是 Surge 那类 URL 改写做不到的事。
//
// 结构：
//   CdnProxy（本文件）        —— HttpServer、连接管理、播放器接口
//   proxy_core.dart           —— Range/切块/缓冲的纯逻辑（已单测）
//
// 正确性优先级高于性能：任何一步出问题都会表现为"卡住/花屏/跳转失灵"，所以
//   * 跟随 mpv 的 Range 语义（206 + Content-Range），不做擅自改写
//   * 命中缓冲的部分直接回，未命中的部分并发取
//   * 取不全就退回**单连接直通**，宁可慢不可错
//   * 任何异常都让这一次请求走直通路径

import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show Uint8List, BytesBuilder;

import 'package:PiliPlus/services/cdn/cdn_debug_log.dart';
import 'package:PiliPlus/services/cdn/proxy_core.dart';

export 'package:PiliPlus/services/cdn/proxy_core.dart'
    show ByteRange, RangeRequest, ContentRange, planChunks, ByteBufferIndex;

/// 一次上游取块的样本。**这是唯一可信的吞吐来源**。
///
/// 为什么不测量"整个请求耗时"：mpv 缓冲满了就不再读，代理的写操作会被背压卡住，
/// 那段时间与网络无关。实测踩过：一次 64MiB 请求算出 2.0 Mbps，而视频其实播得好好的。
/// 逐块计时只覆盖"上游把这段字节发过来"，不含播放器消费时间。
class _ChunkSample {
  const _ChunkSample(this.len, this.ms, {this.ok = true});

  final int len;
  final int ms;
  final bool ok;

  double get mbps => ms <= 0 ? 0 : len * 8 / 1000000 / (ms / 1000);
}

/// 一次请求的统计，用于日志与"瓶颈在网络还是在播放器"的判断。
class _RequestStats {
  int upstream = 0;
  int fallback = 0;
  bool aborted = false;

  /// 花在"从上游取字节"上的时间（含背压，仅供参考，别用它算吞吐）。
  int netMs = 0;

  /// 花在"把字节写给 mpv"上的时间。
  int writeMs = 0;

  /// 逐块样本：并发窗口内的块各自计时。
  final List<_ChunkSample> chunks = [];

  /// 取这批块时实际用了多少条并发。
  int concurrency = 1;

  final Stopwatch total = Stopwatch()..start();

  /// 聚合吞吐：所有块的字节 ÷ 它们整体占用的墙钟时间。
  ///
  /// 分母用 `块数 ÷ 并发数 × 平均单块耗时` 近似：k 个块按 c 并发跑，整体时长约为
  /// (k/c)×平均块时长。这比"耗时求和"（等于串行假设）和"取最长块"都更接近真实。
  ({int bytes, int ms, double mbps, int count, int failed}) get aggregate {
    if (chunks.isEmpty) {
      return (bytes: 0, ms: 0, mbps: 0, count: 0, failed: 0);
    }
    var bytes = 0;
    var sumMs = 0;
    var failed = 0;
    for (final c in chunks) {
      if (!c.ok) failed++;
      bytes += c.len;
      sumMs += c.ms;
    }
    final avgMs = sumMs / chunks.length;
    final effective = concurrency < 1 ? 1 : concurrency;
    final window = (avgMs * chunks.length / effective).ceil();
    return (
      bytes: bytes,
      ms: window,
      mbps: window <= 0 ? 0.0 : bytes * 8 / 1000000 / (window / 1000),
      count: chunks.length,
      failed: failed,
    );
  }
}

/// 播放器侧要引用的媒体。
class ProxyTrack {
  ProxyTrack({required this.url, this.label = ''});

  /// 上游地址（带签名的原始 URL，代理原样使用，只是并发地取）。
  String url;

  /// 仅用于日志/诊断。
  final String label;

  /// 哪些字节已经有了（只记范围，不存数据）。
  final ByteBufferIndex buffer = ByteBufferIndex();

  /// 真实数据：块起始 offset → 该块字节。与 [buffer] 的范围一一对应。
  final Map<int, Uint8List> chunks = {};

  /// 上游总长度；未知时按 -1。
  int total = -1;

  /// 是否正在被 mpv 读取。
  bool active = false;

  /// 预取是否在跑（避免重复起）。
  bool prefetching = false;

  /// 取出 [start, end] 的字节。区间必须已被 [buffer] 标记为可用。
  ///
  /// 按块起始 offset 升序拼接，遇到缺口就停下（缺口应由调用方先补齐）。
  Uint8List take(int start, int end) {
    if (start > end) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    var offset = start;
    final bases = chunks.keys.toList()..sort();
    for (final base in bases) {
      if (offset > end) break;
      final data = chunks[base]!;
      final chunkEnd = base + data.length - 1;
      if (chunkEnd < offset) continue;
      if (base > offset) break; // 缺口
      final from = offset - base;
      final to = (end - base + 1).clamp(0, data.length);
      out.add(Uint8List.sublistView(data, from, to));
      offset = base + to;
    }
    return out.takeBytes();
  }

  /// 写入一块数据。
  void put(ByteRange range, List<int> data) {
    chunks[range.start] = data is Uint8List
        ? data
        : Uint8List.fromList(data);
    buffer.add(range);
    // buffer 裁剪后可能已丢弃某些范围，这里同步丢掉对应的数据，避免内存只增不减
    final live = buffer.ranges;
    chunks.removeWhere(
      (start, d) => !live.any((r) => r.start <= start && start <= r.end),
    );
  }

  void reset() {
    buffer.clear();
    chunks.clear();
    total = -1;
  }
}

/// 代理的对外门面。
class CdnProxy {
  CdnProxy({
    this.connections = 8,
    this.chunkBytes = 512 * 1024,
    this.prefetchAhead = 8 * 1024 * 1024,
    this.bufferLimit = 64 * 1024 * 1024,
    this.userAgent = '',
    this.referer = 'https://www.bilibili.com/',
  });

  /// 并发连接数。
  final int connections;

  /// 每次上游 Range 请求的字节数。
  final int chunkBytes;

  /// 跟播位置保持多远的预取窗口（字节，0 = 不预取）。
  final int prefetchAhead;

  final int bufferLimit;
  final String userAgent;
  final String referer;

  HttpServer? _server;
  HttpClient? _client;
  final Map<String, ProxyTrack> _tracks = {};

  /// 统计：给面板/日志用。
  int servedRequests = 0;
  int upstreamRequests = 0;

  /// 走了直通且成功（并发取失败但单连接救回来了）。
  int fallbackCount = 0;

  /// 并发取失败、直通也失败 → 毁掉连接。
  int abortedForBadUpstream = 0;

  /// 连资源大小都探测不到（上游 403/超时）→ 502。
  int totalUnavailable = 0;

  int errorCount = 0;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  /// 启动本地监听（只绑 127.0.0.1）。
  Future<int> start() async {
    if (_server != null) return port;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = connections + 4
      ..userAgent = userAgent.isEmpty ? null : userAgent;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {}, cancelOnError: false);
    return server.port;
  }

  Future<void> stop() async {
    for (final t in _tracks.values) {
      t.buffer.clear();
    }
    _tracks.clear();
    await _server?.close(force: true);
    _server = null;
    _client?.close(force: true);
    _client = null;
  }

  /// 把一条上游地址变成代理地址（mpv 用这个）。
  ///
  /// 同一个 key 复用同一个 track（保留已缓存字节）；但地址变了必须作废缓存——
  /// 签名 URL 换了、或同一 hashCode 撞车时，旧字节与新地址不是同一份内容。
  String register(String upstreamUrl, {String label = ''}) {
    final key = _key(upstreamUrl);
    final existing = _tracks[key];
    if (existing == null) {
      _tracks[key] = ProxyTrack(url: upstreamUrl, label: label);
    } else if (existing.url != upstreamUrl) {
      existing
        ..url = upstreamUrl
        ..reset();
    }
    return 'http://127.0.0.1:$port/p/$key';
  }

  ProxyTrack? trackOf(String upstreamUrl) => _tracks[_key(upstreamUrl)];

  static String _key(String url) {
    // 用 URL 的 hashCode 稳定生成一个短 key；碰撞概率可忽略，且碰撞只会导致
    // 取到错误的媒体（不会崩），所以这里再带上长度做一点区分。
    final h = url.hashCode.toUnsigned(32).toRadixString(16);
    return '${h}_${url.length}';
  }

  ProxyTrack? _trackFromPath(String path) {
    if (!path.startsWith('/p/')) return null;
    return _tracks[path.substring(3)];
  }

  // ------------------------------------------------------------------ HTTP

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final stats = _RequestStats();
    ProxyTrack? track;
    try {
      track = _trackFromPath(req.uri.path);
      if (track == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      servedRequests++;
      track.active = true;

      // 让上游看到和 mpv 直连时一样的头
      final extra = <String, String>{
        if (userAgent.isNotEmpty) 'User-Agent': userAgent,
        if (referer.isNotEmpty) 'Referer': referer,
      };

      final size = await _ensureTotal(track, extra, stats);
      final wanted = RangeRequest.parse(req.headers.value(HttpHeaders.rangeHeader));
      final range = wanted?.resolve(size) ??
          (size > 0 ? ByteRange(0, size - 1) : null);
      if (range == null) {
        // 连资源大小都拿不到（上游拒绝/超时）：绝不能回一个 200 空响应——
        // 播放器会把它当成有效数据。明确回 502，让播放器走"网络错误"分支。
        if (size <= 0) {
          totalUnavailable++;
          res.statusCode = HttpStatus.badGateway;
          await res.close();
          _logRequest(track, wanted, stats, 0, '拿不到资源大小 → 502');
          return;
        }
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        _logRequest(track, wanted, stats, 0, 'Range 越界 → 416');
        return;
      }

      track.buffer.center = range.start;
      final isPartial = wanted != null;

      res.statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, _contentTypeFor(track.url));
      if (isPartial) {
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          ContentRange.format(range, size > 0 ? size : null),
        );
      }
      res.headers.set(HttpHeaders.contentLengthHeader, '${range.length}');

      // 先起读循环（兜底路径靠它），再补网络数据进来
      unawaited(_pump(track, range, res, extra, stats, isPartial, wanted));
      _schedulePrefetch(track, range.end + 1, extra);
    } catch (e) {
      errorCount++;
      // 出错也要给个明确响应，否则 mpv 会一直等。
      // HttpResponse 没有 headersSent，重复 close 是安全的（内部会忽略）。
      try {
        await res.close();
      } catch (_) {}
      if (track != null) {
        _logRequest(track, null, stats, 0, '处理异常：$e');
      }
    }
  }

  /// 把一次请求的统计写进日志。这是判断"瓶颈在网络还是在播放器"的唯一依据。
  ///
  /// 注意 `netMs` 含播放器背压（缓冲满了 mpv 就不读，代理写操作被卡住），
  /// 所以日志里同时给"墙钟折算 wall"和"逐块聚合 agg"两个数——**后者才可信**。
  void _logRequest(
    ProxyTrack track,
    RangeRequest? wanted,
    _RequestStats stats,
    int bytes, [
    String? note,
  ]) {
    final agg = stats.aggregate;
    CdnDebugLog.record(
      CdnRequestRecord(
        seq: CdnDebugLog.nextSeq(),
        at: DateTime.now(),
        label: track.label,
        host: Uri.tryParse(track.url)?.host ?? '?',
        range: wanted == null
            ? '整段'
            : '${wanted.start ?? ''}-${wanted.end ?? ''}'
                  '${wanted.suffixLength != null ? ' suffix=${wanted.suffixLength}' : ''}',
        bytes: bytes,
        netMs: stats.total.elapsedMilliseconds,
        upstream: stats.upstream,
        fallback: stats.fallback,
        aborted: stats.aborted,
        mbps: agg.count == 0 ? null : agg.mbps,
        chunkCount: agg.count,
        chunkMs: agg.ms,
        chunkFailed: agg.failed,
        concurrency: stats.concurrency,
        note: note,
      ),
    );
  }

  String _contentTypeFor(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    if (path.endsWith('.m4s') || path.contains('/upgcxcode/')) {
      return 'video/mp4';
    }
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.flv')) return 'video/x-flv';
    return 'application/octet-stream';
  }

  /// 探测总长度：发一个 1 字节的 Range，从 Content-Range 里读 total。
  Future<int> _ensureTotal(
    ProxyTrack track,
    Map<String, String> extra,
    _RequestStats stats,
  ) async {
    if (track.total >= 0) return track.total;
    final sw = Stopwatch()..start();
    try {
      final r = await _openUpstream(track.url, const ByteRange(0, 0), extra);
      final resp = await r.close().timeout(const Duration(seconds: 12));
      upstreamRequests++;
      stats.upstream++;
      final cr = ContentRange.parse(
        resp.headers.value(HttpHeaders.contentRangeHeader),
      );
      final status = resp.statusCode;
      final len = resp.contentLength;
      await resp.drain<void>().catchError((_) {});
      if (status == HttpStatus.partialContent && cr?.total != null) {
        // 只取到 total，这 1 个字节不进缓冲（探测用的请求，不复用其内容）
        track.total = cr!.total!;
      } else if (status == HttpStatus.ok && len > 0) {
        track.total = len;
      }
    } catch (_) {
      track.total = -1;
    } finally {
      stats.netMs += sw.elapsedMilliseconds;
    }
    return track.total;
  }

  Future<HttpClientRequest> _openUpstream(
    String url,
    ByteRange range,
    Map<String, String> extra,
  ) async {
    final client = _client!;
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end}');
    extra.forEach(req.headers.set);
    return req;
  }

  /// 取一段数据进缓冲。**逐块并发**，任一块失败立即抛错（由调用方决定退回直通）。
  ///
  /// 取块大小按请求长度自适应：固定用小碎块会让 12 条连接对 4MiB 请求拆出 ~342KiB
  /// 的碎块，请求数翻倍而吞吐不变。这里让它至少覆盖"一次能并行吃下的量"。
  Future<void> _fetch(
    ProxyTrack track,
    ByteRange want,
    Map<String, String> extra, [
    _RequestStats? stats,
  ]) async {
    final perConn = _chunkSizeFor(want.length);
    final chunks = planChunks(
      want,
      connections: connections,
      perConn: perConn,
    );
    if (stats != null && chunks.length > stats.concurrency) {
      stats.concurrency = chunks.length;
    }
    await Future.wait([
      for (final c in chunks) _fetchChunk(track, c, extra, stats),
    ]);
  }

  /// 每块多大：不小于 [chunkBytes]，也不让块数超过连接数。
  int _chunkSizeFor(int wantLength) {
    if (connections <= 1) return wantLength;
    final even = (wantLength / connections).ceil();
    return even > chunkBytes ? even : chunkBytes;
  }

  Future<void> _fetchChunk(
    ProxyTrack track,
    ByteRange range,
    Map<String, String> extra, [
    _RequestStats? stats,
  ]) async {
    final sw = Stopwatch()..start();
    try {
      final req = await _openUpstream(track.url, range, extra);
      upstreamRequests++;
      stats?.upstream++;
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != HttpStatus.partialContent) {
        await resp.drain<void>().catchError((_) {});
        throw HttpException('上游返回 ${resp.statusCode}，非 206');
      }
      final got = <int>[];
      await for (final part in resp.timeout(const Duration(seconds: 20))) {
        got.addAll(part);
        if (got.length >= range.length) break;
      }
      if (got.length < range.length) {
        throw HttpException('上游只给了 ${got.length}/${range.length} 字节');
      }
      track.put(range, got.sublist(0, range.length));
      // 逐块样本：这就是"这条路能跑多快"的直接证据
      stats?.chunks.add(_ChunkSample(range.length, sw.elapsedMilliseconds));
    } catch (e) {
      stats?.chunks.add(_ChunkSample(range.length, sw.elapsedMilliseconds, ok: false));
      rethrow;
    } finally {
      stats?.netMs += sw.elapsedMilliseconds;
    }
  }

  /// 按顺序把字节写给 mpv。
  ///
  /// 兜底逻辑在这里：库里没有的字节就先同步取一段；取失败就**直通**（单连接）——
  /// 宁可慢，也不能让播放停住。
  Future<void> _pump(
    ProxyTrack track,
    ByteRange range,
    HttpResponse res,
    Map<String, String> extra,
    _RequestStats stats,
    bool isPartial,
    RangeRequest? wanted,
  ) async {
    var offset = range.start;
    final end = range.end;
    var written = 0;
    try {
      while (offset <= end) {
        // 1) 缓冲里已连续的字节直接发
        final contiguous = track.buffer.contiguousEndFrom(offset);
        if (contiguous >= offset) {
          final stop = contiguous > end ? end : contiguous;
          final sw = Stopwatch()..start();
          final data = track.take(offset, stop);
          res.add(data);
          await res.flush();
          stats.writeMs += sw.elapsedMilliseconds;
          written += data.length;
          offset = stop + 1;
          continue;
        }
        // 2) 缺：取一段（至少覆盖到请求末尾，或一次能并行吃下的量）
        final fetchEnd = _min(end, offset + chunkBytes * connections - 1);
        final want = ByteRange(offset, fetchEnd);
        try {
          await _fetch(track, want, extra, stats);
        } catch (e) {
          final sw = Stopwatch()..start();
          final before = stats.upstream;
          final ok = await _passthrough(track, ByteRange(offset, end), res, extra, stats);
          stats.writeMs += sw.elapsedMilliseconds;
          if (ok) {
            fallbackCount++;
            stats.fallback++;
            written += end - offset + 1;
          } else {
            // 直通也拿不到：这时响应头早已发出，只能毁掉连接。
            // 吐一个"长度对但内容为空"的响应更糟 —— 播放器会把它当成有效数据。
            abortedForBadUpstream++;
            stats.aborted = true;
            await _abort(res);
          }
          if (stats.upstream == before) stats.upstream++; // 至少记一次尝试
          return;
        }
        if (track.buffer.contiguousEndFrom(offset) < offset) {
          // 取回来了却没有覆盖 offset：说明上游行为异常，直通
          final ok = await _passthrough(track, ByteRange(offset, end), res, extra, stats);
          if (ok) {
            fallbackCount++;
            stats.fallback++;
            written += end - offset + 1;
          } else {
            abortedForBadUpstream++;
            stats.aborted = true;
            await _abort(res);
          }
          return;
        }
      }
    } catch (e) {
      errorCount++;
    } finally {
      try {
        await res.close();
      } catch (_) {}
      _logRequest(
        track,
        wanted,
        stats,
        written,
        isPartial ? null : '整段请求',
      );
    }
  }

  /// 直通：单连接、原样透传上游字节（跳过缓冲）。
  ///
  /// 两条硬约束（都踩过）：
  ///   1. 上游必须是 206（或对无 Range 请求的 200）。否则返回 false —— 此时**不能**
  ///      往响应里写任何东西，因为响应头早发出去了，写了就变成"声明长度 != 实际长度"。
  ///   2. 写入绝不能超过 [range] 的长度。上游若忽略了 Range 返回整段（200），
  ///      直接倒给播放器会触发 "Content size exceeds specified contentLength"。
  Future<bool> _passthrough(
    ProxyTrack track,
    ByteRange range,
    HttpResponse res,
    Map<String, String> extra, [
    _RequestStats? stats,
  ]) async {
    final sw = Stopwatch()..start();
    try {
      final req = await _openUpstream(track.url, range, extra);
      upstreamRequests++;
      stats?.upstream++;
      final resp = await req.close();
      final ok =
          resp.statusCode == HttpStatus.partialContent ||
          resp.statusCode == HttpStatus.ok;
      if (!ok) {
        await resp.drain<void>().catchError((_) {});
        return false;
      }
      var written = 0;
      await for (final part in resp) {
        if (written >= range.length) break;
        var take = part;
        final remain = range.length - written;
        if (part.length > remain) {
          // 流里给的是 List<int>，不能直接 sublistView（那要求 TypedData）
          take = part.sublist(0, remain);
        }
        res.add(take);
        written += take.length;
      }
      return written == range.length;
    } finally {
      stats?.netMs += sw.elapsedMilliseconds;
    }
  }

  /// 毁掉这条连接。用在"响应头已发出、但拿不到数据"的场合。
  Future<void> _abort(HttpResponse res) async {
    try {
      final socket = await res.detachSocket(writeHeaders: false);
      socket.destroy();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  void _schedulePrefetch(ProxyTrack track, int from, Map<String, String> extra) {
    if (prefetchAhead <= 0) return;
    if (track.total > 0 && from >= track.total) return;
    final end = track.total > 0
        ? _min(track.total - 1, from + prefetchAhead - 1)
        : from + prefetchAhead - 1;
    if (end < from) return;
    final want = ByteRange(from, end);
    if (track.buffer.gaps(want).isEmpty) return; // 已经都有
    if (track.prefetching) return;
    track.prefetching = true;
    unawaited(
      _fetch(track, want, extra)
          .catchError((_) {})
          .whenComplete(() => track.prefetching = false),
    );
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// 诊断字符串（面板/日志用）。
  String debugSummary() {
    final b = StringBuffer()
      ..write('代理 :$port ')
      ..write('请求$servedRequests 上游$upstreamRequests ')
      ..write('直通$fallbackCount 错误$errorCount');
    for (final t in _tracks.values) {
      b
        ..write('\n  ${t.label.isEmpty ? 'track' : t.label} ')
        ..write('total=${t.total < 0 ? '?' : t.total} ')
        ..write('缓存=${t.buffer.cachedBytes ~/ 1024}KB');
    }
    return b.toString();
  }
}
