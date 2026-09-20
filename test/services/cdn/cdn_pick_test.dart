// 「自动」选节点的纯逻辑测试：不需要网络、不需要存储、不需要 patch 过的 Flutter SDK。
//
//   flutter test test/services/cdn/cdn_pick_test.dart
//
// 存储层（CdnAutoPicker 的读写）不在这里测——它 import 应用层，而那个链路要 patch 过的
// Flutter SDK 才编译得过（patch.ps1 会往 SDK 里注入 textPainter 等符号）。

import 'package:PiliPlus/services/cdn/cdn_pick.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:flutter_test/flutter_test.dart';

const _ttl = kCdnRankTtlMs;
const _now = 1700000000000;

const _cos = 'upos-sz-mirrorcos.bilivideo.com';
const _ali = 'upos-sz-mirrorali.bilivideo.com';
const _hk = 'cn-hk-eq-bcache-01.bilivideo.com';

CdnProbeResult _ok(String host, double mbps) => CdnProbeResult(
  name: host.split('.').first,
  host: host,
  region: CdnRegion.of(host),
  singleMbps: mbps,
  parallelMbps: mbps,
);

CdnProbeReport _report(
  List<CdnProbeResult> ranked, {
  int testedAt = _now,
  String? pickHost,
}) => CdnProbeReport(
  testedAt: testedAt,
  videoKey: 'test',
  results: ranked,
  ranked: ranked,
  pick: pickHost == null
      ? (ranked.isEmpty ? null : ranked.first)
      : ranked.firstWhere((e) => e.host == pickHost),
);

