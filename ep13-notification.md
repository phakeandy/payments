# EP13 讲义：通知服务 —— 至少一次投递，一次效果

- **视频** `9:43:03 – 10:31:14`（48 分）｜分支 `ep13` ｜ diff：`+1159 / -2`（21 个文件）
- **转录** `media/ep13.txt`（183 句，5,728 词）
- 时间戳是视频绝对时间

一句话：**投递是"至少一次"，所以处理必须"两次无害"。**

> 这是全课程第一次出现**"别人家的消息"**：前 12 集所有代码都在钱的那条线上，这一集第一次有一条**完全在钱之外**的线，而且**它挂了钱也照走**。
>
> 也是第一次：**一个新服务上线，上游两个服务一行代码都没改。**

```
git diff --stat upstream/ep12 upstream/ep13 | tail -3
 21 files changed, 1159 insertions(+), 2 deletions(-)
```

💡 注意那个 `-2`：整个 EP13 只删了 2 行（`docker-compose.yml` 和 `Makefile` 里的旧行）。**这是一个纯增量的集**——因为它建的是一个新服务，而不是改一个旧服务。

---

## 0. 为什么通知要有自己的服务

> `[9:44:19]` Who should send the email? **the transfer service could, as one more step of the saga**, but then **the money path waits for a mail server**, when the mail server is down, **transfers stall, or even fail over an email**, email retries get tangled with **the saga's own**, and **email scales with transfers, whether it needs to or not**.

> **译文**：邮件该由谁发？**transfer 服务可以，作为 saga 的又一步**，但那样**钱的路径就要等一台邮件服务器**；邮件服务器挂了，**转账会卡住，甚至因为一封邮件而失败**；邮件的重试会和**saga 自己的重试**缠在一起；而且**邮件会随转账一起扩缩容，不管它需不需要**。

💡 这是四个独立的坏理由，一个一个看：

| 问题 | 后果 |
|---|---|
| 钱等邮件 | 邮件服务器的可用性变成**转账的可用性** |
| 重试缠在一起 | saga 的重试策略和邮件的重试策略**抢同一个预算** |
| 一起扩缩容 | 转账的峰值（10 倍）变成邮件的峰值，但邮件不需要 10 倍 |
| **saga 多一步** | 每多一步，saga 的状态机**多一个能卡住的点** |

第四条最容易被忽略：**saga 是"步骤越多越脆弱"的东西**。EP12 里它已经有 hold / capture / release 三步了。加第四步"发邮件"，等于给每一笔转账加一个**能永久卡住它的外部依赖**。

> `[9:44:43]` a service that **listens to events flips all of that**: the transfer service **publishes, and forgets about it**. If notifications are down for an hour, **transfers don't even notice**, the events **wait in the stream until it's back**, and **a new kind of notification changes one service, nobody else** — that's **choreography**, as promised last time.

> **译文**：一个**监听事件的服务把这一切都翻过来了**：transfer 服务**发布，然后忘掉它**。如果通知服务挂了一个小时，**转账根本不会注意到**，事件**在流里等着它回来**，而**一种新的通知只改一个服务，别人都不用动**——这就是**协同（choreography）**，上次承诺过的。

💡 EP12 那一集讲编排 vs 协同时说"我们用编排（orchestrator）"。这里出现了**混合**：

- **钱的那条线**（hold/capture）→ **编排**，因为顺序必须被一个东西拥有
- **通知这条线** → **协同**，因为它是**旁路**，谁也不需要等它

**同一个系统里两种模式并存，按"是否在关键路径上"来选。** 这比"选一个"更接近真实工程。

---

## 1. 拓扑：每一个箭头都背离钱

> `[9:45:06]` Here's where it sits, the transfer service and the wallet **publish through their outboxes**, onto the transfer and wallet streams, **exactly as before, nothing changes on their side today**.

> **译文**：它在这里：transfer 服务和 wallet **通过它们各自的 outbox 发布**，到 transfer 流和 wallet 流上，**和以前完全一样——它们那一侧今天什么都没改**。

> `[9:45:21]` the notification service **reads both, through a durable consumer on each**. For every event, **it asks auth for the user's email address, because events carry user IDs, not addresses**. It sends through **SMTP**, which in development is **Mailpit**, a mail catcher with a web inbox, and **it gets its own database, called notification**, with **two tables**: what we've sent, and **what we gave up on**.

> **译文**：通知服务**两个流都读，每个流上一个持久消费者**。对每个事件，**它去问 auth 服务要用户的邮箱地址，因为事件里带的是 user ID，不是地址**。它通过 **SMTP** 发信，开发环境里那是 **Mailpit**——一个带网页收件箱的邮件捕获器——而**它拿到自己的数据库，叫 notification**，里面**两张表**：我们发出去的，和**我们放弃的**。

> `[9:45:51]` And **notice the arrows, every one of them points away from the money**. **If notifications are down, nothing upstream changes.**

> **译文**：而且**看这些箭头——每一个都背离钱的方向**。**如果通知挂了，上游什么都不变。**

```
                    ┌──────────────┐
   wallet  ──outbox─┤ wallet.stream│──┐
                    └──────────────┘  │   durable consumer ×2
                    ┌──────────────┐  ├──►  notification  ──SMTP──► Mailpit
 transfer ──outbox─►│transfer.stream│─┘         │
                    └──────────────┘            │ 一问一答（HTTP）
                                                ▼
                                          auth /internal/users/{id}
```

💡 图中有一条**反向箭头**（notification → auth）。这是本集唯一一个**同步调用**，值得记住：

- **事件里不带邮箱**（理由见 §10）
- 所以每封邮件要**多一次 HTTP 往返**
- 这一次往返**可能失败**，而它失败的性质决定邮件是重试还是死信

**"事件驱动"不等于"零同步调用"。** 它等于"**关键路径上没有同步调用**"。

---

## 2. 第一个决定：push 还是 pull

> `[9:46:08]` and **the first choice is push or pull**. A **push** consumer has the server **push messages to a subject**, at the server's pace. A **pull** consumer lets the worker **ask for a batch whenever it's ready**.

> **译文**：而**第一个选择是 push 还是 pull**。**push** 消费者让服务器**按它自己的节奏把消息推到某个 subject**。**pull** 消费者让 worker **在它准备好的时候来要一批**。

> `[9:46:27]` so with push, **a slow worker needs flow control, or messages pile up in its memory**. With pull, **a slow worker simply asks less often — back pressure built in**.

> **译文**：所以用 push，**一个慢的 worker 需要流控，否则消息在它的内存里堆起来**。用 pull，**慢的 worker 就少要几次——背压是内建的**。

> `[9:46:42]` to scale out, start more instances, **they share one durable consumer, and each message goes to one of them**. **Push suits low latency fan-out, pull suits work**.

> **译文**：要扩容就多起几个实例，**它们共享一个持久消费者，每条消息只去其中一个**。**push 适合低延迟的扇出，pull 适合干活**。

> `[9:46:57]` **ours is a worker, so we pull.**

> **译文**：**我们这个是 worker，所以我们用 pull。**

💡 这段话的分量在于它给了一个**判定标准**，而不是一个偏好：

| | push | pull |
|---|---|---|
| 谁定节奏 | 服务器 | 消费者 |
| 慢消费者的后果 | 内存里堆积 → **需要流控** | 少要几次 → **天然背压** |
| 适合 | 低延迟扇出（推给很多订阅者） | 干活（每个消息要几秒 IO） |

发邮件是**典型的"干活"**：一封 SMTP 可能几百毫秒，`MaxAckPending` 是 100。**如果用 push，NATS 会以它的速度灌进来，我们得自己写一个队列挡住它。** 那正是"背压"这个词要避免的事。

---

## 3. 投递的规则：把服务器当成"待办清单"

> `[9:47:12]` Now **the rules of delivery**: the server delivers a message to us, and **waits for our answer**. **Ack** means done, the consumer moves on to the next one. **Nak with a delay** means **not now, deliver it again later**. **No answer at all within the AckWait** — because we crashed, or we're slow — and **the server delivers it again**. **Redelivery isn't a rare accident, it's the design.**

> **译文**：现在说**投递的规则**：服务器把消息投给我们，然后**等我们的回答**。**Ack** 表示做完了，消费者走下一个。**带延迟的 Nak** 表示**现在不行，晚点再投一次**。**在 AckWait 之内完全没有回答**——因为我们崩了，或者我们太慢——**服务器就再投一次**。**重投不是罕见的意外，它就是设计。**

> `[9:47:43]` **Term** means **never again, this message is hopeless**. **Think of it as the server keeping a to-do list for us, and only crossing an item off when we say so.**

> **译文**：**Term** 表示**永远别再投，这条消息没救了**。**把它想成服务器替我们保管一份待办清单，只有我们说了它才划掉一项。**

> `[9:47:57]` And **MaxDeliver caps the attempts**; after that many deliveries **the server stops trying**. That's **at-least-once delivery**. The server **can't know whether we did the work before we went quiet, so it always errs on the side of delivering again** — which means **any message can arrive twice**, and **a consumer that sends emails has to be idempotent**.

> **译文**：而 **MaxDeliver 给尝试次数封顶**；投了那么多次之后**服务器就不再试了**。这就是**至少一次投递**。服务器**无法知道我们沉默之前有没有把活干完，所以它永远偏向"再投一次"**——这意味着**任何消息都可能到达两次**，而**一个发邮件的消费者必须幂等**。

💡 这段话里有一个词被 whisper 听成了 "airs"，原文是 **"errs on the side of"**（偏向……）。这是**整个分布式消息系统的核心妥协**，用一句话说清了：

> **沉默无法区分"没收到"和"收到了但没来得及回答"。**

所以系统只能二选一：

| 选择 | 后果 |
|---|---|
| 偏向"没发生"，重投 | **至少一次**（可能重复）→ 需要幂等 |
| 偏向"发生了"，不重投 | **至多一次**（可能丢失）→ 钱不能这样 |

**发钱不能丢，所以只能重复。** 这就是整集存在的原因。

四个回答，一张表（下面 §12 会看到它们全部出现在一个 `switch` 里）：

| 回答 | 意思 | 谁决定 |
|---|---|---|
| `Ack` | 干完了 | 我们 |
| `Nak` / `NakWithDelay(d)` | 现在不行，`d` 之后再投 | 我们 |
| `Term` | 永远别再投 | 我们 |
| **沉默** | 崩了 / 太慢 → 到 AckWait 后重投 | **服务器** |

