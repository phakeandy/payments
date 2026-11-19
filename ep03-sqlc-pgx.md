# EP3 讲义：Type-Safe SQL with sqlc + pgx

- **视频** `1:17:49 – 2:05:17`（47 分 28 秒）
- **分支** `ep03` ｜ diff：`+836 / -0`（15 个文件）
- **转录** `media/ep03.txt`（310 句，6,082 词）
- 时间戳是视频绝对时间

一句话：**让 SQL 保持是唯一真相，Go 代码从它推导出来。**

---

## 0. 本集的承诺

> `[1:17:55]` Last time we designed a ledger that refuses to store money that doesn't add up, but so far only psql has ever talked to it. Today our Go code finally meets the database.

**译文**：上一集我们设计了一个拒绝存储加不起来的钱的账本，但到目前为止只有 psql 跟它说过话。今天我们的 Go 代码终于要和数据库见面了。

---

## 1. 三种让 Go 和 Postgres 对话的方式

> `[1:19:21]` There are three common answers.

### ① 手写 `database/sql` + 逐列 Scan

> `[1:19:29]` You write the query as a string, and then scan each column into a struct field **in exactly the right order**. It's explicit, which is good. But the column order now lives in two places. A typo in a column name only shows up when that code path runs.

**译文**：你把查询写成字符串，然后**按完全正确的顺序**把每一列 Scan 进结构体字段。显式，这是优点。但列顺序现在活在两个地方。列名打错只会在那条代码路径真的跑起来时才暴露。

### ② ORM

> `[1:19:51]` You describe your structs, and the library writes the SQL for you. That's great for a quick prototype, but the SQL that actually runs is hidden, so performance problems like N+1 queries sneak in, and you end up fighting the ORM the moment you need something it doesn't model well. **And our ledger uses exactly those things: a view, deferred constraint triggers, and composite foreign keys.**

**译文**：你描述结构体，库替你写 SQL。做原型很棒，但**真正执行的 SQL 是隐藏的**，于是 N+1 这类性能问题悄悄钻进来；一旦你需要它没建模好的东西，你就得跟 ORM 打架。**而我们的账本恰好用的就是那些东西：一个视图、延迟约束触发器、复合外键。**

💡 最后一句是决定性的。ORM 的失败不在于"慢"，在于**它无法表达你的不变量**。EP2 里那三条约束，没有任何 ORM 能自动处理。

### ②.5 半自动（sqlx / `pgx.CollectRows`）

> `[1:20:34]` They do cut the boilerplate… But the SQL is still a string the compiler can't check, so a renamed column is still a runtime error, bound by a user or with luck by a test.

**译文**：确实减少了样板代码……但 SQL 仍然是编译期无法检查的字符串，改个列名依然是运行时错误，由用户来发现，或者运气好被测试发现。

### ③ sqlc：「把 ORM 的想法掉过头来」

> `[1:20:50]` The third answer is sqlc, and it flips the ORM idea around. You write **real SQL in SQL files** with a name on each query. Then sqlc reads your schema, checks every query against it, and generates the Go code you would have written by hand.

**译文**：第三种答案是 sqlc，它把 ORM 的思路掉过头来。你在 SQL 文件里写**真正的 SQL**，每个查询一个名字。然后 sqlc 读你的 schema，用 schema 校验每个查询，再生成你本来要手写的那份 Go 代码。

> `[1:21:11]` There's **no reflection at runtime, and no query builder**. The generated code is plain Go that you can read, step into with a debugger, and commit.

**译文**：**运行时没有反射，也没有查询构造器。** 生成的是普通 Go 代码，你可以读、可以用调试器单步进去、可以提交进仓库。

> `[1:21:22]` So **SQL stays the source of truth, and Go is derived from it.** If a query references a column that doesn't exist, sqlc refuses to generate. If you change a query's parameters, the Go compiler points at every caller that needs updating.

**译文**：于是 **SQL 保持是真相来源，Go 是从它推导出来的。** 查询引用了不存在的列，sqlc 拒绝生成。你改了查询参数，Go 编译器会指出每一个需要改的调用点。

> `[1:21:39]` The trade-off: sqlc isn't great at truly dynamic queries, like a search form with 10 optional filters. For those, you can still drop down to plain pgx. **In a payment system, almost every query is fixed and known in advance, so sqlc is a perfect fit.**

**译文**：代价是：sqlc 不擅长真正动态的查询，比如有 10 个可选过滤条件的搜索表单。那种情况你可以退回裸 pgx。**在支付系统里，几乎每个查询都是固定且预先知道的，所以 sqlc 非常合适。**

