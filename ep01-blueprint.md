# EP01 讲义：The Blueprint（蓝图与骨架）

- **视频** `0:00:00 – 0:36:14`（36 分）｜分支 `ep01`（仓库初始化，只有 3 个文件）
- **转录** `media/ep01.txt`（171 句，5,466 词）
- 时间戳是视频绝对时间

一句话：**这一集没有业务代码，但定下了后面 23 集全部要遵守的东西。**

> 如果你只读一集，读这集。它决定了"什么叫做对"。

---

## 0. 先看终点

他不从代码开始，从**结果**开始：

> `[0:00:19]` Before we write a single line, let me show you where we're going to end up. This is **one payment**, Alice sends Bob $15, and this is the trace of that single request in Jaeger.

**译文**：在我们写第一行代码之前，让我先给你看我们最终会走到哪里。这是**一笔支付**——Alice 转给 Bob 15 美元——这是这一条请求在 Jaeger 里的调用链。

> `[0:00:44]` **66 spans**, across six services, **every database query included**, each one with its exact timing.

**译文**：**66 个 span**，横跨六个服务，**包括每一条数据库查询**，每一个都有精确耗时。

> `[0:01:03]` ...an event going out through an outbox, across NATS, into the notification service which sends an email. All of it connected into one story, **even the parts that happen after the HTTP response has already gone back to Alice**. And this diagram? **Nobody drew it. Jaeger built it from the traces alone.**

**译文**：……一个事件从 outbox 出来，穿过 NATS，进入通知服务发出邮件。全都被串成一个故事，**甚至是那些在 HTTP 响应已经返回给 Alice 之后才发生的事**。而这个拓扑图？**没人画它。Jaeger 只根据调用链就把它建出来了。**

> `[0:01:38]` **It's never out of date because it's made from what actually happened.**

💡 这句话值得单独摘出来。文档会过时，**痕迹不会**。整个可观测性章节（EP14/EP19）存在的理由就这一句。

然后他去找慢查询：

> `[0:02:56]` Now look at the p99 latency, top right — **something just got slow, so we go hunting.**

> `[0:03:13]` ...from a slow panel on a dashboard, **to the exact query in a couple of clicks**.

**译文**：……从仪表盘上一个变慢的图，**到那条确切的 SQL，只需要点几下。**

### 他对 "production grade" 的定义

> `[0:03:19]` That's what production grade means in this course: **not just code that works on a good day, but code you can operate and debug when something breaks at 3 in the morning.**

**译文**：这就是本课程里 production grade 的意思：**不只是天气好的时候能跑的代码，而是凌晨三点出事时你能运维、能调试的代码。**

他接着把三个最难的问题**当场录像证明**：

| 集 | 演示 | 原话 |
|---|---|---|
| EP6 | 200 笔并发转账，第一版**死锁**，Postgres 杀掉，用锁排序修好，race detector 跑绿 | `[0:03:34]` |
| EP7 | 同一笔支付同时重试 20 次，**只有 1 次执行**，其余拒绝或返回存好的答案 | `[0:03:51]` |
| EP12 | 故意在"钱包已冻结资金、transfer 还没记账"之间**杀掉服务**，重启后 saga 续上，只扣一次 | `[0:04:08]` |
| EP13 | 邮件服务器宕机 → 退避重试 → 死信队列 → 恢复后重放 | `[0:04:25]` |

---

## 1. 五条规则：全课程的宪法

这一段（`0:06:30 – 0:07:53`）是整门课**最重要的一分钟**。后面每一集都会回到其中至少一条。

> `[0:06:30]` Payment code lives by a few rules that most code can get away with ignoring, and **this whole course is built around them**.

### 规则一：钱是整数

> `[0:06:32]` **Money is an integer.** We store cents as a 64-bit integer, plus our currency code, **never a float**, because in floating point, 10 cents plus 20 cents isn't exactly 30 cents.