void main() {
  group('pickCdnHost', () {
    test('选中的那台在候选里 → 直接换过去', () {
      final report = _report([_ok(_ali, 90), _ok(_cos, 40)], pickHost: _ali);
      expect(
        pickCdnHost(report, [_cos, _ali], nowMs: _now, ttlMs: _ttl),
        _ali,
      );
    });

    test('排名过期 → 不换（原样放过）', () {
      final report = _report([_ok(_ali, 90)], testedAt: _now - _ttl - 1);
      expect(
        pickCdnHost(report, [_ali, _cos], nowMs: _now, ttlMs: _ttl),
        isNull,
      );
    });

    test('刚好未过期 → 仍然可用', () {
      final report = _report([_ok(_ali, 90)], testedAt: _now - _ttl + 1);
      expect(pickCdnHost(report, [_ali], nowMs: _now, ttlMs: _ttl), _ali);
    });

    test('选中的那台不在这条视频的候选里 → 退到排名内第一个可用节点', () {
      // 排名第一是 hk（这条视频没有），第二是 ali（候选里只有 cos/ali）→ 取 ali。
      final report = _report(
        [_ok(_hk, 99), _ok(_ali, 50), _ok(_cos, 30)],
        pickHost: _hk,
      );
      expect(pickCdnHost(report, [_cos, _ali], nowMs: _now, ttlMs: _ttl), _ali);
    });

    test('全部候选都不在排名里 → null（不猜）', () {
      final report = _report([_ok(_hk, 99)]);
      expect(pickCdnHost(report, [_cos, _ali], nowMs: _now, ttlMs: _ttl), isNull);
    });

    test('没有 pick（只测了部分候选）→ 退到排名里候选内的第一个', () {
      // 部分测速（移动端小额档可能中途停）：ranked 有值但没选出 pick。
      final report = CdnProbeReport(
        testedAt: _now,
        videoKey: 'test',
        results: [_ok(_hk, 99), _ok(_ali, 50)],
        ranked: [_ok(_hk, 99), _ok(_ali, 50)],
        note: '未选出目标',
      );
      expect(pickCdnHost(report, [_cos, _ali], nowMs: _now, ttlMs: _ttl), _ali);
    });

    test('ranked 全空 → null', () {
      final report = CdnProbeReport(
        testedAt: _now,
        videoKey: 'test',
        results: const [],
        ranked: const [],
      );
      expect(pickCdnHost(report, [_cos], nowMs: _now, ttlMs: _ttl), isNull);
    });

    test('被标记拒绝的 host 会跳过（某视频在某节点上没有资源）', () {
      final report = _report([_ok(_ali, 90), _ok(_cos, 40)], pickHost: _ali);
      expect(
        pickCdnHost(
          report,
          [_cos, _ali],
          nowMs: _now,
          ttlMs: _ttl,
          rejectedHosts: {_ali},
        ),
        _cos,
      );
    });

    test('候选为空 → null', () {
      final report = _report([_ok(_ali, 90)]);
      expect(pickCdnHost(report, const [], nowMs: _now, ttlMs: _ttl), isNull);
    });
  });

  group('hostsOfUrls / swapUrlHost', () {
    const sample =
        'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/16/53/1/1-1-30032.m4s'
        '?e=abc&deadline=1758300000&upsig=deadbeef&u=ip';

    test('抽出主机名并去重（baseUrl + 两个 backupUrl）', () {
      final hosts = hostsOfUrls([
        sample,
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/16/53/1/1-1-30032.m4s?e=abc',
        sample, // 重复
      ]);
      expect(hosts, {
        'upos-sz-mirrorcosov.bilivideo.com',
        'upos-sz-mirrorali.bilivideo.com',
      });
    });

    test('忽略解析不出主机的项', () {
      expect(hostsOfUrls(['', 'not a url', 'https://ok.bilivideo.com/a']), {
        'ok.bilivideo.com',
      });
    });

    test('换主机但路径与签名逐字节保留', () {
      final out = swapUrlHost(sample, 'upos-tf-all-hw.bilivideo.com');
      expect(Uri.parse(out).host, 'upos-tf-all-hw.bilivideo.com');
      expect(Uri.parse(out).path, Uri.parse(sample).path);
      expect(Uri.parse(out).query, Uri.parse(sample).query);
      expect(out.contains('upsig=deadbeef'), isTrue);
    });

    test('已是目标主机则原样返回', () {
      expect(swapUrlHost(sample, Uri.parse(sample).host), sample);
    });
  });

  group('autoPickedHost', () {
    test('把候选主机交给 resolve 决定', () {
      const sample =
          'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1/2/3.m4s?e=1';
      Iterable<String>? seen;
      final host = autoPickedHost([sample], (hosts) {
        seen = hosts;
        return 'upos-sz-mirrorcos.bilivideo.com';
      });
      expect(host, 'upos-sz-mirrorcos.bilivideo.com');
      expect(seen, {'upos-sz-mirrorcosov.bilivideo.com'});
    });

    test('resolve 返回 null 时也不抛', () {
      expect(autoPickedHost(const [], (_) => null), isNull);
    });
  });

  group('networkFingerprintOf', () {
    test('取第一个非回环 IPv4 的前三段', () {
      expect(networkFingerprintOf([('en0', '192.168.31.57')]), 'en0/192.168.31.0');
    });

    test('同一网段不同主机地址指纹一致（DHCP 换地址不该触发重测）', () {
      expect(
        networkFingerprintOf([('en0', '10.0.5.9')]),
        networkFingerprintOf([('en0', '10.0.5.200')]),
      );
    });

    test('不同网段指纹不同（换 Wi-Fi 要重测）', () {
      expect(
        networkFingerprintOf([('en0', '192.168.1.20')]),
        isNot(networkFingerprintOf([('en0', '192.168.2.20')])),
      );
    });

    test('IPv6 不参与', () {
      expect(networkFingerprintOf([('en0', 'fe80::1')]), 'unknown');
    });

    test('跳过回环与自分配地址', () {
      expect(networkFingerprintOf([('lo', '127.0.0.1')]), 'unknown');
      expect(networkFingerprintOf([('en0', '169.254.10.3')]), 'unknown');
    });

    test('回环之后还有正常接口时取正常的那个', () {
      expect(
        networkFingerprintOf([('lo', '127.0.0.1'), ('en0', '172.20.10.2')]),
        'en0/172.20.10.0',
      );
    });

    test('空输入与非法地址都回落 unknown', () {
      expect(networkFingerprintOf(const []), 'unknown');
      expect(networkFingerprintOf([('en0', 'not-an-ip')]), 'unknown');
    });
  });

  group('指纹缓存', () {
    test('debugSetNetworkFingerprint 能改缓存值（存储层读的就是它）', () {
      debugSetNetworkFingerprint('wlan0/192.168.1.0');
      expect(cachedNetworkFingerprint, 'wlan0/192.168.1.0');
      debugSetNetworkFingerprint('unknown');
    });
  });
}