---

## 2. `sqlc.yaml`：把 schema 指回 migrations

> `[1:24:56]` sqlc understands golang-migrate's file layout, it reads the **up** migrations in order, and **ignores the down files**, so there's no second copy of this schema to keep in sync.

**译文**：sqlc 懂 golang-migrate 的文件布局，它按顺序读 **up** 迁移、**忽略 down 文件**，所以不存在"schema 的第二份拷贝需要同步"这个问题。

💡 这是整个工具链最漂亮的一处闭合：**migrations 既是执行的脚本，又是类型检查的输入**。没有这一步，你就得维护一份 `schema.sql` 和一堆迁移，然后它们会漂移。

> `[1:25:31]` `sql_package: pgx/v5` tells sqlc to generate code for pgx's native interface instead of `database/sql`.
> **译文**：sql_package: pgx/v5 告诉 sqlc 为 pgx 的原生接口生成代码，而不是 database/sql。

### 2.1 三个 emit 选项

| 选项 | 作用 | 他给的理由 |
|---|---|---|
| `emit_json_tags` | 每个字段加 snake_case 的 JSON tag | `[1:25:49]` 调试和测试时方便 |
| `emit_empty_slices` | 无行的查询返回空切片而非 nil | `[1:25:54]` 编码成 `[]` 而不是 `null` |
| `emit_enum_valid_method` | 给枚举加 `Valid()` | `[1:26:04]` 在值进数据库之前就能检查 |

💡 `emit_empty_slices` 那条值得记住：Go 里 `nil` 切片 JSON 编码成 `null`，前端拿到 `null` 而不是 `[]` 会崩。这是**用生成器消灭一整类 bug**。

### 2.2 overrides：sqlc 灵活性的全部所在

> `[1:26:20]` By default, pgx represents a UUID with its own `pgtype.UUID`; we'd rather use Google's `uuid` package everywhere because that's what the rest of our code and most of the Go ecosystem uses.
>
> `[1:26:35]` For **nullable** UUID columns, like `owner_id`, we ask for a **pointer**, so a system account simply has a nil owner. And `timestamptz` becomes a plain `time.Time`, **because none of our timestamp columns can be null**.

**译文**：默认 pgx 用自己的 `pgtype.UUID` 表示 UUID；我们更希望全项目用 Google 的 `uuid` 包，因为代码其它部分和 Go 生态大多用它。对**可空**的 UUID 列（比如 `owner_id`）我们要求生成**指针**，这样系统账户的 owner 就是 nil。`timestamptz` 映射成普通的 `time.Time`，**因为我们的时间戳列都不允许为空**。

> `[1:26:52]` Overrides are where most of sqlc's flexibility lives. You can map any database type, or even **one specific column**, to your own Go type. A common next step is a custom money type. For now, printing `int64`s for amounts are exactly what we want.

**译文**：overrides 是 sqlc 灵活性的主要所在。你可以把任何数据库类型、甚至**某一个特定列**映射成你自己的 Go 类型。常见的下一步是自定义的 money 类型。眼下对金额打印 `int64` 正是我们要的。

💡 他说"以后可以换成 money 类型"——EP18 的 `fx` 包就是那个"以后"。

---

## 3. 查询文件：四个技巧

> `[1:27:23]` Every query starts with a special comment, `-- name:`, then the Go method name, then **how many rows it returns**. `:one` means exactly one row, `:many` means a slice, and `:exec` means no rows at all, just an error.

### 3.1 `RETURNING *` 不会变成脆弱的扫描

> `[1:28:04]` Don't worry about the star — **sqlc expands it into an explicit column list** in the generated code, so adding a column later can never silently shift the scanning.

**译文**：不用担心那个星号——sqlc 会在生成的代码里把它展开成显式的列清单，所以以后加一列绝不会悄悄让 Scan 错位。

### 3.2 命名参数 + cast：把可空参数变成必填

```sql
-- name: ListAccountsByOwner :many
SELECT * FROM accounts
WHERE owner_id = @owner_id::uuid
ORDER BY created_at;
```

> `[1:28:31]` `owner_id` is nullable in the table, so by default sqlc would ask for a pointer. But **asking for the accounts of a nil owner makes no sense**, so the cast to `uuid` tells sqlc this parameter is always a real value.

**译文**：`owner_id` 在表里可空，所以默认 sqlc 会要一个指针。但"查询 nil 所有者的账户"毫无意义，所以 cast 成 `uuid` 告诉 sqlc 这个参数永远是真实值。

