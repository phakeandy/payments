# EP07 讲义：Idempotency Keys（让重试变安全）

- **视频** `4:27:23 – 5:15:03`（48 分）｜分支 `ep07` ｜ diff：`+774 / -42`（19 个文件）
- **转录** `media/ep07.txt`（196 句，6,214 词）
- 时间戳是视频绝对时间

一句话：**上一集解决了"两个请求同时来"，这一集解决"同一个请求来两次"——而且这是唯一一个必须靠应用层解决的问题。**

> 这一集有全课程最好的开场：他**当场**制造了一笔双重扣款，然后说"没人做错任何事"。

---

## 0. 上一集留下的洞

> `[4:27:30]` Last time, we made transfers safe from **each other** — row locks, lock ordering, retries, and a test that fires hundreds of transfers at once. **But I ended with a problem: our transfers aren't safe from the network.**

**译文**：上一集我们让转账在**彼此之间**是安全的——行锁、锁顺序、重试，还有一个几百笔并发转账的测试。**但我留下了一个问题：我们的转账对网络不安全。**

### 一句话对比两集

| | EP6 | EP7 |
|---|---|---|
| 威胁 | **两个不同的请求**同时来 | **同一个请求**来两次 |
| 后果 | 透支 / 死锁 | **双重扣款** |
| 解法 | 行锁 + 顺序 + 重试 | **幂等键** |
| 在哪解决 | 数据库（锁是数据库原语） | **应用层（没有数据库原语能做这件事）** |

---

## 1. 现场演示：双重扣款（`4:29:45 – 4:32:27`）

### 他做的事：在 commit 之后、写响应之前，sleep 2 秒

> `[4:30:00]` To simulate that, I'll add a **two-second sleep right after the transfer, before we answer**... **The important part is where it is: after the transaction committed.**

**译文**：为了模拟这个，我在**转账之后、回答之前**加一个 2 秒的 sleep……**重要的部分是它放的位置：在事务提交之后。**

💡 **这个位置是全部的重点。** 如果 sleep 在 commit **之前**，事务还没提交，客户端超时重试时交易是安全的（第一次会回滚）。他偏偏放在**之后**——**钱已经动了，但客户端永远不会知道。**

### 客户端做的事：1 秒超时 → 重试

> `[4:30:59]` ...and **like every sensible HTTP client, ours has a timeout** — here one second, with `--max-time`.

```
operation timed out, after one second, with zero bytes received.
```

> `[4:31:14]` **From the app's point of view, the transfer may or may not have happened. It has no way to know.**

> `[4:31:29]` So it does what **every retry policy in the world** does: it tries again. Same body, same transfer, no timeout this time. And after the slow network's two seconds, **a 201 with the transaction ID**.

### 结果

> `[4:31:42]` Now the balance is: Alice deposited $25, and wanted to send 10. **She has 5 left, and Bob has 20. Alice paid twice.**

> `[4:31:56]` **Nobody did anything wrong.** The client retried after a timeout, **which is exactly what it should do**. And the server processed two valid requests, **which is also exactly what it should do**.

**译文**：**没有人做错任何事。** 客户端在超时后重试，**这正是它该做的**。而服务端处理了两个合法请求，**这也正是它该做的**。

> `[4:32:12]` The access log tells the same story: **two transfers, both 201, both took two seconds.** The first client hung up long before its response was written, **but the transaction had already committed.**

**译文**：访问日志讲了同样的故事：**两笔转账，都是 201，都花了 2 秒。** 第一个客户端在响应写出来之前早就挂断了，**但事务已经提交了。**

💡 注意这段日志证据链：**两行 201 都是"对的"**。这个 bug 的可怕之处是——**系统里没有任何东西看起来是错的**。账本平衡、约束通过、日志正常、状态码全对。

---

## 2. 为什么客户端**必须**重试（这是全集的分析基石）

> `[4:32:43]` So what went wrong? **A request can fail in three places, and they look identical to the client.**

```
① 请求在路上丢了        → 服务端根本没看到它
② 服务端中途失败        → 事务回滚，什么都没发生
③ 服务端做完了、提交了  → 但响应丢了
```

> `[4:32:58]` **The request can be lost on the way — the server never saw it — and a retry is exactly right.**
>
> `[4:33:12]` **The server can fail halfway — maybe a crash, or a database error — the transaction rolls back, nothing happened — and again a retry is right.**
>
> `[4:33:12]` **Or the server finished, committed, and the response got lost. Then a retry runs the transfer a second time — and not retrying is wrong too.**

