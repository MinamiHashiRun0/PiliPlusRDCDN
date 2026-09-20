// CDN/代理诊断页：把每次媒体请求的关键指标摆出来，并支持整段复制。
//
// 这一页是为了回答三个问题，之前只能靠"感觉"猜：
//   1. 代理到底有没有生效？        → 看有没有 [req] 记录、上游请求数
//   2. 瓶颈在网络还是在播放器？    → 看 net（网络耗时）与 speed
//   3. 并发有没有提升？            → 开关代理各看一段 speed 对比
//
// 「复制」拿到的是落盘日志全文，可以直接贴出来。

import 'dart:async';

import 'package:PiliPlus/services/cdn/cdn_debug_log.dart';
import 'package:PiliPlus/services/cdn/cdn_proxy_service.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:material_ui/material_ui.dart';

class CdnDebugPage extends StatefulWidget {
  const CdnDebugPage({super.key});

  @override
  State<CdnDebugPage> createState() => _CdnDebugPageState();
}

class _CdnDebugPageState extends State<CdnDebugPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 每 2 秒刷新一次：播放时观察最有用
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = await CdnDebugLog.export();
    if (!mounted) return;
    await Utils.copyText(
      text.isEmpty ? '日志为空' : text,
      toastText: '已复制 ${text.length} 字符',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    final records = CdnDebugLog.records.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('CDN 诊断'),
        actions: [
          IconButton(
            tooltip: '复制全部日志',
            onPressed: _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: () async {
              await CdnDebugLog.clear();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '代理状态',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(proxyStatusLine()),
                  const SizedBox(height: 12),
                  Text(
                    '最近汇总',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(CdnDebugLog.summary()),
                  const SizedBox(height: 12),
                  Text(
                    '怎么读：net 是代理花在网络取字节上的时间，speed 是折算吞吐。'
                    '关掉代理再播放一次，对比同一位置的 speed —— 如果开代理后 speed 明显更高'
                    '但播放依旧卡，说明瓶颈不在网络（去查解码/渲染/缓冲设置）。',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '单次请求（新→旧，${records.length} 条）',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (records.isEmpty)
                    Text(
                      '暂无记录。请在播放设置里打开「CDN 调试日志」，'
                      '再播放一个视频。',
                      style: TextStyle(color: scheme.outline),
                    )
                  else
                    for (final r in records)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: SelectableText(
                          r.toLine(),
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