💡 第四行是最重要的：**"不回答"也是一种回答**，而且是服务器替你做的决定。

---

## 4. 开发环境先要有"一个收信的地方"

> `[9:48:59]` in development **we don't want real email, we want a mail catcher**. **Mailpit** is a tiny SMTP server that **accepts everything, delivers nothing, and shows it all in a web inbox**.

> **译文**：开发环境里**我们不要真邮件，我们要一个邮件捕获器**。**Mailpit** 是一个极小的 SMTP 服务器，**什么都收、什么都不投递，然后在一个网页收件箱里把它们全展示出来**。

> `[9:49:16]` in docker compose a Mailpit service with a **pinned version**, SMTP on **port 1025**. **At a real email provider, one bug in a loop, and you've emailed your real customers a thousand times.**

> **译文**：docker compose 里一个 Mailpit 服务，**版本钉死**，SMTP 在 **1025** 端口。**对着一个真实的邮件服务商，一个循环里的 bug，你可能就给真实客户发了一千封邮件。**

💡 这一句是**用工具做安全护栏**，不是"图方便"：

- 删掉测试数据库 → 重新 migrate，代价 5 秒
- 给真实客户发 1000 封邮件 → **没法撤销**

**所以"邮件"这种东西必须在开发环境里被物理隔断**，而不是靠"小心一点"。和 EP01 那条"钉版本号"是同一个思路：**把不可逆的事变成不可能，而不是变成需要记住。**

---

## 5. 一个自己的数据库，以及那个"初始化脚本的坑"

> `[9:49:33]` the notification service needs a database for idempotency and dead letters, so the init script gets a fourth line — **but that script only runs when the Postgres volume is first created, and ours exists already**, so on this machine **we create it by hand**.

> **译文**：通知服务需要一个数据库来放幂等和死信，所以初始化脚本加了第四行——**但那脚本只在 Postgres 的 volume 第一次创建时运行，而我们的已经存在了**，所以在这台机器上**我们手工建它**。

💡 这是**Postgres 官方镜像的经典坑**：`/docker-entrypoint-initdb.d/*.sql` 只在**数据目录为空**时执行。`docker compose down`（不带 `-v`）之后数据还在，脚本**不会重跑**。

> EP01 里那句"`down -v` 是本课程唯一诚实的重置方式"在这里收账了。

> `[9:49:49]` and yes, **a database of its own: each service owns its data**. So **notifications don't get a table in the transfer database, however convenient that would be**.

> **译文**：是的，**它自己的数据库：每个服务拥有自己的数据**。所以**通知不会在 transfer 的数据库里放一张表，不管那有多方便**。

💡 这条规则到这一集才真正**有代价**：如果通知表放在 transfer 库里，就**不需要新建数据库、不需要新 sqlc block、不需要新 migrate 目录**。省下的工作量是真实的——但换来的是：

| 放 transfer 库里 | 放自己的库 |
|---|---|
| 一个事务能同时改两个服务的表 | 两个服务的事务**完全隔离** |
| transfer 库的 schema 变成一个**多方共管**的东西 | 谁改谁知道 |
| 备份/迁移/清理由 transfer 负责 | 各自负责 |

**"方便"和"所有权清晰"在这里是一对真正的取舍**，而 EP13 选了后者，因为这是本节要演示的模式。

---

## 6. 幂等表：为什么不是 Redis 的 `SET seen`

> `[9:50:19]` the first table, `notifications`, **one row per event we told someone about**. **The event's id is the primary key, and that's the whole trick of an idempotent consumer**: an event that arrives twice **finds its own row**.

> **译文**：第一张表 `notifications`，**每个我们通知过的事件一行**。**事件的 id 就是主键，而这正是幂等消费者的全部诀窍**：一个到达两次的事件**会找到它自己那一行**。

```sql
CREATE TABLE notifications (
    event_id   uuid        PRIMARY KEY,      -- ← 全部诀窍在这一个词
    user_id    uuid        NOT NULL,
    recipient  text        NOT NULL,
    subject    text        NOT NULL,
    sent_at    timestamptz NOT NULL DEFAULT now()
);
```

> `[9:50:50]` **why a table, and not a set of seen IDs in Redis, with a TTL?** because **the record, its lock and the send have to share one transaction, and Redis can't give us that**.

> **译文**：**为什么用一张表，而不是 Redis 里一个带 TTL 的"见过的 ID"集合？** 因为**那条记录、它的锁、以及这一次发送，必须共享同一个事务，而 Redis 给不了我们这个**。

💡 这是本集**最值得抄下来的一句**。它把"用什么存储"变成了一个**事务边界**问题，而不是性能问题：

| 方案 | 插入记录 | 发送邮件 | 在同一个事务里？ |
|---|---|---|---|
| Redis `SET NX` | Redis | SMTP | ❌ |
| Postgres 表 | Postgres | **在 tx 里调用** | ✅ |

而"在同一个事务里"能带来什么，下一节就是答案。

> `[9:51:06]` and **the table doubles as a record of what we told whom**.

> **译文**：而且**这张表顺便成了"我们告诉了谁什么"的记录**。

💡 幂等表有一个很好的性质：**它不是纯技术开销**。它同时是产品要的功能（"我上周收到的那封邮件说了什么？"）和支持排查的依据。**最好的技术机制往往顺便解决了业务需求**——这是判断一个设计好不好的实用标准。

还有第二张表，死信：

```sql
CREATE TABLE dead_letters (
    stream      text        NOT NULL,
    seq         bigint      NOT NULL,   -- 流 + 序号 = 一条消息的身份
    subject     text        NOT NULL,
    payload     bytea       NOT NULL,   -- 原样存下：它可能连解码都做不到
    error       text        NOT NULL,
    deliveries  integer     NOT NULL,
    failed_at   timestamptz NOT NULL DEFAULT now(),
    replayed_at timestamptz,
    PRIMARY KEY (stream, seq)
);
```

> `[9:51:06]` ...a **stream and a sequence number identify a message, even one that never decoded**. The error, **how many deliveries it got**, when it failed, and **when it was replayed, if it was**.

> **译文**：……**流 + 序号标识一条消息，即便是一条从来没被解码的消息**。错误信息、**它被投递了几次**、它什么时候失败的，以及**它什么时候被重放过——如果重放过的话**。

💡 三个细节值得注意：

1. **主键是 `(stream, seq)` 而不是消息自己的 id** ——因为**坏消息可能连 id 都没有**（§17 的 poison message 演示正是这个）。
2. **`payload bytea` 存原样** ——死信的价值在于"能重放"，重放需要字节，不是解析后的结构。
3. **`error` 存文本而不是错误码** ——凌晨 3 点看的人需要读得懂。

第三点的取舍值得说清：存文本**没法做聚合统计**（"错误率按类型"），但**死信的量级是"人工处理"级别的**，不是"仪表盘"级别的。**用错了量级才会觉得这是缺陷。**

---

## 7. 全集的核心：`Deliver` —— 插入和发送在同一个事务里

> `[9:58:02]` now **the most important decision of the episode**: how do we send each email once? For each message: **begin a database transaction, insert the event's id — which does nothing if it's already there — send the email, commit, and Ack**.

> **译文**：现在说**本集最重要的决定**：我们怎么让每封邮件只发一次？对每条消息：**开一个数据库事务，插入事件的 id——如果它已经在那儿就什么都不做——发邮件，提交，然后 Ack。**

```go
func (s *Store) Deliver(ctx context.Context, m Message, send func() error) (bool, error) {
	sent := false
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		n, err := s.q.WithTx(tx).InsertNotification(ctx, ...)
		if err != nil || n == 0 {
			return err            // 0 行 = 以前处理过 = 什么都不发
		}
		// Until we commit, the new row is locked: the same event, delivered
		// twice at once, waits here, and then finds it.
		sent = true
		return send()
	})
	...
}
```

> `[9:59:55]` ...call send **inside the transaction**. If it fails, **its error rolls the insert back**. And **notice the comment: until we commit, the new row is locked** — **which is what makes two deliveries at once safe**.

> **译文**：……**在事务里**调用 send。如果它失败，**它的错误会让插入回滚**。而且**注意那条注释：在我们提交之前，新行是被锁住的**——**这正是"同时两次投递"安全的原因**。

💡 这里有一个很多人第一反应会担心的点：**"在数据库事务里做网络 IO？那不是大忌吗？"**

对，**通常是大忌**——事务持有连接和锁，网络 IO 可能几百毫秒。但这里它是**故意**的，因为**它在换取唯一性**：

| 如果你在事务外发邮件 | 后果 |
|---|---|
| 插入 → 提交 → 发邮件 | 崩溃在中间 = 记录说"发过了"，实际没发 → **邮件永久丢失** |
| 发邮件 → 插入 | 崩溃在中间 = 发了但没记录 → **重投时再发一次** |

**在事务里发**，把"记录"和"动作"绑成一个原子单元。而代价（事务变长、锁被持有）**在这个场景里是可以接受的**，因为：

- 表很小，插入是本地操作
- SMTP 到 Mailpit 是毫秒级
- `MaxAckPending` 是 100，不会同时开几百个事务

💡 而那句 "until we commit, the new row is locked" 是**免费得到的第二个性质**：两个实例**同时**收到同一个事件时，第二个的 `ON CONFLICT` 会**等第一个提交**，然后发现冲突，返回 0 行，跳过。**不需要分布式锁，Postgres 的主键唯一索引就是锁。**

> 这也是 EP07 幂等键 `ON CONFLICT DO NOTHING` 那个注释的同一句话。**同一个技巧第二次出现，说明它是模式而不是巧合。**

### 三个崩溃窗口，一个一个数

> `[9:58:18]` now **crash anywhere**. **Before the commit**, say the send failed — **the insert rolls back, and the retry sends it. Good.** **After the commit, but before the Ack** — the server delivers it again, **the insert finds the row, and we skip it**. That's the one we'll prove live.

> **译文**：现在**在任何地方崩溃**。**提交之前**——比如发送失败了——**插入回滚，重试会把它发出去。很好。** **提交之后、Ack 之前**——服务器再投一次，**插入发现那一行已经存在，我们跳过它**。这个我们等一下现场证明。

