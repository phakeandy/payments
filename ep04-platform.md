# EP04 讲义：Config, Logging, Request IDs, Errors, Middleware

- **视频** `2:05:17 – 2:54:53`（50 分）｜分支 `ep04` ｜ diff：`+922 / -26`（19 个文件）
- **转录** `media/ep04.txt`（158 句，6,403 词）
- 时间戳是视频绝对时间

一句话：**这一集建立 `internal/platform`——后面 20 集每个服务都踩在上面的那层地板。**

> 这一集的代码"看起来"都是样板：读配置、打日志、包错误。但**每一处都有一个人踩过坑之后才写得出来的细节**。这一份讲义专挑那些细节。

---

## 0. 起点：上一集留下了什么

> `[2:05:24]` Our wallet service can now talk to its ledger, but on the inside **it's still a prototype**. Its settings are hard-coded, its logs are plain text with no context, and **an error or a panic would surface as whatever `net/http` felt like sending**.

**译文**：我们的 wallet 服务现在能和账本说话了，但里面**仍然是原型**。设置是写死的，日志是没有上下文的纯文本，而且**一个错误或 panic 会变成 `net/http` 想发什么就发什么**。

> `[2:07:27]` ...0.42 endpoints. But more endpoints, and for more services, are coming. **If each one invents its own error format, every client has to handle every format.**

**译文**：……0.42 个端点。但会有更多端点、更多服务。**如果每个都发明自己的错误格式，每个客户端都得处理每一种格式。**

💡 "0.42 endpoints" —— 他连"现在只有一个健康检查"都用这种方式自嘲，然后给出真正的理由：**共享件现在写一次，比以后统一 N 次便宜。**

---

## 1. 中间件链：顺序不是风格，是因果

> `[2:08:13]` A middleware in Go is nothing magic. It's **a function that takes an HTTP handler and returns another handler** which wraps it. It can run code **before** calling the next handler, **after** it, or **decide not to call it at all**.
> **译文**：Go 里的中间件一点也不神秘。它是一个「接收 HTTP handler、返回另一个包住它的 handler」的函数。它可以在调用下一个 handler 之前跑代码、之后跑，或者干脆决定不调用它。

> `[2:08:37]` And **the order matters**. The outermost layer sees the request first and the response last.

**然后是这一集最关键的一段**：

> `[2:08:47]` **Recover must sit inside the access log**, so that when it writes a 500, the access log **sees** that 500. And **the request ID must be outermost**, so even the access log line **carries** it.

**译文**：**Recover 必须在 access log 的内侧**，这样当它写出 500 时，access log **看得见**那个 500。而 **request ID 必须在最外层**，这样连 access log 那一行都**带着**它。

```
RequestID  ← 必须在最外：否则 access log 那行没有 id
  └─ AccessLog  ← 必须在 Recover 外：否则看不到 500
       └─ Recover  ← 必须在 handler 外：否则抓不到 panic
            └─ ServeMux → handlers
```

### 为什么顺序反过来会坏（三个具体故障）

| 换序 | 故障 |
|---|---|
| `Recover` 在 `AccessLog` **外面** | panic 被 recover 就地写成 500，但 access log 在**内层**，它根本没被执行完 → **这次请求没有访问日志**。你失去了唯一能证明"这个请求发生过"的记录。 |
| `RequestID` 在 `AccessLog` **里面** | access log 执行时 ctx 里还没有 id → **所有访问日志都没有 request id**，你没法把一行日志和一次请求对上 |
| `AccessLog` 在 `Recover` **里面** 且 `Recover` 最外 | 同上第一条 |

**注意：这三种错误在功能测试里全都会通过。** 只有你在日志里找东西的时候才会发现。

> `[2:42:19]` ...last, the **order of chain**, because **getting it backwards is an easy mistake to make and a hard one to spot**. `mark` returns a middleware that appends its name to a slice... We chain three of them and serve one request — they must run `first second third` in the order we listed them, which proves the loop over `slices.Backward` is right.

**译文**：最后是链条的顺序测试，因为**搞反了很容易，而且很难发现**。`mark` 返回一个把自己名字追加到切片里的中间件……我们把三个串起来发一个请求——它们必须以 `first second third` 的顺序执行，这就证明了 `slices.Backward` 那个循环是对的。

💡 这个测试**只测顺序，不测功能**。它是一个纯粹的"我信不过我的循环方向"测试。**这类测试的价值被严重低估。**

代码（`middleware.go`）：

```go
func Chain(h http.Handler, mw ...Middleware) http.Handler {
	for _, m := range slices.Backward(mw) {   // 反向遍历
		h = m(h)
	}
	return h
}
```

