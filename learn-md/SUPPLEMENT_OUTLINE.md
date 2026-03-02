# JRaft 源码学习 — 补充章节大纲

> 本文档列出 01-12 章节尚未覆盖的核心源码模块，按优先级排序，后续逐一攻破。
>
> 每个补充章节严格遵循 [[memory:592bhmre]] 中的 29 条源码阅读规则。

---

## 📊 补充章节总览

| 编号 | 补充主题 | 归属位置 | 核心源码文件 | 代码量 | 优先级 |
|------|---------|---------|-------------|--------|--------|
| S1 | RocksDBSegmentLogStorage 新一代日志引擎 | 新增 05b 章节 | `RocksDBSegmentLogStorage.java` (47.6KB) + `SegmentFile.java` (30.7KB) + `CheckpointFile.java` (3.8KB) + `AbortFile.java` (2KB) | **~84KB** | **P0** |
| S2 | LocalRaftMetaStorage — term/votedFor 持久化 | 补入 02 章节 | `LocalRaftMetaStorage.java` (6KB) | ~6KB | **P0** |
| S3 | LogEntry 编解码器（V1/V2） | 补入 05 章节 | `V2Encoder.java` (5.4KB) + `V2Decoder.java` (4.5KB) + `V1Encoder.java` (4.5KB) + `V1Decoder.java` (4KB) + `AutoDetectDecoder.java` (1.7KB) + `LogEntryCodecFactory` 体系 | **~25KB** | **P1** |
| S4 | Transfer Leadership 完整流程 | 补入 03 章节 | `NodeImpl.transferLeadershipTo()` (行 3235) + `NodeImpl.handleTimeoutNowRequest()` (行 3310) | ~200 行 | **P1** |
| S5 | Learner 角色机制 | 补入 09 章节 | `NodeImpl.addLearners/removeLearners/resetLearners` (行 3142-3190) + `Configuration.learners` | ~150 行 | **P1** |
| S6 | gRPC RPC 实现（对比 Bolt） | 补入 10 章节 | `GrpcClient.java` (13KB) + `GrpcServer.java` (9.8KB) + `GrpcRaftRpcFactory.java` (5.6KB) + 7 个辅助类 | **~43KB** | **P2** |
| S7 | RheaKV Placement Driver（调度中心） | 新增 13 章节 | `PlacementDriverServer.java` (14.4KB) + `DefaultPlacementDriverService.java` (15KB) + `DefaultMetadataStore.java` (13KB) + pipeline 处理器链 | **~80KB** | **P2** |
| S8 | Bootstrap 集群引导流程 | 补入 02 章节 | `NodeImpl.bootstrap()` (行 797) + `BootstrapOptions` | ~100 行 | **P3** |
| S9 | 节点优雅停机（shutdown/destroy）| 补入 02 章节 | `NodeImpl.shutdown()` + `NodeImpl.join()` + 各组件 shutdown 链 | ~300 行 | **P1** |
| S10 | 远程快照拷贝（RemoteFileCopier + CopySession）| 补入 06 章节 | `RemoteFileCopier.java` (6.8KB) + `CopySession.java` (10.8KB) + `ThroughputSnapshotThrottle.java` (3.5KB) | **~21KB** | **P1** |
| S11 | SPI 扩展机制 + JRaftServiceFactory 体系 | 补入 02 章节或新增小节 | `JRaftServiceLoader.java` (12.7KB) + `JRaftServiceFactory.java` (2.3KB) + `DefaultJRaftServiceFactory.java` (2.9KB) + `StorageOptionsFactory.java` (17.5KB) | **~35KB** | **P2** |
| S12 | HashedWheelTimer 时间轮实现 | 补入 11 章节 | `HashedWheelTimer.java` (31KB) + `DefaultRaftTimerFactory.java` (9.9KB) + `Timer/Timeout/TimerTask` 接口 | **~48KB** | **P2** |
| S13 | Protobuf 协议定义与消息结构 | 新增附录 | `raft.proto` + `rpc.proto` + `cli.proto` + `log.proto` + `local_storage.proto` + `enum.proto` + `local_file_meta.proto` | **~7个proto文件** | **P2** |
| S14 | 端到端写入链路（Node.apply → 状态机回调） | 新增专题文档 | 横跨 `NodeImpl.apply()` → `LogManager` → `Replicator` → `BallotBox` → `FSMCaller` | 横跨全模块 | **P1** |
| S15 | BDB 日志存储扩展实现 | 补入 05 章节 | `BDBLogStorage.java` (19.2KB) | **~19KB** | **P3** |
| S16 | NodeOptions/RaftOptions 配置项全解 | 新增附录或补入 01 章节 | `NodeOptions.java` (17.4KB) + `RaftOptions.java` (13KB) | **~30KB** | **P2** |

---

## S1：RocksDBSegmentLogStorage — 新一代日志存储引擎 【P0】

### 归属：新增 `05b-segment-log-storage/README.md`

### 为什么 P0

这是 JRaft 通过 RFC-0001 引入的**新一代日志存储引擎**，解决了旧版 `RocksDBLogStorage` 在生产环境中的核心痛点：
- 旧版把日志 value（可能很大）直接写入 RocksDB，导致 LSM Compaction 放大
- 新版将 **日志数据（data）** 写入自管理的 `SegmentFile`（基于 mmap），**RocksDB 只存索引**
- 总代码量 84KB，比旧版 27KB 复杂 3 倍

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `RocksDBSegmentLogStorage.java` | 47.6KB | 新日志存储引擎主类，继承 `RocksDBLogStorage` |
| `SegmentFile.java` | 30.7KB | 段文件管理：mmap 映射、日志读写、文件滚动 |
| `CheckpointFile.java` | 3.8KB | 检查点文件：记录已刷盘位置 |
| `AbortFile.java` | 2KB | 异常退出标记文件 |
| `LibC.java` | 1.9KB | JNI 调用 Linux madvise/sync |

