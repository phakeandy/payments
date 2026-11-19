# EP6 讲义：Moving Money Safely

- **视频** `3:41:14 – 4:27:27`（46 分）｜分支 `ep06` ｜ diff：`+538 / -31`（14 个文件）
- **转录** `media/ep06.txt`（196 句，6,139 词）
- 时间戳是视频绝对时间
- 关键文件：`internal/wallet/transfer.go`（57 行）、`internal/platform/postgres/retry.go`（54 行）、`internal/wallet/ledger.go`（`inTx`）

> 这一集他会**故意制造一个死锁**，然后当着镜头把隔离级别改成 `REPEATABLE READ`，让你看一个已经通过的测试**重新失败**。

---

## 0. 一句话

> EP2 拿掉了 `balance` 列，于是 EP6 必须在应用层**手动加锁**，
> 于是必须处理**死锁**，于是必须有**重试**，于是必须有**抖动**。

这四件事是一条因果链，不是四张彼此独立的"最佳实践"。看懂这条链，这一集就通了。

---

## 1. 要保护的三条不变量

在转账这个操作里，同时成立才算对：

1. **不透支**：`from` 的余额减完不能 < 0
2. **守恒**：`from` 减掉的 == `to` 加上的（EP2 的触发器管这条，应用层不用管）
3. **原子**：要么两条分录都进，要么都不进（EP2 的事务 + 延迟触发器管这条）

EP6 关心的是**第 1 条**，因为它是唯一需要读数据才能判断的。第 2、3 条数据库已经替你保证了。

---

## 2. 朴素版本错在哪

新手会写成三步：

```go
bal := getBalance(from)          // ① 读
if bal >= amount {               // ② 判断
    postTransfer(from, to, amount) // ③ 写
}
```

三个 bug，逐个看：

### bug 1：读-改-写丢更新（lost update）

```
时刻  事务A（余额1000）            事务B（余额1000）
t1    读 bal = 1000
t2                                读 bal = 1000
t3    判断 1000 >= 800 ✓
t4                                判断 1000 >= 800 ✓
t5    写：余额 = 200
t6                                写：余额 = 200
```

两个 800 都成功了，但余额最后是 200，不是 -600。**丢了一次更新**。

### bug 2：检查-然后-行动（TOCTOU）

即使把①③合成一个原子操作，"判断"和"写"之间仍然有窗口。经典名 `time-of-check to time-of-use`。

### bug 3：部分写入

插入 tx 成功、插入第一条分录成功、进程崩了 —— 这在 EP2 已经被事务挡住了，这里不再重复。**注意这正是"问题被下移"的例子**：EP2 解决掉的 bug，EP6 不必再想。

---

## 3. 关键因果：为什么不能写一条原子 SQL

如果余额是一列，这事一行就能解决：

```sql
UPDATE accounts SET balance = balance - $2
WHERE id = $1 AND balance >= $2;
-- 影响 0 行 ⇒ 余额不足
```

这条语句是**原子**的：判断和写发生在同一条语句里，行锁由 Postgres 隐式持有。

**但 EP2 决定不存余额。** 余额是 `account_balances` 视图算出来的。于是：

```sql
-- 这样写并不原子
INSERT INTO entries (...)
SELECT ... WHERE (SELECT balance FROM account_balances WHERE account_id=$1) >= $2;
```

两条并发事务都能看到 `balance = 1000`，然后各自插入。**子查询读到的行不会被锁住**（Postgres 的 `FOR UPDATE` 不能用在聚合上）。

> **因为余额是推导出来的，就没有一行可以锁。所以你必须显式锁住"那个账户"，用它当互斥量。**

这是 EP6 全部复杂度的来源。下面每一行代码都是这句话的展开。

---

## 4. `transfer.go` 逐行

```go
func (s *Store) Transfer(ctx context.Context, from, to uuid.UUID, amount int64, currency string) (Transaction, error) {
	var posted Transaction
	err := s.inTx(ctx, func(q *walletdb.Queries) error {
```

### 4.1 `inTx`：整个函数体重跑的能力

```go
// ledger.go
func (s *Store) inTx(ctx context.Context, fn func(q *walletdb.Queries) error) error {
	return postgres.Retry(ctx, func() error {
		return s.tryTx(ctx, fn)
	})
}
```