> `[4:33:26]` **In the first two cases, a client that gives up means a payment that silently never happens, which is its own kind of incident.** So **the client must retry, and the server must make that safe.**

**译文**：**在前两种情况下，放弃的客户端意味着一次付款静默地从未发生——那本身就是一种事故。** 所以**客户端必须重试，而服务端必须让重试变安全。**

💡 这一段的价值：**它把"要不要重试"这个讨论彻底终结了**。

| 策略 | 后果 |
|---|---|
| 客户端不重试 | 情况 ①② → **用户付了钱但没到账**，或者"钱没动"但用户以为动了 |
| 客户端重试，服务端无幂等 | 情况 ③ → **双重扣款** |
| 客户端重试 + 服务端幂等 | **三种情况全部正确** ✅ |

**"客户端不该重试"是错的，"服务端应该拒掉重试"也是错的。唯一正确的答案是让重试在语义上安全。**

> `[4:33:41]` When a retry arrives, **the server has to recognize it, and answer it, without doing the work again.** In other words, **the operation has to be idempotent: doing it twice has the same effect as doing it once.**

---

## 3. 幂等键的契约

> `[4:33:59]` The standard way to do that, used by the major payment APIs, is an **idempotency key**. The client sends a header `Idempotency-Key` with a unique value.

### 客户端的那一条规则

> `[4:34:14]` **The rule for the client is simple: one key per operation.** It generates a random UUID **before the first attempt**, and sends **the same key on every retry of that operation**. **A new transfer gets a new key.**

💡 "**一次操作**一个 key"——注意不是"一个请求一个 key"，也不是"一分钟一个 key"。**一次业务意图**。这个定义是客户端唯一需要理解的东西。

### 哪些请求需要它（他的划分很精确）

> `[4:34:44]` We'll **require the header on every request that moves money** — deposits and transfers. **Reads don't need it, because reading a balance twice is already harmless. Creating a wallet doesn't need it either — one wallet per owner and currency is a unique constraint, so a retry gets a conflict, not a second wallet.**

| 操作 | 需要 key？ | 为什么 |
|---|---|---|
| `GET` 余额 / 流水 | ❌ | 读两次无害 |
| `POST /wallets` | ❌ | **唯一约束已经让它"幂等"**（第二次是 409） |
| `POST /deposits` | ✅ | 会重复加钱 |
| `POST /transfers` | ✅ | 会重复转账 |

💡 注意第二行的逻辑：**唯一约束是"数据库层的幂等键"**。这是 EP5 `CreateAccount` 不做"先查再插"的回报——**它天然就是幂等的**。

### 作用域与保留期

> `[4:34:59]` ...and **keys are scoped per caller**, so Alice's keys can never collide with Bob's.

> `[4:35:16]` We remember each key for **24 hours**, which is **far longer than any retry policy waits**.

⚠️ 但这一集的实现里，**所有 caller 都是 `"anonymous"`**（`[4:53:57]` 明说）。他留了这个洞，EP8/EP10 才补。见 §11。

---

## 4. 五种情况：完整决策表（`4:35:16 – 4:37:13`）

这是全集最该背下来的一段。

| # | 情况 | 行为 | 状态码 |
|---|---|---|---|
| 1 | **从没见过的 key** | 执行请求，**存下状态码和 body** | 正常（201） |
| 2 | 同一个 key，**同一个请求**，已完成 | **逐字节重放**存下的响应，多加一个头 | 原状态码 + `Idempotent-Replayed: true` |
| 3 | 同一个 key，**不同的请求** | **拒绝**，`idempotency_key_reused` | **422** |
| 4 | 同一个 key，**第一个还在跑** | **拒绝**，`request_in_progress` | **409** |
| 5 | 请求**失败**了（如校验错误） | **什么都不存，释放 key** | 原错误 |
| 6 | 需要 key 但**没给** | 拒绝 | **400** |

### 情况 3：为什么必须 422，不能"悄悄重放旧的"

> `[4:35:45]` **The same key with a different request — that's a client bug**, like reusing a key for a new transfer. **We refuse it with a 422... Silently replaying the old response would hide that bug, and running the new request would break the promise of the key.**

**译文**：**同一个 key 配不同的请求——那是客户端的 bug**，比如把一个 key 复用到新的转账上。**我们用 422 拒绝它……悄悄重放旧响应会掩盖这个 bug，而执行新请求会破坏 key 的承诺。**

💡 两个错误选项都被明确否定了。**422 是唯一"诚实"的选择**：它把这个矛盾暴露给客户端。

### 情况 4：为什么不"等它跑完再重放"