💡 **用类型系统表达业务约束**，而不是靠运行时判断。同一个思想在 EP2 是 `UNIQUE (id, currency)`，在这里是一个 `::uuid`。

### 3.3 sqlc 也读视图

> `[1:28:57]` sqlc reads views as well as tables, so it knows the `balance` column is a `bigint` that can't be null, thanks to the coalesce and the cast in the view.

**译文**：sqlc 既读表也读视图，所以它知道 `balance` 列是不为空的 `bigint`——多亏了视图里的 `coalesce` 和 cast。

### 3.4 keyset pagination

> `[1:29:58]` This is keyset pagination. Instead of an offset, which makes PostgreSQL pass every skipped row, we ask for entries with an id **below the last one we saw**. Newest first, with a page size. Thanks to our index on `account_id`, each page is fast, no matter how deep you go.

**译文**：这叫游标分页。不用 offset（它会让 PostgreSQL 遍历每一条被跳过的行），我们要的是 id **小于我们上一条见过的**那些分录。倒序，带页大小。靠 `account_id` 上的索引，无论翻多深，每一页都快。

💡 为什么 `OFFSET 100000` 慢：Postgres 必须**生成并丢弃**前 10 万行。keyset 直接从索引的那一点开始读。这是 O(1) vs O(n) 的差别。

### 3.5 一行注释变成 godoc

> `[1:30:16]` A comment between the name line and the query ends up as the godoc comment too.
> **译文**：name 行和查询之间的注释，也会变成 godoc 注释。

💡 于是 `go doc` 里能直接看到"这个查询干什么"。这是让生成代码**有人味**的小细节。

### 3.6 其余注解

> `[1:30:26]` `:execrows` returns how many rows a statement affected, `:batchexec` queues many statements into a single round trip, `:copyfrom` uses PostgreSQL's COPY protocol for fast bulk inserts, and `sqlc.narg` marks a parameter as **explicitly nullable**, which is the clean way to write an optional filter.
> **译文**：:execrows 返回一条语句影响了多少行，:batchexec 把多条语句排进一次往返，:copyfrom 用 PostgreSQL 的 COPY 协议做快速批量插入，而 sqlc.narg 把参数标记为显式可空——这是写可选过滤条件的干净方式。

---

## 4. 生成的代码里，最重要的是 `db.go`

> `[1:32:04]` `db.go` is the smallest file, and the most interesting one. `DBTX` is an interface with **just the three methods** the queries need: `Exec`, `Query`, and `QueryRow`.
> **译文**：db.go 是最小的文件，也是最有意思的一个。DBTX 是一个接口，只有查询需要的三个方法：Exec、Query、QueryRow。

```go
type DBTX interface {
	Exec(context.Context, string, ...interface{}) (pgconn.CommandTag, error)
	Query(context.Context, string, ...interface{}) (pgx.Rows, error)
	QueryRow(context.Context, string, ...interface{}) pgx.Row
}
```

> `[1:32:11]` A pgx pool has them, a single connection has them, and **so does a transaction**. `New` wraps any of those in a `Queries` struct, and `WithTx` returns a copy that runs on a transaction instead.

**译文**：pgx 的连接池有这三个方法，单条连接有，**事务也有**。`New` 把其中任何一个包装成 `Queries`，`WithTx` 返回一个在事务上运行的副本。

> `[1:32:24]` Keep that in mind because **it's the key to running several queries atomically**.
> **译文**：记住这一点，因为它是「让多条查询原子地一起跑」的关键。

💡 这是全集最需要理解的一行设计：**事务性不是靠"记住用 tx"，而是靠类型流动。** `WithTx` 之后你手里的 `*Queries` 只能走事务，想绕过都不行。

### 4.1 `rows.Err()`：手写时最容易漏的一步

> `[1:33:16]` It loops over the rows and **checks `rows.Err()` at the end**, which is the step that's easiest to forget when you write this by hand. **Forget it, and a connection that dies halfway through looks like a short list, instead of an error.**

**译文**：它遍历完行之后**检查了 `rows.Err()`**，这是手写时最容易忘的一步。忘了它，一条中途断掉的连接看起来就像**一个短列表**，而不是错误。

💡 这是"静默数据损坏"的典型形态：分页少了半页，没有人报错。sqlc 替你消掉了这一类 bug。

### 4.2 他明确划出 sqlc 不管的三件事

> `[1:33:33]` It **doesn't manage the schema** — that's still golang-migrate's job. It **doesn't know about relationships**: if you write a join, you get a flat row struct, not an account with its entries nested inside. And it **never runs anything behind your back** — every query that reaches the database is one you wrote, and can paste straight into psql to `EXPLAIN` or debug.