**译文**：**钱是整数。** 我们把"分"存成 64 位整数，加上币种代码，**绝不用浮点**，因为在浮点里，10 分加 20 分并不精确等于 30 分。

💡 EP5 会把这条规则展开成完整的 `Money{Amount int64, Currency string}`，并解释 ISO 4217 的 exponent（日元是 0，第纳尔是 3）。

### 规则二：钱不创造也不消失，只是移动

> `[0:06:58]` **Money is never created or destroyed, it only moves**, so we record every movement twice — once where it lives, and once where it arrives — and **balances are derived from those records, never overwritten**.

**译文**：**钱从不被创造或销毁，它只移动**，所以我们把每次移动记两遍——一次记在它离开的地方，一次记在它到达的地方——而且**余额是从这些记录推导出来的，从不被覆盖**。

💡 这一条 = EP2 的全部。注意最后半句"从未被覆盖"：它不是风格偏好，它是**让 EP6 变难的直接原因**（没有可锁的余额列）。

### 规则三：每个请求都可能来两次

> `[0:07:11]` **Every request can arrive twice** — networks retry, and users double-click — so every request that moves money carries an **idempotency key**.

**译文**：**每个请求都可能到达两次**——网络会重试，用户会双击——所以每个移动钱的请求都带一个**幂等键**。

⚠️ 注意这句话否定了"客户端不会重试"这个假设。EP5 里他的 `Deposit` **故意**不实现幂等（`[3:19:34]` 明说"如果网络丢了响应、客户端重试，Alice 会被付两次"），留到 EP7。

### 规则四：并发请求不能超支

> `[0:07:11]` **Concurrent requests can't overspend.** Two withdrawals at the same instant must never both see the same balance, so we **lock the rows, always in the same order**.

**译文**：**并发请求不能超支。** 同一瞬间的两笔取款绝不能都看到同一个余额，所以我们**锁住行，而且总是按同样的顺序**。

💡 "always in the same order" 这五个字，就是 EP6 那一整集。

### 规则五：任何两行代码之间都可能崩溃

> `[0:07:25]` **A crash can happen between any two lines of code**, so multi-step work is a **saga that can resume**, events go out through an **outbox**, and consumers are **idempotent**.

### 他给这五条配了后果的一句话

> `[0:07:39]` **Break the first rule, and cents go missing to rounding. Break the second, and you can't prove where money went. Break the others, and someone gets charged twice, overdraws an account, or loses money in a crash.**

**译文**：**破了第一条，分会在四舍五入里消失。破了第二条，你无法证明钱去了哪里。破了其余几条，就会有人被扣两次、账户透支、或者在崩溃中丢钱。**

> `[0:07:53]` Keep these five in mind, **every single episode comes back to at least one of them.**

### 我的补充：把五条规则变成一张可检验的表

| # | 规则 | 谁在保证 | 在哪一集 |
|---|---|---|---|
| 1 | 钱是整数 | `Money{int64, currency}` + `MaxAmount` | EP5 |
| 2 | 钱只移动、余额推导 | 复式记账 + 延迟触发器 + 视图 | **EP2** |
| 3 | 请求可能来两次 | 幂等键 + Redis/存储的应答回放 | EP7 |
| 4 | 并发不能超支 | `FOR UPDATE` + 锁排序 + 重试 | **EP6** |
| 5 | 任何两行之间可能崩 | saga + outbox + 幂等消费者 | EP12 / EP13 |

**前三条在数据库里可以被强制，后两条只能在系统层面被设计出来。** 这就是为什么这门课后半段越来越难。

---

## 2. 为什么是 Go（四个理由 + 一个诚实的代价）

> `[0:11:09]` Before we set anything up, **two questions you should always ask: why this language, and why this architecture?**

💡 这个提问方式本身就值得学：**先问"为什么不用默认选项"，再动手。**