> `[4:36:14]` **A 409 request in progress.** We could make the duplicate **wait and then replay**, but **that holds a connection open for nothing**, and **a client that retries this fast should just back off and try again.**

**译文**：**409 request in progress。** 我们可以让重复的请求**等待然后重放**，但**那白白占住一个连接**，而且**重试得这么急的客户端本来就该退避再试。**

💡 这是一个**容量决定伪装成正确性决定**：等待式设计在重试风暴下会**耗尽服务端连接**。

### 情况 5：失败不烧 key —— 这个选择很重要

> `[4:36:30]` If the request failed, like a validation error, **we store nothing, and release the key. Nothing happened, so there's nothing to protect, and the client can fix its request and send it again with the same key.**

> `[4:36:43]` **Some APIs store errors too, so the key is used up** — then **a typo means minting a new key, and a passing hiccup is replayed forever.**

**译文**：**有些 API 连错误也存，于是这个 key 就被用掉了**——那么**一个错字意味着要造一个新的 key，而一次短暂的抖动会被永久重放。**

💡 两种设计的对比：

| 设计 | 客户端体验 | 风险 |
|---|---|---|
| 失败不烧 key（他选的） | 改一下请求，**同一个 key 再试** | 无 |
| 失败也存（有些 API） | 每次失败都要新 key | **永久重放一次瞬时故障** |

演示里他验证了这条（`[5:11:41]`）：Alice 转 $50 余额不足 → 充值 → **用同一个 key 重试** → 成功。

---

## 5. 全集最重要的决定：key 什么时候标记完成

> `[4:37:13]` Now **the most important decision of the episode: when is the key marked as completed?**

### 错误版本：先提交，再标记（`4:37:13 – 4:37:42`）

> `[4:37:13]` The **obvious** design writes it **after** the work: `BEGIN`, post the transfer, `COMMIT` — **the money has moved** — and then, before we can mark the key completed, **the process dies** (a deploy, an out-of-memory kill, a node going away). **The key is still marked "in progress". The client retries, finds no completed key, and runs the transfer again.**

> `[4:37:42]` **We built an idempotency system, and it double-charged anyway.**

**译文**：**我们建了一套幂等系统，结果它还是双重扣款了。**

```
        ┌─ 事务 ─────────────┐
BEGIN → 转账 → COMMIT                            ← 钱动了
                    ↓ 窗口（崩溃、OOM、发布）
              标记 key = completed                ← 没执行到
```

### 正确版本：在**同一个事务**里

> `[4:37:42]` The fix: **complete the key inside the same database transaction that posts the transfer, together with the response we're about to send.** Then there's **one commit, and PostgreSQL makes it atomic.** **The key is completed if, and only if, the money moved.**

> `[4:38:12]` **Crash before the commit, and neither happened, so the retry runs it safely. Crash after it, and both happened, so the retry gets the stored response. There's no moment in between.**

**译文**：**在 commit 之前崩溃，两件事都没发生，所以重试是安全的。在之后崩溃，两件事都发生了，所以重试拿到存着的响应。中间没有那个时刻。**

```
        ┌─ 一个事务 ───────────────────┐
BEGIN → 转账 → 标记 key=completed + 存响应 → COMMIT
                                              ↑
                                  钱动了 ⟺ key 完成了
```

💡 **这是整个 EP07 的一句话。** 它和 EP2 的"延迟约束在 COMMIT 时检查"、EP6 的"锁持有到 COMMIT"是同一个思想的第三次应用：**原子性的边界是 COMMIT，任何需要和钱同时成立的东西，必须放进同一个事务。**

### 5.1 由此推出：不能用 middleware

> `[4:38:27]` That decides **where the code lives**. The usual place for something that touches every request is **HTTP middleware**. **But middleware wraps the handler from the outside — it sees the response only after the handler returns, and that's after the transaction committed.**

> `[4:38:43]` The only way around that is to **hide the transaction in the request context, and have the store fish it out — which is implicit and easy to get wrong.** So we'll write **a helper that owns the transaction instead**: it begins it, hands it to the work, completes the key in it, and commits.

**译文**：这就决定了**代码该放在哪里**。处理每个请求的常见位置是 **HTTP 中间件**。**但中间件从外面包住 handler——它只在 handler 返回之后才看到响应，而那已经是事务提交之后了。**

唯一的绕法是**把事务藏进 request context，让 store 去捞出来——那是隐式的、很容易出错。** 所以我们写**一个拥有事务的 helper**。

