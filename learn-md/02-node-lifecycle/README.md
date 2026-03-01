# 02 - Node 生命周期与启动流程

## 学习目标

深入理解一个 Raft 节点从创建到销毁的完整生命周期，掌握 `NodeImpl.init()` 中各组件的初始化顺序与依赖关系。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `NodeImpl` | `core/NodeImpl.java` | 节点核心实现（145KB，重点方法：`init` / `shutdown`） |
| `RaftGroupService` | `RaftGroupService.java` | 节点启动入口，组装 NodeImpl + RpcServer |
| `State` | `core/State.java` | 节点状态枚举（STATE_FOLLOWER/CANDIDATE/LEADER 等） |
| `NodeOptions` | `option/NodeOptions.java` | 节点配置（选举超时、快照间隔、存储路径等） |
| `RaftOptions` | `option/RaftOptions.java` | Raft 协议参数 |
| `TimerManager` | `core/TimerManager.java` | 定时器管理（选举超时、心跳、快照定时器） |
| `RepeatedTimer` | `util/RepeatedTimer.java` | 可重置的周期定时器基类 |
| `NodeManager` | `NodeManager.java` | 全局节点注册表 |

## 节点状态机

```
                  ┌─────────────────┐
                  │  STATE_UNINITIALIZED │
                  └────────┬────────┘
                           │ init()
                  ┌────────▼────────┐
              ┌──►│ STATE_FOLLOWER  │◄──────────────────┐
              │   └────────┬────────┘                   │
              │            │ 选举超时                    │
              │   ┌────────▼────────┐                   │
              │   │STATE_CANDIDATE  │                   │
              │   └────────┬────────┘                   │
              │            │ 获得多数票                  │
              │   ┌────────▼────────┐    stepDown()     │
              │   │  STATE_LEADER   │───────────────────┘
              │   └────────┬────────┘
              │            │ transferLeadership()
              │   ┌────────▼────────┐
              └───│STATE_TRANSFERRING│
                  └─────────────────┘
                  
  STATE_ERROR ← 任意状态发生不可恢复错误
  STATE_SHUTTING_DOWN / STATE_SHUTDOWN ← shutdown() 调用
```

## NodeImpl.init() 初始化顺序

```
NodeImpl.init(NodeOptions opts)
  1. 校验配置参数（NodeOptions）
  2. 初始化 metaStorage（持久化 term/votedFor）
  3. 初始化 logStorage（RocksDB）
  4. 初始化 logManager（日志管理器）
  5. 初始化 fsmCaller（状态机调用器）
  6. 初始化 ballotBox（投票箱）
  7. 初始化 snapshotExecutor（快照执行器）
  8. 初始化 replicatorGroup（复制组，Leader 专用）
  9. 初始化 readOnlyService（线性一致读）
  10. 注册 RPC 处理器（RequestVote/AppendEntries/InstallSnapshot 等）
  11. 启动定时器（electionTimer / voteTimer / stepDownTimer / snapshotTimer）
  12. 加入 NodeManager 全局注册表
  13. 触发 bootstrap 或 stepDown(term) 进入 Follower 状态
```

## 关键定时器

| 定时器 | 触发条件 | 作用 |
|---|---|---|
| `electionTimer` | Follower 超时未收到心跳 | 发起预投票（PreVote） |
| `voteTimer` | Candidate 投票超时 | 重新发起选举 |
| `stepDownTimer` | Leader 检查 quorum 活跃性 | 防止脑裂后 Leader 继续服务 |
| `snapshotTimer` | 周期触发 | 触发快照保存 |

## 关键字段（NodeImpl）

```java
// 并发控制
private final ReadWriteLock readWriteLock;   // 保护大多数状态变更
private final Lock writeLock;
private final Lock readLock;

// 核心状态（volatile 保证可见性）
private volatile State state;               // 当前节点状态
private volatile long currTerm;             // 当前任期
private volatile PeerId leaderId;           // 当前 Leader

// 核心组件
private LogManager logManager;
private FSMCaller fsmCaller;
private BallotBox ballotBox;
private SnapshotExecutor snapshotExecutor;
private ReplicatorGroup replicatorGroup;
private ReadOnlyService readOnlyService;
```

## 生命周期方法

- `init(NodeOptions)` — 初始化所有子组件，启动定时器
- `shutdown(Closure)` — 有序关闭（先停止接收请求 → 等待 pending 完成 → 关闭存储）
- `join()` — 等待 shutdown 完成（阻塞）

## 学习重点

1. **父类构造链** ⭐：`NodeImpl` 实现了哪些接口？各接口的 `init()` 语义是什么？
2. **锁的粒度**：哪些操作需要 writeLock？哪些只需要 readLock？
3. **定时器重置时机**：`electionTimer` 在什么情况下被 reset？（收到心跳、收到 AppendEntries）
4. **shutdown 的异常路径** ⭐：如果 `fsmCaller.shutdown()` 抛异常，后续组件还会关闭吗？

## 面试高频考点 📌

- Raft 节点有哪些状态？状态转换的触发条件是什么？
- `NodeImpl` 初始化时为什么要先初始化 `metaStorage`？（term/votedFor 必须先恢复）
- `stepDownTimer` 的作用是什么？（Leader 活跃性检查，防止网络分区后继续服务）

## 生产踩坑 ⚠️

- `electionTimeoutMs` 设置过小（< 网络 RTT * 3）会导致频繁选举风暴
- 节点重启后 `metaStorage` 损坏会导致 term 回退，引发选举异常
- `shutdown()` 后未调用 `join()` 直接退出进程，可能导致 RocksDB WAL 未 flush