> `[0:11:15]` **First**, it compiles to a single static binary. No runtime to install, no virtual machine — copy one file into a tiny container, and it runs.
>
> `[0:11:28]` **Second**, concurrency is built into the language. Goroutines are cheap, and context gives every request a deadline and a way to cancel it.
>
> `[0:11:43]` **Third**, the standard library is made for servers: HTTP, JSON, crypto, and structured logging, all built-in and stable.
>
> `[0:11:54]` **Fourth**, it's boring on purpose. A small language, one formatting style, fast builds, and **code that whoever is on call can read at 3 in the morning**. And code written for Go 1 back in 2012 **still compiles today**.

💡 第四条里两次出现同一个词：**boring**。你昨天说 "这个 boring 可能就是我想要的"——**他自己把 boring 列成了一个正式的技术理由**，而且给出的读者不是"写代码的人"，是"凌晨三点被叫起来的人"。

> `[0:12:17]` The honest trade-off: **Go is verbose about errors**. There are no exceptions, so you'll write `if err != nil` a lot. **For code that moves money, I'd call that a feature.** Every failure path is right there in the code, where a reviewer can see it, instead of an exception **flying past three layers nobody looked at**.

**译文**：诚实的代价：**Go 在错误处理上很啰嗦**。没有异常，所以你会写很多 `if err != nil`。**对于处理钱的代码，我说这是特性。** 每条失败路径都明明白白写在代码里，reviewer 能看见，而不是一个异常**从三层没人看的代码里飞过去**。

### 他也解释了为什么不选别的

> `[0:12:41]` Java, Kotlin, and C# are excellent, **mature** choices for payments, with heavier runtimes and more framework. Node gets you started fast, but you'll **fight harder for type safety** and CPU-heavy work. Rust gives you more control and more guarantees **for a much steeper learning curve**. For network services that a team has to run and maintain for years, **Go sits in a very comfortable middle**.

💡 注意他的诚实结构：每个替代方案都是"**优点 + 代价**"，没有一个是被贬低的。

---

## 3. 微服务：他不推销，他算计

> `[0:13:03]` Now, microservices — **let's be honest about them, because they're oversold.**

然后他用了四组"收益 / 代价"：

| 收益 | 代价（原话） |
|---|---|
| 服务可以独立部署和扩容 | `[0:13:15]` far more moving parts to run and to watch |
| 每个服务拥有自己的数据，一个团队改不坏另一个团队的 schema | `[0:13:38]` **no database transaction can span two services**, so moving money across them needs an **outbox and sagas** |
| 通知服务崩溃不会带着支付一起挂 | 网络开始以新的、有创意的方式失败：超时、重试、重复消息 |
| 边界清晰 | 一个请求现在在五个地方留日志，**所以 tracing 不是可选项** |

> `[0:13:52]` So, my honest advice: **if you're a small team starting a product, start with a well-structured monolith and split it when you actually need to.**

**译文**：所以，我的诚实建议：**如果你是小团队做产品，从结构良好的单体开始，等你真的需要时再拆。**

> `[0:14:03]` We're building microservices here **because that's where the hard, interesting patterns live** — sagas, outboxes, idempotent consumers, distributed tracing.

💡 这是全片最诚实的一句：**他选微服务是为了教那些模式，不是因为微服务总是更好。** 而且他立刻补上了边界怎么划：

> `[0:14:18]` When we split, **we split by business capability, not by a technical layer** — not a database service and a validation service, but auth, wallet, transfers, notifications. **Each one owns three things: its API, its data, and the events it publishes.**

**译文**：拆分时**按业务能力拆，不按技术层拆**——不是"数据库服务 + 校验服务"，而是 auth、wallet、transfers、notifications。**每个服务拥有三样东西：它的 API、它的数据、它发布的事件。**

---

## 4. Monorepo：为什么一个仓库、一个 Go module

> `[0:17:04]` a monorepo, **one repository, and one Go module** for all of them.

