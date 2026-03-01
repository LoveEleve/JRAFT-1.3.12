# 08 - 线性一致读（ReadIndex）

## 学习目标

深入理解 JRaft 的线性一致读实现，包括 `ReadIndex` 和 `LeaseRead` 两种模式，以及 `ReadOnlyService` 的内部机制。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `ReadOnlyService` | `ReadOnlyService.java` | 线性一致读服务接口 |
| `ReadOnlyServiceImpl` | `core/ReadOnlyServiceImpl.java` | 线性一致读实现（19KB） |
| `ReadIndexClosure` | `closure/ReadIndexClosure.java` | ReadIndex 回调 |
| `ReadIndexState` | `entity/ReadIndexState.java` | ReadIndex 请求状态 |
| `ReadIndexStatus` | `entity/ReadIndexStatus.java` | ReadIndex 状态（index + closure） |
| `ReadOnlyOption` | `option/ReadOnlyOption.java` | 读模式枚举（ReadOnlySafe / ReadOnlyLeaseBased） |
| `ReadIndexRequestProcessor` | `rpc/impl/core/ReadIndexRequestProcessor.java` | 处理 Follower 转发的 ReadIndex 请求 |

## 为什么需要线性一致读？

直接从 Follower 读取可能读到旧数据（Follower 日志可能落后）。  
直接从 Leader 读取也不安全（Leader 可能刚当选，旧 Leader 的提交还未同步）。

**线性一致读保证：** 读操作能看到在它之前所有已完成的写操作结果。

## ReadIndex 模式（默认，安全）

```
Client.readIndex(requestContext, closure)
  │
  ▼
NodeImpl.readIndex()
  │  如果是 Follower，转发给 Leader
  │  如果是 Leader，直接处理
  ▼
ReadOnlyServiceImpl.addRequest(context, closure)
  │  1. 记录当前 committedIndex 作为 readIndex
  │  2. 向所有 Follower 发送心跳（确认自己仍是 Leader）
  │
  ▼
  收到多数 Follower 的心跳响应
  │
  ▼
ReadOnlyServiceImpl.notifySuccess()
  │  等待 appliedIndex >= readIndex
  │
  ▼
  appliedIndex 追上 readIndex
  │
  ▼
closure.run(Status.OK, readIndex)
  │
  ▼
用户执行读操作（此时读到的数据一定是线性一致的）
```

## LeaseRead 模式（高性能，依赖时钟）

```
原理：Leader 在租约期内（electionTimeout * 0.9）不会被替换，
     因此可以直接读取，无需发送心跳确认。

风险：依赖时钟精度，时钟漂移可能导致读到旧数据。

配置：NodeOptions.setReadOnlyOptions(ReadOnlyOption.ReadOnlyLeaseBased)
```

## ReadOnlyServiceImpl 内部机制

### 请求批处理

```java
// 使用 Disruptor 批量处理 ReadIndex 请求
private Disruptor<ReadIndexEvent> disruptor;

// 批量发送心跳，合并多个 ReadIndex 请求
// 一次心跳可以确认多个 ReadIndex 请求
private final TreeMap<Long, List<ReadIndexStatus>> pendingNotifyStatus;
```

### 心跳确认流程

```
ReadOnlyServiceImpl.sendHeartbeat()
  │  向所有 Follower 发送 AppendEntries（空，isHeartbeat=true）
  │  携带当前 committedIndex 作为 readIndex
  │
  ▼
  收到多数响应后
  │
  ▼
ReadOnlyServiceImpl.onHeartbeatReturned()
  │  确认 readIndex 有效
  │  等待 appliedIndex >= readIndex
```

### appliedIndex 追踪

```java
// FSMCaller 每次 onApply 后更新 appliedIndex
// ReadOnlyService 轮询检查 appliedIndex
private final ScheduledExecutorService checkReplicator;

// 检查是否有 ReadIndex 请求可以响应
private void onApplied(long appliedIndex) {
    // 找到所有 readIndex <= appliedIndex 的请求
    // 调用对应的 closure
}
```

## Follower 处理 ReadIndex

```
Follower 收到 Client 的 readIndex 请求
  │
  ▼
NodeImpl.readIndex()
  │  转发给 Leader（ReadIndexRequest）
  │
  ▼
Leader: ReadIndexRequestProcessor
  │  处理后返回 readIndex 给 Follower
  │
  ▼
Follower 等待 appliedIndex >= readIndex
  │
  ▼
响应 Client
```

## ReadIndexClosure 使用示例

```java
// 用户代码示例
node.readIndex(requestContext, new ReadIndexClosure() {
    @Override
    public void run(Status status, long index, byte[] reqCtx) {
        if (status.isOk()) {
            // index 是安全读取点，此时读取状态机数据是线性一致的
            Object result = stateMachine.read(key);
            // 响应客户端
        } else {
            // 处理错误（如 Leader 切换、超时等）
        }
    }
});
```

## 两种模式对比

| 特性 | ReadIndex（Safe） | LeaseRead |
|---|---|---|
| 安全性 | 强一致，不依赖时钟 | 依赖时钟精度 |
| 性能 | 需要一次心跳 RTT | 无额外网络开销 |
| 适用场景 | 对一致性要求严格 | 对性能要求高，时钟可靠 |
| 配置 | `ReadOnlyOption.ReadOnlySafe` | `ReadOnlyOption.ReadOnlyLeaseBased` |

## 关键不变式

1. **ReadIndex ≤ CommittedIndex**：readIndex 取自请求时刻的 committedIndex
2. **心跳确认 Leader 身份**：确保 readIndex 时刻自己确实是 Leader
3. **等待 Apply**：必须等到 appliedIndex ≥ readIndex 才能响应

## 面试高频考点 📌

- ReadIndex 为什么需要发送心跳？（确认自己仍是 Leader，防止脑裂）
- LeaseRead 的风险是什么？（时钟漂移导致租约判断错误）
- Follower 能否直接处理 ReadIndex？（可以，但需要转发给 Leader 获取 readIndex）
- `appliedIndex` 和 `committedIndex` 的区别？（committed 是已达成 quorum，applied 是已应用到状态机）

## 生产踩坑 ⚠️

- ReadIndex 超时设置过短，在 Leader 切换时大量请求失败
- LeaseRead 在虚拟机环境中时钟漂移严重，导致读到旧数据
- `ReadIndexClosure.run()` 中执行耗时操作，阻塞 ReadOnlyService 的回调线程
