// 段调度核心单测：SegmentWindow 与 SegmentScheduler。
//
//   flutter test test/services/cdn/segment_scheduler_test.dart
//
// 重点覆盖两类容易写错的地方：
//   1. 字节偏移 —— 段边界拼接错一位就是花屏，所以逐字节断言；
//   2. 窗口滑出 —— 丢弃后再取应返回 null（由调用方补段），不能返回错的字节。

import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/segment_scheduler.dart';
import 'package:PiliPlus/services/cdn/sidx_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个段表：每段 [size] 字节，序号 0..count-1 首尾相接。
List<SidxSegment> makeSegments(int count, int size) {
  final out = <SidxSegment>[];
  var offset = 1000; // 故意不从 0 开始，模拟 init 段占用前部
  for (var i = 0; i < count; i++) {
    out.add(
      SidxSegment(
        index: i,
        offset: offset,
        size: size,
        startMs: i * 5000,
        durationMs: 5000,
      ),
    );
    offset += size;
  }
  return out;
}

/// 直接构造 SidxIndex（真实场景由 SidxParser 产出，测试里不必绕网络字节）。
SidxIndex makeIndex(int count, int size) => SidxIndex(
  timescale: 1000,
  earliestPresentationMs: 0,
  segments: makeSegments(count, size),
);