注意 `Retry` 包住的是 **`tryTx`**，也就是**一整个数据库事务**。这意味着发生冲突时，`fn` 会**从头再跑一遍**——包括重新加锁、重新读余额。

代码注释里那句很关键：

> Both mean nothing happened, so another attempt is safe, **as long as fn has no side effects outside the transaction.**

这条约束是重试机制的**前提条件**，不是建议。如果 `fn` 里发了邮件、扣了 Redis 里的幂等键、调了外部 API，重试就会重复产生副作用。（EP7 的幂等键设计就是为了让这类操作也能安全重试。）

### 4.2 死板的顺序：先锁小的

```go
		first, second := from, to
		if bytes.Compare(from[:], to[:]) > 0 {
			first, second = to, from
		}
```

`uuid.UUID` 是 `[16]byte`，`bytes.Compare` 是**字典序全序**。所以无论 A→B 还是 B→A，两个事务都按同一个顺序加锁。

### 4.3 两次 `FOR UPDATE`

```go
		for _, id := range []uuid.UUID{first, second} {
			if _, err := q.LockAccount(ctx, id); err != nil {
				return fmt.Errorf("lock account %s: %w", id, err)
			}
		}
```

对应的 SQL（`db/wallet/queries/accounts.sql`）：

```sql
-- name: LockAccount :one
SELECT id FROM accounts
WHERE id = $1
FOR UPDATE;
```

三个细节：

- **锁的是 `accounts` 行，不是 `entries`**。`entries` 只会被插入，插入不需要锁。要保护的是"这个账户的余额"，所以拿账户行当锁。
- **`FOR UPDATE` 持有到 COMMIT/ROLLBACK**，不是到语句结束。
- **第二个锁可能阻塞**：如果另一个事务正持有它，我们就停在这里等。等的时候我们持有 `first` 的锁 —— 这正是死锁的温床（见 §6）。

### 4.4 锁完之后读

```go
		b, err := q.GetAccountBalance(ctx, from)
		if err != nil { ... }
		if b.Balance < amount {
			return fmt.Errorf("wallet %s: %w", from, ErrInsufficientFunds)
		}
```

为什么在这里读就安全了？因为**所有会减少余额的路径都必须先拿同一个锁**。我们持有它，所以在此期间没人能改动 `from` 的余额。

⚠️ 注意这句话里的"所有"是**约定**，不是数据库强制。见 §10——这里有个真实的洞。

### 4.5 写

```go
		posted, err = insertTransaction(ctx, q, NewTransaction{
			Description: "transfer",
			Postings: []Posting{
				{AccountID: from, Direction: Debit,  Amount: amount, Currency: currency},
				{AccountID: to,   Direction: Credit, Amount: amount, Currency: currency},
			},
		})
```

两条分录，EP2 的延迟触发器在 COMMIT 时检查借贷相等。

---

## 5. 全篇最反直觉的一点：隔离级别必须是 READ COMMITTED

```go
// ledger.go
// Our row locks rely on READ COMMITTED: every statement sees all the work
// committed before it started, even work we just waited for. Ask for it,
// so a different default on the server can't quietly break that.
tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
```

大多数人会觉得"隔离级别越高越安全"。这里**恰好相反**：如果把隔离级别调成 `REPEATABLE READ`，整个设计会**静默地坏掉**。

为什么：

| | READ COMMITTED | REPEATABLE READ |
|---|---|---|
| 快照 | **每条语句**取新快照 | **事务开始**时取一次 |
| 等锁之后读到的 | 对方刚提交的最新值 ✓ | **事务开始时的旧值** ✗ |
| 结果 | 检查是正确的 | **读到过期余额 → 透支** |

关键的一环：`REPEATABLE READ` 本来会用"序列化冲突"保护你——但**它只能检测到你写的那一行被别人改过**。这里我们锁的是 `accounts`，改的是 `entries`：

```
事务A: 锁 accounts(alice)  → 读视图（entries 的聚合） → 插 entries
事务B: 锁 accounts(alice)  → 等
事务A: COMMIT
事务B: 拿到锁 → 读视图
```

在 RR 下，事务B 的视图快照在事务开始时就固定了，`entries` 里的事务A 新增的行它**看不见**（快照更早）。而 `accounts` 行没有被任何一方 UPDATE，所以**没有任何冲突可检测**。事务B 会拿着过期余额通过检查，然后插分录 → 透支，而且数据库完全不会报错。

