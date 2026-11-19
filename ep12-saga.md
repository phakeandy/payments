# EP12 讲义：Saga —— 转账从一个事务变成一个过程

- **视频** `8:45:12 – 9:42:49`（58 分）｜分支 `ep12` ｜ diff：`+2923 / -80`（41 个文件，全课程最大）
- **转录** `media/ep12.txt`（188 句，5,903 词）
- 时间戳是视频绝对时间

一句话：**你没法让一步"恰好发生一次"，但你可以让它"发生两次也安全"。**

> 这是全课程技术含量最高的一集。它把"转账"从**一个数据库事务**变成一个**有状态的、可崩溃、可恢复的过程**。

---

## 0. 为什么转账需要自己的服务

> `[8:46:23]` Right now, a transfer is **one database transaction inside the wallet**. That works **because both wallets live in one database**. But **a real transfer is a process**:

```
① 接受它
② 把钱冻结（hold）
③ 跑风控检查          ← EP19
④ 付给收款人（capture）
⑤ 通知他              ← EP13
```

> `[8:46:42]` **Each step can fail on its own** — a frozen wallet, a service that's down, a timeout. **Some take time**: milliseconds today, **a manual review tomorrow**. And **somebody has to own the whole thing and answer "where is my transfer?"**

**译文**：**每一步都可能自己失败**——钱包被冻结、服务宕机、超时。**有些步骤要花时间**：今天是毫秒，**明天可能是一次人工审核**。而且**必须有某个东西拥有整个过程，并能回答"我的转账到哪了？"**

> `[8:47:06]` That's the transfer service, **on port 8083, with its own database**. **It owns the process; the wallet still owns the money.**

**译文**：这就是 transfer 服务，**端口 8083，有自己的数据库**。**它拥有过程；wallet 仍然拥有钱。**

💡 这句话划了一条极其重要的边界：**"流程的所有权"和"数据的所有权"是分开的**。transfer 服务知道"这笔转账走到哪一步"，但它**永远不碰余额**。

---

## 1. 为什么不用两阶段提交（2PC）

> `[8:47:27]` The textbook answer for atomic work across systems is a **distributed transaction — two-phase commit**: a coordinator asks every participant to **prepare**, and once they all say yes, tells them to **commit**. **But**:

| # | 2PC 的问题 | 原话 |
|---|---|---|
| 1 | **持锁跨网络** | `[8:47:46]` prepared participants **hold their locks across the network** waiting for the slowest |
| 2 | **协调者挂掉 → in-doubt** | `[8:47:46]` if the coordinator dies after prepare, **they are stuck in doubt, still holding those locks** |
| 3 | **参与者必须都说这个协议** | `[8:48:06]` **NATS doesn't, HTTP APIs don't, and your bank certainly doesn't** |
| 4 | **必须同时在线** | `[8:48:06]` and **all of them must be up at the same moment, for every transfer** |

> `[8:48:06]` **Each service owns its data, and no transaction spans them. We need a different tool.**

💡 第 4 条和 EP11 里他说 2PC 的理由完全一样（`[8:10:47]`）：

> **even where it exists, it makes every transfer depend on both systems being up at the same moment, which is exactly the coupling we're trying to get rid of.**

**跨服务原子性和"服务独立可用"是根本矛盾的。** 你只能在两者中选一个。

---

## 2. Saga：1987 年的答案

> `[8:48:24]` That tool is a **saga**, from a **1987 paper about long-lived transactions**: **a sequence of local transactions, each committed on its own.** Ours: **hold** Alice's $15, then **capture** them into Bob's wallet. **If a step fails for good** — say Bob's wallet is frozen — **we undo what already happened, backwards: release the hold.**

### 2.1 补偿不是回滚

> `[8:49:03]` **Each step commits in its own service, and each has a compensation — a business action, not a rollback, so it must always work.**

**译文**：**每一步在自己的服务里提交，每一步都有一个补偿动作——一个业务动作，不是回滚，所以它必须永远能成功。**

💡 这是 saga 和事务最本质的区别：

| | 事务回滚（ROLLBACK） | saga 补偿（compensation） |
|---|---|---|
| 谁执行 | 数据库 | **你的业务代码** |
| 会失败吗 | **不会**（只是丢掉未提交的改动） | **可能会**（它是一个真实的业务操作） |
| 例子 | `ROLLBACK` | **`release`：把钱还回去** |

**如果你的补偿是一个普通业务操作，它就可能失败**（钱包被冻结、币种不对、余额不足……），而那时你已经无法撤销前面的步骤了。这就是为什么 §3 的 hold 设计如此重要。

### 2.2 没有隔离性

> `[8:49:03]` And **there's no isolation: in-between states are visible, so [the design] must be designed for them.**

