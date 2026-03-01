# 11 - Disruptor 与并发基础设施

## 学习目标

深入理解 JRaft 中 Disruptor 的使用模式、自定义并发工具（MpscSingleThreadExecutor、FixedThreadsExecutorGroup）以及定时器实现。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `DisruptorBuilder` | `util/DisruptorBuilder.java` | Disruptor 构建器（封装配置） |
| `LogExceptionHandler` | `util/LogExceptionHandler.java` | Disruptor 异常处理器 |
| `MpscSingleThreadExecutor` | `util/concurrent/MpscSingleThreadExecutor.java` | MPSC 单线程执行器（13KB） |
| `DefaultFixedThreadsExecutorGroup` | `util/concurrent/DefaultFixedThreadsExecutorGroup.java` | 固定线程组 |
| `DefaultSingleThreadExecutor` | `util/concurrent/DefaultSingleThreadExecutor.java` | 单线程执行器 |
| `RepeatedTimer` | `util/RepeatedTimer.java` | 可重置周期定时器（7KB） |
| `ThreadPoolUtil` | `util/ThreadPoolUtil.java` | 线程池工具（13KB） |
| `ThreadPoolsFactory` | `util/ThreadPoolsFactory.java` | 线程池工厂 |
| `Recyclers` | `util/Recyclers.java` | 对象池（14KB，仿 Netty） |
| `SegmentList` | `util/SegmentList.java` | 分段列表（12KB） |
| `NonReentrantLock` | `util/concurrent/NonReentrantLock.java` | 不可重入锁（检测死锁） |
| `LongHeldDetectingReadWriteLock` | `util/concurrent/LongHeldDetectingReadWriteLock.java` | 长持锁检测读写锁 |

## Disruptor 在 JRaft 中的使用

JRaft 在多个关键路径使用 Disruptor 实现高性能异步处理：

| 使用位置 | 事件类型 | 作用 |
|---|---|---|
| `LogManagerImpl` | `StableClosureEvent` | 异步批量写日志 |
| `FSMCallerImpl` | `ApplyTask` | 异步驱动状态机 |
| `ReadOnlyServiceImpl` | `ReadIndexEvent` | 批量处理 ReadIndex 请求 |

### DisruptorBuilder 使用示例

```java
// JRaft 封装的 Disruptor 构建器
Disruptor<LogManagerImpl.StableClosureEvent> disruptor = DisruptorBuilder
    .<LogManagerImpl.StableClosureEvent>newInstance()
    .setRingBufferSize(opts.getDisruptorBufferSize())  // 必须是 2 的幂
    .setEventFactory(new StableClosureEventFactory())
    .setThreadFactory(new NamedThreadFactory("JRaft-LogManager-Disruptor-", true))
    .setProducerType(ProducerType.MULTI)   // 多生产者
    .setWaitStrategy(new BlockingWaitStrategy())
    .build();

disruptor.handleEventsWith(new StableClosureEventHandler());
disruptor.setDefaultExceptionHandler(new LogExceptionHandler<>(getClass().getName()));
disruptor.start();
```

### Disruptor 批量消费模式

```java
// EventHandler 的 onEvent 会被批量调用
// endOfBatch=true 时表示当前批次结束，可以做批量提交
@Override
public void onEvent(StableClosureEvent event, long sequence, boolean endOfBatch) {
    // 累积事件
    closures.add(event.done);
    entries.addAll(event.entries);
    
    if (endOfBatch) {
        // 批量写入 RocksDB
        logStorage.appendEntries(entries);
        // 批量回调
        for (Closure done : closures) {
            done.run(Status.OK());
        }
        closures.clear();
        entries.clear();
    }
}
```

## MpscSingleThreadExecutor（MPSC 单线程执行器）

**MPSC = Multi-Producer Single-Consumer**，基于 Netty 的 `MpscQueue` 实现：

```java
// 特点：
// 1. 多个生产者可以并发提交任务（无锁 CAS）
// 2. 单个消费者线程顺序执行（无需加锁）
// 3. 比 LinkedBlockingQueue 性能更高（减少锁竞争）

// 使用场景：Replicator 的任务执行
MpscSingleThreadExecutor executor = new MpscSingleThreadExecutor(
    maxPendingTasksPerThread, 
    new NamedThreadFactory("Replicator-", true)
);
```