💡 这一段说明了一件重要的设计推理：**"放在哪一层"不是风格问题，是被"什么时候需要原子性"决定的。** 中间件在架构图上"位置更好"，但它在时间上**太晚了**。

### 5.2 `Store.WithTx`：让 wallet 加入别人的事务

> `[4:39:10]` The wallet joins that transaction through a small `WithTx` method on the store — **a store bound to the caller's transaction**, the same idea as sqlc's own `WithTx`. **The service code doesn't change at all.**

```go
// store.go
func (s *Store) WithTx(tx pgx.Tx) *Store {
	return &Store{pool: s.pool, q: s.q.WithTx(tx), tx: tx}   // ← 多了一个 tx 字段
}

// ledger.go —— inTx 只多了两行
func (s *Store) inTx(ctx context.Context, fn func(*walletdb.Queries) error) error {
	if s.tx != nil {
		// 已经在调用方的事务里：不 begin、不 commit、不 retry，直接跑
		return fn(s.q)
	}
	return postgres.Retry(ctx, func() error { return s.tryTx(ctx, fn) })
}
```

> `[4:52:46]` ...`WithTx` returns **a copy of the store**, with sqlc's queries bound to that transaction. **The comment states the deal: the caller commits it, and the caller retries it.**

**译文**：……`WithTx` 返回**store 的一个副本**，sqlc 的查询绑定到那个事务上。**注释写明了交易条件：调用方负责提交它，调用方负责重试它。**

💡 **"the caller commits it, the caller retries it"** —— 两句话定义了所有权转移。这比任何文档都清楚。而且它解释了为什么 `inTx` 要跳过 `Retry`：**重试必须包住整个事务（包括 key 的完成），不能只包住里面的一段。**

---

## 6. 表设计：每一列都有理由

```sql
CREATE TABLE idempotency_keys (
    scope          text        NOT NULL,   -- 调用方
    key            text        NOT NULL,   -- 客户端给的
    fingerprint    bytea       NOT NULL,   -- 32 字节，请求的指纹
    status         text        NOT NULL,   -- in_progress | completed
    response_code  int,                    -- NULL 直到完成
    response_body  bytea,                  -- 重放时逐字节还原
    created_at     timestamptz NOT NULL,
    locked_at      timestamptz NOT NULL,   -- 最后一次"认领"的时间
    completed_at   timestamptz,
    expires_at     timestamptz NOT NULL,
    PRIMARY KEY (scope, key),
    CHECK ((status = 'completed') = (response_code IS NOT NULL)),
    ...
);
CREATE INDEX ON idempotency_keys (expires_at);
```

### 主键不只是索引

> `[4:41:09]` **The primary key is the scope and the key together. That's not just an index — it's what makes two requests with the same key wait for each other**, as we'll see.

**译文**：**主键是 scope 加 key。它不只是一个索引——它正是让两个同 key 请求互相等待的机制。**

💡 这是本集最容易被忽略的一句。**唯一索引在 Postgres 里有一个副作用：并发插入同一个键时，第二个 INSERT 会阻塞，直到第一个事务提交或回滚。** 所以 `INSERT ... ON CONFLICT DO NOTHING` 天然提供了"同一时刻只有一个 claim 成功"的保证。

> `[4:47:26]` ...`ON CONFLICT DO NOTHING`. If the key is new, we inserted it. **If another request is inserting the very same key at this moment, PostgreSQL makes us wait on the primary key until that transaction commits, and then we conflict. So two claims can never both win.**

### `fingerprint`：32 字节代表整个请求

> `[4:40:11]` ...the fingerprint is **a SHA-256 of the method, the path, and the canonical body** — **32 bytes that identify the request, without storing the request itself.**

> `[4:44:16]` The **canonical body**: two requests that differ only in spaces, **or in the order of their fields, decode to the same struct, so they get the same fingerprint.** Change any value, and the fingerprint changes. And **since our decoder rejects unknown fields, nothing can hide in the body that the fingerprint doesn't cover.**

**译文**：**规范化 body**：两个请求只差空格、**或者字段顺序不同，会解码成同一个结构体，所以得到同一个指纹。** 改任何一个值，指纹就变。而且**因为我们的 decoder 拒绝未知字段，body 里藏不住指纹没覆盖的东西。**

💡 两件事在这里闭环了：

1. **规范化** = `json.Marshal(解码后的结构体)`。所以 `jq` 美化过的、字段排序过的同一个请求，**指纹相同**——他在演示里验证了这一点（`[5:11:09]`）。
2. **`DisallowUnknownFields`（EP4）成了指纹完整性的一部分**。如果允许未知字段，客户端可以加一个 `"x":1` 改变语义但指纹不变 → 绕过幂等保护。

