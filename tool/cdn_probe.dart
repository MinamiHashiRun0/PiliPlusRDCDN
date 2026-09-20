// 本地 CDN 探测 CLI：不依赖 Flutter，直接 `dart run tool/cdn_probe.dart`。
//
// 为什么要有它：CdnProbe 是纯 dart:io 的，所以「你所在网络下这 21 个 B 站节点分别多快」
// 这件事在电脑上就能量出来，不必先出 iOS 包。CLI 与 App 走的是同一套探测/排序代码，
// 所以这里看到的结论对手机端成立（差异只在出口网络本身）。
//
// 两种样本来源：
//   1. 自带引导（默认）：请求 playurl 拿真实签名，WBI 签名在本地算
//        dart run tool/cdn_probe.dart --popular          # 直接抓热门榜第一条
//        dart run tool/cdn_probe.dart --bv BV1xx --cid 123
//   2. 你贴一条已签名的分片地址（浏览器 F12 / App 日志里都有），最省事、也最贴近手机
//        dart run tool/cdn_probe.dart --sample "https://upos-.../upgcxcode/...?e=...&u=..."
//
// 常用参数：
//   --connections 8      并发轮连接数
//   --single-bytes 4194304 / --parallel-bytes 1048576
//   --hosts ali,cos,hk_bcache     只测指定节点（默认全测）
//   --region overseas|mainland|bstar|all
//   --hk-first           排名优先取港澳台/海外节点
//   --json report.json   落盘完整报告
//   --no-parallel        只测单连接（省流量，只看节点配额）
//   --timeout 15         读超时（秒）
//
// 流量成本按默认值估算：每节点 (1×4MiB 单连接) + (8×512KiB 并发) = 8MiB，21 个节点约 168MiB。
// 只想先摸底就用 `--no-parallel --single-bytes 1048576 --region overseas`。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/services/cdn/cdn_probe.dart';
import 'package:PiliPlus/utils/wbi.dart' as wbi;

const _playUrlApi = 'https://api.bilibili.com/x/player/playurl';
const _popularApi = 'https://api.bilibili.com/x/web-interface/popular';
const _navApi = 'https://api.bilibili.com/x/web-interface/nav';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  if (opts.help) {
    stdout.writeln(_usage);
    return;
  }

  final candidates = _candidates(opts);
  if (candidates.isEmpty) {
    stderr.writeln('没有匹配的候选节点，检查 --hosts / --region');
    exitCode = 2;
    return;
  }

  stdout
    ..writeln('== B 站 CDN 探测 ==')
    ..writeln(
      '候选 ${candidates.length} 个 · 单连接 ${_mb(opts.singleBytes)}'
      '${opts.parallel ? ' · 并发 ${opts.connections}×${_mb(opts.parallelBytes)}' : ' · 不测并发'}'
      ' · 读超时 ${opts.readTimeout.inSeconds}s',
    );

  // gain = 并发/单连接 只有在两轮总字节相同时才有意义，否则短请求的启动成本会污染结果。
  if (opts.parallel) {
    final singleTotal = opts.singleBytes;
    final parallelTotal = opts.connections * opts.parallelBytes;
    if (singleTotal != parallelTotal) {
      stdout.writeln(
        '  ⚠ 单连接 ${_mb(singleTotal)} ≠ 并发总量 ${_mb(parallelTotal)}：'
        'gain 会被请求长度差异污染，建议让两者相等'
        '（如 --single-bytes ${opts.connections * opts.parallelBytes}）',
      );
    }
  }

  final String sampleUrl;
  if (opts.sample != null) {
    sampleUrl = opts.sample!;
    stdout.writeln('样本：命令行给定');
  } else {
    try {
      sampleUrl = await _bootstrapSample(opts);
    } catch (e) {
      stderr
        ..writeln('取样本失败：$e')
        ..writeln('可以改用 --sample "<已签名分片URL>"');
      exitCode = 1;
      return;
    }
  }
  final sampleHost = Uri.parse(sampleUrl).host;
  stdout
    ..writeln('样本 host：$sampleHost')
    ..writeln(
      '样本路径：${Uri.parse(sampleUrl).path}'
      '（签名 query 已保留，共 ${Uri.parse(sampleUrl).query.length} 字符）',
    )
    ..writeln('');

  final config = CdnProbeConfig(
    singleBytes: opts.singleBytes,
    parallelConnections: opts.connections,
    parallelBytesPerConn: opts.parallelBytes,
    readTimeout: opts.readTimeout,
    hkFirst: opts.hkFirst,
  );
  final probe = CdnProbe(config: config);

  final results = <CdnProbeResult>[];
  final sw = Stopwatch()..start();
  for (final candidate in candidates) {
    stdout.write(
      '  ${candidate.name.padRight(12)} ${candidate.region.name.padRight(9)} ',
    );
    await stdout.flush();
    final result = opts.parallel
        ? await probe.measure(candidate, sampleUrl: sampleUrl)
        : await _measureSingleOnly(probe, candidate, sampleUrl);
    results.add(result);
    stdout.writeln(_line(result));
  }
  sw.stop();

  final report = probe.rank(
    results,
    sampleUrl: sampleUrl,
    videoKey: opts.videoKey ?? sampleUrl,
  );

  stdout
    ..writeln('')
    ..writeln('== 排名（吞吐优先，同速看延迟）==');
  if (report.ranked.isEmpty) {
    stdout.writeln('  全部候选未通过：${report.note}');
  } else {
    for (var i = 0; i < report.ranked.length; i++) {
      final r = report.ranked[i];
      stdout.writeln(
        '  ${(i + 1).toString().padLeft(2)}. ${r.host.padRight(38)} '
        '${_mbps(r.mbps)}  ${r.region.name}${r.partial ? '  (partial)' : ''}',
      );
    }
  }
  if (report.pick != null) {
    stdout
      ..writeln('')
      ..writeln(
        '目标：${report.pick!.host}${config.hkFirst ? '（hk-first）' : ''}',
      );
    final full = report.ranked.first;
    if (full.host != report.pick!.host) {
      stdout.writeln('全场最快：${full.host} ${_mbps(full.mbps)}');
    }
  }

  _printDiagnosis(results);

  if (opts.jsonPath != null) {
    final file = File(opts.jsonPath!);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
    );
    stdout
      ..writeln('')
      ..writeln('报告已写入 ${file.path}');
  }

  stdout
    ..writeln('')
    ..writeln('用时 ${sw.elapsed.inSeconds}s');
}

