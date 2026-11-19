# EP11 讲义：NATS JetStream 与 Transactional Outbox

- **视频** `7:54:51 – 8:45:10`（50 分）｜分支 `ep11` ｜ diff：`+861 / -16`（22 个文件）
- **转录** `media/ep11.txt`（156 句，4,657 词）
- 时间戳是视频绝对时间

一句话：**两个系统不能一起提交，但可以把两次写变成一次写。**

> 这一集他会**当场让服务崩溃**，然后指着数据库说："这笔转账发生了，而全世界永远不会知道。"

---

## 0. 为什么不要直接调用

> `[7:55:52]` **Why events?** When money moves, other parts of the system care. **A notification service wants to tell Bob he got paid, fraud checks want to see every transfer, analytics wants all of it.**
> **译文**：为什么要事件？钱一动，系统的其他部分就关心。通知服务想告诉 Bob 他收到钱了，风控想看到每一笔转账，分析想要全部。

### 直接调用的三个问题

> `[7:56:22]` The direct way: **the wallet calls each of them right after the transfer.** But then:
> **译文**：直接的做法：钱包在转账之后立刻去调它们每一个。但那样的话：

| # | 问题 | 原话 |
|---|---|---|
| 1 | **同步等待** | `[7:56:29]` then the wallet **waits** for all of them |
| 2 | **级联故障** | `[7:56:29]` **fails when any of them is down** |
| 3 | **每加一个消费者就要改代码** | `[7:56:29]` **changes every time someone new wants to know** |

> `[7:56:41]` ...our **most important service ends up depending on our least important ones.**

**译文**：……我们**最重要的服务最终依赖了我们最不重要的那些服务。**

💡 这句话是全集的价值判断：**wallet 是核心，通知是外围。让核心依赖外围，等于让"发邮件失败"能拖垮"转账"。**

### 事件版的对比

> `[7:56:41]` As events, **the wallet does one thing: it states a fact** — "a transfer completed, and here's what happened" — **it publishes that to a stream, and it's done.** Whoever cares subscribes. **The wallet doesn't know who's listening, or how many, and it doesn't wait for anyone.** A notification service that's down for an hour **catches up when it's back**, and **a new consumer next year means zero changes to the wallet.**

> `[7:57:07]` **The price is eventual consistency**: Bob's notification arrives **a moment after** his money. But in the same request, for notifications, fraud alerts, and analytics, **that's exactly right.**

**译文**：**代价是最终一致性**：Bob 的通知在钱之后**片刻**到达。但同一个请求里，对通知、欺诈告警、分析来说，**这完全正确。**

### 事件不是命令（这句话很锋利）

> `[7:57:07]` And **notice an event isn't a command**. **"Send Bob an email" is a command** — it's addressed to someone, **and it couples us to them.** Ours — "transfer completed" — **is a fact, addressed to nobody in particular.**

**译文**：**注意事件不是命令。** **"给 Bob 发一封邮件"是命令**——它有收件人，**而且把我和那个收件人耦合起来。** 我们的——"转账完成"——**是一个事实，不针对任何特定的人。**

💡 判别方法：

| | 命令 | 事件 |
|---|---|---|
| 语气 | 祈使 | **过去时** |
| 收件人 | 有，明确的 | 无 |
| 加一个消费者 | 要改发送方 | **零改动** |
| 谁决定做什么 | 发送方 | **接收方** |

---

## 1. NATS 的两层：Core vs JetStream

> `[7:57:40]` NATS comes in **two layers**.
> **译文**：NATS 有两层。

| | **Core NATS**（纯消息） | **JetStream**（持久化层） |
|---|---|---|
| 消息活多久 | **只在飞行途中**，一瞬间 | **按我们说的时长存到磁盘** |
| 没人订阅时 | **丢了** | 存着 |
| 投递语义 | **at-most-once** | **at-least-once** |
| 重放 | **没有** | 从任意时间点重放 |
| 重复 | **你自己的问题** | **按 message id 帮你去重** |
| 宕机后 | 错过就错过了 | **消费者追上来** |

> `[7:58:30]` **Core is great for requests and live updates. For events about money, we want everything in the right-hand column.**

> `[7:58:50]` And **it's the same server, the same client, and the same subjects** — our stream simply **keeps** what it hears.

**译文**：而且**是同一个服务器、同一个客户端、同一套 subject**——我们的流只是**把听到的留住**。

💡 "同一个服务器"是关键：**JetStream 不是另一个产品，是 NATS 的一个开关**（`-js`）。所以从 Core 迁到 JetStream **不需要换技术栈**。

---

## 2. Subject 命名：三个决定

```
wallet.events.transfer.completed.v1
└─┬──┘ └─┬──┘ └──┬───┘ └──┬────┘ └┬┘
服务名   事件    聚合     动作   版本
```

> `[8:02:47]` **Events are facts, so always the past tense.** And **the version is in the name, because events live a long time.**

