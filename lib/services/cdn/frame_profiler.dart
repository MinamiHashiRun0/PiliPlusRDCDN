// 帧耗时自动记录仪：把"卡不卡"从体感变成每秒钟一行数字。
//
// 为什么需要它：用户反馈"视频页一碰 UI 就卡""后台挂一会回来，滑动搜索结果也卡"。
// 这两条指向的不是同一个组件，而是**整机的帧预算被吃掉了**。光靠看代码猜不出来，
// 必须知道：
//   * 是 UI 线程（build/layout）慢，还是光栅线程（raster）慢？→ build 与 raster 分开报
//   * 慢在什么时候？→ 每秒一行，和页面操作对得上
//   * 平均帧率掉了没有？→ 用"本秒实际画了几帧"算，掉帧一目了然
//
// 只在开启 CDN 调试日志时运行，且**只读不干预**渲染流程。
//
//   [fps] 构建 12.3ms/帧(最差 71.2) 光栅 8.1ms/帧(最差 55.0) 58帧/秒
//     └ 最差构建 71.2ms 超过 16.7ms 预算
//
// 判据（120Hz iPad 的预算是 8.3ms，60Hz 是 16.7ms）：
//   * 构建慢 → Dart 侧（build/layout/setState 风暴、SliverChildBuilderDelegate 重建）
//   * 光栅慢 → GPU 侧（Impeller 着色器、超大纹理、模糊/阴影）
//   * 两者都不慢但帧率低 → 有人塞了太多帧或者 vsync 被卡住

import 'dart:async';

import 'package:PiliPlus/services/cdn/cdn_debug_log.dart';
import 'package:flutter/scheduler.dart';

abstract final class FrameProfiler {
  static bool enabled = false;

  static Timer? _timer;
  static bool _ticking = false;
  static int _frames = 0;

  static int _buildUs = 0;
  static int _buildWorstUs = 0;
  static int _rasterUs = 0;
  static int _rasterWorstUs = 0;
  static int _janky = 0;

  /// 最近一次落盘的 [fps] 行（诊断页直接用，不必去翻日志）。
  static String? get lastLine => _lastLine;
  static String? _lastLine;

  /// 开关。开着时每秒落一行 [fps] 到调试日志。
  static void setEnabled(bool value) {
    enabled = value;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      if (_ticking) {
        SchedulerBinding.instance.removeTimingsCallback(_onTimings);
        _ticking = false;
      }
      return;
    }
    if (_ticking) return;
    _ticking = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _reset();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _flush());
  }

  static void _reset() {
    _frames = 0;
    _buildUs = 0;
    _buildWorstUs = 0;
    _rasterUs = 0;
    _rasterWorstUs = 0;
    _janky = 0;
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (!enabled) return;
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds;
      final r = t.rasterDuration.inMicroseconds;
      _frames++;
      _buildUs += b;
      _rasterUs += r;
      if (b > _buildWorstUs) _buildWorstUs = b;
      if (r > _rasterWorstUs) _rasterWorstUs = r;
      if (t.totalSpan.inMicroseconds > 16700) _janky++;
    }
  }

  static void _flush() {
    if (!enabled) return;
    if (_frames == 0) return; // 没有渲染活动就不刷屏
    final n = _frames;
    final avgBuild = _buildUs / n / 1000;
    final avgRaster = _rasterUs / n / 1000;
    final worstBuild = _buildWorstUs / 1000;
    final worstRaster = _rasterWorstUs / 1000;
    final line =
        '[fps] 构建 ${avgBuild.toStringAsFixed(1)}ms/帧'
        '(最差 ${worstBuild.toStringAsFixed(1)}) '
        '光栅 ${avgRaster.toStringAsFixed(1)}ms/帧'
        '(最差 ${worstRaster.toStringAsFixed(1)}) '
        '$n帧/秒'
        '${_janky > 0 ? ' 掉帧 $_janky' : ''}'
        '${worstBuild > 16.7 ? '  ← 构建超预算' : ''}'
        '${worstRaster > 16.7 ? '  ← 光栅超预算' : ''}';
    _lastLine = line;
    CdnDebugLog.log(line);
    _reset();
  }
}