**译文**：它不管 schema——那仍是 golang-migrate 的事。它不懂关系：你写 join，得到的是扁平的行结构体，不是把分录嵌套在账户里。它**从不背着你执行任何东西**——到达数据库的每条查询都是你写的，可以直接粘进 psql 去 `EXPLAIN` 或调试。

---

## 5. 演示：故意写错一个列名

> `[1:34:05]` In `ledger.sql` I'll make a **very believable mistake**, and call the column `entry_id` instead of `id`, and regenerate.
> **译文**：在 ledger.sql 里我会犯一个非常可信的错误：把列叫 entry_id 而不是 id，然后重新生成。

```
ledger.sql:15: column "entry_id" does not exist
```

> `[1:34:18]` With handwritten SQL in Go strings, this would have **compiled fine**, and failed on the first request in production. Here it fails on my laptop, before any Go code is even generated.

**译文**：如果 SQL 是写在 Go 字符串里手写的，这会**编译通过**，然后在生产环境的第一个请求上失败。而这里它在我笔记本上就失败了，甚至还没生成任何 Go 代码。

> `[1:34:44]` In CI, you can run `sqlc diff`, which **fails the build if someone edited a query but forgot to regenerate**.
> **译文**：在 CI 里你可以跑 sqlc diff，它会在「有人改了查询但忘了重新生成」时让构建失败。

💡 这两条合起来是一个完整的防线：**生成期拦截 + CI 拦截**。少了 `sqlc diff`，就有人会改了 SQL 忘了 regenerate，然后仓库里跑的是旧查询。

---

## 6. pgx 与连接池

> `[1:35:19]` pgx speaks Postgres's **binary protocol** directly, supports Postgres types like arrays, enums and json properly, and gives us **rich error details like the error code our trigger raises**.

**译文**：pgx 直接使用 Postgres 的**二进制协议**，正确支持数组、枚举、json 这些类型，并且给出**丰富的错误细节，比如我们触发器抛出的那个错误码**。

💡 那个错误码就是 `23514`。**这就是 EP2 里"选对错误码"的回报**：EP3 才有能力把它变成干净的 4xx。

> `[1:36:09]` Choosing pgx's native interface doesn't lock us in. pgx also ships an adapter called `stdlib`… So if a library ever insists on `database/sql` — a migration tool, or a reporting library — it can still run on pgx.

### 6.1 为什么必须用池

> `[1:36:40]` Opening a Postgres connection is expensive: there's a TCP handshake, maybe a TLS handshake, authentication, and on the server, **Postgres starts a whole new backend process for every connection**.

**译文**：打开一个 Postgres 连接很贵：TCP 握手、可能还有 TLS 握手、认证，而在服务端，**Postgres 为每一个连接启动一整个后端进程**。

### 6.2 他的参数

| 参数 | 值 | 理由（原话） |
|---|---|---|
| `MinConns` | 2 | `[1:37:16]` 冷启动后第一批请求不付连接成本 |
| `MaxConns` | 10 | 见下方那条"最重要的规则" |
| `MaxConnLifetime` | 1h + jitter | `[1:39:17]` 连接**黏在**它建立时的那台服务器上 |
| `MaxConnIdleTime` | 15m | 回收闲置 |
| `HealthCheckPeriod` | 30s | 池自己检查 |
| `ConnectTimeout` | 5s | `[1:37:34]` 网络死了要快速失败，不要挂住 |

> `[1:39:17]` Why recycle a perfectly good connection? After an hour, **because connections stick to the server they were opened against**. After a database failover, or when you add a read replica, old connections would never move.

**译文**：为什么要回收一条好端端的连接？一小时后，因为**连接黏在它打开时那台服务器上**。数据库做了主备切换、或者你加了一个只读副本，老连接永远不会迁过去。

> `[1:39:29]` And jitter spreads those reconnects out, so **10 connections opened at the same moment don't all expire at the same moment**.

**译文**：抖动把这些重连摊开，所以**同一时刻打开的 10 条连接不会在同一时刻一起过期**。

💡 和 EP6 的重试抖动是**同一个原理的两次应用**：避免同步。

### 6.3 全篇最重要的一条容量规则

> `[1:37:34]` Postgres has a **hard limit** on connections, 100 by default. Run 5 replicas of the wallet service with 10 connections each, and that's **50**, before any other service connects.

> `[1:38:04]` **A pool that's too big just moved the queue from your app into the database, where it's harder to see.**

