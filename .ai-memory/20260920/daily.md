session-id: 20260920-2315

## [2315] 功能实现: SIDX 分段索引解析器（Phase 2 第 ① 步）
- 文件: lib/services/cdn/sidx_index.dart（新）、test/services/cdn/sidx_index_test.dart（新）、tool/sidx_dump.dart（新）
- 决策: 抛弃"按字节窗口预取"（实测两处 O(n) 热点：ByteBufferIndex._evict 每块全量排序、add 全量重建列表）；改按 SIDX 段表调度
- 关键纠错: SIDX 引用类型位 bit31 语义写反（1=层级引用、0=直接引用）；B 站 377/376 条全为 0，写反导致索引解析为 null；合成盒测试因同错语义而"假绿"，只有真实字节测试能发现
- 验证: test/services/cdn 99 项通过（24 项 SIDX）；analyze 零 error；tool/sidx_dump.dart --url 真实签名地址跑通（242 段、段首尾相接、末段末尾=total-1、二分命中）
- 未完成: ② 接进代理按段预取、③ 段级重试/换节点、④ 面板 N/M 段；待用户裁定

## [2338] 功能实现: 段调度核心（P1 第二步起步）
- 文件: lib/services/cdn/segment_scheduler.dart（新）、test/services/cdn/segment_scheduler_test.dart（新，23 项）
- 决策: 用 SegmentWindow（按段存放，map 索引 O(1)，窗口滑动才丢弃）替代 ByteBufferIndex（每块全量排序 + 全量重建列表 → 用户反馈的性能热点根源）
- 契约: 成功路径必须"先 put 数据再 markFinished"——markFinished 只管在飞/重试计数，"已就绪"由 slot.data 表达；只 finish 不落数据会导致该段被重复下载（单测抓到）
- 验证: 段调度 23 项 + 全套 122 项通过；analyze 零 error
- 重要澄清: 用户反馈 4K 是"性能卡顿+发热"（非缓冲卡顿）→ 这是解码/渲染瓶颈，**P1（网络层）修不了**。已查 preferCodecs 默认 [AVC, AV1]、hwdec 默认 kHwdec，配置本身已偏硬解友好；需设备型号才能定论
- 未完成: 接进 cdn_proxy.dart（替换取数路径）、段级换线路重试、面板 N/M 段、删除旧字节窗口代码

## [2405] 性能验证: 缓冲记账微基准（用户要求"先加这个微基准"）
- 文件: test/services/cdn/proxy_profiler_test.dart（新，11 项）、proxy_core.dart、cdn_proxy.dart、cdn_debug.dart（诊断页新增卡片）
- 插入: CdnProxyProfiler（全局累计 + 最差单次）、RequestProfile（**每请求一个实例**，归集 put/take 增量）、[prof] 日志行（>8ms 标注超半帧预算）
- 关键纠错: evict 计数原本写在 try/finally 里 → "未超限提前返回"也计数，evictCalls 恒等于 add 次数，报告那一行完全没用；改为只在真的丢数据时计数
- **结论（重要）: 记账不是卡顿原因**。实测 512MiB(1024 块) 单次 take 0.051ms / put 0.015ms；碎片 256 段 put 0.045ms；最差单次 evict 2.3ms。相对 16.7ms 帧预算可忽略
- 副产物: ByteBufferIndex 相邻范围会被合并（r.end+1 >= next.start），要留碎片必须留 ≥1 字节空隙——写这类测试的坑
- 验证: test/services/cdn 全套 134 项通过；lib/ analyze 零 issue
- 推论: 之前"两处 O(n) 热点导致卡顿"的判断**被数据否掉**；P1 的价值回到"网络层提速/段级重试"，而不是"修主线程开销"
