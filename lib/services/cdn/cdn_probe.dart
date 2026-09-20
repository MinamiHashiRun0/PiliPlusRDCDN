// CDN 探测核心：纯 dart:io，不依赖 Flutter。
//
// 这样它既能被 App 调用，也能被 `tool/cdn_probe.dart` 在桌面端 `dart run` 直接验证。
// 只 import 纯 Dart 的模型文件（cdn_type.dart 是无 Flutter 依赖的枚举）。
//
// 设计要点：
// - 探测样本必须是**当前视频自己的已签名 URL**（保留 path 与全部 query），只换 host。
//   已实测：换 host 后 CDN 仍返回 206；但**必须带 Range**——不带 Range 的普通 GET
//   会撞上 CDN 的怪异状态码（如 upos-tf-all-hw 对无 Range 的 HEAD 返回 959）。
// - 每个 host 测两轮：单连接（看节点给单流的配额）+ 多连接（看路径能否被并发吃满）。
//   两者比值就是判定依据：
//     单连接慢、多连接显著更快 → 瓶颈在单连接/路径，换节点无用，只能靠客户端并发
//     单连接慢、多连接也慢     → 节点对海外 IP 的配额低，应剔除/降权
// - 只有 Range 字节数达标（received >= wanted）才允许计入排名；被截断的样本会让
//   吞吐被高估。200 响应（服务端忽略 Range）按 want 截断后仍可用，但会标记 partial。
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';

/// 节点类别。只用于展示与「港优先」这类策略，不改变排名公式。
enum CdnRegion {
  /// 大陆镜像（upos-sz-mirror*/upos-tf-*）
  mainland,

  /// 港澳台/海外镜像（*ov、cn-hk-eq-*、Akamai）
  overseas,

  /// 国际版（*bstar1）
  bstar;

  /// 港澳台/海外类的主机：`upos-sz-mirrorcosov`（注意是 mirror 之后直接 **ov**，不是 `-ov.`）、
  /// `upos-sz-mirroraliov`、`cn-hk-eq-*`、Akamai。
  static final _overseasSuffix = RegExp(r'(ov|bstar\d*)\.bilivideo\.(com|cn|net)$');

  static CdnRegion of(String host) {
    if (host.contains('bstar')) return CdnRegion.bstar;
    if (host.startsWith('cn-hk-') ||
        host.contains('akamaized') ||
        _overseasSuffix.hasMatch(host)) {
      return CdnRegion.overseas;
    }
    return CdnRegion.mainland;
  }
}

/// 一个候选节点。host 为空表示 `baseUrl`/`backupUrl` 这类哨兵，不参与探测。
class CdnCandidate {
  CdnCandidate({
    required this.name,
    required this.host,
    required this.desc,
  }) : region = CdnRegion.of(host);

  final String name;
  final String host;
  final String desc;
  final CdnRegion region;

  static List<CdnCandidate> fromServices() => [
    for (final e in CDNService.values)
      if (e.host case final host?) CdnCandidate(name: e.name, host: host, desc: e.desc),
  ];

  static CdnCandidate? byName(String name) {
    for (final e in CDNService.values) {
      if (e.name != name) continue;
      final host = e.host;
      if (host != null) {
        return CdnCandidate(name: e.name, host: host, desc: e.desc);
      }
    }
    return null;
  }
}

/// 未通过测速的原因。
enum CdnProbeFailure {
  /// 403/404/959 一类：这个节点拿不到这个资源，或拒绝这个签名
  rejected,

  /// 连接/首字节超时
  timeout,

  /// 连接被重置、DNS 失败等
  network,

  /// 返回了 HTML 之类的东西（错误页）
  notMedia,

  /// 连上了但没读到足够字节（被截断/被限速到近乎停滞）
  tooSlow,
}

class CdnProbeResult {
  const CdnProbeResult({
    required this.name,
    required this.host,
    required this.region,
    this.statusCode,
    this.singleMbps,
    this.parallelMbps,
    this.singleTtfbMs,
    this.bytes,
    this.seconds,
    this.connections = 1,
    this.partial = false,
    this.failure,
  });

  final String name;
  final String host;
  final CdnRegion region;
  final int? statusCode;

  /// 单连接吞吐（Mbps）。null = 该轮没测成功。
  final double? singleMbps;

  /// 多连接聚合吞吐（Mbps）。
  final double? parallelMbps;

  final int? singleTtfbMs;
  final int? bytes;
  final double? seconds;
  final int connections;