反向遍历 → 列表里的**第一个**包在最外层 → **链的书写顺序 == 请求经过的顺序**。

---

## 2. 配置：两条规则 + 一个反常识的做法

> `[2:09:00]` The idea comes from the **12-factor app**: the same build runs in every environment, and **only the environment changes**, so settings come from environment variables. But environment variables are just strings. We want them **parsed once, at startup, into a typed config struct**, so the rest of the code works with an `int` or a `time.Duration` and **never touches `os.Getenv` again**.
> **译文**：这个想法来自 12-factor app：同一个构建在每个环境里跑，只有环境变化，所以设置来自环境变量。但环境变量只是字符串。我们要它们在启动时被解析一次，装进一个有类型的配置结构体，这样其余代码处理的是 int 或 time.Duration，并且再也不碰 os.Getenv。

### 2.1 两条规则

> `[2:09:18]` **Two rules.** Everything gets a sensible default **except secrets, like the database URL. Those are required**, because **the default password in code is how secrets end up in git**.
>
> `[2:09:44]` And **all parsing and validation happens at startup, never lazily halfway through a request.**

**译文**：**两条规则。** 一切都有合理默认值，**除了密钥，比如数据库 URL。那些是必填的**，因为**写在代码里的默认密码，就是密钥进 git 的方式**。而且**所有解析和校验都在启动时完成，绝不懒加载到请求中途。**

### 2.2 反常识：一次报出所有问题

> `[2:10:06]` And here's **the part most config code gets wrong**: when something's missing or invalid, **we don't stop at the first problem. We collect every problem, print them all, and exit before serving any traffic. Nobody enjoys fixing one variable, redeploying, and discovering the next one.**

**译文**：这里是**大多数配置代码搞错的地方**：当某个东西缺失或非法时，**我们不停在第一个问题上。我们收集所有问题，全部打印出来，然后在开始服务任何流量之前退出。没人喜欢修一个变量、重新部署、然后发现下一个。**

### 2.3 为什么不用 viper / envconfig

> `[2:10:06]` Why not a library like `envconfig` or `viper`? **What we need is about 70 lines, with no reflection and no dependency — and reading it once tells you exactly how it behaves.**

**译文**：为什么不用 `envconfig` 或 `viper`？**我们需要的就是大约 70 行，没有反射、没有依赖——读一遍就知道它到底怎么行为。**

💡 注意这不是"不要用库"的教条。他的判据是**可解释性**：一个 70 行的文件，你能读完；viper 你不能。**运维事故里，"我不知道这条配置为什么没生效"是常见死因。**

### 2.4 设计：把"环境"注入进来

```go
type env struct {
	lookup   func(string) (string, bool)
	problems []string
}
```

> `[2:10:47]` `New` takes the lookup function. In the service, that's `os.LookupEnv`. **In tests, it's a little function over a map, so tests never touch the real environment and can run in parallel.**

**译文**：`New` 接收一个 lookup 函数。在服务里是 `os.LookupEnv`。**在测试里是一个遍历 map 的小函数，所以测试从不碰真实环境，还可以并行跑。**

💡 这是**函数注入**代替**接口注入**的范例：一个函数签名就够，不需要为它定义一个 interface。和 EP3 `DBTX` 只有三个方法是一脉相承的——**用最小的抽象**。

### 2.5 两个细节

> `[2:11:06]` A private helper `get` looks a variable up and **trims surrounding spaces**, which sneak in more often than you'd think, **especially from copy-paste**. And **a variable that's set but empty counts as unset**.

> `[2:11:20]` In a compose file or a Kubernetes manifest, **an empty value almost always means someone forgot to fill it in**.

**译文**：私有 helper `get` 查一个变量并**去掉首尾空白**，这些空白比你想象的更容易混进来，**尤其是复制粘贴**。而且**设置了但为空，等于没设置**。

💡 这两条都是"被事故教育过"的痕迹：`PORT=` 和 `PORT` 缺失在 K8s 里是同一个问题，但你如果把它们区别对待，就会得到一个**在 0 号端口监听**的服务。

### 2.6 `parse` 为什么是函数而不是方法

```go
func parse[T any](e *env, key string, def T, parse func(string) (T, error)) T
```

> `[2:13:07]` Notice it's a **function, not a method**. **Go methods can't have their own type parameters**, so this is the idiomatic workaround.

**译文**：注意它是**函数，不是方法**。**Go 的方法不能有自己的类型参数**，所以这是惯用的绕法。