> `[8:49:21]` **In exchange, every saga finishes: all of it happened, or all of it was undone.**

**译文**：**而且没有隔离性：中间状态是可见的，所以必须为它们做设计。** **作为交换，每一个 saga 都会结束：要么全都发生了，要么全都被撤销了。**

💡 两个性质要分清：

- **原子性**：saga **保留了**（全成或全撤）✅
- **隔离性**：saga **放弃了**（中间状态可见）❌

所以 `pending`、`funds_held`、`compensating` 这些状态**必须能被外部看到**——那不是实现细节，那是契约的一部分。EP13 的通知服务就要处理"一笔转账最后变成 reversed"。

---

## 3. 编排 vs 协同（orchestration vs choreography）

> `[8:49:21]` Two ways to run a saga: with **orchestration**, one orchestrator decides each next step from the saga state. With **choreography**, each service reacts to the previous one's event.

| | 编排（orchestration） | 协同（choreography） |
|---|---|---|
| 状态在哪 | **一行** | 分散在各服务的消费位点 |
| 「我的转账在哪」 | `[8:49:39]` **one query**, not a hunt through four services' logs | 要去翻四个服务的日志 |
| 加一步 | **一处改动** | 改两个服务（发+收） |
| 代价 | `[8:49:58]` **耦合：编排者知道每一步** | 没人知道全局 |

> `[8:49:58]` **For money, with a strict order and compensations, we want one place that owns the state: easy to reason about, and to watch.** So **we orchestrate transfers**, and **episode 14's notifications will be choreography** — each where it fits.

**译文**：**对钱来说，有严格顺序和补偿，我们要一个地方拥有状态：容易推理，也容易观察。** 所以我们**编排转账**，而**第 14 集的通知会用协同**——各取所长。

💡 这一段的价值在于：**他不认为其中一个更好。** 判据是"有没有严格顺序和补偿需求"：

- **有顺序 + 有补偿** → 编排（钱）
- **无顺序 + 只是"有人关心"** → 协同（通知）

---

## 4. 为什么是 hold，而不是直接 debit/credit

这是全集最漂亮的设计论证（`8:50:34 – 8:51:32`）。

### 朴素版本

```
step 1: debit Alice
step 2: credit Bob
补偿:   反向一步
```

> `[8:50:34]` **But then step 1 already puts the money in Bob's wallet. He can spend it right away. And the compensation, taking it back, can fail.**

**译文**：**但那样第 1 步就已经把钱放进 Bob 的钱包了。他可以立刻花掉。而补偿——把它拿回来——可能失败。**

三个具体后果：
1. Bob 立刻能花 → 事后拿不回来
2. 补偿是"从别人账户扣钱" → **这个操作会失败**（余额不足、被冻结）
3. 补偿失败 → **saga 永远结束不了**

### hold 版本

```
step 1: hold    —— Alice 的钱进 hold 账户（Alice 余额立刻下降）
step 2: capture —— hold 账户 → Bob 钱包   ← 唯一不可撤销的一步，放最后
补偿:   release —— hold 账户 → Alice 钱包
```

> `[8:50:54]` With a **hold**, **step 1 moves the money into a hold we control, and Alice's balance drops at once, so she can't spend it twice.** **It costs a table, an account, and three RPCs.** **It buys the rule that matters most in a saga: a compensation must never fail for a business reason.**

**译文**：用 **hold**，**第 1 步把钱移进一个我们能控制的 hold 里，Alice 的余额立刻下降，所以她不能花两次。** **代价是一张表、一个账户、三个 RPC。** **换来的是 saga 里最重要的那条规则：补偿绝不能因为业务原因失败。**

> `[8:51:14]` **The money stays in our hands until the one step that can't be undone — the capture, which comes last.**

**译文**：**钱一直留在我们手里，直到那个不可撤销的步骤——capture，它放在最后。**

💡 这一段的推理链值得反复看：

```
补偿可能失败        ← 问题的根源
  ↓ 所以
补偿必须是"我方账户 → 原路返回"
  ↓ 所以
钱必须先进入"我方账户"
  ↓ 所以
需要 hold 这个中间账户
  ↓ 而且
release（我方 → Alice）永远能成功，即使 Alice 的钱包被冻
  ↓ 结论
capture 必须最后，而且它不需要补偿
```

**"补偿必须永远能成功"这条规则，倒推出了整个 hold 设计。**

---

## 5. hold 是**真实的账本交易**

> `[8:54:24]` ...**a hold is a real ledger transaction**: from Alice's wallet **to a system account called `holds`**, one per currency. **That's money we owe someone before we know whom.**