  /// 服务端忽略了 Range，只拿到了部分字节：吞吐是下限，标记出来。
  final bool partial;
  final CdnProbeFailure? failure;

  bool get ok => failure == null && singleMbps != null;

  /// 并发收益倍数：>2 说明单连接吃不满路径，瓶颈在单流而不是节点。
  double? get gain {
    final single = singleMbps;
    final parallel = parallelMbps;
    if (single == null || parallel == null || single <= 0) return null;
    return parallel / single;
  }

  /// 排名用吞吐：优先并发值（更接近播放器多轨/多分片的实际情形），没有就用单连接。
  double? get mbps => parallelMbps ?? singleMbps;

  /// 判定文案，直接给人与 CLI 看。
  String get verdict {
    if (failure != null) {
      return switch (failure!) {
        CdnProbeFailure.rejected => '剔除（HTTP $statusCode）',
        CdnProbeFailure.timeout => '剔除（超时）',
        CdnProbeFailure.network => '剔除（连接失败）',
        CdnProbeFailure.notMedia => '剔除（非媒体响应）',
        CdnProbeFailure.tooSlow => '剔除（读不满字节）',
      };
    }
    final g = gain;
    if (g == null) return '仅单轮';
    // 单连接几乎读不动、并发却很快：不是"路径慢"，是单流被卡住/被限速（实测见过
    // 1.3Mbps 对 309Mbps，×238）。真实播放器冷启动、seek 时只有一两条连接在飞，
    // 这种节点会先卡一下，所以要点出来，而不是当成好节点。
    if (g >= _anomalyGain) {
      return '单流异常（单连接 ×${_f(g)}，但并发 ${_f(mbps ?? 0)}Mbps 正常）';
    }
    if (g >= 2.0) return '单连接瓶颈（并发 ×${_f(g)}，换节点无用）';
    // gain 低 + 绝对值低 = 这个节点给本机（尤其海外 IP）的配额就这么多，换路径也救不了。
    // 阈值取 10Mbps：4K 高码率单轨约 20-30Mbps，低于它的节点留着只会拖后腿。
    if ((mbps ?? 0) < _nodeThrottleMbps) return '节点限速（并发 ×${_f(g)}，建议降权）';
    return '正常（并发 ×${_f(g)}）';
  }

  /// 低于这个吞吐且并发也提不上去 → 判定为节点侧限速。
  static const double _nodeThrottleMbps = 10.0;

  /// gain 超过这个值就不是"路径需要并发"，而是单连接那次测量本身出了问题。
  static const double _anomalyGain = 10.0;

  Map<String, Object?> toJson() => {
    'name': name,
    'host': host,
    'region': region.name,
    'statusCode': statusCode,
    'singleMbps': singleMbps,
    'parallelMbps': parallelMbps,
    'singleTtfbMs': singleTtfbMs,
    'bytes': bytes,
    'seconds': seconds,
    'connections': connections,
    'partial': partial,
    'failure': failure?.name,
  };

  static CdnProbeResult fromJson(Map<String, Object?> json) {
    final failureName = json['failure'] as String?;
    final regionName = json['region'] as String?;
    return CdnProbeResult(
      name: json['name']! as String,
      host: json['host']! as String,
      region: CdnRegion.values.firstWhere(
        (e) => e.name == regionName,
        orElse: () => CdnRegion.of(json['host']! as String),
      ),
      statusCode: (json['statusCode'] as num?)?.toInt(),
      singleMbps: (json['singleMbps'] as num?)?.toDouble(),
      parallelMbps: (json['parallelMbps'] as num?)?.toDouble(),
      singleTtfbMs: (json['singleTtfbMs'] as num?)?.toInt(),
      bytes: (json['bytes'] as num?)?.toInt(),
      seconds: (json['seconds'] as num?)?.toDouble(),
      connections: (json['connections'] as num?)?.toInt() ?? 1,
      partial: json['partial'] == true,
      failure: failureName == null
          ? null
          : CdnProbeFailure.values.firstWhere(
              (e) => e.name == failureName,
              orElse: () => CdnProbeFailure.network,
            ),
    );
  }
}

/// 一次完整测速的落盘结构（App 侧写 Hive 的就是这个）。
class CdnProbeReport {
  CdnProbeReport({
    required this.testedAt,
    required this.videoKey,
    required this.results,
    this.ranked = const [],
    this.pick,
    this.note,
  });

  final int testedAt;
  final String videoKey;
  final List<CdnProbeResult> results;

  /// 通过探测的 host，按吞吐降序。
  final List<CdnProbeResult> ranked;