**一个 EP4 的"严格性"决定，在 EP7 变成了一条安全属性。** 这是这门课里最漂亮的前后呼应之一。

### `response_body` 存字节，不存 JSON

> `[4:40:38]` ...the response we sent, **the status code and the body, as raw bytes, so a replay is exact.**

> `[4:44:44]` ...`JSON` builds one **exactly the way `httpx.WriteJSON` does, with the trailing newline, so a fresh response and a replay are the same bytes.**

> `[4:45:02]` ...`Write` sends it, **adding the replayed header only for a replay. Everything else — the status, the content type, and the body — is exactly what the first request got.**

💡 **逐字节一致**是他的原话（`byte for byte`）。这也是为什么 `idempotency.JSON()` 必须复用 `httpx` 的序列化路径——否则首次响应有 trailing newline、重放没有，字节就不同了。

### `CHECK` 约束

```sql
CHECK ((status = 'completed') = (response_code IS NOT NULL))
```

> `[4:41:22]` **A check constraint ties the status to the response**: a completed key **always has one**, and an in-progress key **never does**.

💡 和 EP5 的 `CHECK ((kind='wallet') = (owner_id IS NOT NULL))` 是**同一个语法、同一个思想**：**两个字段的取值必须一致，一致性写在数据库里。**

### `expires_at` 索引

> `[4:41:37]` ...and an index on `expires_at`, **so the cleanup job can find old keys without reading the whole table.**

---

## 7. Claim 是一个 **lease**（租约），不是锁

> `[4:46:26]` One more case: **a claim that never finishes**, because the process died between steps 2 and 3. **Its row says "in progress" forever.** So **a claim is really a lease**: after a minute, a retry may take it over.

> `[4:46:40]` That's safe for exactly the reason we just discussed: **a claim that never completed the lease is 1 minute. No request of ours takes anywhere near that long, so a claim that old belongs to a request that's gone.**

**译文**：这是安全的，理由正是我们刚讨论过的：**租约是 1 分钟。我们的任何请求都远不需要那么久，所以那么老的 claim 属于一个已经消失的请求。**

> `[4:46:56]` **These are constants, not configuration, on purpose — they are part of the contract with clients, and they shouldn't quietly differ between environments.**

**译文**：**这些是常量，不是配置，这是故意的——它们是和客户端的契约的一部分，不应该在不同环境里悄悄不同。**

💡 这句话值得单独记：**"可配置"并不总是优点。** 一个行为如果影响 API 语义（重放窗口、租约长度），把它做成配置只会让 staging 和 prod 的行为不一致。

### 接管的安全前提

接管之所以安全，是因为 §5 的原子性：

> `[4:47:56]` ...`existing` starts by reading the row with `SELECT ... FOR UPDATE`. **That lock matters for takeovers: if two retries find the same abandoned claim, the second one waits here, and then sees the first one's fresh `locked_at`.**

> `[4:48:37]` ...and whether the claim is older than the lease, **computed by Postgres, so the clocks of different servers never matter.**

**译文**：……以及这个 claim 是否比租约更老，**由 Postgres 计算，所以不同服务器的时钟永远不影响结果。**

💡 **用数据库的时间，不用应用服务器的时间。** 多副本部署时，`time.Now()` 在五台机器上可能是五个不同的值。

### 决策顺序也是设计

> `[4:49:06]` And the decision — **and the order matters**: **a different fingerprint comes first** — a reused key is refused **even when its first request completed**, **so a different request can never read somebody else's stored response.**

**译文**：而判定——**顺序很重要**：**指纹不同排在最前面**——一个被复用的 key **即使在它第一个请求已完成时也要拒绝**，**这样一个不同的请求永远读不到别人存着的响应。**

```go
switch {
case !bytes.Equal(row.Fingerprint, key.fingerprint):  // 先查这个
	return reused                                    // 422
case row.Status == "completed":
	return replay(row.Response)                      // 重放
case !row.Expired:                                   // 还在租约内
	return inProgress                                // 409
default:
	return takeover()                                // 接管
}
```

💡 如果把这个顺序反过来（先看 completed），一个**猜中别人 key** 的请求就能读到别人的转账响应。**这是一个安全漏洞，不是一个功能 bug。**

---

## 8. `attempt`：work + complete 在同一事务

> `[4:49:50]` It begins a transaction **at READ COMMITTED, explicitly**, like the wallet does, **because the row locks inside a transfer were written for that level**.

