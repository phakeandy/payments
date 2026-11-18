# EP6 深读：Moving Money Safely

> 这份讲义从 `upstream/ep06` 的**真实代码**出发。视频字幕还没转出来（机器在排队），
> 但 EP6 的核心不是他讲了什么，是那 111 行代码为什么必须长成那样。
> 时间戳等字幕到了我补。

- 分支 `ep06`，diff：`+538 / -31`
- 关键文件：`internal/wallet/transfer.go`（57 行）、`internal/platform/postgres/retry.go`（54 行）、`internal/wallet/ledger.go`（`inTx`）

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

前面说过，`Deposit` 不拿锁。今天它是安全的（只加钱）。但如果有人加一个"提现"：

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

**他为什么选中间那个**：EP2 已经定下"余额不存"，而这正是支付系统最看重的东西（审计、可解释）。所以他用**应用层的复杂度**换取**数据层的单一真相**。这是清醒的取舍，不是疏忽。

---

## 12. 自测题

1. 为什么 `LockAccount` 锁的是 `accounts` 而不是 `entries`？
2. 如果把隔离级别改成 `REPEATABLE READ`，具体哪一步会出错？为什么 Postgres 检测不到？
3. 锁顺序已经保证不死锁了，`Retry` 还有用吗？给出至少两个理由。
4. 为什么不能重试 `23514`？如果重试了会发生什么？
5. `rand.N(backoff)` 改成固定的 `backoff`，会出现什么现象？在监控上看起来像什么？
6. `Deposit` 没有加锁，为什么现在是安全的？加一个"提现"接口后还是安全的吗？