## FixedThreadsExecutorGroup（固定线程组）

```java
// 将任务路由到固定线程，保证相同 key 的任务在同一线程执行（有序性）
FixedThreadsExecutorGroup group = new DefaultFixedThreadsExecutorGroup(
    nThreads,
    new DefaultFixedThreadsExecutorGroupFactory()
);

// 按 key 路由（如 peerId.hashCode()）
group.next(peerId.hashCode()).execute(task);
```

## RepeatedTimer（可重置周期定时器）

```java
// JRaft 自定义的定时器，支持：
// 1. 周期执行（run() 方法）
// 2. 随时 reset()（重置倒计时，用于心跳收到后重置选举超时）
// 3. 随机抖动（避免选举风暴）

public abstract class RepeatedTimer {
    // 子类实现具体逻辑
    protected abstract void onTrigger();
    
    // 重置定时器（延迟触发）
    public void reset();
    
    // 重置并指定超时时间
    public void reset(int timeoutMs);
}

// 选举定时器示例
electionTimer = new RepeatedTimer("JRaft-ElectionTimer", opts.getElectionTimeoutMs()) {
    @Override
    protected void onTrigger() {
        handleElectionTimeout();
    }
    
    @Override
    protected int adjustTimeout(int timeoutMs) {
        // 随机抖动：timeoutMs + random(0, electionTimeoutMs / 2)
        return randomTimeout(timeoutMs);
    }
};
```

## Recyclers（对象池）

仿 Netty 的 `Recycler` 实现，减少 GC 压力：

```java
// 使用对象池的类：LogEntry、RecyclableByteBufferList 等
public class LogEntry implements Recyclable {
    private static final Recyclers<LogEntry> recyclers = new Recyclers<>(512);
    
    public static LogEntry getInstance() {
        return recyclers.get();
    }
    
    @Override
    public boolean recycle() {
        // 重置字段，归还到对象池
        return recyclers.recycle(this, handle);
    }
}
```

## SegmentList（分段列表）

```java
// 解决 ArrayList 扩容时大内存拷贝的问题
// 内部维护多个固定大小的 segment 数组
// 适合 LogManager 的内存日志缓存（logsInMemory）

// 特点：
// 1. 随机访问 O(1)（两次数组寻址）
// 2. 尾部追加 O(1)（无需拷贝）
// 3. 头部截断 O(1)（直接丢弃第一个 segment）
```

## 线程模型总览

```
┌─────────────────────────────────────────────────────────────┐
│  用户线程（apply/readIndex）                                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│  Disruptor: LogManager 写入线程（单线程）                     │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│  Disruptor: FSMCaller 状态机线程（单线程）                    │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│  Replicator 线程组（每个 Follower 一个 MpscSingleThread）     │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  RPC 处理线程池（Bolt/gRPC IO 线程 + 业务线程池）             │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  定时器线程（HashedWheelTimer）                               │
└─────────────────────────────────────────────────────────────┘
```

## 面试高频考点 📌

- JRaft 为什么用 Disruptor 而不是 `BlockingQueue`？（无锁 RingBuffer，批量消费，更高吞吐）
- `MpscSingleThreadExecutor` 相比 `SingleThreadExecutor` 的优势？（无锁 MPSC 队列，减少竞争）
- `RepeatedTimer` 的随机抖动如何防止选举风暴？
- `SegmentList` 的头部截断为什么是 O(1)？（直接丢弃第一个 segment 引用）

## 生产踩坑 ⚠️

- Disruptor `RingBufferSize` 设置过小，生产者阻塞，导致写入延迟飙升
- `FSMCaller` 的 Disruptor 队列积压，`onApply` 执行慢，导致 `committedIndex` 和 `appliedIndex` 差距越来越大
- 对象池 `Recyclers` 在高并发下 ThreadLocal 内存泄漏（需要注意线程池复用场景）