**译文**：……**一个 hold 是一笔真实的账本交易**：从 Alice 的钱包**转到一个叫 `holds` 的系统账户**，每个币种一个。**那是我们还不知道欠谁的、但已经收下的钱。**

```
                借方              贷方
Alice 钱包      −1500
holds 账户                        +1500     ← debit-normal，所以这是"我们持有"
```

💡 这是 EP5 的 settlement 账户的**第二次应用**：

| 系统账户 | 什么时候用 | 语义 |
|---|---|---|
| `settlement` | 充值 | 外部世界 → 我们 |
| **`holds`** | **转账中** | **我们持有，但归属未定** |

而且它继承了 EP2 的全部保证：**借贷必须平衡、只能追加、余额由视图推导**。hold 不是一张"特殊的表"，它是**一笔普通的账本交易 + 一条元数据**。

### 5.1 hold 表的 CHECK 约束

```sql
-- 一个 hold 处于 held 状态，当且仅当它没有 settled_transaction_id
CHECK ((status = 'held') = (settled_tx IS NULL))
```

> `[8:54:02]` ...a check, **a hold is `held` exactly when it has no settled transaction — like the ledger, it makes a half-settled hold impossible to store.** Held money **has to sit somewhere in the ledger; debits and credits must always balance.**

**译文**：……一个检查，**一个 hold 处于 held 状态，当且仅当它没有结算交易——和账本一样，它让"半结算的 hold"无法被存储。** 被冻结的钱**必须在账本里某处存在；借方和贷方必须永远平衡。**

💡 注意这个 CHECK 的**结构**和 EP5 的 `CHECK ((kind='wallet') = (owner_id IS NOT NULL))` 一模一样：**两个字段的取值必须一致**。这是他第三次用这个技巧。

### 5.2 `frozen` 列

> `[8:54:46]` And a new column, **`frozen`**. **A frozen wallet can't send or receive money** — a dispute, a compliance check. **It's what we'll use to make a transfer fail halfway**, and episode 19 builds on it.

---

## 6. 三层错误分类：`no` vs `not now`

> `[8:56:18]` ...and the rules a hold can break: **a frozen wallet, a currency mismatch, a hold that's already settled**. These are **rule errors**, so they reach the gRPC client as **FAILED_PRECONDITION, with a reason it can branch on**.

> `[8:56:39]` **That reason matters: it's how the transfer service will tell "no" from "not now".**

**译文**：**那个 reason 很重要：transfer 服务靠它区分"不行"和"现在不行"。**

```go
func rejection(err error) error {
	switch {
	case isFailedPrecondition(err):   // insufficient_funds, wallet_frozen, ...
		return Rejection{err}          // 永久：不重试，走补偿
	case isNotFound(err), isInvalidArgument(err):
		return Rejection{err}          // 也不会变：不重试
	default:
		return TemporaryError{err}     // 可能变好：重试
	}
}
```

| 分类 | 例子 | saga 的动作 |
|---|---|---|
| **rejection**（永久） | 余额不足、钱包冻结、币种不符 | **不重试** → 走向补偿/失败 |
| **temporary** | 超时、服务不可用、连接断开 | **重试**（带退避） |
| **stale** | 版本不匹配 | 别人先动了 → 放弃本次写入 |

💡 这个三分类是 saga 正确性的核心。**把"钱包冻结"当临时错误 → 无限重试 → 永远不结束。把"超时"当永久错误 → 提前补偿 → 但钱可能已经动了。**

---

## 7. 三个 RPC 的不对称（每一处都有理由）

### ① `hold`：按用户查询钱包

> `[8:56:59]` ...finds the wallet, **as the user, so other people's wallets don't exist.**

### ② `capture`：**不**检查 owner

> `[9:01:32]` ...notice what's missing: **capture doesn't take an owner. Anyone's wallet can receive money**, like with the transfer.

### ③ `release`：**什么都不检查**

> `[8:59:33]` ...**a release doesn't check anything. Giving money back must always work, even into a frozen wallet. That's the compensation rule in code.**

**译文**：……**release 什么都不检查。把钱还回去必须永远能成功，即使是还进一个被冻结的钱包。这就是补偿规则在代码里的样子。**

💡 **这一行代码是整集设计哲学的最浓缩表达**。对比：

| | 检查 | 为什么 |
|---|---|---|
| `hold` | 余额、冻结、币种、owner | 这是**开启**一个承诺，必须严格 |
| `capture` | 收款方币种、收款方冻结 | 钱要进新地方，要验证目的地 |
| **`release`** | **什么都不检查** | **撤销承诺必须无条件成功** |

### ④ 双向都错的场景

> `[8:58:58]` ...if it was settled the **other** way, **that's an error: capturing a released hold would create money, and releasing a captured one would take it from Bob.**