> `[9:58:52]` And **the honest one**: we die **after the mail server accepted the email, before our commit**. Then **it goes out twice**. **No database can close that window**, because **the email isn't in our database**. **It's milliseconds wide**, and **the Message-ID helps the mail system drop the copy**.

> **译文**：还有**诚实的那一个**：我们在**邮件服务器已经收下这封信之后、我们提交之前**死掉。那么**它会发出去两次**。**没有任何数据库能关上这个窗口**，因为**邮件不在我们的数据库里**。**它只有几毫秒宽**，而且 **Message-ID 能帮邮件系统把副本丢掉**。

💡 这一段是**整集最诚实的地方**，也是我最想让你记住的地方。三个窗口：

```
     插入记录                提交              Ack
────────●──────────────────────●────────────────●────────►
         │                      │                │
   窗口① 崩在这          窗口② 崩在这      窗口③ 崩在这
   → 回滚，重试           → 重投，跳过      → 重投，跳过
     完全安全               完全安全            完全安全

                        ↑
              窗口④：邮件已经被 Mailpit 收下，但我们还没提交
              → 真的会发两次。只能靠 Message-ID 让下游去重。
```

**关键认知**：第④个窗口**不是 bug，是物理事实**。它是"一个外部系统 + 一个本地数据库"必然的缝。所以正确的说法不是"我们做到了恰好一次"，而是：

> **至少一次投递 + 一份"我做过什么"的记录 = 效果上的一次。**

而"效果上的一次"在**对方也能去重**的时候才成立（这里靠 `Message-ID`）。**如果下游无法去重，那就真的会重复**——这是系统设计的边界，不是实现质量问题。

💡 作者特意用了 "**the honest one**"（诚实的那个）。**一个愿意说"这里我们做不到"的讲解，比一个声称完美的讲解可信得多。** 你在读代码时该找的正是这种注释。

---

## 8. `PermanentError`：一条错误分类，决定它还值不值得试

```go
// A PermanentError won't go away if we try again, like an event that doesn't
// decode, or a user who doesn't exist. Any other error might.
type PermanentError struct{ Err error }

func (e *PermanentError) Error() string { return e.Err.Error() }
func (e *PermanentError) Unwrap() error { return e.Err }

func Permanent(err error) error { return &PermanentError{Err: err} }
```

> `[9:52:25]` and **the distinction the whole retry design rests on**: **a permanent error, one that won't go away if we try again** — like an event that doesn't decode, or a user who doesn't exist. **Permanent wraps an error that way. Everything else might work next time.**

> **译文**：还有**整个重试设计所依赖的那个区分**：**永久错误——再试一次也不会消失的那种**——比如一个解不开的事件，或者一个不存在的用户。**Permanent 用那种方式包装一个错误。其他一切下次都可能成功。**

💡 为什么**不用现有的 `apperr` 分类**（EP04 那套 `Invalid`/`NotFound`/`Internal`）？

因为它们回答的是**另一个问题**：`Invalid` 说的是"**客户端的请求**有问题"，`Permanent` 说的是"**这条消息**没救了"。两个维度正交：

| | 是客户端的问题吗 | 重试有用吗 |
|---|---|---|
| 事件解不开 | 不是（是发布者的 bug） | ❌ |
| 用户不存在 | 不是 | ❌ |
| 邮件服务器挂了 | 不是 | ✅ |
| 400 reply | 不是 | ✅（SMTP 里 4xx **字面意思就是"稍后再试"**） |

**错误分类是分层的能力**：`apperr` 属于 HTTP 层（决定状态码），`PermanentError` 属于**投递层**（决定重试）。它们不可能用同一套。

> `[10:03:09]` **and a rule of thumb: when in doubt, call it transient. A retry costs a little; a lost email costs trust.**

> **译文**：**一条经验法则：拿不准的时候，当成瞬时错误。一次重试只花一点点，一封丢掉的邮件花掉的是信任。**

💡 这和 EP05 那句 "`%v` 而不是 `%w`" 是同一个思想的两面：

- EP05：**分错了会把我们自己的 bug 变成客户的 404**
- EP13：**分错了会让一封该重试的邮件变成死信**

两边都选了**"偏向更保守的那一侧"**，而"保守"的方向**不同**：EP05 偏"别怪客户"，EP13 偏"别放弃"。**因为风险的性质不同：一个是误伤，一个是漏救。**

---

## 9. `compose`：一条事件到一封信

```go
switch evt.Type {
case transferevents.Completed, transferevents.Failed:
	m.UserID = t.UserID                                    // 发钱的人
	if evt.Type == transferevents.Completed {
		m.Subject = "You sent " + money(t.Amount, t.Currency)
	} else {
		m.Subject = "Your transfer of " + money(...) + " didn't go through"
		m.Body = "Reason: " + t.FailureReason + ". Nothing left your wallet."
	}
case walletevents.TransferCompleted:
	m.UserID = t.To.OwnerID                                // 收钱的人
	m.Subject = "You received " + money(t.Amount, t.To.Currency)
default:
	return m, false, nil                                   // 不是我们的事，不是错误
}
```

> `[9:53:12]` completed: **you sent $15**. Failed: **it didn't go through, with the reason, and the reassurance people actually want — "nothing left your wallet"**. That's true of failed and reversed transfers alike.

> **译文**：完成：**你发出了 $15**。失败：**它没成功，加上原因，以及人们真正想要的那句安慰——「你的钱没有离开钱包」**。这句话对失败的转账和被反向的转账都成立。

💡 "nothing left your wallet" 是一个**产品级别的句子**，不是技术文案。它回答的是用户真正的恐惧：**"我的钱是不是卡在中间了？"**

而它成立的**技术前提**是 EP12 的 hold 设计：hold 是**冻结**，不是扣除。所以失败时 release 一下，钱**从未离开**。**一句安慰话的可信度，取决于架构是不是真的这么做的。**

> `[9:53:42]` from the wallet stream, a completed transfer tells us **who received money**: the owner of the receiving wallet, **which wallet events carry since episode 11**. That's Bob's email. **Any other event isn't ours to tell anyone about, so compose says no — and that isn't an error.**

> **译文**：从 wallet 流来的、一笔完成的转账告诉我们**谁收到了钱**：收款钱包的主人，**wallet 事件从第 11 集起就带这个**。那就是 Bob 的邮箱。**其他任何事件都不是我们该去告诉别人的，所以 compose 说不——而那不是一个错误。**

💡 `return m, false, nil` 这个签名值得单独说：**三个返回值，其中 `ok=false` 和 `err=nil` 是两个不同的东西**。

| 返回 | 意思 | 后果 |
|---|---|---|
| `ok=true, err=nil` | 这是一封我们该发的信 | 发 |
| `ok=false, err=nil` | **不是我们的事** | **Ack**，不发，不算失败 |
| `ok=false, err!=nil` | 是我们的信但写不出来 | 按永久错误处理 |

如果 `ok=false` 用 error 表示，**每一条与我们无关的事件都会变成死信**。这是"**沉默不是错误**"的又一个实例（和 EP04 里 `404` 不应该产生 `ERROR` 级别日志同一道理）。

> `[10:11:28]` ...one durable consumer on each stream will listen to **every transfer event from transfer, and only the completed transfers from wallet**.

> **译文**：……每个流上一个持久消费者，**transfer 流上听每一个转账事件，wallet 流上只听完成的转账**。

💡 **过滤是在服务端做的**（`FilterSubjects`），不是在代码里 `if` 掉的。区别很大：

- 服务端过滤：消息**不投递**，不占 `MaxAckPending`，不消耗你的 CPU
- 代码里 if：消息**投递了**，一行代码 Ack 掉

对一个每分钟几千事件的流，这个差别就是**你的消费者能不能跟上**。

---

## 10. `money()`：给人类看的钱

```go
func money(amount int64, currency string) string {
	if currency == "JPY" {
		return fmt.Sprintf("%d JPY", amount)      // 日元没有小数位
	}
	return fmt.Sprintf("%d.%02d %s", amount/100, amount%100, currency)
}
```

> `[9:53:56]` and **money formats minor units for people: 1500 cents is 15.00. JPY has no minor units** — **a real currency table arrives with exchange rates, in episode 18**.

> **译文**：而 **money 把最小单位格式化给人看：1500 分是 15.00。日元没有最小单位**——**一张真实的货币表会在第 18 集随汇率一起到来。**

💡 这里同时有**正确**和**已知不足**，而且作者主动说了：

```go
if currency == "JPY" { ... }     // ← 硬编码了一个特例
```

正确的做法是查 ISO 4217 的 exponent（EP18 会做，`internal/fx` 里的 `exponents` 表）。但现在**只有一个特例，一行 if 就够了**。

> 这是"**先一行 if，等第二个特例出现再建表**"的实例。和 EP01 那句 "measure before you get clever" 一致：**不要在没有第二个例子的地方建抽象。**

而 `money()` 用 `%d.%02d` 而不是浮点除法，也是一个细节：`amount/100` 和 `amount%100` **全整数运算**，没有浮点误差。**钱从头到尾没有变成 `float64` 过一次。**

---

## 11. `sender.go`：`net/smtp` 不认识 context

> `[9:54:45]` **the conversation itself — with Go's `net/smtp`, its `SendMail` helper knows nothing about context**, and **a mail server that hangs would hang us with it**. So **we dial with the context ourselves, and give the connection the context's deadline**.

> **译文**：**对话本身——用 Go 的 `net/smtp` 时，它的 `SendMail` helper 完全不懂 context**，而**一台卡住的邮件服务器会把我们一起卡住**。所以**我们自己用 context 拨号，并把 context 的截止时间交给这条连接**。

```go
conn, err := d.DialContext(ctx, "tcp", s.Addr)      // ← 用 context 拨号
if deadline, ok := ctx.Deadline(); ok {
	conn.SetDeadline(deadline)                      // ← 把 deadline 交给 socket
}
```

💡 这是一个**标准库不支持 context 时的通用补丁**。三步：

1. `Dialer.DialContext` 管**连接**阶段
2. `conn.SetDeadline` 管**读写**阶段（`net/smtp` 的每一步读写都受它约束）
3. 上层 context 一旦过期，**socket 的读写立刻返回错误**

**为什么不能只做第 1 步**：`DialContext` 只管到"连上"为止。连上之后 `smtp.Client` 的 `Mail`/`Rcpt`/`Data` 全是裸的 `conn.Read/Write`，**一个不回话的服务器能让它们永远等下去**。

