在上一章我们已经对 FSMCallerImpl 状态机组件完成了重构，实现了 FSMCallerImpl 状态机组件同步和异步生成快照文件的操作，并且我也为大家详细剖析了 sofajraft 框架生成的快照文件的模式。在上一章结束的时候，我们关注的重点又回到了 NodeImpl 类中，现在我把 NodeImpl 类中和快照生成有关的内容再给大家展示一下，帮助大家简单回顾一下，请看下面代码块。  
package com.alipay.sofa.jraft.core;  
  
public class NodeImpl implements Node,RaftServerService {  
//省略其他成员变量

//快照生成定时器

private RepeatedTimer snapshotTimer;  
//状态机组件

private FSMCaller fsmCaller;  
  
/\*\*

\* @author:B站UP主陈清风扬，从零带你写框架系列教程的作者，个人微信号：chenqingfengyangjj。

\* @Description:系列教程目前包括手写Netty，XXL-JOB，Spring，RocketMq，Javac，JVM等课程。

\* @Date:2023/11/21

\* @Description:本类最最核心的方法，初始化节点的方法，jraft框架中的所有组件都是在这个方法中初始化的，但是我们这是第一版本代码

\* 所以初始化的组件非常少，只有集群内部使用的客户端服务初始化了，还有元数据存储器初始化了

\*/

@ Override

public boolean init (final NodeOptions opts) {  
//省略该方法的其他内容  
//创建状态机组件

this.fsmCaller \= new FSMCallerImpl ();  
//得到NodeId对象的toString方法结果

final String suffix \= getNodeId ().toString ();

//得到快照生成定时器

String name \= "JRaft-SnapshotTimer-" + suffix;

//创建快照生成定时器，这里定义了定时任务要执行的间隔时间

this.snapshotTimer \= new RepeatedTimer (name,this.options.getSnapshotIntervalSecs () \* 1000,

在上面代码块中，只要 snapshotTimer 快照定时器定时调用 doSnapshot() 方法，那么 raft 集群的节点就可以定时调用 FSMCallerImpl 状态机组件的 onSnapshotSave() 方法生成快照文件。这一点大家肯定都很熟悉了，但是我们也都非常清楚，仅仅把 jraft 框架生成快照的功能实现到这种程度还远远不够，因为还有很多和生成快照文件相关的重要功能没有实现，还有很多问题没有解决。在上一章结束之前，我为大家分析了几个尚未解决的问题，现在我就再为大家总结一下，把这几个尚未解决的问题展示在下面，而我们本章的内容就要围绕着这几个问题来展开，把这几个问题都解决了，jraft 框架生成快照文件的功能就彻底完善了，本章的内容也就结束了。以下就是上一章实现的 jraft 框架生成快照的功能中尚未解决的问题：  
1 虽然在 jraft 集群启动的时候可以由用户自己定义存储快照文件的路径，但是用户定义的快照文件的存储路径并没有在我们实现的功能中用到。  
2 同步或者异步生成快照的功能并没有在程序中体现出来，也就是说，并没有把同步或者异步生成快照的操作交给用户来选择。  
3 快照定时器每一次要执行的定时任务，都必须真的执行吗？什么情况下可以不执行本次生成快照文件的定时任务呢？  
4 生成了快照文件之后，那么与快照文件存储数据对应的日志条目应该怎么删除呢？  
5 快照文件的生成是一个定时任务，也就是说，在 sofajraft 框架构建的 raft 集群中，只要集群一直正常运行，对外提供服务，那么每一个节点都会应用新的日志，每一个节点备份的数据会发生变化，也就意味着会生成新的快照文件。那么新的快照文件生成了，旧的快照文件该怎么删除呢？毕竟每一个快照文件存储的都是生成快照文件那一刻状态机中保存的所有数据，既然是这样，那么新生成的快照文件中的数据一定是状态机中保存的最新的数据，所以旧快照文件也就可以删除了，这一点大家应该可以理解吧？那么旧的快照文件应该怎么删除呢 ？  
以上就是我们目前面临的五个问题，接下来就让我们从第一个问题开始分析，依次解决它们。  
  
引入 LocalSnapshotStorage 本地快照存储器  
  
如果我们只是想把用户在 jraft 集群启动的时候定义的存储快照文件的路径传递到程序中，或者说的准确一点，可以让 FSMCallerImpl 状态机组件生成快照文件的时候，使用用户定义的存储快照文件的路径，那么这个功能实现起来还是非常简单的。无非就是在 FSMCallerImpl 中定义一个 String 类型的 path 代表存储文件的路径，然后在当前节点初始化的时候，也就是 NodeImpl 对象调用它的 init() 方法时，把用户定义的路径赋值给 FSMCallerImpl 状态机组件中的 path 成员变量即可。因为 FSMCallerImpl 状态机组件就是在 NodeImpl 的 init() 方法中创建的。这个逻辑理解起来并不困难吧？但是我们不能这么简单的考虑这个问题，这倒不是说在我们开发项目的时候不能按照这个思路来编写代码，实际上，我个人更倾向于使用清晰易懂，也就是常规的思路，简单的代码实现健全的功能。但是在我们目前要进一步完善的 sofajraft 框架的生成快照文件的功能时，我们并不能这么做，因为在 sofajraft 框架源码在处理用户定义的存储快照文件的路径时，并不是像我们想象得这么简单。接下来就让我来为大家解释一下。  
  
实际上，在 sofajraft 框架中是这么做的： 当 FSMCallerImpl 状态机组件想要生成快照文件时，并不会直接就把生成的快照文件存储在用户定义的文件目录中，而是会先创建一个临时目录，也就是一个临时文件夹，等快照文件成功生成完毕之后，才会把快照文件从临时目录下转移到正式的目录下 。sofajraft 框架这么处理快照文件的原因我们也能想到，肯定是担心在生成快照文件的过程中出现一些问题，导致快照文件生成失败，或者生成到一半操作执行突然被中断了，这样一来还需要把正式目录下的错误快照文件清除了。为了避免出现这种情况，索性就先把生成的快照存放到临时文件夹中，成功生成完毕之后，再转移到正式文件夹中。 说白了其实就是要保证生成快照操作的原子性和一致性 ，我相信这一点大家应该都能理解。  
  
如果大家理解了这一点，那接下来让我们思考一下，该怎么实现这个功能呢？临时目录和正式目录都还好说，实现起来没有一点难度， 这里面有一个最关键的操作，那就是等快照文件成功生成之后，需要把快照文件从临时目录移动到正式目录中。这个功能该如何实现，确实需要思考一下，因为我们必须要清楚地知道快照文件是否成功生成了，也就是说，我们需要知道快照成功生成的时机。一旦快照文件成功生成了，就可以直接把该文件从临时目录移动到正式目录了 。那怎么就知道快照文件成功生成的时机呢？我相信这时候肯定已经有朋友能够想到了， 直接使用回调方法啊 ！快照文件是由 FSMCallerImpl 状态机组件生成的，而上一章我在为大家重构 FSMCallerImpl 状态机组件的时候，在代码块中展示了以下内容，请看下面代码块。  
通过对以上代码块中的内容的学习，我们已经知道了只要调用 FSMCallerImpl 状态机组件的 onSnapshotSave(final SaveSnapshotClosure done) 方法，就可以让 FSMCallerImpl 状态机内部的线程执行生成快照文件的操作，我把 onSnapshotSave(final SaveSnapshotClosure done) 方法的内容单独展示在下面代码块中了，请看下面代码块。  
可以看到， 在上面代码块的 onSnapshotSave() 方法中有一个 SaveSnapshotClosure 类型的参数对象，从该参数的类名称上来看，以及我们对 sofajraft 框架传输日志以及应用日志操作的掌握，我们完全可以才想到这个 SaveSnapshotClosure 类型的参数对象其实就是一个回调对象，并且这个回调对象中的方法会在快照生成完毕之后被回调 。这个逻辑大家可以再消化消化。而这个 SaveSnapshotClosure 类型的参数对象最终会被传递到 FSMCallerImpl 状态机组件的 doSnapshotSave() 方法中，而在 doSnapshotSave() 方法中会调用用户定义的真正的状态机，也就是 StateMachine 对象的 onSnapshotSave() 方法执行生成快照的操作。 如果我们让用户真正定义的 StateMachine 状态机对象得到 SaveSnapshotClosure 类型的参数对象，那么就可以在 StateMachine 状态机执行完快照生成的操作后执行 SaveSnapshotClosure 回调对象中的方法。也就是说，这个 SaveSnapshotClosure 回调对象中的方法确实可以在快照成功生成之后被回调，那么我们就把快照文件从临时目录移动到正式目录的操作定义在 SaveSnapshotClosure 回调对象中不就行了吗 ？就像下面代码块中展示的这样，请看下面代码块。  
上面代码块中的内容非常详细，我就不再重复讲解了。好了朋友们，到此为止我们已经清楚地知道了快照文件成功生成的时机，也知道怎么把快照文件从临时目录移动到正式目录了， 只需要把移动快照文件到正式目录的操作定义在 SaveSnapshotClosure 回调对象中，然后把 SaveSnapshotClosure 回调对象交给 FSMCallerImpl 状态机组件的 onSnapshotSave(final SaveSnapshotClosure done) 方法使用即可 。对我们目前要实现的功能来说，这就足够了。现在，我们可以暂时不必考虑怎么定义 SaveSnapshotClosure 回调对象，以及如何创建 SaveSnapshotClosure 回调对象，怎么把该对象传递给 FSMCallerImpl 状态机组件的 onSnapshotSave(final SaveSnapshotClosure done) 方法使用，我们还是先回过头把存储快照文件的临时目录和正式目录，以及把快照从临时目录移动到正式目录的功能实现了吧。  
  
在上一章我已经为大家展示了我自己定义的 jraft 框架存储快照文件的目录，就是下面代码块展示的这样，请看下面代码块。  
上面代码块展示了存储快照文件的正式路径，其实就是把生成的快照文件存储在 snapshot 文件夹中，当然，在该文件夹中还会为每一次生成的快照文件创建新的名称为 snapshot\_X 文件夹。现在我们要做的是把这个临时路径定义出来，这个其实也很简单，我已经想好了， 就把这个临时路径定义为 "temp" 。当然， 这其实就意味着当 jraft 框架构建的集群节点每一次生成快照文件的时候，要先在 snapshot 文件夹中创建一个用来存放临时快照文件的文件夹，也就是 "temp" 文件夹，然后把生成的临时快照都存放到 "temp" 文件夹中。等快照文件成功生成完毕之后，就可以根据快照文件应用的最后一条日志的索引创建正式文件夹，比如说快照文件夹应用的最后一条日志索引为 100，那么这时候就会在 snapshot 文件夹中创建一个 snapshot\_100 的文件夹，然后把 "temp" 临时文件夹中的快照文件移动到 snapshot\_100 文件夹中即可 。大家可以仔细品味品味这个逻辑，如果这个逻辑理解清楚了，那么接下来我们就一起来实现这个操作流程吧。  
  
我决定为我们自己发开的 jraft 框架引入一个新的组件， 这个组件就是专门负责把快照文件从临时文件夹移动到正式文件夹操作的 。 我把这个新引入的组件定义为了本地快照文件存储器，也就是 LocalSnapshotStorage 类 。就目前的情况来说，这个 LocalSnapshotStorage 类的内容非常简单，我只需要把存储临时快照文件的文件夹路径定义在该类中即可。当然， 因为 LocalSnapshotStorage 负责把快照文件从临时文件夹移动到正式文件夹中，这就意味着在 LocalSnapshotStorage 组件要根据快照文件应用的最后一条日志的索引创建对应的正式存储快照文件的文件夹，所以 LocalSnapshotStorage 组件肯定要知道生成的日志快照应用的最后一条日志索引，所以我把这个也定义为 LocalSnapshotStorage 类的成员变量了 。目前这个 LocalSnapshotStorage 类定义成下面这样，请看下面代码块。  
从上面代码块中可以看到，我把存储临时快照文件的文件夹路径和快照文件应用的最后一条日志的索引定义在 LocalSnapshotStorage 类中了，该类的其他内容还没有实现，所谓其他内容，其实就是把快照文件从临时文件夹移动到正式文件夹的功能还没有实现。但目前我们还不急着实现它，现在我有一个新的问题想问问大家， 那就是我们新引入的这个 LocalSnapshotStorage 组件在什么时候被创建呢 ？我之所以在这里提出这个问题，是因为在我为大家展示的代码块中，我们可以清楚地看到， LocalSnapshotStorage 类的 path 成员变量是在构造方法中被赋值的，也就是说，当 LocalSnapshotStorage 对象被创建的时候，其内部的成员变量 path 才会被赋值 。当然， 在 LocalSnapshotStorage 类的构造方法中，我们也可以看到 lastSnapshotIndex 的默认初始值被赋值为 0 了 。LocalSnapshotStorage 类中的成员变量都是在构造方法中被赋值的，所以，LocalSnapshotStorage 对象在什么时候、怎么被创建就显得尤为重要了。那么，这个 LocalSnapshotStorage 对象应该在什么时候被创建呢？  
  
按照我们前面章节对 sofajraft 框架的学习和了解， jraft 框架需要的各个组件在程序启动之初就会被创建然后初始化，就比如说管理日志的组件，状态机组件，还有各种定时器以及投票箱等等功能组件，都会在 NodeImpl 类的 init() 方法中被创建，然后初始化。初始化的过程也很简单，程序启动的时候会把用户定义的各种参数信息封装到 NodeOptions 对象中，然后使用 NodeOptions 对象中的信息初始化各个组件即可。 那么现在引入了新的 LocalSnapshotStorage 快照存储器组件，这就不用说了，LocalSnapshotStorage 对象肯定也是在程序启动之初就会被创建然后初始化，初始化的时候，就会得到 NodeOptions 对象中持有的快照文件存储路径 。这样一来， 也就意味着 jraft 集群中的节点一旦启动，那么就会在节点内部创建一个 LocalSnapshotStorage 快照存储器对象，这个对象内部持有着存储临时快照文件的文件夹路径，以及快照文件应用的最后一条日志的索引 。与此同时，我们应该也能想到，尽管现在我们还没有完全实现 LocalSnapshotStorage 类的所有功能，并且还不知道这个类的对象究竟应该怎么使用、在哪里被使用，但就目前的情况来说，我们肯定知道一点， 那就是这个 LocalSnapshotStorage 快照文件存储器既然会在节点启动的时候就被创建出来，并且会在节点生成快照文件的过程中被用到，而节点生成快照文件的操作是一个定时任务，这也就意味着，节点每一次生成快照文件，就会用到这个 LocalSnapshotStorage 快照存储器 。  
  
当然，具体使用的方式我们也可以猜到： 那就是节点在生成快照的过程中，要使用 LocalSnapshotStorage 快照存储器得到存储临时快照文件的文件夹路径，然后生成快照，把快照存储在临时文件夹中，等快照成功生成完毕后，再使用 LocalSnapshotStorage 快照存储器根据快照文件应用的最后一条日志的索引创建正式存储快照文件的文件夹，然后把快照文件从临时文件夹中移动到正式文件夹里 。这个逻辑大家应该可以理解吧？并且根据文章前半部分的讲解，我们现在还知道了，把快照文件从临时文件夹中移动到正式文件夹里的操作应该在快照文件成功生成之后才能执行，而 FSMCallerImpl 状态机组件在快照文件成功生成之后会回调 SaveSnapshotClosure 对象中的方法。那这就好办了， 我现在就可以在 LocalSnapshotStorage 类中定义一个新的方法，比如说就把这个方法定义为 close 方法，意味着关闭快照存储器的方法 。所谓关闭快照存储器，其实就是在 raft 集群的节点每一次使用完快照存储器生成快照文件之后，要把快照存储器关闭，既然要关闭快照存储器了，那就意味着可以在 close() 方法中执行一些收尾操作，所以， 我就把从临时文件夹中移动快照文件到正式文件夹的操作定义在 close() 方法中了 。这样一来， 我只需要在 FSMCallerImpl 状态机组件成功生成快照文件之后会回调 SaveSnapshotClosure 对象中的方法时，在 SaveSnapshotClosure 内部的回调方法中进一步调用 LocalSnapshotStorage 快照存储器的 close() 方法 ，这不就真正实现了快照成功生成之后，移动快照文件到正式文件夹的操作了吗？大家可以仔细品味品味这个逻辑，接下来，我就把简单重构之后的 LocalSnapshotStorage 类展示给大家，请看下面代码块。  
上面代码快就展示了我要给 LocalSnapshotStorage 类的 close() 方法定义的逻辑。当然，这个 close() 方法我还没有实现，目前只是把实现思路展示在代码块中了。看到我这个实现思路，我不知道大家会不会感到困惑。因为就目前的情况来说，在 LocalSnapshotStorage 快照存储器关闭的时候，要得到旧的快照文件应用的最后一条日志的索引，还要得到新生成的快照文件应用的最后一条日志的索引，但是我们目前好像根本无法得到旧快照文件应用的最后一条日志索引，也无法得到新生成的最后一条日志的索引。这个问题该怎么解决呢？  
  
重构 LocalSnapshotStorage 本地快照存储器  
  
也许与朋友会说， 我们已经在 LocalSnapshotStorage 类中定义了一个 lastSnapshotIndex 成员变量，这个成员变量记录的就是生成的快照文件应用的最后一条日志的索引，并且每次生成了新的快照文件之后，这个 lastSnapshotIndex 成员变量的值就会被更新 。这也就是说，只要我们每次在 LocalSnapshotStorage 类的 close() 方法中，把新生成的快照应用的最后一条日志的索引更新给 lastSnapshotIndex 成员变量，那我们确实就可以凭借 LocalSnapshotStorage 类的 getLastSnapshotIndex() 方法，在每次生成新的快照文件时，得到旧的快照文件应用的最后一条日志的索引。这个逻辑应该很简单吧？这么做虽然可以使我们得到旧快照文件应用的最后一条日志的索引，但是还存在一个问题，那就是当 raft 集群节点刚刚启动，或者是宕机重启时，在节点本地存在一个最新生成的快照文件，假如说存在的快照文件就存储在 snapshot\_100 文件夹中，这就意味着节点最新生成的快照文件应用的最后一条日志索引为 100。可是通过 LocalSnapshotStorage 类的构造方法，我们可以知道节点启动的时候会给 LocalSnapshotStorage 类的 lastSnapshotIndex 成员变量赋一个默认值 0。这么着的话，当节点生成新的快照文件时，通过 LocalSnapshotStorage 类的 getLastSnapshotIndex() 方法得到的旧快照文件应用的最后一条日志的索引显然是错误的。所以， 现在我们要给 LocalSnapshotStorage 类新定义一个 init() 方法，该方法会在节点启动的过程中被调用，所谓初始化，就是把节点本地最新的快照文件应用的最后一条日志的索引加载到内存，然后赋值给 LocalSnapshotStorage 类的 lastSnapshotIndex 成员变量 。这个逻辑我相信大家也可以理解吧？  
  
那接下来我们就要按照我们刚才的分析实现 LocalSnapshotStorage 类的 init() 方法了。当然，我们没必要那么着急，既然要重构 LocalSnapshotStorage 类了，索性就重构得彻底一点，把 LocalSnapshotStorage 类的 close() 方法也重构了。在上一小节最后我为大家展示了 LocalSnapshotStorage 类的 close() 方法的实现思路，在展示了我认为的实现思路之后，我还在代码块中给大家留下了一个问题，那就是有没有什么操作可以补充在 close() 方法中。如果大家没有想到的话，那么我就说一下我自己的想法： 实际上，我们完全可以在 LocalSnapshotStorage 类的 close() 方法中执行删除旧快照文件的操作 ！原因很简单，LocalSnapshotStorage 类的 close() 方法会在 FSMCallerImpl 状态机组件生成新的快照文件后被回调，在执行的过程中会把快照文件移动到正式目录中，这个时候既然新的快照文件已经成功生成了，显然就可以把旧的快照文件删除了。这个操作在 close() 方法中执行显然没一点问题。那么在删除旧快照文件的时候，我们该怎么做呢？是直接就删除吗？比如说 raft 集群的领导者本地的 snapshot\_100 文件夹中存储着一份快照文件和快照元信息文件，领导者运行了一会之后，又在 snapshot\_200 文件夹中存储了新的快照文件，那这个时候显然就可以把 snapshot\_100 文件夹删除了。 这个功能实现起来非常简单，只要知道旧快照文件应用的最后一条日志的索引，那我们就可以得到存储旧快照文件的文件夹，然后直接删除该文件夹即可 。说实话，我很想这么做，但我不能真的这么做。  
  
原因很简单，假如领导者本地的 snapshot\_100 文件夹中的快照正在远程安装给集群的某个节点，恰好这个时候新的快照生成了，存储在 snapshot\_200 文件夹中了，难道这个时候就要直接把 snapshot\_100 文件夹给删除了吗？如果真的删除了，那集群中的某个节点还怎么安装领导者的快照啊。所以，为了避免误删除情况的出现，我们可以这么做： 那就是给节点生成的每一个快照应用的最后一条日志索引定义一个引用计数对象。比如说 snapshot\_100 文件夹中的快照正在被安装给其他节点，那就给索引 100 的引用计数自增 1。当然，如果是最新创建的快照文件，那么就需要给快照文件应用的最后一条日志索引的引用计数自动加 1。如果是旧的要被删除的快照文件，那就要给快照文件应用的最后一条日志索引的引用计数减 1，如果某个快照文件应用的最后一条日志索引的引用计数减为 0 了，那就意味着这个快照文件可以删除了 。光用文字描述显然太抽象了，接下来我就为大家展示一下我重构完毕之后的 LocalSnapshotStorage 类，大家可以结合我们刚才的分析，仔细阅读阅读 LocalSnapshotStorage 类的 init() 方法和重构之后的 close() 方法，请看下面代码块。  
到此为止，我就把 LocalSnapshotStorage 类重构完毕了。上面代码块中的注释非常详细，所以我就不再重复讲解了。总之，现在我们已经知道， FSMCallerImpl 状态机组件成功生成完快照之后，会回调 SaveSnapshotClosure 对象中的方法，而在 SaveSnapshotClosure 对象的方法中，会执行 LocalSnapshotStorage 快照存储器的 close() 方法，该方法一旦执行，就会把新生成的快照从临时文件夹中移动到正式文件夹中，并且还会视情况删除旧的快照文件 。这个逻辑大家应该都能梳理清楚了吧？  
  
但现在的问题是，怎么在 SaveSnapshotClosure 对象的回调方法中调用 LocalSnapshotStorage 快照存储器的 close() 方法呢？ 现在我们不知道 SaveSnapshotClosure 回调对象怎么创建，也不知道该对象怎么交给 FSMCallerImpl 状态机组件使用；我们也不知道 LocalSnapshotStorage 快照存储器具体在哪里创建，怎么被初始化，也不知道 LocalSnapshotStorage 快照存储器的 close() 方法怎么在 SaveSnapshotClosure 对象的回调方法中调用；当然， 我们也更不清楚怎么把 LocalSnapshotStorage 快照存储器中的存储快照文件的临时文件夹路径交给 FSMCallerImpl 状态机组件使用 ， 我们都知道快照文件是被 FSMCallerImpl 状态机组件生成的，但是生成的时候要先把快照文件存储在临时文件夹中，而临时文件夹的路径被 LocalSnapshotStorage 快照存储器持有，所以必须让 LocalSnapshotStorage 快照存储器把临时文件夹的路径交给 FSMCallerImpl 状态机组件使用，我们之前实现的一切功能才能正常发挥作用 。但现在我们连这一点都无法做到。那这个功能究竟该怎么实现呢？怎么才能让 FSMCallerImpl 状态机组件获得 LocalSnapshotStorage 快照存储器中的临时文件夹路径呢？这个功能就放到下一章实现吧。本章的内容已经够多了，我建议大家结合第八版本代码的相关代码来阅读本章内容，大家可以直接去我提供的第八版本代码中查看文章中展示的各个类，虽然现在第八版本代码还有一些功能我没在文章中实现和展示，但大家只要掌握了本章和前两章的内容，那么看懂第八版本代码应该不成问题，剩下的内容非常少了，下一章应该就能完全实现 jraft 框架生成快照的功能。好了朋友们，我们下一章见！  
若有收获，就点个赞吧

---
*Source: https://www.yuque.com/u26328320/kxtdy3/bgywlvq73lrnrzih*  
*All content belongs to its respective owners and creators.*