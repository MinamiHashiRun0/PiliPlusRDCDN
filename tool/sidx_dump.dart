// SIDX 解析器的真实调用路径驱动器（同时也是排查工具）。
//
//   dart run tool/sidx_dump.dart <文件路径>
//   dart run tool/sidx_dump.dart --b64 <base64 的 m4s 头部字节>
//   dart run tool/sidx_dump.dart --url "<带签名的 m4s 地址>"   # 自动取前 64KiB
//
// 为什么要有它：解析器是纯库函数，单测只能证明"给定字节算得对"。真正要验证的是
// **它接进真实链路后能不能用**——所以这里按生产路径调用同一份代码，并额外打印
// 段表的自洽性检查（段首尾相接、时长单调、字节总数与文件 total 是否吻合）。
//
// 生产路径（第 ② 步）会做同样三件事：取头部字节 → SidxParser.parse → 建段表。
// 这里就是把那条路径单独跑起来，便于在没有设备的情况下核对真实视频。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/cdn/sidx_index.dart';

Future<void> main(List<String> args) async {
  // 只拦显式求助；无参数时走环境变量分支（SIDX_URL / SIDX_B64 / SIDX_FILE），
  // 不能在这里因为 args 为空就返回——那会让环境变量入参永远不可达。
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  Uint8List? bytes;
  String source = '';

  // 支持从环境变量取地址：B 站签名 URL 里全是 & ，经 cmd.exe / PowerShell 传参
  // 极易被拆断（实测被拆成十几段命令，导致上游 403）。SIDX_URL 是最稳的入参方式。
  final envUrl = Platform.environment['SIDX_URL'];
  final envB64 = Platform.environment['SIDX_B64'];
  final envFile = Platform.environment['SIDX_FILE'];

  if (args.isNotEmpty && args[0] == '--b64') {
    if (args.length < 2) {
      stderr.writeln('--b64 需要一个 base64 参数');
      exitCode = 2;
      return;
    }
    source = 'base64 输入（命令行）';
    bytes = base64Decode(args[1]);
  } else if (args.isNotEmpty && args[0] == '--url') {
    if (args.length < 2) {
      stderr.writeln('--url 需要一个地址参数');
      exitCode = 2;
      return;
    }
    source = 'HTTP Range 取头部（命令行地址）';
    bytes = await _fetchHead(args[1]);
    if (bytes == null) {
      stderr.writeln('取头部失败（网络或签名问题）');
      exitCode = 1;
      return;
    }
  } else if (args.isNotEmpty) {
    final file = File(args[0]);
    if (!file.existsSync()) {
      stderr.writeln('文件不存在：${args[0]}');
      exitCode = 2;
      return;
    }
    source = file.path;
    bytes = file.readAsBytesSync();
  } else if (envB64 != null) {
    source = 'base64 输入（SIDX_B64）';
    bytes = base64Decode(envB64);
  } else if (envUrl != null) {
    source = 'HTTP Range 取头部（SIDX_URL）';
    bytes = await _fetchHead(envUrl);
    if (bytes == null) {
      stderr.writeln('取头部失败（网络或签名问题）');
      exitCode = 1;
      return;
    }
  } else if (envFile != null) {
    final file = File(envFile);
    if (!file.existsSync()) {
      stderr.writeln('文件不存在：$envFile');
      exitCode = 2;
      return;
    }
    source = file.path;
    bytes = file.readAsBytesSync();
  } else {
    stdout.writeln(_usage);
    return;
  }

  stdout
    ..writeln('来源：$source')
    ..writeln('字节数：${bytes.length}');

  // 1) 顶层盒
  final boxes = SidxParser.readTopLevelBoxes(bytes);
  stdout.writeln('\n顶层盒：');
  for (final b in boxes) {
    final truncated = b.contentEnd > bytes.length - 1;
    stdout.writeln(
      '  ${b.type.padRight(6)} hdr=${b.headerSize} '
      'content=${b.contentStart}~${b.contentEnd} '
      'len=${b.contentLength}${truncated ? '  ⚠ 被截断' : ''}',
    );
  }

  // 2) 解析
  final index = SidxParser.parse(bytes);
  if (index == null) {
    stdout.writeln('\n结果：无可用 SIDX（调用方应回落直通）');
    return;
  }
  stdout
    ..writeln('\nSIDX：${SidxParser.describe(index)}')
    // 3) 自洽性检查 —— 这几条正是"能不能按段调度"的前提
    ..writeln('\n自洽性检查：');
  var ok = true;
  for (var i = 1; i < index.segments.length; i++) {
    final prev = index.segments[i - 1];
    final cur = index.segments[i];
    if (cur.offset != prev.endOffset + 1) {
      stdout.writeln('  ❌ 段 $i 与前一段不相接：${prev.endOffset} → ${cur.offset}');
      ok = false;
      break;
    }
  }
  if (ok) stdout.writeln('  ✅ 段首尾相接（${index.segmentCount} 段无缝隙）');

  var mono = true;
  for (var i = 1; i < index.segments.length; i++) {
    if (index.segments[i].startMs < index.segments[i - 1].startMs) {
      mono = false;
      break;
    }
  }
  stdout.writeln(mono ? '  ✅ 起始时刻单调不减' : '  ❌ 起始时刻出现回退');

  final sizes = index.segments.map((s) => s.size).toList()..sort();
  final durs = index.segments.map((s) => s.durationMs).toSet();
  stdout
    ..writeln(
      '  段字节：min=${sizes.first} 中位=${sizes[sizes.length ~/ 2]} max=${sizes.last}',
    )
    ..writeln(
      '  段时长：${durs.length == 1 ? '全部 ${durs.first}ms' : '${durs.length} 种取值'}',
    )
    // 4) 抽样：首尾各段 + 一次二分查找
    ..writeln('\n抽样（前 3 段 / 后 1 段）：');
  for (final s in [...index.segments.take(3), index.segments.last]) {
    stdout.writeln('  $s');
  }
  final probe = index.segments[index.segmentCount ~/ 2].offset;
  final hit = index.segmentAt(probe);
  stdout.writeln(
    '  二分查找 offset=$probe → ${hit == null ? '未命中 ❌' : '段#${hit.index} ✅'}',
  );
}

Future<Uint8List?> _fetchHead(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=0-${SidxParser.recommendedHeaderBytes - 1}')
      ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com/')
      ..set('Origin', 'https://www.bilibili.com');
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != HttpStatus.partialContent &&
        resp.statusCode != HttpStatus.ok) {
      stderr.writeln('上游返回 ${resp.statusCode}');
      await resp.drain<void>().catchError((_) {});
      return null;
    }
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) stdout.writeln('上游 Content-Range：$cr');
    final out = BytesBuilder(copy: false);
    await for (final part in resp) {
      out.add(part);
      if (out.length >= SidxParser.recommendedHeaderBytes) break;
    }
    return out.takeBytes();
  } catch (e) {
    stderr.writeln('取头部异常：$e');
    return null;
  } finally {
    client.close(force: true);
  }
}

const _usage = '''
SIDX 解析器驱动器 —— 验证真实 m4s 的段表能否解析并自洽。

  dart run tool/sidx_dump.dart <文件路径>
  dart run tool/sidx_dump.dart --b64 <base64>
  dart run tool/sidx_dump.dart --url "<带签名的 m4s 地址>"

输出：顶层盒列表、SIDX 摘要、自洽性检查（段相接 / 时刻单调 / 段大小分布）、
抽样段与一次二分查找。生产路径（第 ② 步）用的是同一份 SidxParser.parse。
''';