  /// 最终目标（可为 null = 都不行，回落原地址）。
  final CdnProbeResult? pick;
  final String? note;

  bool isFresh(int now, int ttlMs) => now - testedAt < ttlMs;

  Map<String, Object?> toJson() => {
    'testedAt': testedAt,
    'videoKey': videoKey,
    'results': [for (final e in results) e.toJson()],
    'ranked': [for (final e in ranked) e.host],
    'pick': pick?.host,
    'note': note,
  };

  static CdnProbeReport fromJson(Map<String, Object?> json) {
    final results = [
      for (final e in (json['results'] as List? ?? const []))
        CdnProbeResult.fromJson((e as Map).cast<String, Object?>()),
    ];
    final byHost = {for (final e in results) e.host: e};
    return CdnProbeReport(
      testedAt: (json['testedAt'] as num?)?.toInt() ?? 0,
      videoKey: json['videoKey'] as String? ?? '',
      results: results,
      ranked: [
        for (final h in (json['ranked'] as List? ?? const [])) ?byHost[h],
      ],
      pick: byHost[json['pick']],
      note: json['note'] as String?,
    );
  }
}

class CdnProbeConfig {
  const CdnProbeConfig({
    this.singleBytes = 4 * 1024 * 1024,
    this.parallelConnections = 8,
    this.parallelBytesPerConn = 512 * 1024,
    this.connectTimeout = const Duration(seconds: 6),
    this.readTimeout = const Duration(seconds: 15),
    this.minBytesRatio = 0.98,
    this.rankTtlMs = 6 * 60 * 60 * 1000,
    this.skipParallelWhenSingleBelowMbps = 1.0,
    this.hkFirst = false,
  });

  /// 移动端/移动网络用的小额档：每节点约 (2MiB 单连接 + 4×512KiB 并发) = 4MiB。
  static const mobile = CdnProbeConfig(
    singleBytes: 2 * 1024 * 1024,
    parallelConnections: 4,
    parallelBytesPerConn: 512 * 1024,
    readTimeout: Duration(seconds: 12),
  );

  /// 单连接一轮的目标字节数。
  final int singleBytes;

  /// 并发轮的连接数。
  final int parallelConnections;

  /// 并发轮每条连接的目标字节数。
  ///
  /// **总字节应与 [singleBytes] 相等**（默认 4MiB = 8×512KiB），否则 gain 比较不公平：
  /// 实测踩过这个坑——单连接跑 4MiB、并发跑 8×1MiB 时，短请求的启动成本与 TCP 爬升
  /// 让并发轮吞吐被低估（一个 183Mbps 的节点在 8×1MiB 下只量到 118Mbps，算出 gain 0.6）。
  /// [CdnProbe] 的构造函数里有断言，CLI 也会把两轮总量印出来。
  final int parallelBytesPerConn;

  final Duration connectTimeout;
  final Duration readTimeout;

  /// 实收/应收 达到这个比例才认为样本完整。
  final double minBytesRatio;

  /// 排名有效期（默认 6 小时，与 Surge 版一致）。
  final int rankTtlMs;

  /// 单连接低于这个值就跳过并发轮（太差的节点不值得再花流量）。
  final double skipParallelWhenSingleBelowMbps;

  /// 排名时优先取第一个港澳台/海外节点（对海外用户通常更近）。
  final bool hkFirst;
}

/// 单机吞吐探测。
class CdnProbe {
  CdnProbe({this.config = const CdnProbeConfig()});

  final CdnProbeConfig config;

  /// 探测一个 host。失败不抛异常，统一落在 [CdnProbeResult.failure]。
  ///
  /// [withParallel] 为 false 时只跑单连接那一轮（CLI 的 `--no-parallel` 用它省流量）。
  Future<CdnProbeResult> measure(
    CdnCandidate candidate, {
    required String sampleUrl,
    bool withParallel = true,
  }) async {
    final probeUrl = buildProbeUrl(sampleUrl, candidate.host);
    if (probeUrl == null) {
      return CdnProbeResult(
        name: candidate.name,
        host: candidate.host,
        region: candidate.region,
        failure: CdnProbeFailure.notMedia,
      );
    }

    final single = await _measure(
      probeUrl,
      connections: 1,
      bytesPerConn: config.singleBytes,
    );

    if (single.failure != null) {
      return CdnProbeResult(
        name: candidate.name,
        host: candidate.host,
        region: candidate.region,
        statusCode: single.statusCode,
        failure: single.failure,
      );
    }

    _ProbeSample? parallel;
    if (withParallel &&
        (single.mbps ?? 0) >= config.skipParallelWhenSingleBelowMbps) {
      parallel = await _measure(
        probeUrl,
        connections: config.parallelConnections,
        bytesPerConn: config.parallelBytesPerConn,
      );
    }

    return CdnProbeResult(
      name: candidate.name,
      host: candidate.host,
      region: candidate.region,
      statusCode: single.statusCode,
      singleMbps: single.mbps,
      singleTtfbMs: single.ttfbMs,
      bytes: (single.bytes ?? 0) + (parallel?.bytes ?? 0),
      seconds: (single.seconds ?? 0) + (parallel?.seconds ?? 0),
      connections: parallel == null ? 1 : config.parallelConnections,
      partial: single.partial || (parallel?.partial ?? false),
      parallelMbps: parallel?.failure == null ? parallel?.mbps : null,
    );
  }