> `[4:50:20]` ...then, **still in that transaction**, we complete the key: status completed, the response code and body, and the completion time. **Look at the `WHERE` clause: `status = 'in_progress'`. Normally it is — but if a takeover happened, two requests could be running the same key, and this check makes sure only one of them can commit. The other updates zero rows, returns "in progress", and its rollback erases its transfer.**

**译文**：……然后**在同一个事务里**完成 key……**看 `WHERE` 子句：`status = 'in_progress'`。正常情况下它成立——但如果发生了接管，两个请求可能在跑同一个 key，而这个检查保证只有一个能提交。另一个更新零行，返回 "in progress"，然后它的回滚把自己的转账擦掉了。**

```sql
UPDATE idempotency_keys SET status='completed', response_code=$3, response_body=$4, completed_at=now()
WHERE scope=$1 AND key=$2 AND status='in_progress';   -- ← 乐观锁
```

💡 这是**双保险**：
- `SELECT FOR UPDATE` 防的是"同时 claim"
- `UPDATE ... WHERE status='in_progress'` 防的是"claim 之后被接管"

**两个请求可能都通过了 claim**（因为租约过期被接管），但只有一个能通过这个 `UPDATE`。另一个的整个事务回滚——**包括它已经写进去的转账分录。**

---

## 9. `release`：失败路径也必须安全

> `[4:51:34]` `release` deletes the claim, **but only while it's still in progress, so it can never delete a completed key.** **It runs even if the client hung up — which cancels the request's context — so it uses `context.WithoutCancel`, with a short timeout.** And if the delete fails, **we only log it**: `delete` runs out, **and a retry takes the key over.**

**译文**：`release` 删除这个 claim，**但只在它仍然是 in progress 时，所以它永远删不掉一个已完成的 key。** **它即使在客户端挂断（这会取消请求的 context）时也要执行——所以它用 `context.WithoutCancel`，带一个短超时。** 而如果删除失败，**我们只记日志**：删除超时了，**重试会把这个 key 接管过去。**

💡 三个细节都是"踩过坑才写得出来"的：

1. `WHERE status='in_progress'` → 保护已完成的 key 不被删
2. `context.WithoutCancel` → 客户端断开时，请求的 ctx 已取消，用原来的 ctx 发 DELETE **必然失败**
3. **删除失败只记日志** → 因为租约兜底。**这就是为什么设计里每个环节都有第二条路。**

> `[4:52:04]` **That's the nice property of this design: every failure path ends in a state that's safe to retry.**

**译文**：**这就是这个设计优雅的地方：每一条失败路径都终止在一个可以安全重试的状态。**

💡 可以列一张表验证这句话：

| 崩溃点 | 留下的状态 | 重试时发生什么 |
|---|---|---|
| claim 之前 | 无行 | 正常 claim |
| claim 之后、work 之前 | `in_progress`，租约内 | 409，1 分钟后接管 |
| work 中、commit 前 | 事务回滚 + `in_progress` | 同上 |
| **commit 后、响应前** | **`completed`** | **重放** ✅ |
| release 失败 | `in_progress` 过期 | 接管 |

---

## 10. Redis：只是快速路径，**允许失败**

> `[4:56:43]` So far, every request costs **two short PostgreSQL transactions**, even a replay. **Retries tend to come in storms** — a whole fleet of phones reconnecting at once — so let's answer replays from memory. **But PostgreSQL stays the source of truth**: the key commits with the money, and **every decision can still be made from PostgreSQL alone.**

### 三条硬约束

> `[4:57:11]` This **only holds completed responses for an hour** — a retry storm for a finished request **never touches the database**, and **it can't go stale**: a completed response never changes.

> `[4:57:25]` And **keys that are in progress never go in the cache.**
>
> `[4:57:25]` **If Redis is down, or slow, we log a warning and ask Postgres. We fail fast, with short timeouts, and no retries — and we never fail closed. Refusing payments because our cache is down would be an outage we chose.**

**译文**：**如果 Redis 挂了或很慢，我们记一条警告然后去问 Postgres。我们快速失败，用很短的超时，不重试——而且我们绝不 fail closed。因为我们的缓存挂了就拒绝支付，那是一场我们自己选择的故障。**

💡 **"fail open" vs "fail closed"** —— 这个决定必须显式做。对于**缓存**，答案永远是 fail open：**Postgres 才是真相，缓存只是加速。**

### 为什么不用 Redis 单独做（很多人这么干）