### 分析大纲

```
1. 问题推导：旧版 RocksDBLogStorage 有什么生产痛点？
   - 大 value 写入 RocksDB → LSM Compaction 写放大
   - 推导出"数据和索引分离"的设计思路

2. 核心数据结构
   2.1 RocksDBSegmentLogStorage 字段分析（对比旧版新增了什么）
   2.2 SegmentFile 字段分析
       - mmap 映射管理（MappedByteBuffer）
       - 文件头格式 + 日志条目格式
       - 写位置、提交位置、文件大小
   2.3 CheckpointFile 格式
   2.4 AbortFile 的作用

3. 写入流程
   3.1 appendEntry() 的新路径：先写 SegmentFile，再写 RocksDB 索引
   3.2 SegmentFile.write() 的 mmap 写入 + fsync 策略
   3.3 文件滚动（roll）策略：什么时候创建新的 SegmentFile？
   3.4 与旧版 appendEntry() 的横向对比

4. 读取流程
   4.1 getEntry() 的新路径：RocksDB 查索引 → SegmentFile 读数据
   4.2 SegmentFile.read() 的 mmap 读取
   4.3 与旧版 getEntry() 的横向对比

5. 截断流程
   5.1 truncatePrefix()（日志压缩）
   5.2 truncateSuffix()（日志回滚）
   5.3 SegmentFile 的生命周期管理

6. 恢复流程
   6.1 启动时如何从 CheckpointFile 恢复？
   6.2 AbortFile 检测异常退出并触发恢复
   6.3 SegmentFile 的完整性校验

7. 并发设计
   7.1 读写锁策略对比旧版
   7.2 mmap 的线程安全性分析

8. 面试高频考点 📌
   - 为什么要做数据和索引分离？
   - mmap vs FileChannel 的 trade-off
   - SegmentFile 滚动策略对写入延迟的影响

9. 生产踩坑 ⚠️
   - mmap 的内存占用和 OOM 风险
   - 文件数过多时的 fd 限制
```

---

## S2：LocalRaftMetaStorage — term/votedFor 持久化 【P0】

### 归属：补入 `02-node-lifecycle/README.md` 新增第 N 节

### 为什么 P0

Raft 论文 Figure 2 明确要求 `currentTerm` 和 `votedFor` 必须持久化。这个模块虽然只有 6KB，但回答了一个关键问题：**节点重启后怎么知道自己当前的 term 和投给了谁？**

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `LocalRaftMetaStorage.java` | 6KB | 基于 Protobuf 序列化的本地元数据存储 |

### 分析大纲

```
1. 问题推导
   - Raft 论文要求持久化哪些状态？→ currentTerm + votedFor
   - 如果不持久化会发生什么？→ 重启后可能投两次票，破坏选举安全性
   - 需要什么样的存储？→ 原子写入、crash-safe

2. 核心数据结构
   2.1 字段分析：path、term、votedFor、raftMetaFile
   2.2 Protobuf 序列化格式（StablePBMeta）

3. 核心方法
   3.1 init() — 从文件加载 term 和 votedFor
   3.2 setTermAndVotedFor() — 原子写入
   3.3 save() — 序列化 + 写文件 + fsync
   3.4 异常路径：文件损坏怎么处理？

4. 与 NodeImpl 的交互
   4.1 init() 时从 MetaStorage 恢复 term/votedFor
   4.2 投票时（votedFor 变更）调用 setTermAndVotedFor()
   4.3 term 变更时调用 setTermAndVotedFor()

5. 面试考点 📌
   - 为什么 term 和 votedFor 必须持久化？
   - 写入是否需要 fsync？不 fsync 会怎样？
```

---

## S3：LogEntry 编解码器（V1/V2） 【P1】

### 归属：补入 `05-log-storage/README.md` 新增第 N 节

### 为什么 P1

LogEntry 编解码器是日志从内存对象到磁盘字节流的桥梁，也是跨版本兼容性的关键设计。

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `LogEntryEncoder.java` | 1.1KB | 编码器接口 |
| `LogEntryDecoder.java` | 1.2KB | 解码器接口 |
| `LogEntryCodecFactory.java` | 1.2KB | 工厂接口 |
| `DefaultLogEntryCodecFactory.java` | 1.9KB | 默认工厂实现 |
| `V1Encoder.java` | 4.5KB | V1 编码器（旧版） |
| `V1Decoder.java` | 4KB | V1 解码器（旧版） |
| `V2Encoder.java` | 5.4KB | V2 编码器（基于 Protobuf） |
| `V2Decoder.java` | 4.5KB | V2 解码器（基于 Protobuf） |
| `AutoDetectDecoder.java` | 1.7KB | 自动版本检测解码器 |
| `LogOutter.java` | 63.7KB | Protobuf 生成的 V2 消息类 |

### 分析大纲

