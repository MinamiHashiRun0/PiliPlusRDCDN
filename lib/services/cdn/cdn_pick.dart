// 「自动」选节点的**纯逻辑**：不 import Flutter、不碰存储。
//
// 为什么单独一个文件：应用层（storage_pref 那条链）会拖进整个 app，而这个 fork 依赖
// Flutter SDK 的 patch（patch.ps1 往 SDK 里注入 textPainter 等符号）。没有 patch 的环境
// 编译不了 app → 任何 import 应用层的测试都加载不了。把决策逻辑与存储分开，
// 这部分就能在任何环境跑 `flutter test`（见 test/services/cdn/cdn_pick_test.dart）。
//
// 存储与触发在 services/cdn/cdn_auto_picker.dart。

import 'dart:io' as io;

import 'package:PiliPlus/services/cdn/cdn_probe.dart';

/// 默认排名有效期，与 Surge 版 BiliFast 的 rank TTL 一致。
const int kCdnRankTtlMs = 6 * 60 * 60 * 1000;

/// 从报告里挑出这条视频该用哪台机器。
///
/// 顺序：排名必须新鲜 → 选中的那台必须在 [sampleHosts] 里 → 否则退到排名里第一个
/// 「候选内」且未被拒绝的节点 → 都没有就返回 null（原样放过，不猜）。
///
/// [sampleHosts] 是这条视频自己的地址们的 host（baseUrl/backupUrl）。**只在候选内换机**
/// 是刻意的：换到一台这条视频压根没有资源的机器上，结果就是播不了——那不是加速。
/// 这也正是 PiliPlus 原版那句「此视频可能无法替换为该 CDN」的由来。
String? pickCdnHost(
  CdnProbeReport report,
  Iterable<String> sampleHosts, {
  required int nowMs,
  int ttlMs = kCdnRankTtlMs,
  Set<String>? rejectedHosts,
}) {
  if (!report.isFresh(nowMs, ttlMs)) return null;

  final hosts = sampleHosts.where((e) => e.isNotEmpty).toSet();
  if (hosts.isEmpty) return null;
  final rejected = rejectedHosts ?? const <String>{};

  final pick = report.pick;
  if (pick != null && hosts.contains(pick.host) && !rejected.contains(pick.host)) {
    return pick.host;
  }
  // pick 为空（例如只测了部分候选，排名有值但没选出目标）时不该直接放弃：
  // 退到排名里第一个「候选内」的节点。所有候选都被拒/都不在排名里才返回 null。
  for (final r in report.ranked) {
    if (hosts.contains(r.host) && !rejected.contains(r.host)) return r.host;
  }
  return null;
}

/// (接口名, 地址字符串) —— 指纹函数的输入。
typedef HostAddress = (String, String);

/// 一组媒体地址里的主机名（baseUrl + backupUrl…），去重且保序。
Set<String> hostsOfUrls(Iterable<String> urls) {
  final hosts = <String>{};
  for (final url in urls) {
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) hosts.add(host);
  }
  return hosts;
}

/// 只换主机名，其余（路径、签名 query）原样保留。
String swapUrlHost(String url, String host) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host == host) return url;
  return uri.replace(host: host).toString();
}

/// 「自动」模式对一组地址的最终决定：返回该换到哪台，null 表示原样放过。
///
/// [resolve] 是存储层的查询（CdnAutoPicker.resolve），传进来是为了让本文件不依赖存储。
String? autoPickedHost(
  Iterable<String> urls,
  String? Function(Iterable<String> sampleHosts) resolve,
) => resolve(hostsOfUrls(urls));

/// 网络指纹：同网段算同一个网络。
///
/// 取第一个非回环、非自分配的 IPv4 的前三段。用网段而不是 SSID：跨平台可用、不需要
/// 任何权限（iOS 上拿 SSID 要定位权限，不值当），DHCP 换地址也不会误判成换网络。
///
/// 输入刻意收成 [HostAddress] 而不是 `io.NetworkInterface`：后者在 dart:io 里是
/// `abstract interface class`，测试构造不出来（socket.dart:193）。
String networkFingerprintOf(List<HostAddress> entries) {
  for (final (name, ip) in entries) {
    if (name == 'lo') continue;
    final io.InternetAddress addr;
    try {
      addr = io.InternetAddress(ip);
    } catch (_) {
      continue;
    }
    if (addr.type != io.InternetAddressType.IPv4) continue;
    if (addr.isLoopback) continue;
    final bytes = addr.rawAddress;
    if (bytes.length != 4) continue;
    if (bytes[0] == 169 && bytes[1] == 254) continue; // 自分配地址，没有网络可言
    return '$name/${bytes[0]}.${bytes[1]}.${bytes[2]}.0';
  }
  return 'unknown';
}

/// 当前网络指纹的缓存值。
///
/// [io.NetworkInterface.list] 是异步的，而 getCdnUrl 是同步 API，所以指纹异步算好后放这里，
/// 决策侧只读缓存。App 启动或进入播放页前调 [primeNetworkFingerprint] 刷新一次即可。
String get cachedNetworkFingerprint => _fingerprint;
String _fingerprint = 'unknown';

/// 测试用：直接设置缓存值。
void debugSetNetworkFingerprint(String value) => _fingerprint = value;

/// 异步刷新网络指纹缓存。拿不到时回落 'unknown'（不会误判成"换了网络"以外的行为）。
Future<String> primeNetworkFingerprint() async {
  try {
    final list = await io.NetworkInterface.list(
      includeLoopback: false,
      type: io.InternetAddressType.IPv4,
    );
    _fingerprint = networkFingerprintOf([
      for (final ni in list)
        for (final addr in ni.addresses) (ni.name, addr.address),
    ]);
  } catch (_) {
    _fingerprint = 'unknown';
  }
  return _fingerprint;
}