  /// 依次探测多个 host；[onResult] 用于边测边刷 UI / 边打印。
  Future<List<CdnProbeResult>> measureAll(
    List<CdnCandidate> candidates, {
    required String sampleUrl,
    void Function(CdnProbeResult result)? onResult,
    bool Function()? shouldStop,
  }) async {
    final out = <CdnProbeResult>[];
    for (final candidate in candidates) {
      if (shouldStop?.call() ?? false) break;
      final result = await measure(candidate, sampleUrl: sampleUrl);
      out.add(result);
      onResult?.call(result);
    }
    return out;
  }

  /// 排序 + 选目标。规则刻意保持简单可解释：
  /// 1. 未被剔除的、吞吐达标的进排名
  /// 2. 吞吐优先，同速看延迟
  /// 3. hkFirst 时先取第一个港澳台/海外节点（没有就回落全场第一）
  CdnProbeReport rank(
    List<CdnProbeResult> results, {
    required String sampleUrl,
    String? videoKey,
    String? noPickNote,
  }) {
    final usable = [
      for (final e in results)
        if (e.ok && (e.mbps ?? 0) > 0) e,
    ]..sort((a, b) {
      final bySpeed = (b.mbps ?? 0).compareTo(a.mbps ?? 0);
      if (bySpeed != 0) return bySpeed;
      return (a.singleTtfbMs ?? 1 << 30).compareTo(b.singleTtfbMs ?? 1 << 30);
    });

    CdnProbeResult? pick = usable.isEmpty ? null : usable.first;
    if (config.hkFirst) {
      for (final e in usable) {
        if (e.region == CdnRegion.overseas) {
          pick = e;
          break;
        }
      }
    }

    return CdnProbeReport(
      testedAt: DateTime.now().millisecondsSinceEpoch,
      videoKey: videoKey ?? sampleUrl,
      results: results,
      ranked: usable,
      pick: pick,
      note: pick == null ? (noPickNote ?? '全部候选未通过，回落原地址') : null,
    );
  }

