# 12 - RheaKV：基于 JRaft 的分布式 KV 存储

## 学习目标

深入理解 RheaKV 如何在 JRaft 之上构建分布式 KV 存储，包括多 Region 分片、Placement Driver（PD）、存储引擎（RocksDB/Memory）以及客户端路由与故障转移。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `RheaKVStore` | `rheakv-core/.../client/RheaKVStore.java` | KV 存储客户端接口 |
| `DefaultRheaKVStore` | `rheakv-core/.../client/DefaultRheaKVStore.java` | KV 存储客户端实现（93KB） |
| `StoreEngine` | `rheakv-core/.../StoreEngine.java` | 存储引擎（管理多个 RegionEngine） |
| `RegionEngine` | `rheakv-core/.../RegionEngine.java` | 单个 Region 的 Raft 引擎 |
| `KVStoreStateMachine` | `rheakv-core/.../storage/KVStoreStateMachine.java` | KV 状态机实现 |
| `RocksRawKVStore` | `rheakv-core/.../storage/RocksRawKVStore.java` | RocksDB KV 存储（73KB） |
| `MemoryRawKVStore` | `rheakv-core/.../storage/MemoryRawKVStore.java` | 内存 KV 存储 |
| `RaftRawKVStore` | `rheakv-core/.../storage/RaftRawKVStore.java` | Raft 包装的 KV 存储 |
| `AbstractPlacementDriverClient` | `rheakv-core/.../client/pd/AbstractPlacementDriverClient.java` | PD 客户端基类（18KB） |
| `HeartbeatSender` | `rheakv-core/.../client/pd/HeartbeatSender.java` | 心跳发送器（上报 Region 信息） |
| `RegionRouteTable` | `rheakv-core/.../client/RegionRouteTable.java` | Region 路由表（15KB） |
| `DefaultDistributedLock` | `rheakv-core/.../client/DefaultDistributedLock.java` | 分布式锁实现 |

## RheaKV 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    RheaKVStore（客户端）                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  RegionRouteTable（路由表：key range → Region）      │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  PlacementDriverClient（PD 客户端）                  │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
                           │ RPC
┌──────────────────────────▼──────────────────────────────────┐
│                    StoreEngine（服务端）                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ RegionEngine │  │ RegionEngine │  │ RegionEngine │      │
│  │  (Region 1)  │  │  (Region 2)  │  │  (Region 3)  │      │
│  │  NodeImpl    │  │  NodeImpl    │  │  NodeImpl    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         └─────────────────┴─────────────────┘               │
│                           │                                  │
│  ┌────────────────────────▼────────────────────────────┐    │
│  │              RocksRawKVStore（共享存储）              │    │
│  │  (不同 Region 使用不同的 Column Family 隔离)          │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                 Placement Driver（PD）                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  基于 JRaft 的元数据集群（管理 Region 分配）          │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

## Region 分片

```java
// Region 是 RheaKV 的基本分片单位
// 每个 Region 对应一个独立的 Raft Group
public class Region {
    private long id;
    private byte[] startKey;   // 分片起始 key（包含）
    private byte[] endKey;     // 分片结束 key（不包含）
    private RegionEpoch regionEpoch;  // 版本号（分裂/合并时递增）
    private List<Peer> peers;  // 该 Region 的 Raft 成员
}
```

## 写请求流程

```
Client.put(key, value)
  │
  ▼
DefaultRheaKVStore.put()
  │  1. 根据 key 查找 RegionRouteTable，找到对应 Region
  │  2. 找到 Region 的 Leader 节点
  │
  ▼
RaftRawKVStore.put()
  │  1. 封装为 KVOperation（type=PUT）
  │  2. 序列化为 Task.data
  │  3. 调用 Node.apply(task)
  │
  ▼
KVStoreStateMachine.onApply(iter)
  │  1. 反序列化 KVOperation
  │  2. 调用 RocksRawKVStore.put()
  │  3. 回调 KVStoreClosure
  │
  ▼
Client 收到响应
```