> **锁住的不是被修改的行，这让高隔离级别失去了保护作用。**

这就是为什么代码显式写 `pgx.ReadCommitted`，而不是用默认值：默认值可以被服务器配置（`default_transaction_isolation`）改掉，这个依赖关系太致命，必须写死在代码里。

### 5.1 他当场验证了这一点（`4:07:18 – 4:08:32`）

> `[4:07:18]` **If the other transaction had updated the row we lock, Postgres would raise a serialization error. But it only locked it, so nothing tells us.**

**译文**：**如果另一个事务 UPDATE 了我们锁的那一行，Postgres 会抛一个序列化错误。但它只是锁了那一行，所以没有什么会告诉我们。**

💡 这句话**逐字确认了上一节的推理**：`REPEATABLE READ` 的冲突检测**只能看到被写的行**，而这里锁的是 `accounts`、写的是 `entries`。**检测不到，所以静默放行。**

然后他做了实验：

> `[4:08:03]` But **don't take my word for any of this** — let's try it. In `ledger.go`, `Begin` starts every transaction; let's ask for `repeatable read`.

> `[4:08:32]` **It overdraws again. Same locks, same code, a stricter isolation level, and Alice is negative again.** Beware: **isolation levels are subtle, and tests are how you find out what your code really does.**

**译文**：**它又透支了。同样的锁、同样的代码、更严格的隔离级别，而 Alice 又变成负数了。** 小心：**隔离级别很微妙，而测试是你发现自己代码真正行为的方式。**

**注意他是用“更严格”的隔离级别让一个已经通过的测试失败的。** 这个演示比任何文档都有说服力。

### 5.2 换成 `SERIALIZABLE` 呢

> `[4:08:48]` Now serializable — and this time both transfer tests. **Different failure: no negative balance this time; the overdraft test got its two successes.** Instead, transfers failed with **could not serialize access due to read-write dependencies among transactions**, SQLSTATE `40001`. **Postgres saw the stale reads and refused to commit them.**

> `[4:09:33]` **That's by design: it may abort too often, but never too rarely.** And every one of those failures means the same thing: **nothing happened, please try again.**

**译文**：**这是设计使然：它可能中止得太频繁，但绝不会太罕见。** 而每一个这样的失败都意味着同一件事：**什么都没发生，请再试一次。**

| 隔离级别 | 透支测试 | 转账测试 | 结论 |
|---|---|---|---|
| `READ COMMITTED` + 显式锁 | ✅ 通过 | ✅ 通过 | **他选的** |
| `REPEATABLE READ` | ❌ **又透支了** | — | 静默失效，最危险 |
| `SERIALIZABLE` | ✅ 通过 | ⚠️ 大量 `40001` | 正确但浪费 |

### 5.3 serializable 的真实代价

> `[4:14:56]` **That's the real cost of serializable under contention: it's always correct, but it throws work away, and the busier a wallet is, the more it throws away.**

> `[4:15:46]` ...**if someone runs our code at serializable one day, it keeps working.**

**译文**：**这就是 serializable 在竞争下的真实代价：它永远正确，但它会丢弃工作，而一个钱包越忙，它丢掉的越多。**

💡 最后那句是**重试机制的隐性价值**：它让同一份代码在**任何**隔离级别下都能工作。

---

## 6. 死锁：机制与复现

### 6.1 如果不管顺序，会发生什么

```
事务A: A→B        事务B: B→A
锁 A ✓            锁 B ✓
锁 B ⏳ 等待       锁 A ⏳ 等待
```

两个事务互相等对方放锁，谁都不动。`accounts` 行锁是**普通的排他锁**，没有超时（除非设了 `lock_timeout`）。

### 6.2 Postgres 怎么发现它

Postgres 有个后台的**死锁检测器**。当事务等锁超过 `deadlock_timeout`（默认 **1 秒**）时，它构建一次**等待图**（谁在等谁），如果发现环，就 **abort 掉其中一个事务**，给它返回：

```
ERROR: deadlock detected  (SQLSTATE 40P01)
```

他现场拿到的是：

> `[4:03:02]` **`deadlock detected`, SQLSTATE `40P01`** — and **it took many seconds, for a test that should take about one.**