> `[8:03:09]` **A consumer can replay an event from last month, so a breaking change can't replace the old shape. It becomes a new type, published next to the old one, until every consumer has moved over.**

**译文**：**消费者可以重放上个月的事件，所以一个破坏性变更不能替换旧的形状。它变成一个**新的类型**，发布在旧的旁边，**直到所有消费者都迁移完。

💡 这是**事件和 API 最本质的差别**：

| | HTTP API | 事件 |
|---|---|---|
| 旧版本何时消失 | 部署即消失 | **可能永远活着**（有人还在重放） |
| 破坏性变更 | 改，或者 `/v2` | **必须是新 type，并与旧的并存** |
| 判断"能不能删" | 没人调了 | **没人重放了** |

### 通配符

> `[8:03:30]` ...all separated by dots, and subscribers can use **wildcards**: `*` matches **one** token, and `>` matches **everything after it**. So `wallet.events.transfer.>` is **every transfer event, in every version**.
> **译文**：……都用点分隔，而订阅者可以用通配符：* 匹配一个 token，> 匹配它之后的一切。所以 wallet.events.transfer.> 就是每一个转账事件，任何版本。

---

## 3. 流配置

> `[8:03:55]` ...the stream itself: its subjects `wallet.events.>`, **file storage** locally, **three in production** where JetStream keeps every message on three servers. **Retention by limits**: events stay for **30 days**, read or not, up to a **gigabyte**, **oldest out first**.
> **译文**：……流本身：它的 subject 是 wallet.events.>，本地用文件存储，生产上用三份，JetStream 把每条消息存在三台服务器上。按限制保留：事件留 30 天，不管读没读，上限一吉字节，最旧的先出。

> `[8:04:35]` **That's what lets a new consumer replay history, or a broken one catch up after a fix.**
> **译文**：这就是为什么新消费者能重放历史，或者一个坏掉修好之后能追上。

> `[8:05:00]` ...the **duplicate window** — the same message id the stream has seen in the last **10 minutes** is acknowledged, and dropped. **Remember that one — it saves us later.**
> **译文**：……重复窗口——同一个 message id 在最近 10 分钟内已经被这个流见过，就被确认并丢掉。记住这一条——它以后会救我们。

💡 最后那半句 "it saves us later" 就是 §6 的 outbox 去重机制。**这是他有意埋的伏笔。**

---

## 4. 现场制造双写问题（`8:09:26 – 8:12:53`）

### 4.1 第一版：commit 之后 publish

> `[8:07:42]` ...after `once` has returned — at this point **the transfer has committed, the money moved** — so now we tell everyone. The message **waits until the stream acknowledges that it stored the message**, so if it returns without an error, **the event is saved on disk**.
> **译文**：……在 once 返回之后——此时转账已提交，钱已经动了——所以现在我们去告诉所有人。消息会等到流确认它存下了这条消息，所以如果它没报错返回，事件就落盘了。

跑通了，`nats sub` 里看到：

```
received on wallet.events.transfer.completed : {...}
```

> `[8:09:26]` **It works. Ship it.** **Not so fast.**
> **译文**：它能用。发布吧。别急。

### 4.2 两次写的两个方向都错

**方向 A：先 commit，后 publish**

> `[8:09:45]` ...it writes to **two systems**: Postgres, then NATS. **Bob is never told, fraud never sees it, the analytics are wrong, and nothing in the system even knows that something is missing.**

**译文**：……它写**两个系统**：Postgres，然后 NATS。**Bob 永远不会被告知，欺诈检测永远看不到，分析数据是错的，而且系统里没有任何东西知道有东西丢了。**

💡 最后半句最要命：**静默丢失**。没有错误日志、没有失败指标、没有告警——因为**publish 这一步根本没执行到**。

**方向 B：先 publish，后 commit**

> `[8:10:05]` ...then the commit can fail, or the process can die before it, and **there's an event about money that never moved — a phantom.** **Bob gets told he was paid**, and there's nothing to point at in the ledger.

**译文**：……然后 commit 可能失败，或者进程在它之前死掉，于是**有一个关于"从未发生过的转账"的事件——一个幽灵。** **Bob 被告知他收到了钱**，而账本里找不到任何对应。

### 4.3 一个藏在代码里的陷阱

> `[8:10:27]` And **there's a trap in our own code**: inside `once`, right after the service's `Transfer` returns, **it looks like the transfer is done. It isn't — `once` commits later, together with the idempotency key.** **Publish in there, and you've written the phantom version without noticing.**

**译文**：而且**我们自己的代码里有个陷阱**：在 `once` 里面，就在 service 的 `Transfer` 返回之后，**它看起来像转账已经完成了。并不是——`once` 之后才提交，连同幂等键一起。** **在那里 publish，你就写下了幽灵版本，而且不会察觉。**

💡 **这是 EP7 的知识在 EP11 的第一次变现。** `service.Transfer` 返回 ≠ 事务已提交。EP7 教过你：**commit 发生在 `once`/`attempt` 的末尾。**