**译文**：……如果它是以**另一个方向**结算过的，**那是错误：capture 一个已 release 的 hold 会凭空造钱，而 release 一个已 capture 的会从 Bob 那里拿走钱。**

| 尝试 | 若允许 | 后果 |
|---|---|---|
| capture 已 released 的 hold | hold 账户已经空了 | **凭空造钱** |
| release 已 captured 的 hold | 钱已经在 Bob 那里 | **从 Bob 拿钱** |

**同方向 = 重试（幂等，返回原样）。反方向 = 错误。** 这个区分是靠 `settled_tx` 和 status 一起判断的。

---

## 8. `place_hold`：一个事务里的四步

> `[8:57:35]` First **the same lock a transfer takes on the wallet**, so **only one movement out of it happens at a time**. Then **is there a hold with this ID already? If there is, this is a retry** — we check it's the same request, the same wallet and amount, **and return the hold as it is.** **Nothing moves twice.** If there isn't, **we check the balance, under the lock, exactly like a transfer**, [then write] a ledger transaction: a debit to the wallet, a credit to the hold's account, and the hold itself pointing at that transaction. **Both commit together, or neither does.**

**译文**：首先**拿和 transfer 一样的钱包锁**，这样**同一时刻只有一笔钱出去**。然后**是否已经有这个 ID 的 hold？有的话这就是一次重试**——我们检查它是不是同一个请求（同钱包、同金额），**然后原样返回那个 hold。没有任何东西动两次。** 如果没有，**我们在锁下检查余额，和 transfer 完全一样**，[然后写] 一笔账本交易……**两者一起提交，或者都不提交。**

### 幂等键是白送的

> `[8:52:32]` ...**the hold's ID chosen by the caller is its idempotency key.** ...the transfer service will use **the transfer's own ID**, **which makes it the idempotency key for free.**

**译文**：……**调用方选择的 hold ID 就是它的幂等键。** ……transfer 服务会用**转账自己的 ID**，**这让幂等键免费。**

💡 这是 EP7 的第三次应用，而且是**最优雅的一次**：不需要额外的 `Idempotency-Key` header，不需要一张幂等表——**业务实体本身的 ID 就是幂等键**。

| 实体 | ID 从哪来 | 幂等键 |
|---|---|---|
| 幂等表（EP7） | 客户端 header | `(scope, key)` |
| transfer | 客户端 header | `(user, idempotency_key)` |
| **hold** | **transfer 的 ID** | **hold.id** |

---

## 9. transfer 表：为什么 state 是 `text` 不是 `enum`

> `[9:04:08]` ...the state, **as text with a check constraint listing every state.** **Why not an enum, like the wallet's?** **Postgres can add a value to an enum, but never remove or rename one, and this list will change as the saga grows.**

**译文**：……状态，**用 text 加一个列出所有状态的 check 约束。为什么不像 wallet 那样用 enum？** **Postgres 可以往 enum 里加值，但永远不能删或改名，而这个列表会随着 saga 长大而变化。**

💡 **这是全课程里对 EP2 那个决定最直接的一次修正**。回顾 EP2：

> `entry_direction` 用了 enum（`debit` / `credit`）——因为它**永远不会变**（复式记账的定义）。
> `transfer.state` 用了 text + check —— 因为它**会变**。

**同一个作者，两种选择，判据是"这个集合会不会增长"。**

| | enum | text + CHECK |
|---|---|---|
| 加值 | `ALTER TYPE ADD VALUE` ✅ | 改 CHECK ✅ |
| 删值 / 改名 | ❌ **永远不能** | ✅ 改 CHECK 就行 |
| 类型安全 | 更强 | 靠 CHECK |
| 适合 | **封闭集合**（debit/credit） | **会增长的集合**（状态机） |

### 其他列

```sql
state            text NOT NULL CHECK (state IN ('pending','funds_held','completed','compensating','reversed','failed')),
failure_reason   text,                          -- 只有失败/撤销时才有
next_attempt_at  timestamptz NOT NULL,          -- 重试调度 + lease
version          int NOT NULL,                  -- 乐观并发
UNIQUE (user_id, idempotency_key),              -- 重试找到同一笔，而不是新建一笔
CHECK ((failure_reason IS NOT NULL) = (state IN ('failed','reversed')))
```

> `[9:04:44]` ...a **version**, bumped by **every write, for optimistic concurrency**. A **unique key on the user and their idempotency key, so a retry finds this transfer instead of creating another.** And **a check that ties the failure reason to the states that need one.**

> `[9:05:01]` ...then **an index for the question the orchestrator asks all day: "which unfinished transfers are due?"** **Finished ones aren't even in it** [partial index].

### `saga_history`：给客服看的表

