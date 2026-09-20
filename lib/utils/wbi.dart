// B 站 WBI 签名。纯 Dart，不依赖 Flutter —— App 与 tool/cdn_probe.dart 共用一份。
//
// 算法：nav 接口返回 img_url / sub_url，各取文件名，按固定置换表取 32 位得到 mixin key；
// 参数按 key 排序、剔除 !'()* 、追加 wts 后拼成 query，md5(query + mixinKey) 即 w_rid。
//
// ignore_for_file: avoid_print

import 'dart:convert';

/// 置换表（B 站前端 JS 里的 mixinKeyEncTab，与 yujincheng08/BiliRoaming 一致）。
const _mixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

/// 由 img_url / sub_url 推出 mixin key。
String mixinKey(String imgUrl, String subUrl) {
  final raw = '${_fileName(imgUrl)}${_fileName(subUrl)}';
  final picked = StringBuffer();
  for (final i in _mixinKeyEncTab) {
    if (i < raw.length) picked.write(raw[i]);
  }
  final s = picked.toString();
  return s.length >= 32 ? s.substring(0, 32) : s;
}

/// 给参数加上 wts 与 w_rid。不修改入参。
Map<String, String> wbiSign(
  Map<String, String> params, {
  required String imgUrl,
  required String subUrl,
  int? timestampSeconds,
}) {
  final signed = Map<String, String>.from(params)
    ..['wts'] = '${timestampSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}';
  final keys = signed.keys.toList()..sort();
  final query = keys.map((k) => '${_enc(k)}=${_enc(_filter(signed[k]!))}').join('&');
  return signed..['w_rid'] = md5Hex('$query${mixinKey(imgUrl, subUrl)}');
}

/// 把参数拼成查询串（含 wts / w_rid 时直接可用）。
String encodeQuery(Map<String, String> params) =>
    params.entries.map((e) => '${_enc(e.key)}=${_enc(e.value)}').join('&');

/// 查询串编码：空格用 %20（不是 +），与 B 站自己的签名实现保持一致。
String _enc(String value) =>
    Uri.encodeQueryComponent(value).replaceAll('+', '%20');

String _fileName(String url) {
  final name = url.split('/').last;
  final dot = name.indexOf('.');
  return dot == -1 ? name : name.substring(0, dot);
}

/// WBI 要求剔除 !'()* 这几个字符。
String _filter(String value) => value.replaceAll(RegExp(r"[!'()*]"), '');

/// MD5（十六进制小写）。为签名自带实现，避免引入 crypto 依赖。
String md5Hex(String input) => md5Bytes(utf8.encode(input));

/// 字节版 MD5，给确实要按字节算的场景。
String md5Bytes(List<int> bytes) {
  const s = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  const k = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
    0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
    0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
    0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
    0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
    0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  final message = List<int>.from(bytes)..add(0x80);
  while (message.length % 64 != 56) {
    message.add(0);
  }
  final bitLen = bytes.length * 8;
  for (var i = 0; i < 8; i++) {
    message.add((bitLen >> (8 * i)) & 0xff);
  }

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;

  for (var chunk = 0; chunk < message.length; chunk += 64) {
    final m = List<int>.generate(
      16,
      (i) =>
          message[chunk + i * 4] |
          (message[chunk + i * 4 + 1] << 8) |
          (message[chunk + i * 4 + 2] << 16) |
          (message[chunk + i * 4 + 3] << 24),
    );
    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + k[i] + m[g]) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl(f, s[i])) & 0xffffffff;
    }
    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }

  final out = StringBuffer();
  for (final v in [a0, b0, c0, d0]) {
    for (var i = 0; i < 4; i++) {
      out.write(((v >> (8 * i)) & 0xff).toRadixString(16).padLeft(2, '0'));
    }
  }
  return out.toString();
}

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;
