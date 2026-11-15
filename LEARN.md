# learn 分支

自己的学习分支，**orphan**（无历史），只属于我，不会和教程的 `ep01..ep24` 打架。

- 起点：`ep01` / `e72c8be` 的代码快照
- 对象库和主干共用，所以随时能对比：`git diff origin/ep01 -- cmd/wallet/main.go`
- 教程原文在 `upstream`（dev-marker/payments），自己的 fork 是 `origin`（phakeandy/payments）

## 当前状态

`cmd/wallet/main.go`

- `main2()` —— 作者 ep01 的优雅退出骨架，原样保留，别动
- `main()` —— 我的实验：`signal.NotifyContext` + `time.Sleep(10s)`

跑实验：`go run ./cmd/wallet`，然后 Ctrl-C —— 现象是**完全没反应，必须等满 10 秒**。

## 今天想明白的

1. `defer stop()` 不是"触发优雅退出"的机制。让 goroutine 收到 `ctx.Done()` 的是**信号本身**，不是 `stop`。
   `stop()` = `cancel()` + `signal.Stop()`，管的是**信号注册的生命周期**，不是 goroutine 的生命周期。
   它在这里的价值：(a) Go 的 defer-cancel 配对约定，搬进 `run() error` / 测试里就变必需；(b) 不 `stop` 的话第二个 Ctrl-C 也会被吞，进程只能 `kill -9`。
2. `main` 返回 = 进程立刻退出，Go **不等** goroutine。所以清理必须是同步的（像 `main2` 里 `srv.Shutdown` 那样阻塞到完成），或者用 `errgroup` / `WaitGroup` 显式等。不能靠 `defer stop()`。
3. `main2` 里的精华：
   ```go
   shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
   ```
   parent 必须是 `context.Background()`（或 `context.WithoutCancel(ctx)`），**不能用 `ctx`** —— `ctx` 此刻已被信号取消，拿它当 parent 会让 `shutdownCtx` 出生即过期，in-flight 请求被直接砍掉，优雅退出退化成暴力退出。
4. `srv.Shutdown(shutdownCtx)` 的 10s 是**上限不是固定等待**：先立刻关 listener（微秒级，运维立刻看到），再等 in-flight 请求。没有在途请求时立即返回。
5. `time.Sleep` / 不可中断的下游调用，即使有 ctx 也没用 —— 必须 `select` 在 `ctx.Done()` 上，或者用 `NewRequestWithContext` / `QueryContext` / `CommandContext`。

## 明天接着做

- [ ] 把 `main()` 的实验改成 ctx-aware：`select { case <-time.After(10s): case <-ctx.Done(): }`，让 Ctrl-C 立刻返回
- [ ] 加二次信号强杀：`go func() { <-ctx.Done(); stop() }()`
- [ ] 把 `main2` 改成 `func main() { os.Exit(run()) }` 的形状，顺便把 goroutine 里的 `os.Exit(1)` 换成 error channel / `errgroup`
- [ ] 复现 `main2` 的缺口：端口被占用时 `ListenAndServe` 秒返回，但 main 还卡在 `<-ctx.Done()` → 进程活着却不监听