### 4.4 结论

> `[8:10:47]` **No order of the two writes is safe, because NATS doesn't join the transaction.** And **even where it exists** (distributed transactions), it **makes every transfer depend on both systems being up at the same moment, which is exactly the coupling we're trying to get rid of.**

**译文**：**两次写的任何顺序都不安全，因为 NATS 无法加入这个事务。** 而且**即使在有分布式事务的地方**，它**让每一笔转账都依赖两个系统同时在线——而这正是我们想摆脱的耦合。**

💡 注意他连"两阶段提交（2PC）"都堵掉了，理由不是"性能"，是**"2PC 恰好制造了你想消除的耦合"**。这是一个更高层的判断。

### 4.5 让崩溃变成必然

> `[8:11:29]` So let's **make it crash**. A flag — just for this demo — if `WALLET_CRASH_BEFORE_PUBLISH` is set, **the process exits, right between the commit and the publish.** A real crash can hit that same window; **we're just making it hit every time.**

演示结果：

> `[8:12:30]` So did that transfer happen? **Alice's balance: $20** — 50, minus 15, minus 15. **Both transfers, and the rest of the system will never hear about it.** **That's the dual write problem, live.**

**译文**：那笔转账发生了吗？**Alice 的余额：20 美元**——50 减 15 减 15。**两笔转账都发生了，而系统其余部分永远不会听说。** **这就是双写问题，现场演示。**

---

## 5. Outbox：把两次写变成一次

这是全集的中心思想：

> `[8:12:53]` The fix is a pattern called the **transactional outbox**. **We can't make two systems commit together, but we can turn two writes into one.**
> **译文**：修法是一个叫事务性 outbox 的模式。我们没法让两个系统一起提交，但我们可以把两次写变成一次。

> `[8:13:17]` In the **same database transaction** as the ledger entries **and the idempotency key**, [we write the event into an outbox table]. **A crash before the commit loses both** — which is fine, **nothing happened, so there's nothing to tell.** **A crash after it loses nothing.**
> **译文**：在和账本分录、以及幂等键同一个数据库事务里，我们把事件写进一张 outbox 表。提交前崩溃两个都丢——这没关系，什么都没发生，也就没什么要告诉别人的。提交后崩溃什么都不丢。

```
        ┌─ 一个 Postgres 事务 ────────────────┐
BEGIN → 分录 → 幂等键 → outbox 行 → COMMIT
                                        ↑
                        钱动了 ⟺ 事件被记下了
```

### 5.1 那"第二次写"去哪了？

> `[8:13:38]` Then **a relay, running in the background, reads the outbox and publishes each event to JetStream.** **That's still two writes** — publishing and marking as published — **but now we can retry**: the event's id as its **NATS message id**, and the stream's **duplicate window drops the copy.**

**译文**：然后**一个后台的 relay 读 outbox，把每个事件发布到 JetStream。** **那仍然是两次写**——发布，和标记已发布——**但现在我们可以重试**：用事件的 id 当作 **NATS message id**，而流的**去重窗口会丢掉副本。**

💡 这是全集最精巧的一步棋：**"两次写不安全"这个结论，只对"必须同时成功"的两个系统成立。** 如果第二次写**可以安全地重复**，那它就不再是双写问题，而是一个**幂等重试问题**——而 EP7 已经解决了那个。

| | 双写问题 | 幂等重试 |
|---|---|---|
| 前提 | 两次写必须同时成功 | 第二次可以安全重复 |
| 后果 | 丢一次 / 多一次 | 最终一致 |
| 谁解决 | 无解（除非 2PC） | **幂等键 / 消息 id** |

### 5.2 为什么不用 CDC

> `[8:14:20]` You may have heard of the other well-known answer, **change data capture**. **Outbox gets us there with one table and a page of Go.**

**译文**：你可能听说过另一个有名的答案，**变更数据捕获（CDC）**。**outbox 用一张表和一页 Go 代码就达到了同样的效果。**

💡 CDC 的代价：Debezium + Kafka Connect + 一个额外的集群 + 一个要运维的"读 binlog"的进程。**outbox 的代价：一张表 + 一个循环。**

### 5.3 Postgres 成为事件的真相来源

> `[8:13:59]` **Postgres becomes the source of truth for events too. NATS can be down for an hour, money keeps moving, and the events wait their turn.**

**译文**：**Postgres 也成为事件的真相来源。NATS 可以挂一个小时，钱照常流动，事件排队等它回来。**

---

## 6. outbox 表：四个设计

```sql
CREATE TABLE outbox (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     uuid        NOT NULL UNIQUE,
    subject      text        NOT NULL,
    payload      json        NOT NULL,          -- 注意：json 不是 jsonb
    published_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON outbox (id) WHERE published_at IS NULL;   -- partial
```

### ① `bigint identity` 的顺序 = 发布顺序

