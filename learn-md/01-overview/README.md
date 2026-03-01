# 01 - JRaft 整体架构概览

## 学习目标

理解 JRaft 的整体模块划分、核心接口体系以及各组件之间的协作关系。

## 核心源码位置

| 类 / 接口 | 路径 | 说明 |
|---|---|---|
| `Node` | `jraft-core/.../Node.java` | 核心接口，代表一个 Raft 节点 |
| `NodeImpl` | `jraft-core/.../core/NodeImpl.java` | Node 的唯一实现，145KB 超大类 |
| `RaftGroupService` | `jraft-core/.../RaftGroupService.java` | Raft 分组服务，节点启动入口 |
| `NodeManager` | `jraft-core/.../NodeManager.java` | 全局节点注册表（单例） |
| `JRaftServiceFactory` | `jraft-core/.../JRaftServiceFactory.java` | 核心组件工厂接口（SPI 扩展点） |
| `DefaultJRaftServiceFactory` | `jraft-core/.../core/DefaultJRaftServiceFactory.java` | 默认工厂实现 |
| `Lifecycle` | `jraft-core/.../Lifecycle.java` | 所有组件的生命周期接口（init/shutdown） |
| `JRaftUtils` | `jraft-core/.../JRaftUtils.java` | 工具类，快速构建 PeerId/Configuration |

## 整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      RaftGroupService                        │
│  (启动入口：创建并初始化 NodeImpl + RpcServer)                │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │   NodeImpl  │  ← 核心大脑（状态机驱动）
                    └──────┬──────┘
          ┌────────────────┼────────────────────┐
          │                │                    │
   ┌──────▼──────┐  ┌──────▼──────┐   ┌────────▼────────┐
   │  LogManager │  │  Replicator │   │  FSMCaller      │
   │  (日志管理)  │  │  Group      │   │  (状态机调用)    │
   └──────┬──────┘  └──────┬──────┘   └────────┬────────┘
          │                │                    │
   ┌──────▼──────┐  ┌──────▼──────┐   ┌────────▼────────┐
   │ LogStorage  │  │  Replicator │   │  StateMachine   │
   │ (RocksDB)   │  │  (per peer) │   │  (用户实现)      │
   └─────────────┘  └─────────────┘   └─────────────────┘
          │
   ┌──────▼──────────────────────────┐
   │  SnapshotExecutor               │
   │  (快照触发 / 安装)               │
   └─────────────────────────────────┘
```

## 模块划分

```
sofa-jraft
├── jraft-core          # 核心实现（Raft 协议 + 存储 + RPC）
├── jraft-extension     # 扩展实现（gRPC、BDB/Java 日志存储）
├── jraft-rheakv        # 基于 JRaft 构建的分布式 KV 存储
├── jraft-example       # 使用示例（Counter、RheaKV）
└── jraft-test          # 集成测试
```

## 核心接口体系

```
Lifecycle
  └── Node               # 节点核心操作（apply/readIndex/snapshot...）
  └── LogManager         # 日志管理（append/get/truncate）
  └── FSMCaller          # 状态机调用器
  └── ReadOnlyService    # 线性一致读服务
  └── ReplicatorGroup    # 复制组管理
  └── SnapshotExecutor   # 快照执行器
  └── LogStorage         # 日志持久化（SPI 扩展点）
  └── SnapshotStorage    # 快照持久化（SPI 扩展点）
  └── RaftMetaStorage    # 元数据持久化（term/votedFor）
```

## SPI 扩展点

JRaft 通过 `JRaftServiceLoader`（仿 Java SPI）提供以下扩展点：

- `JRaftServiceFactory` → 替换核心组件实现
- `RaftRpcFactory` → 替换 RPC 传输层（默认 Bolt，可换 gRPC）
- `LogStorage` → 替换日志存储（默认 RocksDB，可换 BDB/Java）
- `RaftTimerFactory` → 替换定时器实现

## 关键配置类

- `NodeOptions` — 节点级别配置（选举超时、快照间隔、存储路径等）
- `RaftOptions` — Raft 协议参数（pipeline、batch、压缩等）
- `RpcOptions` — RPC 超时、连接池配置

## 学习顺序建议

1. 先读 `Node.java` 接口，理解节点对外暴露的能力
2. 读 `RaftGroupService` 理解启动流程
3. 读 `NodeImpl` 的构造函数和 `init()` 方法，梳理组件初始化顺序
4. 结合 `jraft-example` 中的 Counter 示例跑通一个完整流程

## 面试高频考点 📌

- JRaft 与 braft（C++ 版）的关系？
- `NodeImpl` 为什么是单一大类而不拆分？（状态一致性保证）
- SPI 机制如何实现存储层可插拔？

## 生产踩坑 ⚠️

- `NodeOptions.setSnapshotIntervalSecs()` 设置过小会导致频繁快照，影响写性能
- 忘记调用 `RaftGroupService.shutdown()` 会导致 RocksDB 文件句柄泄漏