**译文**：连接池开太大，只是**把排队从你的应用里搬到了数据库里**，而那里更难看清。

💡 这句是全片最好的一句话之一，值得单独记住：**连接池不是越大越好，它只是排队的位置。** 数据库里的队列不区分优先级、不可观测、还会拖垮所有服务。

### 6.4 池是懒连接的

> `[1:39:54]` Here's something that surprises a lot of people: **creating a pool doesn't actually connect to anything**. pgxpool opens connections lazily, in the background, so we ping with its own 5-second timeout. If the DSN is wrong, or the database is down, we find out **right now, at startup**, instead of on the first customer request.

> `[1:40:20]` And if the ping fails, we **close** the pool before returning, so we don't leak its background goroutines.

**译文**：有件事让很多人意外：**创建连接池其实不连接任何东西**。pgxpool 是懒连接的，在后台开。所以我们用自己单独的 5 秒超时去 ping 一次。DSN 错了、或者数据库挂了，我们现在就发现——在启动时，而不是在第一个客户请求上。ping 失败就关闭池，避免泄漏后台 goroutine。

---

## 7. Store 层：为什么 sqlc 已经有方法了还要它

> `[1:41:22]` You might ask why we need a store at all, when sqlc already gave us a method for every query. **Three reasons.**

> `[1:41:30]`
> 1. It's **the one place that knows about pgx and database transactions**.
> 2. It **translates database errors**, like `no rows`, into domain errors, like `account not found`.
> 3. It **keeps `walletdb` an implementation detail**, so the rest of the service never imports it.

**译文**：① 它是唯一知道 pgx 和数据库事务的地方。② 它把 `no rows` 这类数据库错误翻译成领域错误（"账户不存在"）。③ 它让 `walletdb` 成为实现细节，服务其余部分永不 import 它。

### 7.0 现在不定义 interface

> `[1:41:49]` And notice there's **no interface here yet**. In Go, you define an interface **where it's consumed**, when a consumer actually needs one. We'll add one the day a caller needs a fake store.

**译文**：注意这里还没有 interface。在 Go 里，interface 定义在**它被消费的地方**，当真的有消费者需要它时。哪一天有调用方需要一个假 store，我们就加。

💡 这是 Go 社区最容易被 Java/C# 背景的人搞反的一条。**不要预先抽象**，接口由消费者定义、越小越好。EP15 会用上这一点。

### 7.1 类型别名而不是复制结构体

> `[1:42:30]` The generated models are good domain types for now, so instead of copying them field by field, we **alias** them. `Account` in package `wallet` is the very same type as `walletdb.Account`.

> `[1:42:50]` If the domain types ever need to diverge from the table, **we replace an alias with a real struct, and the callers don't change.**

**译文**：目前生成的 model 就是不错的领域类型，所以我们**用别名**而不是逐字段复制。`wallet.Account` 和 `walletdb.Account` 是同一个类型。哪天领域类型需要和表结构分道扬镳，我们把别名换成一个真正的结构体，**调用方一行都不用改**。

💡 这是"一个别名的技术债，未来的重构成本为零"。反过来说：如果一开始就复制结构体，你就永远在同步两份。

### 7.2 每个方法第一个参数都是 ctx

> `[1:43:47]` And notice that every method takes a context as its first argument. That's how **deadlines and cancellation flow** through the whole service. If the client disconnects or a timeout expires, pgx stops waiting and returns an error straight away.
> **译文**：注意每个方法的第一个参数都是 context。截止时间和取消就是这样流过整个服务的。如果客户端断开或者超时到期，pgx 立刻停止等待并返回错误。

> `[1:44:12]` For a hard limit on the server side as well, Postgres has a `statement_timeout` setting, which you can set **per database or per connection**.
> **译文**：服务端也要一条硬上限的话，Postgres 有 statement_timeout，可以按数据库或按连接设置。

💡 两道防线：客户端 ctx（应用侧）+ `statement_timeout`（数据库侧）。后者连"应用已经死了但查询还在跑"都能杀掉。

### 7.3 返回 `AccountBalance` 而不是裸 `int64`

> `[1:44:56]` Remember from last episode: **an amount without its currency is meaningless**, so the currency travels with the balance.

**译文**：记得上一集说的：**没有币种的金额毫无意义**，所以币种跟着余额一起走。

### 7.4 Store 从不打日志

> `[1:45:50]` **It never logs.** It returns errors with context, and leaves the decision to whoever handles them. If every layer logged the same failure on its way up, **one bad request would produce five log lines that all say the same thing**. Log once at the edge, where you know the request and the outcome.

