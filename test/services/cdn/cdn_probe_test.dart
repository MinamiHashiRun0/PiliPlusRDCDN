// CdnProbe 的离线单测：全部为纯 Dart，不需要网络、不需要设备。
//
// 跑法（装了 Flutter 之后）：
//   flutter test test/services/cdn/cdn_probe_test.dart
// 或者只装了 Dart SDK：
//   dart test test/services/cdn/cdn_probe_test.dart

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:PiliPlus/utils/wbi.dart' show md5Hex;
import 'package:flutter_test/flutter_test.dart';

/// 样本 URL 刻意长得像真实签名：路径带 /upgcxcode/，query 里有 e/u/deadline 等。
const _sample =
    'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/16/53/42009365316/'
    '42009365316-1-30032.m4s'
    '?e=ig8euxZM2rNcNbdlhoNvNC8BqJIzNbfqXBvEqxTEto8BTrNvN0GvT90W5JZMkX'
    '&deadline=1758300000&gen=playurlv3&nbs=1&oi=3025718326&os=cosov&platform=pc'
    '&trid=abc123&u=ip&upsig=deadbeef&uparams=e,deadline,gen,nbs,oi,os,platform,trid,u';

CdnProbeResult _ok(
  String host,
  double? single, {
  double? parallel,
  int? ttfb,
  CdnRegion? region,
  bool partial = false,
}) => CdnProbeResult(
  name: host.split('.').first,
  host: host,
  region: region ?? CdnRegion.of(host),
  singleMbps: single,
  parallelMbps: parallel,
  singleTtfbMs: ttfb,
  partial: partial,
);