> `[0:17:47]` **One Go module, one `go.mod`, so one version of every dependency.** And when a gRPC contract changes, **the contract, the server, and the client change in a single commit** and get tested together.

**译文**：一个 module、一个 `go.mod`，所以每个依赖只有一个版本。而当 gRPC 契约变化时，**契约、服务端、客户端在同一个 commit 里一起改**，一起被测试。

> `[0:18:02]` And `internal` isn't just a folder name — **the Go compiler enforces it.** Code outside our module can't import those packages.

💡 Go 的 `internal/` 是**语言级**的封装。这解释了 EP6 里那个"分层靠约定"的观察为什么只到**文件级**为止——**包级**的边界是编译器管的。

> `[0:18:16]` So one rule: **services never import each other's internals** — the wallet's code never imports the transfer service's code. They only talk over the network, through contracts, **exactly as if they lived in separate repositories**. That way, splitting the repo later would be **a boring afternoon, not a rewrite**.

**译文**：所以有一条规矩：**服务之间绝不 import 对方的内部**……它们只通过网络、通过契约通信，**就好像它们住在不同仓库里一样**。这样以后拆仓库只是**一个无聊的下午，不是一次重写**。

> `[0:18:34]` The alternative is a repository per service... but every shared change turns into a release of a shared library, version bumps across five repos, and a few weeks where services disagree about what a contract looks like. For one team and five services, **one repo is simply less work.**

💡 **注意这条规矩没有任何工具强制。** 它和 EP6 的锁顺序一样，是**约定**。而它一旦被破坏（wallet import transfer），`boring afternoon` 就变成了 `rewrite`。

---

## 5. Docker Compose：三个决定

> `[0:19:51]` Instead of installing all of that on your machine, we describe it in one docker compose file. Anyone who clones the repo gets **the exact same versions with one command**, and can throw it all away just as easily.

> `[0:20:12]` Our compose file is also **documentation** — a new teammate reads this one file and knows exactly what the system depends on.

### 5.1 为什么 `postgres:17-alpine`

> `[0:20:20]` ...pinned to the major version means **we get bug fixes but never a surprise upgrade**.

💡 钉 major 而不是钉死补丁版本：拿得到安全修复，拿不到破坏性变更。

### 5.2 healthcheck 的那句金句

> `[0:20:56]` The health check is important. It runs `pg_isready` every 5 seconds so Docker knows when Postgres is **actually ready to accept connections**, not just when the container has started. **Those are two very different moments.**

**译文**：健康检查很重要。它每 5 秒跑一次 `pg_isready`，这样 Docker 知道 Postgres **真的准备好接受连接**了，而不只是容器启动了。**这是两个完全不同的时刻。**

💡 这个区分会在 EP4 以另一个名字回来：**liveness vs readiness**。同一个洞察，两个层次。

### 5.3 为什么 Redis 不要 volume

> `[0:21:26]` No volume this time — **everything we put in Redis is either a cache or short-lived, so losing it on a restart is fine. The source of truth is always Postgres.**

**译文**：这次不要 volume——我们放进 Redis 的东西要么是缓存，要么是短命的，重启丢掉没关系。**真相来源永远是 Postgres。**

### 提示：那条会让你丢数据的命令

> `[0:23:24]` `docker compose down` stops and removes the containers but **keeps the volume**, so your data survives. `docker compose down -v` **removes the volumes too**, which gives you a completely fresh database. That's handy — and also **exactly how you lose your local data by accident**, so use it on purpose.

💡 记住这条。EP5 的迁移**会要求你**跑一次 `down -v`，因为旧的测试数据会被迁移判定成 system account 然后撞上唯一索引。

---

## 6. 服务骨架：五个决定

> `[0:23:44]` Today it's just a skeleton: a server that starts, answers a health check, and stops cleanly. But **every service in this course has this same skeleton**, so let's get it right.

### ① slog：结构化日志

