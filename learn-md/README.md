# JRaft 源码学习路线图

> 基于 SOFAJRaft 源码（`jraft-core` + `jraft-rheakv`），系统性学习 Raft 协议工程实现。

## 学习主题目录

| 序号 | 主题 | 核心类 | 难度 |
|---|---|---|---|
| [01](./01-overview/README.md) | **整体架构概览** | `Node`, `RaftGroupService`, `JRaftServiceFactory` | ⭐⭐ |
| [02](./02-node-lifecycle/README.md) | **Node 生命周期与启动流程** | `NodeImpl.init()`, `State`, `RepeatedTimer` | ⭐⭐⭐ |
| [03](./03-leader-election/README.md) | **Leader 选举** | `preVote`, `electSelf`, `Ballot` | ⭐⭐⭐⭐ |
| [04](./04-log-replication/README.md) | **日志复制** | `Replicator`, `BallotBox`, `AppendEntries` | ⭐⭐⭐⭐⭐ |
| [05](./05-log-storage/README.md) | **日志存储** | `LogManagerImpl`, `RocksDBLogStorage`, `SegmentFile` | ⭐⭐⭐⭐ |
| [06](./06-snapshot/README.md) | **快照机制** | `SnapshotExecutorImpl`, `LocalSnapshotCopier`, `FileService` | ⭐⭐⭐⭐ |
| [07](./07-state-machine/README.md) | **状态机与 FSMCaller** | `FSMCallerImpl`, `StateMachine`, `Iterator` | ⭐⭐⭐ |
| [08](./08-read-index/README.md) | **线性一致读（ReadIndex）** | `ReadOnlyServiceImpl`, `ReadIndexClosure` | ⭐⭐⭐ |
| [09](./09-membership-change/README.md) | **成员变更** | `CliServiceImpl`, `Configuration`, `RouteTable` | ⭐⭐⭐ |
| [10](./10-rpc-layer/README.md) | **RPC 通信层** | `BoltRpcServer`, `AppendEntriesRequestProcessor` | ⭐⭐⭐ |
| [11](./11-disruptor-pipeline/README.md) | **Disruptor 与并发基础设施** | `DisruptorBuilder`, `MpscSingleThreadExecutor`, `RepeatedTimer` | ⭐⭐⭐⭐ |
| [12](./12-rheakv/README.md) | **RheaKV 分布式 KV 存储** | `StoreEngine`, `RegionEngine`, `KVStoreStateMachine` | ⭐⭐⭐⭐⭐ |

## 推荐学习顺序

```
第一阶段：建立全局视图
  01（架构概览）→ 02（节点生命周期）→ 07（状态机）

第二阶段：核心协议
  03（Leader 选举）→ 04（日志复制）→ 08（线性一致读）

第三阶段：存储与快照
  05（日志存储）→ 06（快照机制）

第四阶段：工程细节
  10（RPC 层）→ 11（Disruptor 并发）→ 09（成员变更）

第五阶段：综合应用
  12（RheaKV）
```

## 核心数据流

```
Client.apply(Task)
  │
  ▼ [NodeImpl]
  写入 LogManager（Disruptor 异步）
  │
  ▼ [Replicator × N]
  Pipeline 复制给所有 Follower
  │
  ▼ [BallotBox]
  Quorum 达成 → committedIndex 推进
  │
  ▼ [FSMCaller]
  Disruptor 异步驱动状态机
  │
  ▼ [StateMachine.onApply()]
  用户业务逻辑 + Closure 回调客户端
```

## 关键源码文件大小参考

| 文件 | 大小 | 说明 |
|---|---|---|
| `NodeImpl.java` | 145 KB | 节点核心，最复杂的类 |
| `Replicator.java` | 73 KB | 日志复制核心 |
| `FSMCallerImpl.java` | 28 KB | 状态机调用器 |
| `LogManagerImpl.java` | 46 KB | 日志管理器 |
| `SnapshotExecutorImpl.java` | 30 KB | 快照执行器 |
| `ReadOnlyServiceImpl.java` | 19 KB | 线性一致读 |
| `DefaultRheaKVStore.java` | 93 KB | RheaKV 客户端 |
| `RocksRawKVStore.java` | 73 KB | RocksDB KV 存储 |

## 阅读技巧

遵循 [[memory:592bhmre]] 中的源码阅读规则：

1. **数据结构优先**：先看字段（特别是 `volatile`/`final`），再看方法
2. **问题导向**：每次阅读前明确问题，读完后用自己的话回答
3. **异常路径必读** ⭐：每个 `catch` 块都要看，生产故障 90% 在异常路径
4. **父类构造链必查** ⭐：`NodeImpl` 实现了哪些接口？各接口的 `init()` 语义？
5. **Debug 验证**：对执行路径有疑问必须 Debug，不能靠猜