> `[9:55:15]` notice that **the errors from Mail and Rcpt aren't wrapped** — **those are the server's replies, the `textproto.Error`s that `Send` looks for**. **`net/smtp` is frozen**, and **it's fine for a mail catcher**.

> **译文**：注意 **`Mail` 和 `Rcpt` 的错误没有被包装**——**它们就是服务器的回复，正是 `Send` 要找的那些 `textproto.Error`**。**`net/smtp` 已经冻结了**，而**对一个邮件捕获器来说够用**。

```go
err := s.send(ctx, m)
var reply *textproto.Error
if errors.As(err, &reply) && reply.Code >= 500 {
	return Permanent(err)                    // 5xx = 永久
}
return err                                   // 其他都可能下次成功
```

💡 这里有个**必须不包装**的理由，和 EP05 那条"包装是一个 API 决定"是同一条规则的**反面用法**：

- EP05：`%v` **故意切断**链，让 500 不变成 404
- EP13：**故意不包**，因为 `errors.As` 需要**穿透**到 `*textproto.Error`

**如果用 `fmt.Errorf("smtp mail: %w", err)` 包一层会怎样？** 其实 `%w` 也会让 `errors.As` 穿透，**所以包了也能工作**。真正必须不包的是 **`%v`**。作者这里的不包装更多是"少一层没用的前缀"。

> 顺带一个知识点：**SMTP 的状态码分两类**——`4xx` 字面意思是"**现在不行，稍后再试**"，`5xx` 是"**永久失败**"。**SMTP 协议自己就有 transient/permanent 的概念**，而 `PermanentError` 只是把它翻译成 Go 的类型。**这不是我们发明的分类，是抄协议。**

### `Message-ID`：给下游一个去重的抓手

```go
fmt.Fprintf(&b, "Message-ID: <%s@payments.example>\r\n", m.EventID)
```

> `[9:55:48]` ...**a Message-ID built from the event's ID, which matters later: a mail system that sees the same message ID twice can drop the copy**.

> **译文**：……一个**用事件 ID 拼出来的 Message-ID，这个后面很重要：一个邮件系统如果两次看到同一个 Message-ID，它可以丢掉副本**。

💡 这是**窗口④**的补救措施。它不完美（Mailpit 不会去重，真实邮件客户端也不一定），但它是**我们能给下游的全部帮助**：

> **我们无法做到恰好一次，但我们可以把"这是同一条消息"的**证据**交给下游。**

再加上一句：

```go
fmt.Fprintf(&b, "From: Payments <%s>\r\nTo: %s\r\nSubject: %s\r\n", ...)
fmt.Fprintf(&b, "Date: %s\r\n", time.Now().Format(time.RFC1123Z))
fmt.Fprintf(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", m.Body)
```

> `[9:56:06]` **every header line ends in a carriage return and a line feed, as SMTP requires, and a blank line separates the headers from the body**.

> **译文**：**每一行 header 以回车+换行结尾，这是 SMTP 要求的，而一个空行把 header 和 body 分开**。

💡 两个常见的坑都在这里：

- **`\r\n` 而不是 `\n`**：SMTP 规范（RFC 5321）要求 CRLF。用 `\n` 时有些服务器会吞掉行，或者把 header 拼在一起。
- **空行分隔**：header 和 body 之间**必须有恰好一个空行**（`\r\n\r\n`）。没有它，body 会被当成最后一个 header。

**这两条都是"协议级细节"，抄对了就行，不要试图理解为什么。**（历史原因：电传打字机的回车和换行是两个字符。）

---

## 12. 为什么不把邮箱放进事件里

> `[9:56:06]` **events carry user IDs, never email addresses — and that's on purpose. An address can change, and events stay in the stream for a month.**

> **译文**：**事件里带的是 user ID，从来不是邮箱地址——这是有意的。地址会变，而事件会在流里留一个月。**

💡 两个理由，第二个更硬：

| 理由 | 说明 |
|---|---|
| 地址会变 | 用户改了邮箱，**已经写进流里的旧事件**仍然带着旧地址 |
| 事件保留 30 天 | 所以"旧地址"不是存在几毫秒，是**存在一个月** |

**这是"事件里放什么"的通用规则：放**不可变的标识**，不放**会变的属性**。**

- ✅ `user_id`（不变）
- ✅ `amount` + `currency`（事件发生时的快照，**必须**是快照）
- ❌ `email`（会变，且 30 天后可能是错的）

💡 注意这里有个微妙之处：`amount` 是**快照**，而 `email` **不是**。区别在哪？

> **`amount` 是"这件事发生时的事实"，`email` 是"这个人现在的联系方式"。**
>
> 前者**必须**冻结在事件里（否则你没法解释历史）；后者**必须**在消费时查（否则你会给旧地址发信）。

**同一份事件里，有些字段该冻结，有些该查。** 判断标准是"这个值的含义是**过去**还是**现在**"。

> `[9:56:54]` one **HTTP call per email is fine at our scale**; **a bigger system would cache addresses for a few minutes, or keep a copy of its own, fed by events from auth**.

> **译文**：**我们这个量级，每封邮件一次 HTTP 调用没问题**；**更大的系统会缓存地址几分钟，或者自己留一份副本，由 auth 的事件喂它**。

💡 注意第二选项：**用事件同步一份用户表**。这是**CQRS 读模型**最基础的形态——但作者说"更大的系统"，意思是**现在不要做**。

> 又是 "measure before you get clever"。**一次 HTTP 调用 5 毫秒，一小时发 100 封信，总共 0.5 秒。** 建读模型的成本远大于收益。

### `/internal` 路由：网络是守卫

> `[9:57:11]` auth needs that route, in its `http.go`: **`GET /internal/users/{id}`**. **The gateway only routes the paths it lists, and `/internal` isn't one of them**, so **users can't reach it — only our services can**. Like the wallet's whole service last time, **the network is the guard for now, and mTLS makes it proper in episode 21**.

> **译文**：auth 需要那条路由，在它的 `http.go` 里：**`GET /internal/users/{id}`**。**网关只转发它列出来的那些路径，而 `/internal` 不在其中**，所以**用户到不了它——只有我们的服务能**。像上次钱包整个服务那样，**暂时用网络当守卫，第 21 集用 mTLS 让它变得正当**。

💡 这是一种**明确标注的技术债**，而且标注得很清楚：

| 现在 | 以后 |
|---|---|
| 网关不转发 `/internal` | mTLS（服务身份） |
| "用户到不了" ≈ **网络拓扑** | **密码学证明** |

风险是：**任何能连到 auth 服务端口的东西都能读任何用户的邮箱**。在 docker compose 里都是 localhost，风险为零；在 Kubernetes 里，**同一集群的任意 pod 都能**。

**作者没有假装这是安全的，他说了 "the network is the guard for now"。** 这种诚实是读代码时最该找的东西。

---

## 13. `consume.go`：六个配置项，每个都有理由

```go
consumer, err := js.CreateOrUpdateConsumer(ctx, stream, jetstream.ConsumerConfig{
	Durable:        "notification",
	Description:    "tells users what happened to their money",
	FilterSubjects: subjects,
	DeliverPolicy:  jetstream.DeliverNewPolicy,   // no emails about last month
	AckPolicy:      jetstream.AckExplicitPolicy,
	AckWait:        ackWait,                       // 30s
	MaxDeliver:     n.MaxAttempts,                 // 5
	MaxAckPending:  100,
})
```

> `[10:04:48]` **Creating the consumer in code at startup means every environment gets the same configuration, reviewed like any other code, instead of a command somebody once ran by hand.**

> **译文**：**在启动时代码里创建消费者，意味着每个环境拿到同一份配置，它像其他代码一样被 review 过，而不是某个人曾经手工跑过的一条命令。**

💡 这是**基础设施即代码**在消费者上的应用。手工 `nats consumer add` 的问题不是"麻烦"，是**漂移**：开发环境 30 秒，生产环境 5 分钟，**没人知道为什么**。

逐项看：

| 配置 | 值 | 理由 |
|---|---|---|
| `Durable` | `"notification"` | 有名字才叫持久消费者：**记住进度**，重启不重放 |
| `DeliverPolicy` | `DeliverNewPolicy` | **一个全新的服务从"现在"开始** |
| `AckPolicy` | `AckExplicit` | 每条都明确回答（不是自动 Ack） |
| `AckWait` | 30s | 服务器等我们这么久 |
| `MaxDeliver` | 5 | 5 次之后就是死信 |
| `MaxAckPending` | 100 | **在所有实例之间**，同时最多 100 条在飞 |

> `[10:05:15]` **`DeliverNew`**: **a brand new notification service starts with what happens from now on**. The event log replayed everything — **which is right for a log, but nobody wants an email about last month's transfers**.

> **译文**：**`DeliverNew`**：**一个全新的通知服务从"从现在起发生的事"开始**。event log 重放了所有东西——**对一个日志来说这是对的，但没人想收到上个月转账的邮件**。

💡 这是**同一个流、不同的消费者、不同的起点**：

| 消费者 | `DeliverPolicy` | 为什么 |
|---|---|---|
| `eventlog`（EP11） | `DeliverAll` | 它是**日志**，历史就是它的全部价值 |
| `notification`（EP13） | `DeliverNew` | 它是**动作**，历史是噪音 |

> `[10:05:46]` **History isn't lost though: the stream keeps 30 days, and another consumer could still read all of it.**

> **译文**：**历史并没有丢：流保留 30 天，另一个消费者仍然可以读到全部。**

💡 这句话很重要：**"从哪开始"是消费者的选择，不是流的选择**。流保留 30 天（EP11 的 `MaxAge`），任何消费者都能选自己从哪读。

**这也意味着"想补发历史"是一个消费者配置的改动，不是一次数据修复。**

> `[10:05:31]` **`MaxAckPending: 100`** — **at most a hundred messages in flight across every instance**.

> **译文**：**`MaxAckPending: 100`**——**在所有实例之间，最多一百条消息同时在飞**。

💡 注意 "**across every instance**"：**它不是每个实例 100，是总共 100**。3 个实例时，每个大约 33。

这是一个**全局背压阀**。它的作用是防止"实例扩容 → 邮件服务器被打爆"：

```
MaxAckPending = 100  →  无论起几个实例，同时在处理的永远 ≤ 100
```

**扩容提高的是吞吐，不提高并发度上限。** 这个区别在设计限流时很关键。