> `[8:15:08]` ...a `bigint identity`, **the order the events were written in, which is the order the relay publishes them in.**
> **译文**：……一个 bigint identity，事件被写入的顺序，也就是中继发布它们的顺序。

### ② `event_id` 唯一，并且**就是** NATS message id

> `[8:15:30]` The **event id, unique, which travels as the NATS message id.**
> **译文**：事件 id，唯一，它作为 NATS 的 message id 出行。

💡 一个字段服务三个目的：
1. 聚合内的唯一标识（消费者去重用）
2. NATS 去重的键
3. 幂等发布的凭证

**这就是 `Duplicate: 10 * time.Minute` 那个配置的用途。**

### ③ `json` 而不是 `jsonb`——这是故意的

> `[8:15:30]` ...the payload, **as JSON, not JSONB, and that's deliberate. JSONB is great for querying, but it reorders.**

**译文**：……payload，**用 JSON，不用 JSONB，这是故意的。JSONB 适合查询，但它会重排。**

💡 **`jsonb` 会规范化：去掉重复键、重排键顺序、去掉空白。** 而 outbox 的 payload 要**原样**发出去。如果被重排，那么"存进去的字节"和"发出去的字节"不一致——**重放就不再逐字节一致**（呼应 EP7 的 `byte for byte` 要求）。

**查询能力 vs 字节保真**，他选了后者。

### ④ partial index

> `[8:15:55]` The relay asks one question, all day long: **"what's unpublished, oldest first?"** **A partial index answers it**: only rows where `published_at IS NULL` are in it, **so once a row is published, it leaves the index. It stays tiny, even when the table holds millions of old events.**

**译文**：relay 整天只问一个问题："哪些还没发布，最老的在前？" **一个 partial index 回答它**：只有 `published_at IS NULL` 的行在索引里，**所以一行被发布之后它就离开索引。索引保持很小，即使表里存着几百万条旧事件。**

💡 这是 partial index 的教科书用法：**索引只覆盖"活跃工作集"**。和 EP5 的两个 partial unique index 是同一种技术，不同目的。

---

## 7. `LISTEN/NOTIFY`：为什么它是事务性的

> `[8:16:34]` And here's **the beautiful part: `NOTIFY` is transactional.** Postgres delivers it **when the transaction commits, never after a rollback**, and **once per transaction, however many events it wrote.**

> `[8:16:54]` **So the relay is only ever woken by events that really exist.**

**译文**：**`NOTIFY` 是事务性的。** Postgres **在事务提交时才投递它，回滚之后永不投递**，而且**每个事务一次，不管它写了多少事件。** **所以 relay 只会被真实存在的事件唤醒。**

💡 这是本集第二个"漂亮"的地方。对比一下轮询：

| | 纯轮询 | NOTIFY 唤醒 |
|---|---|---|
| 延迟 | 最多 5 秒 | **毫秒级** |
| 空转 | 一直查 | **不查** |
| 幽灵唤醒 | 不可能（只查存在的行） | **也不可能**（NOTIFY 也是事务性的） |

> `[8:16:54]` One caveat for later: **at very high write rates, the relay lags** — **the relay works either way.**
> **译文**：后面要注意一点：在极高写入速率下，中继会落后——中继两种情况都能工作。

💡 他主动标了这个限制：**NOTIFY 不能替代轮询**，因为高写入率下通知会挤爆。所以他的 `run` 循环是**两者都要**（见 §9）。

---

## 8. 事件的信封（envelope）

```go
type Event struct {
	ID          uuid.UUID       // uuid v7，时间有序
	Type        string          // "wallet.events.transfer.completed.v1"
	AggregateID uuid.UUID       // 事件发生在谁身上
	OccurredAt  time.Time       // UTC
	Data        json.RawMessage // 两级解码
}
```

### ① 为什么是 uuid v7

> `[8:17:39]` ...every event from every service travels in the same envelope: **an id — a version 7 UUID, so it's sorted by time** — **it's also the NATS message id, and what consumers use to recognize an event they've already handled.**
> **译文**：……每个服务的每个事件都走同一个信封：一个 id——version 7 UUID，所以按时间有序——它同时也是 NATS 的 message id，也是消费者用来认出「已经处理过」的那个东西。

💡 uuid v7 的前 48 位是毫秒时间戳，所以**按字节排序 ≈ 按时间排序**。这带来一个实际的性能好处：**索引插入是顺序的**（不像 v4 随机写导致页分裂）。

### ② `Data` 是 `json.RawMessage`，两级解码

> `[8:19:41]` ...and **the data as raw JSON** — **raw, so a consumer can decode the envelope first, and the data later, once the type says what it is.**

**译文**：……而**数据是原始 JSON**——**raw，这样消费者可以先解出信封，等 type 告诉它是什么之后，再解数据。**

💡 如果 `Data` 是 `any` 或具体的结构体，消费者就**必须先知道类型才能解信封**——鸡生蛋。`json.RawMessage` 让信封可以被**无类型地**读取。

