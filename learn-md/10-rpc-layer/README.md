# 10 - RPC 通信层

## 学习目标

深入理解 JRaft 的 RPC 通信层设计，包括 Bolt（默认）和 gRPC 两种传输实现、RPC 处理器注册机制、以及 Protobuf 序列化。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `RpcServer` | `rpc/RpcServer.java` | RPC 服务端接口 |
| `RpcClient` | `rpc/RpcClient.java` | RPC 客户端接口 |
| `RaftRpcFactory` | `rpc/RaftRpcFactory.java` | RPC 工厂接口（SPI 扩展点） |
| `BoltRpcServer` | `rpc/impl/BoltRpcServer.java` | Bolt 服务端实现 |
| `BoltRpcClient` | `rpc/impl/BoltRpcClient.java` | Bolt 客户端实现 |
| `BoltRaftRpcFactory` | `rpc/impl/BoltRaftRpcFactory.java` | Bolt RPC 工厂 |
| `AbstractClientService` | `rpc/impl/AbstractClientService.java` | 客户端服务基类（12KB） |
| `DefaultRaftClientService` | `rpc/impl/core/DefaultRaftClientService.java` | Raft 客户端服务实现 |
| `RpcProcessor` | `rpc/RpcProcessor.java` | RPC 请求处理器接口 |
| `AppendEntriesRequestProcessor` | `rpc/impl/core/AppendEntriesRequestProcessor.java` | AppendEntries 处理器（18KB） |
| `ProtobufSerializer` | `rpc/ProtobufSerializer.java` | Protobuf 序列化器 |
| `RaftRpcServerFactory` | `rpc/RaftRpcServerFactory.java` | RPC 服务端工厂工具类 |

## RPC 层架构

```
┌─────────────────────────────────────────────────────────┐
│                    JRaft RPC 抽象层                       │
│  RpcServer / RpcClient / RpcProcessor                    │
└──────────────┬──────────────────────────────────────────┘
               │  SPI 扩展
    ┌──────────┴──────────┐
    │                     │
┌───▼────────┐    ┌───────▼──────┐
│  Bolt 实现  │    │  gRPC 实现   │
│ (默认)      │    │ (扩展模块)   │
└────────────┘    └──────────────┘
```

## Raft RPC 消息类型

```
Raft 内部 RPC（rpc.proto）：
  ├── AppendEntriesRequest / Response   ← 日志复制 + 心跳
  ├── RequestVoteRequest / Response     ← 选举投票
  ├── InstallSnapshotRequest / Response ← 快照安装
  ├── GetFileRequest / Response         ← 快照文件传输
  ├── ReadIndexRequest / Response       ← 线性一致读
  └── TimeoutNowRequest / Response      ← Leader 转让

CLI RPC（cli.proto）：
  ├── AddPeerRequest / Response
  ├── RemovePeerRequest / Response
  ├── ChangePeersRequest / Response
  ├── GetLeaderRequest / Response
  ├── SnapshotRequest / Response
  └── TransferLeaderRequest / Response
```

## RPC 处理器注册

```java
// NodeImpl.init() 中注册所有 RPC 处理器
RaftRpcServerFactory.addRaftRequestProcessors(rpcServer, raftExecutor, cliExecutor);

// 处理器注册示例
rpcServer.registerProcessor(new AppendEntriesRequestProcessor(executor));
rpcServer.registerProcessor(new RequestVoteRequestProcessor(executor));
rpcServer.registerProcessor(new InstallSnapshotRequestProcessor(executor));
```

## AppendEntriesRequestProcessor（核心处理器）

```
AppendEntriesRequestProcessor.processRequest()
  │  1. 根据 groupId + serverId 找到对应的 NodeImpl
  │  2. 检查 term（过期请求直接拒绝）
  │  3. 调用 NodeImpl.handleAppendEntriesRequest()
  │
  ▼
NodeImpl.handleAppendEntriesRequest()
  │  1. 校验 term、leaderId
  │  2. 重置 electionTimer（收到心跳，延迟选举）
  │  3. 校验 prevLogIndex / prevLogTerm（日志一致性检查）
  │  4. 追加日志到 LogManager
  │  5. 更新 committedIndex
  │  6. 返回 AppendEntriesResponse
```

**并发优化：** `AppendEntriesRequestProcessor` 使用 `PeerRequestContext` 为每个 Peer 维护独立的处理队列，避免不同 Peer 的请求互相阻塞。

## Bolt RPC 实现

```java
// BoltRpcServer 基于 SOFABolt 框架
// SOFABolt 是蚂蚁金服开源的高性能网络通信框架（基于 Netty）

// 连接管理
BoltRpcClient.checkConnection(endpoint)  // 检查连接是否可用
BoltRpcClient.closeConnection(endpoint)  // 关闭连接

// 异步调用
BoltRpcClient.invokeAsync(endpoint, request, invokeCallback, timeoutMs)
```

## gRPC 扩展实现

```
jraft-extension/rpc-grpc-impl/
  ├── GrpcRaftRpcFactory    ← gRPC RPC 工厂
  ├── GrpcServer            ← gRPC 服务端
  └── GrpcClient            ← gRPC 客户端

配置方式：
  META-INF/services/com.alipay.sofa.jraft.rpc.RaftRpcFactory
  → 指向 GrpcRaftRpcFactory
```

## Protobuf 序列化

```java
// ProtobufSerializer 负责 Raft 消息的序列化/反序列化
// 使用 ZeroByteStringHelper 优化零拷贝

// ProtobufMsgFactory 通过消息类名注册/查找消息类型
ProtobufMsgFactory.registerAllMessageTypes(RpcRequests.class);
```

## RpcRequestClosure（响应封装）

```java
// 统一封装 RPC 响应发送
public class RpcRequestClosure implements Closure {
    private final RpcContext rpcCtx;
    
    @Override
    public void run(Status status) {
        // 发送响应给调用方
        rpcCtx.sendResponse(responseBuilder.build());
    }
}
```

## 关键不变式

1. **处理器线程隔离**：Raft 核心 RPC（AppendEntries/Vote）和 CLI RPC 使用不同的线程池
2. **请求有序处理**：同一 Peer 的 AppendEntries 请求按序处理（PeerRequestContext 队列）
3. **超时保护**：所有 RPC 调用都有超时，防止慢节点阻塞 Leader

## 面试高频考点 📌

- JRaft 为什么默认使用 Bolt 而不是 gRPC？（Bolt 是蚂蚁内部成熟框架，性能更优）
- `AppendEntriesRequestProcessor` 为什么要为每个 Peer 维护独立队列？（保证同一 Peer 的请求有序处理）
- RPC 层如何实现可插拔？（SPI 机制，`RaftRpcFactory` 接口）
- Protobuf 序列化的零拷贝优化是如何实现的？（`ZeroByteStringHelper`）

## 生产踩坑 ⚠️

- Bolt 连接池耗尽导致 RPC 超时，需要调整 `RpcOptions.rpcConnectTimeoutMs`
- 大消息（AppendEntries 携带大量日志）导致 Netty 内存压力，需要配置 `maxBodySize`
- gRPC 和 Bolt 混用导致序列化不兼容，集群内所有节点必须使用相同的 RPC 实现