---

## 14. `handle`：四种结果一个 `switch`

```go
ctx, cancel := context.WithTimeout(context.Background(), ackWait/2)
err = n.process(ctx, msg.Data())
var permanent *PermanentError
switch {
case err == nil:
	msg.Ack()          // ack 丢了就再见一次，然后跳过
case !errors.As(err, &permanent) && meta.NumDelivered < uint64(n.MaxAttempts):
	msg.NakWithDelay(n.backoff(meta.NumDelivered))
default:
	n.deadLetter(ctx, msg, err)
}
```

> `[10:06:11]` **each message gets its own context, with half the AckWait**. Why **a fresh context and not the service's?** Because **on shutdown we drain: a message already in our hands should finish, not be cut off halfway through a send**.

> **译文**：**每条消息拿到自己的 context，超时是 AckWait 的一半**。为什么**用一个新的 context 而不是服务的那个？** 因为**关闭时我们会 drain：一条已经在我们手里的消息应该做完，而不是在发送途中被切断**。

💡 三个设计点挤在这里，每个都值得停一下：

**① 为什么是 `ackWait/2`（15 秒）？**

> `[10:04:29]` **AckWait, 30 seconds — how long the server waits for our answer before delivering again. Handling a message gets half of it, so we always answer in time.**

> **译文**：**AckWait，30 秒——服务器等我们回答等多久，超了再投一次。处理一条消息只拿到它的一半，这样我们永远来得及回答。**

这是**超时必须严格小于外层超时**的老原则：如果处理超时 = 30 秒，那"我们超时了"和"服务器认为我们死了"会**同时发生**——这时你可能还在 `Nak`，服务器已经重投了。**留一半余量，让内层永远先失败。**

**② 为什么 `context.Background()` 而不是 `ctx`？**

这是 EP13 里**最容易看漏的一行**。`ctx` 是服务的 context，**在 Ctrl-C 时被取消**。如果用它：

```
Ctrl-C → ctx 取消 → 正在发送的邮件被切断 → 但消息没 Ack → 重投 → 再发一次
```

用 `Background()` + 自己的 15 秒超时：

```
Ctrl-C → ctx 取消 → consumer.Drain()                     ← 停止拉新消息
       → 但手上这条有自己的 15 秒 → 正常发完 → Ack     ← 优雅收尾
```

**这是"drain"能成立的技术前提。** 没有它，`Drain()` 只会等到超时，然后一样丢。

**③ 顺序**：注意 `switch` 的顺序。第二个 `case` 同时检查两件事：

```go
!errors.As(err, &permanent) && meta.NumDelivered < uint64(n.MaxAttempts)
```

- 不是永久错误 ✅
- **而且还有投递次数** ✅ → 重试

两个条件缺一不可。**如果是永久错误，或者次数用完，都落到 `default` → 死信。**

> `[10:06:45]` **a transient error with deliveries left → Nak with a delay from backoff. Anything else — a permanent error, or the last delivery — it's a dead letter.**

> **译文**：**还有次数剩下的瞬时错误 → 带 backoff 延迟的 Nak。其他一切——永久错误，或者最后一次投递——都是死信。**

### `Ack` 和"double ack"

> `[10:07:03]` **the Ack is a plain one, which doesn't wait for the server to confirm it**. **A double Ack would, but idempotency already covers a lost Ack, so we skip the round trip.**

> **译文**：**Ack 是普通的那种，它不等服务器确认**。**双 ack 会等，但幂等已经覆盖了"ack 丢失"这件事，所以我们省掉这次往返。**

💡 一句话省掉一次网络往返，理由却很硬：

| 如果 Ack 丢了 | 会发生什么 |
|---|---|
| 没有幂等 | **重投 → 邮件发两次** ❌ |
| 有幂等（我们） | 重投 → 查到记录 → 跳过 ✅ |

**因为已经为"至少一次"付过账了，就不必再为"ack 可靠"付第二次账。** 这就是"幂等"这个投资的红利：**它让系统其他部分可以更懒。**

### `deadLetter`：存不下来怎么办

```go
err := n.store.DeadLetter(ctx, ...)
if err != nil {
	// Not kept: let the server deliver it again, if it still will.
	n.logger.ErrorContext(ctx, "keep dead letter", "err", err)
	msg.Nak()
	return
}
msg.Term()
```

💡 这个 `if` 是**死信队列自己的失败模式**，很容易漏：

```
死信表写不进去（数据库挂了）
  ├─ 直接 Term → 消息永久丢失，连带"为什么失败"也没了  ❌
  └─ Nak      → 服务器再投，也许数据库会好起来          ✅
```

**死信的可靠性必须 >= 消息的可靠性**，否则"保存失败"就变成了"销毁失败"。

> 注意 `Nak()`（不带延迟）而不是 `NakWithDelay`：**数据库挂了，不需要指数退避**，立即重试是对的。

---

## 15. 为什么用表，而不是 JetStream 的 advisory

> `[10:03:24]` option two: **the server's `MaxDeliver` advisory** — **JetStream announces every message that ran out of deliveries, and a listener copies it. But the advisory doesn't know why it failed, and why is exactly what you need at 3 in the morning.**

> **译文**：选项二：**服务器的 MaxDeliver advisory**——**JetStream 会宣告每一条用完了投递次数的消息，一个监听者把它抄下来。但 advisory 不知道它为什么失败，而"为什么"恰恰是你凌晨 3 点需要的东西。**

> `[10:03:41]` **what the advisory does catch is a consumer that crashed on its very last delivery — the server gives up silently, and option one never runs.**

> **译文**：**advisory 确实能抓到一种情况：一个消费者在它最后一次投递时崩溃了——服务器静静地放弃，而选项一（消费者自己写）永远不会运行。**

💡 这是**"两个方案各有盲区"**的经典对照：

| 方案 | 抓得到 | 抓不到 |
|---|---|---|
| 消费者自己写（option 1） | **失败的完整上下文**（错误、payload、次数） | **最后一次投递时崩溃**（代码没跑完） |
| 服务器 advisory | **最后一次崩溃** | **为什么失败**（服务器只知道次数用完） |

作者选了 option 1，并**明确说出了它漏掉的那个洞**。这是好的技术决策的写法：**不是"我的方案更好"，而是"我选了这个，它漏这个，我认为可以接受"。**

漏掉的洞（最后一次崩溃）的后果是：**那条消息既没进死信，也没被处理，而且服务器不再投了**。它**静静地消失**。

> **这是本设计已知的、唯一的消息丢失路径。** 值得写在你的设计文档里。

---

## 16. `backoff`：翻倍 + 抖动，一行

```go
// backoff doubles with each delivery, up to a minute, with jitter.
func (n *Notifier) backoff(delivery uint64) time.Duration {
	d := min(n.Backoff<<min(delivery-1, 16), time.Minute)     // 1s,2s,4s,... 上限 1min
	return (d/2 + rand.N(d/2+1)).Round(time.Millisecond)      // 全抖动：50%~100%
}
```

> `[10:02:04]` **retries wait longer each time — about one second, then two, four, eight — with jitter, so a thousand messages that fail together don't all come back together**.

> **译文**：**重试每次等更久——大约一秒，然后两秒、四秒、八秒——带抖动，这样一千条一起失败的消息不会一起回来。**

💡 三个细节：

**① `min(delivery-1, 16)` 的 `16`**：防止移位溢出。`1<<17` 秒 = 36 小时，其实也不会溢出，但**`min(..., 16)` 保证了移位次数有限**，是一个**防御性写法**。

**② `min(..., time.Minute)`**：上限 1 分钟。**没有上限的指数退避会让一次暂时故障变成 20 分钟的空窗。**

**③ 全抖动（full jitter）**：`d/2 + rand.N(d/2+1)` → 实际等待在 **[50%, 100%]** 之间。

> 这是 EP06 里"full jitter"公式的**第三次出现**（EP06 是 `rand.N(d)`，区间 [0, d)）。两者都对，**`[d/2, d]` 更保守**：它保证不会比 `d/2` 更早重试，避免"抖动把退避抵消掉"。

💡 为什么必须有抖动，一句话：**"同步失败 → 同步重试"是级联故障的引擎**。

```
1000 个消费者同时失败
  ├─ 无抖动：全在 t+1s 重试 → 邮件服务器收到 1000 个并发 → 又全失败 → t+2s 再来 1000 个
  └─ 有抖动：散布在 t+0.5s ~ t+1s → 峰被削平 → 服务器能缓过来
```

**抖动不解决"失败"，它解决"失败的同步性"。**

> `[10:02:54]` ...or **we Nak with a delay, chosen per message, in code**. We'll **Nak explicitly, with our own jitter** — because **the consumer's backoff list only applies when we don't answer at all, and it replaces the AckWait**.

> **译文**：……或者**我们在代码里按消息选延迟来 Nak**。我们**显式 Nak，用自己的抖动**——因为**消费者的 backoff 列表只在我们完全不回答时才生效，而且它会替换掉 AckWait**。

💡 这是"NATS 有这个功能但我们不用"的**明确理由**：

| JetStream 的 `BackOff` 列表 | 我们的 `NakWithDelay` |
|---|---|
| 只在**不回答**时生效 | 我们**主动**回答"晚点再投" |
| 替换 `AckWait`（**全局**改动） | 每条消息独立 |
| 固定间隔 | 可以**按投递次数**算 |

**关键差别**：`BackOff` 会**替换** `AckWait`，也就是说你为了让退避生效，必须把 `AckWait` 让给它。**一个全局设置被另一个功能绑架了**——那就不值得用。

---

## 17. 现场演示：四种破坏

### ① 邮件服务器挂掉

> `[10:16:26]` now **let's break things: the mail server goes down.** `docker compose stop mailpit`. In production **this is your email provider having an outage**, or the network between you and it having a bad day.

> **译文**：现在**我们来搞破坏：邮件服务器挂了**。`docker compose stop mailpit`。生产环境里**这就是你的邮件服务商出了故障**，或者你和它之间的网络今天状态不好。

> `[10:16:57]` the notification service's log tells the rest: **both messages failed, connection refused**, and **each one is retrying, on a later delivery each time**. **Look at the delays: under a second, then between 1 and 2, then a few seconds — they double with jitter.** And **meanwhile the transfer service and the wallet are fine.**