```
1. 问题推导
   - LogEntry 包含哪些字段需要序列化？→ type, term, index, peers, data, checksum
   - 为什么需要 V1 和 V2 两个版本？→ 版本演进 + 向后兼容
   - 如何自动识别旧版日志？→ AutoDetectDecoder

2. 工厂模式设计
   2.1 LogEntryCodecFactory 接口
   2.2 DefaultLogEntryCodecFactory → V2 + AutoDetectDecoder 的组合
   2.3 LogEntryV1CodecFactory / LogEntryV2CodecFactory

3. V1 编码格式（逐字节分析）
   3.1 V1Encoder.encode() 的字节布局
   3.2 V1Decoder.decode() 的解析流程

4. V2 编码格式（Protobuf）
   4.1 V2Encoder.encode() — 构建 PBLogEntry
   4.2 V2Decoder.decode() — 解析 PBLogEntry
   4.3 LogOutter.proto 定义的消息结构

5. AutoDetectDecoder — 版本自动检测
   5.1 如何通过 magic number 区分 V1/V2？
   5.2 为什么解码器需要自动检测，而编码器不需要？

6. V1 vs V2 横向对比
   | 维度 | V1 | V2 |
   |------|----|----|
   | 序列化方式 | 手工字节操作 | Protobuf |
   | 扩展性 | 差 | 好 |
   | 性能 | ? | ? |
   | 向后兼容 | - | 通过 AutoDetectDecoder |

7. 面试考点 📌
   - 为什么 JRaft 选择 Protobuf 做 V2 编码？
   - AutoDetectDecoder 的设计模式是什么？
```

---

## S4：Transfer Leadership 完整流程 【P1】

### 归属：补入 `03-leader-election/README.md` 新增第 N 节

### 为什么 P1

Transfer Leadership 是**运维场景最常用的操作**（滚动升级时迁移 Leader），当前文档仅在面试考点中一笔带过。

### 核心源码位置

| 方法 | 位置 | 职责 |
|------|------|------|
| `NodeImpl.transferLeadershipTo()` | `NodeImpl.java:3235` | Leader 端：发起转移 |
| `NodeImpl.handleTimeoutNowRequest()` | `NodeImpl.java:3310` | 目标节点：收到 TimeoutNow 后立即选举 |
| `Replicator.sendTimeoutNow()` | `Replicator.java` | 通过 Replicator 发送 TimeoutNowRequest |
| `NodeImpl.onTransferTimeout()` | `NodeImpl.java` | 转移超时处理 |

### 分析大纲

```
1. 问题推导
   - 为什么需要 Transfer Leadership？→ 滚动升级、负载均衡
   - 直接 stepDown 让重新选举行不行？→ 不行，不能保证目标节点当选
   - 设计思路：Leader 停止接受新写入 → 等目标节点日志追上 → 发 TimeoutNow → 目标节点立即选举

2. 完整时序图（Mermaid sequenceDiagram）
   Client → Leader.transferLeadershipTo(targetPeer)
   Leader → Leader: 检查 target 是否在 conf 中
   Leader → Leader: 设置 STATE_TRANSFERRING，停止接受 apply
   Leader → Replicator: 检查 target 日志是否已追上
   alt 已追上
     Leader → Target: sendTimeoutNow()
   else 未追上
     Leader → Target: 继续发 AppendEntries 等追上
   end
   Target → Target: handleTimeoutNowRequest() → 跳过 preVote，直接 electSelf()
   Target → Cluster: RequestVote
   Target → Target: 成为新 Leader

3. transferLeadershipTo() 逐行分析
   3.1 前置检查（分支穷举清单）
   3.2 设置 stopTransferArg
   3.3 超时定时器
   3.4 调用 Replicator.sendTimeoutNowAndStop() / 等日志追上

4. handleTimeoutNowRequest() 逐行分析
   4.1 分支穷举清单
   4.2 为什么跳过 PreVote？
   4.3 直接调用 electSelf()

5. 超时处理
   5.1 onTransferTimeout() — 超时后恢复 Leader 状态
   5.2 STATE_TRANSFERRING 期间拒绝 apply 的机制

6. 面试考点 📌
   - Transfer Leadership 和 stepDown 有什么区别？
   - 为什么目标节点可以跳过 PreVote？
   - Transfer 超时会发生什么？

7. 生产踩坑 ⚠️
   - 目标节点日志落后太多导致 Transfer 超时
   - Transfer 期间集群短暂不可写
```

---

## S5：Learner 角色机制 【P1】

### 归属：补入 `09-membership-change/README.md` 新增第 N 节

### 为什么 P1

Learner 是 Raft 的常见扩展角色（只接收日志不参与投票），用于读扩展和数据同步场景。

### 核心源码位置

| 方法/类 | 位置 | 职责 |
|---------|------|------|
| `NodeImpl.addLearners()` | `NodeImpl.java:3142` | 添加 Learner 节点 |
| `NodeImpl.removeLearners()` | `NodeImpl.java:3166` | 移除 Learner 节点 |
| `NodeImpl.resetLearners()` | `NodeImpl.java:3181` | 重置 Learner 列表 |
| `Configuration.learners` | `Configuration.java` | 配置中的 Learner 集合 |
| `Replicator` | `Replicator.java` | Learner 的日志复制也走 Replicator |

### 分析大纲

```
1. 问题推导
   - 什么场景需要只读副本？→ 读扩展、异地数据同步、新节点预热
   - Learner 和 Follower 的区别？→ 不参与投票、不影响 Quorum

2. Configuration 中 Learner 的存储
   2.1 learners 字段的类型和初始化
   2.2 Learner 和 Peer 的关系

3. addLearners / removeLearners / resetLearners 逐行分析
   3.1 分支穷举清单
   3.2 这些操作是否需要走日志复制？（对比 addPeer/removePeer）

4. Learner 的日志复制路径
   4.1 Replicator 创建时如何区分 Follower 和 Learner？
   4.2 Learner 的 AppendEntries 响应是否影响 BallotBox 的 Quorum 判定？

5. Learner 在选举中的行为
   5.1 Learner 是否参与 PreVote / Vote？
   5.2 Learner 能否被 Transfer Leadership 的目标？

6. 面试考点 📌
   - Learner 和 Follower 的核心区别？
   - 新增 Learner 是否会影响集群可用性？
   - Learner 如何升级为 Follower（投票成员）？
```

---

## S6：gRPC RPC 实现（对比 Bolt） 【P2】