> `[0:24:08]` `slog` is Go's structured logger, in the standard library since 1.21. Structured means every line is **a message plus key-value pairs**, instead of a sentence with values glued into it — so later **a machine can filter on them**: show me every line for this wallet ID.

> `[0:24:37]` The text handler prints them in a readable `key=value` format... **in production you'd want JSON, and in episode 4 that becomes a config option.** And it writes to **standard output, not to a file** — collecting logs is the platform's job. Docker, Kubernetes, or a log shipper reads standard output, so **the service never has to manage, rotate, or clean up log files.**

💡 最后半句是 12-factor 的一条硬规矩：**应用不应该知道日志去哪了。** 它只负责写到 stdout。

### ② 用标准库的路由（Go 1.22+）

> `[0:25:00]` Since Go 1.22, the standard library's `ServeMux` understands **methods and wildcards** in its patterns. `GET /healthz` only matches GET requests. Before that you'd reach for a third-party router just for this.

### ③ 为什么不注册健康检查的日志在别处 / 为什么叫 `healthz`

> `[0:25:25]` A health endpoint is how a load balancer or Kubernetes knows this instance is alive, **so keep it cheap**. And the **z** at the end of `healthz` — it's an old convention, **so the path never clashes with a real route**.

### ④ `ReadHeaderTimeout`：防 Slowloris

> `[0:26:12]` ...our router, and a `ReadHeaderTimeout`. **A client that opens a connection and then sends its headers one byte at a time** — an attack called **slowloris** — gets cut off after 5 seconds, instead of holding a connection open forever.

💡 这个攻击为什么有效：每个连接占一个 goroutine + 一个文件描述符。慢到极限的连接能让服务器耗尽资源而不触发任何"正常"的限流。

### ⑤ 绝不用 `http.DefaultServeMux`

> `[0:26:40]` Notice we pass **our own mux**, instead of using the package-level default one. The default `ServeMux` is **global** — any package you import can register handlers on it. **The classic example is the `pprof` package, which when imported quietly adds debug endpoints to the default mux.** With our own mux, the only routes this server has are the ones you can read right here.

**译文**：注意我们传的是**自己的 mux**，不是包级的默认那个。默认 `ServeMux` 是**全局的**——你 import 的任何包都能往上注册 handler。**经典例子是 `pprof` 包：一 import，它就悄悄往默认 mux 上加了调试端点。**

💡 这是一个**真实的、上过新闻的**事故类型：一个 `import _ "net/http/pprof"` 加上默认 mux，就把 `/debug/pprof/` 暴露到公网了。他的修法是最简单的那种：**不用全局变量。**

---

## 7. Graceful shutdown：本集最有工程含量的一段

> `[0:27:21]` This next part is what separates a toy server from a production one.

> `[0:27:33]` In production your service gets stopped all the time — every deploy, every scale-down, every machine drained for maintenance. And **the platform asks politely first, with a signal called SIGTERM. If we ignore it, we die mid-request.** Somewhere a transfer was halfway through, the client gets a broken connection, and **has no idea whether the money moved**.

**译文**：生产环境里你的服务一直在被停——每次部署、每次缩容、每台机器做维护。而**平台会先用一个叫 SIGTERM 的信号礼貌地问一下。如果我们不理它，我们就会死在请求中间。** 某个地方有一笔转账进行到一半，客户端拿到一个断掉的连接，而且**完全不知道钱到底动没动**。

💡 **"has no idea whether the money moved"** —— 这句话就是 EP7 幂等键存在的全部理由。**不确定**才是灾难，失败本身不是。

> `[0:27:57]` **"In flight"** is the key phrase for us: a request that has already started **should finish**, so the client gets a real answer. A graceful shutdown happens in order: **first stop accepting new connections, then let the requests already in flight finish, then close everything else and exit.**

