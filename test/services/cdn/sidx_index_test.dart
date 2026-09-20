// SIDX 解析器单测：合成盒（可精确断言）+ 真实 B 站字节（验证真实布局）。
//
//   flutter test test/services/cdn/sidx_index_test.dart
//
// 合成盒覆盖：v0/v1 两种字段宽度、largesize、size==0、被截断、非法版本、
// 零 timescale、层级引用（referenced=false）、越界读取。
// 真实字节来自 test/fixtures/sidx_real.json（该目录被 gitignore，缺失时自动跳过）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/sidx_index.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------- 合成盒构造

void _u32(List<int> out, int v) {
  out
    ..add((v >> 24) & 0xff)
    ..add((v >> 16) & 0xff)
    ..add((v >> 8) & 0xff)
    ..add(v & 0xff);
}

void _u64(List<int> out, int v) {
  for (var k = 7; k >= 0; k--) {
    out.add((v >> (k * 8)) & 0xff);
  }
}

/// 一个子分段引用：(size, durationTicks, isHierarchical)。
///
/// **引用类型位语义（实测确认）**：word 的 bit31 = 1 表示层级引用（指向另一个
/// sidx），= 0 表示直接引用（媒体分段）。B 站 377/376 条全部为 0，且低 31 位
/// 恰好等于段字节数。早期按相反语义构造测试，导致合成测试"通过"而真实数据解析
/// 失败——所以这里显式用 isHierarchical 命名，避免再次写反。
typedef Ref = (int size, int durationTicks, bool isHierarchical);

/// 构造一个 sidx 盒；返回完整字节（从头开始，即偏移 0）。
Uint8List buildSidx({
  required int version,
  required int timescale,
  required int firstOffset,
  required List<Ref> refs,
  int earliest = 0,
  String type = 'sidx',
}) {
  final body = <int>[
    version,
    0, 0, 0, // flags
    ..._u32Bytes(1), // reference_ID
    ..._u32Bytes(timescale),
    if (version == 0) ...[
      ..._u32Bytes(earliest),
      ..._u32Bytes(firstOffset),
    ] else ...[
      ..._u64Bytes(earliest),
      ..._u64Bytes(firstOffset),
    ],
    0, 0, // reserved
    ..._u16Bytes(refs.length),
    for (final (size, dur, isHierarchical) in refs) ...[
      // bit31 = 1 → 层级引用；0 → 直接引用（见 typedef Ref 的说明）
      ..._u32Bytes(isHierarchical ? (size | 0x80000000) : size),
      ..._u32Bytes(dur),
      ..._u32Bytes(0x90000000), // starts_with_SAP=1, SAP_type=1
    ],
  ];

  return Uint8List.fromList([
    ..._u32Bytes(8 + body.length),
    ...type.codeUnits,
    ...body,
  ]);
}

/// 构造一个任意大小的具名盒（用于 ftyp/moov 占位）。
Uint8List buildBox(String type, int contentBytes) => Uint8List.fromList([
  ..._u32Bytes(8 + contentBytes),
  ...type.codeUnits,
  ...List.filled(contentBytes, 0),
]);

List<int> _u16Bytes(int v) => [(v >> 8) & 0xff, v & 0xff];

List<int> _u64Bytes(int v) => [
  for (var k = 7; k >= 0; k--) (v >> (k * 8)) & 0xff,
];

