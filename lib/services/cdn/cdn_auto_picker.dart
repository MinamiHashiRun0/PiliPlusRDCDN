// 「自动」选节点的存储与触发层：读/写排名、判断要不要重测、跑一轮测速。
//
// 决策逻辑在 cdn_pick.dart（无 Flutter 依赖，可单独测）；这里只负责把它接到 App 的
// Hive 存储与偏好上，因此会 import 应用层（storage / storage_pref）。
//
// ignore_for_file: avoid_print

import 'package:PiliPlus/services/cdn/cdn_pick.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

abstract final class CdnAutoPicker {
  static const int defaultTtlMs = kCdnRankTtlMs;

  /// 一次视频加载最多触发一轮测速，防止列表页/连播把网络打满。
  static bool _running = false;

  static bool get isRunning => _running;

  static CdnProbeReport? readReport() {
    final raw = GStorage.setting.get(SettingBoxKey.cdnSpeedTestRank);
    if (raw is! String || raw.isEmpty) return null;
    try {
      return decodeReport(raw);
    } catch (_) {
      // 报告结构变了（跨版本升级）就当没有，下次重测。
      return null;
    }
  }

  static int get ttlMs => defaultTtlMs;

  static bool isFresh(CdnProbeReport report) =>
      report.isFresh(DateTime.now().millisecondsSinceEpoch, ttlMs);

  static void saveReport(CdnProbeReport report, {String? network}) {
    GStorage.setting.put(SettingBoxKey.cdnSpeedTestRank, encodeReport(report));
    GStorage.setting.put(
      SettingBoxKey.cdnSpeedTestNetwork,
      network ?? cachedNetworkFingerprint,
    );
  }

  static void clear() {
    GStorage.setting
      ..delete(SettingBoxKey.cdnSpeedTestRank)
      ..delete(SettingBoxKey.cdnSpeedTestNetwork);
  }

  /// 这次播放该用哪台。返回 null = 按 backupUrl 原样放过。
  static String? resolve(Iterable<String> sampleHosts, {String? videoKey}) {
    final report = readReport();
    if (report == null) return null;
    return pickCdnHost(
      report,
      sampleHosts,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      ttlMs: ttlMs,
    );
  }

  /// 网络指纹异步刷新（决策侧只读缓存，见 cdn_pick.dart）。
  static Future<String> primeNetwork() => primeNetworkFingerprint();

  /// 排名是否需要重测：没有、过期、或换了网络。
  static bool needsRefresh() {
    final report = readReport();
    if (report == null) return true;
    if (!isFresh(report)) return true;
    final stored = GStorage.setting.get(SettingBoxKey.cdnSpeedTestNetwork);
    if (stored is String && stored != cachedNetworkFingerprint) return true;
    return false;
  }

  /// 跑一轮测速并落盘。返回报告；失败返回 null（不抛，调用方看日志）。
  ///
  /// [sampleUrl] 必须是**当前视频的已签名地址**：签名只在短时间有效，所以每次都用当场
  /// 拿到的那条当模板，不能把 URL 缓存在报告里复用。
  static Future<CdnProbeReport?> run({
    required String sampleUrl,
    String? videoKey,
    List<CdnCandidate>? candidates,
    CdnProbeConfig config = const CdnProbeConfig(),
  }) async {
    if (_running) return readReport();
    if (!Pref.cdnSpeedTest) return null;
    _running = true;
    final probe = CdnProbe(config: config);
    try {
      final results = await probe.measureAll(
        candidates ?? CdnCandidate.fromServices(),
        sampleUrl: sampleUrl,
      );
      final report = probe.rank(
        results,
        sampleUrl: sampleUrl,
        videoKey: videoKey ?? Uri.parse(sampleUrl).path,
      );
      saveReport(report);
      return report;
    } catch (e) {
      print('cdn probe failed: $e');
      return null;
    } finally {
      _running = false;
    }
  }
}