/// `--no-parallel` 时只跑单连接那一轮，省流量。
Future<CdnProbeResult> _measureSingleOnly(
  CdnProbe probe,
  CdnCandidate candidate,
  String sampleUrl,
) => probe.measure(candidate, sampleUrl: sampleUrl, withParallel: false);

void _printDiagnosis(List<CdnProbeResult> results) {
  final pathBound = <CdnProbeResult>[];
  final nodeBound = <CdnProbeResult>[];
  final anomalous = <CdnProbeResult>[];
  for (final r in results) {
    final gain = r.gain;
    if (gain == null) continue;
    if (gain >= 10.0) {
      // 与 CdnProbeResult.verdict 的 _anomalyGain 对应：单连接那次测量本身有问题
      anomalous.add(r);
    } else if (gain >= 2.0) {
      pathBound.add(r);
    } else if ((r.mbps ?? 0) < 10.0) {
      // 与 CdnProbeResult.verdict 的 _nodeThrottleMbps 对应
      nodeBound.add(r);
    }
  }

  stdout
    ..writeln('')
    ..writeln('== 瓶颈判定 ==');
  if (pathBound.isEmpty && nodeBound.isEmpty && anomalous.isEmpty) {
    stdout.writeln('  没有明显异常：单连接基本能吃满，选节点即可。');
    return;
  }
  if (nodeBound.isNotEmpty) {
    stdout.writeln('  节点限速（并发也拉不起来，换节点不如剔除它们）：');
    for (final r in nodeBound) {
      stdout.writeln('    ${r.host.padRight(38)} ${_mbps(r.mbps)} 并发×${_f(r.gain)}');
    }
  }
  if (pathBound.isNotEmpty) {
    stdout.writeln('  单连接瓶颈（并发显著更快 → 换节点无用，只有客户端并发能救）：');
    for (final r in pathBound) {
      stdout.writeln('    ${r.host.padRight(38)} ${_mbps(r.mbps)} 并发×${_f(r.gain)}');
    }
  }
  if (anomalous.isNotEmpty) {
    stdout.writeln('  单流异常（并发很快但单连接几乎读不动 → 冷启动/seek 会先卡）：');
    for (final r in anomalous) {
      stdout.writeln(
        '    ${r.host.padRight(38)} 单 ${_mbps(r.singleMbps)} / 并发 ${_mbps(r.parallelMbps)}'
        '  ×${_f(r.gain)}',
      );
    }
  }
}