**译文**：**它从不打日志。** 它返回带上下文的错误，把决定权留给处理错误的人。如果每一层都把同一个失败记一遍，**一个坏请求会产生五行说同一件事的日志**。在边缘（知道请求和结果的地方）记一次就好。

💡 "log once at the edge" 是个可以被检验的原则。判定方法：如果一条日志里缺 request ID 或结果状态，它就不该在那一层打。

---

## 8. 全集的中心：`inTx`

> `[1:46:18]` Remember, a ledger transaction is one journal row plus several entries, and they must be stored **together, or not at all**.
> **译文**：记住，一笔账本交易是一行 journal 加若干条分录，它们必须一起存进去，或者一条都不存。

```go
func (s *Store) inTx(ctx context.Context, fn func(q *walletdb.Queries) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	// defer 的 Rollback：提交之后它是空操作，所以这一行覆盖了
	// 提前 return、返回 error、甚至 panic 的所有退出路径。
	defer tx.Rollback(ctx)

	if err := fn(s.q.WithTx(tx)); err != nil {
		return err
	}
	// 注意：commit 的错误很重要 —— EP2 的延迟约束是在这一刻才检查的
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
```

> `[1:47:14]` And here's **the mistake to avoid**: inside that function, every query must go through the transaction. If you accidentally use the pool instead, that query runs on **a different connection outside the transaction**. It can't see the rows you've just inserted, and it won't be rolled back with them.

**译文**：这里有个**要避免的错误**：在那个函数内部，每个查询都必须走事务。如果你不小心用了池，那条查询会在**另一条连接上、事务之外**执行。它看不见你刚插入的行，也不会跟着回滚。

> `[1:47:31]` **Passing the function a `Queries` value that's already bound to the transaction makes that mistake much harder to make.**

**译文**：把**已经绑定到事务的 `Queries`** 传给那个函数，让这个错误几乎不可能犯。

### 8.1 最重要的一行是 `defer tx.Rollback(ctx)`

> `[1:48:36]` That one line covers **every way out** of this function: an early return, an error, even a panic. And once the transaction is committed, rollback does nothing at all, so it's **always safe to defer**.

### 8.2 `Commit` 的错误必须检查

> `[1:49:12]` And notice **the commit error matters**. For a ledger, this is where a deferred constraint fails, so it's often **the most important error in the whole function**. Ignoring the result of commit is a classic bug.

**译文**：注意 **commit 的错误很重要**。对账本来说，延迟约束正是在这一刻失败的，所以它往往是**整个函数里最重要的那个错误**。忽略 commit 的返回值是个经典 bug。

💡 这句话直接连着 EP2：我们花了一整集把检查推迟到 COMMIT，**所以 COMMIT 就是唯一会报"借贷不平"的地方**。把 `tx.Commit()` 写成 `_ = tx.Commit(ctx)`，EP2 的整集工作就白费了。

### 8.3 他不在这里做平衡检查

> `[1:50:38]` We **don't check that the postings balance.** That's the service layer's job in episode 5, so users get a friendly validation error. **Today we want to see the database's guarantee on its own.**

**译文**：我们**不检查分录是否平衡**。那是第 5 集 service 层的事，好让用户拿到友好的校验错误。**今天我们想看到数据库自己的保证。**

💡 分层意图很明确：store 层**故意不做**应用层校验，这样测试才能真正证明"数据库拦得住"。

---

## 9. 隔离级别的预告

> `[1:51:11]` `Begin` starts a transaction at the Postgres default, **read committed**… For inserting a brand new transaction and its entries, that's exactly right. But **reading a balance and then spending it is a different story**. Two transfers could both see the same $20.

**译文**：`Begin` 用 Postgres 默认的 **read committed** 开启事务……对于插入一笔全新的交易和它的分录，这完全正确。但**读出余额然后花掉它，是另一回事**。两笔转账可能都看到同一个 20 美元。

> `[1:51:36]` That's what episode 6 is about: row locks with `SELECT ... FOR UPDATE` and **a consistent lock order, so concurrent transfers can never deadlock**.
> **译文**：那就是第 6 集的内容：用 SELECT ... FOR UPDATE 做行锁，以及一致的加锁顺序，让并发转账永远不会死锁。

💡 注意他在这里就把 EP6 的答案说完了（行锁 + 一致顺序）。EP6 讲的是**为什么**需要这两样——正是我那份 EP6 讲义干的事。

---

## 10. `main.go`：三件容易被忽略的事