  /// 换 host、保留签名与其余 query。签名与 host 无关已实测确认。
  static String? buildProbeUrl(String sampleUrl, String newHost) {
    final uri = Uri.tryParse(sampleUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    // 手工重建而不是 uri.replace(port: 0)：端口必须**消失**，不能把样本的
    // :8082/:4483 带到新 host 上（那些端口是 MCDN/PCDN 专用的）。
    return Uri(
      scheme: uri.scheme,
      host: newHost,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  Future<_ProbeSample> _measure(
    String url, {
    required int connections,
    required int bytesPerConn,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = config.connectTimeout
      // 允许真正的并发：不设上限会被默认值挡住。
      ..maxConnectionsPerHost = connections < 4 ? 4 : connections + 2
      ..userAgent = _userAgent;
    final sw = Stopwatch()..start();
    var received = 0;
    var wanted = 0;
    int? statusCode;
    int? ttfbMs;
    var partial = false;
    CdnProbeFailure? failure;

    try {
      final tasks = <Future<_OneShot>>[];
      for (var i = 0; i < connections; i++) {
        final start = i * bytesPerConn;
        final end = start + bytesPerConn - 1;
        wanted += bytesPerConn;
        tasks.add(_one(client, url, start, end));
      }
      final shots = await Future.wait(tasks);
      for (final shot in shots) {
        // 单条失败不整轮作废：能拿到的字节照算，整轮标 partial（吞吐是下限）。
        statusCode ??= shot.statusCode;
        ttfbMs ??= shot.ttfbMs;
        if (shot.failure != null) {
          failure ??= shot.failure;
          partial = true;
          continue;
        }
        received += shot.bytes;
        partial |= shot.partial;
      }
    } catch (e) {
      failure ??= _classify(e);
    } finally {
      client.close(force: true);
    }

    sw.stop();

    if (failure == null && received < wanted * config.minBytesRatio) {
      // 连上了但没读满：要么被截断，要么被限速到停滞。
      if (received == 0) {
        failure = CdnProbeFailure.tooSlow;
      } else {
        partial = true;
      }
    }

    final seconds = sw.elapsedMicroseconds / Duration.microsecondsPerSecond;
    final mbps = received == 0
        ? null
        : received * 8 / 1000000 / (seconds <= 0 ? 0.001 : seconds);

    return _ProbeSample(
      statusCode: statusCode,
      mbps: failure == null ? mbps : null,
      ttfbMs: ttfbMs,
      bytes: received,
      seconds: seconds,
      partial: partial,
      failure: failure,
    );
  }

  Future<_OneShot> _one(
    HttpClient client,
    String url,
    int start,
    int end,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end')
        ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com/')
        ..set('Origin', 'https://www.bilibili.com');
      final response = await request.close().timeout(config.readTimeout);
      final code = response.statusCode;

      if (code != HttpStatus.ok && code != HttpStatus.partialContent) {
        await response.drain<void>().catchError((_) {});
        return _OneShot(
          statusCode: code,
          bytes: 0,
          ttfbMs: sw.elapsedMilliseconds,
          failure: _classifyStatus(code),
        );
      }

      final ttfb = sw.elapsedMilliseconds;
      final headType = response.headers.contentType?.mimeType ?? '';
      if (headType.contains('text/html')) {
        await response.drain<void>().catchError((_) {});
        return _OneShot(
          statusCode: code,
          bytes: 0,
          ttfbMs: ttfb,
          failure: CdnProbeFailure.notMedia,
        );
      }

      final want = end - start + 1;
      var got = 0;
      var reached = false;
      await for (final chunk in response.timeout(config.readTimeout)) {
        got += chunk.length;
        if (got >= want) {
          reached = true;
          break;
        }
      }
      sw.stop();
      // 200 = 服务端忽略了 Range，给的是整段；206 但没读满 = 这一段比请求的短。
      // 两种情况都只按实际拿到的字节算，并且标记 partial（吞吐是下限）。
      return _OneShot(
        statusCode: code,
        bytes: got < want ? got : want,
        ttfbMs: ttfb,
        partial: code == HttpStatus.ok || !reached,
      );
    } on TimeoutException {
      return _OneShot(
        statusCode: null,
        bytes: 0,
        ttfbMs: sw.elapsedMilliseconds,
        failure: CdnProbeFailure.timeout,
      );
    } catch (e) {
      return _OneShot(
        statusCode: null,
        bytes: 0,
        ttfbMs: sw.elapsedMilliseconds,
        failure: _classify(e),
      );
    }
  }

  /// 非 200/206 一律算这个节点拿不到资源。403/404/410/416 与 959（B 站 CDN 自家码）
  /// 是明确的「拒绝」，其余（含 5xx）按拒绝处理，但状态码会原样带出去给人看。
  static CdnProbeFailure _classifyStatus(int code) => CdnProbeFailure.rejected;

  static CdnProbeFailure _classify(Object e) {
    if (e is TimeoutException) return CdnProbeFailure.timeout;
    return CdnProbeFailure.network;
  }

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
}

class _ProbeSample {
  const _ProbeSample({
    this.statusCode,
    this.mbps,
    this.ttfbMs,
    this.bytes,
    this.seconds,
    this.partial = false,
    this.failure,
  });

  final int? statusCode;
  final double? mbps;
  final int? ttfbMs;
  final int? bytes;
  final double? seconds;
  final bool partial;
  final CdnProbeFailure? failure;
}

class _OneShot {
  const _OneShot({
    required this.statusCode,
    required this.bytes,
    required this.ttfbMs,
    this.partial = false,
    this.failure,
  });

  final int? statusCode;
  final int bytes;
  final int ttfbMs;
  final bool partial;
  final CdnProbeFailure? failure;
}

String _f(double v) => v.toStringAsFixed(1);

/// 给 CLI 与 App 共用的 JSON 编解码（App 侧写 Hive 的是字符串）。
String encodeReport(CdnProbeReport report) => jsonEncode(report.toJson());

CdnProbeReport decodeReport(String raw) =>
    CdnProbeReport.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