> `[4:03:31]` **Alice sends money to Bob, while Bob sends money to Alice**... **transfer two wants Alice's row, and waits for transfer one. Neither can ever finish. That's a deadlock.** **Postgres doesn't wait forever.**

**译文**：**`deadlock detected`，SQLSTATE `40P01`**——而且**一个本该一秒就跑完的测试花了十几秒。** **Alice 给 Bob 转钱，同时 Bob 给 Alice 转钱**……**transfer two 想要 Alice 的行，等着 transfer one。两个都永远结束不了。** **Postgres 不会永远等下去。**

⚠️ 字幕把 `40P01` 转成了 `40101`。**错误码是 `40P01`。**

所以症状很有特征：**平时很快，偶发 1 秒延迟，然后一个错误。**

### 6.3 现场复现（两个 psql 会话，10 分钟）

```bash
cd ~/git/github.com/dev-marker/payments
git switch --detach upstream/ep06
docker compose up -d postgres && make migrate-up
psql "postgres://payments:payments@localhost:5432/wallet"
```

准备两个钱包（`ep06` 的 schema 在 EP2 之上加了 `kind` 列）：

```sql
-- 会话 0：建两个钱包
INSERT INTO accounts (kind, name, currency, normal_balance) VALUES
  ('wallet','alice','USD','credit'),
  ('wallet','bob',  'USD','credit')
RETURNING id \gset
\echo alice = :'id'
```

把两个 UUID 记下来，然后：

| 步骤 | 会话 A | 会话 B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `SELECT id FROM accounts WHERE id='ALICE' FOR UPDATE;` | |
| 3 | | `SELECT id FROM accounts WHERE id='BOB' FOR UPDATE;` |
| 4 | `SELECT id FROM accounts WHERE id='BOB' FOR UPDATE;` → **卡住** | |
| 5 | | `SELECT id FROM accounts WHERE id='ALICE' FOR UPDATE;` |
| 6 | 约 1 秒后，**其中一个会话**报 `ERROR: deadlock detected` | |

**这一步亲手做一遍，比读十页文档有用。** 你会看到"卡住"是安静的——没有报错，只是不返回。这就是为什么死锁在生产里表现为"偶发延迟"而不是"明显故障"。

顺手可以观察检测器：

```sql
SHOW deadlock_timeout;   -- 1s
```

### 6.4 为什么排序能彻底消灭死锁

> `[4:05:25]` ...that's why **the ordering lives in one place, right next to the lock.** And notice that **the lock order is independent of the money flow.**

**译文**：……这就是为什么**排序逻辑只存在于一个地方，就在锁的旁边。** 而且注意**锁的顺序和钱的流向无关。**

💡 “independent of the money flow” 这句很重要：A→B 和 B→A 走**同一条加锁路径**。如果他写成 `lock(from); lock(to)`，排序就会散落在每个调用点。

实验证明：

> `[4:04:58]` [It] **passed in about a second**. Most of the 200 transfers went through, some were refused for insufficient funds — **which is exactly right with random amounts** — and **not a single deadlock.**

**译文**：**大约一秒就通过了。** 200 笔转账大部分成功了，一些因为余额不足被拒——**在随机金额下这完全正确**——而且**一次死锁都没有。**

如果把每一对账户按 `bytes.Compare` 排成 `(first, second)`，那么所有事务获取锁的顺序，都是同一个**全序**上的**升序**。

于是等待图不可能有环：假设有环 `T1→T2→…→Tn→T1`，每一步都表示"持有一个较小编号的锁，等一个较大编号的锁"（因为每个事务都是升序取锁）。那么 `T1` 等的锁编号 > 它持有的编号，而 `Tn` 持有的编号 > `T1` 持有的……沿着环推下去会得到 `编号 < 编号` 的矛盾。

> **代价几乎为零，收益是"这类 bug 永远不存在"。** 这是本集最划算的一行代码。

💡 这个技巧在 EP18（四账户的 FX 转换）、EP12（holds）都必须继续遵守，否则前面的努力白费。

---

## 7. 既然排序消灭了死锁，为什么还要 `Retry`？

这是最值得问的问题，答案有三层：

### 层一：`Deposit` 根本不加锁

```go
// service.go
return s.store.PostTransaction(ctx, NewTransaction{...})   // 没有 LockAccount
```