> `[2:13:23]` ...so a timeout can be written as `5s`, or `1m30s`. **Any parse function from the standard library, or our own, plugs straight in.**
> **译文**：……所以一个超时可以写成 5s 或者 1m30s。任何标准库的（或我们自己的）解析函数都能直接插进来。

### 2.7 测试怎么写

> `[2:13:39]` ...in package `config_test`, **so we only use the exported API**. We build an `env` from a map with **three bad values**... Both typed values should fall back to their defaults, and **the error must mention all three bad variables, not just the first one — which is the whole point of collecting problems.**
> **译文**：……放在 config_test 包里，所以我们只用导出的 API。我们用一个 map 建 env，里面有三个坏值……两个有类型的值都该回退到默认值，而错误必须提到全部三个坏变量，而不是只有第一个——这正是收集问题的意义。

---

## 3. 日志：slog 的四个决定

> `[2:14:53]` Instead of formatting a sentence, you log **a message plus key-value pairs**. In development, the **text** handler prints them as `key=value`, easy to read in a terminal. In production, the **JSON** handler prints one JSON object per line — log collectors like Loki, Datadog, or CloudWatch **parse that without any regular expressions**, so you can filter on `status=500`, or on one request ID.
> **译文**：不是去格式化一句话，你记录的是「一条消息加若干键值对」。开发环境里文本 handler 打印成 key=value，在终端里好读。生产环境里 JSON handler 每行打印一个 JSON 对象——Loki、Datadog、CloudWatch 这类日志收集器不用任何正则就能解析它，于是你可以按 status=500 或者某个 request id 过滤。

> `[2:15:34]` **Every line should also say which service wrote it, and which version.** When five services ship logs to one place, and a bug appears right after a deploy, those are the first things you'll filter on.

### 3.1 用类型化的 attr，不用交替的 key/value

> `[2:16:39]` ...and call `With`, which returns a logger that adds these attributes to every line: `service` and `version`. Notice I'm using `slog.String`, **instead of alternating keys and values**. These **typed attributes are a little faster, and they can't get out of step** like a key with no value.

**译文**：……调用 `With`，返回一个在每一行都加上这些属性的 logger：`service` 和 `version`。注意我用的是 `slog.String`，**而不是交替的 key/value**。这些**类型化的属性快一点，而且不会像"有 key 没 value"那样错位。**

💡 `slog.Info("msg", "k1", "v1", "k2")` 是合法的、能编译的、运行时不报错的、**在日志里产生一个 `!BADKEY` 的**。类型化 attr 让这种错误无法表达。

### 3.2 `ReplaceAttr`：给人看短时间戳，给机器看完整时间

> `[2:17:08]` `ReplaceAttr` is a hook that lets you **rewrite every attribute before it's written**. In text mode, we print **just the time of day with milliseconds**. Someone reading a terminal doesn't need the date and the time zone on every line. **A log collector does, so JSON keeps the full timestamp.**

**译文**：`ReplaceAttr` 是个钩子，让你在属性写出之前**重写每个属性**。文本模式下我们只打印**带毫秒的时刻**。在终端里看日志的人不需要每行都有日期和时区。**日志收集器需要，所以 JSON 保留完整时间戳。**

💡 这是"**同一条日志，两个消费者**"的经典解法：**格式决定详略**，不是"取短的那部分"。

### 3.3 与 EP3 呼应：logger 自己什么都不写

> `[2:15:57]` ...and **a logger never writes anything itself. It hands each record to a handler**, which we'll wrap in a few minutes.
> **译文**：……而 logger 自己从不写任何东西。它把每条记录交给一个 handler，几分钟后我们会包一层。

💡 记住这句。下一节的整个 trick 就建立在这上面。

---

## 4. 全场最精妙的一段：让 logger 自己从 context 里取 request id

### 4.1 需求

> `[2:18:05]` Picture a user who reports that a transfer failed. The request came in through our gateway... into the transfer service, which called the wallet service. **That's three services and dozens of log lines, mixed in with thousands of other requests. How do you find the right ones?**
> **译文**：设想一个用户报告转账失败。请求从我们的网关进来……进到 transfer 服务，它又调了 wallet 服务。那是三个服务、几十行日志，混在成千上万其他请求里。你怎么找到对的那几行？

> `[2:18:23]` You give every request an ID at the edge and pass it along in a header: `x-request-id`. **Each service reuses the ID it receives, puts it on every log line, and sends it on to the next service.**

### 4.2 但不想每次都手动加

> `[2:19:18]` In Go, a per-request value belongs in the request context. **But we don't want every log call to fetch the ID and add it by hand, because someone would forget. Instead, we'll teach the logger itself to look in the context.**

