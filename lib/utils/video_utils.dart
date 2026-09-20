import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/services/cdn/cdn_auto_picker.dart';
import 'package:PiliPlus/services/cdn/cdn_pick.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 视频播放相关的工具。
///
/// [getCdnUrl] / [getLiveCdnUrl] / [selectCodec] 是**纯函数**（不碰存储），所以这个文件
/// 只在一个地方依赖应用层：[bootstrap] 把用户偏好注入进来。这样 CDN 选择逻辑可以在
/// 未 patch 的 Flutter SDK 上离线单测（见 test/services/cdn/cdn_pick_test.dart）。
abstract final class VideoUtils {
  static CDNService cdnService = CDNService.backupUrl;
  static String? liveCdnUrl;
  static bool disableAudioCDN = false;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;

    if (defaultCDNService == CDNService.auto) {
      final target = autoPickedHost(urls, CdnAutoPicker.resolve);
      // 没有可用排名、或排名里挑不出这条视频自己的候选 → 原样放过（等同“备用URL”）。
      return target == null ? urls.first : swapUrlHost(urls.first, target);
    }

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  /// 把用户设置注入进来。main 里在 GStorage.init() 之后调一次。
  static void bootstrap() {
    cdnService = Pref.defaultCDNService;
    liveCdnUrl = Pref.liveCdnUrl;
    disableAudioCDN = Pref.disableAudioCDN;
  }

  /// 播放前按需触发一轮测速（「自动」模式用）。
  ///
  /// 刻意做成「本次不阻塞」：这一轮拿到的是上一轮的排名，测完写盘供下一次播放用。
  /// 好处是播放启动路径上不多一次网络往返；代价是第一次开自动要多等一个视频。
  /// [sampleUrls] 是这条视频自己的候选地址（签名是新鲜的，必须当场用）。
  ///
  /// [lite] 给移动网络/移动端用的小额档：连接数与字节都减半，一轮总流量从约 250MB
  /// 降到约 100MB（21 个候选）。默认 false（Wi-Fi/桌面）。
  /// 最近一次播放用到的签名媒体地址（只记第一条视频轨）。
  ///
  /// 用途：CDN 设置对话框要拿一条**新鲜的签名地址**当测速模板。拿它比固定用内置样本
  /// 视频准——某个节点有没有你正在看的那条视频的资源，和"那个样本视频"不是一回事。
  /// 只在内存里，不进存储：签名地址是带期限的凭据，没必要写盘。
  static String? get lastSample => _lastSample;
  static String? _lastSample;

  /// 注释见上；由播放流程调用。
  static void rememberSample(String url) => _lastSample = url;

  static void maybeProbe(
    Iterable<String> sampleUrls, {
    String? videoKey,
    bool lite = false,
  }) {
    final sample = sampleUrls.isEmpty ? null : sampleUrls.first;
    if (sample == null) return;
    // 不管是不是自动模式都记下来：对话框测速要用。
    _lastSample = sample;

    if (cdnService != CDNService.auto) return;
    if (CdnAutoPicker.isRunning) return;

    // 节流：同一台设备 5 分钟内只允许触发一轮（列表页/连播会把这里调很多次）。
    final now = DateTime.now();
    if (_lastProbeAt != null &&
        now.difference(_lastProbeAt!) < const Duration(minutes: 5)) {
      return;
    }

    // 网络指纹是异步算的：先刷新，再判断要不要测（换了 Wi-Fi 就该重测）。
    // 先测完“要不要测”再打节流时间戳，避免「什么都没做也把下一轮挡住」。
    _lastProbeAt = now;
    CdnAutoPicker.primeNetwork()
        .then((_) {
          if (!CdnAutoPicker.needsRefresh()) return null;
          return CdnAutoPicker.run(
            sampleUrl: sample,
            videoKey: videoKey,
            config: lite ? CdnProbeConfig.mobile : const CdnProbeConfig(),
          );
        })
        .catchError((Object e) {
          if (kDebugMode) debugPrint('cdn auto probe failed: $e');
          return null;
        });
  }

  static DateTime? _lastProbeAt;

  /// 单测/诊断用：重置节流时间戳。
  static void resetProbeThrottle() => _lastProbeAt = null;

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }
}
