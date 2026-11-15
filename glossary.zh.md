# 术语表（中文对照）

读注释卡住时先查这里。每个词给「中文 + 在本仓库里的具体含义」，不是词典释义。

---

## 一、消息与事件

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `subject` | 主题 / 地址 | 消息地址，用 `.` 分层：`wallet.events.deposit.completed.v1`。支持 `>`（多级）和 `*`（单级）通配 |
| `stream` | 流 | 持久化存储，按 subject 通配符收集消息。本仓库有 `WALLET`、`TRANSFER` 两个 |
| `JetStream` | — | NATS 的持久化层。启动参数 `-js` 打开。没有它，NATS 就是发完即忘的广播 |
| `core NATS` | 核心 NATS | 不带持久化的 pub/sub。**本仓库一条都没用** |
| `durable consumer` | 持久消费者 | 名字固定在服务器上（`Durable: "notification"`），重启后从上次进度继续 |
| `filter subject` | 过滤主题 | 一个消费者只收自己关心的 subject，比如 `wallet.events.deposit.>` |
| `DeliverNewPolicy` | 只投新消息 | 上线后不看历史（不给上月充值补发邮件） |
| `DeliverAllPolicy` | 从头投递 | 新消费者从第一条开始（`cmd/eventlog` 用它回放） |
| `ack` | 确认 | 处理完了，游标前进 |
| `nak` / `NakWithDelay` | 否定确认 | 我这边暂时不行，过会儿再给我 |
| `term` / `Term` | 终止 | 永远别再给我（数据坏了，重试无意义） |
| `redelivery` | 重投 | 没 ack 就再送一次。`AckWait` 决定等多久 |
| `MaxAckPending` | 在途上限 | 全局同时处理中的消息数，天然背压 |
| `MaxDeliver` | 最大投递次数 | 超过就放弃，进死信 |
| `at-least-once` | 至少一次 | 会重复，不会丢。本仓库的实际语义 |
| `at-most-once` | 至多一次 | 会丢，不会重复 |
| `exactly-once` | 恰好一次 | 分布式系统里基本做不到，本仓库靠「至少一次 + 幂等」逼近 |
| `effectively once` | 事实上的恰好一次 | 重复被消费端去重掉后的实际效果 |
| `Nats-Msg-Id` | 消息 ID | 发布时带上，10 分钟内同 ID 只存一份 → 去重 |
| `dead letter` / DLQ | 死信 | 放弃处理的消息存起来等人查，防止毒丸卡住队列 |
| `poison message` | 毒丸消息 | 永远处理不成功的消息 |
| `outbox` | 发件箱 | 事件先写进数据库表，和业务改动同一个事务 |
| `relay` | 中继器 | 扫 outbox 表，把行发到 JetStream，然后标记已发 |
| `fan out` | 扇出 | 一个事件复制给 N 个订阅者（webhook 那段） |
| `backoff` | 退避 | 失败后等得越来越久 |
| `jitter` | 抖动 | 退避时间上加随机量，防止所有客户端同时重试（惊群） |
| `head-of-line blocking` | 队头阻塞 | 一条卡住后面的全卡住。relay 遇到失败就停，正是为了不制造这个 |

## 二、账本与会计

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `double-entry` | 复式记账 | 每笔钱的移动都记两条对称分录，借方合计 = 贷方合计 |
| `ledger` | 账本 | `entries` 表。只追加，不改不删 |
| `entry` / `posting` | 分录 | 一整行「借/贷某账户多少钱」。FX 转换会产生四条 |
| `debit` / `credit` | 借方 / 贷方 | 分录的方向。本仓库用 `direction` 字段 |
| `account` | 账户 | `accounts` 表。分 `wallet`（用户的）和 `system`（如 `holds`） |
| `balance` | 余额 | **算出来的**，不存在账本里。所以不会和分录不一致 |
| `hold` | 冻结 / 预授权 | 先占住钱，`status = 'held'` |
| `capture` | 扣款 / 捕获 | 把冻结的钱真正转走 |
| `release` | 解冻 / 释放 | 撤销冻结，钱放回去 |
| `settled_to` | 结算去向 | 冻结最终流向哪个账户 |
| `reconcile` / `reconciliation` | 对账 | 拿分录算出的余额和事实核对一遍，找出不一致 |
| `trial balance` | 试算平衡表 | 所有科目按币种汇总，看借贷总额是否相等 |
| `statement` | 对账单 | 给用户看的交易流水（CSV 导出） |
| `minor units` | 最小货币单位 | 分 / 厘。钱一律 `int64` 存它，绝不存浮点 |
| `invariant` | 不变量 | 任何时刻都必须成立的等式，比如「借贷相等」「余额不为负」 |