> `[9:05:20]` And **the saga's history: one row per try of each step, its outcome, and the detail — like the reason a wallet gave.** **When support asks "what happened to a transfer?", this table answers.**

💡 这一句透露了一个常被忽略的需求：**可运维性也是功能**。账本回答"钱在哪"，history 回答"为什么"。

---

## 10. 状态机：一张 map 坐镇

```go
var transitions = map[State][]State{
	Pending:      {FundsHeld, Failed},
	FundsHeld:    {Completed, Compensating},
	Compensating: {Reversed},
	Completed:    nil,   // 终态
	Failed:       nil,
	Reversed:     nil,
}
```

> `[9:10:21]` ...`Can` **checks a move against the map**, and **a final state is one with nowhere to go. No other code in the service decides what's allowed — it asks this map.**

**译文**：……`Can` **用这张 map 检查一次转移**，而**终态就是无处可去的状态。服务里没有别的代码决定什么被允许——它问这张 map。**

```
                  ┌──────────────► failed        (终态)
pending ──────────┤
                  └────► funds_held ──┬────────► completed   (终态)
                                       │
                                       └────────► compensating
                                                       │
                                                       └────► reversed (终态)
```

### 为什么状态机值得一个表驱动测试

> `[9:10:59]` ...and **the moves that must never happen**: **completed without a hold, failed with money still held, changing our mind while compensating, and leaving a final state.**

**译文**：……以及**绝不能发生的转移**：**没 hold 就 completed、钱还冻着就 failed、补偿中改变主意、离开终态。**

💡 **状态机测试的价值在于"禁止"那一半。** 正向路径会被集成测试覆盖，**反向路径（不该发生的转移）永远不会被真实流量触发**——除非你用测试强制。

> `[9:11:17]` ...cheap to write, and **it'll catch the day someone adds a state and forgets an arrow.**

---

## 11. Exactly-once 的三个支柱

> `[9:16:44]` Now **the one idea that makes the orchestrator correct: exactly-once delivery doesn't exist.** Any step can run twice: **we crash after the wallet said yes, before we wrote it down** — or **a call times out, and we can't know if it worked.**

> `[9:17:22]` So **every step is idempotent**: **the hold's ID is the transfer's ID, and asking again finds it done.**

| # | 机制 | 解决什么 |
|---|---|---|
| 1 | **每步幂等**（hold id = transfer id） | 请求重复 |
| 2 | **claim + `SKIP LOCKED` + lease** | 两个 worker 同时跑同一笔（"nearly always"） |
| 3 | **version（CAS）** | 两个 worker **真的**重叠时，绝不把"可能已发生"的步骤宣告失败 |

> `[9:17:39]` ...and **versions make sure that when two workers do overlap, we never declare failed a step that might have happened — we try it again.** **At-least-once delivery plus idempotent steps = exactly-once effects. We may ask the wallet twice, but the money moves once.**

**译文**：……而**版本号保证当两个 worker 真的重叠时，我们绝不会把一个"可能已经发生"的步骤宣告为失败——我们再来一次。** **至少一次投递 + 幂等步骤 = 恰好一次的效果。我们可能问 wallet 两次，但钱只动一次。**

💡 注意第 2 条那个词：**"nearly always"**。他用词很准——`SKIP LOCKED` + lease 只能**几乎**保证互斥，不能绝对保证（lease 到期时前一个 worker 可能还活着）。**所以必须有第 3 条兜底。**

**三层防御，缺一不可。** 而第 3 条的 CAS 是最后一道线。

---

## 12. `saga.go`：每个状态一个"步骤 + 两条出路"

> `[9:19:17]` The saga itself has, **for each state that isn't final: the step to run, where success leads, and where a rejection leads.**

```go
var steps = map[State]step{
	Pending: {
		do: func(w Wallet, t Transfer) error { return w.Hold(...) },
		ok: FundsHeld,
		no: Failed,          // hold 被拒 → 什么都没动 → 直接失败
	},
	FundsHeld: {
		do: func(w Wallet, t Transfer) error { return w.Capture(...) },
		ok: Completed,
		no: Compensating,    // capture 被拒 → 钱在 hold 里 → 必须补偿
	},
	Compensating: {
		do: func(w Wallet, t Transfer) error { return w.Release(...) },
		ok: Reversed,
		no: "",              // ← 故意留空
	},
}
```

> `[9:20:18]` **`release` has nowhere to go on a rejection — on purpose. Giving money back has to work, so it's retried until it does.**

**译文**：**release 在失败时无处可去——这是故意的。把钱还回去必须成功，所以它会一直重试直到成功。**

💡 这一行是**整个 saga 正确性的地基**：