void main() {
  group('buildProbeUrl', () {
    test('换 host 但保留路径与全部 query（签名不能动）', () {
      final out = CdnProbe.buildProbeUrl(
        _sample,
        'upos-tf-all-hw.bilivideo.com',
      );
      expect(out, isNotNull);
      final uri = Uri.parse(out!);
      expect(uri.host, 'upos-tf-all-hw.bilivideo.com');
      expect(uri.path, Uri.parse(_sample).path);
      expect(uri.query, Uri.parse(_sample).query);
      // 逐字节确认签名参数没被重排或转义
      expect(out.contains('upsig=deadbeef'), isTrue);
      expect(out.contains('e=ig8euxZM2rNcNbdlhoNvNC8BqJIzNbfq'), isTrue);
    });

    test('样本带端口时不会把端口带到新 host 上', () {
      const withPort =
          'https://upos-tf-all-hw.bilivideo.com:8082/upgcxcode/a/b/c.m4s?e=1&u=2';
      final out = CdnProbe.buildProbeUrl(withPort, 'upos-sz-mirrorcos.bilivideo.com');
      expect(out, isNotNull);
      expect(Uri.parse(out!).hasPort, isFalse);
      expect(Uri.parse(out).host, 'upos-sz-mirrorcos.bilivideo.com');
      expect(out.contains('/upgcxcode/a/b/c.m4s?e=1&u=2'), isTrue);
    });

    test('非 http(s) 或非法输入返回 null（由调用方标 notMedia）', () {
      expect(CdnProbe.buildProbeUrl('not a url', 'a.bilivideo.com'), isNull);
      expect(CdnProbe.buildProbeUrl('ftp://x/y.m4s', 'a.bilivideo.com'), isNull);
      expect(CdnProbe.buildProbeUrl('', 'a.bilivideo.com'), isNull);
    });
  });

  group('候选池', () {
    test('只取有 host 的服务，baseUrl/backupUrl 这类哨兵不进池', () {
      final pool = CdnCandidate.fromServices();
      expect(pool, isNotEmpty);
      expect(pool.any((e) => e.name == 'baseUrl'), isFalse);
      expect(pool.any((e) => e.name == 'backupUrl'), isFalse);
      expect(pool.length, CDNService.values.where((e) => e.host != null).length);
      for (final c in pool) {
        expect(c.host, isNotEmpty, reason: '${c.name} 的 host 不能为空');
      }
    });

    test('region 归类', () {
      expect(
        CdnCandidate.fromServices()
            .firstWhere((e) => e.name == 'akamai')
            .region,
        CdnRegion.overseas,
      );
      expect(
        CdnCandidate.fromServices()
            .firstWhere((e) => e.name == 'cosov')
            .region,
        CdnRegion.overseas,
      );
      expect(
        CdnCandidate.fromServices()
            .firstWhere((e) => e.name == 'hk_bcache')
            .region,
        CdnRegion.overseas,
      );
      expect(
        CdnCandidate.fromServices().firstWhere((e) => e.name == 'cos').region,
        CdnRegion.mainland,
      );
      expect(
        CdnCandidate.fromServices()
            .firstWhere((e) => e.name == 'tf_hw')
            .region,
        CdnRegion.mainland,
      );
    });
  });

  group('排名与选目标', () {
    final probe = CdnProbe();

    test('吞吐优先，同速看延迟', () {
      final report = probe.rank([
        _ok('upos-sz-mirrorcos.bilivideo.com', 30, parallel: 40, ttfb: 90),
        _ok('upos-sz-mirrorali.bilivideo.com', 30, parallel: 40, ttfb: 20),
        _ok('upos-sz-mirrorhw.bilivideo.com', 30, parallel: 55, ttfb: 200),
      ], sampleUrl: _sample);

      expect(report.ranked.map((e) => e.host).toList(), [
        'upos-sz-mirrorhw.bilivideo.com', // 55 最快
        'upos-sz-mirrorali.bilivideo.com', // 同为 40，延迟 20 < 90
        'upos-sz-mirrorcos.bilivideo.com',
      ]);
      expect(report.pick?.host, 'upos-sz-mirrorhw.bilivideo.com');
    });

    test('被剔除的不进排名，全部失败时 pick 为 null 且给出回落说明', () {
      final report = probe.rank([
        const CdnProbeResult(
          name: 'akamai',
          host: 'upos-hz-mirrorakam.akamaized.net',
          region: CdnRegion.overseas,
          statusCode: 403,
          failure: CdnProbeFailure.rejected,
        ),
        const CdnProbeResult(
          name: 'hwov',
          host: 'upos-sz-mirrorhwov.bilivideo.com',
          region: CdnRegion.overseas,
          failure: CdnProbeFailure.timeout,
        ),
      ], sampleUrl: _sample);

      expect(report.ranked, isEmpty);
      expect(report.pick, isNull);
      expect(report.note, isNotNull);
      // 剔除原因要能带到面板上
      expect(report.results.first.verdict, contains('403'));
    });

    test('没有并发轮时用单连接值排名', () {
      final report = probe.rank([
        _ok('upos-sz-mirrorcos.bilivideo.com', 12),
        _ok('upos-sz-mirrorali.bilivideo.com', 25),
      ], sampleUrl: _sample);
      expect(report.pick?.host, 'upos-sz-mirrorali.bilivideo.com');
    });

    test('hkFirst 优先取港澳台/海外节点，没有才回落全场第一', () {
      final hk = CdnProbe(config: const CdnProbeConfig(hkFirst: true));
      final withHk = hk.rank([
        _ok('upos-tf-all-hw.bilivideo.com', 90, parallel: 95),
        _ok('cn-hk-eq-bcache-01.bilivideo.com', 12, parallel: 14, ttfb: 30),
      ], sampleUrl: _sample);
      expect(withHk.pick?.host, 'cn-hk-eq-bcache-01.bilivideo.com');
      // 全场最快仍要在排名里（面板要显示对比，不改变测速本身）
      expect(withHk.ranked.first.host, 'upos-tf-all-hw.bilivideo.com');

      final noHk = hk.rank([
        _ok('upos-tf-all-hw.bilivideo.com', 90, parallel: 95),
        _ok('upos-sz-mirrorcos.bilivideo.com', 40),
      ], sampleUrl: _sample);
      expect(noHk.pick?.host, 'upos-tf-all-hw.bilivideo.com');
    });
  });

  group('瓶颈判定（Phase 0 的核心判别）', () {
    test('并发显著更快 → 单连接瓶颈', () {
      final r = _ok('upos-sz-mirrorhw.bilivideo.com', 4.0, parallel: 30.0);
      expect(r.gain, closeTo(7.5, 0.001));
      expect(r.verdict, contains('单连接瓶颈'));
    });

    test('并发也拉不起来 → 节点限速，建议降权', () {
      // 单连接 4.0、并发 5.5：gain 只有 1.4，且绝对值低 → 节点配额低，不是路径问题。
      final r = _ok('upos-tf-all-hw.bilivideo.com', 4.0, parallel: 5.5);
      expect(r.gain, closeTo(1.375, 0.001));
      expect(r.verdict, contains('节点限速'));
    });

    test('正常节点不报异常', () {
      final r = _ok('upos-sz-mirrorcos.bilivideo.com', 60, parallel: 70);
      expect(r.verdict, contains('正常'));
    });

    test('并发收益低但吞吐够高 → 不算限速（阈值是 10Mbps）', () {
      // 12/13：gain 1.08，但 13Mbps 已能喂 1080P 高码率，不该被降权。
      expect(
        _ok('upos-sz-mirrorcos.bilivideo.com', 12, parallel: 13).verdict,
        contains('正常'),
      );
      // 9/9.5：同样提不上去，但绝对值在阈值下方 → 限速。
      expect(
        _ok('upos-sz-mirrorcos.bilivideo.com', 9, parallel: 9.5).verdict,
        contains('节点限速'),
      );
      // 排序用 mbps = parallel ?? single：有并发值时以并发为准。
      expect(_ok('upos-sz-mirrorcos.bilivideo.com', 9, parallel: 9.5).mbps, 9.5);
      expect(_ok('upos-sz-mirrorcos.bilivideo.com', 9).mbps, 9);
    });

    test('只有单连接值时不给结论', () {
      expect(_ok('upos-sz-mirrorcos.bilivideo.com', 50).verdict, '仅单轮');
    });

    test('单流异常：并发极快但单连接几乎读不动（实测 1.3 vs 309.5）', () {
      final r = _ok(
        'upos-sz-mirroraliov.bilivideo.com',
        1.3,
        parallel: 309.5,
      );
      expect(r.gain, closeTo(238.1, 0.1));
      expect(r.verdict, contains('单流异常'));
      // 也不能被误判成"节点限速"
      expect(r.verdict, isNot(contains('节点限速')));
      // 排名仍按并发值走（它是快的）
      expect(r.mbps, 309.5);
    });
  });

  group('结果与报告的序列化', () {
    test('CdnProbeResult 往返（含 partial 与剔除原因）', () {
      const r = CdnProbeResult(
        name: 'cosov',
        host: 'upos-sz-mirrorcosov.bilivideo.com',
        region: CdnRegion.overseas,
        statusCode: 206,
        singleMbps: 12.5,
        parallelMbps: 41.25,
        singleTtfbMs: 180,
        bytes: 12 * 1024 * 1024,
        seconds: 3.4,
        connections: 8,
        partial: true,
      );
      final back = CdnProbeResult.fromJson(r.toJson());
      expect(back.host, r.host);
      expect(back.region, CdnRegion.overseas);
      expect(back.singleMbps, 12.5);
      expect(back.parallelMbps, 41.25);
      expect(back.connections, 8);
      expect(back.partial, isTrue);
      expect(back.failure, isNull);

      const bad = CdnProbeResult(
        name: 'akamai',
        host: 'upos-hz-mirrorakam.akamaized.net',
        region: CdnRegion.overseas,
        statusCode: 959,
        failure: CdnProbeFailure.rejected,
      );
      final badBack = CdnProbeResult.fromJson(bad.toJson());
      expect(badBack.failure, CdnProbeFailure.rejected);
      expect(badBack.statusCode, 959);
      expect(badBack.ok, isFalse);
    });

    test('report 往返保留排名顺序与 pick', () {
      final probe = CdnProbe();
      final report = probe.rank([
        _ok('upos-sz-mirrorcos.bilivideo.com', 30, parallel: 40),
        _ok('upos-sz-mirrorali.bilivideo.com', 80, parallel: 90),
      ], sampleUrl: _sample, videoKey: 'BV1SveU6GExV:42009365316:64');

      final back = decodeReport(encodeReport(report));
      expect(back.videoKey, 'BV1SveU6GExV:42009365316:64');
      expect(back.pick?.host, 'upos-sz-mirrorali.bilivideo.com');
      expect(back.ranked.map((e) => e.host).toList(), [
        'upos-sz-mirrorali.bilivideo.com',
        'upos-sz-mirrorcos.bilivideo.com',
      ]);
      expect(back.ranked.first.mbps, 90);
    });

    test('TTL 判定', () {
      final report = CdnProbeReport(
        testedAt: 1000,
        videoKey: 'k',
        results: const [],
      );
      expect(report.isFresh(1000 + 60 * 1000, 6 * 60 * 60 * 1000), isTrue);
      expect(report.isFresh(1000 + 7 * 60 * 60 * 1000, 6 * 60 * 60 * 1000), isFalse);
    });
  });

  group('WBI 签名用的 MD5', () {
    test('与 RFC 1321 测试向量一致', () {
      expect(md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(md5Hex('a'), '0cc175b9c0f1b6a831c399e269772661');
      expect(md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
      expect(
        md5Hex('message digest'),
        'f96b697d7cb7938d525a2f31aaf161d0',
      );
      expect(
        md5Hex('abcdefghijklmnopqrstuvwxyz'),
        'c3fcd3d76192e4007dfb496cca67e13b',
      );
      expect(
        md5Hex('123456789012345678901234567890123456789012345678901234567890'
            '12345678901234567890'),
        '57edf4a22be3c955ac49da2e2107b67a',
      );
    });
  });

  group('CdnProbeConfig 默认值', () {
    test('默认值与 CLI 说明一致：两轮总字节相等（4MiB = 8×512KiB）', () {
      const c = CdnProbeConfig();
      expect(c.singleBytes, 4 * 1024 * 1024);
      expect(c.parallelConnections, 8);
      expect(c.parallelBytesPerConn, 512 * 1024);
      // 这条断言是刻意的：两轮总量不等会让 gain 失真（实测踩过）。
      expect(
        c.parallelConnections * c.parallelBytesPerConn,
        c.singleBytes,
        reason: '并发轮总量必须等于单连接轮总量，否则 gain 会被请求长度污染',
      );
      expect(c.rankTtlMs, 6 * 60 * 60 * 1000);
      expect(c.hkFirst, isFalse);
    });

    test('移动档也是总量相等', () {
      const c = CdnProbeConfig.mobile;
      expect(c.parallelConnections * c.parallelBytesPerConn, c.singleBytes);
      expect(c.singleBytes, lessThan(const CdnProbeConfig().singleBytes));
    });
  });
}
