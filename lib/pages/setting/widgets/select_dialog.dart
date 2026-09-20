import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(
                      item.$2,
                      style: titleMedium,
                    ),
                    subtitle: subtitleBuilder?.call(context, index),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;

  const CdnSelectDialog({
    super.key,
    this.sample,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

/// 每条候选的测速状态。label 为 null 表示还没测完。
class _CdnProbeState {
  _CdnProbeState(this.service);

  final CDNService service;
  double? mbps;
  int? ttfbMs;
  int? statusCode;
  String? failure;

  String? get label {
    final m = mbps;
    if (m != null) {
      final ttfb = ttfbMs;
      return '${m.toStringAsFixed(1)} Mbps${ttfb == null ? '' : ' · ${ttfb}ms'}';
    }
    return failure;
  }
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  static const _probeConfig = CdnProbeConfig(
    // 对话框里要快：只测单连接，1MiB 就够区分节点档位
    singleBytes: 1024 * 1024,
  );

  /// 同时最多几条探测在飞。原版是串行 21 个节点，最坏 21×15s。
  /// 从 6 降到 4：跨境握手贵，并发太高反而互相抢连接、大面积超时。
  static const _probeConcurrency = 4;

  late final List<_CdnProbeState> _probes;
  late final bool _cdnSpeedTest;

  /// 只在需要回落到「内置样本视频」时用它去请求 playurl。
  Dio? _dio;

  @override
  void initState() {
    _cdnSpeedTest = Pref.cdnSpeedTest;
    _probes = [
      for (final s in CDNService.values) _CdnProbeState(s),
    ];
    if (_cdnSpeedTest) {
      _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      )..options.headers = {
        'user-agent': BrowserUa.pc,
        'referer': HttpString.baseUrl,
      };
      _startSpeedTest();
    }
    super.initState();
  }

  @override
  void dispose() {
    _dio?.close(force: true);
    super.dispose();
  }

  /// 拿一条**新鲜的签名媒体地址**当测速模板。优先级：
  ///   1. 播放页传进来的当前视频（最好）
  ///   2. VideoUtils.lastSample：最近一次播放时记下的地址（几秒~几分钟前，签名仍有效）
  ///   3. 内置样本视频：只在两条都没有时才用，需要请求一次 playurl
  ///
  /// 为什么要绕这一圈：原版固定用 BV1fK4y1t7hj 当样本，测出来的是"那个视频在这个
  /// 节点上"的速度；而某个节点有没有**你正在看的那条视频**的资源，是另一回事。
  Future<String?> _resolveTemplate() async {
    if (widget.sample?.playUrls.firstOrNull case final url?) return url;
    if (VideoUtils.lastSample case final url?) return url;

    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    return result.dataOrNull?.dash?.video?.first.playUrls.firstOrNull;
  }

  Future<void> _startSpeedTest() async {
    try {
      final template = await _resolveTemplate();
      if (template == null) {
        if (mounted) {
          setState(() {
            for (final p in _probes) {
              p.failure = '没有可用的测速样本';
            }
          });
        }
        return;
      }

      final probe = CdnProbe(config: _probeConfig);
      final targets = [
        for (final p in _probes)
          if (p.service.host case final host?)
            (
              state: p,
              candidate: CdnCandidate(
                name: p.service.name,
                host: host,
                desc: p.service.desc,
              ),
            ),
      ];

      // **整个对话框共用一条 HttpClient**。
      // 之前每条探测各自 new 一个，等于每次都重做 TCP+TLS 握手；跨境握手常要 2–5 秒，
      // 6 条并发一起抢就大面积超时，面板上表现为全部 `---`。复用后连接 keep-alive。
      final client = HttpClient()
        ..connectionTimeout = _probeConfig.connectTimeout
        ..maxConnectionsPerHost = _probeConcurrency + 2;

      // 原版是串行跑 21 个节点（最坏 21×15s）。这里用固定并发的工作池。
      var next = 0;
      Future<void> worker() async {
        while (mounted) {
          final index = next++;
          if (index >= targets.length) return;
          final target = targets[index];
          // 模板不合法（连 http(s) 都不是）时不必发请求
          if (CdnProbe.buildProbeUrl(template, target.candidate.host) == null) {
            if (mounted) {
              setState(() => target.state.failure = '样本地址不合法');
            }
            continue;
          }
          final result = await probe.measure(
            target.candidate,
            sampleUrl: template,
            withParallel: false,
            client: client,
          );
          if (!mounted) return;
          setState(() {
            target.state
              ..mbps = result.singleMbps
              ..ttfbMs = result.singleTtfbMs
              ..statusCode = result.statusCode
              // 失败时带上细分原因（超时/连接重置/DNS 失败…），别再只显示 ---
              ..failure = result.failure == null
                  ? null
                  : (result.errorDetail == null
                        ? result.verdict
                        : '${result.verdict} · ${result.errorDetail}');
          });
        }
      }

      try {
        await Future.wait([
          for (var i = 0; i < _probeConcurrency; i++) worker(),
        ]);
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CDN speed test failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectDialog<CDNService>(
      title: 'CDN 设置',
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index) {
              final item = _probes[index];
              return Text(
                item.label ?? '---',
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            }
          : null,
    );
  }
}