充值只**增加**余额，不需要透支检查，所以它不拿锁。那它会不会和转账死锁？不会——它不持有任何账户锁。

但它暴露了一个事实：**锁协议是约定，不是机制**。今天只有 `Transfer` 加锁所以安全；明天有人写一个"提现"忘了加锁，透支检查就失效了。

### 层二：未来会有人打破顺序

`ep12` 的 hold/capture、`ep18` 的四账户转换，每个新流程都是一次破坏排序的机会。`Retry` 是**第二道保险**：即使有人写错了顺序，系统退化成"偶发重试"而不是"偶发卡死"。

### 层三：`40001` 与 `40P01` 的语义特别适合重试

> `[4:09:49]` [The helper] **retries exactly two errors: `40001`, a serialization failure, and `40P01`, a deadlock. For both, PostgreSQL guarantees that the transaction was rolled back, and nothing was written.** **Anything else** — a constraint violation, a lost connection — **is returned as is.**

> `[4:10:04]` **It retries the whole transaction from `Begin`. You can't just repeat the last statement: an aborted transaction refuses every statement until it's rolled back.**

> `[4:10:18]` And that means **the function we retry must have no side effects outside the transaction — no emails, no HTTP calls.** It's bounded: **five attempts, then it gives up and returns the real error, so a pathological case fails loudly instead of spinning forever.**

**译文**：……**它重试整个事务，从 `Begin` 开始。你不能只重复最后一条语句：一个已中止的事务会拒绝每一条语句，直到它被回滚。** 而这意味着**我们重试的那个函数在事务之外必须没有副作用——不发邮件、不发 HTTP 请求。** 它是有界的：**五次尝试，然后放弃并返回真正的错误。**

💡 “an aborted transaction refuses every statement” —— 这正是为什么 `Retry` 包的是**整个 `tryTx`**，而不是重试某一条语句。

```go
switch pgErr.Code {
case "40001", "40P01": // serialization_failure, deadlock_detected
	return true
}
```

这两个码的含义是**"事务被整个回滚了，什么都没发生"**。所以重试**在语义上永远安全**。

反过来，绝对不能重试的错误：

| 错误码 | 含义 | 为什么不重试 |
|---|---|---|
| `23514` | check_violation | EP2 的触发器说"借贷不平"。重试一万次也一样不平——这是 bug，不是冲突 |
| `23505` | unique_violation | 幂等键重复。重试会撞同一个键（EP7 会把它翻译成"这是重复请求，返回上次结果"） |
| 业务错误 | `insufficient_funds` | 余额不足是**结论**，不是故障 |
| 任何非 PG 错误 | — | 不知道发生了什么，不能假设它没副作用 |

> **能重试的错误只有一类：数据库告诉你"我什么都没做"。**

---

## 8. 抖动：为什么退避必须是随机的

> `[4:10:33]` ...and between attempts it sleeps with what's called **full jitter**: **not a fixed delay, a random time between zero and a ceiling, and the ceiling doubles every time.** **If two transactions just collided, and both retried after exactly 10 milliseconds, they'd collide again. Randomness spreads them out.**

**译文**：……而且在尝试之间它睡一段时间，这叫 **full jitter**：**不是固定延迟，而是零到某个上限之间的随机值，而且上限每次都翻倍。** **如果两个事务刚刚撞了，然后都在恰好 10 毫秒后重试，它们会再撞一次。随机性把它们摊开。**

> `[4:11:04]` ...so it goes in `internal/platform/postgres`, in `retry.go`. **`MaxAttempts` is five, and it's exported so tests can refer to it.**

> `[4:12:00]` ...if **the client hangs up while we're backing off, we stop right away**. Then the ceiling doubles: **10, 20, 40, 80 milliseconds.**

**译文**：……如果**客户端在我们退避的时候挂断了，我们立刻停止**。然后上限翻倍：**10、20、40、80 毫秒。**

```go
backoff := 10 * time.Millisecond
...
case <-time.After(rand.N(backoff)):   // 全抖动：0 ~ backoff 之间均匀随机
...
backoff *= 2                           // 上限每次翻倍
```

`rand.N(backoff)` 是 `[0, backoff)` 上的均匀分布，这叫 **full jitter**。

**没有抖动会发生什么**（活锁）：