List<int> _u32Bytes(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

Uint8List concat(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

void main() {
  group('盒遍历', () {
    test('依次读出顶层盒', () {
      final data = concat([
        buildBox('ftyp', 24),
        buildBox('moov', 100),
        buildSidx(version: 1, timescale: 1000, firstOffset: 0, refs: [(100, 1000, false)]),
      ]);
      final boxes = SidxParser.readTopLevelBoxes(data);
      expect(boxes.map((b) => b.type).toList(), ['ftyp', 'moov', 'sidx']);
      expect(boxes[0].contentStart, 8);
      expect(boxes[0].contentEnd, 31);
      expect(boxes[1].contentStart, 40);
    });

    test('被截断的盒不产生越界内容', () {
      final full = buildBox('moov', 200);
      final truncated = Uint8List.sublistView(full, 0, 100);
      final boxes = SidxParser.readTopLevelBoxes(truncated);
      expect(boxes.length, 1);
      // 记录下来了，但内容区超出已读范围，调用方据此判断不完整
      expect(boxes.first.contentEnd, greaterThan(truncated.length - 1));
    });

    test('size==1 的 64 位 largesize', () {
      final content = List<int>.filled(16, 7);
      final out = <int>[];
      _u32(out, 1); // size32 == 1 → 读 largesize
      out.addAll('sidx'.codeUnits);
      _u64(out, 16 + content.length);
      out.addAll(content);
      final boxes = SidxParser.readTopLevelBoxes(Uint8List.fromList(out));
      expect(boxes.single.type, 'sidx');
      expect(boxes.single.headerSize, 16);
      expect(boxes.single.contentLength, 16);
    });

    test('非打印字符的类型视为损坏，停止解析', () {
      final data = Uint8List.fromList([0, 0, 0, 16, 0x01, 0x02, 0x03, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(SidxParser.readTopLevelBoxes(data), isEmpty);
    });
  });

  group('SIDX v1 解析', () {
    test('段偏移与时长正确（绝对字节）', () {
      // ftyp(32) 后接 sidx：段起点应等于 sidx 盒末尾（36+...）
      final sidx = buildSidx(
        version: 1,
        timescale: 16000,
        firstOffset: 0,
        refs: [(353078, 80000, false), (190475, 80000, false), (373435, 80000, false)],
      );
      final ftyp = buildBox('ftyp', 24);
      final data = concat([ftyp, sidx]);

      final idx = SidxParser.parse(data)!;
      expect(idx.timescale, 16000);
      expect(idx.segmentCount, 3);

      // 80000 ticks / 16000 = 5s
      final s0 = idx.segments[0];
      expect(s0.durationMs, 5000);
      expect(s0.startMs, 0);
      expect(s0.size, 353078);
      // 首段起点 = ftyp(32) + sidx 总长
      final sidxEnd = 32 + sidx.length;
      expect(s0.offset, sidxEnd);
      expect(s0.endOffset, sidxEnd + 353078 - 1);

      final s1 = idx.segments[1];
      expect(s1.offset, s0.endOffset + 1, reason: '段必须首尾相接');
      expect(s1.startMs, 5000);
      final s2 = idx.segments[2];
      expect(s2.offset, s1.endOffset + 1);
      expect(s2.startMs, 10000);
      expect(idx.coveredBytes, 353078 + 190475 + 373435);
      expect(idx.coveredMs, 15000);
    });

    test('first_offset 非零时整体后移', () {
      final sidx = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 512,
        refs: [(100, 1000, false)],
      );
      final idx = SidxParser.parse(sidx)!;
      expect(idx.segments.single.offset, sidx.length + 512);
    });

    test('层级引用条目被跳过且不推进字节游标', () {
      final sidx = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 0,
        refs: [(100, 1000, false), (999, 1000, true), (200, 1000, false)],
      );
      final idx = SidxParser.parse(sidx)!;
      expect(idx.segmentCount, 2, reason: '层级引用不是本文件的段');
      expect(idx.segments[1].offset, idx.segments[0].endOffset + 1,
          reason: '被跳过的条目不能占用字节');
      expect(idx.segments[1].size, 200);
    });
  });

  group('SIDX v0 解析', () {
    test('32 位字段宽度下的偏移与时长', () {
      final sidx = buildSidx(
        version: 0,
        timescale: 90000,
        firstOffset: 0,
        refs: [(1000, 450000, false), (2000, 450000, false)],
      );
      final idx = SidxParser.parse(sidx)!;
      expect(idx.segmentCount, 2);
      // 450000/90000 = 5s
      expect(idx.segments[0].durationMs, 5000);
      expect(idx.segments[0].offset, sidx.length);
      expect(idx.segments[1].offset, sidx.length + 1000);
    });

    test('earliestPresentationTime 被换算成毫秒', () {
      final sidx = buildSidx(
        version: 0,
        timescale: 1000,
        firstOffset: 0,
        earliest: 2500,
        refs: [(10, 1000, false)],
      );
      final idx = SidxParser.parse(sidx)!;
      expect(idx.earliestPresentationMs, 2500);
    });
  });

  group('拒绝非法输入（一律返回 null，由调用方回落直通）', () {
    test('没有 sidx 盒', () {
      final data = concat([buildBox('ftyp', 24), buildBox('moov', 40)]);
      expect(SidxParser.parse(data), isNull);
    });

    test('字节太短', () {
      expect(SidxParser.parse(Uint8List(8)), isNull);
      expect(SidxParser.parse(Uint8List(0)), isNull);
    });

    test('引用表被截断 → null', () {
      final full = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 0,
        refs: List.generate(50, (i) => (100 + i, 1000, false)),
      );
      // 砍掉尾部，引用表不完整
      final cut = Uint8List.sublistView(full, 0, full.length - 100);
      expect(SidxParser.parse(cut), isNull);
    });

    test('timescale 为 0 → null（避免除零）', () {
      final sidx = buildSidx(
        version: 1,
        timescale: 0,
        firstOffset: 0,
        refs: [(100, 1000, false)],
      );
      expect(SidxParser.parse(sidx), isNull);
    });

    test('未知版本 → null，不猜测布局', () {
      final sidx = buildSidx(
        version: 2,
        timescale: 1000,
        firstOffset: 0,
        refs: [(100, 1000, false)],
      );
      expect(SidxParser.parse(sidx), isNull);
    });

    test('全部 entry 都是层级引用 → 没有可用段 → null', () {
      final sidx = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 0,
        refs: [(100, 1000, true), (200, 1000, true)],
      );
      expect(SidxParser.parse(sidx), isNull);
    });

    test('size 为 0 的条目被跳过', () {
      final sidx = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 0,
        refs: [(0, 1000, false), (500, 1000, false)],
      );
      final idx = SidxParser.parse(sidx)!;
      expect(idx.segmentCount, 1);
      expect(idx.segments.single.size, 500);
    });
  });

  group('段查找（二分，覆盖边界）', () {
    late SidxIndex idx;
    setUp(() {
      final sidx = buildSidx(
        version: 1,
        timescale: 1000,
        firstOffset: 0,
        refs: [(100, 1000, false), (200, 1000, false), (300, 1000, false)],
      );
      idx = SidxParser.parse(sidx)!;
    });

    test('命中每一段的首字节与末字节', () {
      for (final s in idx.segments) {
        expect(idx.segmentAt(s.offset)?.index, s.index, reason: '首字节');
        expect(idx.segmentAt(s.endOffset)?.index, s.index, reason: '末字节');
      }
    });

    test('段间边界不串段', () {
      final s0 = idx.segments[0];
      final s1 = idx.segments[1];
      expect(idx.segmentAt(s0.endOffset + 1)?.index, s1.index);
      expect(idx.segmentAt(s1.offset - 1)?.index, s0.index);
    });

    test('索引之前与之后返回 null', () {
      final first = idx.segments.first.offset;
      final last = idx.segments.last.endOffset;
      expect(idx.segmentAt(first - 1), isNull);
      expect(idx.segmentAt(last + 1), isNull);
      expect(idx.segmentAt(0), isNull, reason: 'init 段区域不属于任何子分段');
    });

    test('segmentsCovering 覆盖跨段区间', () {
      final s0 = idx.segments[0];
      final s2 = idx.segments[2];
      final got = idx.segmentsCovering(s0.offset, s2.endOffset);
      expect(got.length, 3);
      expect(got.first.index, 0);
      expect(got.last.index, 2);
    });

    test('segmentsCovering 部分覆盖首尾段', () {
      final s0 = idx.segments[0];
      final s1 = idx.segments[1];
      final got = idx.segmentsCovering(s0.offset + 10, s1.offset + 10);
      expect(got.length, 2);
    });

    test('segmentsCovering 与索引无交集 → 空', () {
      final first = idx.segments.first.offset;
      expect(idx.segmentsCovering(0, first - 1), isEmpty);
      expect(idx.segmentsCovering(idx.segments.last.endOffset + 5,
          idx.segments.last.endOffset + 10), isEmpty);
    });

    test('空索引不崩', () {
      final empty = SidxIndex(timescale: 1000, earliestPresentationMs: 0, segments: const []);
      expect(empty.isEmpty, isTrue);
      expect(empty.segmentAt(100), isNull);
      expect(empty.segmentsCovering(0, 100), isEmpty);
      expect(empty.coveredBytes, 0);
      expect(empty.coveredMs, 0);
    });
  });

  group('真实 B 站字节（夹具缺失则跳过）', () {
    final fixture = File('test/fixtures/sidx_real.json');

    test('真实视频轨/音频轨的 SIDX 可解析且字段自洽', () {
      if (!fixture.existsSync()) {
        markTestSkipped('缺少 test/fixtures/sidx_real.json（该目录被 gitignore）');
        return;
      }
      final json = jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
      for (final name in ['video', 'audio']) {
        final entry = json[name] as Map<String, dynamic>;
        final bytes = base64Decode(entry['b64'] as String);
        final idx = SidxParser.parse(bytes);
        expect(idx, isNotNull, reason: '$name 轨应能解析出 SIDX');

        // 结构自洽：段首尾相接、时长单调、大小为正
        for (var i = 0; i < idx!.segmentCount; i++) {
          final s = idx.segments[i];
          expect(s.size, greaterThan(0), reason: '$name 段 $i 大小应为正');
          expect(s.durationMs, greaterThan(0), reason: '$name 段 $i 时长应为正');
          if (i > 0) {
            expect(s.offset, idx.segments[i - 1].endOffset + 1,
                reason: '$name 段 $i 应与前一段首尾相接');
            expect(s.startMs, greaterThanOrEqualTo(idx.segments[i - 1].startMs));
          }
        }
        // 时间基与段长应符合 B 站惯例（5 秒左右一段）
        expect(idx.segmentCount, greaterThan(50), reason: '$name 轨段数应较多');
        final firstDuration = idx.segments.first.durationMs;
        expect(firstDuration, inInclusiveRange(3000, 7000),
            reason: '$name 首段时长应在 3–7 秒（实测约 5 秒）');
        // 首页字节应落在第一段内或 init 区域，不应报错
        expect(idx.segmentAt(idx.segments.first.offset)?.index, 0);
      }
    });
  });
}