**译文**：在 Go 里，一个"随请求走"的值属于 request context。**但我们不想每次打日志都去取 id 再手动加上，因为一定有人会忘。所以我们教 logger 自己去 context 里找。**

### 4.3 实现：10 行

```go
type contextHandler struct{ slog.Handler }

func (h contextHandler) Handle(ctx context.Context, r slog.Record) error {
	if attrs, ok := ctx.Value(attrsKey{}).([]slog.Attr); ok {
		r.AddAttrs(attrs...)
	}
	return h.Handler.Handle(ctx, r)
}
```

> `[2:19:57]` The context handler **embeds a `slog.Handler`**, so it gets every method of the real handler for free, and we only override what we need.

### 4.4 两个"经典错误"

> `[2:20:28]` **These two are the classic mistake.** When you call `logger.With`, slog calls the handler's `WithAttrs` method. **The embedded one would return the inner handler, without our wrapper — and from then on, request IDs would silently vanish.** And `New` calls `With` to add the service name, so **we'd lose the wrapper on the very first line**.

**译文**：**这两个是经典错误。** 当你调 `logger.With` 时，slog 会调 handler 的 `WithAttrs` 方法。**内嵌的那个会返回内层 handler，不带我们的包装——从那一刻起，request id 就悄悄消失了。** 而 `New` 会调 `With` 加上服务名，所以**我们在第一行就把包装弄丢了**。

所以必须：

```go
func (h contextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return contextHandler{h.Handler.WithAttrs(attrs)}
}
func (h contextHandler) WithGroup(name string) slog.Handler {
	return contextHandler{h.Handler.WithGroup(name)}
}
```

💡 **这是全课程最难发现的一个 bug 类别**：`slog.Handler` 的三个方法都返回 `Handler`，你只 override 了 `Handle`，另外两个**返回的是内层对象**，于是包装在第一次 `With` 时就蒸发了。测试里如果你只测"打一行日志有没有 id"，它**会通过**——因为你测试时用的 logger 可能没调过 `With`。

**验证方法**：写测试时**必须让 logger 经过 `With`**（他的 `New` 里就调了 `With(service, version)`，所以正常路径是安全的）。

### 4.5 `slog.Info` 没有 context

> `[2:21:06]` In a context handler there's one catch, and it's important: **the handler can only see the context if you give it one.** `logger.Info` has no context, so it gets an empty background context and **no request id**. Inside the request, **always use the context variants** — `InfoContext`, `WarnContext`, `ErrorContext` — and pass the request's context.

**译文**：context handler 有一个要注意的地方，很重要：**只有你给它 context，handler 才看得见。** `logger.Info` 没有 context，所以它拿到一个空的 background context，**没有 request id**。在请求内部，**永远用带 context 的变体**。

⚠️ 这是一个**静默失败**：`logger.Info("x")` 编译通过、日志正常、**只是没有 request id**。没有 lint 会报。

---

## 5. Request ID：为什么必须验证入站的值

> `[2:22:17]` The middleware reads the incoming header. If it's missing or not valid, we make a new ID with `crypto/rand.Text`, added in Go 1.24. It returns **26 random characters, 130 bits of randomness, with no dependency**.

> `[2:23:15]` And **why validate an incoming ID at all?** Because the header comes from the client and **we copy it into our logs and our responses**. Without a check, a client could send an ID that's **a megabyte long**, or one with **a newline and a fake log line after it**.

**译文**：**为什么还要校验一个入站的 ID？** 因为这个 header 来自客户端，而我们**会把它复制进日志和响应里**。不检查的话，客户端可以发一个**一兆字节长的** ID，或者一个**带换行、后面跟着一行假日志**的 ID。

> `[2:23:32]` So we accept **at most 64 letters, digits, dashes, and underscores**. Anything else is quietly replaced with a fresh ID.
> **译文**：所以我们最多接受 64 个字母、数字、连字符和下划线。其他任何内容都被静默换成一个新 ID。

💡 这是**日志注入（log injection）**：如果日志是 JSON，换行无害；如果日志是 text，攻击者能伪造一整行 `level=ERROR msg="payment failed" ...`，而你的告警规则会信它。**他的解法是白名单，不是转义**——白名单更容易验证。

另外注意：**id 进 context 两次**（`[2:22:50]`）——一次给业务代码读（`httpx.RequestIDFrom`），一次作为 log attr 给 logger 读。**两个 key 类型都是未导出结构体**，所以外部包不可能撞上。

---

## 6. Access log：三个必要的妥协

### 6.1 得先包住 ResponseWriter

> `[2:23:59]` There's a problem though. **The standard response writer doesn't tell you which status code the handler wrote, or how many bytes.** So we wrap it.
> **译文**：但有个问题。标准 response writer 不告诉你 handler 写了哪个状态码，也不告诉你写了多少字节。所以我们包一层。

