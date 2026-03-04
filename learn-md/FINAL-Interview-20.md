
# JRaft 面试 20 题 — 从源码到答案的终极指南

> **定位**：从 37 篇源码学习文档中提炼出 **20 道高频面试题**，每题标注：
> - 📖 **出处**：对应哪篇文档
> - 🔑 **关键类/方法**：直接定位源码
> - ⭐ **难度**：★（基础）★★（进阶）★★★（深度）
>
> **配套文档**：[架构全景图](./FINAL-Architecture-Panorama.md)

---

## 目录

**Part A — Raft 协议核心（Q1-Q8）**
1. [PreVote 解决什么问题？](#q1)
2. [一次写入请求经过几次 Disruptor？](#q2)
3. [ReadIndex 和 LeaseRead 有什么区别？](#q3)
4. [JRaft 如何保证新 Leader 包含所有已提交的日志？](#q4)
5. [JRaft 的成员变更是单步还是 Joint Consensus？](#q5)
6. [为什么新 Leader 要提交一条 noop 日志？](#q6)
7. [Follower 如何处理 AppendEntries 中的日志冲突？](#q7)
8. [JRaft 的选举优先级是如何实现的？](#q8)

**Part B — 工程实现深度（Q9-Q15）**
9. [Pipeline 复制模式如何工作？](#q9)
10. [BallotBox 为什么用 StampedLock 而不是 ReentrantReadWriteLock？](#q10)
11. [JRaft 的 3 种日志存储引擎有什么区别？](#q11)
12. [快照传输如何限流？分块大小如何配置？](#q12)
13. [NodeImpl 为什么是一个 145KB 的超大类？](#q13)
14. [JRaft 如何通过 SPI 实现存储层可插拔？](#q14)
15. [时间轮 HashedWheelTimer 的 O(1) 是怎么做到的？](#q15)

**Part C — 生产实战（Q16-Q20）**
16. [electionTimeoutMs 设置过大/过小分别有什么影响？](#q16)
17. [Transfer Leadership 和 stepDown 有什么区别？](#q17)
18. [Learner 和 Follower 的核心区别是什么？](#q18)
19. [JRaft 相对于 Raft 论文做了哪些工程扩展？](#q19)
20. [一个 JRaft 节点从启动到可服务，经历了哪些步骤？](#q20)

---

## Part A — Raft 协议核心

<a id="q1"></a>
### Q1：PreVote 解决什么问题？没有 PreVote 会怎样？ ⭐⭐

📖 **出处**：[03-Leader-Election](./03-leader-election/README.md) · [Raft-Paper-vs-JRaft](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md)
🔑 **关键方法**：`NodeImpl.preVote()` · `NodeImpl.handlePreVoteRequest()`

**答**：

PreVote 解决**网络分区恢复后的选举风暴**问题。

**没有 PreVote 的场景**：
1. 节点 A 被网络隔离，持续超时，Term 不断递增（如 Term=100）
2. 网络恢复后，A 发送 `RequestVote(term=100)` 给当前 Leader（Term=5）
3. Leader 收到更大 Term 后**被迫 stepDown**，集群短暂无 Leader
4. 这次选举完全不必要——A 的日志可能很旧，根本不可能当选

**有 PreVote 后**：
1. A 先发 `PreVote(term=6)`（当前 Term+1，但不持久化）
2. 正常节点检查 `isCurrentLeaderValid()` → Leader 仍活跃 → **拒绝 PreVote**
3. A 无法通过 PreVote 阶段 → Term 不会无限增长 → 不会干扰正常集群

**关键设计**：PreVote 的 Term 是 `currTerm+1`（探测值），**不修改本地 Term**，不持久化到 MetaStorage。

> ⚠️ PreVote 出自 Raft 论文作者博士论文 §9.6，不在公开论文正文中。

---

<a id="q2"></a>
### Q2：一次写入请求经过几次 Disruptor？每次的作用是什么？ ⭐⭐⭐

📖 **出处**：[S14-E2E-Write-Path](./00-e2e-write-path/S14-E2E-Write-Path.md)
🔑 **关键类**：`NodeImpl.applyDisruptor` · `LogManagerImpl.diskDisruptor` · `FSMCallerImpl.taskDisruptor`

**答**：**3 次 Disruptor**，分别在 Node 层、LogManager 层、FSMCaller 层。

| # | Disruptor | Producer | Consumer | 作用 | 批量参数 |
|---|-----------|----------|----------|------|---------|
| 1 | `applyQueue` | 多客户端线程（MULTI） | 单消费者 | 将 `apply(Task)` 请求从多线程汇聚为单线程 | `applyBatch=32` |
| 2 | `logQueue` | LogManager 单线程（SINGLE） | 单消费者 | 日志批量写 RocksDB + 触发 Replicator | `maxAppendBufferSize=256KB` |
| 3 | `fsmQueue` | BallotBox 回调（SINGLE） | 单消费者 | 多个 committed 事件合并，批量 apply 到 StateMachine | 合并连续 committedIndex 区间 |

**为什么用 3 个 Disruptor 而不是 1 个？**
- 职责分离：每层只关注自己的事（接收请求 / 持久化 / 应用）
- 背压隔离：日志持久化慢不会阻塞客户端提交，FSM 慢也不会阻塞日志持久化
- 批量优化：每层可以独立做批量合并，3 级批量效果叠加

---

<a id="q3"></a>
### Q3：ReadIndex 和 LeaseRead 有什么区别？什么场景用哪个？ ⭐⭐

📖 **出处**：[08-ReadIndex](./08-read-index/README.md) · [S21-E2E-Read-Path](./00-e2e-read-path/S21-E2E-Read-Path.md)
🔑 **关键类**：`ReadOnlyServiceImpl` · `ReadOnlyOption`

**答**：

| 维度 | ReadIndex (ReadOnlySafe) | LeaseRead (ReadOnlyLeaseBased) |
|------|--------------------------|-------------------------------|
| **确认方式** | 发心跳给多数派，确认自己仍是 Leader | 检查本地 Leader 租约是否有效 |
| **网络开销** | 1 次 RTT（心跳） | 0 次网络（纯本地检查） |
| **安全性** | 完全安全（不依赖时钟） | 依赖时钟精度（NTP 跳变可能返回过期数据） |
| **延迟** | 高一些（等心跳响应） | 极低（微秒级） |
| **降级机制** | — | 租约过期时自动降级为 ReadOnlySafe |

**LeaseRead 的租约公式**：
```
leaderLeaseTimeoutMs = electionTimeoutMs * leaderLeaseTimeRatio / 100
默认 = 1000ms * 90 / 100 = 900ms
有效条件：monotonicMs() - lastLeaderTimestamp < leaderLeaseTimeoutMs
```

**适用场景**：
- **金融交易等强一致场景** → ReadOnlySafe
- **高频查询、可接受极小概率过期的场景** → ReadOnlyLeaseBased

---

<a id="q4"></a>
### Q4：JRaft 如何保证新 Leader 一定包含所有已提交的日志？ ⭐⭐⭐

📖 **出处**：[03-Leader-Election](./03-leader-election/README.md) · [Raft-Paper-vs-JRaft §5.4](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md)
🔑 **关键方法**：`NodeImpl.handleRequestVoteRequest()` · `LogId.compareTo()`

**答**：通过**选举限制（Election Restriction）** 保证——投票者只投给**日志至少和自己一样新**的候选人。

**"至少一样新"的判断**（`LogId.compareTo()`）：
1. 先比较最后一条日志的 **Term**：Term 大的更新
2. Term 相同再比较 **Index**：Index 大的更新

**为什么能保证**：
- 已提交的日志一定存在于多数派节点上
- 候选人要当选必须获得多数派投票
- 这两个"多数派"必有交集（至少一个节点）
- 交集节点只会投给日志 ≥ 自己的候选人
- → 当选者的日志一定 ≥ 已提交日志

**补充规则**：Leader **不能通过计数副本数来提交旧 Term 的日志**。只有当前 Term 的日志被多数派确认后，旧日志才"间接提交"。这就是 `becomeLeader()` 后提交配置日志（充当 noop）的原因。

---

<a id="q5"></a>
### Q5：JRaft 的成员变更是单步还是 Joint Consensus？ ⭐⭐⭐

📖 **出处**：[09-Membership-Change](./09-membership-change/README.md) · [Raft-Paper-vs-JRaft §6](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md)
🔑 **关键类**：`ConfigurationCtx` · Stage 枚举

**答**：**两者都支持**。底层通过 `ConfigurationCtx` 实现了 Joint Consensus 两阶段机制。

```
STAGE_NONE → STAGE_CATCHING_UP(可选) → STAGE_JOINT → STAGE_STABLE → STAGE_NONE
```

| API | 模式 | 说明 |
|-----|------|------|
| `addPeer()` / `removePeer()` | 单步便捷 API | 一次只加/减一个节点，底层仍走 Joint |
| `changePeers(newConf)` | Joint Consensus | 批量变更，显式经历 `STAGE_JOINT → STAGE_STABLE` |

**STAGE_JOINT 阶段**：写入 `C_old,new` 日志，所有决策需要**同时获得新旧两个配置的多数派**（`Ballot` 的 `quorum` 和 `oldQuorum` 都必须 ≤ 0）。

---

<a id="q6"></a>
### Q6：为什么新 Leader 当选后要提交一条 noop 日志？ ⭐⭐

📖 **出处**：[03-Leader-Election](./03-leader-election/README.md) · [Raft-Paper-vs-JRaft §5.4](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md)
🔑 **关键方法**：`NodeImpl.becomeLeader()` · `ConfigurationCtx.flush()`

**答**：

新 Leader 无法确定哪些旧 Term 的日志已被 committed。通过提交一条**当前 Term 的日志**并获得多数派确认，可以：
1. **确认 commitIndex**：当前 Term 日志被提交后，之前所有日志也被"间接提交"（Log Matching Property）
2. **满足安全性规则**：Raft 不允许直接提交旧 Term 日志（论文 Figure 8 证明了直接提交可能不安全）

**JRaft 的实现细节**：JRaft 不是提交空的 noop，而是提交一条**配置变更日志**（`ENTRY_TYPE_CONFIGURATION`），记录当前集群配置。这样既起到了 noop 的作用，又在新 Leader 日志中固化了最新配置。

---

<a id="q7"></a>
### Q7：Follower 如何处理 AppendEntries 中的日志冲突？ ⭐⭐

📖 **出处**：[S17-Follower-RPC-Handling](./04-log-replication/S17-Follower-RPC-Handling.md) · [04-Log-Replication](./04-log-replication/README.md)
🔑 **关键方法**：`NodeImpl.handleAppendEntriesRequest()`

**答**：

```
1. 检查 prevLogIndex/prevLogTerm 是否匹配
   → 不匹配：返回失败（Leader 会回退 nextIndex）

2. 逐条比对新日志与本地日志的 Term
   → 发现第一个冲突点 → truncateSuffix(冲突index - 1)
   → 用 Leader 的日志覆盖

3. 更新 commitIndex = min(leaderCommit, 最新日志 index)
```

**Leader 的回退策略**（两分支）：
- `response.lastLogIndex + 1 < nextIndex`（Follower 日志远远落后）→ 直接 `nextIndex = lastLogIndex + 1`（**快速跳过**）
- 否则 → `nextIndex--`（**逐个回退**，处理 Term 冲突）

---

<a id="q8"></a>
### Q8：JRaft 的选举优先级是如何实现的？高优先级节点宕机后集群还能选出 Leader 吗？ ⭐⭐

📖 **出处**：[03-Leader-Election](./03-leader-election/README.md)
🔑 **关键方法**：`NodeImpl.allowLaunchElection()` · `NodeImpl.decayTargetPriority()`

**答**：

| Priority 值 | 含义 |
|-------------|------|
| `-1` (Disabled) | 禁用优先级，所有节点平等 |
| `0` (NotElected) | 永远不参与选举 |
| `> 0` | 数值越大优先级越高 |

**实现原理**：
1. 节点记录集群中最高优先级为 `targetPriority`
2. `handleElectionTimeout()` → `allowLaunchElection()` 检查 `myPriority < targetPriority` → 跳过本轮
3. 连续 2 次超时未选出 Leader → `decayTargetPriority()`：`targetPriority -= max(gap, targetPriority/5)`
4. 衰减后 `myPriority >= targetPriority` → 允许发起选举

**所以高优先级节点宕机后**，低优先级节点经过 2 次选举超时（约 2-4 秒）后，`targetPriority` 衰减到足够低，集群**仍然能选出 Leader**。

---

## Part B — 工程实现深度

<a id="q9"></a>
### Q9：Pipeline 复制模式如何工作？和逐个确认模式有什么区别？ ⭐⭐⭐

📖 **出处**：[S18-Replicator-Pipeline](./04-log-replication/S18-Replicator-Pipeline.md) · [04-Log-Replication](./04-log-replication/README.md)
🔑 **关键类**：`Replicator` · `Inflight` · `reqSeq/requiredNextSeq`

**答**：

**逐个确认模式（论文方式）**：
```
Leader → AppendEntries(1) → 等响应 → AppendEntries(2) → 等响应
```

**Pipeline 模式（JRaft 扩展）**：
```
Leader → AE(1) → AE(2) → AE(3) → ... (不等响应)
         ← Resp(1) ← Resp(2) ← Resp(3) ← ...
```

**核心机制**：
1. **Inflight 队列**：跟踪已发送未确认的请求，最多 `maxReplicatorInflightMsgs=256` 个
2. **序号系统**：`reqSeq`（发送序号）+ `requiredNextSeq`（期望下一个响应序号），保证**按序处理响应**
3. **乱序响应处理**：如果收到的响应序号 ≠ `requiredNextSeq`，说明有乱序或丢失，**重置 Pipeline 从头重发**

**三层流控**：
| 层次 | 参数 | 默认值 | 限制 |
|------|------|--------|------|
| Inflight 窗口 | `maxReplicatorInflightMsgs` | 256 | 最大 in-flight 请求数 |
| 单次条目数 | `maxEntriesSize` | 1024 | 单次 AE 最大条目数 |
| 单次字节数 | `maxBodySize` | 512KB | 单次 AE 最大字节数 |

---

<a id="q10"></a>
### Q10：BallotBox 为什么用 StampedLock 而不是 ReentrantReadWriteLock？ ⭐⭐

📖 **出处**：[S14-E2E-Write-Path](./00-e2e-write-path/S14-E2E-Write-Path.md) · [04-Log-Replication](./04-log-replication/README.md)
🔑 **关键类**：`BallotBox` · `StampedLock`

**答**：

`BallotBox.getLastCommittedIndex()` 是**读多写少**的典型场景：
- **读操作**（`getLastCommittedIndex`）：Replicator 心跳、ReadIndex、各种状态查询，非常频繁
- **写操作**（`commitAt`）：只在 Replicator 收到成功响应时调用

`StampedLock` 的**乐观读**在无竞争时**完全无锁**（只读一个 stamp 值并验证），比 `ReentrantReadWriteLock` 少了 CAS 操作，性能更高。

```java
// StampedLock 乐观读模式
long stamp = this.stampedLock.tryOptimisticRead();
long value = this.lastCommittedIndex;  // 无锁读
if (!this.stampedLock.validate(stamp)) {
    // 被写入打断，退化为悲观读
    stamp = this.stampedLock.readLock();
    value = this.lastCommittedIndex;
    this.stampedLock.unlockRead(stamp);
}
```

---

<a id="q11"></a>
### Q11：JRaft 的 3 种日志存储引擎有什么区别？ ⭐⭐

📖 **出处**：[05-Log-Storage](./05-log-storage/README.md) · [S1-SegmentLog](./05b-segment-log-storage/S1-RocksDBSegmentLogStorage.md) · [S15-BDB](./05-log-storage/S15-BDB-LogStorage.md)
🔑 **关键类**：`RocksDBLogStorage` · `RocksDBSegmentLogStorage` · `BDBLogStorage`

**答**：

| 维度 | RocksDB (旧版) | SegmentLog (新版) | BDB |
|------|---------------|-------------------|-----|
| **索引存储** | RocksDB | RocksDB | BerkeleyDB |
| **数据存储** | RocksDB | SegmentFile (mmap) | BerkeleyDB |
| **写放大** | 高（LSM Compaction） | 低（数据不经过 LSM） | 中 |
| **外部依赖** | RocksDB JNI | RocksDB JNI + mmap | 纯 Java |
| **适用场景** | 通用 | 大 value 日志 | 纯 Java 部署 |
| **推荐度** | 一般 | ⭐⭐⭐ 生产推荐 | 特殊场景 |

**SegmentLog 的核心创新**：数据和索引分离——RocksDB 只存 `index → (fileNo, offset)` 的索引，日志数据写入自管理的 `SegmentFile`（基于 mmap），避免大 value 进入 LSM Compaction。

---

<a id="q12"></a>
### Q12：快照传输如何限流？分块大小如何配置？ ⭐

📖 **出处**：[S10-Remote-File-Copier](./06-snapshot/S10-Remote-File-Copier.md) · [06-Snapshot](./06-snapshot/README.md)
🔑 **关键类**：`CopySession` · `ThroughputSnapshotThrottle` · `RaftOptions.maxByteCountPerRpc`

**答**：

**分块传输**：`CopySession` 按 `maxByteCountPerRpc`（默认 128KB）分块发送 `GetFileRequest`，每块传输完成后发送下一块，直到收到 EOF 标记。

**限流机制**：`ThroughputSnapshotThrottle` 基于**滑动窗口**控制吞吐量：
- 设定每个窗口期（默认 1 秒）允许传输的最大字节数
- 超过限额 → 阻塞等待下一个窗口
- 防止快照传输打满网络带宽，影响正常 Raft 心跳和日志复制

**文件去重**：`filterBeforeCopyRemote` 在传输前比对文件名 + checksum，跳过 Follower 本地已有的相同文件。

---

<a id="q13"></a>
### Q13：NodeImpl 为什么是一个 145KB 的超大类？不应该拆分吗？ ⭐⭐

📖 **出处**：[01-Overview](./01-overview/README.md) · [S20-NodeImpl-StateMachine](./02-node-lifecycle/S20-NodeImpl-StateMachine.md)
🔑 **关键类**：`NodeImpl` · `LongHeldDetectingReadWriteLock`

**答**：

这是**一致性优先于代码整洁**的设计取舍。

Raft 协议的**核心不变式**（如"同一 term 不能投两次票"、"state 转换必须原子"）必须在**同一个锁保护**下维护。`NodeImpl` 持有的关键状态：

```
currTerm + votedId + state + leaderId + conf + ballotBox + ...
```

这些状态的修改**高度耦合**——例如 `stepDown()` 需要同时修改 `state`、`currTerm`、`votedId`、启停定时器、清理 BallotBox。如果拆分成多个类，就需要**跨类锁协调**，反而更复杂、更容易出 bug。

**JRaft 的 NodeImpl 有 9 种状态、23 处状态转换**，全部由一把 `ReadWriteLock` 保护。

---

<a id="q14"></a>
### Q14：JRaft 如何通过 SPI 实现存储层可插拔？如何自定义一个 LogStorage？ ⭐⭐

📖 **出处**：[S11-SPI](./02-node-lifecycle/S11-SPI.md)
🔑 **关键类**：`JRaftServiceLoader` · `JRaftServiceFactory` · `DefaultJRaftServiceFactory`

**答**：

**SPI 加载机制**：
1. `JRaftServiceLoader`（增强版 Java ServiceLoader）扫描 `META-INF/services/` 配置文件
2. 加载用户自定义实现类，按 `@SPI` 注解的优先级排序
3. `DefaultJRaftServiceFactory.createLogStorage()` 默认创建 `RocksDBLogStorage`

**自定义 LogStorage 的步骤**：
1. 实现 `LogStorage` 接口
2. 实现 `JRaftServiceFactory`，在 `createLogStorage()` 返回自定义实现
3. 在 `META-INF/services/com.alipay.sofa.jraft.JRaftServiceFactory` 文件中注册
4. 或直接通过 `NodeOptions.setServiceFactory()` 手动设置

**RPC 层同理**：`RaftRpcFactory` 是 SPI 接口，`BoltRaftRpcFactory`（默认）和 `GrpcRaftRpcFactory` 通过 SPI 切换。

---

<a id="q15"></a>
### Q15：时间轮 HashedWheelTimer 的 O(1) 添加和触发是怎么做到的？ ⭐⭐

📖 **出处**：[S12-HashedWheelTimer](./11-concurrency-infra/S12-HashedWheelTimer.md)
🔑 **关键类**：`HashedWheelTimer` · `HashedWheelBucket` · `HashedWheelTimeout`

**答**：

**数据结构**：
- `wheel[]`：固定大小的数组（默认 512 格），每格是一个 `HashedWheelBucket`（双向链表）
- `Worker` 线程：每隔 `tickDuration`（默认 100ms）推进一格

**添加任务 O(1)**：
```
计算 deadline = currentTime + delay
计算 wheelIndex = (deadline / tickDuration) % wheel.length
直接插入 wheel[wheelIndex] 的链表尾部
```

**触发任务 O(1) 摊销**：
```
Worker 线程每 tick 推进一格 → 遍历当前格的链表
  → 剩余轮数 == 0 → 触发
  → 剩余轮数 > 0 → 轮数减 1，留在原位等下一圈
```

**与 `ScheduledExecutorService` 对比**：后者使用优先队列（堆），添加和取消是 O(log N)；时间轮在大量定时任务场景下更优。JRaft 有 4 种定时器 × N 个 Raft 组，任务数量可能很大。

---

## Part C — 生产实战

<a id="q16"></a>
### Q16：electionTimeoutMs 设置过大/过小分别有什么影响？ ⭐

📖 **出处**：[S16-Configuration-Guide](./01-overview/S16-Configuration-Guide.md) · [03-Leader-Election](./03-leader-election/README.md)
🔑 **关键配置**：`NodeOptions.electionTimeoutMs`（默认 1000ms）

**答**：

| 设置 | 影响 |
|------|------|
| **过小**（如 200ms） | 网络抖动、GC STW 时频繁触发选举，集群不稳定。每次选举需要 Term+1 + 多数派投票，期间集群不可写 |
| **过大**（如 30s） | Leader 宕机后，Follower 需等待 30s 才能发起选举，**故障恢复时间过长** |
| **推荐值** | 局域网 1000-3000ms，跨机房 3000-5000ms |

**关联参数**：
- `stepDownTimer` 间隔 = `electionTimeoutMs / 2`
- Leader 租约 = `electionTimeoutMs * leaderLeaseTimeRatio / 100`（默认 90%）
- 选举随机化范围 = `[electionTimeoutMs, electionTimeoutMs + maxElectionDelayMs)`

---

<a id="q17"></a>
### Q17：Transfer Leadership 和 stepDown 有什么区别？ ⭐⭐

📖 **出处**：[S4-Transfer-Leadership](./03-leader-election/S4-Transfer-Leadership.md)
🔑 **关键方法**：`NodeImpl.transferLeadershipTo()` · `NodeImpl.stepDown()`

**答**：

| 维度 | Transfer Leadership | stepDown |
|------|--------------------|---------  |
| **触发方** | 运维主动调用 | 发现更高 Term 被动触发 |
| **目标** | 指定目标节点当选 | 无目标，等待集群重新选举 |
| **过程** | 停止接受写入 → 等目标日志追平 → 发 TimeoutNow → 目标跳过 PreVote 直接选举 | 直接转为 Follower，重启 electionTimer |
| **可写性** | Transfer 期间集群**不可写**（STATE_TRANSFERRING 拒绝 apply） | stepDown 后等选出新 Leader 后恢复 |
| **确定性** | 高——目标节点大概率当选 | 低——任何节点都可能当选 |
| **超时处理** | 超时后恢复为 Leader 状态，继续服务 | 无超时概念 |
| **使用场景** | 滚动升级、负载均衡 | 被动降级 |

---

<a id="q18"></a>
### Q18：Learner 和 Follower 的核心区别是什么？ ⭐

📖 **出处**：[S5-Learner](./09-membership-change/S5-Learner.md)
🔑 **关键类**：`Configuration.learners` · `ReplicatorType`

**答**：

| 维度 | Follower | Learner |
|------|----------|---------|
| **参与投票** | ✅ 参与 PreVote / Vote | ❌ 不参与 |
| **影响 Quorum** | ✅ 计入多数派 | ❌ 不计入 |
| **接收日志** | ✅ | ✅（通过 Replicator） |
| **可以当选 Leader** | ✅ | ❌ |
| **触发选举** | ✅ | ❌（electionTimer 不启动） |
| **使用场景** | 正常数据副本 | 只读副本、跨机房灾备、新节点预热 |

**新增 Learner 不会影响集群可用性**——因为 Learner 不影响 Quorum 计算，即使所有 Learner 宕机，集群的写入和选举不受影响。

---

<a id="q19"></a>
### Q19：JRaft 相对于 Raft 论文做了哪些工程扩展？（说出 10 个以上得高分） ⭐⭐⭐

📖 **出处**：[Raft-Paper-vs-JRaft](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md)

**答**：JRaft 在 Raft 论文基础上做了 **15 项工程扩展**：

| # | 扩展 | 价值 |
|---|------|------|
| 1 | **PreVote** 两阶段预投票 | 防止分区恢复后选举风暴 |
| 2 | **Election Priority** 优先级选举 | 指定 Leader 偏好节点 |
| 3 | **Transfer Leadership** 主动让渡 | 滚动升级必备 |
| 4 | **Learner** 只读副本角色 | 读扩展、跨机房灾备 |
| 5 | **Pipeline** 复制模式 | 高延迟网络吞吐量提升数十倍 |
| 6 | **4 层批量优化** | apply/log/entries/body 多级合并 |
| 7 | **ReadIndex** 完整协议 | 线性一致读不写日志 |
| 8 | **LeaseRead** 租约读 | 零网络开销读（自动降级保安全） |
| 9 | **快照限流** SnapshotThrottle | 防止快照传输打满带宽 |
| 10 | **快照文件去重** | 减少重复文件传输 |
| 11 | **Disruptor 异步流水线** | 3 个 Ring Buffer 高性能串联 |
| 12 | **Multi-Raft Group** | 单进程运行多个 Raft 组，共享资源 |
| 13 | **多存储引擎** SPI 可扩展 | RocksDB / BDB / SegmentLog |
| 14 | **Metrics 全链路可观测** | 生产环境监控必备 |
| 15 | **nextIndex 快速回退** | 日志差距大时一步到位 |

---

<a id="q20"></a>
### Q20：一个 JRaft 节点从启动到可服务，经历了哪些步骤？ ⭐⭐

📖 **出处**：[02-Node-Lifecycle](./02-node-lifecycle/README.md) · [S8-Bootstrap](./02-node-lifecycle/S8-Bootstrap.md)
🔑 **关键方法**：`NodeImpl.init()`

**答**：`NodeImpl.init()` 的 **14 步初始化流程**：

```
① 参数校验 & 基础赋值（serviceFactory / options / metrics）
② 初始化 timerManager（定时器调度线程池）
③ 创建 4 个定时器（election / vote / stepDown / snapshot，只创建不启动）
④ 创建 ConfigurationManager
⑤ 创建 applyDisruptor（异步处理 apply 请求）
⑥ new FSMCallerImpl()（先占位，解决循环依赖）
⑦ initLogStorage()（创建 LogStorage + LogManager，依赖 fsmCaller 引用）
⑧ initMetaStorage()（加载持久化的 term + votedFor，恢复选举状态）
⑨ initFSMCaller()（真正初始化，此时 logManager 已就绪）
⑩ initSnapshotStorage()（可选，snapshotUri 为空则跳过）
⑪ 日志一致性检查 + 恢复集群配置（从日志或 options 获取）
⑫ initBallotBox()（依赖 snapshot + logManager 已就绪）
⑬ 初始化 replicatorGroup + rpcService + readOnlyService → state = FOLLOWER
⑭ 启动 snapshotTimer → stepDown(currTerm) 启动 electionTimer
   → 单节点集群? → electSelf() 直接成为 Leader
```

**关键依赖链**：`fsmCaller 占位 → logStorage → metaStorage → fsmCaller 真正初始化 → snapshot → ballotBox`

这个顺序解决了 `LogManager ↔ FSMCaller` 的**循环依赖**——先 `new FSMCallerImpl()`（空壳），再初始化 LogManager（需要 fsmCaller 引用报告错误），最后再 `fsmCaller.init()`。

---

## 📊 按主题分类速查

### 选举相关：Q1, Q4, Q6, Q8, Q17
### 日志复制相关：Q2, Q7, Q9, Q10, Q11
### 线性一致读相关：Q3
### 成员变更相关：Q5, Q18
### 快照相关：Q12
### 架构设计相关：Q13, Q14, Q15, Q19, Q20
### 生产运维相关：Q16, Q17, Q18

---

> **配套阅读**：[架构全景图 ←](./FINAL-Architecture-Panorama.md)