### 10.1 启动时崩溃，好过假装健康

> `[1:52:53]` If the database isn't reachable, we log the error and **exit with status 1**. Crashing at startup is the right call: an orchestrator like Kubernetes will restart us, and it's far better than **a service that looks healthy but fails every request**.

**译文**：数据库连不上就记日志并**以状态码 1 退出**。启动时崩溃是对的：Kubernetes 这类编排器会重启我们，这远比**一个看起来健康、但每个请求都失败的服务**要好。

### 10.2 `readyz` 和 `healthz` 是两个问题

> `[1:53:10]` `HealthZ` answers whether the **process is alive**. `ReadyZ` answers a different question: **can this instance serve traffic right now?**

> `[1:53:43]` When the database is briefly unreachable, a failing **readiness** check takes this instance **out of the load balancer, but leaves it running**. If we failed the **liveness** check instead, Kubernetes would **restart every replica at once**, which makes an outage worse, not better.

**译文**：数据库短暂不可达时，**就绪**检查失败会把这个实例**从负载均衡里摘掉，但让它继续运行**。如果错用了**存活**检查，Kubernetes 会**一次重启所有副本**，那会把故障放大，而不是缩小。

💡 这是 K8s 运维最经典的一个坑。判据：**依赖挂了我还能不能服务？** 不能 → readiness。**我自己卡死了吗？** 是 → liveness（而且 liveness 不该检查任何外部依赖）。

### 10.3 关闭顺序必须和启动相反

> `[1:54:00]` And at the very end, **after the HTTP server has stopped**, we close the pool. Order matters here: shutdown waits for in-flight requests to finish, and those requests **may still be using the database**. Close the pool first, and they'd fail right at the finish line.
> **译文**：而在最末尾，HTTP 服务器停下之后，我们关掉池。顺序在这里很重要：关闭会等待在途请求跑完，而那些请求可能还在用数据库。先关池，它们就会在终点线前失败。

> `[1:54:47]` **Starting up in one order and tearing down in the reverse is a pattern you'll see in every service we build.**
> **译文**：以一种顺序启动、以相反顺序拆除，是你会在我们建的每个服务里看到的模式。

💡 这就是 EP16 `draining` 的雏形。

---

## 11. 集成测试

> `[2:56:12]` **A unit test with a fake database would tell us very little here.** The interesting behavior — the balance check, the foreign keys, the view — all lives in Postgres, so we test against a real Postgres.

**译文**：**用假数据库写单元测试在这里几乎什么都证明不了。** 有意思的行为——余额检查、外键、视图——全都活在 Postgres 里，所以我们对着真的 Postgres 测试。

> `[2:56:39]` The first helper connects to the database in an environment variable. **If the variable isn't set, the test is skipped instead of failing**, so `go test ./...` still passes on a machine with no Docker at all.

**译文**：第一个 helper 连接环境变量里的数据库。**变量没设就跳过测试而不是失败**，于是 `go test ./...` 在一台完全没装 Docker 的机器上也能通过。

### 11.1 每个测试自己建账户

> `[1:57:06]` Every test creates **its own accounts, so tests never step on each other's data**, which means they can run **in parallel**.
> **译文**：每个测试建自己的账户，所以测试永不踩到彼此的数据，这意味着它们可以并行跑。

💡 这是并发测试的前提：**测试之间没有共享状态**，才敢 `t.Parallel()`。EP15 会把这个思想升级成"每个包一套容器"。

### 11.2 那个"他期待已久"的测试

> `[1:58:20]` Alice pays Bob $20 but **Bob only receives $15**, $5 would simply vanish. And yes, **Alice doesn't even have $20 in this test** — preventing overdrafts is episode 6's job. Today we're only testing that **the books must balance**.

> `[1:58:39]` We expect an error, and not just any error: **code 23514, check violation**, the error code our trigger raises.

> `[1:58:57]` And then we check **atomicity**: both balances must still be zero, because the entries inserted before the failed commit **were rolled back too**.

**译文**：我们期待一个错误，而且不是随便什么错误：**代码 23514，check violation**，我们触发器抛出的那个码。然后检查**原子性**：两个余额必须仍然为零，因为在失败的 commit 之前插入的分录**也被回滚了**。

💡 一个测试同时验证三件事：**约束存在**（23514）、**错误码正确**（可编程识别）、**原子性**（没有部分写入）。这是测试设计的范本。

### 11.3 `-count=1` 的坑

> `[2:00:20]` `go test -count=1` turns off Go's test cache. **The cache can't know that the database changed.**

