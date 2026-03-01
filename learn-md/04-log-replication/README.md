# 04 - 日志复制

## 学习目标

深入理解 JRaft 的日志复制机制，包括 `Replicator`（复制器）的工作原理、Pipeline 复制、批量发送、以及 `BallotBox` 的提交流程。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `Replicator` | `core/Replicator.java` | 单个 Follower 的复制器（73KB，核心类） |
| `ReplicatorGroup` | `ReplicatorGroup.java` | 复制组接口 |
| `ReplicatorGroupImpl` | `core/ReplicatorGroupImpl.java` | 复制组实现，管理所有 Replicator |
| `BallotBox` | `core/BallotBox.java` | 投票箱，负责日志提交的 quorum 计数 |
| `AppendEntriesRequestProcessor` | `rpc/impl/core/AppendEntriesRequestProcessor.java` | Follower 处理 AppendEntries |
| `NodeImpl.appendEntries()` | `core/NodeImpl.java` | Leader 接收客户端写请求入口 |
| `LogManager` | `storage/LogManager.java` | 日志管理接口 |

## 日志复制完整流程

```
Client
  │  apply(Task)
  ▼
NodeImpl.apply()
  │  1. 封装为 LogEntry（type=DATA）
  │  2. 追加到 LogManager（先写本地）
  │  3. 注册到 BallotBox（等待 quorum）
  ▼
LogManagerImpl.appendEntries()
  │  写入 RocksDB（异步 batch）
  │  通知 Replicator 有新日志
  ▼
Replicator.notifyOnNewLog()
  │  构造 AppendEntriesRequest
  │  Pipeline 发送给 Follower
  ▼
Follower: AppendEntriesRequestProcessor
  │  校验 prevLogIndex/prevLogTerm
  │  写入本地 LogStorage
  │  返回 AppendEntriesResponse
  ▼
Replicator.onAppendEntriesReturned()
  │  更新 nextIndex / matchIndex
  │  通知 BallotBox
  ▼
BallotBox.commitAt()
  │  quorum 达成 → 推进 committedIndex
  ▼
FSMCaller.onCommitted()
  │  回调用户 StateMachine.onApply()
  ▼
Closure.run(Status.OK)  ← 通知客户端成功
```

## Replicator 核心机制

### Pipeline 复制

JRaft 支持 Pipeline 模式（`RaftOptions.maxReplicatorInflightMsgs`），无需等待上一批 ACK 就可以发送下一批：

```
Leader ──[batch1]──► Follower
Leader ──[batch2]──► Follower  (不等 batch1 的 ACK)
Leader ──[batch3]──► Follower
       ◄──[ACK1]────
       ◄──[ACK2]────
```

**关键字段：**
```java
private final ArrayDeque<Inflight> inflights;  // 在途请求队列
private int reqSeq;      // 发送序号
private int requiredNextSeq;  // 期望的下一个 ACK 序号（保证有序）
```

### 日志探测（Probe）

当 Follower 的 `nextIndex` 未知时，Replicator 发送空的 AppendEntries 探测 Follower 的日志位置：

```
Replicator.sendEmptyEntries(isHeartbeat=false)
  → 收到响应后确定 nextIndex
  → 开始正常复制
```

### 心跳机制

Leader 通过 `heartbeatTimer` 周期发送心跳（空 AppendEntries），维持 Leader 权威：

```java
// 心跳间隔 = electionTimeoutMs / 10（默认）
private void sendHeartbeat() {
    sendEmptyEntries(true);
}
```

### 快速回退（Log Matching 失败）

当 Follower 返回 `AppendEntries` 失败时，Replicator 需要回退 `nextIndex`：

```
JRaft 优化：Follower 在响应中携带 lastLogIndex
→ Leader 直接跳到 lastLogIndex+1，避免逐条回退
```

## BallotBox（投票箱）

```java
// 核心数据结构
private final SegmentList<Ballot> pendingMetaQueue;  // 待提交的 Ballot 队列
private long lastCommittedIndex;  // 已提交的最大 index
private long pendingIndex;        // 待提交的起始 index

// 提交流程
public boolean commitAt(long firstLogIndex, long lastLogIndex, PeerId peer) {
    // 1. 找到对应的 Ballot
    // 2. 调用 ballot.grant(peer)
    // 3. 如果 quorum 达成，推进 lastCommittedIndex
    // 4. 通知 FSMCaller
}
```

## 关键不变式

1. **日志顺序性**：Leader 的 `nextIndex[i]` 单调递增，Pipeline 响应必须按序处理
2. **提交安全性**：只有当前 term 的日志才能直接提交（旧 term 日志通过新 term 日志间接提交）
3. **Follower 日志一致性**：AppendEntries 的 `prevLogIndex/prevLogTerm` 校验保证

## 面试高频考点 📌

- Pipeline 复制如何保证有序性？（`reqSeq` + `requiredNextSeq` 机制）
- 为什么 Leader 不能直接提交旧 term 的日志？（Raft 论文 Figure 8 的 corner case）
- `BallotBox` 中的 `pendingMetaQueue` 为什么用 `SegmentList` 而不是普通 `ArrayList`？
- Follower 宕机重启后，Leader 如何重新同步日志？（探测 → 回退 → 重发）

## 生产踩坑 ⚠️

- `maxReplicatorInflightMsgs` 设置过大，Follower 内存压力大，可能 OOM
- 单条日志过大（> `maxBodySize`）会导致 RPC 超时，需要业务层分片
- Follower 磁盘 IO 慢导致 AppendEntries 超时，触发不必要的 Leader 切换
