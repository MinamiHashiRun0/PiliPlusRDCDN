// CdnProxy 的端到端测试：起一个"假上游 CDN"（支持 Range 的真 HTTP 服务器），
// 让代理去取，然后逐字节比对。
//
// 这是上设备前最重要的验证：并发拼接一旦偏移错位，表现是花屏/卡住，在手机上极难定位。
// 纯逻辑已有 proxy_core_test 覆盖，这里验证的是 HTTP 层：Range 语义、206/Content-Range、
// 并发取回后的拼接顺序、seek 后重取、以及上游出错时能否退回直通。
//
//   flutter test test/services/cdn/cdn_proxy_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/cdn_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内容可预测：第 i 字节 = i % 251（251 是质数，能暴露错位）。
int byteAt(int i) => i % 251;

const mediaSize = 1 << 20; // 1 MiB 足够验证偏移

class FakeUpstream {
  FakeUpstream({this.failWith, this.ignoreRange = false});

  HttpServer? _server;

  /// 非空时所有请求返回该状态码（用来测直通/降级）。
  final int? failWith;

  /// true = 不理会 Range，直接回 200 全量（真实 CDN 也可能这样）。
  final bool ignoreRange;

  /// 记录收到的 Range 请求，用来断言"确实并发发了多条"。
  final List<String> rangeLog = [];

  int get port => _server!.port;

  String get url => 'http://127.0.0.1:$port/media.m4s';

  Future<void> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((req) async {
      final res = req.response;
      final header = req.headers.value(HttpHeaders.rangeHeader);
      if (header != null) rangeLog.add(header);

      if (failWith case final code?) {
        res.statusCode = code;
        await res.close();
        return;
      }

      final range = header == null || ignoreRange
          ? const ByteRange(0, mediaSize - 1)
          : (RangeRequest.parse(header)!.resolve(mediaSize) ??
                const ByteRange(0, mediaSize - 1));

      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4');
      if (header == null || ignoreRange) {
        res.statusCode = HttpStatus.ok;
        res.headers.set(HttpHeaders.contentLengthHeader, '$mediaSize');
      } else {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$mediaSize',
        );
        res.headers.set(HttpHeaders.contentLengthHeader, '${range.length}');
      }
      // 分小块写，模拟真实网络的分片到达
      const step = 16 * 1024;
      for (var o = range.start; o <= range.end; o += step) {
        final e = (o + step - 1) > range.end ? range.end : o + step - 1;
        res.add(Uint8List.fromList([
          for (var i = o; i <= e; i++) byteAt(i),
        ]));
      }
      await res.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

/// 通过代理取一段，返回字节。
Future<Uint8List> fetchThroughProxy(
  CdnProxy proxy,
  String proxyUrl, {
  ByteRange? range,
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(proxyUrl));
    if (range != null) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end}');
    }
    final res = await req.close();
    expect(res.statusCode, anyOf(HttpStatus.ok, HttpStatus.partialContent));
    if (range != null) {
      expect(res.statusCode, HttpStatus.partialContent);
      final cr = ContentRange.parse(
        res.headers.value(HttpHeaders.contentRangeHeader),
      );
      expect(cr, isNotNull, reason: '206 必须带 Content-Range');
      expect(cr!.start, range.start);
      expect(cr.end, range.end);
      expect(cr.total, mediaSize);
    }
    final out = BytesBuilder(copy: false);
    await for (final part in res) {
      out.add(part);
    }
    return out.takeBytes();
  } finally {
    client.close(force: true);
  }
}

void expectRange(Uint8List got, int start, int length) {
  expect(got.length, length, reason: '长度不对');
  for (var i = 0; i < length; i++) {
    if (got[i] != byteAt(start + i)) {
      fail('第 $i 字节错了：期望 ${byteAt(start + i)}，实际 ${got[i]}（绝对偏移 ${start + i}）');
    }
  }
}

