大家好，紧接着上一章的内容，这一章我将为大家实现日志组件的初始化。在上一章我已经为大家引入了 LogManager 接口和接口实现类 LogManagerImpl，以及 LogStorage 接口和接口的实现类 RocksDBLogStorage。LogManagerImpl 是日志管理器，RocksDBLogStorage 是日志存储器，也可以称为日志存储引擎。并且 RocksDBLogStorage 是 LogManagerImpl 类的一个成员变量。在上一章我也为大家展示了 LogManagerImpl 和 RocksDBLogStorage 这两个类的内容，当然，这两个类都还非常简单，内部的方法都还没有实现，各自的初始化方法也没有实现。这一章我们就从初始化方法开始讲起，先实现各自的初始化方法，然后再进一步实现其他功能。  
  
剖析 LogManager 初始化流程  
  
大家应该还有印象，在上一章我为大家展示了一下 NodeImpl 类的代码，因为引入日志组件之后，LogManager 日志管理器就被定义为了 NodeImpl 类的一个成员变量，并且我也跟大家讲到了，LogManager 会在 NodeImpl 的 init 方法中被初始化。具体逻辑请看下面代码块。  
public class NodeImpl implements Node,RaftServerService {  
  
//日志管理组件

private LogManager logManager;  
  
//省略其他内容  
  
@ Override

public boolean init (final NodeOptions opts) {  
//省略其他内容  
//初始化日志存储组件

if (!initLogStorage ()) {

LOG.error ("Node {} initLogStorage failed.",getNodeId ());

return false;

}  
//初始化元数据存储器组件

if (!initMetaStorage ()) {

LOG.error ("Node {} initMetaStorage failed.",getNodeId ());

return false;

}  
//省略其他内容

}  
  
//初始化日志组件的方法

private boolean initLogStorage () {

//该方法暂时不实现

}

可以看到，在上面的代码块中，在 NodeImpl 的 init 方法中，执行了 initLogStorage 方法，这个方法就是用来初始化日志组件的。现在我可以跟大家分析分析这个 initLogStorage 方法的实现逻辑了。要 初始化日志组件，首先肯定得先创建日志组件，或者说先得到日志组件的对象，这里的日志组件指的就是 logManager 日志管理器。当然，创建日志管理器时肯定就是创建 LogManager 接口实现类的对象，也就是创建 LogManagerImpl 对象，然后再调用该对象的 init 方法 。这个逻辑还是比较简单的，但是在 sofajraft 框架中，在 initLogStorage 方法中做了更多的操作。 在 sofajraft 中不仅创建了 LogManagerImpl 对象，还创建了 RocksDBLogStorage 对象。实际上，在 sofajraft 框架中，日志存储器也被定义为了 NodeImpl 类中的成员变量。虽然 NodeImpl 对象本身并没有直接使用日志存储器的情况 。具体实现请看下面代码块。  
这时候大家肯定感到困惑，不明白为什么在 sofajraft 框架中，把日志存储器也定义为 NodeImpl 的成员变量。让我来给大家简单解释一下，实际上，在 sofajraft 框架中，日志存储器接口 LogStorage 有多个不同的实现类，RocksDBLogStorage 只是其中之一，也是逻辑比较简单的一个实现，除了 RocksDBLogStorage 实现类，还有其它 4 个不同的实现类，也就是说在 sofajraft 框架中可供选择使用的日志存储器有 5 个，我为大家展示的只是其中一个，就是这个 RocksDBLogStorage 类。其他的 4 个日志存储器我们先不必关心，大家感兴趣的话可以直接去源码中查看。现在我们先看看这个 RocksDBLogStorage 类的对象是怎么创建的。  
在上面代码块中，我不止为大家展示了 logManager 和 logStorage 这两个成员变量，还展示了 serviceFactory 成员变量。如果大家对第 4 章的内容还有印象，肯定就能回忆起来，这个 serviceFactory 就是为框架提供各种服务组件的工厂。实际上， 日志存储器就是这个 serviceFactory 服务工厂提供的，这也就意味着 RocksDBLogStorage 对象是在 serviceFactory 服务工厂内部创建的 。具体实现请看下面代码块。  
反正 NodeImpl 类持有者这个 serviceFactory 服务工厂，这样一来，在程序执行到 NodeImpl 对象的 init 方法时，开始在方法内部的 initLogStorage 方法中初始化日志组件，就可以直接使用 serviceFactory 服务工厂创建 RocksDBLogStorage 日志存储器，然后把日志存储器交给 LogManagerImpl 日志管理器使用，同时还能直接给 NodeImpl 类中的 logStorage 赋值。  
好了，现在我们已经分析了几个要在 initLogStorage 方法中执行的操作： 1 使用 serviceFactory 服务工厂创建 RocksDBLogStorage 日志存储器对象；2 将日志存储器对象赋值给 NodeImpl 类的 logStorage 成员变量；3 创建 LogManagerImpl 日志管理器对象；4 调用 LogManagerImpl 日志管理器对象的 init 方法，将日志存储器对象交给日志管理器对象使用 。具体实现请看下面代码块。  
本来讲到这里，我们就可以直接去实现 LogManagerImpl 类的 init 方法了。但是，在实现这个方法之前，我想先为大家把主题岔开一下，讲点不一样的东西。在上一章我为大家讲解了， 实际上在 sofajraft 框架中，每一条日志想要持久化到本地，都要通过 RocksDBLogStorage 日志存储器才能实现。而在 RocksDBLogStorage 存储器中，实际上是持有了 RocksDB 数据库对象，把日志存储到 RocksDB 数据库中，再由这个数据库完成持久化 。所以说， 一条日志完整的持久化流程是先被领导者生产出来，然后这条日志会交给 LogManagerImpl 日志管理器，调用日志管理器的 appendEntries 方法，将日志交给 RocksDBLogStorage 日志存储器，在日志存储器中，再将日志交给 RocksDB 数据库对象，存储到 RocksDB 数据库中，再由数据库完整本地持久化 。这个其实是下一章的内容了，下一章我要为大家实现日志落盘功能，但是现在有些知识点也需要围绕着日志落盘来简单讲解一下，所以就先为大家稍微扩展一下，下一章会讲解得更加详细。总之，一条日志持久化成功，最终是通过 RocksDB 数据库实现的，要想将日志持久化成功，就要先把日志存放到 RocksDB 数据库中。现在我要为大家继续拓展一个知识点， 那就是 RocksDB 数据库是一个以键值对方式来存放数据的数据库 。这就意味着在我们实现的框架中，如果一条日志想要存储到 RocksDB 数据库中，也需要以键值对的方法进行存储。这个好说，既然是键值对的方式，而且之前我们已经分析过了， 领导者内部生产的每一条日志都有唯一的日志索引，那么存储日志的时候，就以日志的索引为键。日志本身，也就是 LogEntry 对象为 value， 这样不就可以把日志顺利存储到这个键值对数据库中了吗？  
很好，如果上面的知识大家都理解了，接下来让我们再思考另一个问题，那就是日志本身需要怎么存放到 RocksDB 数据库中呢？刚才我们已经明确了，日志需要以键值对的方式存放到 RocksDB 数据库中。但是，这只是为我们制定了一个大的方针而已，具体的细节都还没有明确。比如说，将数据存放到数据库的时候，是以字符串的方式存储呢？还是以另外的方式存储呢？如果是我的话，我就弄得直接一点， 反正这些数据最终都是要持久化到硬盘上的，索性从一开始我就把这些日志编码成二进制数据，然后直接以二进制的形式将日志存放到 RocksDB 数据库中，RocksDB 数据库再将这些数据持久化到硬盘即可 。  
如果是这样的话， 显然我就要再为自己的程序定义一个编码器 ，对要存放到 RocksDB 数据库中的日志进行编码，当然， 既然有日志编码器，自然也应该有日志解码器 ，因为你肯定会在某些场景下，需要将日志从本地加载到内存，到时候就需要解码器登场了。所以，为我们的程序构建编解码器就成了目前的主要任务。  
那么这个编码器应该怎么定义呢？我们的每一步思考都应该是有逻辑的，既然现在要定义日志编码器了，首先应该考虑的是什么？毫无疑问，应该考虑的是应该对数据的哪些内容进行编码，以及应该定义怎样的编码协议？说协议可能有些夸张了，那么，至少应该定义一个编解码的标准，或者是规范吧？ 既然日志是以键值对的方式存放到 RocksDB 数据库中的 ，然后持久化到本地，这就意味着键值对中的 key、value 都需要进行二进制编码，key 就是日志索引，value 也就是 LogEntry 对象本身。 如果对 key 进行编码，无非就是把 key 编码成二进制数据，这个很好说，毕竟 key 也就是一个整型数值，所以这个并不是我们要研究的重点，我们关注的重点是如何对 value，也就是 LogEntry 进行编码，换句话说，要对 LogEntry 定制什么样的编码规范 ？  
很好，现在目标已经有了，那么请大家想一想，根据我们对 RPC 的了解，当我们自己手写 RPC 框架的时候，通常都会自定义编码协议，自己定义编解码规范。在我们自己定义的编码规范中，可能会先定义魔数，版本号，数据长度，甚至还会预留一个扩展位，最后是数据本身。那么在我们自己实现的 raft 共识算法框架中，可以怎么定义编码规范呢？这时候简单点就可以了，没必要设计得非常复杂， 首先魔数是必须要有的，魔数的作用有很多，但最重要的作用就是可以作为一段二进制数据的起始标识，通过对魔术的检验，我们可以准确判断当前正在解码的数据是不是一个 LogEntry 的二进制数据；然后再定义一个协议版本号吧，预留一个扩展位字段也很有必要，谁知道以后会不会拓展别的什么功能呢？最后就是 LogEntry 数据本身了 。  
总之，这么分析下来，我们要对 LogEntry 日志进行编码的规范也差不多明确了，接下来再确定一下协议中的具体字节即可。我是这么规划的， 魔术使用 2 个字节来表示，协议版本号使用 1 个字节来表示，预留字段使用 3 个字节来表示。这样算下来，这三个重要数据一共占据了 6 个字节 ，就像下面代码块展示的这样。  
如果要用代码来表示，可以写成下面这样，请看下面代码块。  
好了，到此为止，这些前置知识都讲解得差不多了，现在得来点真格的了。假如说现在有一个 LogEntry 对象，这个日志对象的索引为 1，要把这个日志持久化到本地，首先应该对这条日志的键值对进行编码，然后存放到 RocksDB 数据库中，最终持久化到本地硬盘。在编码的过程中应该怎么做呢？先不考虑怎么对键值对的 key 如何编码，先让我们关注一下怎么对键值对的 value，也就是 LogEntry 对象如何编码。这就很简单了， 肯定是把 LogEntry 中的全部数据都转化为二进制数据，存放到一个字节数组中 。所以，这时候就要看看 LogEntry 对象中究竟封装着什么数据了，我把上一章的 LogEntry 类搬运到这里了，请大家简单回顾一下。请看下面代码块。  
结合上面的代码块，现在我想为大家简单总结一下， 如果想把一个 LogEntry 对象进行二进制编码，那么就应该把日志对象的任期、索引、日志类型、日志有效数据以及集群中的节点信息都进行编码，然后把编码后的数据存放到一个字节数组中即可 。如果这个逻辑理解了，那么接下来我就来为大家正式展示一下我早已经定义好的 LogEntry 编码器和解码器。  
在展示具体的编解码器之前，我还要先展示一下我定义好的编解码器工厂，也就是 LogEntryV2CodecFactory 类，编解码器就是由这个 LogEntryV2CodecFactory 编解码器工厂创建的。请看下面代码块。  
在上面代码块中可以看到，接下来我要给大家展示的编码器名称为 V2Encoder，解码器的名称为 V2Decoder。接下来我先为大家展示编码器的具体内容，请看下面代码块。  
代码中的注释非常详细，V2Encoder 类中的核心方法就是 encode 方法，大家看看就行。接下来就是 V2Decoder 解码器的具体实现，请看下面代码块。  
到此为止，我就为大家把 LogEntry 对象的编解码器实现完毕了。当然，我们的任务还没有完成，现在我们也只是实现了键值对中的 value 的编解码功能，那么键值对中的 key 该怎么编码呢？这个很简单，在 sofajraft 框架中制定了一个规范， 那就是日志索引统一编码成为 8 个字节长度的二进制数据 ，使用以下方式对键值对的 key 进行编码，请看下面代码块。  
现在，我才终于为大家把日志编解码的功能全都实现了。好了，此刻我终于可以解释一下为什么我在前面忽然把主题岔开了，没有继续实现 LogManagerImpl 类的 init 方法，而是讲起了日志的编解码器。这是因为在 LogManagerImpl 初始化的过程中，用到了日志编解码器，而编解码器都是由 LogEntryV2CodecFactory 工厂创建的，但是 LogEntryV2CodecFactory 工厂是由 DefaultJRaftServiceFactory 服务工厂创建的，具体实现请看下面代码块。  
而我们在 NodeImpl 类的 initLogStorage 方法中已经使用 DefaultJRaftServiceFactory 服务工厂创建了日志存储器，也就是 RocksDBLogStorage 对象，接下来其实就应该紧接着把编解码器工厂创建出来，交给 LogManagerImpl，让它在初始化的时候能够使用。所以，NodeImpl 类的 initLogStorage 方法的部分代码应该重构成下面这样。请看下面代码块。  
好了，编解码器讲完之后，本章的核心内容其实已经讲完了，剩下的日志组件初始化的流程都比较常规。我为大家简单讲讲即可。当程序在上面代码块的 initLogStorage 方法中执行了 logManager.init(opts) 代码时，程序就会来到 LogManagerImpl 类中，执行 LogManagerImpl 对象的 init 方法。而在 LogManagerImpl 对象的 init 方法中，所做的操作很简单， 无非就是对 LogManagerImpl 类中的成员变量赋值，然后初始化日志存储器即可，也就是调用 RocksDBLogStorage 对象的 init 方法 。具体实现请看下面代码块。  
接下来，程序的执行流程就来到了日志存储器的 init 方法中，也就是 RocksDBLogStorage 类的 init 方法中。在这个方法中做了很多操作。这些操作还是很有必要为大家梳理一下的。要想正确认识 RocksDBLogStorage 类 init 方法中的诸多操作，仍然要先讲解一些前置知识，或者说对现有的 RocksDBLogStorage 类进行一些扩充。首先请大家看看上一章的 RocksDBLogStorage 类的简单实现，请看下面代码块。  
在上面的代码块中，RocksDBLogStorage 类中只有几个简单的成员变量，其中最重要的就是 RocksDB 类型的 db 成员变量，这个就是用来存储数据的 RocksDB 数据库本身。但是仅仅有这一个成员变量，还不足以把日志存放到 RocksDB 数据库中，这就要从 RocksDB 数据库存储数据的方式开始讲起了。当我们使用 Mysql 数据库的时候，将数据存放到数据库时，肯定需要明确这些数据要存放到哪张表中，向 RocksDB 数据库中存放数据也是同样的道理，虽然是以键值对的方式存储数据，但也要知道存放的数据究竟存到哪张表中了。 而在 RocksDB 数据库中，一张表其实就可以用 ColumnFamilyHandle 对象来表示。如果两个数据要分别存放到两张表里，就可以创建两个 ColumnFamilyHandle 对象，存放不同的数据 。  
在我们开发的框架中，日志对象其实有两种类型， 一种是业务日志，也就是客户端指令被包装后产生的日志，一种是配置变更日志 。 为了区分这两种日志，在 RocksDBLogStorage 类中还额外定义了两个新的成员变量，这两个成员变量都是 ColumnFamilyHandle 类型，分别为 defaultHandle 成员变量和 confHandle 成员变量。其中 confHandle 就是用来存放配置变更日志的，而 defaultHandle 成员变量就是用来存放业务日志的 。当然，除了这两个重要的成员变量，另外还有一些成员变量也需要定义在 RocksDBLogStorage 类中，这些成员变量都和 RocksDB 数据库有关，封装着数据库相关操作的配置参数。除此之外，还有我之前为大家引入的编解码器。接下来，我就把重构好的 RocksDBLogStorage 类展示给大家，请看下面代码块。  
好了，现在 RocksDBLogStorage 类的成员变量已经重构完整了，我知道大家现在对其中某些成员变量还很困惑，不知道它们的作用。这很正常，因为我当初看源码的时候也是看了后面的逻辑，也就是 RocksDBLogStorage 类的 init 方法的实现逻辑之后，才完全清楚了那些成员变量的作用。所以，接下来我会为大家分析一下 RocksDBLogStorage 类的 init 方法的实现过程。其实要在 init 方法中执行的操作很简单，虽然代码看起来很多，但是逻辑真的很简单， 无非就是建立对 RocksDB 数据库的连接，以便通过 RocksDB 数据库对象直接操纵数据库，向里面存放数据，当然，也需要给 RocksDBLogStorage 类中的各个成员变量赋值。最后，还有一条最重要的逻辑，那就是从本地加载第一条日志的索引，将本地的配置变更日志加载到内存中。因为如果当前节点是故障重启，并不是第一次启动的话，那么在本地肯定有很多数据，这时候肯定是需要把本地的数据加载到内存中，使节点尽快恢复到宕机之前的状态 。  
RocksDBLogStorage 类的 init 方法我也早就为大家实现了，接下来就请大家看看下面的代码块。  
好了朋友们，上面的代码块展示完毕之后，这一章的内容也就结束了。可以看到，最后一个代码块的内容非常多，我也没有多么仔细的分析。请允许我解释一下，在上面代码块中虽然出现了很多方法，但是这些方法的逻辑都很常规，就相当于 1+1 一定等于 2 的那种逻辑，只要顺着方法一直往下看，肯定可以看懂，所以我就不做过多解释了，况且代码中的注释已经非常详细了。当然，在这一章里，不管是 LogManagerImpl 类还是 RocksDBLogStorage 类，这两个类中都有一些方法还没有为大家实现。在第二版本代码中，这些方法都加上了非常详细的注释，实现得也都非常简单。所以，大家也可以直接去代码中查看。可能有的朋友也注意到了，本章我已经为大家引入了日志编码器，但是这个编码器并没有被我们真正使用。这不要紧，下一章我将为大家实现日志落盘，在这个过程中就会用到日志编码器了。这些知识就留到下一章为大家讲解吧，好了朋友们，我们下一章见！  
若有收获，就点个赞吧

---
*Source: https://www.yuque.com/u26328320/kxtdy3/haqvlz06up04iabm*  
*All content belongs to its respective owners and creators.*