```go
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}
```

> `[2:24:18]` `WriteHeader` remembers **the first** status code and passes it on — **only the first, because writing the header twice is a bug and the first one is what the client actually received.**
> **译文**：WriteHeader 记住第一个状态码并把它传出去——只有第一个，因为写两次 header 是 bug，而客户端真正收到的是第一个。

> `[2:24:45]` ...and if a handler calls `Write` **without calling `WriteHeader` first, `net/http` sends a 200.** So that's what we record.

### 6.2 `Unwrap`：别把 `Flush` 藏起来

> `[2:24:59]` **Wrapping a response writer hides any extra methods the real one has, like `Flush`, which streaming responses need.** Since Go 1.20, `http.ResponseController` calls `Unwrap` to find them, so our wrapper doesn't break those features.

**译文**：**包装 ResponseWriter 会隐藏真实对象上的额外方法，比如流式响应需要的 `Flush`。** 从 Go 1.20 起，`http.ResponseController` 会调用 `Unwrap` 去找它们，所以我们的包装不会破坏那些功能。

💡 这是**装饰器模式的经典陷阱**：`*http.ResponseWriter` 上有 `Flusher`、`Hijacker`、`Pusher` 等可选接口，包一层就全丢了。`Unwrap` 是标准库给出的官方后门。

### 6.3 错误级别怎么分

> `[2:25:27]` **Server errors are logged at error level**, so an alert on error logs fires **for them and only for them**. **A 404 is the client's problem, not ours, so it stays at info.**

**译文**：**服务器错误用 error 级别记录**，这样"error 日志"上的告警**只为它们触发，也只被它们触发**。**404 是客户端的问题，不是我们的，所以留在 info。**

💡 这是**告警信噪比**的设计：如果 404 也打 ERROR，你的告警就会因为扫描器而天天响，然后所有人开始忽略它。

### 6.4 两个小决定

> `[2:26:16]` **We log the path, not the full URL**, because query strings can contain things you don't want in logs, **like tokens or email addresses**. And in JSON **a duration is written as a number of nanoseconds, which log tools can graph directly.** If your team prefers milliseconds, that's a one-line change.
> **译文**：我们记 path，不记完整 URL，因为 query string 里可能带着你不想进日志的东西，比如 token 或邮箱地址。而在 JSON 里，一个时长被写成纳秒数，日志工具可以直接画图。如果你们团队偏好毫秒，那是一行改动。

---

## 7. `apperr`：错误分类，只此一处

> `[2:26:35]` The goal: **the domain code says what went wrong, and the HTTP layer decides how to say it.**
> **译文**：目标：领域代码说「出了什么错」，HTTP 层决定「怎么说」。

| 语义 | HTTP |
|---|---|
| not found | 404 |
| conflict | 409 |
| validation（带字段级消息） | 422 |
| 请求本身坏了（JSON 畸形） | 400 |
| body 太大 | 413 |
| 其它一切 | 500 |

> `[2:27:20]` ...and anything else is a 500. **That's our fault, not the client's. So the client gets a generic message and the real one goes to the log, tagged with the request ID.**

### 7.1 为什么单独一个包

> `[2:27:37]` Why a separate package for the errors? **Because the wallet's domain code must not import HTTP.** In episode 9 we'll add gRPC, and **the very same errors will map to gRPC codes**.

**译文**：为什么错误要单独一个包？**因为 wallet 的领域代码绝不能 import HTTP。** 第 9 集我们会加 gRPC，而**同一批错误会映射到 gRPC 的码**。

💡 **一句话预言了 5 集之后的复用。** 这也是判断"抽象是否过早"的标准：**如果第二个消费者已经在路线图上明确存在，那就不算过早。**

### 7.2 Go 最著名的坑：`nil` 接口里的 `nil` 指针

```go
func (v *ValidationError) Err() error {
	if len(v.Fields) == 0 {
		return nil
	}
	return v
}
```

> `[2:28:27]` ...`Add` records one, **creating the map on first use so the zero value of the struct is ready to use**... **This avoids one of Go's most famous traps: an interface holding a nil pointer is not a nil interface.** If a validate function returned a nil `*ValidationError` as an `error`, **`err != nil` would be true and every request would fail validation.** Returning `v.Err()` makes that mistake impossible.

**译文**：……`Add` 记录一条，**第一次使用时才创建 map，所以结构体的零值就能直接用**……**这避免了 Go 最著名的陷阱之一：一个持有 nil 指针的 interface 不等于 nil interface。** 如果 validate 函数返回一个 nil 的 `*ValidationError` 作为 `error`，**`err != nil` 会是 true，于是每个请求都会校验失败。**

