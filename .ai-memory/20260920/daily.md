session-id: 20260920-2315

## [2315] 功能实现: SIDX 分段索引解析器（Phase 2 第 ① 步）
- 文件: lib/services/cdn/sidx_index.dart（新）、test/services/cdn/sidx_index_test.dart（新）、tool/sidx_dump.dart（新）
- 决策: 抛弃"按字节窗口预取"（实测两处 O(n) 热点：ByteBufferIndex._evict 每块全量排序、add 全量重建列表）；改按 SIDX 段表调度
- 关键纠错: SIDX 引用类型位 bit31 语义写反（1=层级引用、0=直接引用）；B 站 377/376 条全为 0，写反导致索引解析为 null；合成盒测试因同错语义而"假绿"，只有真实字节测试能发现
- 验证: test/services/cdn 99 项通过（24 项 SIDX）；analyze 零 error；tool/sidx_dump.dart --url 真实签名地址跑通（242 段、段首尾相接、末段末尾=total-1、二分命中）
- 未完成: ② 接进代理按段预取、③ 段级重试/换节点、④ 面板 N/M 段；待用户裁定
