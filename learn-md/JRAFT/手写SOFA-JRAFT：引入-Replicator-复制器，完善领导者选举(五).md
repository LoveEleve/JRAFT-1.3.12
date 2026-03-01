大家好，这一章我将继续为大家讲解 raft 集群中领导者选举的知识。在上一章我已经为大家把领导者选举的流程全部展示完毕了，整个流程剖析得非常清楚，可以说在领导者选举这一块，知识都已经讲解得差不多了，就差最后收尾了。所谓收尾，其实就是集群中某个节点成功当选了领导者之后，怎么在代码层面上表明它领导者的身份和职责。当然，也就是实现上一章没有实现的 becomeLeader 方法。大家应该都还记得这个 becomeLeader 方法是在哪里被调用的，如果忘了也没关系，这里我把上一章的代码搬运过来一部分，帮助大家简单回顾一下 becomeLeader 方法，请看下面代码块。  
public class NodeImpl implements Node {  
private static final Logger LOG \= LoggerFactory.getLogger (NodeImpl.class);  
  
//元数据存储器

private RaftMetaStorage metaStorage;  
//计算预投票结果的计数器

private final Ballot prevVoteCtx \= new Ballot ();  
//计算正式选票结果的计数器

private final Ballot voteCtx \= new Ballot ();  
//省略其他内容  
  
  
//如果当前节点的身份是候选者，发送了索要投票的请求给其他节点后，收到其他节点的响应后就会调用这个方法

//处理响应，这个方法中term参数代表的是当前候选者节点发送索要投票请求之前的任期，这个逻辑可以从OnRequestVoteRpcDone类的run方法中查看

public void handleRequestVoteResponse (final PeerId peerId,final long term,final RpcRequests.RequestVoteResponse response) {  
//当前候选者节点接收到响应之后，发现自己的身份不是候选者了，就直接退出该方法

//也许在接收到投票响应之前已经收到了集群中选举出来的领导者的信息，这样就会把自己的身份降级为跟随者了

//也许候选者节点已经接收到足够的投票，变成领导者了，后面再有响应过来的时候，就不会再继续判断是否为成功

//投票的响应了

if (this.state!= State.STATE\_CANDIDATE) {

LOG.warn ("Node {} received invalid RequestVoteResponse from {}, state not in STATE\_CANDIDATE but {}.",

getNodeId (),peerId,this.state);

return;

}

//判断当前候选者节点的任期是否发生了变化，这里的这个term代表的是当前候选者节点发送索要投票请求之前的任期

//而在发送索要投票请求之后，收到响应之前，很可能任期就被新的领导者改变了，如果前后任期不一致，也直接退出该方法

在上面的代码块中，我为大家把 handleRequestVoteResponse 方法展示出来了，该方法的作用大家应该很熟悉了，那就是在候选者节点接收到正式投票请求的响应后被调用，在该方法的第 53 行会判断这个响应是不是成功投票的响应。因为候选者节点肯定会向集群中其他所有节点都发送索要投票的请求，所以也会接收到很多响应，每接收到一个响应就调用 handleRequestVoteResponse 方法，判断当前候选者节点是否接收到足够的票数了，如果接收到的成功票数超过集群中过半节点， 那么当前候选者就可以执行 becomeLeader 方法，在 becomeLeader 方法中将自己的状态更新为领导者了 。这个是肯定要执行的操作，这应该可以理解吧？实际上就是将当前候选者节点的 NodeImpl 对象的 state 成员变量更新为 State.STATE\_LEADER 状态，这个状态就是领导者状态，也就代表着当前节点成为领导者了。这个操作非常容易实现，但是，成为领导者之后呢？  
我要和大家讨论的问题正是这个，当一个候选者节点成功当选了领导者之后，除了将自己的节点状态更新为 State.STATE\_LEADER 之外，还应该执行什么操作呢？  
  
引入复制器概念，实现 becomeLeader 方法  
  
请大家想一想，当集群中的一个候选者成功当选为领导者之后，只是将候选者节点的 state 更新为 State.STATE\_LEADER，这只不过是执行了一个最表层的操作，接下来的操作才是需要我们关心和重视的。比如说， 当一个节点成为领导者之后，肯定需要立即向集群中的其他各个节点发送心跳消息，心跳消息发送给其他跟随者节点，这样其他跟随者节点才不会触发自己的超时选举定时器工作 。这个操作也很容易实现，其实就是让当前领导者向其他节点通过 RPC 发送消息，其他节点接收到领导者发送的消息后，更新自己本地的 lastLeaderTimestamp 时间戳即可。而每个节点恰好在初始化的时候，都会获得集群配置信息，知道集群中各个节点的网络地址，所以，直接让当前节点根据这些网络地址发送心跳消息即可，从逻辑上来看，这个操作也很容易实现。当然，现在还不必立即就实现发送心跳消息给跟随者的方法，也不必关心应该定义什么类型的请求来封装心跳消息的信息。现在，我们需要接着讨论的是，领导者节点该以什么样的方式来向集群中的所有节点发送心跳消息？这个问题可能有歧义，让我再为大家解释得清楚一点，那就是，领导者需不需要集中管理集群中的其他所有节点，然后再向它们发送心跳消息？  
也许还是有朋友感到疑惑，接下来，让我仔细为大家剖析一下。如果集群中的领导者不需要对集群中的其他所有节点进行管理，那么这个领导者只需要根据集群配置信息就能获得集群中除自己之外的所有节点的网络地址，然后向它们发送心跳消息就行了。这么做确实很方便，也很直接，几乎不用编写什么复杂的代码。但是，让我们想想这么做有什么弊端， 首先这么做会让 NodeImpl 类更加庞大，因为我们定义的向跟随者节点发送心跳的方法，归根结底也是节点本身的方法，如果不另外设计，这个方法肯定也要定义在 NodeImpl 类中。当然，NodeImpl 本来已经有些膨胀了，再让它膨胀一些也无所谓，这个也称不上什么明显的弊端。但是，除此之外，让我们再稍微扩展一下，raft 集群中的一个节点成为领导者之后，肯定需要生产日志，然后将日志复制给集群中的每一个跟随者。这个是前三章的知识，大家应该还记得。一旦开始复制日志，会发生什么呢？显然领导者就会按照日志的索引顺序，将本地日志一条条复制给集群中的所有跟随者。每一个跟随者接收到日志之后，会将日志本地持久化。当然，这个只是最理想的情况，每个跟随者节点所处的网络环境不一样，领导者通过网络传输向每个跟随者节点复制日志，可能有的能复制成功，有的不能复制成功，如果有的跟随者节点在某次复制日志时没有成功，领导者就会重新传输失败日志给跟随者节点。分析了这么做，其实只是有一个意思，那就是每个跟随者节点复制日志的进度可能是不同的。如果集群中有 3 个节点，节点 1 为领导者，节点 2、3 分别为跟随者，在某个时刻，节点 2 复制日志从领导者复制完了索引为 8 的日志，节点 3 才刚刚从领导者复制完了索引为 6 的日志。如果领导者不对每一个跟随者进行包装或者管理，将关于集群中所有跟随者节点的信息全部定义在 NodeImpl 类中，我相信不用我说，大家也能想象到，NodeImpl 类中的代码将会非常混乱和复杂，代码可维护性将大大降低。  
虽然在第一版本代码中，领导者还没有实现传输日志给跟随者的功能，但用不了多久就要实现了。所以，我就直接仿照 sofajraft 框架的做法， 在我们自己的程序中也引入一个 Replicator 类，我把这个类的对象成为复制器对象。当 raft 集群中一个节点当选为领导者后，这个领导者将会把集群中其他的每一个节点，都用一个 Replicator 对象来包装。然后将心跳传输和日志复制的方法都定义在 Replicator 类中。这就意味，每一个 Replicator 对象都对应集群中唯一一个节点，并且负责向这个节点发送心跳消息以及日志传输。这就是我在本章要为大家讲解的领导者管理跟随者的方式 。这样一来，每一个跟随者节点的信息都可以直接封装在与其对应的 Replicator 对象中了，比如这个跟随者节点要从领导者接收的下一条日志索引，领导者向该跟随者发送了多少次心跳消息等等。说了这么多，那这个 Replicator 类该怎么定义呢？  
我认为，在这个 Replicator 类内部， 首先需要定义一个定时任务调度器 ，原因很简单，因为这个 Replicator 类的对象要向对应的跟随者节点发送心跳消息，而心跳消息的发送具备周期性，所以肯定需要要一个定时任务调度器来调度。除此之外， 还要把当前节点部署的客户端对象定义为 Replicator 类的成员变量 ，这个也很容易理解，客户端是用来给集群中其他节点发送消息的，而这个 Replicator 对象正好负责给对应的跟随者节点发送心跳消息，所以，Replicator 类中持有发送消息的客户端也是必须的。当然，还有最重要的一个内容，那就是当前 Replicator 包装的是哪个跟随者节点， 这个跟随者节点的信息也需要交给 Replicator 对象 。所谓信息也就是这个跟随者节点的 IP 地址和端口号，Replicator 对象向与其对应的跟随者节点发送消息，总得知道这个跟随者节点的网络地址吧？当然，你还可以继续定义两个成员变量，一个是 groupId，代表这个跟随者节点所在的集群的 ID，一个是 serverId，这个 serverId 就是当前领导者节点的信息，这样一来，包装着跟随者的 Replicator 就知道自己包装的跟随者是属于哪个领导者的了。所以，现在我就为大家分析好了，这个 Replicator 类中究竟应该定义什么成员变量： 一个定时任务调度器，用来向对应的跟随者节点发送心跳消息，Replicator 包装的跟随者节点的信息，groupId 以及 serverId 。对应的代码我也已经编写好了，请看下面代码块。  
好了，Replicator 类的成员变量都已经定义好了，就在上面的代码块中，看起来还挺简单的。接下来，让我们想想，应该给这个类定义什么方法？其实在前面已经为大家分析过了， 发送心跳消息的方法肯定得有吧？既然发送了心跳信息，肯定就会接收到心跳响应，所以，处理心跳消息响应的方法也必须要有吧 ？除此之外，暂时也用不着定义什么方法了。在第一版本中还用不着实现日志传输，所以， 要在 Replicator 类中定义的最主要的方法，其实就两个，一个就是给对应的跟随者发送心跳消息的方法，另一个就是在跟随者回复了心跳消息的响应后，当前领导者节点处理心跳响应的方法 。这两个方法的名字我都已经定义好了， 发送心跳消息的方法名为 sendEmptyEntries，意思为发送空的条目，这里也可以稍微为大家扩展一下，实际上在后面的版本中，我们会在 Replicator 类中继续定义发送日志给跟随者的方法，发送日志的方法名为 sendEntries，也就是发送多个条目的意思。而 sendEmptyEntries 为发送空条目，没有条目就意味着当前发送的是心跳消息 。处理心跳响应的方法名为 onHeartbeatReturned，从名字上也很容易就能看出这个方法的作用。当然，这时候还无法为大家具体展示这两个方法的实现逻辑，所以就先定义两个空方法在 Replicator 类中吧。  
也许有朋友会感到疑惑，为什么这个 Replicator 类讲到一半就不讲了，接着往下讲，直接把心跳检测的流程分析一下不行吗？当然没问题，我肯定要为大家实现心跳检测功能的，但别忘了我们这一小节的标题，这一小节的目的是实现 becomeLeader 方法，所以还是先让我们回到正轨上来吧。  
在前面我为大家分析了，raft 集群中的一个节点当选为领导者之后，需 要将自己的状态更新为 State.STATE\_LEADER，然后立即向集群中的其他所有节点发送心跳信息 。在分析心跳信息发送方式的时候，我为大家引入了 Replicator 类，并且解释了为什么要把集群其他的每一个节点都用 Replicator 对象来包装，也展示了 Replicator 类的部分内容。如果大家理解了上面的这个流程，肯定也都赞同这样一种逻辑， 那就是在领导者向集群中其他节点发送心跳信息之前，应该先把集群中其他的所有节点都用 Replicator 来包装一下 。很好，现在问题来了，将集群中其他节点包装成 Replicator 的操作应该在哪里执行呢？答案已经不言而喻了，肯定就是在这个 becomeLeader 方法中。简而言之， 当 raft 集群中的一个节点成为领导者后，会调用 becomeLeader 方法更新自己的节点状态为 State.STATE\_LEADER，然后再将集群中的其他所有节点都包装成一个个 Replicator 对象 。这就是我为大家总结出来的目前的 becomeLeader 方法的实现逻辑。  
当然，我为大家分析的是简化之后的实现逻辑，在 sofajraft 框架中，becomeLeader 方法的实现逻辑稍微复杂一些。因为 becomeLeader 方法也是定义在 NodeImpl 类中的， 所以 sofajraft 框架首先为 NodeImpl 类引入了一个新的成员变量，那就是 replicatorGroup，这个成员变量的类型是 ReplicatorGroupImpl，ReplicatorGroupImpl 实现了 ReplicatorGroup 接口 。这个 ReplicatorGroup 的作用非常明显，就是用来管理所有的 Replicator 对象。节点成为领导者后，需要将集群中其他节点都包装成 Replicator 对象，而包装成的这些 Replicator 对象都要交给 ReplicatorGroup 对象来管理，ReplicatorGroup 内部定义了一个 Map 成员变量，专门用来存放 Replicator。如果解释得更直接一点，那就是把属于一个集群的所有 Replicator 都交给这一个 ReplicatorGroup 来管理。这个 replicatorGroup 成员变量也是在 NodeImpl 对象的 init 方法中被创建，然后被初始化。除了这个 replicatorGroup 成员变量，还要在 NodeImpl 类中定义另一个重要的成员变量， 那就是 rpcService，这个 rpcService 对象的类型为 RaftClientService，它就承担了当前节点的客户端职责 。当前节点要向集群中其他节点发送消息，比如之前两章实现的发送预投票请求和正式投票请求，这些请求都是这个 rpcService 客户端发送的。其实在前两章我就应该把这个 rpcService 成员变量定义在 NodeImpl 类中，结果忘了，这里算是补充完整了。当然，不用我说大家也能猜出来，NodeImpl 类中的这个 rpcService 成员变量肯定也是要给 Replicator 对象使用的，Replicator 复制器对象中不是也定义了一个 RaftClientService 类型的 rpcService 成员变量吗？最后还应该在 NodeImpl 类中定义一个成员变量，那就是 Replicator 要使用的定时任务调度器 timerManager。  
好了，现在大家肯定都已经蒙圈了，不明白为什么要在 NodeImpl 类中新定义这么多成员变量。先让我来为大家解释一下，实际上，在 sofajraft 框架中，当一个节点成为集群中的领导者之后，会进行下面的操作流程： 执行 becomeLeader 方法，在该方法中会调用 replicatorGroup 对象的方法，将集群配置信息中的每一个节点都包装成 Replicator 对象。因为 Replicator 中定义了一些成员变量，在将每一个跟随者节点包装成 Replicator 对象的时候肯定需要给 Replicator 中的成员变量赋值，这个工作就是由 replicatorGroup 来完成的。所以，这就要求当节点调用 becomeLeader 方法的时候，replicatorGroup 对象也已经被创建，并且初始化完成了，replicatorGroup 对象内部持有者一些成员变量，正好可以用来给 Replicator 对象中的成员变量赋值。那么 replicatorGroup 中的成员变量是怎么被赋值的呢？这个就是显而易见的了，我之前也为大家简单讲解了，replicatorGroup 成员变量会在 NodeImpl 的 init 方法中被创建，然后初始化，初始化完毕之后，replicatorGroup 内部的成员变量就被 NodeImpl 的成员变量赋值了。  
好了，光是这样用文字分析，只会让大家越看越乱，接下来，我就直接用代码为大家展示一下，大家可以通过代码再次梳理一下刚才的流程。  
首先是 timerManager 定时任务调度器，这个定时任务调度器专门执行心跳消息的发送，其类型为 TimerManager，实现了 Scheduler 接口，所以我也经常称它为定时任务管理器。请看下面代码块。  
首先是 Scheduler 接口。  
然后是 TimerManager 类本身。  
接下来是 replicatorGroup 成员变量，这个成员变量的类行为 ReplicatorGroupImpl 类型，这个类实现了 ReplicatorGroup 接口。这里就不展示 ReplicatorGroup 接口了，直接展示 ReplicatorGroupImpl 实现类，具体实现请看下面代码块。  
这个类的具体使用方法先不做讲解，大家只要先对这个类中的 commonOptions 成员变量以及还未实现的 addReplicator 方法有个印象即可。接下来让我们赶快看看重构之后的 NodeImpl 类。请看下面代码块。  
到此为止，这个重构过后的 NodeImpl 类就给大家展示完了。当然，目前展示的只是重构之后的 init 方法，并且展示的是 init 方法的部分代码，最重要的 becomeLeader 方法还没有给大家展示。因为我想在继续展示 becomeLeader 方法之前，为大家简单梳理一下在上面代码块中展示的 init 方法中，当前节点都执行了什么操作。  
在节点初始化的时候：  
1 创建了一个 timerManager 定时任务调度器，也可以称为定时任务管理器；  
2 接着又创建了用来向集群中其他节点发送消息的客户端 rpcService  
3 创建了一个 ReplicatorGroupOptions 对象，用来封装一些重要的参数，这个 ReplicatorGroupOptions 对象内部的配置参数，会在创建 Replicator 对象的时候，给 Replicator 对象的成员变量赋值  
4 给 ReplicatorGroupOptions 对象内部的各个成员变量赋值  
5 初始化客户端 rpcService  
6 初始化 replicatorGroup 对象，在调用 replicatorGroup 对象的 init 方法时，大家可以再次回顾上面展示的 ReplicatorGroupImpl 代码块的内容，在 ReplicatorGroupImpl 类的 init 方法中，会把步骤 3 中创建的 ReplicatorGroupOptions 对象中配置的各个参数，设置到 replicatorGroup 对象内部的 commonOptions 成员变量中。注意，当 replicatorGroup 对象的 init 方法调用完毕之后，replicatorGroup 对象内部的 commonOptions 成员变量中的参数也都赋值成功了。很快我们就会用到这个 commonOptions 成员变量了。  
以上就是 NodeImpl 类重构之后的 init 方法的部分逻辑，大家可以再仔细领略一下，如果理顺逻辑之后，接下来，就请大家跟我一起看看 becomeLeader 方法是怎么实现的。当然，在实现 becomeLeader 方法之前，我还是要再啰嗦一下，再重复一次 becomeLeader 方法中要执行的操作。  
在 becomeLeader 方法中：  
1 首先会把当前节点的状态更新为领导者状态，因为只有当选了领导者，才会调用 becomeLeader 方法  
2 调用 replicatorGroup 类的 addReplicator 方法，将集群中其他的每一个节点，都包装成 Replicator 复制器对象，把每一个 Replicator 复制器对象都存放到 replicatorGroup 对象中。  
好了，接下来，就让我们一起看看 becomeLeader 方法的实现逻辑。请看下面代码块。  
现在，becomeLeader 方法的逻辑就全部展示清楚了。代码中注释非常详细，所以我就不再重复讲解其中的逻辑了。当然，becomeLeader 方法展示完毕并不意味着我们要讲解的内容就结束了。因为现在代码的逻辑只展示到调用了 replicatorGroup 对象的 addReplicator 方法，将集群中其他的每一个节点包装成一个个 Replicator 复制器对象。但是这个 addReplicator 方法，我还没有为大家实现。在 ReplicatorGroupImpl 类中，它还是一个空方法。所以，接下来，我就要为大家实现 ReplicatorGroupImpl 类中的 addReplicator 方法。  
  
实现 addReplicator 方法，创建 Replicator 复制器  
  
要实现这个 addReplicator 方法也没有那么难，因为在上一小节我其实已经把节点当选为领导者之后的逻辑分析完毕了，只不过现在我们在 becomeLeader 方法中只展示了一部分。本来领导者节点需要将集群中的其他节点包装成一个个 Replicator 对象，现在我只是给大家展示了该操作的入口方法，也就是 addReplicator 方法。所以， 接下来只要在这个 addReplicator 方法中把对应的跟随者节点包装成 Replicator 对象即可 。具体逻辑请看下面代码块。  
现在 ReplicatorGroupImpl 类经过重构，其内部的 addReplicator 方法被实现了。  
我相信上面代码块中的逻辑对大家来说也没什么难度，都是很简单的逻辑，现在又一次绊住大家脚步的肯定就是上面代码块的第 91 行，也就是 Replicator.start(opts, this.raftOptions) 这行代码，在我之前为大家展示的 Replicator 类中，并没有这个 start 方法，这是大家第一次见到这个方法。我在注释中解释了这行代码的作用，就是用来创建一个 Replicator 复制器对象的。讲到这里，就来到了本小节的重点。  
请大家想一想，当 raft 集群中的一个节点成为领导者之后，它需要将自己的状态更新为领导者状态，然后把集群中其他的每一个节点都包装成一个个 Replicator 对象，那么，当一个个 Replicator 对象创建完毕之后呢？不用想别的， 肯定就是领导者立刻向每一个跟随者节点发送心跳消息呀 ，对吧？这个逻辑之前已经分析过了。 而 Replicator 对象就是在 Replicator 类的 start 方法中创建的，当这个 Replicator 对象创建完毕后，就要立刻向对应的跟随者节点发送心跳消息。所以我就把这个操作也定义在 Replicator 类的 start 方法中了 。  
这样分析下来，大家应该也意识到了，其实在在这个 Replicator 类的 start 方法中，只进行了两个关键操作，那就是创建 Replicator 对象，然后发送心跳消息给跟随者节点。具体逻辑，可以从重构之后的 Replicator 类中查看。在展示代码块之前，我还要再简单解释几句，之前我们在 Replicator 类中定义了 groupId、serverId、peerId 这三个成员变量，在重构之后这几个成员变量就取消了。因为 Replicator.start(opts, this.raftOptions) 代码中，可以看到是用 ReplicatorOptions 类型的 opts 参数对象来创建 Replicator 对象的，opts 对象的成员变量包含了 groupId、serverId、peerId 这些数据的信息，所以在 Replicator 类中就直接也定义了一个 ReplicatorOptions 类型的成员变量，把之前的 groupId、serverId、peerId 三个成员变量取消了。这样一来，Replicator 复制器对象仍然可以知道领导者 Id 和集群 Id，以及包装的对应跟随者节点的信息。好了，现在我们可以看看重构之后的 Replicator 代码了。请看下面代码块。  
接下来就是这个 ThreadId 类，请看下面代码块。这个 ThreadId 类大家可以先混个眼熟，也可以直接去第一版本代码中，结合具体情境来学习这个类的作用。下一章，我会为大家结合心跳消息的流程来讲解这个类的具体作用。  
到此为止，我就为大家把 Replicator 类初步重构了一下，也展示了 start 方法。现在，创建 Replicator 对象，并且发送心跳信息的操作都为大家实现了，大家可以多看几遍代码，或者直接去看我提供的第一版本的代码。这个时候，大家应该可以结合文章掌握第一版本代码了。当然，领导者发送心跳消息，以及处理心跳响应的具体流程和细节，我还没有为大家分析，所以在上面的代码块中，sendEmptyEntries 和 onHeartbeatReturned 方法都还是空的。但是这并不妨碍大家去学习第一版本代码，实际上，结合第一版本代码注释，掌握了前面几章内容的朋友们，很容易就会看明白第一版本代码中实现的这两个方法。  
在本章，这两个方法还不必急着实现。当然，更重要的原因是没时间讲解了。因为我不可能只讲解领导者发送心跳消息和处理心跳响应的流程，领导者把心跳消息发送给跟随者之后，或者说是发送给集群中其他的所有节点，我肯定需要进一步为大家分析集群中其他节点接收到领导者的心跳消息后，该如何处理这个请求。这个过程也包含了很多细节，需要考虑多种情况，为大家全面分析。当领导者处理心跳消息响应的时候，也需要考虑多种情况，分析流程中的细节操作。我非常愿意为大家把知识剖析得非常仔细，所以，就又要多写一篇文章，来为大家讲解心跳消息发送和响应的整个流程。  
好了，不管怎么说，这一章的任务算是完成了。我们为程序引入了 Replicator 复制器，并且也完善了领导者选举。至于 RPC 业务线程的职责，以及心跳消息发送和响应的整个流程，就放到下一章为大家讲解吧。我们下一章见！  
若有收获，就点个赞吧

---
*Source: https://www.yuque.com/u26328320/kxtdy3/kkgxa93fuhgha761*  
*All content belongs to its respective owners and creators.*