### 归属：补入 `10-rpc-layer/README.md` 新增第 N 节

### 为什么 P2

gRPC 是 JRaft 通过 SPI 扩展支持的第二种 RPC 框架，在云原生环境中越来越常用。10 章只分析了 Bolt 实现。

### 核心源码文件（`jraft-extension/rpc-grpc-impl/`）

| 文件 | 大小 | 职责 |
|------|------|------|
| `GrpcClient.java` | 13.2KB | gRPC 客户端封装 |
| `GrpcServer.java` | 9.8KB | gRPC 服务端封装 |
| `GrpcRaftRpcFactory.java` | 5.6KB | SPI 工厂：创建 gRPC 的 Client/Server |
| `MarshallerHelper.java` | 3.7KB | Protobuf 序列化辅助 |
| `MarshallerRegistry.java` | 1.4KB | 序列化注册表 |
| `ManagedChannelHelper.java` | 2.7KB | Channel 管理 |
| `GrpcServerHelper.java` | 2.6KB | Server 辅助工具 |
| `GrpcResponseFactory.java` | 2.2KB | 响应工厂 |
| `ConnectionInterceptor.java` | 2.4KB | 连接拦截器 |
| `RemoteAddressInterceptor.java` | 1.9KB | 远程地址拦截器 |

### 分析大纲

```
1. SPI 扩展机制
   1.1 RaftRpcFactory SPI 接口
   1.2 GrpcRaftRpcFactory 如何通过 SPI 被加载
   1.3 Bolt vs gRPC 的切换方式

2. GrpcServer 核心逻辑
   2.1 Server 启动流程
   2.2 请求处理：gRPC ServiceDefinition 如何映射到 RpcProcessor
   2.3 Interceptor 链

3. GrpcClient 核心逻辑
   3.1 ManagedChannel 管理（连接池？复用？）
   3.2 请求发送：同步/异步
   3.3 超时和重试

4. 序列化差异
   4.1 Bolt 使用 Hessian/自定义序列化
   4.2 gRPC 使用 Protobuf 的 Marshaller 体系
   4.3 MarshallerRegistry 的注册机制

5. Bolt vs gRPC 横向对比

   | 维度 | Bolt | gRPC |
   |------|------|------|
   | 序列化 | Hessian / 自定义 | Protobuf |
   | 传输协议 | 自定义协议 | HTTP/2 |
   | 连接模型 | 长连接 + 心跳 | ManagedChannel |
   | 流式传输 | 不支持 | 支持 |
   | 云原生兼容 | 差 | 好 |
   | 性能 | ? | ? |

6. 面试考点 📌
   - JRaft 如何通过 SPI 支持多种 RPC 框架？
   - gRPC 的 HTTP/2 多路复用对 Raft 通信的影响？
```

---

## S7：RheaKV Placement Driver（调度中心） 【P2】

### 归属：新增 `13-rheakv-pd/README.md`

### 为什么 P2

PD 是分布式 KV 的**调度大脑**（类比 TiKV 的 PD），负责元数据管理、Region 负载均衡、自动分裂。12 章只分析了 rheakv-core，缺了 PD 架构图不完整。

### 核心源码文件（`jraft-rheakv/rheakv-pd/`）

| 文件 | 大小 | 职责 |
|------|------|------|
| `PlacementDriverServer.java` | 14.4KB | PD 服务端主类 |
| `DefaultPlacementDriverService.java` | 15KB | PD 核心服务实现 |
| `DefaultMetadataStore.java` | 13KB | 元数据存储（基于 Raft） |
| `ClusterStatsManager.java` | 6.9KB | 集群状态统计 |
| `PlacementDriverProcessor.java` | 4.8KB | PD RPC 处理器 |
| **pipeline 处理器链** | | |
| `RegionLeaderBalanceHandler.java` | 7.5KB | Region Leader 负载均衡 |
| `SplittingJudgeByApproximateKeysHandler.java` | 4.2KB | Region 自动分裂判断 |
| `RegionStatsValidator.java` | 4.3KB | Region 状态校验 |
| `StoreStatsValidator.java` | 2.9KB | Store 状态校验 |
| `RegionStatsPersistenceHandler.java` | 1.8KB | Region 状态持久化 |
| `StoreStatsPersistenceHandler.java` | 1.8KB | Store 状态持久化 |
| `LogHandler.java` | 1.5KB | 日志处理 |
| `PlacementDriverTailHandler.java` | 1.9KB | Pipeline 尾处理器 |

### 分析大纲

```
1. 问题推导
   - 多 Region 的 KV 存储需要谁来管理元数据？→ PD
   - Region 负载不均怎么办？→ Leader 迁移
   - Region 数据量过大怎么办？→ 自动分裂
   - PD 自身高可用怎么保证？→ 基于 Raft

2. 整体架构（Mermaid 图）
   - PD Server ←→ StoreEngine 的心跳交互
   - PD 内部 Pipeline 处理链

3. PlacementDriverServer 启动与初始化
   3.1 内嵌 Raft Group 保证 PD 自身高可用
   3.2 RPC 处理器注册

4. 心跳机制
   4.1 Store 心跳（StorePingEvent）
   4.2 Region 心跳（RegionPingEvent）
   4.3 PongEvent 响应中携带的调度指令

5. Pipeline 处理器链（核心）
   5.1 StoreStatsValidator → RegionStatsValidator → 持久化 → 均衡/分裂判断 → TailHandler
   5.2 RegionLeaderBalanceHandler — Leader 均衡算法
   5.3 SplittingJudgeByApproximateKeysHandler — 分裂判断算法

6. 元数据管理
   6.1 DefaultMetadataStore — 基于 Raft 的元数据存储
   6.2 Store/Region 元数据的 CRUD

7. 与 TiKV PD 的横向对比

8. 面试考点 📌
   - PD 如何保证自身高可用？
   - Region 分裂的判断条件是什么？
   - Leader 均衡的策略是什么？
```