- `hold` 被拒 → `failed`（安全，钱没动）
- `capture` 被拒 → `compensating`（必须补救）
- **`release` 被拒 → 没有出路 → 无限重试**

**如果 release 也能"放弃"，钱就永久卡在 hold 账户里**——账本仍然平衡，但 Alice 的钱永远回不来。**这是设计里唯一一个允许无限重试的地方，而且是必须的。**

---

## 13. `run` 循环：四个旋钮和一次明确的"不做"

> `[9:20:35]` ...and **four knobs**: **10 transfers per claim**, a **lease of 10 seconds** — **comfortably longer than one step, which the wallet client caps at 3 seconds**; if a step could outlive its lease, another worker would start the same step while the first is still running — **safe, thanks to idempotency, but wasteful**; **poll every second**, and **retries that start at a second**.

💡 **"safe but wasteful"** —— 这个判断很诚实。lease 太短不会导致错误，只会导致重复调用。**所以他把 lease 设成 step 超时的 3 倍多。**

### 那个"这里没有什么"的观察

> `[9:21:28]` **And notice what's not here: no code for recovery.** A transfer that a dead process was working on is **simply due again once its lease runs out.**

**译文**：**注意这里没有什么：没有任何恢复代码。** 一个死掉的进程正在处理的转账，**在它的租约到期后就简单地重新到期了。**

💡 这是本集最值得学的架构洞察：

| 常见做法 | 他的做法 |
|---|---|
| 写"启动时扫描僵尸任务"的恢复逻辑 | **让"到期"这个性质自动处理** |
| 恢复代码是一条独立的、很少被测试的路径 | **恢复和正常路径是同一条代码** |

**"崩溃恢复"不应该是功能，应该是数据状态的必然结果。** 这和 EP7 的"每条失败路径都终止在可安全重试的状态"是同一个思想。

### `context.WithoutCancel`

> `[9:21:55]` ...**each step gets a `context.WithoutCancel`** — a step that [writes] in the saga table, and does it.

💡 为什么？如果直接用请求的 ctx，**客户端一挂断，正在执行的 hold 会被取消**——但那个 hold 可能已经在 wallet 侧提交了。**saga 的步骤不能被 HTTP 请求的生命周期管着。**

---

## 14. API：`202 Accepted` + Location

> `[9:23:28]` A transfer takes several steps, so **the API is asynchronous**: creating one answers **202 Accepted at once, with a URL to follow it**. **Why not wait for the saga and answer 201?** **Today it takes milliseconds, but with a manual review, it could take a day, and no HTTP request should wait that long.**

**译文**：一笔转账要走好几步，所以 **API 是异步的**：创建它**立刻返回 202，带一个可以跟进的 URL**。**为什么不等着 saga 完成再返回 201？** **今天是毫秒，但如果有一次人工审核，可能要一天，而没有任何 HTTP 请求该等那么久。**

💡 这个决定的价值不在今天，在**未来**：如果一开始用同步 201，后来加人工审核就必须改 API（破坏性变更）。**202 从一开始就是对的形状。**

### 只校验"自己能校验的"

> `[9:24:27]` ...then it validates **only what it can check alone**: two different wallet IDs, a positive amount, a currency code. **Whose wallets they are, and whether the money is there, is the wallet service's call — step by step.**

> `[9:24:45]` **We could ask the wallet up front, to fail faster, but the saga would still have to handle it: a wallet can be frozen between that check and the capture.**

**译文**：**我们可以事先问 wallet，好失败得更快，但 saga 反正还是要处理它：一个钱包可能在那个检查和 capture 之间被冻结。**

💡 这是**"不要做预检"**的经典论证：**预检不能消除失败路径，它只能提前发现一部分。** 而 saga 必须处理全部。

### `202` 只在"新转账"时唤醒 orchestrator

> `[9:25:25]` ...then 202, with the transfer, and a `Location` header — the URL to poll. And **only for a new transfer, wake the orchestrator.**

💡 重试不该唤醒（因为那笔已经在跑了）。

---

## 15. `main.go`：两个独立的 context 和关闭顺序

> `[9:27:13]` ...**the orchestrator** [and the relay], **each has a context of its own, not the one that ends on Ctrl-C: they keep working while the server drains.**

> `[9:27:32]` Shutdown in order: **the HTTP server stops taking requests**, then **the orchestrator, which finishes the steps it's in the middle of, and writes them down**, then **the relay, which publishes the events those steps wrote**, then **the connections.**

**译文**：按顺序关闭：**HTTP 服务器停止接受请求**，然后**orchestrator，它完成正在进行的步骤并把它们记下来**，然后**relay，它发布那些步骤写下的事件**，然后**连接**。

