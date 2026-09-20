// 缓冲记账微基准：把"代理在主线程上维护缓冲要花多少毫秒"量出来。
//
// 动机：用户在 4K 下"一碰 UI 就卡、切到官方 App 就不卡"，怀疑瓶颈不是网络而是
// 主线程记账。这一组测试不依赖网络，纯本地跑，用来**钉死**开销是否存在、在哪里、
// 随什么增长。判据是**单次耗时**（帧预算 16.7ms @60Hz），不是累计量。
//
//   flutter test test/services/cdn/proxy_profiler_test.dart
//
// 注意：数字随机器变化，所以断言只钉"量级"与"单调性"，不钉具体毫秒值。

import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/cdn_proxy.dart';
import 'package:PiliPlus/services/cdn/proxy_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnProxyProfiler 计数正确', () {
    setUp(CdnProxyProfiler.reset);

    test('add / has / take 都被计数', () {
      final b = ByteBufferIndex();
      final track = ProxyTrack(url: 'x');
      b.add(const ByteRange(0, 99));
      b.has(0);
      track.put(const ByteRange(0, 99), Uint8List(100));
      track.take(0, 99);
      expect(CdnProxyProfiler.addCalls, greaterThanOrEqualTo(2));
      expect(CdnProxyProfiler.hasCalls, 1);
      expect(CdnProxyProfiler.takeCalls, 1);
    });

    test('evict 只在真的丢到东西时计数', () {
      // 远未超限：不计数
      final b = ByteBufferIndex(limit: 1 << 20);
      b.add(const ByteRange(0, 1023));
      expect(CdnProxyProfiler.evictCalls, 0, reason: '远未超限');

      // 已有 1MiB 顶格缓存，再在更远处加一块 → 必须丢东西，计数
      final b2 = ByteBufferIndex(limit: 1 << 20)..center = 0;
      b2.add(const ByteRange(0, (1 << 20) - 1));
      expect(CdnProxyProfiler.evictCalls, 0, reason: '刚好在上限内');
      b2.add(const ByteRange(1 << 22, (1 << 22) + 1023));
      expect(CdnProxyProfiler.evictCalls, greaterThanOrEqualTo(1));
      // 注意既有策略：center=0 时**新加的那块更远**，于是被丢的是新块。
      // 这正是 P1 要用分段调度取代"距离驱逐"的原因。
      expect(b2.has(1 << 22), isFalse, reason: '新块被当成"远的"丢掉了');
    });

    test('reset 清零（含最差记录）', () {
      final b = ByteBufferIndex(limit: 100)..center = 0;
      b.add(const ByteRange(0, 499));
      b.add(const ByteRange(10000, 10499));
      expect(CdnProxyProfiler.evictCalls, greaterThan(0));
      CdnProxyProfiler.reset();
      expect(CdnProxyProfiler.addCalls, 0);
      expect(CdnProxyProfiler.evictCalls, 0);
      expect(CdnProxyProfiler.takeCalls, 0);
      expect(CdnProxyProfiler.worstEvictUs, 0);
      expect(CdnProxyProfiler.worstTakeUs, 0);
    });

    test('report() 有样本时给出四个操作，无样本时给出提示', () {
      CdnProxyProfiler.reset();
      expect(CdnProxyProfiler.report(), contains('暂无样本'));
      final track = ProxyTrack(url: 'x');
      track.put(const ByteRange(0, 99), Uint8List(100));
      track.take(0, 99);
      final r = CdnProxyProfiler.report();
      expect(r, contains('add'));
      expect(r, contains('evict'));
      expect(r, contains('has'));
      expect(r, contains('take'));
    });
  });

  group('RequestProfile 每请求独立', () {
    test('两个 RequestStats 的归集互不污染', () {
      final a = RequestStats();
      final b = RequestStats();
      final pa = RequestProfile.of(a);
      final pb = RequestProfile.of(b);
      expect(identical(pa, pb), isFalse, reason: '并发请求必须各自一个实例');
      pa.putUs = 100;
      expect(pb.putUs, 0);
    });

    test('of 幂等，take 取走后复位', () {
      final s = RequestStats();
      expect(identical(RequestProfile.of(s), RequestProfile.of(s)), isTrue);
      RequestProfile.of(s).putCount = 3;
      final taken = RequestProfile.take(s);
      expect(taken.putCount, 3);
      expect(RequestProfile.of(s).putCount, 0, reason: 'take 之后必须是新实例');
    });
  });

  group('记账耗时的规模特性（微基准本体）', () {
    /// 造一个"真实播放时"的碎片化缓冲：blockCount 个块，每块 [blockBytes]。
    ProxyTrack fragmented({
      required int blockCount,
      required int blockBytes,
      required int limit,
    }) {
      final t = ProxyTrack(url: 'x', buffer: ByteBufferIndex(limit: limit));
      for (var i = 0; i < blockCount; i++) {
        t.put(
          ByteRange(i * blockBytes, (i + 1) * blockBytes - 1),
          Uint8List(blockBytes),
        );
      }
      t.buffer.center = 0;
      return t;
    }

    test('take 的单次耗时随缓存块数增长（排序全部键的代价）', () {
      CdnProxyProfiler.reset();
      final small = fragmented(
        blockCount: 16,
        blockBytes: 512 * 1024,
        limit: 512 * 1024 * 1024,
      );
      final big = fragmented(
        blockCount: 256,
        blockBytes: 512 * 1024,
        limit: 512 * 1024 * 1024,
      );
      // 各取 200 次，比较总耗时（单次太快、噪声大）
      final swS = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        small.take(0, 64 * 1024);
      }
      swS.stop();
      final swB = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        big.take(0, 64 * 1024);
      }
      swB.stop();
      // ignore: avoid_print
      print(
        '[prof] take×200：16 块 ${swS.elapsedMicroseconds}us，'
        '256 块 ${swB.elapsedMicroseconds}us '
        '（单次 ${(swB.elapsedMicroseconds / 200 / 1000).toStringAsFixed(3)}ms）',
      );
      expect(swB.elapsedMicroseconds, greaterThan(0));
    });

    test('evict 的单次耗时随 range 数增长（O(n²) 求和 + 排序）', () {
      // 重要前提：`buffer.add` 会把**相邻**范围合并（r.end + 1 >= next.start），
      // 所以段间要留 ≥1 字节真空隙才留得住碎片。
      // 构造：铺 n 段各 block 字节（段间 1 字节空隙，避免被合并成一大段），
      // 上限取"刚好装得下全部铺底数据"，然后插一大块把总量顶过上限 ——
      // 这一次 put 必然触发真实驱逐。
      int spread(int n, int block) {
        final limit = n * (block + 1) + block; // 刚好容纳铺底数据
        CdnProxyProfiler.reset();
        final t = ProxyTrack(url: 'x', buffer: ByteBufferIndex(limit: limit));
        for (var i = 0; i < n; i++) {
          final s = i * (block + 1);
          t.put(ByteRange(s, s + block - 1), Uint8List(1));
        }
        expect(t.buffer.ranges.length, n, reason: '每段必须保持独立（空隙不够）');
        final tail = n * (block + 1);
        final before = CdnProxyProfiler.evictCalls;
        final sw = Stopwatch()..start();
        t.put(ByteRange(tail, tail + limit + block - 1), Uint8List(1));
        sw.stop();
        expect(
          CdnProxyProfiler.evictCalls,
          greaterThan(before),
          reason: '尾块(${limit + block}B) 比上限($limit) 还大，必须驱逐',
        );
        return sw.elapsedMicroseconds;
      }

      final results = <int, int>{};
      for (final n in [32, 128, 256, 512, 1024]) {
        results[n] = spread(n, 4096);
      }
      // ignore: avoid_print
      print(
        '[prof] 触发驱逐的那次写入：'
        '${results.entries.map((e) => '${e.key}段 ${e.value}us').join('，')}',
      );
      // 单调性：段数越多单次驱逐越贵（不钉具体数值，机器不同）
      expect(results[1024]!, greaterThanOrEqualTo(results[32]!));
    });

    test('put 把 evict 的开销算进去（最坏一次写入是可见的）', () {
      CdnProxyProfiler.reset();
      final prof = RequestProfile.of(RequestStats());
      // 块很大 + limit 很小 → 每次 put 都会真的丢数据
      final t = ProxyTrack(url: 'x', buffer: ByteBufferIndex(limit: 1 << 20));
      for (var i = 0; i < 64; i++) {
        t.put(
          ByteRange(i * (1 << 21), i * (1 << 21) + (1 << 20) - 1),
          Uint8List(1),
          prof,
        );
      }
      expect(prof.putCount, 64, reason: '每次 put 都要归集一次');
      expect(prof.putUs, greaterThan(0));
      expect(CdnProxyProfiler.evictCalls, greaterThan(0), reason: '应当触发过驱逐');
      // ignore: avoid_print
      print(
        '[prof] 64 次 put 合计 ${prof.putMs.toStringAsFixed(2)}ms，'
        '最差单次 evict ${(CdnProxyProfiler.worstEvictUs / 1000).toStringAsFixed(3)}ms',
      );
    });

    test('无 prof 时 put/take 仍然计数（预取路径不受影响）', () {
      CdnProxyProfiler.reset();
      final t = ProxyTrack(url: 'x');
      t.put(const ByteRange(0, 99), Uint8List(100));
      t.take(0, 99);
      // 二者都是全局累计量，不在请求结束时归零，只断言"确实增加了"
      expect(CdnProxyProfiler.addCalls, greaterThanOrEqualTo(1));
      expect(CdnProxyProfiler.takeCalls, greaterThanOrEqualTo(1));
    });

    test('真实规模扫描：单次 put/take 在各档缓存下的耗时', () {
      // 4K 码率按 60 Mbps 估：90s 预取窗口 ≈ 675MB，桌面 limit 512MB。
      // 块大小取实际用的 512KiB，所以块数 = 缓存字节 / 512KiB。
      const block = 512 * 1024;
      for (final blocks in [64, 128, 256, 512, 1024]) {
        CdnProxyProfiler.reset();
        final limit = blocks * block + block; // 刚好装得下，不触发驱逐
        final t = ProxyTrack(url: 'x', buffer: ByteBufferIndex(limit: limit));
        final prof = RequestProfile.of(RequestStats());
        for (var i = 0; i < blocks; i++) {
          t.put(ByteRange(i * block, (i + 1) * block - 1), Uint8List(1), prof);
        }
        final putMs = prof.putMs;
        final takeSw = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          t.take(blocks * block ~/ 2, blocks * block ~/ 2 + 64 * 1024);
        }
        takeSw.stop();
        final perPut = putMs / blocks;
        final perTake = takeSw.elapsedMicroseconds / 100 / 1000;
        // ignore: avoid_print
        print(
          '[prof] ${(blocks * block / 1048576).toStringAsFixed(0).padLeft(4)}MiB '
          '(${blocks.toString().padLeft(4)} 块)  '
          'put ${perPut.toStringAsFixed(3)}ms/次  '
          'take ${perTake.toStringAsFixed(3)}ms/次  '
          '${perPut > 8 || perTake > 8 ? '← 超半帧预算' : ''}',
        );
        expect(perPut.isFinite && perTake.isFinite, isTrue);
      }
    });

    test('真实规模扫描：碎片化（range 多）时的 put 开销', () {
      // 关键场景：seek/跳转后缓冲被切成很多段。put 里两处是 O(chunks × ranges)：
      //   * `chunks.removeWhere` 对每个块扫一遍 live 范围
      //   * `buffer.add` 每次重建整个 range 列表
      // 所以这里固定块数、只增加碎片度，看单次 put 怎么变。
      const block = 512 * 1024;
      for (final gapKb in [0, 256, 4096, 65536]) {
        CdnProxyProfiler.reset();
        final t = ProxyTrack(
          url: 'x',
          buffer: ByteBufferIndex(limit: 1 << 30),
        );
        final prof = RequestProfile.of(RequestStats());
        const blocks = 256;
        final stride = block + gapKb * 1024;
        for (var i = 0; i < blocks; i++) {
          t.put(ByteRange(i * stride, i * stride + block - 1), Uint8List(1), prof);
        }
        // ignore: avoid_print
        print(
          '[prof] gap ${gapKb.toString().padLeft(5)}KiB  '
          'range ${t.buffer.ranges.length.toString().padLeft(4)}  '
          'put ${(prof.putMs / blocks).toStringAsFixed(3)}ms/次',
        );
        expect(prof.putCount, blocks);
      }
    });
  });
}
