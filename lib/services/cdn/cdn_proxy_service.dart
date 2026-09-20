// 本地并发代理的生命周期管理 + 单例门面。
//
// 播放器侧只跟这个类打交道：
//   1. 播放前调 [prepare] 拿到"改写后的 URL"（失败就原样返回，绝不让播放失败）
//   2. 页面销毁时调 [release]
//
// 为什么要有这一层：代理会接管媒体流，出问题的表现是卡住/花屏。所以这里的策略是
// **任何异常都退回原始地址**——代理只做加速，不做必需品。

import 'dart:async';

import 'package:PiliPlus/services/cdn/cdn_debug_log.dart';
import 'package:PiliPlus/services/cdn/cdn_proxy.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

class CdnProxyService {
  CdnProxyService._();

  static final CdnProxyService instance = CdnProxyService._();

  CdnProxy? _proxy;
  Future<CdnProxy?>? _starting;
  String? _lastError;

  /// 引用计数：同一个代理服务多个播放器实例（列表页预加载 + 正片）。
  int _refs = 0;

  bool get isRunning => _proxy?.isRunning ?? false;
  String? get lastError => _lastError;
  bool get enabled => Pref.cdnProxy;

  /// 诊断信息（面板/日志用）。
  String debugSummary() => _proxy?.debugSummary() ?? '代理未启动';

  /// 启动并返回代理实例；[connections] 不传就用设置里的值。
  ///
  /// 并发调用只会启动一次（[_starting] 兜住）。
  Future<CdnProxy?> ensureStarted({int? connections}) async {
    if (_proxy?.isRunning ?? false) return _proxy;
    if (_starting != null) return _starting;
    _starting = _start(connections);
    try {
      return await _starting;
    } finally {
      _starting = null;
    }
  }

  Future<CdnProxy?> _start(int? connections) async {
    try {
      // 单位换算：字节 → 秒，需要知道码率。
      //
      // 实测教训：原来预取窗口固定 8MiB。1080P60（约 7Mbps）下 8MiB ≈ 9.5 秒，
      // 够用，用户看到"缓冲一路刷满、拖动秒加载"；4K（约 35Mbps）下 8MiB ≈ 1.9 秒，
      // 刚垫上就被吃完，于是"4K 完全看不到快速缓冲"。窗口必须按**播放时长**给。
      //
      // 取 512KiB/s（≈4Mbps）作为兜底码率估计；画面/音频两条流各自算。
      const fallbackBytePerSec = 512 * 1024;
      final bytesPerSec = _estimateBytesPerSec() ?? fallbackBytePerSec;

      // 目标：预取约 90 秒的播放量，且不超过缓冲上限（超了会被裁剪，白下）
      final bufferLimit = PlatformUtils.isMobile
          ? 256 * 1024 * 1024
          : 512 * 1024 * 1024;
      final wantPrefetch = bytesPerSec * 90;
      final prefetchAhead = wantPrefetch.clamp(
        8 * 1024 * 1024,
        bufferLimit ~/ 2,
      );

      final proxy = CdnProxy(
        connections: connections ?? Pref.cdnProxyConnections,
        // 512KiB × 8 连接 = 一次最多 4MiB，够填满 mpv 的读窗口
        chunkBytes: 512 * 1024,
        prefetchAhead: prefetchAhead,
        bufferLimit: bufferLimit,
        userAgent: _userAgent,
      );
      await proxy.start();
      _proxy = proxy;
      _lastError = null;
      _observedBytesPerSec = bytesPerSec;
      CdnDebugLog.marker(
        '代理启动 :${proxy.port} · 并发 ${proxy.connectionCount} 条 · '
        '缓冲上限 ${bufferLimit ~/ (1024 * 1024)}MB/流 · '
        '预取 ${prefetchAhead ~/ (1024 * 1024)}MB'
        '（按 ${(bytesPerSec * 8 / 1000000).toStringAsFixed(1)}Mbps 估算 ≈ '
        '${(prefetchAhead / bytesPerSec).toStringAsFixed(0)}s 播放量）',
      );
      return proxy;
    } catch (e) {
      _lastError = '$e';
      _proxy = null;
      return null;
    }
  }

  int? _observedBytesPerSec;

  /// 估计当前媒体的每秒字节数（视频+音频两条流之和）。
  ///
  /// 来自签名 URL 的 `bw` 参数，第一条视频就准。拿不到 `bw` 时按每条流 1MiB/s
  /// （≈8Mbps）粗估 —— 宁可窗口偏大（多下一点）也不要偏小（4K 下窗口不足会一直卡）。
  int? _estimateBytesPerSec() {
    final observed = _observedBytesPerSec;
    if (observed != null && observed > 0) return observed;
    final n = _trackBytesPerSec.length;
    return n == 0 ? null : n * 1024 * 1024;
  }