### ③ 为什么用 JSON 而不是 protobuf（这是本集最好的取舍）

> `[8:18:20]` ...shaped by the type. **JSON, or protobuf?** **We use protobuf between our services, and it would work here too** — compact, typed, and **guarded by `buf breaking`**. **But events have a wider audience than our gRPC calls**: **other teams, a data warehouse, a script someone writes in Python next year.**

> `[8:19:01]` **What we give up: `buf breaking`. We replace it with two rules: only ever add fields within a version, and a breaking change is a new type — version two — published next to version one, until nobody reads version one anymore.**

**译文**：**我们放弃的是：`buf breaking` 的自动检查。我们换成两条规则：在一个版本内只允许新增字段；破坏性变更是一个新类型——version two——发布在 version one 旁边，直到没有人再读 version one。**

⚠️ **注意他放弃了什么**：一个**自动化的兼容性检查**，换成**两条必须靠人遵守的约定**。

| | protobuf + buf breaking | JSON + 两条规则 |
|---|---|---|
| 兼容性检查 | **自动**（CI 挂） | **人工 review** |
| 外部消费者 | 需要 proto 文件 + 代码生成 | **`jq` 就能读** |
| 数据仓库 | 需要 schema registry | **直接吃 JSON** |

💡 这和 EP6 的锁协议、EP3 的分层是同一个模式：**用约定换简洁，用测试和 review 兜底。**

### ④ 为什么 owner 要放进事件里

> `[8:20:26]` ...a deposit: the ledger transaction, the wallet, and the amount. A transfer: the transaction, **both wallets**, and the amount. **Notice the owners are in there, and that's a choice: a notification service needs to know whom to tell.** **If the event didn't, [it would have to call the wallet back].**

**译文**：……一笔存款：账本交易、钱包、金额。一笔转账：交易、**两个钱包**、金额。**注意所有者信息在里面，这是个选择：通知服务需要知道该告诉谁。** **如果事件里没有，[它就得回头调 wallet]。**

💡 **事件应该自足（self-contained）**。如果一个事件迫使消费者回调服务，那你就没摆脱耦合——**你只是把同步调用推后了一步。**

---

## 9. Relay：一个循环里的四个决定

### ① 代码放在 store 层，不放在 service

> `[8:21:29]` This lives next to the store, and **not in the service, because the store owns the transaction. The event has to be written by the same code that writes the money, through the same transaction.**

**译文**：它放在 store 旁边，**不在 service 里，因为 store 拥有事务。事件必须由写钱的那同一段代码、通过同一个事务来写。**

💡 和 EP6 里 `Store.Transfer` 拥有锁是同一个理由：**"需要事务的东西"决定"代码放在哪"。**

### ② `SKIP LOCKED`：多个 relay 自然分担

> `[8:26:40]` ...**`SKIP LOCKED` is what lets it scale.** If another wallet instance is relaying and **has locked some rows, we don't wait for them — we skip them.** So **five wallet instances are five relays sharing the work, never publishing the same row at the same moment.**

**译文**：……**`SKIP LOCKED` 是让它可扩展的东西。** 如果另一个 wallet 实例正在 relay 并**锁住了一些行，我们不等它——跳过它们。** 所以**五个 wallet 实例就是五个 relay 分担工作，永远不会在同一刻发布同一行。**

⚠️ 但代价立刻来了：

> `[8:27:23]` ...with several relays, **the order across instances isn't strict anyway, which is one more reason consumers shouldn't depend on it.**

**译文**：……有多个 relay 时，**跨实例的顺序本来就不是严格的，这是消费者不该依赖顺序的又一个理由。**

💡 `SKIP LOCKED` + 多实例 = **放弃了全局顺序**。这是一个必须显式接受的代价。

### ③ 崩溃点分析（他的招牌动作）

> `[8:24:49]` **For every step the question is: what if we crash right after it?**
> **译文**：对每一步，问题都是：如果我们在它之后立刻崩溃会怎样？

| 崩溃点 | 结果 | 下次运行 |
|---|---|---|
| `SELECT` 之后 | 没发生任何事，事务死掉，锁释放 | **找到同样的行** |
| **发布之后、commit 之前** | **事件已在流里，但未标记** | **再发一次 → 被 msg id 去重** |
| commit 之后 | 已发布 + 已标记 | 跳过 |

> `[8:25:13]` ...**that's the idea**: and [the stream] drops the copies, **so the stream stores each event once — effectively once.** **And consumers must still be idempotent**: JetStream **redelivers to consumers too**, and **a copy can arrive after the window**.

**译文**：……**这就是思路**：流丢掉副本，**所以流对每个事件只存一次——"有效地一次"。而消费者仍然必须幂等**：JetStream **也会向消费者重投**，而且**一个副本可能在窗口之后才到**。

💡 **"effectively once" 是一个诚实的说法。** 真正的 exactly-once 投递不存在（在分布式系统里）。能做的只有：**at-least-once 投递 + 幂等消费 = 有效上的一次**。