> `[0:28:20]` But not forever: **we give it 10 seconds. Kubernetes by default waits 30 seconds after SIGTERM, and then sends SIGKILL, which can't be caught or ignored.** So we finish well inside that window, on our own terms.

**译文**：但不能无限等：**我们给它 10 秒。Kubernetes 默认在 SIGTERM 之后等 30 秒，然后发 SIGKILL——那个信号捕不到也忽略不了。** 所以我们在那个窗口里、按自己的方式结束。

### 7.1 `signal.NotifyContext`

> `[0:28:56]` `signal.NotifyContext` gives us a context that's **cancelled when the process receives an interrupt** — which is Ctrl-C in a terminal, or SIGTERM, which is what Docker and Kubernetes send.

### 7.2 一个必须知道的细节：`os.Exit` 不跑 defer

> `[0:29:34]` One subtlety: **`os.Exit` ends the program immediately without running deferred functions.** That's fine today because nothing's open yet — **it's a trade-off we'll keep in mind as the service grows.**

**译文**：一个微妙之处：**`os.Exit` 会立刻结束程序，不执行 deferred 函数。** 今天没问题，因为还没有任何东西被打开——**但随着服务长大，这是一个要记住的取舍。**

💡 到 EP3/EP4，`main` 里就有连接池了。这时候如果还在错误路径上 `os.Exit`，就会**泄漏连接**。所以后面的解法是：**`main` 只 `return error` 的最外层做一次 `os.Exit`。**

### 7.3 为什么 shutdown 要用一个**新的** context

> `[0:30:09]` ...then `Shutdown` with **a fresh context that times out after 10 seconds — a fresh one, because the signal context is already cancelled.**

**译文**：……然后用**一个 10 秒超时的新 context** 调 `Shutdown`——**必须新的，因为信号那个 context 已经取消了。**

💡 这个 bug 极其常见：拿已经 cancel 的 ctx 去 shutdown，`Shutdown` 立刻返回，正在执行的请求**全部被杀**，而你还在日志里写着 "gracefully"。

### 7.4 退出顺序

> `[0:30:21]` ...and then "server stopped". On the way out, **the deferred calls run in reverse order** — `cancel` then `stop`.

> `[0:30:47]` Read top to bottom, that's the shape of every service in this course: **build the dependencies, start serving in the background, wait for a signal, shut down in order.** The dependencies will grow — a database pool, NATS, a gRPC server — and **each one gets closed in that last section**.

💡 EP3 会把这条规矩推进一格：**关闭顺序必须和启动顺序相反**，而且**连接池必须最后关**（因为还在跑的请求要用它）。

---

## 8. 实测：405 是白送的

> `[0:32:00]` Now the same path but with POST: **405 Method Not Allowed, and an `Allow` header listing GET and HEAD.** We didn't write any of that — **the method in our route pattern did**, and the `GET` route answers `HEAD` requests too, for free.

💡 这就是 1.22 之后标准库路由的价值：**它把 HTTP 语义都实现了**，你只声明"这个方法 + 这个路径"。

---

## 9. 静态二进制

> `[0:32:49]` ...the single static binary: `go build -o` to put it in a file outside the project, and let's check its size: **under 10 megabytes, with the Go runtime and everything it needs inside.** And for Linux from this Mac, just set `GOOS` and `GOARCH`: a **statically linked Linux executable, no runtime, no shared libraries to install**. That's what goes into a tiny container image later in the course.

---

## 10. 最后那个"诚实的细节"

> `[0:33:35]` One honest detail: **`docker stop` also sends SIGTERM, but by default it waits only 10 seconds before SIGKILL — the same as our budget.** So in Docker you'd either give the container a longer stop grace period, or **keep the shutdown budget comfortably below the platform's**. The rule is always the same: **know your platform's grace period and finish inside it.**

**译文**：一个诚实的细节：**`docker stop` 也发 SIGTERM，但默认只等 10 秒就 SIGKILL——和我们的预算一样。** 所以在 Docker 里，你要么给容器更长的 stop grace period，要么**把关闭预算压在平台期限之下并且留出余量**。规则永远一样：**知道你的平台期限，在它之内结束。**