💡 具体演示这个坑：

```go
var v *ValidationError = nil
var e error = v        // e != nil ！！因为类型信息还在
fmt.Println(e == nil)  // false
```

**`Err()` 这个小小的间接层，把一个"运行时全站 422"的 bug 变成了**写不出来**的代码。**

### 7.3 排序保证确定性

> `[2:28:56]` ...and `Error` lists the invalid fields **in sorted order, so messages and tests are deterministic**.
> **译文**：……而 Error 按排序后的顺序列出非法字段，这样消息和测试都是确定的。

💡 Go 的 map 遍历顺序是**随机**的。不排序 → 错误消息随机 → 测试间歇性失败 → 有人开始 `-count=1` 或者把断言改松。**一个 `slices.Sorted` 就解决了。**

---

## 8. `httpx`：输出与输入

### 8.1 先 encode，再写 header

> `[2:32:20]` `WriteJSON` **encodes the value first, and only then writes the header and the body.** If you stream straight into the response and encoding fails halfway, **the client has already received a 200 and half a body.** Encoding first means a bug becomes a clean 500 instead.

**译文**：`WriteJSON` **先把值编码完，然后才写 header 和 body。** 如果你直接往响应里流式编码，而编码中途失败，**客户端已经收到了 200 和半个 body。** 先编码意味着一个 bug 变成一个干净的 500。

💡 这条适用于**任何**序列化边界。判断标准：**状态码一旦写出去就收不回来。**

### 8.2 `decodeJSON` 的三道严格限制

> `[2:33:21]` `decodeJSON` is the other direction, and **it's strict on purpose**:
> **译文**：decodeJSON 是另一个方向，而它是故意严格的：

| 限制 | 防什么 |
|---|---|
| `MaxBytesReader`（1 MiB） | 客户端让你缓冲一个 G |
| `DisallowUnknownFields` | **拼错的字段被静默忽略** |
| 只允许一个值（后面必须 EOF） | `{"a":1}{"b":2}` 这类走私 |

> `[2:33:28]` **That matters for money.** If a client sends `amount` with a typo, we want **a clear error**, not a request that **silently ignores the field**.

**译文**：**这对钱很重要。** 如果客户端把 `amount` 拼错了，我们要**一个明确的错误**，而不是一个**静默忽略该字段**的请求。

💡 如果没有 `DisallowUnknownFields`，`{"amout": 100}` 会被解析成 `amount=0`（零值）→ **存 0 元成功，返回 201**。这是灾难，而它"看起来"完全正常。

### 8.3 把 JSON 的错误翻译成人话

> `[2:34:16]` `decodeError` turns `encoding/json`'s errors into messages **a client can actually act on**. **These are the errors clients hit most while they integrate with an API, so good messages here save real support tickets.**
> **译文**：decodeError 把 encoding/json 的错误变成客户端真正能据以行动的消息。这些是客户端接入 API 时最常撞上的错误，所以这里的好消息能省下真实的工单。

- 空 body、语法错误（带**字节偏移**）、body 中途断掉
- 类型错（要数字给了字符串）→ **点名字段和期望类型**
- 未知字段 → 只能匹配消息前缀（**"不漂亮，但这是有文档的消息"**）
- 超过上限 → 413

> `[2:35:09]` The **type** case shows why strictness pays off: **sending an amount as a string in quotes is one of the most common client bugs**, and now they find out **on their very first request**.
> **译文**：type 那个分支说明了严格为什么值得：把金额以带引号的字符串发出去是最常见的客户端 bug 之一，而现在他们在第一个请求上就知道了。

---

## 9. Panic recovery：为什么要自己写

> `[2:35:09]` You might know that `net/http` **already recovers from a panic** in our handler, so one bad request can't crash the whole server. **But look at what the client gets: the connection is simply closed with no response at all**, and the panic goes to standard error **as plain text, outside our structured logs, with no request ID**.

**译文**：你可能知道 `net/http` **已经会 recover handler 里的 panic**，所以一个坏请求不会让整个服务器崩掉。**但看看客户端拿到的是什么：连接被直接关掉，完全没有响应**，而 panic 以纯文本形式进了标准错误，**在我们的结构化日志之外，没有 request id**。

### 9.1 一个绝不能吞的 panic

> `[2:36:02]` ...there's **one panic we must not swallow**: `http.ErrAbortHandler`. Handlers use it **on purpose** to abort a response, and `net/http` handles it quietly, **so we re-panic and let it**.

