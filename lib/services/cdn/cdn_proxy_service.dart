// 本地并发代理的生命周期管理 + 单例门面。
//
// 播放器侧只跟这个类打交道：
//   1. 播放前调 [prepare] 拿到"改写后的 URL"（失败就原样返回，绝不让播放失败）
//   2. 页面销毁时调 [release]
//
// 为什么要有这一层：代理会接管媒体流，出问题的表现是卡住/花屏。所以这里的策略是
// **任何异常都退回原始地址**——代理只做加速，不做必需品。

import 'dart:async';

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
      // 缓冲上限按平台给：视频+音频两条流，各自一份。移动端给 32MB（合计约 64MB 峰值），
      // 桌面给 64MB。上限只影响"能回看多远"，超了会丢最远的数据再重取，不影响正确性。
      final bufferLimit = PlatformUtils.isMobile
          ? 32 * 1024 * 1024
          : 64 * 1024 * 1024;
      final proxy = CdnProxy(
        connections: connections ?? Pref.cdnProxyConnections,
        // 512KiB × 8 连接 = 一次最多 4MiB，够填满 mpv 的读窗口
        chunkBytes: 512 * 1024,
        // 预取 8MiB：太小会频繁等网络，太大浪费流量
        prefetchAhead: 8 * 1024 * 1024,
        bufferLimit: bufferLimit,
        userAgent: _userAgent,
      );
      await proxy.start();
      _proxy = proxy;
      _lastError = null;
      return proxy;
    } catch (e) {
      _lastError = '$e';
      _proxy = null;
      return null;
    }
  }

  /// 把一条上游地址换成代理地址。
  ///
  /// 未开启、或启动失败时**原样返回**——这是刻意的：宁可没加速，也不能播不了。
  Future<String> rewrite(String upstreamUrl) async {
    if (!enabled) return upstreamUrl;
    if (!upstreamUrl.startsWith('http')) return upstreamUrl;
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
    try {
      await p?.stop();
    } catch (_) {}
  }

  static String _labelOf(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    if (path.contains('30080') || path.endsWith('.m4s')) {
      // B 站的 m4s 分片：路径里带 -1-（视频轨）/-2-（音频轨）
      if (path.contains('-2-')) return 'audio';
      if (path.contains('-1-')) return 'video';
      return 'media';
    }
    return uri?.host ?? 'media';
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