> `[4:57:39]` You'll also see designs that use **Redis alone, with `SET NX` as the lock**. It's fast, **but Redis can't join the ledger's transaction, so we're back to the window between moving money and completing the key.** And **an eviction under memory pressure, or a failover to a replica that missed the last writes, forgets keys — and a forgotten key is a double charge.**

**译文**：你也会看到**只用 Redis、拿 `SET NX` 当锁**的设计。它很快，**但 Redis 无法加入账本的事务，所以我们又回到了"钱动了"和"key 完成了"之间那个窗口。** 而且**内存压力下的淘汰，或者故障切换到一台漏了最后几次写的副本，会忘掉 key——而一个被忘掉的 key 就是一次双重扣款。**

💡 这段拆掉了两个常见的误解：

| 误解 | 现实 |
|---|---|
| "Redis 有 SETNX，可以做分布式锁" | 能做锁，**不能加入别人的数据库事务** |
| "Redis 是持久化的" | **淘汰/主从切换会真丢**。丢一行 = 双重扣款 |

### Redis 客户端设置：为"缓存"而不是"数据库"调

> `[4:58:53]` ...then the settings that make it a **good cache**: **half a second to connect, 200 milliseconds to read or write, a single dial attempt, and no retries.** **The defaults are made for Redis as a database: they retry and wait**, and with Redis down a request took **almost two seconds**. **For a cache, giving up quickly is the feature.**

**译文**：……然后是一些让它成为**好的缓存**的设置：**连接 0.5 秒、读写 200 毫秒、只拨一次、不重试。默认值是为"把 Redis 当数据库用"设计的：它们重试、它们等**，而 Redis 挂掉时一个请求花了**将近两秒**。**对缓存来说，快速放弃才是特性。**

💡 具体数字：`go-redis` 默认 `MaxRetries: 3` + 退避，三次重试 ≈ 1.5–2 秒。**一个"可选"的组件不该让主流程慢 2 秒。**

### 一个诚实的细节：缓存写入在 commit 之后

> `[5:01:56]` ...and **after a successful attempt we remember the response. Notice it's after the commit** — if we cached it before, and the commit failed, **Redis would replay a transfer that never happened.**

**译文**：……而且**在一次成功的 attempt 之后我们才记住响应。注意它在 commit 之后**——如果我们提前缓存，然后 commit 失败，**Redis 就会重放一笔从未发生过的转账。**

💡 和 §5 是同一个原理，只是换了一个存储：**任何"钱已动"的声明，必须晚于 commit。**

---

## 11. 测试：20 个并发同 key

> `[5:07:02]` ...the test this episode is really about. Alice gets **ten dollars**, then **one transfer of a dollar, sent 20 times at once, with the same key** — a client retrying in a panic. We reuse `concurrently` from last episode, **with its starting gun**, so all 20 really overlap.

> `[5:07:31]` ...each goroutine puts its response in a **buffered channel**, which needs no lock, and after close, we can range over it. Then we sort the responses: **a 409 was refused while the first one ran; a 201 with the replayed header is a replay; a 201 without it actually ran**; anything else fails the test.

**收集与断言**：

> `[5:08:00]` ...**every 201 body goes in a set, so we can check they're identical.** We lock the counts, and the assertion: **exactly one ran, and every 201 has the same bytes.** Once it's all over, **one more retry must be replayed** with the same body. And the money check: **Alice has nine dollars, Bob has one — one dollar moved, not 20.**

> `[5:08:16]` **Without idempotency keys, this test would move all 20 dollars**, and Alice's ten-dollar wallet would refuse the last ten with insufficient funds.

**译文**：**如果没有幂等键，这个测试会移动全部 20 美元**，而 Alice 那个 10 美元的钱包会因为余额不足拒绝后面十笔。

💡 注意最后那句"**如果没有幂等键**"——他在解释**这个测试的鉴别力**。一个好的并发测试应该能说清楚"如果实现错了，会看到什么不一样的数字"。

### 他跑了三次

> `[5:08:30]` ...run it three times, verbose with `-run storm`. **Three runs, each time exactly one request ran**, and the logline shows what happened to the other 19: **refused while it was running, or replayed after it finished.**

💡 为什么跑三次：**19 个里面 409 和 201-replayed 的比例每次都不一样**（取决于调度），但"恰好一个真的执行了"必须每次成立。**这正是断言该断言的东西。**

### 测试故意不用 Redis

> `[5:03:23]` ...**and no cache on purpose. Redis only ever makes things faster, so if a test passes without it, the rules hold in Postgres alone, which is the part that has to be right.**

**译文**：……**而且故意不用缓存。Redis 只会让事情变快，所以如果一个测试在没有它的情况下通过，说明规则在 Postgres 里单独就成立——而那正是必须正确的部分。**

