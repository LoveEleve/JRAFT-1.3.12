# 03 - Leader 选举

## 学习目标

深入理解 JRaft 的选举机制，包括 PreVote（预投票）、RequestVote（正式投票）、选举优先级、以及 Leader Transfer（主动转让）。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `NodeImpl` | `core/NodeImpl.java` | 选举核心逻辑（`preVote` / `electSelf` / `handleRequestVoteRequest`） |
| `Ballot` | `entity/Ballot.java` | 投票计数器（quorum 判断） |
| `BallotBox` | `core/BallotBox.java` | 日志提交投票箱 |
| `ElectionPriority` | `core/ElectionPriority.java` | 选举优先级枚举 |
| `RequestVoteRequestProcessor` | `rpc/impl/core/RequestVoteRequestProcessor.java` | 处理投票请求 |
| `RaftClientService` | `rpc/RaftClientService.java` | 发送投票 RPC |

## 选举流程时序图

```
Follower                    Candidate                   其他节点
   │                            │                          │
   │  electionTimer 超时        │                          │
   │──────────────────────────►│                          │
   │                            │  preVote(term+1)         │
   │                            │─────────────────────────►│
   │                            │◄─────────────────────────│
   │                            │  收到多数 PreVote 响应    │
   │                            │                          │
   │                            │  electSelf(term+1)       │
   │                            │  (term++ 持久化)         │
   │                            │─────────────────────────►│
   │                            │◄─────────────────────────│
   │                            │  收到多数 Vote 响应       │
   │                            │                          │
   │                            │  becomeLeader()          │
   │                            │  发送空 AppendEntries     │
   │                            │─────────────────────────►│
```

## PreVote（预投票）机制

**为什么需要 PreVote？**

防止网络分区恢复后，被隔离节点（term 已经很大）重新加入集群时，强制触发不必要的选举，破坏当前稳定的 Leader。

**PreVote 流程：**
1. Follower 选举超时，先发起 PreVote（不增加 term）
2. 其他节点判断：当前 Leader 是否活跃？请求方日志是否足够新？
3. 收到多数 PreVote 响应后，才真正发起 RequestVote（term+1）

**关键代码路径：**
```
NodeImpl.handleElectionTimeout()
  └── preVote()
        ├── 构造 RequestVoteRequest（preVote=true, term=currTerm+1）
        ├── 向所有 peers 发送 preVote RPC
        └── onPreVoteGranted() → electSelf()
```

## RequestVote（正式投票）

**投票授予条件（handleRequestVoteRequest）：**
1. `request.term > currTerm` — 请求方 term 更大
2. `votedFor == null || votedFor == candidateId` — 本轮未投票或已投给该候选人
3. 候选人日志不比自己旧（lastLogIndex/lastLogTerm 比较）

**日志新旧比较规则：**
```
if (request.lastLogTerm > myLastLogTerm) → 候选人更新
if (request.lastLogTerm == myLastLogTerm && request.lastLogIndex >= myLastLogIndex) → 候选人更新
```

## 选举优先级

JRaft 支持为节点设置优先级（`PeerId.priority`），优先级高的节点优先成为 Leader：

- 优先级范围：`[0, MAX_PRIORITY]`，0 表示不参与选举
- 实现：低优先级节点在选举超时时会额外等待一段时间，让高优先级节点先发起选举
- 相关类：`ElectionPriority`、`NodeImpl.allowLaunchElection()`

## Leader Transfer（主动转让）

```
NodeImpl.transferLeadershipTo(PeerId peer)
  1. 检查当前是 Leader
  2. 等待目标节点日志追上（catchUp）
  3. 发送 TimeoutNowRequest 给目标节点
  4. 目标节点收到后立即发起选举（跳过 PreVote）
  5. 当前 Leader 进入 STATE_TRANSFERRING，停止接受新请求
```

## Ballot（投票计数器）

```java
// Ballot 核心逻辑
public boolean grant(PeerId peer) {
    // 标记该 peer 已投票
    // 检查是否达到 quorum（多数派）
    return quorum <= 0;  // quorum 减到 0 表示获得多数票
}
```

**Quorum 计算：** `quorum = peers.size() / 2 + 1`

## 关键不变式

1. **同一 term 内，一个节点只能投票给一个候选人**（votedFor 持久化保证）
2. **Leader 的日志一定是最新的**（投票条件保证）
3. **PreVote 不增加 term**（避免无效选举污染 term）

## 面试高频考点 📌

- PreVote 解决了什么问题？没有 PreVote 会怎样？
- 为什么投票前要比较日志新旧？（保证 Leader Completeness 特性）
- 选举超时为什么要随机化？（避免多个节点同时超时，导致选票分裂）
- JRaft 的选举优先级是如何实现的？

## 生产踩坑 ⚠️

- 时钟漂移导致选举超时不准确，建议使用单调时钟
- 网络分区恢复后，旧 Leader 的 `stepDownTimer` 未触发，导致双 Leader 短暂共存
- `transferLeadershipTo()` 超时后，旧 Leader 不会自动 stepDown，需要业务层处理