## 三、钱与汇率

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `FX` | 外汇 | 货币转换 |
| `conversion` | 兑换 | 从一个钱包卖出币种 A、买入币种 B |
| `quote` | 报价 | 带有效期（过期就作废）的汇率 |
| `rate` | 汇率 | 存成整数（十亿分之一为单位），不用 float |
| `exponent` | 小数位数 | ISO 4217 规定：USD=2，JPY=0，KWD=3 |
| `round down` / `round up` | 向下 / 向上取整 | 付出去向下，收进来向上 —— 永远不亏 |
| `fee` | 手续费 | 在卖出金额之外另收 |
| `spread` | 点差 | 买入价和卖出价的差，这里体现为 fee |

## 四、并发与数据库

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `row lock` / `FOR UPDATE` | 行锁 | 事务结束前其他事务不能改这几行 |
| `SKIP LOCKED` | 跳过已锁 | 多个实例分活，不互相阻塞（relay 用的） |
| `lock ordering` | 锁顺序 | 永远按同一顺序加锁（如先小 ID 后大 ID），避免死锁 |
| `deadlock` | 死锁 | 两个事务互相等对方放锁 |
| `retry on conflict` | 冲突重试 | 撞上并发就重来，而不是报错 |
| `idempotency key` | 幂等键 | 客户端给的唯一 ID，同 key 重复请求只生效一次 |
| `keyset pagination` | 游标分页 | 用「上一页最后一条的 ID」翻页，不用 `OFFSET`（大偏移量很慢） |
| `migration` | 数据库迁移 | `db/*/migrations/` 下的 SQL，按序号执行 |
| `sqlc` | — | 把 SQL 编译成类型安全的 Go 函数，手写 SQL 但不用手写 Scan |
| `pgx` | — | Go 的 PostgreSQL 驱动 |
| `LISTEN` / `NOTIFY` | 数据库通知 | 事务提交时发个信号，relay 用它立刻醒来（不用死轮询） |
| `transactional outbox` | 事务性发件箱 | 「写业务表 + 写事件表」放进同一个事务 |

## 五、可靠性与故障

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `saga` | 长事务模式 | 跨服务做不到一个事务，就用「每步都有反悔动作」串起来 |
| `compensation` | 补偿 | saga 里的反悔动作，比如「解冻」补偿「冻结」 |
| `bulkhead` | 舱壁 | 隔离资源池，一个慢功能不拖垮全部（报表用） |
| `chaos` / `game day` | 混沌工程 / 演练日 | 故意注入故障，验证系统还能自愈、账本还平 |
| `Toxiproxy` | — | 在服务之间插一个代理，可以切断/延迟/丢包 |
| `drain` / `draining` | 优雅退出 | 先说自己不健康，把手上的请求做完再退出 |

## 六、安全

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `JWT` | — | 自包含的令牌，网关在入口验证 |
| `access token` / `refresh token` | 访问令牌 / 刷新令牌 | 前者短命，后者可轮换 |
| `argon2id` | — | 密码哈希算法（抗 GPU 暴力破解） |
| `EdDSA` | — | 签名算法，服务间验令牌用它 |
| `mTLS` | 双向 TLS | 客户端和服务端互相验证书，服务间通信才允许 |
| `least privilege` | 最小权限 | 每个服务一个数据库角色，只能干它该干的事 |
| `audit log` | 审计日志 | 谁在什么时候做了什么，事后可追 |
| `govulncheck` | — | 检查依赖里有没有已知漏洞的调用 |

## 七、交付与运维

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `liveness` / `readiness` | 存活 / 就绪探针 | 前者「要不要重启我」，后者「要不要给我流量」 |
| `distroless` | — | 镜像里没有 shell 和包管理器，攻击面小 |
| `rolling update` | 滚动更新 | 一个个换 pod，服务不中断 |
| `autoscaling` | 自动扩缩容 | 按负载加减副本 |
| `leader election` | 选主 | 多副本里只有一个执行定时任务，避免重复跑 |
| `Helm` / `kind` | — | k8s 的包管理 / 本地 k8s 集群 |

## 八、测试

| 英文 | 中文 | 本仓库里指什么 |
|---|---|---|
| `table test` | 表驱动测试 | 一张表列所有用例，循环跑 |
| `integration test` | 集成测试 | 连真的 PostgreSQL / NATS / Redis（`testcontainers` 起临时容器） |
| `testcontainers` | — | 用 Docker 临时起依赖，用完销毁 |
| `race detector` | 竞态检测器 | `go test -race`，发现数据竞争 |
| `fuzz` | 模糊测试 | 随机输入找 panic |
| `load test` | 压测 | `loadtest/` 里的 k6 脚本 |
| `-short` | 短测试模式 | `go test -short` 跳过集成测试，几秒跑完 |