> **译文**：通知服务的日志说了剩下的事：**两条消息都失败了，connection refused**，而且**每一条都在重试，每次投递更晚一点**。**看这些延迟：不到一秒，然后 1 到 2 秒之间，然后几秒——它们在翻倍并带抖动。** 而**与此同时 transfer 服务和 wallet 都好好的**。

> `[10:17:29]` **their part was done the moment the events were in the stream**. Mailpit comes back — `docker compose start mailpit` — and **at their next retry, both notifications go out. Nobody had to do anything.**

> **译文**：**它们那一部分在事件进入流的那一刻就做完了**。Mailpit 回来了——`docker compose start mailpit`——**在它们下一次重试时，两封通知都发出去了。谁都不需要做任何事。**

💡 这是**整集最重要的一次演示**，因为它同时证明了四件事：

| 证明了 | 机制 |
|---|---|
| 钱不等邮件 | outbox + stream（EP11） |
| 邮件不丢 | JetStream 持久化 + `MaxDeliver 5` |
| 不会打爆恢复的服务器 | 指数退避 + 抖动 |
| 恢复是自动的 | 无人工介入 |

**而这一切的成本，在 transfer 和 wallet 侧是零行代码改动。**

### ② 提交之后、Ack 之前崩溃

> `[10:18:01]` we send an email, **write it down, and die before the Ack**. **A flag just for this demo**, like last episodes: `-notify-crash-after` names the type of event we just sent. **The process exits.**

> **译文**：我们发出一封邮件、**把它记下来、然后在 Ack 之前死掉**。**一个只为这个演示存在的 flag**，像前几集那样：`-notify-crash-after` 指定我们刚发完的那类事件。**进程退出。**

> `[10:18:51]` ...here's **the server's side of it**: `nats consumer info`, for the notification consumer on transfer. **The last delivered message, an acknowledgement floor that stops short of it, and one outstanding Ack — the message we handled and never acknowledged.** **It's in limbo now, and the AckWait decides when it comes back.**

> **译文**：……这是**服务器那一侧的视角**：`nats consumer info`，看 transfer 上的 notification 消费者。**最后投递的消息、停在它前面的 ack floor，以及一个未完成的 Ack——那条我们处理了却从未确认的消息。** **它现在处于悬空状态，而 AckWait 决定它什么时候回来。**

💡 "**in limbo**"（悬空）这个词很准。服务器眼里有三种消息：

```
acked    ─── 有 ack floor 保护，不会重投
pending  ─── 已投递，等回答  ← 我们死在这里，它就在这
new      ─── 还没投递
```

> `[10:19:40]` ...started again normally, **the server is waiting for the AckWait to run out — 30 seconds after it delivered the message — and then it delivers it again. And notice there's no recovery code anywhere.** The server **keeps the message until it gets an answer**, and **the consumer neither knows nor cares that this is the second time.**

> **译文**：……正常重新启动，**服务器在等 AckWait 走完——在它投递那条消息 30 秒之后——然后它再投一次。注意：任何地方都没有恢复代码。** 服务器**一直留着消息直到拿到回答**，而**消费者既不知道也不关心这是第二次。**

> `[10:20:18]` there it is: **Alice's message, on delivery two, "already sent, skipping". The insert found the row, and nothing went out.** That's **the case from the slide: after the commit, before the Ack.**

> **译文**：来了：**Alice 的消息，第二次投递，「already sent, skipping」。插入找到了那一行，什么都没发出去。** 这就是**幻灯片上那个情况：提交之后、Ack 之前。**

💡 **"there's no recovery code anywhere"** 是本集最值得记住的一句话。

对比一下"传统"做法会怎么写：

```go
// 假设性的"恢复逻辑"——本课程里不存在
func recover() {
	// 1. 找出所有 status='sending' 且超过 5 分钟的记录
	// 2. 判断它们到底发了没有  ← 判断不了！
	// 3. 决定重发还是标记完成
}
```

第 2 步**在原理上做不到**。所以作者的选择是：**不做恢复，而是让"重复"无害**。

> **能在架构上消除的问题，不要用运维手段去补。** 这比"写一个恢复任务"高一个层级。

> `[10:20:35]` **without the notifications table, Alice would have two emails now**, and she'd be wondering whether she paid twice. And Mailpit agrees: **still two emails**. **A crash at the worst possible moment, and Alice got exactly one.**

> **译文**：**如果没有 notifications 表，Alice 现在会有两封邮件**，而她会怀疑自己是不是付了两次。Mailpit 也同意：**仍然只有两封邮件**。**在最糟的时刻崩溃，而 Alice 恰好只收到一封。**

💡 "she'd be wondering whether she paid twice" 是**产品语言**。技术上的"重复消息"在用户那里是"**我是不是被扣了两次钱？**"

**这就是为什么这一集配得上 48 分钟：它讲的不是"消息去重"，是"别让用户怀疑自己的钱"。**

### ③ poison message

> `[10:21:07]` now **the dead letter queue. First a poison message**: someone publishes a **bare transfer onto the `transfer.events.` subject, without our envelope, and without an id**. **A publisher with a bug — it happens.** It lands in the transfer stream like any other message, and **our consumer's filter matches it**.

> **译文**：现在说**死信队列。先来一条毒消息**：有人往 `transfer.events.` 这个 subject 上发布了一个**裸的 transfer，没有我们的信封，也没有 id**。**一个发布者出了 bug——这种事会发生。** 它像任何其他消息一样落进 transfer 流，而**我们消费者的过滤器匹配到了它**。

> `[10:21:42]` the log: **"failed for good, dead letter, on delivery one"**. **Without an id, it's permanent, so we don't waste five deliveries on it.** **Without that distinction, it would get five deliveries with backoff, failing the same way every time, only to end up in the same place.**

> **译文**：日志：**「failed for good, dead letter, on delivery one」**。**没有 id 就是永久错误，所以我们不在它身上浪费五次投递。** **没有那个区分，它会拿到五次带退避的投递，每次都以同样的方式失败，最后到同一个地方。**

💡 这就是 `PermanentError` 的**实际价值**：

```
坏消息 5 次投递 × 指数退避（1+2+4+8+16 秒）≈ 31 秒 + 5 次 SMTP 尝试
```

**每一秒都是在浪费一个 worker 的位置**，而且**结果从第一次就确定了**。

> `[9:59:26]` ...**at-least-once delivery plus a record of what we've done — effectively once.**

> **译文**：……**至少一次投递，加上一份"我们做过什么"的记录——效果上是一次。**

💡 注意 poison message 能进死信的**前提**是 `process` 里的这个检查：

```go
if evt.ID == uuid.Nil {
	return Permanent(fmt.Errorf("event %q has no ID", evt.Type))
}
```

> `[10:01:33]` a message that isn't an event is permanent, **and so is one without an id — without an id we can't be idempotent about it**.

> **译文**：一条不是事件的消息是永久错误，**没有 id 的也一样——没有 id 我们就不可能对它幂等**。

**这句话点出了幂等的必要条件：你需要一个稳定的键。** 没有键的消息**必须**被拒绝，否则它会**每次都被当成新的**。

### ④ 瞬时错误一直不好

> `[10:21:59]` then **a transient failure that lasts too long**. Three transfers have nearly emptied Alice's wallet, so **she tops it up first**, then **Mailpit goes down again**, and she pays Bob $15, $15. **Five deliveries each** — the way it's doubling — **and then "failed for good, dead letter, on delivery five"**. **From first delivery to last, that's 10 to 15 seconds of trying; for real email you'd stretch it to hours.**

> **译文**：然后是一个**持续太久的瞬时错误**。三笔转账几乎掏空了 Alice 的钱包，所以她**先充了一笔**，然后 **Mailpit 又挂了**，她付给 Bob \$15、\$15。**每封五次投递**——按它翻倍的方式——**然后「failed for good, dead letter, on delivery five」**。**从第一次投递到最后一次，那是 10 到 15 秒的尝试；对真实邮件你会把它拉长到几个小时。**

💡 "for real email you'd stretch it to hours" 是一个**参数选择的提醒**：

| 环境 | `MaxAttempts` | `Backoff` | 总时长 |
|---|---|---|---|
| 演示 | 5 | 1s | ~15 秒 |
| 生产 | 8~10 | 30s~1min | **几小时** |

**为什么生产要几小时**：邮件服务商的故障**通常持续几分钟到几小时**（配额、黑名单、DNS）。**15 秒的死信等于"一有波动就全进人工队列"。**

> 而反过来：**如果 `MaxAttempts` 太大，一次真故障会产生一个巨大的死信表**。**这就是"重试预算"——你要在"太早放弃"和"攒一堆垃圾"之间选。**

### 重放

> `[10:23:19]` Mailpit comes back, and **we replay the dead letters: two sent — Alice's and Bob's — and the poison message failed again, so it's kept**. **No replay can fix a bug in the publisher. That takes a person who fixes the publisher, and then deletes the dead letter, or corrects it and replays it.**

> **译文**：Mailpit 回来了，**我们重放死信：两封发出去了——Alice 的和 Bob 的——而毒消息又失败了，所以它被留着**。**重放修不了发布者的 bug。那需要一个真人去修发布者，然后删掉这条死信，或者修正它再重放。**

💡 **"重放不会让毒消息变好"** 是这个演示的**关键收尾**。如果重放能"清空"死信表，那死信表就成了一个**掩盖问题的抽屉**。

死信的正确用法是：

```
死信 → 人来判断 → 修那个原因（部署修复 / 改数据 / 丢弃）
     → 然后再重放
```

**而不是**：

```
死信 → 定时任务每小时重放一次 → 表看起来总是空的 → 问题永远不解决
```

> **一条永远失败的消息能被重放 100 次，但它需要的是一次修复。**

---

## 18. 设计目标：让顺序不重要

> `[10:08:08]` ...and **what about order?** Within one instance, `consume` calls `handle` **with one message at a time, per consumer**. We have two consumers, so **two at once**. For more throughput, **start more instances — they share the same durable consumer, and the server spreads the messages between them.** And `MaxAckPending` caps what's in flight across all of them. **And order? It's gone.**

> **译文**：……**顺序呢？** 在一个实例内，`consume` **对一个消费者来说一次只调一条消息**。我们有两个消费者，所以**同时两条**。要更高吞吐就**多起实例——它们共享同一个持久消费者，服务器把消息分给它们**。而 `MaxAckPending` 给所有实例的同时在飞数量封顶。**那顺序呢？没了。**

