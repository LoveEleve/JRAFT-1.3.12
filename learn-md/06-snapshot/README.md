# 06 - 快照（Snapshot）

## 学习目标

深入理解 JRaft 的快照机制，包括快照的触发、保存、安装（远程传输）以及快照与日志截断的协调。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `SnapshotExecutor` | `storage/SnapshotExecutor.java` | 快照执行器接口 |
| `SnapshotExecutorImpl` | `storage/snapshot/SnapshotExecutorImpl.java` | 快照执行器实现（30KB） |
| `LocalSnapshotStorage` | `storage/snapshot/local/LocalSnapshotStorage.java` | 本地快照存储 |
| `LocalSnapshotWriter` | `storage/snapshot/local/LocalSnapshotWriter.java` | 快照写入器 |
| `LocalSnapshotReader` | `storage/snapshot/local/LocalSnapshotReader.java` | 快照读取器 |
| `LocalSnapshotCopier` | `storage/snapshot/local/LocalSnapshotCopier.java` | 快照远程拷贝（16KB） |
| `RemoteFileCopier` | `storage/snapshot/remote/RemoteFileCopier.java` | 远程文件拷贝 |
| `CopySession` | `storage/snapshot/remote/CopySession.java` | 单文件拷贝会话 |
| `FileService` | `storage/FileService.java` | 文件服务（提供快照文件下载） |
| `ThroughputSnapshotThrottle` | `storage/snapshot/ThroughputSnapshotThrottle.java` | 快照传输限速 |
| `StateMachine` | `StateMachine.java` | 用户实现快照保存/加载的接口 |

## 快照触发条件

```
1. 定时触发：snapshotTimer 周期触发（NodeOptions.snapshotIntervalSecs）
2. 手动触发：Node.snapshot(closure) 主动调用
3. 安装快照：Follower 落后太多，Leader 发送 InstallSnapshot 请求
```

## 快照保存流程（Leader/Follower 均可）

```
NodeImpl.doSnapshot()
  │
  ▼
SnapshotExecutorImpl.doSnapshot(done)
  │  1. 检查是否有正在进行的快照（互斥）
  │  2. 获取当前 committedIndex 作为快照 index
  │  3. 创建 LocalSnapshotWriter
  │
  ▼
FSMCaller.onSnapshotSave(writer, done)
  │  通过 Disruptor 异步调用
  │
  ▼
StateMachine.onSnapshotSave(writer, done)  ← 用户实现
  │  1. 将状态机数据写入 writer 指定的目录
  │  2. 调用 writer.addFile() 注册快照文件
  │  3. 调用 done.run(Status.OK())
  │
  ▼
SnapshotExecutorImpl.onSnapshotSaveDone()
  │  1. 保存快照元数据（snapshotMeta：index/term/peers/files）
  │  2. 通知 LogManager 截断旧日志（truncatePrefix）
  │  3. 更新 lastSnapshotIndex / lastSnapshotTerm
```

## 快照安装流程（Follower 接收）

```
Leader: Replicator 发现 Follower 落后太多（nextIndex < firstLogIndex）
  │
  ▼
Replicator.installSnapshot()
  │  发送 InstallSnapshotRequest（携带快照元数据）
  │
  ▼
Follower: InstallSnapshotRequestProcessor
  │
  ▼
SnapshotExecutorImpl.installSnapshot(request, done)
  │  1. 创建 LocalSnapshotCopier
  │  2. 异步从 Leader 下载快照文件
  │
  ▼
LocalSnapshotCopier.copy()
  │  遍历快照元数据中的文件列表
  │  对每个文件创建 CopySession
  │  通过 GetFile RPC 从 Leader 下载
  │
  ▼
SnapshotExecutorImpl.onSnapshotLoadDone()
  │
  ▼
FSMCaller.onSnapshotLoad(reader, done)
  │
  ▼
StateMachine.onSnapshotLoad(reader)  ← 用户实现
  │  从 reader 指定目录加载状态机数据
  │
  ▼
  重置 LogManager（清空旧日志，从快照 index 开始）
```

## 快照文件结构

```
{storagePath}/snapshot/
  ├── snapshot_00000000000000001000/   ← 快照目录（以 index 命名）
  │   ├── __raft_snapshot_meta         ← 快照元数据（Protobuf）
  │   ├── data                         ← 用户状态机数据文件
  │   └── ...                          ← 其他用户文件
  └── snapshot_00000000000000002000/   ← 新快照（保留最近 N 个）
```

**快照元数据（`__raft_snapshot_meta`）：**
```protobuf
message SnapshotMeta {
    int64 last_included_index = 1;
    int64 last_included_term = 2;
    repeated string peers = 3;
    repeated string old_peers = 4;
    repeated LocalFileMeta files = 5;
}
```

## 快照传输限速

```java
// ThroughputSnapshotThrottle
// 控制快照传输速率，避免影响正常 Raft 流量
public long throttledByThroughput(long bytes) {
    // 令牌桶算法限速
    // NodeOptions.snapshotThrottle 配置
}
```

## FileService（文件服务）

Leader 通过 `FileService` 提供快照文件下载服务：

```
GetFileRequest { reader_id, filename, offset, count }
  ↓
FileService.handleGetFile()
  ↓
LocalDirReader.readFile(filename, offset, count)
  ↓
GetFileResponse { data, eof }
```

## 关键不变式

1. **快照与日志的一致性**：快照的 `lastIncludedIndex` 一定 ≤ `committedIndex`
2. **快照互斥**：同一时刻只能有一个快照操作（保存或安装）
3. **安装快照后日志重置**：安装快照后，`firstLogIndex = lastSnapshotIndex + 1`

## 面试高频考点 📌

- 快照保存期间，新的写请求能否继续处理？（可以，快照是对某个 committedIndex 的状态做快照）
- 为什么快照元数据要包含 `peers`？（集群成员变更时，快照需要携带当时的配置）
- `LocalSnapshotStorage` 为什么保留多个快照目录？（防止新快照保存失败时旧快照被删除）
- 快照传输失败如何处理？（CopySession 支持断点续传，通过 offset 参数）

## 生产踩坑 ⚠️

- `onSnapshotSave()` 中忘记调用 `done.run()`，导致快照永远不完成，节点卡死
- 快照文件过大（几十 GB），传输时间超过选举超时，导致 Follower 频繁触发选举
- 快照目录权限问题导致文件写入失败，节点进入 `STATE_ERROR`
- 未配置 `snapshotThrottle`，快照传输占满带宽，影响正常 Raft 心跳