---

## S8：Bootstrap 集群引导流程 【P3】

### 归属：补入 `02-node-lifecycle/README.md` 新增第 N 节

### 为什么 P3

Bootstrap 是部署 JRaft 集群的第一步操作，虽然是一次性操作，但理解它有助于完整理解节点启动链路。

### 核心源码位置

| 方法 | 位置 | 职责 |
|------|------|------|
| `NodeImpl.bootstrap()` | `NodeImpl.java:797` | 从空状态引导集群 |
| `BootstrapOptions` | `option/BootstrapOptions.java` | 引导配置项 |

### 分析大纲

```
1. 问题推导
   - 集群第一次启动时，没有任何日志和元数据，怎么初始化？
   - Bootstrap 和 init() 的区别？

2. BootstrapOptions 字段分析

3. bootstrap() 逐行分析
   3.1 分支穷举清单
   3.2 写入初始 Configuration 到日志
   3.3 写入初始元数据（term=0, votedFor=empty）
   3.4 生成初始快照（如果有 FSM）

4. bootstrap 与 init 的关系
   4.1 调用顺序：先 bootstrap 再 init
   4.2 bootstrap 后的状态：日志中有一条 CONFIGURATION 类型的 entry

5. 面试考点 📌
   - Bootstrap 只需要执行一次还是每次启动？
   - Bootstrap 执行完后集群处于什么状态？
```

---

## S9：节点优雅停机（shutdown / destroy） 【P1】

### 归属：补入 `02-node-lifecycle/README.md` 新增第 N 节

### 为什么 P1

02 章节只分析了 `init()` 启动链路，但**没有分析 `shutdown()` / `join()` 停机链路**。节点停机是请求生命周期的终点，涉及所有组件的有序关闭、资源释放、线程池停止，是生产运维的核心操作。文档中搜索 `shutdown` / `destroy` 在编号章节中**零结果**。

### 核心源码位置

| 方法 | 位置 | 职责 |
|------|------|------|
| `NodeImpl.shutdown()` | `NodeImpl.java` | 触发停机：状态切换 + 各组件 shutdown |
| `NodeImpl.join()` | `NodeImpl.java` | 等待停机完成 |
| `RaftGroupService.shutdown()` | `RaftGroupService.java` | 上层封装：RPC Server + Node 的停机 |
| 各组件 `shutdown()` | `LogManagerImpl` / `FSMCallerImpl` / `SnapshotExecutorImpl` / `ReadOnlyServiceImpl` / `ReplicatorGroup` 等 | 组件级停机 |

### 分析大纲

```
1. 问题推导
   - 节点停机时需要关闭哪些组件？关闭顺序是什么？
   - 正在进行中的 apply / 复制 / 快照怎么处理？
   - 如何保证"不丢数据"和"不泄露资源"？

2. shutdown() 完整调用链
   2.1 NodeImpl.shutdown(done) 逐行分析
   2.2 状态切换：STATE_SHUTTING → STATE_SHUTDOWN
   2.3 各组件 shutdown 的调用顺序（关键：先停 Timer，再停 Replicator，最后停 LogManager）
   2.4 shutdownLatch 的使用

3. join() 的等待机制

4. 各组件的 shutdown 细节
   4.1 ReplicatorGroup.stopAll()
   4.2 FSMCallerImpl.shutdown()
   4.3 LogManagerImpl.shutdown()
   4.4 SnapshotExecutorImpl.shutdown()
   4.5 ReadOnlyServiceImpl.shutdown()

5. 异常路径
   5.1 shutdown 过程中新的 RPC 请求怎么处理？
   5.2 shutdown 超时怎么办？
   5.3 重复调用 shutdown 是否安全（幂等性）？

6. 面试考点 📌
   - JRaft 节点停机的组件关闭顺序是什么？为什么是这个顺序？
   - shutdown 和 destroy 的区别？

7. 生产踩坑 ⚠️
   - shutdown 后未调用 join 导致资源泄露
   - 滚动升级时 shutdown 顺序不当导致数据丢失
```

---

## S10：远程快照拷贝（RemoteFileCopier + CopySession） 【P1】

### 归属：补入 `06-snapshot/README.md` 新增第 N 节

### 为什么 P1

06 章节分析了 `LocalSnapshotCopier` 的整体流程，但**没有深入 `RemoteFileCopier` 和 `CopySession` 的分块传输细节**。在文档中搜索 `CopySession` / `RemoteFileCopier` **零结果**。远程快照拷贝是跨网络传输大文件（可能数 GB）的核心逻辑，涉及分块、重试、限流。

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `RemoteFileCopier.java` | 6.8KB | 远程文件拷贝器：建立连接、创建 CopySession |
| `CopySession.java` | 10.8KB | 单个文件的拷贝会话：分块请求、重试、写入本地 |
| `Session.java` | 1.4KB | 拷贝会话接口 |
| `ThroughputSnapshotThrottle.java` | 3.5KB | 吞吐量限流器 |
| `SnapshotFileReader.java` | 3.6KB | Leader 端的文件读取器 |
| `FileService.java` | 6.1KB | Leader 端的文件服务（处理 GetFileRequest）|

### 分析大纲

