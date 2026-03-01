# 09 - 成员变更（Membership Change）

## 学习目标

深入理解 JRaft 的集群成员变更机制，包括单节点变更（One-at-a-time）、联合共识（Joint Consensus）、Learner 节点，以及 CLI 服务的使用。

## 核心源码位置

| 类 | 路径 | 说明 |
|---|---|---|
| `CliService` | `CliService.java` | 集群管理 CLI 接口 |
| `CliServiceImpl` | `core/CliServiceImpl.java` | CLI 服务实现（26KB） |
| `Configuration` | `conf/Configuration.java` | 集群配置（peers + learners） |
| `ConfigurationEntry` | `conf/ConfigurationEntry.java` | 配置条目（新旧配置） |
| `ConfigurationManager` | `conf/ConfigurationManager.java` | 配置历史管理 |
| `NodeImpl` | `core/NodeImpl.java` | `addPeer` / `removePeer` / `changePeers` 实现 |
| `RouteTable` | `RouteTable.java` | 路由表（客户端用，缓存 Leader 信息） |
| `AddPeerRequestProcessor` | `rpc/impl/cli/AddPeerRequestProcessor.java` | 处理添加节点请求 |
| `ChangePeersRequestProcessor` | `rpc/impl/cli/ChangePeersRequestProcessor.java` | 处理批量变更请求 |

## 成员变更方式

### 1. 单节点变更（One-at-a-time）

每次只增加或删除一个节点，安全但变更多个节点时需要多次操作：

```java
// 添加节点
cliService.addPeer(groupId, conf, newPeer, cliOptions);

// 删除节点
cliService.removePeer(groupId, conf, peer, cliOptions);

// 转移 Leader
cliService.transferLeader(groupId, conf, peer, cliOptions);
```

### 2. 批量变更（changePeers）

一次性变更多个节点，内部使用联合共识（Joint Consensus）保证安全：

```java
// 一次性将集群配置变更为新的 peers 列表
cliService.changePeers(groupId, conf, newPeers, cliOptions);
```

## 联合共识（Joint Consensus）流程

```
阶段一：提交 C_old,new 配置日志
  ├── 新旧两个配置同时生效
  ├── 需要新旧两个 quorum 都同意才能提交
  └── Leader 同时向新旧成员复制日志

阶段二：提交 C_new 配置日志
  ├── 只有新配置生效
  └── 只需新 quorum 同意

NodeImpl.unsafeChangePeers()
  │  1. 创建 ConfigurationEntry（oldConf + newConf）
  │  2. 追加配置变更日志（type=CONFIGURATION）
  │  3. 等待日志提交
  │  4. 更新 conf（只保留 newConf）
```

## Learner 节点

Learner 是只接收日志复制但不参与投票的节点，适用于：
- 数据备份（异地容灾）
- 读扩展（从 Learner 读取数据）
- 新节点追赶（先作为 Learner 追上日志，再升级为 Voter）

```java
// 添加 Learner
cliService.addLearners(groupId, conf, learners, cliOptions);

// 移除 Learner
cliService.removeLearners(groupId, conf, learners, cliOptions);

// Learner 升级为 Voter
cliService.resetLearners(groupId, conf, learners, cliOptions);
```

**Learner 在 Configuration 中的表示：**
```java
public class Configuration {
    private List<PeerId> peers;     // 投票成员
    private List<PeerId> learners;  // 学习者（不参与投票）
}
```

## ConfigurationManager（配置历史）

```java
// 维护配置变更历史，用于日志回放时恢复配置
private final SegmentList<ConfigurationEntry> configurations;

// 根据 logIndex 查找对应的配置
public ConfigurationEntry getConfiguration(long lastIndex) {
    // 找到 index <= lastIndex 的最新配置
}
```

## RouteTable（客户端路由）

```java
// 客户端使用 RouteTable 缓存 Leader 信息，避免每次都查询
RouteTable.getInstance().updateConfiguration(groupId, conf);

// 刷新 Leader 信息
RouteTable.getInstance().refreshLeader(cliClientService, groupId, timeout);

// 获取 Leader
PeerId leader = RouteTable.getInstance().selectLeader(groupId);
```

## CatchUp（日志追赶）

新节点加入时，需要先追赶日志才能正式成为成员：

```java
// NodeImpl.addPeer() 内部流程
1. 将新节点作为 Learner 加入复制组
2. 等待新节点追赶（catchUpClosure）
3. 追赶完成后，提交配置变更日志
4. 新节点正式成为 Voter
```

**追赶超时配置：** `NodeOptions.catchupMargin`（允许的日志落后条数）

## 关键不变式

1. **配置变更通过日志提交**：配置变更作为特殊日志条目（type=CONFIGURATION）提交，保证所有节点看到相同的配置变更顺序
2. **联合共识期间需要双 quorum**：防止新旧配置同时存在两个 Leader
3. **Learner 不参与 quorum 计算**：Learner 的落后不影响集群可用性

## 面试高频考点 📌

- 为什么不能直接一次性变更多个节点？（可能导致新旧配置各自形成 quorum，出现双 Leader）
- 联合共识的两个阶段分别解决什么问题？
- Learner 节点的应用场景？
- 新节点加入时为什么要先追赶日志？（防止新节点成为 Voter 后立即成为 Leader，但日志不完整）

## 生产踩坑 ⚠️

- 成员变更期间 Leader 宕机，联合共识未完成，需要人工介入
- 新节点磁盘 IO 慢，追赶超时，导致成员变更失败
- 频繁成员变更导致配置日志积累，快照时需要携带完整配置历史
- `RouteTable` 缓存过期，客户端请求发到旧 Leader，需要处理重定向