```
关闭顺序（严格）：
1. HTTP 停止接受请求
2. orchestrator 完成手上的步骤 + 写下来   ← 不丢工作
3. relay 发布这些步骤写的事件              ← 不丢事件
4. 关闭连接池 / NATS
```

💡 **这个顺序不是"反过来关"，而是"按数据依赖关闭"**：relay 依赖 orchestrator 写的 outbox 行，所以 relay 必须后关。**如果反了，第 2 步写的事件会留在 outbox 里（下一轮再发，不丢），但会多一次延迟。**

---

## 16. 三个演示

### 演示 1：成功（`9:31:15`）

```
202 accepted（几毫秒）→ pending
GET Location → completed
日志：hold succeeded → funds_held → capture succeeded → completed
事件：transfer.completed 通过 outbox 发出
余额：Alice 35, Bob 15
```

### 演示 2：冻结 Bob 的钱包（`9:32:13`）

```
202 → pending
hold 成功 → funds_held
capture 被拒：wallet_frozen → compensating
release 成功 → reversed（reason: wallet_frozen）
Alice 余额：35（和没转账一样）
```

> `[9:33:27]` **The money left her wallet for a few milliseconds, and came back**, and a **transfer.failed** event went out, with the state **reversed** and the reason. **The history in the transfer database has both sagas**: the first transfer's hold and capture, and this one's hold, its rejected capture with the reason, and the release. **That's what support reads when someone asks what happened.**

**译文**：**钱离开了她的钱包几毫秒，又回来了**，而一个 **transfer.failed** 事件发出去了，状态是 **reversed**，带着原因。**transfer 数据库里的历史有两次 saga**：第一笔转账的 hold 和 capture，以及这一笔的 hold、被拒的 capture（带原因）、和 release。**这就是客服在被问"发生了什么"时读的东西。**

💡 注意事件类型只有两个（`completed` / `failed`），**`reversed` 被归入 `failed`**：

> `[9:12:53]` ...**two event types, for a saga that's over: `completed`, or `failed`, which covers refused and reversed, since either way, no money moved in the end.** **We don't publish every step; the in-between states are our business.**

**译文**：……**两个事件类型，对应一个已经结束的 saga：`completed`，或者 `failed`（它涵盖 refused 和 reversed，因为无论哪种，最终都没有钱移动）。我们**不发布每一步；中间状态是我们自己的事。**

💡 **对外契约只暴露终态。** 如果每个状态都发事件，消费者就被绑死在你的状态机上——**而你刚在 §9 说这个列表会变。**

### 演示 3：最可怕的那个（`9:34:05`）

> `[9:34:05]` Now the scary one: **the transfer service crashing in the middle of a saga at the worst moment — right after the wallet placed the hold, before we wrote it down.**

```
Alice 付 15 → 202 pending
【transfer 服务崩溃】（在 hold 成功之后、写下来之前）
GET → 502（服务不在）
Alice 余额：20（她的 15 在 hold 里）
transfer 表：pending，version 2，已被一个永不回来的 worker 认领，租约还剩 10 秒
【重启 transfer 服务】
```

> `[9:35:59]` ...**there's no recovery call to run. The orchestrator polls, the dead worker's lease runs out, and the transfer is simply due again.**

> `[9:36:16]` And there it goes: **the hold step runs again, for the same transfer. The wallet found the hold it had already placed, under the transfer's ID. She was charged once, even though the hold was asked for twice.** And Bob has 30 — the first 15, and these. **That's exactly-once effects, live: delivery at least once, and an idempotent step.**

**译文**：……**没有任何恢复调用要跑。orchestrator 轮询，死掉的 worker 的租约到期，这笔转账就简单地重新到期了。**

然后它跑起来了：**hold 步骤对同一笔转账又跑了一次。wallet 找到了它已经放下的那个 hold，用的是转账的 ID。她只被扣了一次，尽管 hold 被请求了两次。** 而 Bob 有 30——第一个 15，和这一次。**这就是恰好一次的效果，现场版：至少一次投递，加一个幂等的步骤。**

💡 **注意这里没有任何"恢复逻辑"被执行。** 崩溃留下的唯一痕迹是：`pending` + 过期的 lease。**然后正常的轮询把它捡起来了。**

---

## 17. 测试：为什么用假 wallet

> `[9:37:28]` ...first **a fake wallet in memory, that behaves like the real one**: each step moves a hold to its next status once, **and repeating a step changes nothing.** It **counts the calls**, and `failHolds` answers "no" for each step before it starts saying yes, so a test can make it **refuse, or be down for a while**.

> `[9:37:46]` **Why a fake, and not the real wallet? These tests are about the orchestrator.**

**译文**：**为什么用假的，不用真的 wallet？因为这些测试是关于 orchestrator 的。**

