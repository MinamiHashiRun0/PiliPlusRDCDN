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

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// 一条媒体请求的记录。
class CdnRequestRecord {
  CdnRequestRecord({
    required this.seq,
    required this.at,
    required this.label,
    required this.range,
    required this.bytes,
    required this.netMs,
    required this.upstream,
    required this.fallback,
    required this.aborted,
    this.note,
  });

  final int seq;
  final DateTime at;
  final String label;
  final String range;
  final int bytes;
  final int netMs;
  final int upstream;

  /// 走了直通（并发失败，单连接救回）的次数。
  final int fallback;

  /// 是否毁掉过连接。
  final bool aborted;
  final String? note;

  double get mbps =>
      netMs <= 0 ? 0 : bytes * 8 / 1000000 / (netMs / 1000);

  String toLine() {
    final b = StringBuffer()
      ..write('[req#$seq] ')
      ..write(_ts(at))
      ..write(' ')
      ..write(label)
      ..write(' range=${range.length > 24 ? '${range.substring(0, 24)}…' : range}')
      ..write(' bytes=$bytes')
      ..write(' net=${(netMs / 1000).toStringAsFixed(2)}s')
      ..write(' speed=${mbps.toStringAsFixed(1)}Mbps')
      ..write(' upstream=$upstream');
    if (fallback > 0) b.write(' fallback=$fallback');
    if (aborted) b.write(' ABORTED');
    if (note != null && note!.isNotEmpty) b.write(' note=$note');
    return b.toString();
  }

  static String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
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
  static void setEnabled(bool value) {
    _enabled = value;
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
    var netMs = 0;
    var upstream = 0;
    var fallback = 0;
    var aborted = 0;
    for (final r in recent) {
      bytes += r.bytes;
      netMs += r.netMs;
      upstream += r.upstream;
      fallback += r.fallback;
      if (r.aborted) aborted++;
    }
    final mbps = netMs <= 0 ? 0.0 : bytes * 8 / 1000000 / (netMs / 1000);
    return '最近 ${recent.length} 次请求：'
        '共 ${(bytes / 1048576).toStringAsFixed(1)}MiB · '
        '网络耗时 ${(netMs / 1000).toStringAsFixed(1)}s · '
        '平均 ${mbps.toStringAsFixed(1)} Mbps · '
        '上游请求 $upstream · 直通 $fallback · 中断 $aborted';
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
      log('--- 会话开始 ${DateTime.now()} ---');
    } catch (e) {
      _file = null;
      _sink = null;
    }
  }

  /// 清空（内存与文件）。
  static Future<void> clear() async {
    _lines.clear();
    _records.clear();
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