## KVStoreStateMachine（KV 状态机）

```java
// 支持的操作类型（KVOperation）
PUT, PUT_IF_ABSENT, DELETE, DELETE_RANGE,
BATCH_PUT, BATCH_DELETE, COMPARE_AND_PUT,
GET_SEQUENCE, RESET_SEQUENCE,
MERGE, SCAN, GET, MULTI_GET,
NODE_EXECUTE  // 自定义操作
```

## Placement Driver（PD）

PD 是 RheaKV 的元数据管理集群（类似 TiKV 的 PD）：

```
功能：
  1. 管理 Region 分配（哪些节点负责哪些 Region）
  2. 接收 Store/Region 心跳，感知集群状态
  3. 下发调度指令（Region 分裂、迁移、合并）
  4. 分配全局唯一 ID（StoreId、RegionId）

心跳流程：
  HeartbeatSender.sendStoreHeartbeat()   ← 上报 Store 级别统计
  HeartbeatSender.sendRegionHeartbeat()  ← 上报 Region 级别统计
  
  PD 响应：
  InstructionProcessor.process()
    ├── SPLIT_REGION   ← 触发 Region 分裂
    ├── TRANSFER_LEADER ← 触发 Leader 转让
    └── CHANGE_PEERS   ← 触发成员变更
```

## Region 分裂

```
触发条件：Region 数据量超过阈值（regionMaxSize）

分裂流程：
  1. PD 下发 SPLIT_REGION 指令
  2. RegionEngine 找到分裂点（中间 key）
  3. 提交分裂日志（type=SPLIT）
  4. KVStoreStateMachine 应用分裂：
     - 创建新 RegionEngine（新 Region）
     - 更新 RegionRouteTable
  5. 通知 PD 更新元数据
```

## 故障转移（Failover）

```java
// DefaultRheaKVStore 内置重试机制
// FailoverClosure 包装用户 Closure，自动处理重试

// 重试条件：
// 1. NotLeaderException → 刷新路由表，重试到新 Leader
// 2. RegionEngineFailException → 等待后重试
// 3. InvalidRegionEpochException → 刷新路由表（Region 已分裂/迁移）

// 重试策略：
RetryRunner.runRetry(retryTimes, retryDelay, callable)
```

## 分布式锁

```java
// 基于 RheaKV 的 CAS 操作实现分布式锁
DefaultDistributedLock lock = rheaKVStore.getDistributedLock(
    "lock-key",
    30,           // 锁超时时间（秒）
    TimeUnit.SECONDS
);

if (lock.tryLock()) {
    try {
        // 临界区
    } finally {
        lock.unlock();
    }
}
```

## 关键不变式

1. **Region 不重叠**：所有 Region 的 key range 不重叠，覆盖全部 key 空间
2. **Region Epoch 单调递增**：每次分裂/成员变更都递增 epoch，客户端用于检测路由过期
3. **写操作必须经过 Raft**：所有写操作通过 `RaftRawKVStore` 走 Raft 日志，保证一致性

## 面试高频考点 📌

- RheaKV 如何实现多 Region 的数据隔离？（RocksDB Column Family）
- Region 分裂期间客户端请求如何处理？（InvalidRegionEpochException + 重试）
- RheaKV 的分布式锁是如何实现的？（CAS + 超时）
- PD 和 Store 之间的心跳有什么作用？（感知集群状态，触发调度）

## 生产踩坑 ⚠️

- Region 分裂过于频繁，导致 PD 元数据压力大
- 客户端路由表缓存过期，大量请求打到旧 Leader，需要合理设置刷新间隔
- `RocksRawKVStore` 的 Column Family 过多，影响 RocksDB 性能
- 分布式锁未设置超时，持锁节点宕机后锁永远不释放
