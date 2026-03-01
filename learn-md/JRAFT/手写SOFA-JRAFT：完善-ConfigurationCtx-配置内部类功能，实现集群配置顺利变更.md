手写SOFA-JRAFT：完善 ConfigurationCtx 配置内部类功能，实现集群配置顺利变更

## 手写SOFA-JRAFT：完善 ConfigurationCtx 配置内部类功能，实现集群配置顺利变更

本章内容还未完成，完成之后会立刻更新  
​

若有收获，就点个赞吧

[tutu](https://www.yuque.com/u26328320)

2024-06-01 23:24

38

0

![ruike](https://cdn.nlark.com/yuque/0/2025/png/34840193/1755588196407-avatar/7ad75f27-7e31-4ed9-84d2-18517be95bf0.png?x-oss-process=image%2Fresize%2Cm_fill%2Cw_64%2Ch_64%2Fformat%2Cpng)

\#### + Space 标题4  
![语雀](https://mdn.alipayobjects.com/huamei_0prmtq/afts/img/A*IVdnTJqUp6gAAAAAAAAAAAAADvuFAQ/original)

[关于语雀](https://www.yuque.com/help/about) [使用帮助](https://www.yuque.com/help) [数据安全](https://www.yuque.com/about/security) [服务协议](https://www.yuque.com/terms) [English](https://www.yuque.com/u26328320/kxtdy3/ai0wr1mh4flv9zm5?language=en-us)

[](https://www.yuque.com/dashboard)

[tutu](https://www.yuque.com/u26328320 "tutu")

从零带你写框架系列10

搜索 ⌘ + J

首页

目录

手写SOFA-JRAFT：引入 Pipeline 日志传输模式，重构 Replicator 复制器对象(一)

](https://www.yuque.com/u26328320/kxtdy3/yes2yep79h1ivylx)

手写SOFA-JRAFT：引入 AppendEntriesRequestProcessor，完善 Pipeline 模式(二)

](https://www.yuque.com/u26328320/kxtdy3/rn93cur7ies48hv1)

手写SOFA-JRAFT：引入 FSMCallerImpl 状态机组件，剖析领导者日志提交全流程(一)

](https://www.yuque.com/u26328320/kxtdy3/br4urh6kc5ritk5i)

手写SOFA-JRAFT：再次使用 Disruptor 框架，在异步回调中实现日志的提交和应用 (二)

](https://www.yuque.com/u26328320/kxtdy3/lz088mbggf31khbx)

手写SOFA-JRAFT：再次使用 Disruptor 框架，在异步回调中实现日志的提交和应用 (三)

](https://www.yuque.com/u26328320/kxtdy3/fevc7e9lcyyu5akl)

手写SOFA-JRAFT：实现线性一致读功能

](https://www.yuque.com/u26328320/kxtdy3/gmvr0u2ob4bzo2qs)

手写SOFA-JRAFT：引入快照组件，创建 snapshotTimer 快照定时生成器，实现快照定时生成(一)

](https://www.yuque.com/u26328320/kxtdy3/cspw216l2xc3nbqw)

手写SOFA-JRAFT：引入快照组件，创建 snapshotTimer 快照定时生成器，实现快照定时生成(二)

](https://www.yuque.com/u26328320/kxtdy3/qu3hk5s3y5m52bgz)

手写SOFA-JRAFT：引入快照组件，创建 snapshotTimer 快照定时生成器，实现快照定时生成(三)

](https://www.yuque.com/u26328320/kxtdy3/bgywlvq73lrnrzih)

手写SOFA-JRAFT：引入快照组件，创建 snapshotTimer 快照定时生成器，实现快照定时生成(四)

](https://www.yuque.com/u26328320/kxtdy3/vft0so5twa0ght8o)

手写SOFA-JRAFT：引入快照组件，创建 snapshotTimer 快照定时生成器，实现快照定时生成(五)

](https://www.yuque.com/u26328320/kxtdy3/umbts9e35autb0pp)

手写SOFA-JRAFT：完善快照组件，实现跟随者节点的快照安装(一)

](https://www.yuque.com/u26328320/kxtdy3/evi2zb5png8uvcmg)

手写SOFA-JRAFT：完善快照组件，实现跟随者节点的快照安装(二)

](https://www.yuque.com/u26328320/kxtdy3/wwnlhfbuu3fdvgkw)

手写SOFA-JRAFT：完善 ConfigurationCtx 配置内部类功能，实现集群配置顺利变更

](https://www.yuque.com/u26328320/kxtdy3/ai0wr1mh4flv9zm5)

手写SOFA-JRAFT：实现优雅停机功能(一)

](https://www.yuque.com/u26328320/kxtdy3/fgin04z93f0zz7ur)

手写SOFA-JRAFT：实现优雅停机功能(二)

](https://www.yuque.com/u26328320/kxtdy3/ximxx53pdmr9vyxd)

手写SOFA-JRAFT：实现优雅停机功能(三)

](https://www.yuque.com/u26328320/kxtdy3/titaur67smtgh00c)

从零带你写 hippo4j

](https://www.yuque.com/u26328320/kxtdy3/smgq25gprfgaw41v)

从 java 线程池探讨动态线程池框架的可行性以及扩展性

](https://www.yuque.com/u26328320/kxtdy3/ixaed22ru46b0ssw)

引入 DynamicThreadPoolExecutor 体系，完善线程池扩展功能(一)

](https://www.yuque.com/u26328320/kxtdy3/beawgfqt8imcpl47)

完善 DynamicThreadPoolExecutor 体系，构建简单客户端(二)

](https://www.yuque.com/u26328320/kxtdy3/fehzsospvtrimlg4)

构建简单客户端，实现项目线程池信息向服务端的注册功能(三)

](https://www.yuque.com/u26328320/kxtdy3/pnz4nn1u2b73370v)

完善框架，实现客户端与服务端的心跳检测以及过期服务移除功能

](https://www.yuque.com/u26328320/kxtdy3/vp2q98opib9y7goc)

运用长轮询，实现线程池配置信息的动态变更(一)

](https://www.yuque.com/u26328320/kxtdy3/ogl1ba6b6i8a10za)

---
*Source: https://www.yuque.com/u26328320/kxtdy3/ai0wr1mh4flv9zm5*  
*All content belongs to its respective owners and creators.*