### ④ `run` 循环的三路等待

> `[8:28:48]` ...**and a full batch means there may be more, so we go again right away.** **Otherwise wait for one of three things: shut down, wake up from Postgres, or the timer** — **which doubles every time there was nothing, so a broken NATS doesn't get hammered.**

**译文**：……**而且一个满批次意味着可能还有更多，所以我们立刻再来一次。** **否则等三件事之一：关闭、被 Postgres 唤醒、或者定时器**——**它在每次无事可做时翻倍，这样一个坏掉的 NATS 不会被猛锤。**

```
select {
case <-ctx.Done():          return          // 关闭
case <-notify:              /* 立刻再查 */   // NOTIFY
case <-time.After(backoff): /* 查一次 */     // 定时器，空闲时翻倍
}
```

💡 **三路等待 = 低延迟 + 低空转 + 优雅退出的组合**。缺任何一路都会出问题：

| 缺 | 后果 |
|---|---|
| 缺 `ctx.Done()` | 关不掉，SIGTERM 卡住 |
| 缺 NOTIFY | 最坏 5 秒延迟 |
| 缺 定时器 | NATS 恢复后永远不知道（NOTIFY 只在有写入时来） |

### ⑤ Notice：`run` 循环的第四路

> `[8:29:29]` ...meanwhile, `run` still polls. **The notifications make the relay fast, but nothing depends on them.** `waitForNotifications` takes a connection from the pool **and hijacks it**, a connection that `LISTEN outbox`, and waits. **Each notification sends a wake-up without blocking; if one is already waiting, that's enough.**

**译文**：……同时，`run` 仍然轮询。**通知让 relay 变快，但没有任何东西依赖它们。** `waitForNotifications` 从池里拿一条连接**并劫持它**，在那条连接上 `LISTEN outbox` 然后等待。**每个通知非阻塞地发一个唤醒；如果已经有人在等，就够了。**

💡 **"hijack"** 是个准确的词：这条连接从此不能还给池，不能跑别的查询。所以：

> `[8:29:29]` ...if it fails we log it and try again five seconds later.
> **译文**：……如果失败我们就记一笔，五秒后再试。

⚠️ 劫持连接意味着**池的有效容量 -1**。如果你把 `MaxConns` 设成 2，relay 就吃掉了半个池。

### ⑥ 放在哪个进程里跑

> `[8:30:14]` Where should the relay run? **Inside the wallet's process as a goroutine** — **one binary to ship, it scales with the wallet**, and `SKIP LOCKED` shares the work between instances. **Or as a separate service** — it reads the wallet's database anyway. **We'll start inside the wallet**, and **the relay is its own package, so moving it out later is a new `main.go`, and nothing else.**
> **译文**：中继该跑在哪？在钱包进程里作为一个 goroutine——只有一个二进制要发布，它随钱包一起扩缩，而 SKIP LOCKED 在实例之间分活。或者作为一个独立服务——反正它读的是钱包的数据库。我们先从钱包内部开始，而中继是它自己的包，所以以后搬出去只是一个新的 main.go，别的都不用动。

### ⑦ 用独立的 context

> `[8:30:57]` In `main`, right after the idempotency cleanup, the relay gets **a context of its own, not the one that ends on Ctrl-C**. **Requests that are still finishing the readiness check** — with the outbox, **the wallet can take money while NATS is down, so it should keep taking traffic.** **And once the servers have stopped, we stop the relay, and wait for it.** If it was in the middle of a batch, **the batch rolls back, and those events go out on the next start.**
> **译文**：在 main 里，紧接幂等清理之后，中继拿到自己的 context，不是那个在 Ctrl-C 时结束的。还在完成就绪检查的请求——有了 outbox，钱包可以在 NATS 挂着的时候收钱，所以它应该继续收流量。而服务器停下之后，我们停中继，并等它。如果它正停在一批中间，那一批回滚，那些事件在下次启动时发出去。

💡 **关闭顺序**：HTTP 停 → relay 停 → 池关。而且 relay 的 ctx **不能**和 HTTP 的 ctx 共享，否则 HTTP 停止时 relay 也跟着死——**但那时可能还有事件没发完。**

---

## 10. 演示：把 NATS 停掉

> `[8:32:40]` Now the real test: **NATS goes down.** Alice pays Bob again — **201, money still moves, with NATS down.** **That's the outbox in one picture**: the wallet sends, then the relay fails to publish and tries again.
> **译文**：现在真正的测试：NATS 挂了。Alice 又付给 Bob——201，钱照动，NATS 挂着。这就是 outbox 的一张图：钱包发送，然后中继发布失败并重试。

> `[8:33:01]` `outbound buffer limit exceeded` is the client's way of saying **"I'm disconnected, and you turned my buffer off"** — exactly what we asked for. And **look at the timestamps: the waits double, on their way up to 5 seconds.**
> **译文**：outbound buffer limit exceeded 是客户端在说「我断开了，而你把我的缓冲区关了」——正是我们要的。看时间戳：等待在翻倍，一路涨到 5 秒。

