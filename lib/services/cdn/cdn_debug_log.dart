// CDN/代理相关的诊断日志：落盘 + 内存环形缓冲 + 应用内可复制。
//
// 为什么要有它：代理是否生效、卡顿出在哪一段，光靠"感觉"判断不了。原来的面板只给汇总
// 计数（请求数/上游数），既没有速率也没有耗时，等于没法定位。这里把每次媒体请求的关键
// 指标都记下来：
//
//   [req] range=0-4194303 bytes=4194304 net=1.23s speed=27.3Mbps upstream=13 fallback=0
//
// 其中 net 是"代理花在网络取字节上的时间"。把它和播放器实际等待时间对比，就能判断
// 瓶颈到底在网络还是在播放器/解码：
//   * net ≈ 播放器等待 → 网络是真瓶颈，并发才有意义
//   * net 远小于等待 → 网络不是瓶颈，加并发没用（该去查解码/渲染/缓冲设置）
//
// 日志同时写文件（可用"导出日志"取出）与内存（供应用内查看页显示）。

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/cdn/frame_profiler.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// 一条媒体请求的记录。
class CdnRequestRecord {
  CdnRequestRecord({
    required this.seq,
    required this.at,
    required this.label,
    required this.host,
    required this.range,
    required this.bytes,
    required this.netMs,
    required this.upstream,
    required this.fallback,
    required this.aborted,
    this.mbps,
    this.chunkCount,
    this.chunkMs,
    this.chunkFailed,
    this.concurrency,
    this.note,
  });

  final int seq;
  final DateTime at;
  final String label;

  /// 实际命中的上游主机（判断"是不是走了 08c"就看它）。
  final String host;
  final String range;
  final int bytes;

  /// 整个请求的墙钟时间。**含播放器背压，不能用来算吞吐**。
  final int netMs;
  final int upstream;

  /// 走了直通（并发失败，单连接救回）的次数。
  final int fallback;

  /// 是否毁掉过连接。
  final bool aborted;

  /// 逐块聚合吞吐（可信的那个数）。
  final double? mbps;
  final int? chunkCount;
  final int? chunkMs;
  final int? chunkFailed;
  final int? concurrency;
  final String? note;

  double get wallMbps =>
      netMs <= 0 ? 0 : bytes * 8 / 1000000 / (netMs / 1000);

  String toLine() {
    final b = StringBuffer()
      ..write('[req#$seq] ')
      ..write(_ts(at))
      ..write(' ')
      ..write(label)
      ..write('@')
      ..write(host)
      ..write(' range=${range.length > 24 ? '${range.substring(0, 24)}…' : range}')
      ..write(' bytes=$bytes')
      ..write(' net=${(netMs / 1000).toStringAsFixed(2)}s')
      ..write(' wall=${wallMbps.toStringAsFixed(1)}Mbps')
      ..write(' upstream=$upstream');
    if (fallback > 0) b.write(' fallback=$fallback');
    if (aborted) b.write(' ABORTED');
    if (note != null && note!.isNotEmpty) b.write(' note=$note');
    b.write('\n         ');
    if (chunkCount == null || chunkCount == 0) {
      b.write('[agg] 无取块样本（整段命中缓冲或走了直通）');
    } else {
      b
        ..write('[agg] ')
        ..write('${chunkCount!} 块 × 并发 ${concurrency ?? 1}')
        ..write('  合计 ${(bytes / 1048576).toStringAsFixed(1)}MiB')
        ..write(' / ${((chunkMs ?? 0) / 1000).toStringAsFixed(2)}s')
        ..write(' = ${(mbps ?? 0).toStringAsFixed(1)}Mbps');
      if ((chunkFailed ?? 0) > 0) b.write('  失败块 ${chunkFailed!}');
    }
    return b.toString();
  }

  static String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// 播放器侧的一次采样。
class CdnPlayerSample {
  CdnPlayerSample({
    required this.at,
    required this.positionMs,
    required this.bufferMs,
    required this.durationMs,
    required this.buffering,
    required this.stalled,
    this.consumedMbps,
    this.proxyMbps,
  });

  final DateTime at;
  final int positionMs;

  /// 已缓冲到多远（相对播放位置的**前向**缓冲量，由调用方换算）。
  final int bufferMs;
  final int durationMs;
  final bool buffering;

  /// 与上一次采样相比是否发生了新的卡顿。
  final bool stalled;

  /// 这段窗口内播放器实际消费的码率。**判断"够不够播"就看它**。
  final double? consumedMbps;

  /// 同期代理侧的聚合吞吐（有代理时才有）。
  final double? proxyMbps;

