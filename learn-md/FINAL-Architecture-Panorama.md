
# JRaft 架构全景图 — 37 篇文档的终极串联

> **定位**：本文是 S1-S21 + 01-15 全部 37 篇源码学习文档的**架构总览图**。
> 用 Mermaid 图把所有组件、数据流、关键路径串联到一张地图上，方便回顾和面试前速查。
>
> **配套文档**：[面试 20 题](./FINAL-Interview-20.md)

---

## 目录

1. [组件全景架构图](#1-组件全景架构图)
2. [写路径全链路图（Node.apply → StateMachine.onApply）](#2-写路径全链路图)
3. [读路径全链路图（Node.readIndex → ReadIndexClosure）](#3-读路径全链路图)
4. [Leader 选举流程图（PreVote → BecomeLeader）](#4-leader-选举流程图)
5. [快照生成与安装流程图](#5-快照生成与安装流程图)
6. [成员变更流程图（Joint Consensus 两阶段）](#6-成员变更流程图)
7. [模块间数据流关系总图](#7-模块间数据流关系总图)
8. [RheaKV 分布式 KV 架构图](#8-rheakv-分布式-kv-架构图)
9. [关键数据结构关系图](#9-关键数据结构关系图)
10. [三层 Disruptor 流水线图](#10-三层-disruptor-流水线图)
11. [37 篇文档索引速查表](#11-37-篇文档索引速查表)

---

## 1. 组件全景架构图

```mermaid
flowchart TD
    subgraph 用户层["用户层 API"]
        CLIENT["Client<br/>Node.apply(Task) / Node.readIndex()"]
        RGS["RaftGroupService<br/>启动入口，管理 Node 生命周期"]
    end

    subgraph 核心节点["NodeImpl — 核心大脑 (145KB)"]
        direction TB
        STATE["State 状态机<br/>9 种状态 · 23 处转换<br/>📖 S20"]
        LOCK["LongHeldDetectingReadWriteLock<br/>读写锁 + 死锁检测<br/>📖 S20"]
        TIMER["定时器组 (4个)<br/>electionTimer · voteTimer<br/>stepDownTimer · snapshotTimer<br/>📖 S12"]
        CONF["ConfigurationCtx<br/>成员变更状态机<br/>📖 09"]
    end

    subgraph 选举层["选举层 📖 03 + S4"]
        PREVOTE["PreVote<br/>两阶段预投票"]
        VOTE["Ballot<br/>投票计数器"]
        PRIORITY["Election Priority<br/>优先级选举 + 衰减"]
        TRANSFER["Transfer Leadership<br/>TimeoutNow 主动让渡"]
    end

    subgraph 日志层["日志层 📖 04 + 05"]
        LM["LogManager<br/>Disruptor 异步 · 内存+持久化<br/>📖 04"]
        LS_ROCKS["RocksDBLogStorage<br/>旧版日志引擎<br/>📖 05"]
        LS_SEG["RocksDBSegmentLogStorage<br/>新版：索引与数据分离<br/>📖 S1"]
        LS_BDB["BDBLogStorage<br/>BerkeleyDB 扩展<br/>📖 S15"]
        CODEC["LogEntry Codec<br/>V1(手工) / V2(Protobuf)<br/>AutoDetectDecoder<br/>📖 S3"]
        LM --> LS_ROCKS
        LM --> LS_SEG
        LM --> LS_BDB
        LM --> CODEC
    end

    subgraph 复制层["复制层 📖 04 + S17 + S18"]
        RG["ReplicatorGroup<br/>管理所有 Follower 的 Replicator"]
        REP["Replicator<br/>Pipeline 模式 · Inflight 队列<br/>三层流控 · 序号系统<br/>📖 S18"]
        FOL["Follower RPC 处理<br/>handleAppendEntries<br/>handleRequestVote<br/>📖 S17"]
        RG --> REP
    end

    subgraph 投票箱["投票箱 📖 04"]
        BB["BallotBox<br/>StampedLock 乐观读<br/>Quorum 多数派确认"]
    end

    subgraph 状态机层["状态机层 📖 07"]
        FSM["FSMCaller<br/>Disruptor 异步驱动<br/>IteratorImpl 批量 apply"]
        SM["StateMachine (用户实现)<br/>onApply · onSnapshotSave<br/>onSnapshotLoad · onLeaderStart"]
        FSM --> SM
    end

    subgraph 快照层["快照层 📖 06 + S10"]
        SE["SnapshotExecutor<br/>快照调度器"]
        SS["SnapshotStorage<br/>LocalSnapshotStorage"]
        RFC["RemoteFileCopier<br/>分块传输 · 重试<br/>📖 S10"]
        THROTTLE["SnapshotThrottle<br/>令牌桶限流"]
        SE --> SS
        SE --> RFC
        RFC --> THROTTLE
    end

    subgraph 读服务层["读服务层 📖 08 + S21"]
        ROS["ReadOnlyService<br/>Disruptor 异步"]
        RI_SAFE["ReadOnlySafe<br/>Quorum 心跳确认"]
        RI_LEASE["ReadOnlyLeaseBased<br/>Leader 租约 · 自动降级"]
        ROS --> RI_SAFE
        ROS --> RI_LEASE
    end

    subgraph 元数据层["元数据层 📖 S2"]
        META["LocalRaftMetaStorage<br/>Protobuf 序列化<br/>term + votedFor 持久化"]
    end

    subgraph RPC层["RPC 层 📖 10 + S6 + S13"]
        RPC_BOLT["Bolt RPC<br/>默认实现 · 自定义协议<br/>📖 10"]
        RPC_GRPC["gRPC RPC<br/>SPI 扩展 · HTTP/2<br/>📖 S6"]
        PROTO["Protobuf 协议<br/>7 个 .proto 文件<br/>📖 S13"]
        RPC_BOLT --> PROTO
        RPC_GRPC --> PROTO
    end

    subgraph SPI层["SPI 扩展层 📖 S11"]
        SPI["JRaftServiceFactory<br/>+ JRaftServiceLoader<br/>可插拔组件工厂"]
    end

    subgraph 并发基础设施["并发基础设施 📖 11 + S12"]
        DISRUPTOR["Disruptor<br/>3 个 Ring Buffer"]
        HWT["HashedWheelTimer<br/>O(1) 定时器<br/>📖 S12"]
        METRICS["Metrics 可观测<br/>📖 12"]
    end

    subgraph 配置层["配置层 📖 S16"]
        OPTS["NodeOptions + RaftOptions<br/>60+ 配置项"]
    end

    %% 连接关系
    CLIENT --> 核心节点
    RGS --> 核心节点

    核心节点 --> 选举层
    核心节点 --> 日志层
    核心节点 --> 复制层
    核心节点 --> 投票箱
    核心节点 --> 状态机层
    核心节点 --> 快照层
    核心节点 --> 读服务层
    核心节点 --> 元数据层
    核心节点 --> RPC层

    SPI层 -.->|创建| 日志层
    SPI层 -.->|创建| 元数据层
    SPI层 -.->|创建| 快照层
    SPI层 -.->|创建| RPC层

    并发基础设施 -.->|底层支撑| 核心节点
    配置层 -.->|参数注入| 核心节点
```

---

## 2. 写路径全链路图

> 详见 📖 [S14-E2E-Write-Path](./00-e2e-write-path/S14-E2E-Write-Path.md)

```mermaid
sequenceDiagram
    participant C as Client
    participant N as NodeImpl
    participant D1 as Disruptor①<br/>applyQueue
    participant LM as LogManager
    participant D2 as Disruptor②<br/>logQueue
    participant LS as LogStorage<br/>(RocksDB)
    participant REP as Replicator<br/>(Pipeline)
    participant BB as BallotBox
    participant D3 as Disruptor③<br/>fsmQueue
    participant FSM as FSMCaller
    participant SM as StateMachine

    C->>N: apply(Task)
    N->>D1: publish(LogEntryAndClosure)
    Note over D1: 批量合并 (applyBatch=32)

    D1->>LM: executeApplyingTasks()
    LM->>D2: appendEntries(batch)
    Note over D2: 第二级批量合并

    par 并行执行
        D2->>LS: appendToStorage()<br/>RocksDB WriteBatch
    and
        D2->>REP: wakeupAllAppender()<br/>触发日志复制
    end

    REP->>REP: sendEntries()<br/>Pipeline 模式 · Inflight 队列
    REP-->>BB: commitAt(peerIndex)
    Note over BB: StampedLock 乐观读<br/>Quorum 多数派确认

    BB->>D3: onCommitted(committedIndex)
    D3->>FSM: doCommitted()
    Note over D3: 第三级批量合并

    FSM->>SM: onApply(Iterator)
    SM-->>C: done.run(Status.OK)
```

**写路径关键数字**：
- **3 次 Disruptor**：`applyQueue` → `logQueue` → `fsmQueue`
- **3 级批量合并**：Node 层 32 条 → LogManager 层按 Buffer → FSMCaller 层合并 committed 区间
- **2 次磁盘 I/O**：日志写 RocksDB + fsync（关键路径），快照写磁盘（异步路径）

---

## 3. 读路径全链路图

> 详见 📖 [S21-E2E-Read-Path](./00-e2e-read-path/S21-E2E-Read-Path.md)

```mermaid
sequenceDiagram
    participant C as Client
    participant N as NodeImpl
    participant ROS as ReadOnlyService
    participant D as Disruptor<br/>readIndexQueue
    participant REP as Replicator<br/>(心跳)
    participant FSM as FSMCaller

    C->>N: readIndex(reqCtx, closure)
    N->>ROS: addRequest(reqCtx, closure)
    ROS->>D: publish(ReadIndexEvent)
    Note over D: 批量合并同类请求

    D->>N: handleReadIndex(batch)<br/>分 Safe / LeaseBased 两次调用

    alt ReadOnlySafe（默认）
        N->>N: readLeader()<br/>新 Leader 保护 + 单节点快速路径
        N->>REP: 向多数派发心跳
        REP-->>N: Quorum 确认 Leader 身份
        N-->>ROS: ReadIndexResponse(commitIndex)
    else ReadOnlyLeaseBased
        N->>N: checkLeaderLease()
        alt 租约有效
            N-->>ROS: 直接返回 commitIndex
        else 租约过期
            Note over N: 自动降级为 ReadOnlySafe
            N->>REP: 向多数派发心跳
        end
    end

    ROS->>ROS: ReadIndexResponseClosure<br/>isApplied? → success<br/>notApplied? → pendingNotifyStatus

    FSM->>ROS: onApplied(appliedIndex)
    Note over ROS: headMap(appliedIndex, true)<br/>唤醒所有 ≤ appliedIndex 的等待者
    ROS-->>C: closure.run(Status.OK)
```

**读路径关键数字**：
- **1 次 Disruptor**：`readIndexQueue`（vs 写路径 3 次）
- **0 次磁盘 I/O**：ReadIndex 不写日志（vs 写路径 2 次）
- **1 次网络 RTT**（Safe 模式心跳确认）/ **0 次网络 RTT**（Lease 模式）

---

## 4. Leader 选举流程图

> 详见 📖 [03-Leader-Election](./03-leader-election/README.md) + [S4-Transfer-Leadership](./03-leader-election/S4-Transfer-Leadership.md)

```mermaid
stateDiagram-v2
    [*] --> FOLLOWER : init() → stepDown()

    state FOLLOWER {
        [*] --> WaitHeartbeat
        WaitHeartbeat --> CheckTimeout : electionTimer 超时
        CheckTimeout --> WaitHeartbeat : Leader 仍有效
        CheckTimeout --> CheckPriority : Leader 失效
        CheckPriority --> WaitHeartbeat : 优先级不够(跳过)
        CheckPriority --> PreVote : 优先级OK / 衰减后OK
    }

    state PreVote {
        [*] --> SendPreVote : term+1(不持久化)
        SendPreVote --> PreVoteGranted : 多数派授权
        SendPreVote --> PreVoteFailed : 被拒绝
        PreVoteFailed --> FOLLOWER : stepDown
    }

    PreVoteGranted --> CANDIDATE : electSelf()

    state CANDIDATE {
        [*] --> IncrTerm : currTerm++
        IncrTerm --> SendVote : 发 RequestVote
        SendVote --> Persist : metaStorage.setTermAndVotedFor()
        Persist --> CountVotes : 统计 Ballot
    }

    CountVotes --> LEADER : voteCtx.isGranted()
    CountVotes --> FOLLOWER : 收到更高 term / voteTimer 超时

    state LEADER {
        [*] --> InitReplicators : 为每个 Peer 启动 Replicator
        InitReplicators --> CommitNoop : confCtx.flush()(配置日志)
        CommitNoop --> StartStepDownTimer : 定期检查多数派
        StartStepDownTimer --> Serving : 正常服务
    }

    LEADER --> TRANSFERRING : transferLeadershipTo()
    TRANSFERRING --> FOLLOWER : TimeoutNow 发送 / 超时

    LEADER --> FOLLOWER : stepDown(更高 term)
```

---

## 5. 快照生成与安装流程图

> 详见 📖 [06-Snapshot](./06-snapshot/README.md) + [S10-Remote-File-Copier](./06-snapshot/S10-Remote-File-Copier.md)

```mermaid
flowchart TD
    subgraph 生成快照["Leader/Follower 独立生成快照"]
        T["snapshotTimer 触发<br/>间隔: snapshotIntervalSecs"]
        T --> CHECK["检查: logIndex - lastSnapshotIndex<br/>> snapshotLogIndexMargin?"]
        CHECK -->|是| SAVE["doSnapshot()<br/>① FSMCaller.onSnapshotSave()<br/>② StateMachine.onSnapshotSave(writer)<br/>③ writer.saveMeta(lastIncludedIndex/Term)"]
        SAVE --> TRUNC["LogManager.setSnapshot()<br/>→ truncatePrefix(lastSnapshotIndex)"]
        CHECK -->|否| SKIP["跳过本次快照"]
    end

    subgraph 安装快照["Follower 从 Leader 安装快照"]
        NEED["Follower 需要的日志已被 Leader 删除"]
        NEED --> IS["Leader 发送 InstallSnapshot RPC"]
        IS --> COPY["RemoteFileCopier<br/>分块传输 (128KB/块)<br/>SnapshotThrottle 限流"]
        COPY --> FILTER["filterBeforeCopyRemote<br/>文件去重: 比对 checksum"]
        FILTER --> LOAD["FSMCaller.onSnapshotLoad()<br/>StateMachine.onSnapshotLoad(reader)"]
        LOAD --> APPLY["更新 lastApplied<br/>截断旧日志<br/>恢复集群配置"]
    end
```

---

## 6. 成员变更流程图

> 详见 📖 [09-Membership-Change](./09-membership-change/README.md) + [S5-Learner](./09-membership-change/S5-Learner.md)

```mermaid
flowchart LR
    subgraph API层
        ADD["addPeer(peer)"]
        REMOVE["removePeer(peer)"]
        CHANGE["changePeers(newConf)"]
        ADD_L["addLearners(learners)"]
    end

    subgraph ConfigurationCtx["ConfigurationCtx 状态机"]
        NONE["STAGE_NONE<br/>空闲"]
        CATCHING["STAGE_CATCHING_UP<br/>新节点追赶日志"]
        JOINT["STAGE_JOINT<br/>C_old,new 双 Quorum"]
        STABLE["STAGE_STABLE<br/>C_new 单 Quorum"]
    end

    ADD --> NONE
    REMOVE --> NONE
    CHANGE --> NONE
    ADD_L --> NONE

    NONE -->|"新节点? catchupMargin=1000"| CATCHING
    CATCHING -->|"追赶完成"| JOINT
    NONE -->|"无新节点"| JOINT

    JOINT -->|"C_old,new 日志<br/>被多数派确认"| STABLE
    STABLE -->|"C_new 日志<br/>被多数派确认"| NONE

    JOINT -.->|"双 Quorum 投票"| BB2["BallotBox<br/>peers + oldPeers"]
    STABLE -.->|"单 Quorum 投票"| BB3["BallotBox<br/>peers only"]
```

---

## 7. 模块间数据流关系总图

```mermaid
flowchart TD
    CLIENT["Client"] -->|"apply(Task)"| NODE["NodeImpl"]
    CLIENT -->|"readIndex()"| NODE

    NODE -->|"LogEntryAndClosure"| APPLY_D["applyDisruptor<br/>Ring Buffer 16384"]
    APPLY_D -->|"batch ≤ 32"| LM["LogManager"]

    LM -->|"LogEntry batch"| LOG_D["logDisruptor<br/>Ring Buffer 32768"]
    LOG_D -->|"WriteBatch"| LS["LogStorage<br/>(RocksDB)"]
    LOG_D -->|"wakeupAllAppender"| REP["Replicator"]

    REP -->|"AppendEntries RPC"| FOLLOWER["Follower Node"]
    REP -->|"commitAt()"| BB["BallotBox"]

    BB -->|"onCommitted()"| FSM_D["fsmDisruptor<br/>Ring Buffer 16384"]
    FSM_D -->|"doCommitted()"| FSM["FSMCaller"]
    FSM -->|"onApply(iterator)"| SM["StateMachine"]

    NODE -->|"ReadIndexEvent"| RI_D["readIndexDisruptor<br/>Ring Buffer 16384"]
    RI_D -->|"handleReadIndex()"| ROS["ReadOnlyService"]
    ROS -->|"心跳确认"| REP

    FSM -->|"onApplied()"| ROS

    NODE -->|"setTermAndVotedFor"| META["RaftMetaStorage"]
    NODE -->|"doSnapshot()"| SNAP["SnapshotExecutor"]
    SNAP -->|"onSnapshotSave/Load"| FSM

    style APPLY_D fill:#FFE0B2
    style LOG_D fill:#FFE0B2
    style FSM_D fill:#FFE0B2
    style RI_D fill:#FFE0B2
```

---

## 8. RheaKV 分布式 KV 架构图

> 详见 📖 [13-RheaKV](./13-rheakv-advanced/README.md) + [S7-Placement-Driver](./14-rheakv-pd/S7-Placement-Driver.md)

```mermaid
flowchart TD
    subgraph Client["RheaKV Client"]
        RT["RouteTable<br/>Region 路由缓存"]
        FP["FuturePool<br/>异步请求池"]
    end

    subgraph PD["Placement Driver (PD)"]
        PD_RAFT["PD 自身 Raft Group<br/>元数据高可用"]
        PD_META["DefaultMetadataStore<br/>Store/Region 元数据"]
        PD_PIPE["Pipeline 处理链<br/>StatsValidator → Balance → Split"]
    end

    subgraph Store1["StoreEngine Node1"]
        R1_1["Region 1 (Leader)<br/>Raft Group"]
        R1_2["Region 2 (Follower)<br/>Raft Group"]
        ROCKS1["RocksDB<br/>数据存储"]
    end

    subgraph Store2["StoreEngine Node2"]
        R2_1["Region 1 (Follower)"]
        R2_2["Region 2 (Leader)"]
        ROCKS2["RocksDB"]
    end

    Client -->|"put/get/scan"| Store1
    Client -->|"路由查询"| PD

    Store1 -->|"Store/Region 心跳"| PD
    Store2 -->|"Store/Region 心跳"| PD

    PD -->|"Leader Balance 指令"| Store1
    PD -->|"Region Split 指令"| Store2

    R1_1 -->|"AppendEntries"| R2_1
    R2_2 -->|"AppendEntries"| R1_2
```

---

## 9. 关键数据结构关系图

```mermaid
classDiagram
    class NodeImpl {
        -State state
        -long currTerm
        -PeerId votedId
        -PeerId leaderId
        -LogManager logManager
        -FSMCaller fsmCaller
        -BallotBox ballotBox
        -ReplicatorGroup replicatorGroup
        -ReadOnlyService readOnlyService
        -SnapshotExecutor snapshotExecutor
        -RaftMetaStorage metaStorage
        -ConfigurationCtx confCtx
    }

    class LogManager {
        -LogStorage logStorage
        -ConfigurationManager configManager
        -long firstLogIndex
        -long lastLogIndex
        -Disruptor diskQueue
    }

    class Replicator {
        -long nextIndex
        -Inflight[] inflights
        -int reqSeq
        -int requiredNextSeq
        -State state
        -RaftClientService rpcService
    }

    class BallotBox {
        -long lastCommittedIndex
        -long pendingIndex
        -List~Ballot~ pendingMetaQueue
        -StampedLock stampedLock
    }

    class FSMCaller {
        -long lastAppliedIndex
        -LogManager logManager
        -StateMachine fsm
        -Disruptor taskQueue
    }

    class ReadOnlyService {
        -TreeMap~Long,List~ pendingNotifyStatus
        -Disruptor readIndexQueue
    }

    NodeImpl --> LogManager
    NodeImpl --> FSMCaller
    NodeImpl --> BallotBox
    NodeImpl --> Replicator : "via ReplicatorGroup"
    NodeImpl --> ReadOnlyService
    BallotBox --> FSMCaller : "onCommitted()"
    FSMCaller --> ReadOnlyService : "onApplied()"
    LogManager --> Replicator : "wakeupAllAppender()"
```

---

## 10. 三层 Disruptor 流水线图

```mermaid
flowchart LR
    subgraph Layer1["第一层: Node Apply"]
        A1["Client Thread 1"] --> RB1["applyDisruptor<br/>RingBuffer 16384<br/>MULTI Producer"]
        A2["Client Thread 2"] --> RB1
        A3["Client Thread N"] --> RB1
        RB1 -->|"batch ≤ 32"| H1["LogEntryAndClosureHandler<br/>(单消费者)"]
    end

    subgraph Layer2["第二层: Log Persist"]
        H1 -->|"appendEntries"| RB2["logDisruptor<br/>RingBuffer 32768<br/>SINGLE Producer"]
        RB2 --> H2["StableClosureEventHandler<br/>(单消费者)"]
        H2 -->|"WriteBatch"| ROCKS["RocksDB fsync"]
        H2 -->|"wakeup"| REP["Replicator"]
    end

    subgraph Layer3["第三层: FSM Apply"]
        BB["BallotBox<br/>Quorum 确认"] -->|"onCommitted"| RB3["fsmDisruptor<br/>RingBuffer 16384<br/>SINGLE Producer"]
        RB3 --> H3["ApplyTaskHandler<br/>(单消费者)"]
        H3 -->|"onApply(iterator)"| SM["StateMachine"]
    end

    subgraph ReadPath["读路径: ReadIndex"]
        ROS_IN["ReadIndex 请求"] --> RB4["readIndexDisruptor<br/>RingBuffer 16384<br/>MULTI Producer"]
        RB4 --> H4["ReadIndexEventHandler<br/>(单消费者)"]
        H4 -->|"handleReadIndex"| NODE["NodeImpl"]
    end
```

---

## 11. 37 篇文档索引速查表

| # | 文档 | 核心主题 | 关键类 | 路径 |
|---|------|---------|--------|------|
| 01 | Overview | 全局架构、组件一览 | `NodeImpl` | `01-overview/README.md` |
| 02 | Node Lifecycle | init() 14 步、状态机 | `NodeImpl.init()` | `02-node-lifecycle/README.md` |
| 03 | Leader Election | PreVote、投票、becomeLeader | `Ballot`, `NodeImpl` | `03-leader-election/README.md` |
| 04 | Log Replication | Replicator、BallotBox、Pipeline | `Replicator`, `BallotBox` | `04-log-replication/README.md` |
| 05 | Log Storage | RocksDB 日志存储 | `RocksDBLogStorage` | `05-log-storage/README.md` |
| 06 | Snapshot | 快照生成/安装 | `SnapshotExecutorImpl` | `06-snapshot/README.md` |
| 07 | State Machine | FSMCaller、IteratorImpl | `FSMCallerImpl` | `07-state-machine/README.md` |
| 08 | ReadIndex | 线性一致读 Safe/Lease | `ReadOnlyServiceImpl` | `08-read-index/README.md` |
| 09 | Membership | Joint Consensus、addPeer | `ConfigurationCtx` | `09-membership-change/README.md` |
| 10 | RPC Layer | Bolt RPC 实现 | `BoltRaftRpcFactory` | `10-rpc-layer/README.md` |
| 11 | Concurrency | Disruptor、MPSC 队列 | `Disruptor` | `11-concurrency-infra/README.md` |
| 12 | Metrics | 全链路可观测性 | `NodeMetrics` | `12-metrics-observability/README.md` |
| 13 | RheaKV | 分布式 KV 存储 | `RheaKVStore` | `13-rheakv-advanced/README.md` |
| S1 | SegmentLog | 新一代日志引擎 | `RocksDBSegmentLogStorage` | `05b-segment-log-storage/S1` |
| S2 | MetaStorage | term/votedFor 持久化 | `LocalRaftMetaStorage` | `02-node-lifecycle/S2` |
| S3 | LogEntry Codec | V1/V2 编解码 | `V2Encoder/Decoder` | `05-log-storage/S3` |
| S4 | Transfer Leadership | 主动让渡 | `NodeImpl.transferLeadershipTo` | `03-leader-election/S4` |
| S5 | Learner | 只读副本角色 | `Configuration.learners` | `09-membership-change/S5` |
| S6 | gRPC | gRPC vs Bolt 对比 | `GrpcClient/GrpcServer` | `10-rpc-layer/S6` |
| S7 | Placement Driver | PD 调度中心 | `PlacementDriverServer` | `14-rheakv-pd/S7` |
| S8 | Bootstrap | 集群引导 | `NodeImpl.bootstrap()` | `02-node-lifecycle/S8` |
| S9 | Shutdown | 优雅停机 | `NodeImpl.shutdown()` | `02-node-lifecycle/S9` |
| S10 | Remote File Copier | 远程快照拷贝 | `RemoteFileCopier` | `06-snapshot/S10` |
| S11 | SPI | 可插拔工厂体系 | `JRaftServiceLoader` | `02-node-lifecycle/S11` |
| S12 | HashedWheelTimer | 时间轮实现 | `HashedWheelTimer` | `11-concurrency-infra/S12` |
| S13 | Protobuf Protocol | 消息结构定义 | `raft.proto` | `10-rpc-layer/S13` |
| S14 | E2E Write Path | 端到端写入链路 | 横跨 6 个组件 | `00-e2e-write-path/S14` |
| S15 | BDB LogStorage | BerkeleyDB 日志存储 | `BDBLogStorage` | `05-log-storage/S15` |
| S16 | Configuration Guide | 60+ 配置项全解 | `NodeOptions/RaftOptions` | `01-overview/S16` |
| S17 | Follower RPC | Follower 端 RPC 处理 | `NodeImpl.handle*Request` | `04-log-replication/S17` |
| S18 | Replicator Pipeline | Inflight/序号/流控 | `Replicator` | `04-log-replication/S18` |
| S19 | Multi-Raft Group | 多 Raft 组架构 | `NodeManager/RouteTable` | `09-membership-change/S19` |
| S20 | NodeImpl StateMachine | 9 状态 23 转换 | `NodeImpl.state` | `02-node-lifecycle/S20` |
| S21 | E2E Read Path | 端到端读取链路 | `ReadOnlyServiceImpl` | `00-e2e-read-path/S21` |
| — | Raft Paper vs JRaft | 论文对照 | — | `15-raft-paper-vs-jraft/` |

---

> **下一篇**：[面试 20 题 →](./FINAL-Interview-20.md)