```
1. 问题推导
   - 快照文件可能很大（数 GB），如何跨网络传输？→ 分块传输
   - 传输中网络抖动怎么办？→ 重试机制
   - 传输速度过快影响正常 Raft 通信怎么办？→ 限流

2. RemoteFileCopier 核心逻辑
   2.1 init() — 解析远端地址、建立 RPC 连接
   2.2 copyToFile() — 创建 CopySession 并启动拷贝

3. CopySession 分块传输（核心）
   3.1 sendNextRpc() — 发送 GetFileRequest（offset + count）
   3.2 onRpcReturned() — 接收响应、写入本地文件、判断是否继续
   3.3 分块大小的确定（RaftOptions.maxByteCountPerRpc）
   3.4 重试逻辑：失败后怎么重试？最多重试几次？
   3.5 完成判断：如何知道文件已传输完毕？（EOF 标记）

4. FileService（Leader 端）
   4.1 handleGetFile() — 读取文件块并返回
   4.2 SnapshotFileReader — 打开快照目录中的文件

5. ThroughputSnapshotThrottle 限流器
   5.1 限流算法（令牌桶 / 滑动窗口？）
   5.2 throttledByThroughput() 的调用时机

6. 面试考点 📌
   - 快照传输的分块大小如何配置？
   - 传输过程中 Leader 宕机怎么办？
   - 限流器如何平衡"快照传输速度"和"正常 Raft 通信"？

7. 生产踩坑 ⚠️
   - 大快照传输时间过长导致选举超时
   - 限流参数设置不当导致新节点加入速度极慢
```

---

## S11：SPI 扩展机制 + JRaftServiceFactory 体系 【P2】

### 归属：补入 `02-node-lifecycle/README.md` 或新增附录

### 为什么 P2

JRaft 的可扩展性依赖 `JRaftServiceFactory` SPI 体系——LogStorage、RaftMetaStorage、SnapshotStorage、LogEntryCodecFactory 等核心组件都通过工厂模式创建。文档中搜索 `JRaftServiceLoader` / `SPI` **零结果**。理解 SPI 机制才能理解"如何切换日志存储引擎"、"如何切换 RPC 框架"。

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `JRaftServiceLoader.java` | 12.7KB | JRaft 自定义的 SPI 加载器（增强版 ServiceLoader）|
| `JRaftServiceFactory.java` | 2.3KB | 核心组件工厂接口 |
| `DefaultJRaftServiceFactory.java` | 2.9KB | 默认工厂实现 |
| `RaftServiceFactory.java` | 2.4KB | Raft 服务工厂（已弃用，指向 JRaftServiceFactory）|
| `StorageOptionsFactory.java` | 17.5KB | RocksDB 配置选项工厂 |
| `RaftRpcFactory.java` | 3.1KB | RPC 工厂 SPI 接口 |
| `RpcFactoryHelper.java` | 1.3KB | RPC 工厂辅助 |

### 分析大纲

```
1. 问题推导
   - JRaft 如何支持"不同用户使用不同的存储引擎"？→ SPI
   - JRaft 如何支持"Bolt 和 gRPC 两种 RPC 框架切换"？→ SPI
   - Java 原生 ServiceLoader 有什么不足？→ JRaftServiceLoader 的增强

2. JRaftServiceFactory 接口设计
   2.1 createLogStorage() / createRaftMetaStorage() / createSnapshotStorage()
   2.2 createLogEntryCodecFactory()
   2.3 DefaultJRaftServiceFactory 的默认实现

3. JRaftServiceLoader — 增强版 SPI 加载器
   3.1 与 Java ServiceLoader 的区别
   3.2 SPI 注解 @SPI 和优先级排序
   3.3 META-INF/services/ 注册文件

4. RaftRpcFactory SPI
   4.1 BoltRaftRpcFactory vs GrpcRaftRpcFactory
   4.2 RpcFactoryHelper.rpcFactory() 的懒加载

5. StorageOptionsFactory
   5.1 RocksDB 配置项的集中管理
   5.2 默认 ColumnFamily 配置
   5.3 用户自定义配置的覆盖机制

6. 面试考点 📌
   - JRaft 如何实现存储引擎的可插拔？
   - 如何自定义一个 LogStorage 实现并接入 JRaft？
```

---

## S12：HashedWheelTimer 时间轮实现 【P2】

### 归属：补入 `11-concurrency-infra/README.md` 新增第 N 节

### 为什么 P2

11 章提到了"底层使用 HashedWheelTimer"，但没有分析其实现。JRaft **自带了一个 31KB 的完整时间轮实现**（非 Netty 的），是选举超时、心跳超时、快照定时器等所有定时任务的底层引擎。文档中搜索 `HashedWheelTimer` 在 11 章中仅作为一句话提及，没有任何实现分析。

### 核心源码文件

| 文件 | 大小 | 职责 |
|------|------|------|
| `HashedWheelTimer.java` | 31KB | 时间轮核心实现 |
| `Timer.java` | 2KB | 定时器接口 |
| `Timeout.java` | 1.7KB | 超时任务句柄接口 |
| `TimerTask.java` | 1.1KB | 定时任务接口 |
| `DefaultTimer.java` | 3.9KB | 基于 ScheduledExecutorService 的对比实现 |
| `DefaultRaftTimerFactory.java` | 9.9KB | Raft 定时器工厂（选举/心跳/快照/stepDown 等）|
| `RaftTimerFactory.java` | 1.4KB | 定时器工厂接口 |

### 分析大纲