```
t=0     事务A 和 事务B 死锁，B 被 abort
t=10ms  B 立刻重试，又撞上 A，又死锁
t=20ms  B 重试 ...
```

两个事务的重试节奏完全同步（因为它们的退避时间都是确定值 10ms），于是**每次重试都精确地再撞一次**。系统看起来在忙，进度为零。

有了抖动，两者的等待时间变成 `[0,10)` 内的随机值，碰撞概率立刻掉到个位数百分比。即使撞上，第二次退避区间变成 `[0,20)`，再撞的概率继续下降。

**为什么是 `[0, backoff)` 而不是 `backoff/2 + rand`？** 因为全抖动的**期望等待最短**（`backoff/2`），同时碰撞概率被稀释得最好。这是 AWS 那篇著名的 *Exponential Backoff and Jitter* 的结论。

退避序列：`[0,10) → [0,20) → [0,40) → [0,80) → [0,160)`，5 次后放弃（`MaxAttempts = 5`）。

---

## 9. 测试怎么证明它对

```go
// 发令枪：所有 goroutine 都卡在 <-start 上，close 的瞬间一起冲
start := make(chan struct{})
for i := range n {
	wg.Go(func() {
		<-start
		errs[i] = fn()
	})
}
close(start)
```

### 测试一：不能透支

```go
alice = $10 的钱包，bob = $0
10 笔并发转账，每笔 $5
```

```go
if ok, _ := tally(t, errs); ok != 2 {
	t.Errorf("%d transfers succeeded, want 2", ok)
}
```

**恰好 2 笔成功**。$10 只能负担 2 笔 $5。如果锁写错了，会很轻易地出现 3、4、甚至 10 笔成功（余额变负）。

`tally` 还额外断言：除了成功和 `insufficient_funds`，**不允许出现任何其它错误**——死锁重试失败、超时、连接错误都会让测试失败。

### 测试二：守恒

`TestConcurrentTransfersConserveMoney` —— 多钱包随机互转，最后断言总额不变。

### 测试三（EP15 放大）：300 并发 + 全账本不变量

`books_test.go` 里那条 SQL 一次查完：借贷不平、余额为负、holds 账户对不上。这是"钱的守恒律"级别的测试。

### 为什么必须用并发测试，不能只测单线程

单线程下，**所有**上面讨论的 bug 都不存在：没有并发就没有丢更新、没有死锁、没有 TOCTOU。这类 bug 只在"两个事务真的同时跑"时出现，而单元测试默认是串行的。

> 并发 bug 的测试不是"测得更全"，是**测试对象本身变了**。

---

## 10. 这个设计的真实漏洞（讲义补注）

### 洞一：锁协议靠自觉

前面说过，`Deposit` 不拿锁。他自己把这件事说得更明白：

> `[4:15:46]` **The price of explicit locks is that they're opt-in. Every future code path that takes money out of a wallet has to take the lock too.**

**译文**：**显式锁的代价是它们是“可选参加”的。未来每一条从钱包里拿钱的代码路径，都必须自己记得拿那把锁。**

💡 “opt-in” 这个词选得很准：**数据库不会强制你拿锁**，因为锁是一个动作，不是一个约束。想强制，只能靠 CHECK 约束或 SERIALIZABLE。

今天它是安全的（只加钱）。但如果有人加一个“提现”：

```go
// 假设有人这么写，忘了 LockAccount
bal := getBalance(from)
if bal >= amount { postWithdrawal(...) }
```

**这个 bug 不会被任何现有测试抓住**，因为 `Deposit` 和 `Transfer` 的测试都不会和它并发。

### 洞二：没有数据库层的兜底

EP2 把"借贷相等"放到数据库，但"不能透支"只在应用层。对比一下：

| 不变量 | 谁保证 | 可靠性 |
|---|---|---|
| 借贷相等 | EP2 的延迟触发器 | **数据库强制**，绕不过 |
| 不能透支 | EP6 的锁 + 检查 | **应用层约定**，绕得过 |

### 真正的加固方案（三种，各有取舍）

**① 物化余额 + CHECK 约束**（最稳）

```sql
ALTER TABLE accounts ADD COLUMN balance bigint NOT NULL DEFAULT 0
  CHECK (balance >= 0);
```