> `[10:08:39]` **an Acked message comes back after later ones, and instances race each other.** **For email, that's fine — every message stands alone**, and **nobody cares whether Bob's email left a millisecond before analytics**.

> **译文**：**一条被 Ack 的消息会在更晚的消息之后回来，而实例之间互相竞争。** **对邮件来说这没问题——每封邮件都是独立的**，而**没人在意 Bob 的邮件是不是比 analytics 早了一毫秒**。

> `[10:08:56]` **when order does matter, like a ledger projection**, you **partition one subject per key, and one message in flight per key** — or `MaxAckPending` of one — **and you pay for it in throughput**.

> **译文**：**当顺序真的重要时，比如一个账本投影**，你**按 key 分区，一个 key 上只有一条消息在飞**——或者把 `MaxAckPending` 设成 1——**而你在吞吐上为此付账。**

> `[10:09:14]` **the design goal is to make order not matter, and twice not matter.**

> **译文**：**设计目标是让顺序不重要，也让"两次"不重要。**

💡 "**make order not matter, and twice not matter**" 是**整集的题眼**，值得和 EP12 的对应句放在一起：

| EP12 | EP13 |
|---|---|
| exactly-once **delivery** 不存在 | at-least-once **delivery** 是设计 |
| 所以每步**幂等** | 所以每条消息**幂等** |
| at-least-once + 幂等 = exactly-once **effects** | 同一个公式 |

**同一个公式，两个层次**：EP12 是"跨服务的步骤"，EP13 是"消息的处理"。**这不是巧合，是同一个问题的两个实例。**

> 最后那句"**在吞吐上付账**"很实在。顺序和吞吐是**直接对立**的：

```
MaxAckPending = 1  →  严格顺序，吞吐 ≈ 1/处理时间
MaxAckPending = N  →  N 倍吞吐，顺序没了
```

**没有免费的顺序。** 所以正确的问法是"**这条消息顺序重要吗？**"——对邮件，不重要；对账本投影，重要。

---

## 19. `main.go`：一个 flag 而不是一个子命令

> `[10:09:51]` ...its name, and **a flag, `-replay-dead-letters`**. **The same binary, run once to replay them, and then exit.** **A flag, and not a separate command, because replaying needs exactly the same wiring: the database, the address book, and the sender.**

> **译文**：……它的名字，和一个 flag，**`-replay-dead-letters`**。**同一个二进制，跑一次去重放它们，然后退出。** **用 flag，不用单独的子命令，因为重放需要完全相同的接线：数据库、通讯录、发信器。**

```go
replay := flag.Bool("replay-dead-letters", false, "send the dead letters again, and exit")
...
if *replay {
	n, err := notifier.Replay(context.Background())
	pool.Close()
	...
	logger.Info("dead letters replayed", "sent", n)
	return                       // ← 连 NATS 都不连
}
```

💡 这一段值得记住的思路：**"要不要做成独立命令"的判据是"它需不需要同样的接线"**。

| | 独立命令 | flag |
|---|---|---|
| 共享代码 | 要重构出 `pkg/setup` | **不用** |
| 配置 | 要复制一份 | **同一份** |
| 部署 | 多一个二进制 | **同一个镜像** |

> `[10:10:07]` **in Kubernetes, in episode 23, it becomes a one-off job.**

> **译文**：**在 Kubernetes 里，第 23 集，它变成一个一次性 Job。**

💡 这一句把"flag 是不是够正经"回答了：**在容器世界里，一个 flag 和一个 Job 是绝配**——Job 只是"跑一次这个镜像，参数是 `-replay-dead-letters`"。**不需要第二个二进制。**

### 不创建 stream

> `[10:10:39]` ...and there's **no stream to create: transfer and wallet belong to the services that publish to them**. **Creating them here too would mean two services fighting over one stream's config.**

> **译文**：……**没有流要创建：transfer 和 wallet 属于发布它们的那些服务**。**在这里也创建，意味着两个服务为一个流的配置打架。**

💡 这是一个**所有权规则**，和 EP11 的 "the outbox is whose?" 一脉相承：

| 谁建的流 | 谁改配置 |
|---|---|
| **发布者**（transfer / wallet） | 只有它 |
| 消费者也建 | **两个都可以** → `CreateOrUpdateStream` 会**互相覆盖** |

> 后果很具体：如果 notification 用 `MaxAge: 7d` 建流，它就**悄悄改掉了** transfer 的 30 天保留期，而**没有任何人 review 过这个改动**。

**这就是为什么代码里只有 `CreateOrUpdateConsumer`，没有 `CreateOrUpdateStream`。**

### 关闭顺序

```go
<-ctx.Done()
srv.Shutdown(shutdownCtx)          // ① 先停 HTTP（healthz/readyz）
logger.Info("server stopped")
for _, cc := range consumers {
	cc.Drain()                      // ② 停止拉新消息，把手上的做完
	<-cc.Closed()                   // ③ 等它真的做完
}
nc.Close()                          // ④ NATS
pool.Close()                        // ⑤ 数据库
```

> `[10:11:28]` **after the server, drain the consumers. `Drain` stops pulling, and finishes the messages we already have, and `Closed()` says when that's done. A message that's cut short is delivered again later — at least once.**

> **译文**：**服务器之后，drain 消费者。`Drain` 停止拉取，并把我们已有的消息做完，而 `Closed()` 说它什么时候做完。一条被切断的消息以后会再投一次——至少一次。**

💡 和 EP02/EP03 里"**启动正向、拆除反向**"是同一条规则，只是**多了两个必须严格排队的步骤**：

```
启动： Postgres → NATS → consumer → HTTP
关闭： HTTP → consumer(drain+wait) → NATS → Postgres
```

**`<-cc.Closed()` 那一行不能省。** `Drain()` 是**异步**的——它只是"开始 drain"，立刻返回。不等它，你就会在消息还在发的时候关掉 NATS 和数据库，**结果是 NAK 一堆、重投一堆**。

> 而"重投一堆"其实**不会丢数据**（至少一次！），但会给下游一个**完全没有必要的尖峰**。**优雅关闭的意义不只是不丢数据，也是不制造尖峰。**

---

## 20. 活体验证：三行日志，三处分层

服务的启动日志就是拓扑图：

```
[10:13:43]  connected to postgres, max_conns=...
            connected to nats, url=...
            consuming stream=transfer subjects=[transfer.events.>]
            consuming stream=wallet   subjects=[wallet.events.transfer.completed]
            notification service listening addr=:8084
```

然后一次转账在日志里长出两条线：

> `[10:15:05]` ...**our logging package adds them to every line logged with it, so nobody has to pass a logger around.**

> **译文**：……**我们的 logging 包把它们加到每一行日志上，所以没有谁需要到处传一个 logger。**

💡 这里说的是 EP11/EP12 埋下的 `logging.With(ctx, slog.String("stream", ...), ...)`：

```
notification sent  type=transfer.completed  to=alice@example.com  stream=transfer seq=42 delivery=1
notification sent  type=wallet.transfer.completed  to=bob@example.com  stream=wallet seq=17 delivery=1
```

> `[10:15:05]` **those three come from the context we built in `handle`** — **stream, sequence number, delivery**. **The first delivery.** Every email our code sends in development **lands here, whoever it's addressed to — nothing leaves this machine**.

> **译文**：**那三个来自我们在 `handle` 里建的 context**——**stream、序号、投递次数**。**第一次投递。** 我们的代码在开发环境发出的每封邮件**都落在这里，不管收件人是谁——没有任何东西离开这台机器**。

💡 注意日志里 `seq` 和 `delivery` 的**组合含义**：

| 日志 | 含义 |
|---|---|
| `seq=42 delivery=1` | 第一次投递，正常 |
| `seq=42 delivery=2` + `already sent, skipping` | **重投，被幂等挡住** ← 这一行是这一集的证明 |

**一行日志同时证明了"重投发生了"和"重投无害"。**

---

## 21. 生产上还缺什么（作者自己列的）

> `[10:24:07]` ...a word on what a production notification service adds around this core: **preferences** — what each user wants to hear about, **unsubscribe links, quiet hours**; **templates** — HTML and plain text, in the user's language, **edited without a deploy**; **a real provider, whose webhooks report bounces and complaints, so we stop mailing addresses that don't work**; **more channels, like SMS and push — each one just another Sender**; **limits and digests** — if someone makes 50 transfers in a minute, **they want one email, not 50**; and **watching it: a dead letter should page someone, a growing number of pending messages means we're falling behind, and rising redeliveries means something is flaky**.

> **译文**：……说一句生产级通知服务在这个核心之外还加什么：**偏好设置**——每个用户想听什么、**退订链接、免打扰时段**；**模板**——HTML 和纯文本、用户的语言、**不用部署就能改**；**一个真实的服务商，它的 webhook 会报告退信和投诉，这样我们停止给坏地址发信**；**更多渠道，比如短信和推送——每一个只是另一个 Sender**；**限流和摘要**——如果一个人一分钟做了 50 笔转账，**他想要一封邮件，不是 50 封**；以及**看着它：一条死信应该把人叫起来，待处理消息数在涨说明我们落后了，而重投次数上升说明有东西不稳定**。

💡 这段清单最值得学的是**它怎么被组织的**：每一条都**对应架构里的一个接口**，而不是一堆散装需求。

| 需求 | 落在哪个接口 |
|---|---|
| 短信、推送 | **`Sender` 接口**（"each one just another Sender"） |
| 模板 | `compose`（现在是 `switch`，以后是模板表） |
| 偏好/退订 | `compose` 之后加一道过滤 + 一张偏好表 |
| 摘要 | `compose` 之后合并（**需要状态**，最难） |
| 监控 | **指标**（下一集） |

**"每一个只是另一个 Sender"** 这句话说明接口切得对：**加渠道不改核心逻辑。**

而**摘要（digest）**是唯一一个**会破坏当前设计**的需求：

> 现在"一条事件 → 一封信"是**无状态**的。摘要需要"**这一分钟有 50 条事件 → 合并成一封**"，那需要**窗口 + 状态 + 延迟发送**。
>
> 这不是加一个 Sender 能解决的——**它改变的是"事件到动作"的映射本身**。

**能识别出"哪一条需求不属于现有抽象"，比能列出需求更难。**

---

## 22. 测试：真的 Postgres + 真的 NATS