> `[8:33:41]` And the event [appears] in the watching terminal, **which reconnected to** — **not a single event lost, and nobody had to do anything.** The outbox agrees: **all five published.**

💡 `outbound buffer limit exceeded` 那个报错来自 EP11 开头 `[8:00:41]` 的设置：

> `[8:00:41]` ...one setting most people miss: **the reconnect buffer. By default, while it's disconnected, the client keeps up to 8 seconds** [of messages]. **We turn it off: a publish while disconnected fails right away, honestly.**

**译文**：……一个大多数人会漏掉的设置：**重连缓冲。默认情况下，在断开期间客户端最多攒 8 秒**的消息。**我们关掉它：断开时发布立刻诚实地失败。**

💡 为什么关掉是**对的**：

| | 默认（缓冲） | 关掉（立即失败） |
|---|---|---|
| 断线时 publish | **假装成功**，攒在内存里 | **立刻报错** |
| relay 的行为 | 以为发布了 → **标记 published → 事件永久丢失** | **返回错误 → 回滚 → 重试** ✅ |

**这是一个"让错误尽早暴露"的设置**，而且如果没关，outbox 的整个正确性会被破坏——**因为 relay 会以为发成功了。**

---

## 11. Durable Consumer

> `[8:34:00]` ...**a durable consumer has a name, and lives on** [JetStream]. **First event: the stream.** Explicit acks: **we confirm every message, and if we don't within the AckWait, 30 seconds, it's delivered again.** `MaxDeliver` **caps the attempts, so a message that always fails can't loop forever** — **in episode 13, those go to a dead letter queue.**
> **译文**：……持久消费者有名字，而且活在 JetStream 上。第一个事件：流。显式 ack：我们确认每条消息，如果我们在 AckWait 30 秒内没确认，它会被再投一次。MaxDeliver 给尝试次数封顶，所以一条总是失败的消息不会永远循环——第 13 集里，那些会去死信队列。

> `[8:34:47]` And **since a message can arrive more than once**, a tiny consumer, to see the moving parts: `cmd/eventlog`.
> **译文**：而既然一条消息可能到达不止一次，一个很小的消费者，用来看清各个部件：cmd/eventlog。

```go
// 关键配置
DeliverAll           // 从头开始
AckExplicit          // 显式 ack
AckWait: 30s
MaxDeliver: 5
```

### Pull consumer，不是 push

> `[8:36:35]` ...and ack it, which moves the consumer forward. **This is a pull consumer: the client asks for messages when it's ready, so a slow consumer never gets flooded.**

**译文**：……然后 ack 它，这会把消费者往前推。**这是一个 pull 消费者：客户端在准备好的时候才要消息，所以一个慢消费者永远不会被淹没。**

💡 `push` vs `pull`：

| | push | pull |
|---|---|---|
| 谁控制速率 | 服务器 | **客户端** |
| 慢消费者 | 积压/被淹没 | **自然背压** |
| 适合 | 低延迟少量 | **批处理、慢任务** |

### 一个必须知道的细节：sequence 永不回退

> `[8:37:40]` ...the wallet stream, with **4 messages, starting at sequence 2, because a purge removes messages, but sequence numbers never go back.**

**译文**：……wallet 流有 **4 条消息，从 sequence 2 开始，因为 purge 会删掉消息，但序号永不回退。**

💡 **sequence 是单调递增的游标，不是索引。** 所以你不能用 "sequence == 1" 判断是不是第一条。

---

## 12. 测试的两个技巧

### ① 每个测试自己的临时表

> `[8:40:10]` ...a **temporary table copied from the real one. A temporary table is only visible to the connection that created it, and it hides the real table of the same name.** So for this relay, **the outbox holds our events, and nobody else's.**

**译文**：……一个**从真表复制来的临时表。临时表只对创建它的连接可见，并且会遮蔽同名的真表。** 所以对这个 relay 来说，**outbox 里只有我们的事件，没有别人的。**

💡 两个都是必要的：
- **`TEMP`** → 自己可见 → 不污染别人的数据
- **同名遮蔽** → relay 里写死 `FROM outbox` 的 SQL **不用改**，就自动指向临时表

代价：**池必须恰好一条连接**（否则 relay 可能拿到别的连接，看不到临时表）。他明说了这一点（`[8:40:10]`）。

### ② 每个测试自己的 stream

> `[8:40:54]` ...**every test has its own stream, and its own table, so they can all run in parallel.**

### ③ 那个核心断言

> `[8:41:15]` ...**it looks after a relay published a batch and died before its commit: publish again. Every event goes out a second time, and the stream must still hold three messages, not six.** `expectStream` checks the account, and **reads each message back by its sequence number, comparing its NATS message id with the event's id.**