---

## 12. 他明确留下的洞

> `[5:14:35]` Our money moves **exactly once** now, no matter how often our client retries. **But right now every caller is anonymous, and anyone can move anyone's money.** Next time we build the auth service.

> `[4:53:57]` `caller` names who sent a request, for the key scope. **We don't authenticate anyone yet, so everyone is the same caller: anonymous.** In a few episodes, the gateway will verify a token, and this becomes the user's ID. **That matters for security too: without a scope, anyone who guessed another client's key could have that client's response replayed to them.**

**译文**：`caller` 指明是谁发的请求，用于 key 的作用域。**我们还没有认证任何人，所以所有人都是同一个 caller：anonymous。** 几集之后网关会验证 token，这里就变成用户 ID。**这对安全也很重要：没有作用域的话，任何猜中别人 key 的人，都能让那个客户端的响应被重放给自己。**

⚠️ **两个叠加的洞**：
1. `POST /v1/transfers` 无鉴权 → **任何人能动任何人的钱**（EP10 补）
2. 所有 caller 都是 `"anonymous"` → **幂等作用域形同虚设**（EP8/EP10 补）

**在 EP10 之前，这个服务绝不能上公网。** 而且注意：**洞 2 会让洞 1 更糟**——攻击者不仅能转钱，还能读取别人转账的响应。

---

## 13. 我的补注

### ① 24 小时的 TTL 是在赌什么

> `[4:35:16]` We remember each key for 24 hours, which is far longer than any retry policy waits.

风险场景：客户端在第 25 小时重试一个"以为失败"的操作 → **双重扣款**。

判断标准：**TTL > 客户端可能重试的最长时间窗口**。Stripe 是 24 小时，因为它的客户端 SDK 不会重试那么久。**如果你的客户端有离线队列（比如移动端），24 小时可能不够。**

### ② fingerprint 不包含 header

`fingerprint = sha256(method + path + canonical body)`。**不含任何 header。**

于是：同一个 key、同一个 body，但 `Authorization` 不同 → **指纹相同**。在 `scope` 正确时没问题（不同用户不同 scope），但**如果 scope 是 anonymous**，两个不同用户的请求就会互相重放。

**这就是为什么 §12 那个洞是安全问题，而不只是功能缺失。**

### ③ 缓存先查、claim 后查的时序

```
run:
  1. cache.Lookup(scope, key)     ← 命中就直接返回
  2. claim                        ← 没命中才走这里
```

如果缓存命中但**指纹不同**呢？`cache.go` 里存了 fingerprint，所以会返回 422——**和 Postgres 路径一致**（`[5:00:58]` 明说了）。

但有一个边界：**缓存里的条目可能是上一次操作的**，而 Postgres 里已经过期了。因为缓存 TTL（1h）< key TTL（24h），所以**缓存永远比数据库先过期**——**方向是对的**。如果反过来，就会重放一个数据库已经遗忘的操作。

### ④ `context.WithoutCancel` 是 Go 1.21 的一个小宝藏

```go
ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*time.Second)
defer cancel()
```

`WithoutCancel` 保留了 context 的 **values**（所以 request id 还在），但**去掉了取消传播**。没有它，"客户端断开后清理资源"这类操作根本写不出来。

**这是本集唯一一个纯粹靠 Go 标准库就能优雅解决的问题**，其他所有问题都是设计问题。

---

## 14. 自测题

1. 请求失败的三种位置分别是什么？为什么客户端**必须**重试？
2. 为什么"失败也把 key 存下来"是个坏设计？给出两种实际后果。
3. 把 key 的完成放在事务**外面**，具体在哪个时刻崩溃会导致双重扣款？
4. 为什么不能用 HTTP middleware 做幂等？在时间轴上，它错过了什么？
5. 主键 `(scope, key)` 为什么"不只是索引"？它提供了什么保证？
6. 为什么 `DisallowUnknownFields`（EP4 的决定）是指纹完整性的必要条件？
7. 决策顺序如果把"已完成就重放"放在"指纹不同就拒绝"之前，会导致什么安全漏洞？
8. `UPDATE ... WHERE status='in_progress'` 这道检查防的是什么？什么情况下两个请求会同时通过 claim？
9. 为什么 Redis 只能做快速路径？举出它单独使用时会丢数据的两条路径。
10. 为什么 `release` 要用 `context.WithoutCancel`？不用会发生什么？
11. 20 个并发同 key 的测试里，19 个的响应分成哪两类？为什么这个比例每次都不同？