  int? get estimatedMbps {
    final b = _observedBytesPerSec;
    return b == null ? null : (b * 8 / 1000000).round();
  }

  /// 由播放器侧观测到的消费速率喂进来（仅在拿不到 bw 时作为补充）。
  static void observeBitrate(int bytesPerSec) {
    if (bytesPerSec <= 0) return;
    CdnProxyService.instance._observedBytesPerSec ??= bytesPerSec;
  }

  /// 把一条上游地址换成代理地址。
  ///
  /// 未开启、或启动失败时**原样返回**——这是刻意的：宁可没加速，也不能播不了。
  Future<String> rewrite(String upstreamUrl) async {
    // 每次开播都记一次"开关当前处于什么状态"，这样日志自带开/关的分界，
    // 不用靠猜哪一段是开着代理跑的。
    final on = enabled;
    if (_lastLoggedEnabled != on) {
      _lastLoggedEnabled = on;
      CdnDebugLog.marker('代理开关 = ${on ? '开' : '关'}');
    }
    if (!on) return upstreamUrl;
    if (!upstreamUrl.startsWith('http')) return upstreamUrl;

    // 先从 URL 估码率：B 站签名地址的 query 里直接带 `bw=`（字节/秒），
    // 实测 bw=711365 对应约 5.7Mbps，与 playurl 模型里的 bandwidth 一致。
    // 有它就不必等"播放一段再观察消费速率"，第一条视频的预取窗口就是准的。
    final bw = _bytesPerSecOf(upstreamUrl);
    if (bw != null) _registerBitrate(upstreamUrl, bw);

    final proxy = await ensureStarted();
    if (proxy == null) return upstreamUrl;
    try {
      _refs++;
      return proxy.register(upstreamUrl, label: _labelOf(upstreamUrl));
    } catch (e) {
      _lastError = '$e';
      return upstreamUrl;
    }
  }

  bool? _lastLoggedEnabled;

  /// 每条流各自的码率（字节/秒），由 URL 的 bw 参数得到。
  final Map<String, int> _trackBytesPerSec = {};

  void _registerBitrate(String url, int bytesPerSec) {
    _trackBytesPerSec[url] = bytesPerSec;
    // 只留最近几条，避免长时间播放后无限增长
    if (_trackBytesPerSec.length > 8) {
      _trackBytesPerSec.remove(_trackBytesPerSec.keys.first);
    }
    _observedBytesPerSec = _trackBytesPerSec.values.fold<int>(0, (a, b) => a + b);
  }

  /// 从签名 URL 的 query 里取 `bw`（字节/秒）。
  static int? _bytesPerSecOf(String url) {
    final v = Uri.tryParse(url)?.queryParameters['bw'];
    if (v == null) return null;
    final n = int.tryParse(v);
    return (n == null || n <= 0) ? null : n;
  }

  /// 播放页销毁时调用，等到没有引用就停掉代理（省电、释放端口）。
  Future<void> release() async {
    _refs--;
    if (_refs > 0) return;
    _refs = 0;
    await stop();
  }

  Future<void> stop() async {
    final p = _proxy;
    _proxy = null;
    _refs = 0;
    if (p != null) CdnDebugLog.marker('代理停止');
    try {
      await p?.stop();
    } catch (_) {}
  }

  /// 流标签，用于日志可读性。
  ///
  /// B 站 m4s 文件名形如 `42009365316-1-30032.m4s`：`-轨号-清晰度`，轨号 1=视频、2=音频。
  /// 之前只按 `-1-`/`-2-` 判断，遇到不匹配的形态就退回 host（于是日志里出现了 "7"）。
  static final _trackRe = RegExp(r'-(\d+)-(\d+)\.m4s$');

  static String _labelOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final m = _trackRe.firstMatch(path);
    if (m != null) {
      final track = m.group(1);
      final qn = m.group(2);
      final kind = switch (track) {
        '1' => 'video',
        '2' => 'audio',
        _ => 'track$track',
      };
      return '$kind(qn$qn)';
    }
    if (path.contains('-2-')) return 'audio';
    if (path.contains('-1-')) return 'video';
    return 'media';
  }

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 单测/诊断用：把代理换成自定义实例（或 null 清掉）。
  void debugSetProxy(CdnProxy? proxy) => _proxy = proxy;
}

/// 给日志用：输出当前是否在跑、失败原因。
String proxyStatusLine() {
  final s = CdnProxyService.instance;
  if (!s.enabled) return 'CDN 并发代理：关闭';
  if (!s.isRunning) {
    return 'CDN 并发代理：已开启但未启动${s.lastError == null ? '' : '（${s.lastError}）'}';
  }
  return s.debugSummary();
}