💡 这是一条**可检验**的工程规则：`shutdown_timeout < platform_grace_period - safety_margin`。他的 10 秒对上 K8s 的 30 秒是安全的，对上 Docker 的 10 秒是**贴边的**——他自己指出了这个边界。

---

## 11. 他给观众的一条学习建议

> `[0:10:21]` **Type along rather than copy and paste.** Pause whenever you need to, and use the chapters to jump around. Typing it yourself is slower, but **it's how the patterns actually stick**. And when your version breaks and mine doesn't, `git diff` against my branch.

**译文**：**跟着敲，不要复制粘贴。** 需要时暂停，用章节跳转。自己敲会慢，但**这是模式真正长在身上的方式**。当你的版本挂了、我的没挂，就跟我的分支 `git diff`。

💡 对你来说这条要**反着改**：你不打算手打全部代码，那就换成——**每个实验阶段手打那 20 行关键 SQL/命令**（比如 EP6 的双会话死锁复现）。**手打的价值在"建立肌肉记忆的那一小块"，不在总量。**

---

## 12. 收尾金句

> `[0:35:29]` If you remember one thing from today, make it this: **production grade isn't a feature you add at the end.** It's the timeout on the server, the 10-second deadline, the health check, the honest trade-off — **decided on day one, while it's still cheap.**

**译文**：如果今天只记住一件事，记这个：**production grade 不是一个你最后才加上去的功能。** 它是服务器上的超时、那个 10 秒的期限、那个健康检查、那个诚实的取舍——**在第一天、在它还便宜的时候就定下来。**

---

## 13. 我的补注：这集埋下的三个坑

### ① `ReadHeaderTimeout` 只是一个超时，不是全部

真实服务还需要：

```go
srv := &http.Server{
	ReadHeaderTimeout: 5 * time.Second,   // 他设了
	ReadTimeout:       15 * time.Second,  // 他没用：整个请求体读多久
	WriteTimeout:      15 * time.Second,  // 他没用：响应写多久
	IdleTimeout:       60 * time.Second,  // 他没用：keep-alive 空闲多久
}
```

`ReadHeaderTimeout` 只防 slowloris 的 header 慢速攻击；**body 慢速**（slow body）要靠 `ReadTimeout`。他后面用 `MaxBytesReader`（EP4）补了尺寸，但没补时间。

### ② 10 秒 vs Docker 的 10 秒

他自己指出了这个冲突，但没给数字。安全的配法是：

| 层 | 值 |
|---|---|
| 应用 shutdown 预算 | 8s |
| Docker `stop_grace_period` | 12s |
| K8s `terminationGracePeriodSeconds` | 30s |

**永远留 2 秒以上余量**，因为你测不准排队的请求还剩几个。

### ③ `signal.NotifyContext` 之后必须 `stop()`

> `[0:29:08]` `stop` releases the signal handling when `main` returns.

如果不 `stop()`，这个进程会**永久接管 SIGTERM**——在测试里这会导致后续测试收不到信号。这是 `defer stop()` 的意义，不是形式主义。

---

## 14. 自测题

1. 五条规则里，哪一条**只能**在数据库层面强制？哪一条**只能**在系统层面设计？
2. 为什么"余额不被覆盖"这条规则会直接导致 EP6 变难？
3. healthcheck 的"容器启动了"和"能接受连接"为什么是两个不同时刻？举个会出事的场景。
4. 为什么 `shutdown` 必须用一个**新的** context？
5. `os.Exit` 在 EP3 之后为什么会变成一个 bug 来源？
6. 为什么用 `pprof` 做例子说明"不要用 `DefaultServeMux`"？
7. 他的 shutdown 预算 10 秒和 `docker stop` 的 10 秒，问题在哪？
