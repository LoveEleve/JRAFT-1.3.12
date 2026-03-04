# JRaft 源码学习总导航（精炼版 + 通俗版）

> 基于 SOFAJRaft 源码（`jraft-core` + `jraft-rheakv`）的系统化学习路线。
> 
> 你可以按两种方式阅读：
> - **源码精炼版**：每章的 `README.md`（或章节主文档）
> - **通俗解读版**：每章的 `通俗解读.md`（讲故事 + 打比喻）

## 学习主题目录（15章）

| 序号 | 主题 | 源码精炼版 | 通俗解读版 |
|---|---|---|---|
| 01 | 整体架构概览 | [README](./01-overview/README.md) | [通俗解读](./01-overview/通俗解读.md) |
| 02 | Node 生命周期与启动流程 | [README](./02-node-lifecycle/README.md) | [通俗解读](./02-node-lifecycle/通俗解读.md) |
| 03 | Leader 选举 | [README](./03-leader-election/README.md) | [通俗解读](./03-leader-election/通俗解读.md) |
| 04 | 日志复制 | [README](./04-log-replication/README.md) | [通俗解读](./04-log-replication/通俗解读.md) |
| 05 | 日志存储 | [README](./05-log-storage/README.md) | [通俗解读](./05-log-storage/通俗解读.md) |
| 06 | 快照机制 | [README](./06-snapshot/README.md) | [通俗解读](./06-snapshot/通俗解读.md) |
| 07 | 状态机与 FSMCaller | [README](./07-state-machine/README.md) | [通俗解读](./07-state-machine/通俗解读.md) |
| 08 | 线性一致读（ReadIndex） | [README](./08-read-index/README.md) | [通俗解读](./08-read-index/通俗解读.md) |
| 09 | 成员变更 | [README](./09-membership-change/README.md) | [通俗解读](./09-membership-change/通俗解读.md) |
| 10 | RPC 通信层 | [README](./10-rpc-layer/README.md) | [通俗解读](./10-rpc-layer/通俗解读.md) |
| 11 | 并发基础设施 | [README](./11-concurrency-infra/README.md) | [通俗解读](./11-concurrency-infra/通俗解读.md) |
| 12 | 监控与可观测性 | [README](./12-metrics-observability/README.md) | [通俗解读](./12-metrics-observability/通俗解读.md) |
| 13 | RheaKV 进阶 | [README](./13-rheakv-advanced/README.md) | [通俗解读](./13-rheakv-advanced/通俗解读.md) |
| 14 | RheaKV Placement Driver | [S7-Placement-Driver](./14-rheakv-pd/S7-Placement-Driver.md) | [通俗解读](./14-rheakv-pd/通俗解读.md) |
| 15 | Raft 论文 vs JRaft 实现 | [Raft-Paper-vs-JRaft](./15-raft-paper-vs-jraft/Raft-Paper-vs-JRaft.md) | [通俗解读](./15-raft-paper-vs-jraft/通俗解读.md) |

## 推荐学习顺序

### 路线A：零基础/第一次读

`01` → `02` → `03` → `04` → `05` → `06` → `07` → `08` → `09` → `10` → `11` → `12` → `13` → `14` → `15`

建议每章都按这个节奏：
1. **先读通俗解读版**（先建立直觉）
2. **再读源码精炼版**（进入源码细节）

### 路线B：带着问题查阅

- 想搞懂选举稳定性：`03`
- 想搞懂写入性能瓶颈：`04` + `05` + `11`
- 想搞懂读一致性：`08`
- 想搞懂扩缩容与运维：`09` + `12`
- 想搞懂 RheaKV 全貌：`13` + `14`
- 想搞懂“论文到工程”的差异：`15`

## 阅读建议（统一规则）

- **先问题后源码**：每次先明确“我要回答什么问题”
- **先数据结构后算法流程**：字段含义、生命周期、值域先看清
- **异常路径必读**：`catch`、降级分支、超时处理通常最关键
- **关注并发边界**：锁范围、线程切换、回调在哪个线程执行
- **再做运行验证**：必要时用日志/断点验证关键结论

## 核心一句话

这套内容已经形成完整闭环：
- **精炼版**负责“严谨、可定位、可追源码”
- **通俗版**负责“直觉、故事化、降低认知门槛”

建议优先“通俗版入门”，再“精炼版吃透”。