**译文**：`-count=1` 关掉 Go 的测试缓存。**缓存无法知道数据库变了。**

### 11.4 他自己承认的债

> `[2:02:20]` A note on test data: **this test writes into our development database**, and because the ledger is append-only, those rows stay there. Since every run uses new UUIDs that's harmless, but **in episode 15 we'll switch to testcontainers**, which starts a throwaway Postgres for each test run, so tests and development data never mix.

**译文**：关于测试数据：**这个测试会写进我们的开发数据库**，而且因为账本是只追加的，那些行会留在那里。因为每次运行用的是新 UUID，所以无害，但**第 15 集我们会换成 testcontainers**，每次测试跑一个新的临时 Postgres，让测试数据和开发数据永不混在一起。

💡 他主动标出了这个债，并给了偿还时间。**这种"标注技术债 + 给偿还计划"的习惯，比代码本身更值得学。**

---

## 12. 他 recaps（2:02:39 – 2:04:49）

> `[2:03:18]` We set up sqlc, we write plain SQL, and it generates type-safe Go, **checked against the schema from our migrations**, so a broken query fails at generate time, not in production.
> **译文**：我们搭好 sqlc，写纯 SQL，它生成类型安全的 Go，并用 migrations 里的 schema 校验——所以一个坏查询在生成期就失败，而不是在生产环境。

> `[2:04:11]` Our `inTx` helper commits on success and rolls back on any error or panic, so **a transaction and its entries are posted atomically**.
> **译文**：我们的 inTx helper 成功时提交、任何错误或 panic 时回滚，所以一笔交易和它的分录是原子地被记下的。

> `[2:04:31]` And our first integration tests run against the real Postgres, **skip cleanly without one**, and prove the database rejects an unbalanced transaction.
> **译文**：而我们第一批集成测试跑在真的 Postgres 上，没有数据库时会干净地跳过，并证明数据库拒绝一笔不平衡的交易。

---

## 13. 我的补注：这条链上的四个薄弱点

### ① 集成测试写进开发库（他知道，EP15 才修）

在那之前，你可以自己先补一层：**每个测试在一个会回滚的事务里跑**。

```go
tx, _ := pool.Begin(ctx)
defer tx.Rollback(ctx)   // 永远不提交，测完什么也不留
q := walletdb.New(tx)
```

⚠️ 但 EP2 的延迟触发器**在 COMMIT 时**才检查——所以如果测试想验证"不平衡会报错"，**必须真的提交**。这是一个真实的张力：**回滚式测试测不到延迟约束**。他选择写进开发库不是偷懒，是延迟约束逼的。

### ② `MaxConns × 副本数` 他没算完

他说 5 副本 × 10 = 50，距离 100 还有余量。但他没提**另外 5 个服务也要连**。真实的解法通常是 **PgBouncer（事务级池化）**，或者按"总预算 ÷ 服务数"分配。EP23 上 K8s 时这个问题会放大。

### ③ `statement_timeout` 只提了，没落到 DSN

可以直接写进连接串：

```
postgres://...?sslmode=disable&statement_timeout=5000&lock_timeout=2000
```

`lock_timeout` 对 EP6 尤其有用——它把"无限等锁"变成"2 秒后报错"，让死锁从 1 秒的静默延迟变成明确的错误。

### ④ keyset pagination 的 `before=0 → MaxInt64`

> `[1:45:21]` 0 means start from the newest, so we swap it for the largest possible int64.
> **译文**：0 意味着从最新的开始，所以把它换成最大的 int64。

小技巧，好用，但要记住它的前提：**id 是递增的 `bigint identity`**。如果哪天换成 UUID 主键，这个技巧直接失效。

---

## 14. 自测题

1. ORM 在这个项目里失败的具体原因是什么？（不是"慢"）
2. `sqlc.yaml` 把 schema 指向 migrations 目录，不用单独维护 `schema.sql`，好处是什么？代价是什么？
3. 为什么 `ListAccountsByOwner` 的 `@owner_id::uuid` 这个 cast 是必要的？
4. `DBTX` 只有三个方法，为什么这个极小的接口就能让"事务"和"非事务"互换？
5. `defer tx.Rollback(ctx)` 在已经 Commit 之后调用，会发生什么？为什么它"永远安全"？
6. 为什么 `tx.Commit()` 的错误比 `tx.Begin()` 的错误更重要？
7. readiness 和 liveness 分别该不该检查数据库？答错的后果是什么？
8. 如果 `MaxConns` 设成 200，10 个副本，会发生什么？监控上最先看到什么？