  String toLine() {
    final posS = (positionMs / 1000).toStringAsFixed(0);
    final bufS = (bufferMs / 1000).toStringAsFixed(1);
    final totalS = durationMs <= 0
        ? '?'
        : (durationMs / 1000).toStringAsFixed(0);
    final b = StringBuffer()
      ..write('[play] ')
      ..write(CdnRequestRecord._ts(at))
      ..write(' pos=${posS}s/$totalS buffer=${bufS}s');
    final c = consumedMbps;
    if (c != null) b.write(' consumed=${c.toStringAsFixed(1)}Mbps');
    final p = proxyMbps;
    if (p != null) b.write(' proxy=${p.toStringAsFixed(1)}Mbps');
    if (buffering) b.write(' BUFFERING');
    if (stalled) b.write(' STALLED');
    return b.toString();
  }
}

/// 解码器侧的一次采样：**回答"4K 卡顿是解码器的问题吗"**。
///
/// 为什么要单独立一类：网络侧已经量到 92–235 Mbps、缓冲垫也够，但 4K 依旧卡。
/// 剩下的嫌疑只有解码/渲染，而"到底走的硬解还是软解、是不是在丢帧、解码器有多忙"
/// 这三项以前完全看不到。mpv 自己知道这些，只是没人去问：
///   * [hwdecCurrent] —— `hwdec-current`，**实际生效**的解码器；`no` 就是软解
///   * [droppedFrames] —— `frame-drop-count`，一直涨说明解不过来
///   * [decoderLoad]   —— `video-decoder-...-load`，>0.9 说明解码线程已饱和
class CdnDecoderStats {
  const CdnDecoderStats({
    required this.at,
    this.hwdecCurrent,
    this.codec,
    this.width,
    this.height,
    this.fps,
    this.droppedFrames,
    this.decoderLoad,
    this.estimatedVfFps,
    this.containerFps,
  });

  final DateTime at;

  /// 实际生效的硬解方式。`no`/空 = 软解（iOS 上软解 4K 必卡）。
  final String? hwdecCurrent;
  final String? codec;
  final String? width;
  final String? height;
  final String? fps;

  /// 累计丢帧数（只增不减，看增量）。
  final int? droppedFrames;

  /// 解码器占用（mpv 属性里的 "load" 后缀项）。
  final double? decoderLoad;

  /// mpv 估算的实际渲染帧率。
  final double? estimatedVfFps;
  final double? containerFps;

  bool get isSoftDecode {
    final s = hwdecCurrent?.trim().toLowerCase();
    return s == null || s.isEmpty || s == 'no' || s == 'none';
  }

  String toLine() {
    final b = StringBuffer()
      ..write('[dec] ')
      ..write(CdnRequestRecord._ts(at));
    if (codec != null) b.write(' codec=$codec');
    if (width != null && height != null) b.write(' ${width}x$height');
    if (containerFps != null) {
      b.write(' fps=${containerFps!.toStringAsFixed(2)}');
    }
    b.write(
      ' hwdec=${hwdecCurrent == null || hwdecCurrent!.isEmpty ? '?' : hwdecCurrent}',
    );
    if (isSoftDecode) b.write('  ← 软解！');
    if (decoderLoad != null) {
      b.write(' load=${(decoderLoad! * 100).toStringAsFixed(0)}%');
    }
    if (estimatedVfFps != null) {
      b.write(' vfFps=${estimatedVfFps!.toStringAsFixed(1)}');
    }
    if (droppedFrames != null) b.write(' dropped=$droppedFrames');
    return b.toString();
  }
}

abstract final class CdnDebugLog {
  static const int _maxLines = 400;
  static final List<String> _lines = [];
  static final List<CdnRequestRecord> _records = [];

  static File? _file;
  static IOSink? _sink;
  static int _seq = 0;
  static Future<void>? _opening;

  /// 内存里的日志行（新的在后）。
  static List<String> get lines => List.unmodifiable(_lines);

  /// 内存里的结构化记录（新的在后）。
  static List<CdnRequestRecord> get records => List.unmodifiable(_records);

  static bool get enabled => _enabled;
  static bool _enabled = false;

  static String? get filePath => _file?.path;

  /// 开关。关闭时不写文件、不记内存（省电），但已有内容保留。
  ///
  /// 顺带联动帧耗时记录仪：用户反馈的"视频页一碰就卡""后台回来滑动也卡"是整机级
  /// 现象，必须同时拿到帧数据才能判断是 UI 线程还是光栅线程的问题。
  static void setEnabled(bool value) {
    _enabled = value;
    FrameProfiler.setEnabled(value);
    if (value) unawaited(_ensureOpen());
  }

  static int nextSeq() => ++_seq;

  static void log(String line) {
    if (!_enabled) return;
    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeRange(0, _lines.length - _maxLines);
    _sink?.writeln(line);
    if (kDebugMode) debugPrint(line);
  }

  static void record(CdnRequestRecord r) {
    if (!_enabled) return;
    _records.add(r);
    if (_records.length > _maxLines) {
      _records.removeRange(0, _records.length - _maxLines);
    }
    log(r.toLine());
  }