**译文**：……有**一种 panic 我们绝不能吞**：`http.ErrAbortHandler`。handler 会**故意**用它来中止一个响应，`net/http` 会安静地处理它，**所以我们重新 panic，交给它。**

💡 为什么重要：`ErrAbortHandler` 的语义是"**我要立刻掐断这个连接，不要写任何东西**"（常用于检测到客户端已断开、或 gzip 写到一半出错）。如果你把它变成 500，你就在一个**已经废弃的响应**上开始写，可能触发更混乱的行为。

### 9.2 他把日志做成"一条事件"

> `[2:51:45]` ...and in the service's logs, that wall of text is **a single line**: "panic recovered" at error level with the panic value and **the whole stack trace in one attribute**, so **a log collector keeps it as one event**.

**译文**：……而在服务的日志里，那一大片文本是**一行**：error 级别的 "panic recovered"，带着 panic 值，**整个堆栈在同一个属性里**，所以**日志收集器把它当成一个事件**。

💡 如果 stack trace 用 `\n` 原样打出来，Loki/ES 会把**每一帧**当成一条独立日志，然后你的日志量和查询全乱。**把多行塞进一个字段（JSON 里自然会被转义）** 是正确做法。

### 9.3 用临时路由演示

> `[2:51:18]` ...I'll add a **temporary debug route** that does nothing but panic. **This is only for the demo and we'll delete it in a minute. Routes like this must never ship.**
> **译文**：……我会加一个临时调试路由，除了 panic 什么都不做。这只是为了演示，一分钟后我们就删掉。这种路由绝不能上线。

💡 他演示完立刻删掉，而且**明说要删**。这个动作本身是教学的一部分。

---

## 10. 配置长什么样

> `[2:43:40]` `config.go` lists everything the service can be configured with: the environment name, the HTTP address, the shutdown timeout, the log level and format, the database URL, and the pool size. **It reads it in one composite literal so you can see every variable and its default at a glance.**
> **译文**：config.go 列出这个服务能被配置的一切：环境名、HTTP 地址、关闭超时、日志级别和格式、数据库 URL、池大小。它在一个复合字面量里读入，所以你能一眼看到每个变量和它的默认值。

> `[2:44:34]` **It reads almost like documentation, which is exactly what you want from configuration code.**
> **译文**：它读起来几乎像文档，而这正是你对配置代码的期望。

💡 这是配置代码的设计目标：**一个字面量 = 一份完整的环境变量文档**。不需要另外维护 README 表格。

> `[2:44:34]` The log format's default **depends on the environment** — text in development, JSON in production — **and `LOG_FORMAT` can still override it.**
> **译文**：日志格式的默认值取决于环境——开发环境 text，生产环境 JSON——而 LOG_FORMAT 仍然可以覆盖它。

> `[2:45:01]` ...then a range check on the pool size using `Invalid()`, so **it's reported along with everything else**.
> **译文**：……然后是用 Invalid() 做的池大小范围检查，所以它会和其他问题一起被报出来。

---

## 11. `main.go` 重写后的四个改进

| 改进 | 原话 |
|---|---|
| DSN 兜底完全删除 | `[2:46:49]` **the DSN fallback disappears completely** |
| 版本号用 linker flag 注入 | `[2:45:55]` `-X` **overrides a string variable at link time** |
| 配置失败 exit 2 | `[2:46:22]` **the convention for bad usage** — 不能用 logger，因为 logger 的设置也在配置里 |
| 兜底 404 用 JSON | `[2:47:16]` a catch-all pattern `/` sends anything unmatched to our JSON not found |

> `[2:47:16]` **One trade-off: a wrong method on a real path now gets a 404 instead of a 405.** For an internal JSON API, I'm happy with that.

**译文**：**一个取舍：对一个真实路径用错方法，现在会得到 404 而不是 405。** 对于一个内部 JSON API，我接受这个。

💡 这也是 EP5 里 `walletID()` 解析失败返回 404 而不是 400 的同一条原则：**减少客户端要处理的分支**。

> `[2:47:43]` ...and `ErrorLog` redirects `net/http`'s messages like **TLS handshake failures** into slog at warning level, **so nothing escapes our structured logs.**
> **译文**：……而 ErrorLog 把 net/http 的消息，比如 TLS 握手失败，以 warning 级别重定向进 slog，所以什么都逃不出我们的结构化日志。

💡 这些漏网的日志正是 `http.Server.ErrorLog` 默认打到 stderr 的东西。不接住它们，你的日志里就会混进非 JSON 行，然后 Loki 的 JSON 解析器会在那一行失败。

---

## 12. 两个"为什么这样"的细节