**译文**：……它模拟**一个 relay 发布了一批然后 commit 前死掉：再发布一次。每个事件都出去了第二次，而流必须仍然只持有三条消息，不是六条。** `expectStream` 检查计数，并**按 sequence 号把每条消息读回来，比对它的 NATS message id 和事件的 id。**

💡 这个测试**直接验证了"两次写变得安全"这件事**，而不是验证"代码调用了 publish"。

---

## 13. 他承认的债

> `[8:42:18]` One thing to know: **the wallet's tests write events into the outbox of our development database**, so **the next time you start the wallet, it publishes them.** They're all test wallets, so **it's harmless here**.
> **译文**：有一点要知道：钱包的测试会把事件写进我们开发数据库的 outbox，所以你下次启动钱包，它会把它们发出去。它们都是测试钱包，所以在这里无害。

⚠️ 这是 EP3 那笔债的**第二次收利息**（第一次在 EP5 的迁移）。这次的表现是：**开发库的 outbox 里会积累测试事件，然后真的被发布到 NATS。**

生产环境不会这样（因为是不同的库），但如果哪天有人在 staging 上跑集成测试，**staging 的 NATS 流里就会混进测试事件。**

---

## 14. 我的补注

### ① outbox 表会无限增长

`published_at` 不为空的行**永远不会被删**。他提了一句（`[8:28:03]`）：

> ...in production, a cleanup job deletes the ones older than a week, like the one for idempotency keys.

**但这一集里没有这个 job。** 所以手工清：

```sql
DELETE FROM outbox WHERE published_at < now() - interval '7 days';
```

判断标准：**表大小 = 写入速率 × 保留期**。每秒 100 个事件 × 7 天 ≈ 6000 万行。**这不是小数目。**

### ② 去重窗口 10 分钟 vs relay 的退避上限 5 秒

这两个数字其实**不太匹配**：

| 参数 | 值 |
|---|---|
| NATS `Duplicates` | **10 分钟** |
| relay 最大退避 | **5 秒** |

安全的原因：**relay 的重试间隔永远小于去重窗口**。但如果 NATS **挂了一个小时**，那么恢复后的事件**都在窗口之外**——**但那时它们还没被发布过，所以不需要去重。**

真正的风险是：**relay 发布成功但不小心重试超过 10 分钟之后**（比如一个批次特别大、或者程序被暂停）。此时重复就会漏过去 → **消费者必须幂等**。

**他说了这句话**（`[8:25:13]` "consumers must still be idempotent"），但值得你自己算一遍。

### ③ `LISTEN/NOTIFY` 的三个生产陷阱

**a) payload 上限 8000 字节，且不能跨库**。他只用它做"唤醒信号"（不带数据），这是正确用法。

**b) 连接断线后 LISTEN 会静默失效**。他的 `recent()` 那个定时器就是在兜这个（`[8:29:08]` "keeps a listening connection alive, if it fails we log it and try again five seconds later"）。

**c) 别用池里的连接做 LISTEN**。他明确"劫持"了一条专用连接。

```go
// 正确：专用连接
conn, _ := pool.Acquire(ctx)     // 且永不 Release
```

### ④ "effectively once" 的完整链条

把他的设计串起来看，每一环都在防一个具体的失败：

```
写钱 + 写 outbox        同一事务    → 不会丢事件，不会幽灵事件
relay 发布              可重试 + msg id → 重复被流吸收
流 → 消费者             at-least-once  → 可能重复
消费者                  幂等           → 重复无害
────────────────────────────────────────────────────
结果：effectively once
```

**任何一环去掉，结论就崩。** 这就是为什么 EP13 还要做死信队列、EP15 还要做不变量测试。

---

## 15. 自测题

1. 直接调用的三个问题是什么？"最重要的服务依赖最不重要的服务"具体怎么发生？
2. 事件和命令的三个区别？举一个"看起来像事件其实是命令"的例子。
3. Core NATS 和 JetStream 在六个维度上的差别？
4. 为什么事件名里必须有版本号？（提示：重放）
5. 先 commit 后 publish、先 publish 后 commit，各自的失败模式是什么？为什么两种都不行？
6. `service.Transfer` 返回之后、`once` 返回之前 publish，会发生什么？
7. outbox 的"两次写"为什么不再是双写问题？
8. 为什么 payload 用 `json` 而不用 `jsonb`？
9. `NOTIFY` 为什么是事务性的？它带来什么保证、什么限制？
10. 事件的 `Data` 为什么是 `json.RawMessage`？
11. 为什么放弃 protobuf 而用 JSON？放弃的自动化检查换成了哪两条约定？
12. `SKIP LOCKED` 带来什么好处、什么代价？
13. relay 的 `run` 循环为什么要等**三**件事？缺任何一件会怎样？
14. 关掉 NATS 客户端的 reconnect buffer，为什么是 outbox 正确性的必要条件？
15. "effectively once" 的链条有哪四环？去掉消费者幂等会怎样？
