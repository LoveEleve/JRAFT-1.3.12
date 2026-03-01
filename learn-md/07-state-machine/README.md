# 07 - 状态机（StateMachine）与 FSMCaller

## 学习目标

深入理解 JRaft 的状态机驱动机制，包括 `FSMCaller`（状态机调用器）的 Disruptor 异步架构、`Iterator`（日志迭代器）的使用，以及状态机的错误处理。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `StateMachine` | `StateMachine.java` | 用户实现的状态机接口 |
| `StateMachineAdapter` | `core/StateMachineAdapter.java` | 状态机适配器（提供默认实现） |
| `FSMCaller` | `FSMCaller.java` | 状态机调用器接口 |
| `FSMCallerImpl` | `core/FSMCallerImpl.java` | 状态机调用器实现（28KB，Disruptor 驱动） |
| `Iterator` | `Iterator.java` | 日志迭代器接口（用户在 onApply 中使用） |
| `IteratorImpl` | `core/IteratorImpl.java` | 日志迭代器实现 |
| `IteratorWrapper` | `core/IteratorWrapper.java` | 迭代器包装（异常保护） |
| `Closure` | `Closure.java` | 回调接口（通知客户端结果） |
| `TaskClosure` | `closure/TaskClosure.java` | 带 Task 的 Closure |
| `ClosureQueue` | `closure/ClosureQueue.java` | Closure 队列（按序回调） |

## FSMCaller 架构

```
BallotBox.commitAt()  →  FSMCaller.onCommitted(committedIndex)
                              │
                              ▼
                    Disruptor Ring Buffer
                    (ApplyTask 事件队列)
                              │
                              ▼
                    FSMCallerImpl.TaskHandler
                    (单线程消费，保证顺序)
                              │
                    ┌─────────┴──────────┐
                    │                    │
              onApply()           onSnapshotSave()
              onLeaderStart()     onSnapshotLoad()
              onLeaderStop()      onConfigurationCommitted()
              onError()
```

## FSMCaller 事件类型

```java
enum TaskType {
    IDLE,
    COMMITTED,          // 日志提交，触发 onApply
    SNAPSHOT_SAVE,      // 保存快照
    SNAPSHOT_LOAD,      // 加载快照
    LEADER_STOP,        // 失去 Leader 身份
    LEADER_START,       // 成为 Leader
    START_FOLLOWING,    // 开始跟随新 Leader
    STOP_FOLLOWING,     // 停止跟随
    SHUTDOWN,           // 关闭
    FLUSH,              // 刷新（等待队列清空）
    ERROR               // 错误
}
```

## StateMachine 接口

```java
public interface StateMachine {
    // 核心方法：应用已提交的日志
    void onApply(Iterator iter);
    
    // 快照相关
    void onSnapshotSave(SnapshotWriter writer, Closure done);
    boolean onSnapshotLoad(SnapshotReader reader);
    
    // Leader 变更通知
    void onLeaderStart(long term);
    void onLeaderStop(Status status);
    
    // 跟随者变更通知
    void onStartFollowing(LeaderChangeContext ctx);
    void onStopFollowing(LeaderChangeContext ctx);
    
    // 配置变更通知
    void onConfigurationCommitted(Configuration conf);
    
    // 错误处理
    void onError(RaftException e);
}
```

## Iterator（日志迭代器）使用

```java
// 用户在 onApply 中的标准写法
@Override
public void onApply(Iterator iter) {
    while (iter.hasNext()) {
        // 获取当前日志的用户数据
        ByteBuffer data = iter.getData();
        
        // 获取当前日志的 Closure（只有 Leader 上的请求才有）
        Closure done = iter.done();
        
        // 获取日志 index 和 term
        long index = iter.getIndex();
        long term = iter.getTerm();
        
        // 应用到状态机
        applyToStateMachine(data);
        
        // 通知客户端（只有 done != null 时才需要）
        if (done != null) {
            done.run(Status.OK());
        }
        
        iter.next();  // 移动到下一条
    }
}
```

**重要：** `iter.done()` 只在 Leader 节点上非 null，Follower 上始终为 null。

## IteratorImpl 核心逻辑

```java
// 批量处理：一次 onApply 调用可能包含多条日志
private long committedIndex;   // 本次批量提交的最大 index
private long currentIndex;     // 当前迭代位置
private LogEntry currentEntry; // 当前日志条目

// 异常处理：如果 onApply 中抛出异常
// IteratorWrapper 会捕获并调用 iter.setErrorAndRollback()
// 触发 FSMCaller.setError() → StateMachine.onError()
```

## ClosureQueue（回调队列）

```java
// 按序管理 Closure，保证回调顺序与日志顺序一致
// Leader 提交日志时注册 Closure
// FSMCaller 应用日志时按序弹出并调用
private final LinkedList<Closure> queue;
private long firstIndex;  // 队列中第一个 Closure 对应的 logIndex
```

## 错误处理路径 ⭐

```
StateMachine.onApply() 抛出异常
  ↓
IteratorWrapper 捕获
  ↓
iter.setErrorAndRollback(nApplied, status)
  ↓
FSMCallerImpl.setError(error)
  ↓
NodeImpl.onError(error)  → 节点进入 STATE_ERROR
  ↓
StateMachine.onError(RaftException)  ← 通知用户
```

**STATE_ERROR 后的行为：**
- 节点停止接受新的写请求
- 不再参与选举
- 需要人工介入修复

## 关键不变式

1. **顺序性**：`onApply` 中的日志严格按 index 顺序应用
2. **幂等性**：状态机必须能处理重复应用（快照恢复后可能重放）
3. **单线程**：FSMCaller 的 Disruptor 消费者是单线程，`onApply` 无需加锁

## 面试高频考点 📌

- `onApply` 为什么是批量的？（Disruptor 批量消费，提升吞吐量）
- Leader 和 Follower 的 `onApply` 有什么区别？（Leader 有 done 回调，Follower 没有）
- 状态机应用失败怎么办？（节点进入 STATE_ERROR，需要人工介入）
- `iter.done()` 为什么可能为 null？（Follower 节点、Leader 重启后重放旧日志）

## 生产踩坑 ⚠️

- `onApply` 中执行耗时操作（如同步 IO），导致 Disruptor 队列积压，影响整个集群
- 忘记调用 `iter.next()`，导致死循环
- `onSnapshotSave` 中忘记调用 `done.run()`，导致快照永远不完成
- 状态机不幂等，快照恢复后重放日志导致数据错误