### ① 为什么 `make run` 是先 build 再 run，而不是 `go run`

> `[2:49:03]` Why build and then run instead of `go run`? Because **`go run` starts our program as a child process — signals still reach it, but `go run` itself exits with an error after Ctrl-C**, and make would complain about it. **Running the binary directly keeps shutdown clean.**

**译文**：为什么先 build 再 run 而不是 `go run`？因为 **`go run` 把我们的程序当作子进程启动——信号仍能到达它，但 `go run` 自己在 Ctrl-C 之后会以错误退出**，make 就会报错。**直接跑二进制让关闭过程干净。**

💡 这是上一集 graceful shutdown 的直接后果：**你要测 SIGTERM 的行为，就不能让中间人干扰退出码。**

### ② 版本号来自 `git describe`

> `[2:49:57]` Look at the version: **the short commit hash from `git describe`, with `-dirty`** because we have uncommitted changes.
> **译文**：看这个版本号：来自 git describe 的短 commit hash，带 -dirty，因为我们有未提交的改动。

💡 一条日志里带 `service` + `version` + `request_id`，就足以从"用户截图"定位到"哪一行代码"。这是 EP4 三个功能的**乘积**意义。

---

## 13. 我的补注：这集的四个薄弱点

### ① `ReadHeaderTimeout` 有了，但 `ReadTimeout` / `WriteTimeout` 仍然缺失

EP1 设了 `ReadHeaderTimeout`，EP4 没补其余两个。于是：

- **慢 body**（客户端发 1 字节/秒的 body）不会被切断——`MaxBytesReader` 只管**大小**，不管**速度**
- **慢读者**（客户端不读响应）会让 handler 的 goroutine 永久阻塞在 `Write` 上

建议：

```go
ReadTimeout:  15 * time.Second,
WriteTimeout: 15 * time.Second,
IdleTimeout:  60 * time.Second,
```

### ② 1 MiB 的 body 上限对他自己的 API 够用，但要知道它在哪

```go
r.Body = http.MaxBytesReader(w, r.Body, 1<<20)  // 1 MiB
```

EP5 的 deposit 请求只有 `{"amount":2500,"currency":"USD"}`，几十字节。1 MiB 绰绰有余。**但 EP22 如果加批量导入，这个限制会突然变成瓶颈**——而且是 413，不是超时，比较好查。

### ③ 422 vs 400 的界线是他自己的约定，不是标准

他的分法：

| 谁拒绝 | 状态 | 客户端该怎么做 |
|---|---|---|
| **decoder**（读不懂：坏 JSON / 未知字段 / 类型错） | 400 | 这是**客户端代码的 bug** |
| **service**（读懂了但不允许：负数 / 不支持的币种） | 422 | 这是**要展示给用户的错误** |

> `[2:28:50]` ...**clients can treat the first as a bug in their code, and the second as something to show the user.**
> **译文**：……客户端可以把前者当成自己代码的 bug，把后者展示给用户看。

💡 这个区分比"422 是校验错误"这条教科书说法有用得多。**它回答的是"客户端拿到之后该干什么"。**

### ④ `contextHandler` 的两个 bug 没有任何测试能覆盖

他的 `middleware_test.go` 覆盖了 request id / access log / recover / chain 顺序，但**没有**专门测"`With` 之后 context handler 还在不在"。他的 `access log` 测试用了真实的 `logging.New`（里面调了 `With`），所以**间接**覆盖了。

但如果你想更稳，可以加一条：

```go
log := logging.New(...).With("k", "v")   // 再 With 一次
log.InfoContext(ctx, "x")                // 必须仍有 request id
```

---

## 14. 自测题

1. 如果把 `Recover` 放在 `AccessLog` 外面，会有什么具体现象？为什么测试抓不到？
2. 为什么 `RequestID` 必须在最外层？放在 `AccessLog` 内层会怎样？
3. `contextHandler` 只 override `Handle` 会怎样？在哪一步丢的包装？
4. `logger.Info` 和 `logger.InfoContext` 的区别是什么？用错会报错吗？
5. 为什么要校验入站的 `x-request-id`？举出两种攻击载荷。
6. `WriteJSON` 为什么必须**先** encode？如果直接流式写会出什么故障？
7. `DisallowUnknownFields` 对一个支付 API 为什么是必须的？举一个"没有它会静默出错"的请求。
8. `ValidationError.Err()` 避免了 Go 的哪个坑？画出那个坑的代码。
9. 为什么 `http.ErrAbortHandler` 必须 re-panic？
10. 一个 5 字节的错请求和一个 500 错误，在 access log 里应该是什么级别？为什么？