```go
// 有假的，也有真的
fakeSender    // 记录它发了什么，"fail" 期间一直失败
fakeUsers     // 认识 example.com 的每个人
real postgres // 每个测试自己的表
real NATS     // 每个测试自己内存里的流，随机名字
```

> `[10:25:45]` a **fake sender** keeps what it sends, and **like the saga's fake wallet, fail holds its first answers before it starts working**, and **an address book that knows everyone at example.com** — **the fake stand-in for what we don't own**. **The logic, the database, and the broker are the real thing.**

> **译文**：一个**假发信器**记下它发了什么，而且**像 saga 的假钱包一样，"fail" 会让它前几次回答失败、之后才开始工作**；还有一个**认识 example.com 所有人的通讯录**——**我们不管的东西的替身**。**逻辑、数据库和 broker 都是真的。**

💡 "**the fake stand-in for what we don't own**" 是一条**测试替身的判据**：

| 组件 | 归属 | 测试里用 |
|---|---|---|
| SMTP 服务器 | **别人的** | fake |
| auth 服务 | **别人的** | fake |
| Postgres | 我们的 | **真的** |
| NATS | 我们的（基础设施） | **真的** |

**判据不是"快不快"，是"是不是我们的责任"。** 造假 Postgres 会造掉**你唯一能验证幂等的地方**——那等于测了个寂寞。

> `[10:28:42]` the notification tests **take seconds, against real infrastructure, because nothing in them waits longer than it has to — the backoff is a millisecond**.

> **译文**：通知的测试**几秒就跑完，而且用真的基础设施，因为里面没有任何东西等得比它必须等的更久——backoff 是一毫秒。**

💡 这才是**为什么 `MaxAttempts` 和 `Backoff` 是导出字段**：

```go
type Notifier struct {
	MaxAttempts int           // 导出
	Backoff     time.Duration // 导出
}
...
func NewNotifier(...) *Notifier {
	return &Notifier{..., MaxAttempts: 5, Backoff: time.Second}
}
```

**导出不是为了给外部用，是为了给测试改。** 一个默认值 + 可覆盖，比"传 6 个参数"轻得多，也比"测试里 `time.Sleep(1s)`"快 1000 倍。

> `[10:26:16]` `newNotifier` gives each test **its own tables**, with **the trick from the saga's tests: a pool of one connection, and temporary copies of the tables**.

> **译文**：`newNotifier` 给每个测试**它自己的表**，用**saga 测试里那个技巧：一个只带一条连接的池，加上表的临时副本**。

💡 "**a pool of one connection**" 是关键：`CREATE TEMP TABLE` 是**会话级**的。池里有多个连接时，建表的连接和执行查询的连接可能是不同的，**临时表就看不见了**。

> `MaxConns = 1` 保证**同一个会话**，于是 `TEMP` 表全局可用，而且**测试结束自动消失**（连接关了就没了）。

**这个技巧在 EP12 就有了，这里复用**——说明它是**模式**，值得你记住。

> `[10:27:20]` `consume` connects to the **test NATS, and makes a stream for this test alone, with a random name in memory, and deleted afterwards**. **A memory stream is fast, and since tests share nothing, they all run in parallel.**

> **译文**：`consume` 连到**测试用的 NATS，为这一个测试建一个流，随机名字、放在内存里、之后删掉**。**内存流很快，而且因为测试之间什么都不共享，它们全部并行跑。**

💡 **注意这里是"生产代码里不建流，测试里建流"**。

生产代码里 `notifier.Consume(ctx, js, stream, ...)` **只建消费者，不建流**（§19）。**流是测试自己建的**——因为测试就是"发布者"的角色。

**这印证了所有权规则：谁发布谁建流。生产里发布者是 transfer/wallet，测试里发布者是测试自己。**

> `[10:27:37]` ...**the table: every path a message can take.** It sends; **it retries until it works, which is MaxDeliver working**; ...**each case publishes an event, and waits for either an email, or a dead letter**: with **no dead letter expected — exactly one email, and nothing dead**; otherwise **no email, and one dead letter, after the expected number of deliveries**. Then **the mail server is fixed, and a replay sends it once**.

> **译文**：……**那张表：一条消息能走的每一条路径。** 它发送；**它一直重试直到成功，那就是 MaxDeliver 在工作**；……**每个用例发布一个事件，然后等一封邮件或者一条死信**：在**不期望死信的情况下——恰好一封邮件，且没有死信**；否则**没有邮件，并且在预期的投递次数之后恰好一条死信**。然后**邮件服务器被修好，一次重放把它发出去一次**。

💡 注意测试的**断言形态**：不是"检查某个函数被调用了"，而是**观察外部世界的终态**：

```
发布 → 等 → 邮件数 == 1 且 死信数 == 0     (成功路径)
发布 → 等 → 邮件数 == 0 且 死信数 == 1     (失败路径)
修好 → replay → 邮件数 == 1                (重放)
```

**"等"而不是"睡"**：`[10:28:59]` 里提到 "**the poll instead of sleeping**"——轮询而不是固定 `Sleep`。这让测试**既快又不 flaky**。

> 这是测试异步系统的唯一正确姿势：**等条件成立（带超时），不要等固定时间。**

`-race` 也是必须的：

> `[10:28:26]` **the consumer runs handle on its own goroutine, while the test reads the fake sender — which is exactly what the race detector is for.**

> **译文**：**消费者在自己的 goroutine 上跑 handle，而测试在读假发信器——这正是 race detector 存在的意义。**

---

## 23. 一页总结

### 本集建立的六条规则

| # | 规则 | 为什么 |
|---|---|---|
| 1 | **旁路服务，不在钱的路径上** | 邮件挂了钱照走 |
| 2 | **pull 而不是 push** | 背压内建，慢消费者自动降速 |
| 3 | **`event_id` 是幂等表的主键** | 到达两次找到自己那一行 |
| 4 | **插入和发送在同一个事务里** | 提交前崩溃回滚，提交后崩溃跳过 |
| 5 | **`PermanentError` 决定它值不值得重试** | 毒消息不浪费五次投递 |
| 6 | **死信是给人看的，不是给定时任务看的** | 重放修不了发布者的 bug |

### 与 EP11/EP12 的关系

```
EP11  outbox      : 两次写 → 一次写            （发布端）
EP12  saga        : 跨服务步骤 + 幂等 + 版本   （流程端）
EP13  notification: 消息处理 + 幂等 + 死信     （消费端）
```

> **EP11 保证"事件一定会被发布"，EP13 保证"事件被处理多少次都只生效一次"。**
>
> **两端合起来，才是"至少一次 + 幂等 = 一次效果"的完整闭环。**

### 一张表：三个"恰好一次"的谎言

| 你想做到的 | 现实 | 本课程的做法 |
|---|---|---|
| 消息恰好投递一次 | **做不到**（沉默无法区分） | 至少一次 + 幂等 |
| 邮件恰好发一次 | **做不到**（外部系统，窗口 ④） | 幂等表 + `Message-ID` |
| 转账恰好执行一次 | **做不到**（跨服务） | hold id = transfer id + 版本号 |

**三个地方用了同一个公式。记住公式，比记住三个实现有用。**

### 值得背下来的三句

> `[9:47:57]` **"Redelivery isn't a rare accident, it's the design."**
> **译文**：重投不是罕见的意外，它就是设计。

> `[9:50:50]` **"the record, its lock and the send have to share one transaction, and Redis can't give us that."**
> **译文**：那条记录、它的锁、以及这次发送必须共享同一个事务，而 Redis 给不了我们这个。

> `[10:09:14]` **"the design goal is to make order not matter, and twice not matter."**
> **译文**：设计目标是让顺序不重要，也让"两次"不重要。

---

## 24. 自己动手

```bash
# 1. 把整条链跑起来（注意顺序：先发布者，后消费者）
make run-wallet &          # 建 wallet 流
make run-auth &
make run-transfer &        # 建 transfer 流
make run-notification &    # 只能连到已存在的流
open http://localhost:8025 # Mailpit

# 2. 一次成功转账 → 两封邮件（一封给 Alice，一封给 Bob）
#    看日志里的 stream / seq / delivery 三个字段

# 3. 破坏实验
docker compose stop mailpit
#    再转一笔 → 202，钱照动，日志里 "notification failed, retrying in ..."
docker compose start mailpit
#    下一轮重试 → 邮件到达

# 4. 死信
make dead-letters           # 列出没重放的
make replay-dead-letters    # 重放（注意：毒消息会再次失败并被保留）

# 5. 幂等（最值得亲手做的）
#    用 -notify-crash-after transfer.completed 重启通知服务
#    转一笔 → 崩溃 → 等 30 秒 AckWait → 重投
#    日志里应该出现 "already sent, skipping"，而 Mailpit 里只有一封
```

### 三个可以拿去问自己的问题

1. **如果把 `Deliver` 里的 `send()` 挪到事务外面**，第 ② 个崩溃窗口会变成什么？（提示：邮件永久丢失）
2. **如果 `AckWait` 设成和 `handle` 的 timeout 一样长**，会发生什么？（提示：`Nak` 和重投竞争）
3. **为什么 `deadLetter` 在写库失败时要 `Nak()`，而不是 `Term()`？**（提示：死信的可靠性必须 >= 消息的可靠性）

---

## 25. 下一集

> `[10:30:57]` but **with five services passing messages around, when something is slow or failing, where do you even look?** Next time: **observability — OpenTelemetry tracing across HTTP, gRPC and NATS, so one transfer is one trace; Prometheus metrics; dashboards in Grafana and Jaeger; and logs that carry trace IDs.**

> **译文**：但**有五个服务在传消息，当某个东西变慢或者出故障时，你到底去哪儿看？** 下一次：**可观测性——跨 HTTP、gRPC 和 NATS 的 OpenTelemetry 追踪，这样一次转账就是一条 trace；Prometheus 指标；Grafana 和 Jaeger 的仪表盘；以及带着 trace ID 的日志。**

💡 EP13 结束时，系统里有五个服务：`auth` / `wallet` / `transfer` / `gateway` / `notification`。

> 一次失败的转账会**跨过五个进程**，而**没有一个地方能看到全貌**。
>
> **这就是 EP14 要解决的问题**——而且它建立在一个前提上：**EP11 的事件信封里已经有了 `id`，EP13 的日志上下文中已经有了 `stream`/`seq`**。追踪不是凭空加的，它是**顺着已有的标识串起来的**。