```
1. 问题推导
   - Raft 有大量定时任务（选举超时、心跳、快照），需要什么样的定时器？
   - ScheduledExecutorService 有什么问题？→ 大量定时任务时性能差
   - 时间轮如何做到 O(1) 的任务添加和触发？

2. HashedWheelTimer 核心数据结构
   2.1 wheel 数组（HashedWheelBucket[]）
   2.2 tick 游标
   2.3 tickDuration / ticksPerWheel
   2.4 Worker 线程

3. 核心方法
   3.1 newTimeout() — 添加定时任务
   3.2 Worker.run() — tick 推进 + 任务触发
   3.3 HashedWheelBucket — 桶内链表遍历

4. DefaultRaftTimerFactory — Raft 定时器工厂
   4.1 创建选举定时器（electionTimer）
   4.2 创建心跳定时器（voteTimer）
   4.3 创建快照定时器（snapshotTimer）
   4.4 为什么不同类型的定时器用不同的时间轮实例？

5. HashedWheelTimer vs DefaultTimer（ScheduledExecutorService）横向对比

6. 面试考点 📌
   - 时间轮的时间复杂度是多少？
   - JRaft 为什么不用 Netty 的 HashedWheelTimer？
   - tickDuration 设置过大/过小的影响？
```

---

## S13：Protobuf 协议定义与消息结构 【P2】

### 归属：新增附录 `appendix-protobuf-protocol/README.md`

### 为什么 P2

JRaft 所有 RPC 通信的消息结构都定义在 `.proto` 文件中，但文档中搜索 `.proto` / `protobuf` / `Protobuf` **零结果**。理解协议定义是理解 RPC 请求/响应结构的前提。

### 核心源码文件

| 文件 | 职责 |
|------|------|
| `raft.proto` | 核心 Raft RPC 消息：AppendEntries / RequestVote / InstallSnapshot 等 |
| `rpc.proto` | 通用 RPC 消息：PingRequest / ErrorResponse / GetFileRequest 等 |
| `cli.proto` | CLI 管理消息：AddPeer / RemovePeer / TransferLeader 等 |
| `log.proto` | 日志条目的 V2 序列化格式（PBLogEntry）|
| `local_storage.proto` | 本地存储格式：StablePBMeta / LogPBMeta |
| `enum.proto` | 枚举定义：EntryType / ErrorType 等 |
| `local_file_meta.proto` | 快照文件元数据 |

### 分析大纲

```
1. proto 文件总览（字段级解读）
2. 核心 RPC 消息结构
   2.1 AppendEntriesRequest / Response
   2.2 RequestVoteRequest / Response
   2.3 InstallSnapshotRequest / Response
   2.4 ReadIndexRequest / Response
   2.5 TimeoutNowRequest / Response
3. CLI 管理消息结构
4. 日志序列化格式（log.proto → V2Encoder/Decoder）
5. 本地存储格式（local_storage.proto → LocalRaftMetaStorage）
6. 面试考点 📌
   - JRaft 的 RPC 消息格式是什么？
   - AppendEntriesRequest 中为什么要带 committedIndex？
```

---

## S14：端到端写入链路（Node.apply → 状态机回调） 【P1】

### 归属：新增专题文档 `00-e2e-write-path/README.md`

### 为什么 P1

虽然 04/05/07 章节分别分析了日志复制、日志存储、状态机，但**没有一个章节从头到尾串联完整的写入链路**。`NodeImpl.apply()` 是用户 API 入口，在文档中搜索 `NodeImpl.apply` / `apply.*Task` **零结果**。读者缺少一个"端到端"视角来理解一次写入的完整生命周期。

### 核心调用链

```
Client → Node.apply(Task)
  → NodeImpl: 封装 LogEntry, 提交到 LogManager 的 Disruptor
  → LogManager: 写入内存缓冲 + 持久化到 RocksDB (LogStorage)
  → LogManager: 回调 → Replicator 发送 AppendEntries
  → Replicator: 收到多数派 Response → BallotBox.commitAt()
  → BallotBox: lastCommittedIndex 推进 → FSMCaller.onCommitted()
  → FSMCaller: 通过 Disruptor → doCommitted() → IteratorImpl
  → StateMachine.onApply(iterator) → 用户业务逻辑
  → done.run(Status.OK()) → 回调用户的 Closure
```

### 分析大纲

```
1. 完整时序图（Mermaid sequenceDiagram，横跨 6 个组件）

2. 阶段一：用户提交（NodeImpl.apply）
   2.1 Task 封装 → LogEntryAndClosure
   2.2 提交到 applyQueue（Disruptor 环形缓冲区）
   2.3 批量打包（endOfBatch 合并）

3. 阶段二：日志持久化（LogManager）
   3.1 写入 logsInMemory
   3.2 appendToStorage() → RocksDB WriteBatch
   3.3 磁盘 flush 回调

4. 阶段三：日志复制（Replicator）
   4.1 fillCommonFields() + 批量 AppendEntries
   4.2 Pipeline 模式 vs 非 Pipeline

5. 阶段四：Quorum 确认（BallotBox）
   5.1 ballotAt() 投票
   5.2 lastCommittedIndex 推进

6. 阶段五：状态机应用（FSMCaller）
   6.1 onCommitted() → doCommitted()
   6.2 IteratorImpl 遍历 + StateMachine.onApply()
   6.3 done.run(Status.OK()) 回调

7. 延迟分析：每个阶段耗时多少？瓶颈在哪？

8. 面试考点 📌
   - 一次写入请求经过几次 Disruptor？（答：2 次——LogManager 和 FSMCaller）
   - 批量合并在哪个环节发生？
   - 写入延迟的主要组成部分是什么？
```

---

## S15：BDB 日志存储扩展实现 【P3】

### 归属：补入 `05-log-storage/README.md` 新增第 N 节

### 为什么 P3

`jraft-extension/bdb-log-storage-impl/` 提供了基于 BerkeleyDB 的日志存储实现（19.2KB），是除 RocksDB 之外的第三种存储引擎选择。优先级较低，但作为存储层横向对比的素材有价值。

### 分析大纲

