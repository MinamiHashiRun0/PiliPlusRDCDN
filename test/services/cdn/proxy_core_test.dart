// proxy_core 的离线单测：Range 语义、缺口切块、滚动缓冲。
// 这三块是整个并发代理最容易写错的地方——错了的表现是"播放卡住/花屏/跳转失灵"，
// 很难在设备上定位，所以在本地先把它们钉死。
//
//   flutter test test/services/cdn/proxy_core_test.dart

import 'package:PiliPlus/services/cdn/proxy_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RangeRequest.parse', () {
    test('闭区间', () {
      final r = RangeRequest.parse('bytes=0-1023')!;
      expect(r.start, 0);
      expect(r.end, 1023);
      expect(r.resolve(10000), const ByteRange(0, 1023));
    });

    test('开区间（到结尾）', () {
      final r = RangeRequest.parse('bytes=100-')!;
      expect(r.resolve(1000), const ByteRange(100, 999));
      // 总长未知时无法收敛
      expect(r.resolve(null), isNull);
    });

    test('后缀形态 bytes=-n', () {
      final r = RangeRequest.parse('bytes=-500')!;
      expect(r.suffixLength, 500);
      expect(r.resolve(2000), const ByteRange(1500, 1999));
      // n 大于总长时从头开始
      expect(r.resolve(100), const ByteRange(0, 99));
    });

    test('大小写与空格容错', () {
      expect(RangeRequest.parse('Bytes= 0-9')!.resolve(100), const ByteRange(0, 9));
    });

    test('不支持/非法输入一律返回 null（=按无 Range 处理，最安全）', () {
      expect(RangeRequest.parse(null), isNull);
      expect(RangeRequest.parse(''), isNull);
      expect(RangeRequest.parse('items=0-1'), isNull);
      expect(RangeRequest.parse('bytes=0-1,5-6'), isNull); // 多区间
      expect(RangeRequest.parse('bytes=abc'), isNull);
      expect(RangeRequest.parse('bytes=5-1'), isNull); // 起止颠倒
      expect(RangeRequest.parse('bytes=-0'), isNull);
    });

    test('越界与超出总长的收敛', () {
      expect(RangeRequest.parse('bytes=0-99999')!.resolve(100), const ByteRange(0, 99));
      // 起点已超总长 → null，调用方应回 416
      expect(RangeRequest.parse('bytes=200-')!.resolve(100), isNull);
    });
  });

  group('ContentRange.parse / format', () {
    test('带总长', () {
      final c = ContentRange.parse('bytes 0-1023/5000')!;
      expect(c.start, 0);
      expect(c.end, 1023);
      expect(c.total, 5000);
    });

    test('总长为 * 时视作未知', () {
      final c = ContentRange.parse('bytes 100-199/*')!;
      expect(c.total, isNull);
    });

    test('非法输入返回 null', () {
      expect(ContentRange.parse(null), isNull);
      expect(ContentRange.parse('bytes */5000'), isNull);
      expect(ContentRange.parse('0-100/500'), isNull);
    });

    test('format 与 parse 互逆', () {
      const r = ByteRange(100, 199);
      final s = ContentRange.format(r, 5000);
      expect(s, 'bytes 100-199/5000');
      final back = ContentRange.parse(s)!;
      expect(back.start, 100);
      expect(back.end, 199);
      expect(back.total, 5000);
      expect(ContentRange.format(r, null), 'bytes 100-199/*');
    });
  });

  group('planChunks', () {
    test('按连接数均分，合起来不重不漏', () {
      const want = ByteRange(0, 1023);
      final chunks = planChunks(want, connections: 4);
      expect(chunks.length, 4);
      expect(chunks.first.start, 0);
      expect(chunks.last.end, 1023);
      for (var i = 1; i < chunks.length; i++) {
        expect(chunks[i].start, chunks[i - 1].end + 1, reason: '必须首尾相接');
      }
      expect(chunks.fold<int>(0, (s, c) => s + c.length), want.length);
    });

    test('指定每块大小时最后一块吃掉剩余', () {
      const want = ByteRange(0, 999);
      final chunks = planChunks(want, connections: 4, perConn: 100);
      expect(chunks.length, 4);
      expect(chunks[0], const ByteRange(0, 99));
      expect(chunks[1], const ByteRange(100, 199));
      expect(chunks[2], const ByteRange(200, 299));
      expect(chunks[3], const ByteRange(300, 999)); // 尾部一次吃掉
      expect(chunks.last.end, want.end);
    });

    test('请求量小于切块粒度时只有一块', () {
      const want = ByteRange(50, 59);
      expect(planChunks(want, connections: 8, perConn: 1 << 20), [want]);
    });

    test('connections<=1 或空区间时原样返回', () {
      const want = ByteRange(0, 9);
      expect(planChunks(want, connections: 1), [want]);
      expect(planChunks(want, connections: 0), [want]);
    });
  });

  group('ByteBufferIndex', () {
    test('add 合并相邻与重叠段', () {
      final b = ByteBufferIndex();
      b.add(const ByteRange(0, 99));
      b.add(const ByteRange(100, 199)); // 相邻 → 合并
      expect(b.ranges.length, 1);
      expect(b.ranges.single, const ByteRange(0, 199));

      b.add(const ByteRange(50, 149)); // 重叠 → 不变
      expect(b.ranges.single, const ByteRange(0, 199));

      b.add(const ByteRange(300, 399)); // 分开
      expect(b.ranges.length, 2);
      b.add(const ByteRange(200, 299)); // 把两段接起来
      expect(b.ranges.length, 1);
      expect(b.ranges.single, const ByteRange(0, 399));
    });

    test('gaps 求缺口', () {
      final b = ByteBufferIndex();
      b.add(const ByteRange(100, 199));
      // 全空
      expect(b.gaps(const ByteRange(0, 99)), [const ByteRange(0, 99)]);
      // 部分命中
      expect(b.gaps(const ByteRange(150, 249)), [const ByteRange(200, 249)]);
      // 完全命中
      expect(b.gaps(const ByteRange(120, 180)), isEmpty);
      // 两头都缺
      expect(b.gaps(const ByteRange(50, 249)), [
        const ByteRange(50, 99),
        const ByteRange(200, 249),
      ]);
      // 中间缺
      b.add(const ByteRange(300, 399));
      expect(b.gaps(const ByteRange(100, 399)), [const ByteRange(200, 299)]);
    });

    test('contiguousEndFrom', () {
      final b = ByteBufferIndex();
      b.add(const ByteRange(100, 199));
      expect(b.contiguousEndFrom(100), 199);
      expect(b.contiguousEndFrom(150), 199);
      expect(b.contiguousEndFrom(200), 199); // 200 未缓存 → 返回 from-1
      expect(b.contiguousEndFrom(0), -1);
    });

    test('has', () {
      final b = ByteBufferIndex();
      b.add(const ByteRange(10, 19));
      expect(b.has(10), isTrue);
      expect(b.has(19), isTrue);
      expect(b.has(9), isFalse);
      expect(b.has(20), isFalse);
    });

    test('超过上限时优先丢离 center 远的数据', () {
      final b = ByteBufferIndex(limit: 1000)..center = 0;
      b.add(const ByteRange(0, 499));
      b.add(const ByteRange(10000, 10499));
      // 两段各 500，共 1000，正好在上限内
      expect(b.cachedBytes, 1000);
      b.add(const ByteRange(20000, 20499)); // 超了
      expect(b.cachedBytes, lessThanOrEqualTo(1000));
      // 最远的 20000 段应被丢掉，center 所在的 0 段必须留着
      expect(b.has(0), isTrue, reason: 'center 附近的数据不能丢');
      expect(b.has(20000), isFalse, reason: '最远的一段应先丢');
    });

    test('横跨 center 的段不会被整段丢掉', () {
      final b = ByteBufferIndex(limit: 100)..center = 1000;
      b.add(const ByteRange(0, 1999));
      expect(b.cachedBytes, lessThanOrEqualTo(100));
      expect(b.has(1000), isTrue, reason: 'center 必须仍可读');
    });

    test('clear 复位', () {
      final b = ByteBufferIndex()..center = 500;
      b.add(const ByteRange(0, 99));
      b.clear();
      expect(b.ranges, isEmpty);
      expect(b.center, 0);
    });
  });
}