💡 这和 EP5 的"不用假 store"是**同一个判据、相反的结论**：

| | EP5 handler 测试 | EP12 orchestrator 测试 |
|---|---|---|
| 被测对象 | 校验、错误映射、SQL、约束 | **状态机、重试、补偿、CAS** |
| 用假的会怎样 | **主要在测假货** | **正合适** |
| 结论 | 用真的 | **用假的** |

**"要不要 mock"没有普适答案，取决于"被测的那一层是谁"。**

### 那个 stale worker 的回归测试

> `[9:39:43]` Last: **the dead worker comes back to life with what it read back then, and tries to advance the transfer. Its version is stale, so its write is refused.**

**译文**：最后：**那个死掉的 worker 复活了，带着它当初读到的数据，尝试推进这笔转账。它的版本是陈旧的，所以它的写入被拒绝了。**

💡 这个测试**直接验证了 §11 的第三根支柱（CAS）**。没有它，那根支柱就是"我觉得应该没问题"。

---

## 18. 我的补注

### ① `state` 用 text + CHECK，但别忘了 CHECK 也要迁移

他的理由是"enum 不能删值/改名"。但 text + CHECK 的代价是：**每次加状态都要写一个迁移去改 CHECK 约束**，而且**改 CHECK 会重写全表校验**（PG 12+ 对 `ADD CONSTRAINT NOT VALID` + `VALIDATE` 可以避免锁表）。

生产上的写法：

```sql
ALTER TABLE transfers ADD CONSTRAINT transfers_state_check
  CHECK (state IN (...新列表...)) NOT VALID;
ALTER TABLE transfers VALIDATE CONSTRAINT transfers_state_check;  -- 不锁写
```

### ② lease 10 秒 vs step 3 秒：这个比例值得记住

```
wallet client 每次调用最多 3 秒（含重试）
orchestrator lease = 10 秒
```

**判断标准：`lease > 单步最大耗时 × 2`。** 他用了 3.3 倍。

如果 lease < step 耗时：**另一个 worker 会在第一个还在跑的时候开始同一步** → 安全（幂等）但浪费，而且 `version` CAS 会让其中一个失败 → **多一次无用的重试**。

### ③ `saga_history` 会无限增长

一个 transfer 最多 3 步 + 若干重试。**每次重试一行**。一次 NATS/wallet 抖动可能产生几十行。

清理策略和 outbox 一样，但他这一集没做。可以按"transfer 已终态且超过 N 天"清理。

### ④ `202 + 轮询` 的客户端成本

他的 `Location` 指向 `GET /v1/transfers/{id}`，客户端要**轮询**。真实系统里通常是：

- **webhook**（EP22 有签名 webhook）
- **long polling**（挂起直到完成或超时）
- **SSE / WebSocket**

轮询在演示里没问题，但它把延迟和负载都推给了客户端。**`Location` 是"正确的最小实现"，不是"最好的实现"。**

### ⑤ hold 账户的余额是一个业务指标

```sql
SELECT currency, balance FROM account_balances
WHERE name = 'holds' AND kind = 'system';
```

**这个数字 = 当前"已冻结但未结算"的总额。** 它应该：

- 和 `SELECT count(*) FROM holds WHERE status='held'` 对应的金额相等
- 在监控里画成一条曲线（突然上涨 = saga 卡住了）
- 进 EP15 的不变量测试

**这是"账本可以当监控用"的一个具体例子。**

---

## 19. 自测题

1. 2PC 的四个问题里，哪一个是"即使它能工作也不该用"的理由？
2. saga 保留了哪个 ACID 性质、放弃了哪个？放弃的那个对 API 有什么要求？
3. 为什么不能直接 debit Alice → credit Bob？举出三个具体后果。
4. "补偿必须永远能成功"这条规则，是怎么倒推出 hold 设计的？
5. 为什么 `release` 什么都不检查，而 `hold` 检查一大堆？
6. capture 一个已 released 的 hold，会发生什么？（不只是"报错"）
7. transfer 的 `state` 为什么用 text + CHECK 而不是 enum？这和 EP2 的 `entry_direction` 为什么不矛盾？
8. exactly-once 的三根支柱分别是什么？去掉哪一根会出问题？
9. 为什么 `release` 在 `saga.go` 的 map 里"rejection 无处可去"？
10. lease 设成 10 秒、单步 3 秒，这个比例的理由是什么？设错（太短）会怎样——会错还是会浪费？
11. 为什么崩溃恢复**不需要**任何专门的代码？
12. EP5 用真数据库测 handler，EP12 用假 wallet 测 orchestrator，判据是什么？
13. `reversed` 为什么被归入 `transfer.failed` 事件，而不是单独一个事件类型？