于是 `UPDATE accounts SET balance = balance - $2 WHERE id=$1 AND balance >= $2` 一行搞定，
而且**任何**忘记加锁的代码路径都会被 CHECK 挡住（数据库兜底）。
代价：余额又变成"存着的数字"，需要触发器把它和 entries 保持同步，EP2 的"单一真相源"被破坏。这是典型的**正确性 vs 简洁性**取舍。

**② SERIALIZABLE + 重试**（最纯）

不加显式锁，让 Postgres 追踪读写依赖，冲突就 abort 重试。
代价：冲突率高时吞吐下降明显；而且**必须**保证所有事务都是 SERIALIZABLE（混用会破坏保证）。

**③ advisory lock**（最灵活）

```sql
SELECT pg_advisory_xact_lock(hashtext($1::text));
```
按账户 ID 取咨询锁。好处是可以锁"还不存在的账户"，坏处是它和行锁是两个体系，容易和别的事务互相死锁。

他选的是**显式行锁 + 排序**：性能最好、语义最直观、代码最短（57 行）。代价是**协议靠自觉**，靠测试和后续的 review 兜。

---

## 11. 三种设计对照

| | 物化余额 + 条件 UPDATE | 显式行锁 + 排序（本仓库） | SERIALIZABLE |
|---|---|---|---|
| 单笔代码量 | 1 条 SQL | ~20 行 | ~5 行 |
| 防透支靠 | 数据库（原子 + CHECK） | 应用层约定 | 数据库（冲突检测） |
| 防死锁靠 | 仍需有序锁两行 | 排序 | 自动 abort |
| 高并发吞吐 | 高 | 高 | 中（冲突多时低） |
| 可审计性 | 差（余额被覆盖） | **好**（只有 entries） | 好 |
| 失败模式 | 数字错了没人知道 | 有人忘加锁 → 透支 | 冲突风暴 → 吞吐塌陷 |

**他为什么选中间那个**：EP2 已经定下“余额不存”，而这正是支付系统最看重的东西（审计、可解释）。所以他用**应用层的复杂度**换取**数据层的单一真相**。这是清醒的取舍，不是疏忽。

### 他自己怎么说这个取舍

> `[4:16:22]` ...**if that's ever your bottleneck, you'd only lock the side that has a rule — but measure before you get clever.**

> `[4:16:40]` **Serializable is a perfectly good default for a ledger, especially if you'd rather pay in retries than in carefulness. What matters is that you choose and test the choice.**

**译文**：……**如果那真的成了你的瓶颈，你只锁有规则的那一侧——但在你比变聪明之前先测量。** **对账本来说，serializable 是一个完全合理的默认值，尤其是当你宁愿用重试付费、而不是用小心付费的时候。重要的是你做了选择，并且测试了这个选择。**

💡 “you'd rather pay in retries than in carefulness” —— 这句话把两种成本并列了：

| 付什么 | 得到什么 | 风险 |
|---|---|---|
| **重试**（serializable） | 不用每一处都记得加锁 | 高竞争时吞吐塔陷 |
| **小心**（显式锁） | 高吞吐 | **漏一处就透支，而且测试可能拓不到** |

**他选了“小心”，但前提是他把小心变成了测试。**

### 他建议加的一个监控指标

> `[4:13:55]` One thing I'd add in production: **a counter for retries. A few retries are normal. A sudden jump means two parts of the system started fighting over the same rows** — and **it's often the first warning, long before anything fails.**

**译文**：生产上我会加一样东西：**一个重试计数器。少量重试是正常的。突然跳升意味着系统的两个部分开始争抢同一批行**——而且**它往往是最早的预警，远在任何东西失败之前。**

💡 这是一个**先行指标**：重试率上浨 → 延迟上浨 → 超时 → 失败。你在第二环就能知道，而不是在第四环。

---

## 12. 自测题

1. 为什么 `LockAccount` 锁的是 `accounts` 而不是 `entries`？
2. 如果把隔离级别改成 `REPEATABLE READ`，具体哪一步会出错？为什么 Postgres 检测不到？
3. 锁顺序已经保证不死锁了，`Retry` 还有用吗？给出至少两个理由。
4. 为什么不能重试 `23514`？如果重试了会发生什么？
5. `rand.N(backoff)` 改成固定的 `backoff`，会出现什么现象？在监控上看起来像什么？
6. `Deposit` 没有加锁，为什么现在是安全的？加一个"提现"接口后还是安全的吗？