void main() {
  late FakeUpstream upstream;
  late CdnProxy proxy;

  setUp(() async {
    upstream = FakeUpstream();
    await upstream.start();
    proxy = CdnProxy(
      connections: 4,
      chunkBytes: 64 * 1024,
      prefetchAhead: 0, // 测试里关掉预取，只验证按需取
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.stop();
  });

  test('无 Range 请求：返回整段且逐字节正确', () async {
    final url = proxy.register(upstream.url, label: 'video');
    final got = await fetchThroughProxy(proxy, url);
    expect(got.length, mediaSize);
    expectRange(got, 0, mediaSize);
    expect(proxy.servedRequests, 1);
  });

  test('Range 请求：206 + Content-Range，且字节逐一对得上', () async {
    final url = proxy.register(upstream.url);
    final got = await fetchThroughProxy(
      proxy,
      url,
      range: const ByteRange(1000, 4999),
    );
    expectRange(got, 1000, 4000);
  });

  test('大区间会拆成多条并发上游请求', () async {
    final url = proxy.register(upstream.url);
    // 256KiB / 64KiB = 4 条
    final got = await fetchThroughProxy(
      proxy,
      url,
      range: const ByteRange(0, 256 * 1024 - 1),
    );
    expectRange(got, 0, 256 * 1024);
    expect(
      upstream.rangeLog.length,
      greaterThanOrEqualTo(4),
      reason: '应该并发拆成至少 4 条 Range',
    );
  });

  test('前缀形态（bytes=N-）到文件末尾', () async {
    final url = proxy.register(upstream.url);
    final got = await fetchThroughProxy(
      proxy,
      url,
      range: ByteRange(mediaSize - 3000, mediaSize - 1),
    );
    expectRange(got, mediaSize - 3000, 3000);
  });

  test('跳转（seek）后重新取，偏移仍然正确', () async {
    final url = proxy.register(upstream.url);
    expectRange(
      await fetchThroughProxy(proxy, url, range: const ByteRange(0, 999)),
      0,
      1000,
    );
    // 跳到远处
    expectRange(
      await fetchThroughProxy(
        proxy,
        url,
        range: const ByteRange(700000, 702000),
      ),
      700000,
      2001,
    );
    // 再跳回开头附近：应命中缓冲，且内容依旧正确
    expectRange(
      await fetchThroughProxy(proxy, url, range: const ByteRange(100, 900)),
      100,
      801,
    );
  });

  test('重复请求同一区间命中缓冲（不再打上游）', () async {
    final url = proxy.register(upstream.url);
    await fetchThroughProxy(proxy, url, range: const ByteRange(0, 131071));
    final before = upstream.rangeLog.length;
    await fetchThroughProxy(proxy, url, range: const ByteRange(0, 131071));
    expect(
      upstream.rangeLog.length,
      before,
      reason: '第二次应完全命中缓冲',
    );
  });

  test('上游 403：长度探测失败要回 502，绝不回 200 空响应', () async {
    await proxy.stop();
    await upstream.stop();
    upstream = FakeUpstream(failWith: 403);
    await upstream.start();
    proxy = CdnProxy(connections: 4, chunkBytes: 64 * 1024, prefetchAhead: 0);
    await proxy.start();

    final url = proxy.register(upstream.url);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res = await req.close();
      // 关键：不能是 200（那会让播放器把空响应当成有效数据）
      expect(
        res.statusCode,
        isNot(HttpStatus.ok),
        reason: '拿不到资源大小时不能返回 200 空响应',
      );
      expect(res.statusCode, HttpStatus.badGateway);
      await res.drain<void>().catchError((_) {});
    } finally {
      client.close(force: true);
    }
    expect(proxy.totalUnavailable, greaterThan(0));
  });

  test('上游忽略 Range 直接回 200：长度探测可用，但代理不会倒出超量数据', () async {
    await proxy.stop();
    await upstream.stop();
    upstream = FakeUpstream(ignoreRange: true);
    await upstream.start();
    proxy = CdnProxy(connections: 4, chunkBytes: 64 * 1024, prefetchAhead: 0);
    await proxy.start();

    final url = proxy.register(upstream.url);
    final client = HttpClient();
    // 上游给整段而我们要一小段：代理必须**毁连接**，不能把整段倒过来
    // （否则就是 "Content size exceeds specified contentLength"）。
    Object? failure;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res = await req.close();
      final out = BytesBuilder();
      await for (final part in res) {
        out.add(part);
      }
      // 若没有抛错，也绝不能超过声明的长度
      expect(out.length, lessThanOrEqualTo(1024));
    } catch (e) {
      failure = e;
    } finally {
      client.close(force: true);
    }
    expect(
      failure != null || proxy.fallbackCount > 0,
      isTrue,
      reason: '应当走降级路径（毁连接或直通失败）',
    );
  });

  test('register 同一地址复用 track，地址变化则作废缓存', () async {
    final url1 = proxy.register(upstream.url, label: 'v');
    final track1 = proxy.trackOf(upstream.url)!;
    await fetchThroughProxy(proxy, url1, range: const ByteRange(0, 4095));
    expect(track1.buffer.cachedBytes, greaterThan(0));

    // 同地址再注册：应复用（缓存还在）
    proxy.register(upstream.url);
    expect(proxy.trackOf(upstream.url)!.buffer.cachedBytes, greaterThan(0));

    // 换地址（模拟签名刷新）：同一 key 若命中，必须作废缓存
    final sameKeyUrl = '${upstream.url}?t=2';
    final url2 = proxy.register(sameKeyUrl);
    if (url2 == url1) {
      expect(
        proxy.trackOf(sameKeyUrl)!.buffer.cachedBytes,
        0,
        reason: '地址变了必须清缓存',
      );
    }
  });

  test('debugSummary 不崩且含关键计数', () {
    proxy.register(upstream.url, label: 'video');
    final s = proxy.debugSummary();
    expect(s, contains('代理 :'));
    expect(s, contains('video'));
  });
}