  /// 汇总：最近 N 条记录的平均速率与"网络占比"。
  ///
  /// [playerWaitMs] 由调用方传入（当前没有精确的播放器等待时间，先留空），
  /// 只统计代理侧的网络耗时。
  static String summary({int last = 10}) {
    final recent = _records.length <= last
        ? _records
        : _records.sublist(_records.length - last);
    if (recent.isEmpty) return '暂无媒体请求记录';
    var bytes = 0;
    var chunkBytes = 0;
    var chunkMs = 0;
    var upstream = 0;
    var fallback = 0;
    var aborted = 0;
    for (final r in recent) {
      bytes += r.bytes;
      upstream += r.upstream;
      fallback += r.fallback;
      if (r.aborted) aborted++;
      // 聚合口径：把各次请求的"块字节/块时间"累加，得到整体上游吞吐
      if ((r.chunkCount ?? 0) > 0) {
        chunkBytes += r.bytes;
        chunkMs += r.chunkMs ?? 0;
      }
    }
    final aggMbps = chunkMs <= 0 ? 0.0 : chunkBytes * 8 / 1000000 / (chunkMs / 1000);
    return '最近 ${recent.length} 次请求：'
        '共 ${(bytes / 1048576).toStringAsFixed(1)}MiB · '
        '上游请求 $upstream · 直通 $fallback · 中断 $aborted\n'
        '上游聚合吞吐（可信）：${aggMbps.toStringAsFixed(1)} Mbps';
  }

  static Future<void> _ensureOpen() async {
    if (_sink != null) return;
    if (_opening != null) return _opening;
    _opening = _open();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
  }

  static Future<void> _open() async {
    try {
      // appSupportDirPath 是 path_utils.dart 里的顶层 late final（不在 PathUtils 类里）
      final dir = Directory('$appSupportDirPath/cdn_debug');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}/cdn_proxy.log');
      _file = f;
      _sink = f.openWrite(mode: FileMode.append);
      // 文件是追加的，所以"会话开始"每次进程启动都会写一条 —— 靠它给日志分段。
      log('=== 进程启动 ${DateTime.now()} ===');
    } catch (e) {
      _file = null;
      _sink = null;
    }
  }

  /// 由代理服务在启动/停止/改配置时调用，让日志自带"什么时候开了什么"。
  static void marker(String text) {
    if (!_enabled) return;
    log('--- $text ---');
  }

  /// 周期性记录播放器侧状态。
  ///
  /// 为什么必须记这个：此前只埋了网络侧指标，于是"为什么卡"根本无从判断——
  /// 网络聚合吞吐有 92–213 Mbps，但播放器消费速率、缓冲深度、卡顿次数全都是空的。
  /// 有了这几项才能区分：
  ///   * 缓冲深度长期很小 + 消费速率 ≈ 码率 → 网络供不上（该优化下载）
  ///   * 缓冲深度够大仍然卡                     → 问题在解码/渲染
  ///   * 消费速率远低于码率                     → 播放器主动暂停读取（缓冲已足）
  static void sample(CdnPlayerSample s) {
    if (!_enabled) return;
    _samples.add(s);
    if (_samples.length > 120) _samples.removeRange(0, _samples.length - 120);
    log(s.toLine());
  }

  static final List<CdnPlayerSample> _samples = [];
  static List<CdnPlayerSample> get samples => List.unmodifiable(_samples);

  /// 记录一次解码器采样（与 [sample] 同一个开关）。
  static void decoderSample(CdnDecoderStats s) {
    if (!_enabled) return;
    _decoderSamples.add(s);
    if (_decoderSamples.length > 60) {
      _decoderSamples.removeRange(0, _decoderSamples.length - 60);
    }
    log(s.toLine());
  }

  static final List<CdnDecoderStats> _decoderSamples = [];
  static List<CdnDecoderStats> get decoderSamples =>
      List.unmodifiable(_decoderSamples);

  /// 解码器摘要：给面板直接用的一句话结论。
  static String decoderSummary() {
    if (_decoderSamples.isEmpty) return '暂无解码器采样（需开启调试日志并播放）';
    final last = _decoderSamples.last;
    final first = _decoderSamples.first;
    final dropped = (last.droppedFrames ?? 0) - (first.droppedFrames ?? 0);
    return '最近一次：${last.codec ?? '?'} '
        '${last.width ?? '?'}x${last.height ?? '?'} '
        'hwdec=${last.hwdecCurrent?.isEmpty ?? true ? '?' : last.hwdecCurrent}'
        '${last.isSoftDecode ? '（软解）' : ''}'
        '${last.decoderLoad != null ? '  解码占用 ${(last.decoderLoad! * 100).toStringAsFixed(0)}%' : ''}'
        '\n本次会话丢帧合计：$dropped';
  }

  /// 清空（内存与文件）。
  static Future<void> clear() async {
    _lines.clear();
    _records.clear();
    _samples.clear();
    _decoderSamples.clear();
    _seq = 0;
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      if (_file?.existsSync() ?? false) await _file!.writeAsString('');
    } catch (_) {}
  }

  /// 供"导出/复制"用：全部内容拼成一个字符串。
  static Future<String> export() async {
    try {
      if (_file?.existsSync() ?? false) {
        final content = await _file!.readAsString();
        if (content.isNotEmpty) return content;
      }
    } catch (_) {}
    return _lines.join('\n');
  }

  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }
}