void main() {
  group('SegmentWindow 窗口滑动', () {
    test('窗口按 center 覆盖前 back 后 forward，范围外不建槽', () {
      final idx = makeIndex(20, 100);
      final w = SegmentWindow(forwardSegments: 4, backSegments: 2);
      w.slide(idx, 10);
      expect(w.windowStart, 8);
      expect(w.slotCount, 7, reason: '8..14 共 7 段');
      expect(w.slot(7), isNull);
      expect(w.slot(8), isNotNull);
      expect(w.slot(14), isNotNull);
      expect(w.slot(15), isNull);
    });

    test('向后滑动丢弃旧段', () {
      final idx = makeIndex(20, 100);
      final w = SegmentWindow(forwardSegments: 2, backSegments: 1);
      w.slide(idx, 5);
      expect(w.slot(4), isNotNull);
      w.slide(idx, 15);
      expect(w.slot(4), isNull, reason: '已滑出窗口');
      expect(w.slot(14), isNotNull);
    });

    test('center 在两端时窗口被夹到有效范围', () {
      final idx = makeIndex(5, 100);
      final w = SegmentWindow(forwardSegments: 3, backSegments: 3);
      w.slide(idx, 0);
      expect(w.windowStart, 0);
      expect(w.slot(3), isNotNull);
      expect(w.slot(4), isNull, reason: 'forward=3 只到 3');
      w.slide(idx, 4);
      expect(w.slot(4), isNotNull);
      expect(w.slot(0), isNull);
    });

    test('已下载的段在窗口内滑动时被保留', () {
      final idx = makeIndex(20, 100); // 20 段才够"滑出"（10 段时 center 9 的下界仍是 6）
      final w = SegmentWindow(forwardSegments: 3, backSegments: 3);
      w.slide(idx, 9);
      w.slot(9)!.data = Uint8List.fromList(List.filled(100, 9));
      w.slide(idx, 10); // 滑一格，9 仍在窗口内
      expect(w.slot(9)!.ready, isTrue, reason: '不应因为滑动而丢掉已下数据');
      w.slide(idx, 15); // 9 滑出窗口
      expect(w.slot(9), isNull);
    });

    test('空段表不崩', () {
      final w = SegmentWindow();
      w.slide(
        SidxIndex(timescale: 1, earliestPresentationMs: 0, segments: const []),
        0,
      );
      expect(w.slotCount, 0);
      expect(w.pending(), isEmpty);
    });

    test('pending 只列未就绪且未标记失败的段，按序号升序', () {
      final idx = makeIndex(10, 100);
      final w = SegmentWindow(forwardSegments: 4, backSegments: 0);
      w.slide(idx, 3);
      w.slot(4)!.data = Uint8List(100);
      w.slot(5)!.failure = '超时';
      final p = w.pending();
      expect(p.map((s) => s.segment.index).toList(), [3, 6, 7]);
      expect(w.readyCount, 1);
      expect(w.cachedBytes, 100);
    });

    test('pending(limit) 截断', () {
      final idx = makeIndex(10, 100);
      final w = SegmentWindow(forwardSegments: 8, backSegments: 0);
      w.slide(idx, 0);
      expect(w.pending().length, 9);
      expect(w.pending(limit: 3).length, 3);
      expect(w.pending(limit: 3).first.segment.index, 0);
    });
  });

  group('SegmentWindow.take 字节正确性', () {
    late SidxIndex idx;
    late SegmentWindow w;

    setUp(() {
      idx = makeIndex(6, 100); // offset 从 1000 开始，每段 100B
      w = SegmentWindow(forwardSegments: 5, backSegments: 0);
      w.slide(idx, 0);
      // 每段填成可辨认的字节：第 n 段第 i 字节 = (n*100+i) % 251
      for (final s in w.slots) {
        s.data = Uint8List.fromList([
          for (var i = 0; i < s.size; i++) (s.segment.index * 100 + i) % 251,
        ]);
      }
    });

    test('单段内区间', () {
      final got = w.take(1000, 1049);
      expect(got, isNotNull);
      expect(got!.length, 50);
      for (var i = 0; i < 50; i++) {
        expect(got[i], i % 251);
      }
    });

    test('跨段边界逐字节正确（最容易错一位的地方）', () {
      // 第 0 段 [1000-1099]，第 1 段 [1100-1199]
      final got = w.take(1080, 1130);
      expect(got, isNotNull);
      expect(got!.length, 51);
      for (var i = 0; i < 51; i++) {
        final abs = 1080 + i;
        // 期望字节 = 该绝对位置在段内偏移（段 0 起点 1000，段 1 起点 1100）
        final segIndex = abs < 1100 ? 0 : 1;
        final inSeg = abs - (1000 + segIndex * 100);
        expect(got[i], (segIndex * 100 + inSeg) % 251, reason: '绝对位置 $abs');
      }
    });

    test('跨三段区间', () {
      final got = w.take(1050, 1250);
      expect(got, isNotNull);
      expect(got!.length, 201);
      // 填充公式：第 n 段第 i 字节 = (n*100 + i) % 251
      expect(got.first, 50, reason: '段0 内偏移 50 → 50');
      expect(got[50], 100, reason: '段1 起始字节 → (1*100+0)');
      expect(got[150], 200, reason: '段2 起始字节 → (2*100+0)');
    });

    test('段未下载完 → null（调用方需先补段）', () {
      w.slot(1)!.data = null;
      expect(w.take(1050, 1150), isNull);
    });

    test('落在段表之外（init 段区域）→ null', () {
      expect(w.take(0, 100), isNull);
      expect(w.take(999, 1000), isNull);
    });

    test('超出段表末尾 → null', () {
      expect(w.take(1550, 1700), isNull);
    });

    test('滑出窗口后取该区间 → null（不返回错字节）', () {
      final w2 = SegmentWindow(forwardSegments: 1, backSegments: 0);
      w2.slide(idx, 0);
      w2.slot(0)!.data = Uint8List.fromList(List.filled(100, 7));
      expect(w2.take(1000, 1050), isNotNull);
      w2.slide(idx, 5); // 段 0 滑出
      expect(w2.take(1000, 1050), isNull);
    });

    test('start > end 返回空而非 null', () {
      expect(w.take(1100, 1000)?.length, 0);
    });

    test('未绑定段表时 take 返回 null', () {
      final fresh = SegmentWindow();
      expect(fresh.take(0, 10), isNull);
    });
  });

  group('SegmentScheduler 并发与重试', () {
    late SegmentWindow w;
    late SegmentScheduler s;

    setUp(() {
      w = SegmentWindow(forwardSegments: 9, backSegments: 0);
      w.slide(makeIndex(10, 100), 0);
      s = SegmentScheduler(window: w, maxConcurrent: 3, maxRetryPerSegment: 2);
    });

    test('每批不超过并发上限', () {
      final b1 = s.nextBatch();
      expect(b1.length, 3);
      for (final x in b1) {
        s.markStarted(x.segment.index);
      }
      expect(s.nextBatch(), isEmpty, reason: '3 条在飞，已达上限');

      // 完成第 0 条：必须先落数据再 markFinished ——
      // markFinished 只负责在飞计数与重试计数，"这一段已就绪"由 data 表达。
      // 若只 markFinished 不落数据，段落会重新出现在 pending 里被重复下载。
      final done = b1.first.segment.index;
      w.slot(done)!.data = Uint8List(w.slot(done)!.size);
      s.markFinished(done);
      final b2 = s.nextBatch();
      expect(b2.length, 1);
      expect(
        b2.map((x) => x.segment.index),
        isNot(contains(done)),
        reason: '已就绪的段不应再入批',
      );
      expect(b2.first.segment.index, 3, reason: '0..2 在飞，下一个待下的是 3');
    });

    test('已在下载中的段不会重复入批', () {
      s.markStarted(0);
      s.markStarted(1);
      final b = s.nextBatch();
      expect(b.map((x) => x.segment.index).toList(), [2]);
    });

    test('失败未达上限 → 保留待下载（可重试）', () {
      s.markStarted(0);
      s.markFinished(0, failure: '超时');
      expect(s.attemptsOf(0), 1);
      expect(w.slot(0)!.failure, isNull, reason: '未达上限不应标记失败');
      expect(s.nextBatch().map((x) => x.segment.index), contains(0));
    });

    test('失败达上限 → 标记失败并移出待下载', () {
      s.markStarted(0);
      s.markFinished(0, failure: '超时');
      s.markStarted(0);
      s.markFinished(0, failure: '超时');
      expect(w.slot(0)!.failure, '超时');
      expect(s.nextBatch().map((x) => x.segment.index), isNot(contains(0)));
      expect(w.pending().map((x) => x.segment.index), isNot(contains(0)));
    });

    test('成功后清掉重试计数', () {
      s.markStarted(0);
      s.markFinished(0, failure: '超时');
      s.markStarted(0);
      w.slot(0)!.data = Uint8List(100);
      s.markFinished(0);
      expect(s.attemptsOf(0), 0);
    });

    test('reset 清空在飞与计数', () {
      s.markStarted(0);
      s.markFinished(1, failure: 'x');
      s.reset();
      expect(s.inFlightCount, 0);
      expect(s.attemptsOf(1), 0);
    });

    test('全部就绪时不再产生批次', () {
      for (final slot in w.slots) {
        slot.data = Uint8List(slot.size);
      }
      expect(s.nextBatch(), isEmpty);
    });
  });
}