```
1. BDBLogStorage 核心逻辑
2. RocksDB vs BDB vs SegmentFile 三种存储引擎横向对比
   | 维度 | RocksDB (旧版) | SegmentFile (新版) | BDB |
   |------|---------------|-------------------|-----|
   | 索引存储 | RocksDB | RocksDB | BDB |
   | 数据存储 | RocksDB | SegmentFile (mmap) | BDB |
   | 写放大 | 高 | 低 | 中 |
   | 外部依赖 | RocksDB JNI | RocksDB JNI + mmap | BDB Java 纯 Java |
   | 适用场景 | 通用 | 大 value | 纯 Java 部署 |
```

---

## S16：NodeOptions / RaftOptions 配置项全解 【P2】

### 归属：新增附录 `appendix-configuration/README.md` 或补入 01 章节

### 为什么 P2

`NodeOptions`（17.4KB）和 `RaftOptions`（13KB）包含了 JRaft 几乎所有的可调配置项，是生产调优的入口。文档中搜索 `NodeOptions` / `RaftOptions` **零结果**（仅在代码块中出现过类名，没有系统性解读）。

### 分析大纲

```
1. NodeOptions 字段逐一解读
   - 集群配置：initialConf, groupId
   - 存储路径：logUri, raftMetaUri, snapshotUri
   - 定时器参数：electionTimeoutMs, snapshotIntervalSecs
   - 性能参数：disruptorBufferSize, applyBatch
   - 安全参数：enableMetrics, snapshotLogIndexMargin

2. RaftOptions 字段逐一解读
   - 日志复制：maxByteCountPerRpc, maxEntriesSize, maxBodySize
   - Pipeline：maxReplicatorInflightMsgs
   - ReadIndex：readOnlyOptions
   - 同步/异步：sync, syncMeta

3. 生产调优建议表
   | 参数 | 默认值 | 调优建议 | 影响 |
   |------|--------|---------|------|
   | electionTimeoutMs | 1000ms | 网络延迟高时增大 | 选举稳定性 |
   | maxByteCountPerRpc | 128KB | 大日志场景增大 | 复制吞吐量 |
   | maxReplicatorInflightMsgs | 256 | 高延迟网络增大 | Pipeline 深度 |
   | disruptorBufferSize | 16384 | 高并发写入增大 | 吞吐量 |
   | ... | ... | ... | ... |

4. 面试考点 📌
   - electionTimeoutMs 设置过大/过小的影响？
   - maxReplicatorInflightMsgs 的含义和调优？
```

---

## 📋 执行计划

### 第一批（P0 — 阻塞性缺失）
- [x] **S2**：LocalRaftMetaStorage（~6KB，✅ 已完成 → `02-node-lifecycle/S2-LocalRaftMetaStorage.md`）
- [x] **S1**：RocksDBSegmentLogStorage + SegmentFile（~84KB，已完成 ✅）

### 第二批（P1 — 核心链路缺失）
- [x] **S14**：端到端写入链路 Node.apply → 状态机回调（横跨全模块，✅ 已完成 → `00-e2e-write-path/S14-E2E-Write-Path.md`）
- [x] **S3**：LogEntry 编解码器 V1/V2（~25KB，✅ 已完成 → `05-log-storage/S3-LogEntry-Codec.md`）
- [x] **S4**：Transfer Leadership（~200 行，✅ 已完成 → `03-leader-election/S4-Transfer-Leadership.md`）
- [x] **S5**：Learner 角色机制（~150 行，✅ 已完成 → `09-membership-change/S5-Learner.md`）
- [x] **S9**：节点优雅停机（shutdown/destroy）（~300 行，✅ 已完成 → `02-node-lifecycle/S9-Shutdown.md`）
- [ ] **S10**：远程快照拷贝 RemoteFileCopier + CopySession（~21KB，预计 2 小时）

### 第三批（P2 — 扩展模块与基础设施）
- [ ] **S6**：gRPC 实现对比 Bolt（~43KB，预计 3 小时）
- [ ] **S7**：RheaKV Placement Driver（~80KB，预计 4-6 小时）
- [ ] **S11**：SPI 扩展机制 + JRaftServiceFactory（~35KB，预计 2 小时）
- [ ] **S12**：HashedWheelTimer 时间轮实现（~48KB，预计 3 小时）
- [ ] **S13**：Protobuf 协议定义与消息结构（~7 个 proto 文件，预计 2 小时）
- [ ] **S16**：NodeOptions/RaftOptions 配置项全解（~30KB，预计 2 小时）

### 第四批（P3 — 补充完善）
- [ ] **S8**：Bootstrap 集群引导流程（~100 行，预计 0.5 小时）
- [ ] **S15**：BDB 日志存储扩展实现（~19KB，预计 1.5 小时）

---

## 完成后的章节结构

```
00-e2e-write-path/          ← 新增 S14(端到端写入链路)
01-overview/                ← 补入 S16(NodeOptions/RaftOptions 配置项全解) [或新增附录]
02-node-lifecycle/          ← 补入 S2(LocalRaftMetaStorage) + S8(Bootstrap) + S9(优雅停机) + S11(SPI 体系)
03-leader-election/         ← 补入 S4(Transfer Leadership)
04-log-replication/
05-log-storage/             ← 补入 S3(LogEntry 编解码器) + S15(BDB 存储)
05b-segment-log-storage/    ← 新增 S1(RocksDBSegmentLogStorage)
06-snapshot/                ← 补入 S10(远程快照拷贝)
07-state-machine/
08-read-index/
09-membership-change/       ← 补入 S5(Learner)
10-rpc-layer/               ← 补入 S6(gRPC)
11-concurrency-infra/       ← 补入 S12(HashedWheelTimer 时间轮)
12-metrics/
13-rheakv-core/
14-rheakv-pd/               ← 新增 S7(Placement Driver)
appendix-protobuf-protocol/ ← 新增 S13(Protobuf 协议定义)
```
