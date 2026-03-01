# 05 - 日志存储

## 学习目标

深入理解 JRaft 的日志存储层设计，包括 `LogManager`（日志管理器）、`RocksDBLogStorage`（默认存储）、`RocksDBSegmentLogStorage`（分段存储优化）以及日志编解码机制。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `LogStorage` | `storage/LogStorage.java` | 日志存储接口（SPI 扩展点） |
| `LogManager` | `storage/LogManager.java` | 日志管理接口（缓存 + 持久化） |
| `LogManagerImpl` | `storage/impl/LogManagerImpl.java` | 日志管理器实现（46KB） |
| `RocksDBLogStorage` | `storage/impl/RocksDBLogStorage.java` | 基于 RocksDB 的日志存储（默认） |
| `RocksDBSegmentLogStorage` | `storage/log/RocksDBSegmentLogStorage.java` | 分段日志存储（优化大日志场景） |
| `SegmentFile` | `storage/log/SegmentFile.java` | 分段文件实现 |
| `LogEntryCodecFactory` | `entity/codec/LogEntryCodecFactory.java` | 日志编解码工厂（SPI 扩展点） |
| `RaftMetaStorage` | `storage/RaftMetaStorage.java` | 元数据存储（term/votedFor） |
| `LocalRaftMetaStorage` | `storage/impl/LocalRaftMetaStorage.java` | 元数据本地存储实现 |

## 分层架构

```
┌─────────────────────────────────────────────────────┐
│                   LogManagerImpl                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  内存缓存（logsInMemory: SegmentList）        │    │
│  │  配置缓存（configManager）                   │    │
│  └─────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────┐    │
│  │  Disruptor 异步写入队列（StableClosureEvent） │    │
│  └─────────────────────────────────────────────┘    │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────▼────────────┐
          │      LogStorage         │  ← SPI 扩展点
          │  (RocksDBLogStorage)    │
          └────────────┬────────────┘
                       │
          ┌────────────▼────────────┐
          │        RocksDB          │
          └─────────────────────────┘
```

## LogManagerImpl 核心机制

### 异步写入（Disruptor）

```
LogManagerImpl.appendEntries(entries, done)
  │  1. 将 entries 放入 Disruptor Ring Buffer
  │  2. 立即返回（非阻塞）
  ▼
StableClosureEventHandler.onEvent()
  │  批量处理 Ring Buffer 中的事件
  │  调用 LogStorage.appendEntries()
  │  触发 done.run()（通知 Replicator）
```

### 内存缓存（logsInMemory）

```java
// SegmentList 分段存储，避免大数组扩容
private final SegmentList<LogEntry> logsInMemory;

// 读取优先从内存缓存，缓存 miss 才读 RocksDB
public LogEntry getEntry(long index) {
    if (index >= firstLogIndex && index <= lastLogIndex) {
        return logsInMemory.get((int)(index - firstLogIndex));
    }
    return logStorage.getEntry(index);
}
```

### 日志截断（Truncate）

```
truncatePrefix(firstIndexKept)  ← 删除已快照的旧日志
truncateSuffix(lastIndexKept)   ← 回滚未提交的日志（Leader 切换时）
```

## RocksDBLogStorage

### 数据组织

```
RocksDB Column Families:
  ├── default CF: logIndex → LogEntry（序列化后的日志数据）
  └── conf CF:    logIndex → ConfigurationEntry（配置变更日志单独存储）

Key 编码: 8 字节大端序 long（logIndex）
Value 编码: LogEntryEncoder 序列化（Protobuf 或 V2 格式）
```

### 写入优化

```java
// 批量写入（WriteBatch）
WriteBatch batch = new WriteBatch();
for (LogEntry entry : entries) {
    batch.put(encodeKey(entry.getId().getIndex()), encode(entry));
}
rocksDB.write(writeOptions, batch);
```

## RocksDBSegmentLogStorage（分段优化）

**解决的问题：** RocksDB 对大 Value（> 1MB）的读写性能较差，分段存储将日志 Value 存储在独立的 Segment 文件中，RocksDB 只存储索引。

```
RocksDB: logIndex → (segmentFileOffset, length)
SegmentFile: 顺序写入的日志数据文件（类似 Kafka 的 segment）
```

## 日志编解码

```
LogEntryCodecFactory（SPI 扩展点）
  ├── DefaultLogEntryCodecFactory
  │     ├── V1: Protobuf 编码（兼容旧版本）
  │     └── V2: 自定义二进制编码（更高效）
  └── AutoDetectDecoder（自动检测编码格式）
```

**V2 编码格式（更紧凑）：**
```
[magic(4)] [version(1)] [type(1)] [term(8)] [index(8)] [checksum(8)] [data...]
```

## RaftMetaStorage（元数据存储）

持久化 `term` 和 `votedFor`，防止重启后投票信息丢失：

```java
// LocalRaftMetaStorage 使用 Protobuf 文件存储
// 文件路径: {storagePath}/raft_meta
message StablePBMeta {
    int64 term = 1;
    string votedFor = 2;
}
```

## 关键不变式

1. **日志持久化先于响应**：`LogStorage.appendEntries()` 成功后才能通知 Replicator
2. **内存缓存与磁盘一致**：`logsInMemory` 中的日志一定已经持久化
3. **配置日志单独存储**：配置变更日志存在独立的 CF，便于快速恢复集群配置

## 面试高频考点 📌

- `LogManager` 为什么要用 Disruptor 异步写入？（批量合并写，提升吞吐量）
- `SegmentList` 相比 `ArrayList` 的优势？（避免大数组扩容时的内存拷贝）
- RocksDB 的 WAL 和 JRaft 的 Raft Log 有什么关系？（RocksDB WAL 是 RocksDB 内部的，Raft Log 是 Raft 协议层的）
- 为什么配置日志要单独存储在独立的 Column Family？

## 生产踩坑 ⚠️

- RocksDB `BlockCache` 配置不当导致内存占用过高
- 日志目录磁盘满导致 `appendEntries` 失败，节点进入 `STATE_ERROR`
- `truncatePrefix` 删除日志后，Follower 落后太多需要安装快照，影响集群性能
- 使用 `RocksDBSegmentLogStorage` 时，Segment 文件未及时清理导致磁盘占用持续增长