String _line(CdnProbeResult r) {
  if (r.failure != null) {
    return '${r.verdict}${r.statusCode == null ? '' : ' HTTP ${r.statusCode}'}';
  }
  final buf = StringBuffer()
    ..write(_mbps(r.singleMbps).padLeft(9))
    ..write('  ttfb ')
    ..write('${r.singleTtfbMs ?? '-'}ms'.padLeft(7));
  if (r.parallelMbps != null) {
    buf
      ..write('  并发 ')
      ..write(_mbps(r.parallelMbps))
      ..write('  ×${_f(r.gain)}');
  }
  return buf.toString();
}

// ---------------------------------------------------------------- 取样本

Future<String> _bootstrapSample(_Options opts) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = _ua;

  try {
    var bvid = opts.bvid;
    var cid = opts.cid;
    if (bvid == null || cid == null) {
      final popular = await _getJson(client, Uri.parse('$_popularApi?ps=3&pn=1'));
      final list = ((popular['data'] as Map)['list'] as List).cast<Map>();
      final first = list[Random().nextInt(list.length)];
      // ??= 之后分析器就知道 bvid 不是 null 了（--bv 没给时这里一定会赋值）。
      bvid ??= first['bvid'] as String;
      cid ??= (first['cid'] as num?)?.toInt();
      stdout.writeln('热门榜取样：${first['title']}  ($bvid / $cid)');
    }
    if (cid == null) {
      final view = await _getJson(
        client,
        Uri.parse('https://api.bilibili.com/x/web-interface/view?bvid=$bvid'),
      );
      cid = (((view['data'] as Map)['pages'] as List).first as Map)['cid'] as int;
    }

    final nav = await _getJson(client, Uri.parse(_navApi));
    final wbiInfo = (nav['data'] as Map?)?['wbi_img'] as Map?;
    final params = <String, String>{
      'bvid': bvid,
      'cid': '$cid',
      'qn': '${opts.qn}',
      'fnval': '4048',
      'fnver': '0',
      'fourk': '1',
    };
    final query = wbiInfo == null
        ? wbi.encodeQuery(params)
        : wbi.encodeQuery(
            wbi.wbiSign(
              params,
              imgUrl: wbiInfo['img_url'] as String,
              subUrl: wbiInfo['sub_url'] as String,
            ),
          );

    final play = await _getJson(
      client,
      Uri.parse('$_playUrlApi?$query'),
      referer: 'https://www.bilibili.com/video/$bvid',
    );
    if (play['code'] != 0) {
      throw 'playurl code=${play['code']} msg=${play['message']}';
    }
    final dash = (play['data'] as Map)['dash'] as Map?;
    final videos = (dash?['video'] as List?)?.cast<Map>();
    if (videos == null || videos.isEmpty) throw '没有 dash 流（可能需要登录）';
    final wantQn = opts.qn;
    final video = videos.firstWhere(
      (e) => (e['id'] as num?)?.toInt() == wantQn,
      orElse: () => videos.first,
    );
    final urls = [
      video['baseUrl'] as String?,
      ...((video['backupUrl'] as List?)?.cast<String>() ?? const <String>[]),
    ].whereType<String>().toList();
    if (urls.isEmpty) throw 'playurl 里没有 baseUrl';
    return urls.first;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _getJson(
  HttpClient client,
  Uri uri, {
  String? referer,
}) async {
  final request = await client.getUrl(uri);
  request.headers
    ..set(HttpHeaders.refererHeader, referer ?? 'https://www.bilibili.com/')
    ..set(HttpHeaders.acceptHeader, 'application/json');  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw 'HTTP ${response.statusCode}: ${body.length > 200 ? '${body.substring(0, 200)}…' : body}';
  }
  return (jsonDecode(body) as Map).cast<String, dynamic>();
}

// ---------------------------------------------------------------- 参数

List<CdnCandidate> _candidates(_Options opts) {
  var all = CdnCandidate.fromServices();
  if (opts.hosts != null) {
    final wanted = opts.hosts!.split(',').map((e) => e.trim()).toSet();
    all = [
      for (final e in CDNService.values)
        if (e.host case final host? when wanted.contains(e.name))
          CdnCandidate(name: e.name, host: host, desc: e.desc),
    ];
  }
  if (opts.region != null && opts.region != 'all') {
    all = [
      for (final e in all)
        if (e.region.name == opts.region) e,
    ];
  }
  return all;
}

class _Options {
  _Options({
    required this.help,
    this.sample,
    this.bvid,
    this.cid,
    this.qn = 64,
    this.connections = 8,
    this.singleBytes = 4 * 1024 * 1024,
    // 默认让两轮总字节相等（4MiB = 8×512KiB），gain 才有可比性。
    this.parallelBytes = 512 * 1024,
    this.readTimeout = const Duration(seconds: 15),
    this.hosts,
    this.region,
    this.hkFirst = false,
    this.jsonPath,
    this.videoKey,
    this.parallel = true,
  });

  final bool help;
  final String? sample;
  final String? bvid;
  final int? cid;
  final int qn;
  final int connections;
  final int singleBytes;
  final int parallelBytes;
  final Duration readTimeout;
  final String? hosts;
  final String? region;
  final bool hkFirst;
  final String? jsonPath;
  final String? videoKey;
  final bool parallel;

  static _Options parse(List<String> args) {
    String? arg(String name) {
      final i = args.indexOf('--$name');
      if (i == -1 || i + 1 >= args.length) return null;
      return args[i + 1];
    }

    bool flag(String name) => args.contains('--$name');
    int? intArg(String name) => switch (arg(name)) {
      final v? => int.tryParse(v),
      _ => null,
    };

    return _Options(
      help: flag('help') || flag('h'),
      sample: arg('sample'),
      bvid: arg('bv') ?? arg('bvid'),
      cid: intArg('cid'),
      qn: intArg('qn') ?? 64,
      connections: intArg('connections') ?? 8,
      singleBytes: intArg('single-bytes') ?? 4 * 1024 * 1024,
      parallelBytes: intArg('parallel-bytes') ?? 512 * 1024,
      readTimeout: Duration(seconds: intArg('timeout') ?? 15),
      hosts: arg('hosts'),
      region: arg('region'),
      hkFirst: flag('hk-first'),
      jsonPath: arg('json'),
      videoKey: arg('video-key'),
      parallel: !flag('no-parallel'),
    );
  }
}

String _mbps(double? v) => v == null ? '-' : '${v.toStringAsFixed(1)} Mbps';
String _f(double? v) => v == null ? '-' : v.toStringAsFixed(1);
String _mb(int bytes) =>
    bytes >= 1024 * 1024 ? '${bytes ~/ (1024 * 1024)}MB' : '${bytes ~/ 1024}KB';

const _usage = '''
B 站 CDN 探测（纯 Dart，无需 Flutter）

  dart run tool/cdn_probe.dart [选项]

样本来源（二选一）
  --popular                     抓热门榜随机一条视频的签名地址
  --bv BV1xx --cid 123456       指定视频（只给 --bv 会自动取第一 P 的 cid）
  --sample "<已签名分片URL>"     直接给地址：最贴近手机实际，也最省事

测什么
  --connections 8               并发轮连接数（默认 8）
  --single-bytes 4194304        单连接轮目标字节
  --parallel-bytes 524288       并发轮每条连接字节
                                （默认 4MiB = 8×512KiB，两轮总字节相等，gain 才可比）
  --no-parallel                 只测单连接（省流量）
  --qn 64                       清晰度（64=720P，80=1080P，112=1080P+）
  --timeout 15                  读超时（秒）

测哪些
  --region overseas|mainland|bstar|all
  --hosts ali,cos,hk_bcache     只测指定节点名（见 lib/models/common/video/cdn_type.dart）
  --hk-first                    排名优先取港澳台/海外节点

输出
  --json report.json            落盘完整报告（含每个节点的单连接/并发/判定）
  --video-key <key>             报告里记的视频标识，便于 App 侧复用

默认每节点流量 = 1×4MiB + 8×512KiB = 8MiB（两轮总字节相等）。第一次摸底建议：
  dart run tool/cdn_probe.dart --popular --region overseas --no-parallel --single-bytes 1048576
''';
