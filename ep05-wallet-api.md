# EP05 讲义：The Wallet API（金额、存款与分页）

- **视频** `2:55:16 – 3:41:12`（46 分）｜分支 `ep05` ｜ diff：`+788 / -8`（12 个文件）
- **转录** `media/ep05.txt`（188 句，5,982 词）
- 时间戳是视频绝对时间

一句话：**钱第一次以"接口"的形式出现，而"存款"这件事逼出了复式记账里最不直观的一个概念：钱从哪来。**

---

## 0. 这一集补的是"中间那两层"

> `[2:56:58]` ...and in `internal/wallet`, there's the store from episode 3. It can create accounts, read balances, list entries, and post balanced transactions atomically. **What's missing is everything in between**: something that decides **what a client may ask for**, and something that **speaks HTTP**.

**译文**：……而 `internal/wallet` 里有第 3 集的 store。它能建账户、读余额、列分录，原子地记账。**缺的是中间那两层**：一个决定**客户端可以要求什么**的东西，和一个**会说 HTTP** 的东西。

---

## 1. 五个端点 + 三条约定

> `[2:57:28]` Five endpoints: a `POST /v1/wallets` opens a wallet, a `GET` on a wallet's ID reads it back, its balance has its own URL, `POST` to its deposits adds money, and entries list the wallet's ledger entries one page at a time.
> **译文**：五个端点：POST /v1/wallets 开一个钱包，对钱包 ID 的 GET 把它读回来，它的余额有自己的 URL，对它的 deposits 发 POST 加钱，entries 一页一页列出这个钱包的账本分录。

| 方法   | 路径                        | 语义                   |
| ------ | --------------------------- | ---------------------- |
| `POST` | `/v1/wallets`               | 开户                   |
| `GET`  | `/v1/wallets/{id}`          | 读钱包                 |
| `GET`  | `/v1/wallets/{id}/balance`  | 读余额（**单独 URL**） |
| `POST` | `/v1/wallets/{id}/deposits` | 存钱                   |
| `GET`  | `/v1/wallets/{id}/entries`  | 分页流水               |

> `[2:57:47]` Notice the conventions: **the path names the thing, and the HTTP method says what we do with it.** Everything lives under `v1`, so the day we need a breaking change, **a v2 can live right next to it while existing clients keep working.**
> **译文**：注意这些约定：路径命名那个东西，HTTP 方法说明我们拿它做什么。一切都在 v1 之下，所以哪天需要破坏性改动，v2 可以直接住在旁边，而现有客户端继续能用。

### 1.1 为什么余额是独立的 URL

因为余额不是钱包的"字段"，它是**由分录推导出来的视图**（EP2）。给它一个独立的路径，是让 API 的形状**说实话**。

### 1.2 `GET` 安全、`POST` 不幂等——这句话是 EP7 的引信

> `[2:58:13]` One more property of these methods matters for money: **`GET` is safe — it never changes anything, so clients, proxies, and browsers may retry it freely. `POST` is neither safe nor idempotent — sending the same POST twice can create two of something, like two deposits.** Keep that in mind because **it's exactly the problem idempotency keys solve in episode 7.**
> **译文**：这些方法还有一个属性对钱很重要：GET 是安全的——它从不改变任何东西，所以客户端、代理和浏览器可以随意重试。POST 既不安全也不幂等——同一个 POST 发两次可能造出两个东西，比如两笔充值。记住这一点，因为那正是第 7 集幂等键要解决的问题。

💡 注意他不是说"POST 不好"。他说的是：**HTTP 语义已经告诉你 `POST /deposits` 会重复扣钱**。EP7 不是"加个功能"，是**修补一个由协议语义决定的结构性缺口**。

---

## 2. 分层：为什么不把校验放在 handler

> `[2:58:49]` The **handler** deals with HTTP **and only HTTP**: it decodes JSON, reads the URL, and writes responses. The **service** holds the business logic — is this currency supported, is this amount positive, does this wallet exist — and **it knows nothing about HTTP, which matters because in episode 9, the same service gets a gRPC front door, and the rules must be identical.** The **store**, which we already have, runs SQL and owns database transactions. And **PostgreSQL sits at the bottom with constraints that refuse bad data, even if every layer above it has a bug.**

### 2.1 为什么不能只在 handler 校验

> `[2:59:26]` **Why not just validate in the handler?** Because then **every new way in — a gRPC endpoint, a message consumer, an admin tool — has to repeat every check, and sooner or later one of them forgets.**

**译文**：**为什么不就在 handler 里校验？** 因为那样**每一个新的入口——一个 gRPC 端点、一个消息消费者、一个管理工具——都得重复所有检查，而迟早有一个会忘。**

💡 "sooner or later one of them forgets" —— 这是**所有重复校验设计**的最终结局。不是"可能出错"，是"一定会"。

### 2.2 为什么不能放进 store

> `[2:59:37]` And why not put the rules in the store? **Because the store's job is SQL. Keeping each layer to one job is what keeps them small enough to read, and easy to test.**
> **译文**：那为什么不把规则放进 store？因为 store 的职责是 SQL。让每一层只干一件事，它们才小到能读、容易测。

### 2.3 一张"谁能拒绝什么"的表

| 层                | 拒绝什么               | 例子                               | 返回              |
| ----------------- | ---------------------- | ---------------------------------- | ----------------- |
| handler / decoder | 读不懂的请求           | 坏 JSON、未知字段、`"2500"` 当数字 | **400**           |
| service           | 读懂了但不允许         | 负数、不支持的币种、币种不匹配     | **422**（字段级） |
| store             | 数据库层面不可能       | 唯一索引冲突、触发器不平衡         | 翻译成领域错误    |
| **PostgreSQL**    | **上面三层全都失手时** | CHECK / FK / 延迟触发器            | `23514` / `23505` |

> `[3:28:36]` ...**two kinds of client errors, and they come from different layers.** A request we can't even **read** — broken JSON, an unknown field, or a number where we need an integer — is a **400**, from the decoder. A request that's **perfectly readable, but asks for something we won't do** — like a negative amount, or an unsupported currency — is a **422**, from the service, with a message per field.
> **译文**：……两类客户端错误，而且它们来自不同的层。一个我们连读都读不了的请求——坏 JSON、未知字段、该给整数的地方给了数字——是 400，来自解码器。一个完全读得懂、但要求我们不做的事的请求——比如负数金额、不支持的币种——是 422，来自服务层，每个字段一条消息。

> `[3:29:05]` **Clients can treat the first as a bug in their code, and the second as something to show the user.**
> **译文**：客户端可以把前者当成自己代码里的 bug，把后者展示给用户。

---

## 3. 钱在线上长什么样

> `[3:00:03]` ...**an amount is an object with two fields: an integer number of minor units, and an ISO currency code.** $10.50 is `1050` in USD. **The currency always travels with the amount**, because **a bare number like 10.50 means nothing on its own.**
> **译文**：……金额是一个带两个字段的对象：以最小单位计数的整数，以及一个 ISO 币种代码。$10.50 在 USD 下是 1050。币种永远跟着金额一起走，因为像 10.50 这样的裸数字本身没有意义。

```go
type Money struct {
	Amount   int64  `json:"amount"`   // 最小单位（分）
	Currency string `json:"currency"` // ISO-4217
}
```

### 3.1 为什么不用浮点

> `[3:00:29]` **Because binary floating point can't represent most decimal fractions exactly. 0.1 + 0.2 is not 0.3** — it's off by a tiny amount, and **tiny amounts add up over millions of transactions, until your books don't balance.**

**译文**：**因为二进制浮点无法精确表示大多数十进制小数。0.1 + 0.2 不等于 0.3**——差一点点，而**这一点点在几百万笔交易之后会累积，直到你的账不平。**

### 3.2 为什么不用十进制字符串

> `[3:00:41]` Some APIs send decimal strings instead, like `"10.50"` — **that's exact**. But **every client has to parse it**, and `"10.50"` and `"10.5"` are **different strings for the same money**. Integers are exact, and **they add and compare directly**. That's why **Stripe, Adyen, and most payment APIs use minor units.**

**译文**：有些 API 发十进制字符串，比如 `"10.50"`——**那是精确的**。但**每个客户端都得解析它**，而且 `"10.50"` 和 `"10.5"` 是**同一个金额的两个不同字符串**。整数是精确的，而且**可以直接相加和比较**。这就是为什么 **Stripe、Adyen 和大多数支付 API 都用最小单位**。

💡 这段的三个层次值得记：

1. 浮点 **不精确**（技术事实）
2. 字符串 **精确但不规范**（`"10.5"` vs `"10.50"`）
3. 整数 **精确且规范** → **可直接比较、相加、做唯一索引**

### 3.3 不是所有货币都有两位小数

> `[3:01:06]` **One catch: not every currency has two decimals.** ISO 4217 gives each currency an **exponent**: dollars and euros have **two**, so 10.50 is `1050`. **The Japanese yen has none**, so 1050 yen is `1050`. And a few, **like the Kuwaiti dinar, have three.**

> `[3:01:23]` A client formats an amount for display by **dividing by 10 to the power of the exponent**... **but it does arithmetic on the integers, never on the formatted text.**

**译文**：客户端显示金额时**除以 10 的 exponent 次方**……**但它在整数上做运算，绝不在格式化后的文本上做。**

💡 这是 EP18 的伏笔：`internal/fx/convert.go` 里有 `exponents` 表（JPY=0、KWD=3），做换汇时**必须先对齐 exponent**。

⚠️ 转录错误：`[3:01:15]` 的 "Kuwaiti **dinner**" 是 **dinar**（第纳尔）。

### 3.4 int64 够用吗

> `[3:01:34]` ...an int64 holds **over 9 quintillion minor units**. **JavaScript numbers are only exact up to 2^53**, about 9 quadrillion — which is still **$93 trillion in cents**. ...we cap a single deposit at **100 million minor units, a million dollars**, so **a typo with a few extra zeros gets caught**, and no amount ever gets anywhere near those limits.
> **译文**：……int64 能装下超过 9 百亿亿个最小单位。JavaScript 的数字只在 2^53 以内精确，大约 9 千万亿——那仍然是以分为单位的 93 万亿美元。……我们把单笔充值上限定在 1 亿最小单位、一百万美元，这样多打几个零的笔误会被抓住，而且任何金额都永远不会接近那些界限。

| 类型        | 精确上限           | 折算成美分   |
| ----------- | ------------------ | ------------ |
| `int64`     | 9.22 × 10^18       | 天文数字     |
| JS `Number` | 2^53 ≈ 9.0 × 10^15 | **$93 万亿** |
| `MaxAmount` | 10^8               | **$100 万**  |

💡 **关键洞察**：真正的约束不是 Go 的 `int64`，是**前端 JavaScript 的 2^53**。JSON 里的数字会被 `JSON.parse` 成 double。所以**上限必须远小于 2^53**，否则前端会静默丢精度。

### 3.5 什么时候该用 decimal

> `[3:02:02]` ...libraries like `shopspring/decimal` are a fine choice **where fractions of a cent really appear — interest, exchange rates, fees as a percentage** — but **for storing and moving money, integers are simpler and faster**, they match the `bigint` column in our ledger, and **when you do compute a fee, you round it to a whole minor unit once, on purpose, and post the result.**

**译文**：……像 `shopspring/decimal` 这样的库，在**真的出现"分的小数"时**是好选择——利息、汇率、按百分比算的手续费——但**存储和移动钱，整数更简单也更快**，它们和账本里的 `bigint` 列对得上，而且**当你真的算一笔手续费时，你会有意地一次性四舍五入到一个完整的最小单位，然后记这个结果。**

💡 "round it once, on purpose" —— **舍入只发生一次，而且是显式的**。反复舍入是财务系统的经典 bug 来源。EP18 的 FX 会把它变成 `Down`/`Up` 两个函数。

---

## 4. 存款：钱从哪来？

这一节（`3:02:30 – 3:03:33`）是全集的核心。

> `[3:02:30]` Say Alice adds $25 from her bank card. **The naive version simply credits her wallet with 2500 cents. But in double-entry every transaction must balance — a credit with no matching debit is money appearing from nowhere, and our ledger's trigger would reject it at commit. So where does the money come from?**

**译文**：假设 Alice 用银行卡充 25 美元。**朴素版本直接给她的钱包贷记 2500 分。但在复式记账里每笔交易都必须平衡——一笔没有对应借记的贷记就是凭空出现的钱，而我们账本里的触发器会在 COMMIT 时拒绝它。那么钱从哪来？**

### 答案：一个叫 settlement 的系统账户

> `[3:02:56]` **From outside our system. We represent "outside" with a system account called `settlement`, one per currency** — it stands for **the money we actually hold at our bank**. **A deposit debits settlement and credits Alice's wallet by the same amount.**

> `[3:03:06]` `settlement` is **debit-normal, like an asset** — its balance is **what we hold**. The wallet is **credit-normal, like a liability** — its balance is **what we owe Alice**. **So after every deposit, what we hold equals what we owe.**

**译文**：`settlement` 是**借方正常，像资产**——它的余额是**我们持有多少**。钱包是**贷方正常，像负债**——它的余额是**我们欠 Alice 多少**。**所以每笔存款之后，我们持有的等于我们欠的。**

```
            借方(Debit)              贷方(Credit)
settlement  +2500   ← 我们持有        （减少）     资产，debit-normal
Alice钱包              （减少）        +2500       负债，credit-normal
```

> `[3:03:19]` That equation — **what we hold equals what we owe** — **is the whole point of double-entry, and our database enforces it.**
> **译文**：那个等式——我们持有的等于我们欠的——就是复式记账的全部要点，而我们的数据库强制执行它。

💡 这段解释了一个很多人学复式记账时卡住的地方：**为什么"充值"需要两条分录？** 因为**钱是从系统外部进来的**，而外部必须被建模成一个账户，否则分录就不平衡。这个"外部账户"在会计里叫**对方科目**，在这里叫 settlement。

⚠️ 转录错误：`[3:02:56]` 的 "SetTillament" / `[3:03:06]` 的 "SetTillament" 都是 **settlement**（`wallet.SettlementAccount`）。

### 4.1 为什么 settlement 账户用迁移创建，而不是懒创建

> `[3:03:33]` That means the settlement accounts **must exist before the first deposit**. **We could create them lazily, the first time someone uses a currency, but two requests could race to create the same account, and money code is no place for races.** Instead, **a migration seeds one settlement account per supported currency** — **supporting a new currency becomes a deliberate act, a reviewed migration, not a side effect of somebody's first request.**

**译文**：这意味着 settlement 账户**必须在第一笔存款之前就存在**。**我们可以在第一次有人用某个币种时懒创建，但两个请求可能竞争着创建同一个账户——而钱的代码不是放竞争的地方。** 所以**用迁移播种每个支持币种的 settlement 账户**——**支持一个新币种变成一个刻意的行动、一次被 review 的迁移，而不是某人第一个请求的副作用。**

💡 这段话的**结构**比内容更值得学：**"我可以做 X，但 Y 会让它变坏，所以我选了 Z，代价是 W。"** 每个设计决定都长这个样子。

💡 附带效果：**"支持哪些币种"的真相在数据库里**。EP5 后面（`[3:15:29]`）会用到这一点。

### 4.2 另一个更隐蔽的问题：谁有权调用存款？

> `[3:04:19]` **And who's allowed to call deposits? Not Alice's phone, directly.** In production **a deposit is posted when the payment provider confirms that the money really arrived, usually through a webhook to an internal service** — and only then do we credit the wallet. **Today our endpoint trusts its caller**; in episode 10 the API gateway decides who gets to call what, and that's where this endpoint gets locked down.

**译文**：**谁被允许调用存款？不是 Alice 的手机直接调。** 生产环境里，**存款是在支付服务商确认钱真的到账之后才记的**，通常是通过一个 webhook 送到一个内部服务——只有那时我们才给钱包贷记。**今天我们这个端点信任它的调用方**；第 10 集 API 网关会决定谁能调什么。

⚠️ **这是本集最容易被忽略的安全缺口。** 一个暴露在公网的 `POST /v1/wallets/{id}/deposits` = **免费铸币机**。他现在标出来，EP10 才补。**如果你照抄这段代码上线，你就开了一家印钞厂。**

---

## 5. 迁移 `000002`：五个技巧

### 5.1 给已有表加 NOT NULL 列，要三步

> `[3:05:46]` ...adding a NOT NULL column to a table that may already have rows **takes three steps**: add it **with a default**, so existing rows get a value — **since PostgreSQL 11 that's cheap even on a huge table, with no rewrite** — then **fix the rows that should be different**, and **drop the default**, so from now on **every insert has to say which kind it means: a forgotten kind becomes an error, instead of a silent wallet.**
> **译文**：……给一个可能已有数据的表加 NOT NULL 列分三步：先带默认值加上，这样已有行拿到值——从 PostgreSQL 11 起，即便在巨大的表上这也很便宜，不用重写——然后把那些该不一样的行改掉，最后把默认值去掉，这样从现在起每次插入都必须说明它是哪种：漏掉 kind 会变成一个错误，而不是一个静默的钱包。

```sql
ALTER TABLE accounts ADD COLUMN kind account_kind NOT NULL DEFAULT 'wallet';
UPDATE accounts SET kind = 'system' WHERE owner_id IS NULL;
ALTER TABLE accounts ALTER COLUMN kind DROP DEFAULT;
```

💡 三个知识点的组合：

1. **PG 11+ 加带默认值的列不重写表**（之前的版本会）
2. 有默认值 → 老行有值 → 能通过 NOT NULL
3. **立刻删掉默认值** → 新行必须显式指定

第 3 步是**道德上的关键**：如果留着默认值，以后忘记写 `kind` 的代码会**静默创建错误类型的账户**。**宁可让它报错。**

### 5.2 `class` 用 CHECK 约束绑定

> `[3:06:17]` ...then a check constraint that **ties the kind to the owner**. It compares two booleans — **is this a wallet, and does it have an owner** — they must be equal. So **a wallet without an owner, or a system account with one, simply can't exist.**
> **译文**：……然后是一个把 kind 和 owner 绑在一起的 check 约束。它比较两个布尔值——这是不是一个钱包，它有没有主人——它们必须相等。所以一个没有主人的钱包，或者一个带主人的系统账户，根本不可能存在。

```sql
CHECK ((kind = 'wallet') = (owner_id IS NOT NULL))
```

💡 一行约束表达了**两条**业务规则。而且它和 EP2 的"用约束代替应用校验"是同一个思想：**这条规则不靠任何一层代码记得检查。**

### 5.3 两个 partial unique index

> `[3:06:32]` **A partial index only covers the rows that match its WHERE clause.**
> **译文**：部分索引只覆盖匹配它 WHERE 子句的那些行。

```sql
-- 一个 owner 每种币种只能有一个钱包
CREATE UNIQUE INDEX ON accounts (owner_id, currency) WHERE kind = 'wallet';

-- 系统账户按名字+币种唯一
CREATE UNIQUE INDEX ON accounts (name, currency) WHERE kind = 'system';
```

> `[3:06:50]` The first says **an owner can have one wallet per currency** — that's a product rule, **and it lives in the database**, so two simultaneous requests can't both create one.
> **译文**：第一条说一个主人在每种币种下只能有一个钱包——这是产品规则，而它住在数据库里，所以两个同时到达的请求不可能都建成功。

> `[3:07:04]` The second makes system accounts unique by name and currency, so **our code can look up the `settlement` account by name and know there's exactly one.**
> **译文**：第二条让系统账户按名字加币种唯一，这样我们的代码可以按名字查到 settlement 账户，并知道它恰好只有一个。

💡 为什么必须 partial？因为普通唯一索引会让 `(owner_id, currency)` 上的 `NULL` 表现不对——**Postgres 里 `NULL` 不等于 `NULL`**，所以多个系统账户（owner 为 NULL）在普通唯一索引下**不会冲突**。partial index 用 `WHERE kind='system'` 把两类行分开，各自约束。

### 5.4 `ON CONFLICT` 必须重复 WHERE 子句

```sql
INSERT INTO accounts (...) VALUES (...)
ON CONFLICT (name, currency) WHERE kind = 'system' DO NOTHING;
```

> `[3:07:34]` ...`ON CONFLICT DO NOTHING` makes **the seed safe to run twice**... **The conflict target repeats our partial index's WHERE clause, so PostgreSQL knows exactly which rule we mean.**
> **译文**：……ON CONFLICT DO NOTHING 让种子脚本重复跑也安全……冲突目标重复了我们部分索引的 WHERE 子句，所以 PostgreSQL 明确知道我们指的是哪条规则。

💡 这是个经常被忘的语法要求：partial index 的 `ON CONFLICT` **目标**必须包含同样的 `WHERE`，否则 Postgres 找不到你指的是哪个索引。

### 5.5 索引要匹配查询的形状

> `[3:07:48]` And one more index, for the entries endpoint: we'll list one wallet's entries, **newest first, by id**. **An index on `account_id` and then `id`** lets Postgres **jump straight to one account's entries, already in order**. It serves lookups by `account_id` alone as well, **so the old index can go.**
> **译文**：再一个索引，给 entries 端点用：我们要列一个钱包的分录，最新的在前，按 id。先 account_id 再 id 的索引让 Postgres 直接跳到某个账户的分录、而且已经是排好序的。它也顺带服务只按 account_id 的查找，所以旧索引可以删了。

```sql
CREATE INDEX ON entries (account_id, id);
DROP INDEX entries_account_id_idx;  -- 被上面这个前缀覆盖了
```

💡 复合索引 `(a, b)` 能服务 `WHERE a=?`（最左前缀），所以单列索引 `(a)` 是冗余的。**多一个索引就多一份写放大。**

> `[3:08:17]` On a big production table, you'd build it with `CREATE INDEX CONCURRENTLY`, **outside a transaction**, so writes aren't blocked while it builds. Our table is tiny, so this is fine.
> **译文**：在大的生产表上，你会用 CREATE INDEX CONCURRENTLY 在事务外建它，这样建的时候写不被阻塞。我们的表很小，所以这样没问题。

### 5.6 down migration 故意不删 settlement

> `[3:08:47]` Notice what it **doesn't** do: **delete the settlement accounts. Once they have entries they can't be deleted — and they shouldn't be.** Without a `kind` column, an account with no owner is a system account again, just like before.
> **译文**：注意它没做什么：删掉 settlement 账户。一旦它们有了分录就不能删——也不该删。没有 kind 列的话，一个没有主人的账户就又是系统账户，和以前一样。

💡 **回滚不是"逆向执行"，是"回到一个仍然自洽的状态"。** data 的删除几乎永远不该放在 down migration 里。

### 5.7 他自己踩的坑（这一条对你尤其重要）

> `[3:09:02]` **One heads-up if you're coding along**: our integration tests have been **writing accounts without an owner into your local database**. This migration would **turn them into system accounts**, and **the unique index would refuse their duplicate names**. Production has no such rows, but your laptop does. So **first recreate the local database** with `docker compose down -v` and up again.

**译文**：**一个提醒，如果你在跟着敲**：我们的集成测试一直往你的本地数据库里**写没有 owner 的账户**。这个迁移会**把它们变成系统账户**，而**唯一索引会拒绝它们重复的名字**。生产环境没有这种行，但你的笔记本有。所以**先重建本地数据库**。

💡 这就是 EP3 里他主动标注的那笔债（"集成测试写进开发库"）**第一次收到利息**。他当时说"因为每次用新 UUID，所以无害"——确实无害，**直到有一个迁移对数据做了语义假设**。

⚠️ `docker compose down -v` 会**删掉你的数据**。EP1 `[0:23:24]` 已经警告过。

---

## 6. sqlc 重新生成：一个值得注意的细节

> `[3:10:33]` `make generate` runs sqlc. **It reads the new migration too**, so the generated models now have an `account_kind` enum type with a constant for each value and a `Valid` method, and the account struct has a `kind` field **at the end — at the end, because `ALTER TABLE` adds columns at the end, and sqlc follows the real column order.**

**译文**：`make generate` 跑 sqlc。**它也会读新的迁移**，所以生成的 model 现在有 `account_kind` 枚举类型、每个值一个常量、一个 `Valid` 方法，而 account 结构体的 `kind` 字段在**最后面——在最后面，因为 `ALTER TABLE` 把列加在最后，而 sqlc 遵循真实的列顺序。**

> `[3:11:03]` **Every `SELECT *` query picked up the new column, with no changes to the SQL.**
> **译文**：每个 SELECT * 查询都自动带上了新列，SQL 一行没改。

💡 这就是 EP3 里 `RETURNING *` / `SELECT *` 那个设计的回报：**加列不需要改任何查询**，因为 sqlc 在生成时展开星号。

---

## 7. `CreateAccount`：不做"先查再插"

> `[3:11:46]` ...in `CreateAccount`, **when PostgreSQL reports a unique violation, we return that error.** Notice **what's not here: a query that first checks whether the wallet exists.** Two requests could both see no wallet, and both insert. **The unique index is the only check that can't race, so we just try the insert, and translate the failure.**

**译文**：……在 `CreateAccount` 里，**当 PostgreSQL 报告唯一约束冲突时，我们返回那个错误**。注意**这里没有什么：一个先检查钱包是否存在的查询**。两个请求可能都看到"不存在"，然后都插入。**唯一索引是唯一不会竞争的检查，所以我们直接尝试插入，再翻译失败。**

```go
if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok && pgErr.Code == "23505" {
	return Account{}, fmt.Errorf("%w: ...", ErrAccountExists)
}
```

> `[3:12:32]` ...the comment **names it, because nobody remembers these numbers.**
> **译文**：……注释把它写了出来，因为没人记得这些数字。

💡 **这是"先查再插"（check-then-act）的通用解药**，和 EP6 的锁问题同源：**任何"读一下再决定"的检查都有 TOCTOU 窗口；能靠约束表达的，就靠约束。**

⚠️ 转录错误：`[3:12:18]` 的 "errors dot s type" 是 `errors.AsType`（Go 1.26 新增的泛型 `errors.As`）。

---

## 8. Service 层的六个决定

### ① 依赖具体 `*Store`，不要 interface

> `[3:14:15]` ...**notice the service depends on the concrete store, not on an interface. There's one store, and our tests will use the real one, so an interface here would be ceremony without a second implementation.**

**译文**：……注意 service 依赖**具体的 store，不是接口**。只有一个 store，而且我们的测试会用**真的那个**，所以这里的接口是**没有第二个实现的仪式**。

💡 "ceremony without a second implementation" —— 这是判断接口是否过早的**可操作标准**。EP4 里他说"interface 定义在消费处"，这里是同一句话在具体位置的落地。

### ② 不做隐式的大小写宽容

> `[3:15:02]` The currency must look like an ISO code — **three capital letters. We don't quietly uppercase it, because being lenient today means supporting lowercase codes forever.**

**译文**：币种必须像 ISO 码——**三个大写字母。我们不悄悄把它转成大写，因为今天宽容，意味着永远要支持小写码。**

💡 "being lenient today means supporting it forever" —— 这是**API 设计里的单向门**。所有"方便一下"的宽容，都是永久承诺。

### ③ 支持的币种 = 有 settlement 账户的币种

> `[3:15:29]` ...the right shape isn't enough though. `XYZ` is three capital letters, but we can't take deposits in it. **So which currencies do we support? Exactly the ones that have a settlement account. The list lives in one place — the database** — and **the code doesn't change when we add a currency.**

**译文**：……但形状对还不够。`XYZ` 是三个大写字母，但我们不能收它的存款。**所以我们支持哪些币种？恰好就是有 settlement 账户的那些。这份清单只存在一个地方——数据库**——而且**加一个币种时代码不用改**。

💡 注意这里的错误处理：查 settlement 账户用 `ErrAccountNotFound` 包上，**但要让客户端看到 422 而不是 404**（因为这是"币种不支持"，不是"钱包不存在"）。他后面会处理这个。

### ④ 系统账户对客户端不存在

> `[3:16:29]` ...an unknown account is `ErrWalletNotFound`. And **here's a subtle one: so is a system account.** Otherwise **anyone who learned the ID of our settlement account could read the total of every deposit we hold.** **To a client, system accounts simply don't exist.**

**译文**：……未知账户是 `ErrWalletNotFound`。**这里有个微妙的地方：系统账户也是。** 否则**任何知道我们 settlement 账户 ID 的人，都能读出我们持有的所有存款总额。** **对客户端来说，系统账户根本不存在。**

💡 这是一个**信息泄露防线**：`GET /v1/wallets/{settlement_id}` 不能返回"这是系统账户"，也不能返回 403（那等于承认它存在）。**必须返回和"不存在"一模一样的结果。**

> `[3:16:45]` Same status, same message, **so the API doesn't even confirm that the ID means something.**

### ⑤ 存款为什么要带币种

> `[3:18:01]` **Why does a deposit carry a currency at all, when the wallet already has one?** Because **the client should say what it means. If an app shows yen but posts to a dollar wallet, we want a clear error, not the wrong amount of money.**

**译文**：**钱包已经有币种了，为什么存款还要带币种？** 因为**客户端应该说出它的意图。如果一个 app 显示日元，却往一个美元钱包里存，我们要一个明确的错误，而不是一笔金额错误的钱。**

💡 这是**冗余但有意**的设计：重复的信息不是冗余，是**可校验的一致性声明**。和 EP2 的 `UNIQUE (id, currency)` 复合外键是同一个思路。

### ⑥ 两个错误一起报

> `[3:18:18]` ...and **we only return the validation error after both checks**, so **a client with two mistakes hears about both at once.**
> **译文**：……而且我们在两个检查都做完之后才返回校验错误，所以犯了两个错的客户端一次就听到两个。

---

## 9. 全集最精妙的一处：`%v` 还是 `%w`

> `[3:18:34]` ...next, the settlement account for the wallet's currency. **And look closely at this error**: the store returns `ErrAccountNotFound`, which **wraps** `apperr.ErrNotFound`. **If we wrapped it with `%w`, the client would get a 404 for a problem that's entirely ours.** **`%v` keeps the text but breaks the chain, so it becomes a 500, and it gets logged.**

> `[3:18:34]` ...next, the settlement account for the wallet's currency. **And look closely at this error**: the store returns `ErrAccountNotFound`, which **wraps** `apperr.ErrNotFound`. **If we wrapped it with `%w`, the client would get a 404 for a problem that's entirely ours.** **`%v` keeps the text but breaks the chain, so it becomes a 500, and it gets logged.**

**译文**：……然后是钱包币种对应的 settlement 账户。**仔细看这个错误**：store 返回 `ErrAccountNotFound`，它**包装了** `apperr.ErrNotFound`。**如果我们用 `%w` 包装它，客户端就会得到一个 404——而这个完全是我们自己的问题。** **`%v` 保留文本但切断链条，所以它变成 500，并被记录。**

> `[3:19:04]` **Wrapping is a decision about your API, not just about formatting.**

**译文**：**包装是一个关于你的 API 的决定，不只是关于格式化的。**

```go
// 错：客户端拿到 404，客户会以为"是我的钱包 ID 错了"
return fmt.Errorf("settlement account: %w", err)

// 对：客户端拿到 500 "internal error"，我们看到日志并修 bug
return fmt.Errorf("settlement account: %v", err)
```

💡 **这是全课程最反直觉的一行代码**，而且它推翻了"永远用 `%w`"这条流传很广的建议。

背后的逻辑链：

```
store 找不到 settlement 账户
  → 这是我们的部署/数据错误（迁移没跑、币种没播种）
  → 不是客户端的错
  → 不能返回 404（那是"你要的东西不存在"）
  → 必须返回 500（那是"我们坏了"）
  → 500 会触发日志和告警 → 我们才会修
```

**如果包了 `%w`：** 客户端得到 404，**永远不会有人报警**，然后**存款功能对所有该币种静默失效**。这个 bug 可以活几个月。

---

## 10. 分页：两个 bug 和一个技巧

### 10.1 OFFSET 的两个 bug

> `[3:20:02]` ...a busy wallet can have thousands, so we return them a page at a time. **The classic approach is limit and offset.** Page 500 is `OFFSET 10000`, so **Postgres reads 10,020 rows just to throw 10,000 of them away.** **The pages get slower and slower.**

> `[3:20:19]` **Worse, the pages move.** If a deposit arrives **while a client is paging**, every entry **shifts down by one**, and the client **sees an entry twice, or skips one entirely**. **In a statement of someone's money, both are bugs.**

**译文**：**更糟的是，页会移动。** 如果客户端翻页时来了**一笔存款**，所有分录**往下挪一位**，客户端就会**看到重复的一条，或整条跳过**。**在一个人的资金流水里，两者都是 bug。**

💡 第二个 bug 比第一个严重得多，而且**很难测出来**——你需要"翻页过程中有人写入"这个时序。

### 10.2 keyset：两个 bug 一起消失

> `[3:20:51]` **Instead of a position, the client sends the ID of the last entry it saw, and we ask for entries with a smaller ID.** With the index we just added on `(account_id, id)`, **Postgres jumps straight to that point, so page 500 is as fast as page 1.** And **new entries get bigger IDs, so they can't push anything around.**
> **译文**：客户端不发位置，而是发它看到的最后一条分录的 ID，然后我们要 ID 更小的那些分录。用我们刚在 (account_id, id) 上建的索引，Postgres 直接跳到那个点，所以第 500 页和第 1 页一样快。而且新分录拿到更大的 ID，所以它们不会把任何东西挤动。

|                | OFFSET         | keyset           |
| -------------- | -------------- | ---------------- |
| 第 500 页      | 读 10,020 行   | 索引直接跳到位置 |
| 翻页中有人写入 | **重复或跳过** | 不受影响         |
| 能否跳页       | 能             | **不能**         |

### 10.3 `limit + 1`：不用 COUNT 就知道有没有下一页

> `[3:21:21]` We also **fetch one row more than the page size. If it comes back, there's a next page, no count query needed**, and the client gets a cursor.
> **译文**：我们还多取一行。如果它回来了，就有下一页，不需要 count 查询，客户端拿到一个游标。

💡 `COUNT(*)` 在一个百万行的表上是**全表扫描**。而"多取一行"是 O(1) 的。

### 10.4 游标是不透明的，不是秘密

> `[3:21:35]` ...and the client gets a **cursor, not a raw ID. It's the ID in base64, so it looks opaque.** **It's not a secret — anyone can decode it. It's a signal: pass this back, don't build it yourself.** That leaves us free to **change what's inside**, say to a timestamp and an ID, **without breaking a single client.**

**译文**：……客户端拿到的是**游标，不是原始 ID。它是 base64 编码的 ID，所以看起来不透明。它不是秘密——谁都能解出来。它是一个信号：把这个传回来，不要自己构造。** 这样我们就**可以自由改变里面的内容**，比如改成"时间戳 + ID"，**而不会破坏任何一个客户端**。

💡 "It's not a secret" 这句很重要——**不要把它做成加密的**，那是过度的。它的作用是**封装**（封装变化），不是**安全**。

> `[3:22:05]` **The tradeoff is that you can't jump to page 50. For an activity feed, nobody needs to.**
> **译文**：代价是你不能跳到第 50 页。对一个动态流来说，没人需要。

### 10.5 一个隐藏的溢出风险

> `[3:22:55]` ...we ask for `limit + 1`, and **the conversion to int32 is safe, because we just checked that the limit is at most 100.**
> **译文**：……我们要 limit + 1，而到 int32 的转换是安全的，因为我们刚检查过 limit 最多 100。

💡 他在注释里写明了这个推理：**`limit ≤ 100` 已经校验过 → `limit+1 ≤ 101` → `int32` 转换不会溢出**。这类"为什么这里安全"的注释，比代码本身更有价值。

---

## 11. Handler 层

### 11.1 `HandlerFunc` 返回 error：把"三步式"压成一步

> `[3:23:59]` **Every handler follows the same rhythm**: call something that can fail, and if it fails, call `httpx.Error` and return. **Let's make that rhythm shorter.** `HandlerFunc` is like `net/http`'s own, **except that it returns an error**. Its `ServeHTTP` method calls the function **and sends any error it returns through `Error`**, so inside a handler **every failure is just `return err`** — and still gets the right status code and our JSON body.

> `[3:24:44]` The doc states **the one rule: only return an error before writing anything. Once the status line is sent, there's no taking it back.**

**译文**：文档写明了**唯一一条规则：只在写任何东西之前返回错误。状态行一旦发出去，就收不回来了。**

💡 这条规则和 EP4 的 `WriteJSON`"先 encode 再写"是同一个原理：**HTTP 的响应是单向的**。所有"可能失败的操作"必须发生在第一次 `Write` 之前。

### 11.2 为什么不直接返回 sqlc 的 model

> `[3:25:14]` ...starting with **the response types. Why not just return the sqlc models? They even have JSON tags.** But **they mirror the database. Expose the `kind`, the `normal_balance`, the internal `name`, and every schema change becomes an API change.** These structs are **our contract with clients, and they change only when we decide they should.**

**译文**：……从**响应类型**开始。**为什么不直接返回 sqlc 的 model？它们甚至有 JSON tag。** 但**它们镜像的是数据库。把 `kind`、`normal_balance`、内部 `name` 暴露出去，那么每一次 schema 变更都会变成一次 API 变更。** 这些结构体是**我们和客户端的契约，它们只在我们决定该变的时候才变。**

💡 这解答了 EP3 留下的一个疑问：**既然 `wallet.Account` 是 `walletdb.Account` 的别名，为什么 EP5 又要定义 `walletResponse`？**

答案：**别名在内部用，DTO 在边界用。** 两者不冲突，而且**正是因为内部用了别名（零成本），边界上才有余量去定义一份认真的契约**。

### 11.3 UUID 解析失败返回 404，不是 400

> `[3:26:43]` `walletID` reads the `{id}` with `PathValue`. **If it isn't a UUID, it can't name a wallet, so it's a 404 — exactly like an unknown one.** A 400 would be defensible too, but **this way clients have one case to handle: there's no wallet at this URL.**
> **译文**：walletID 用 PathValue 读 {id}。如果它不是 UUID，它就不可能命名一个钱包，所以是 404——和未知钱包完全一样。给 400 也说得过去，但这样客户端只需要处理一种情况：这个 URL 上没有钱包。

💡 和 EP4 `[2:47:16]` 的"错方法返回 404 而不是 405"是同一条原则：**减少客户端的分支数**。

### 11.4 `201 + Location`，并且返回资源本身

> `[3:27:34]` ...sets a `Location` header pointing at the new wallet, which is **the standard HTTP way to say where a created resource lives**, and writes a 201 **with the wallet itself, so the client doesn't need a second request to see it**.
> **译文**：……设一个指向新钱包的 Location 头，这是 HTTP 里表示「创建出来的资源住在哪里」的标准做法，并写 201，响应体里带钱包本身，这样客户端不用再发第二个请求去看它。

💡 两个都做：`Location` 是规范，返回 body 是**省一次往返**。很多 API 只做一个。

### 11.5 空数组不是 null

> `[3:29:19]` We build the response with `make` at the right length, **so an empty page is an empty JSON array, never `null`. Clients can always loop over `entries` without checking for `null` first.**
> **译文**：我们用 make 按正确长度构造响应，所以一个空页是一个空 JSON 数组，永远不会是 null。客户端可以总是对 entries 做循环，不用先检查 null。

💡 和 EP3 的 `emit_empty_slices` 是同一个决定在两层落地。

---

## 12. 测试：为什么不用假 store

> `[3:34:32]` We'll test the handlers with `httptest`, **through the real service and store, against the local Postgres.** **We could put an interface in front of the service and fake it, but then we'd mostly be testing the fake.** With the real database, **these tests cover the JSON, the validation, the error mapping, the SQL, and the constraints** — and they still run in **about a second**.

**译文**：我们用 `httptest` 测 handler，**穿过真的 service 和 store，打到本地 Postgres**。**我们可以在 service 前面放一个接口然后造假实现，但那样我们主要在测那个假货。** 用真数据库，**这些测试覆盖了 JSON、校验、错误映射、SQL 和约束**——而且它们仍然只跑**大约一秒**。

### 12.1 表驱动，但**不能并行**

> `[3:36:33]` **The comment matters: these rows depend on each other, so the subtests run in order, not in parallel.**
> **译文**：那条注释很重要：这些行互相依赖，所以子测试按顺序跑，不并行。

| #   | 请求                  | 期望 |
| --- | --------------------- | ---- |
| 1   | 新 owner + USD        | 201  |
| 2   | 同一 owner + 同一币种 | 409  |
| 3   | 同一 owner + 另一币种 | 201  |
| 4   | 小写 `usd`            | 422  |
| 5   | 不支持的币种          | 422  |
| 6   | owner 不是 UUID       | 422  |
| 7   | 未知字段              | 400  |

💡 第 2 行依赖第 1 行成功。所以 **table-driven 不等于 parallel**——这是两件可以分开决定的事，很多人把它们绑在一起。

### 12.2 那个"真正的重点"断言

> `[3:37:17]` ...each with its status. We check every status — **and then the real point: after all those requests, the balance must be exactly 2500. Rejected requests must never move money, not even a cent.**

**译文**：……每个都有期望状态。我们检查每一个状态——**然后是真正的重点：经过所有这些请求之后，余额必须恰好是 2500。被拒绝的请求绝不能动到钱，一分也不行。**

💡 这是一条**否定式不变量**：不是"成功的那笔对不对"，是"**所有失败的都没留下痕迹**"。这类断言比正向断言有价值得多，因为**它测的是原子性的边界**。

### 12.3 循环上限防挂死

> `[3:38:05]` **The loop stops after five pages no matter what, so a bug that hands out the same cursor forever fails the test instead of hanging it.**

**译文**：**循环无论如何五页之后停下，所以一个"永远返回同一个游标"的 bug 会让测试失败，而不是把它挂住。**

💡 一个分页测试如果不设上限，bug 的表现是**测试永远跑不完**（CI 超时 10 分钟，然后你去看别的地方）。**设上限 = 把 hang 变成 fail。**

---

## 13. 他明确留下的两个洞

> `[3:19:34]` Two things a deposit **can't do yet**: it **can't survive a retry** — if the network drops the response and the client tries again, **Alice is paid twice** — that's idempotency keys in episode 7. And **deposits only ever add money, so they can't overdraw anything** — moving money out of a wallet safely under concurrency is next episode.

**译文**：一笔存款**现在还做不到**两件事：它**扛不住重试**——如果网络丢了响应、客户端再试一次，**Alice 会被付两次**——那是第 7 集的幂等键。而且**存款只会加钱，所以它不会透支任何东西**——在并发下安全地把钱移出一个钱包，是下一集的事。

💡 注意这两个洞**都在 EP5 的"正确"里藏着**：

- 幂等洞 → 违反规则三
- 并发洞 → EP6 才补规则四

**EP5 看起来"完成了"，实际上两个致命缺陷都还开着。** 这就是为什么 EP6/EP7 不是"进阶内容"，是**补完 EP5**。

---

## 14. 我的补注

### ① `MaxAmount` 的真正约束来自浏览器

`100_000_000` 是 $1M。为什么不是 $10 亿（`1e11`）？因为 `2^53 ≈ 9×10^15`，$10 亿 = `1e11` 分，**其实也远低于 2^53**。所以他的 $1M 主要是**打错字的防护**，不是技术上限。

**真正的技术上限**：JSON 数字 → JS double，安全整数 `< 2^53`。**如果你以后做批量转账（多笔求和），要检查的是"和"，不只是单笔。**

### ② settlement 的余额是负债，不是资产

一个反直觉点：`settlement` 是 **debit-normal（借方增加）**，所以它的余额**是一个正数**。而这个正数代表**我们欠客户的钱**。

用 `account_balances` 视图看一眼就明白了：

```sql
SELECT name, kind, balance FROM account_balances
WHERE currency = 'USD' ORDER BY kind;
-- settlement | system | 4550   ← 我们持有
-- alice      | wallet | 4550   ← 我们欠她
```

**两行必须永远相等。** 这条等式就是 EP15 `books_test.go` 要检验的不变量之一。

### ③ 存款端点是印钞机

`POST /v1/wallets/{id}/deposits` 没有任何鉴权。**在 EP10 之前，这段代码绝不能暴露到公网。**

如果你要提前加固，最小的改动是在 handler 里检查一个内部 token：

```go
if r.Header.Get("X-Internal-Token") != cfg.InternalToken {
	return apperr.ErrNotFound   // 连 401 都不要给，用 404 隐藏端点存在
}
```

### ④ 游标 base64 不是加密

```go
base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(id, 10)))
```

**任何人 base64 解码就能拿到 entry 的 id。** 这没问题——但它意味着**别人可以伪造游标**。所以 `decodeCursor` 必须能容忍垃圾输入（它的确返回 422）。**如果你哪天把游标改成含权限信息，就必须加签名。**

---

## 15. 自测题

1. 为什么"充值"需要两条分录？没有 settlement 账户会发生什么？
2. 为什么 settlement 账户用迁移创建，而不是懒创建？给出他说的那个具体竞争。
3. 给一张大表加 `NOT NULL` 列为什么要三步？第三步"删默认值"为什么是关键？
4. 为什么唯一索引必须是 **partial** 的？用普通唯一索引会怎样？
5. `CreateAccount` 为什么不做"先查再插"？
6. `ErrAccountNotFound` 包装 `apperr.ErrNotFound`，为什么查 settlement 时要用 `%v` 而不是 `%w`？包了会有什么后果，多久会被发现？
7. 为什么 `GET /v1/wallets/{settlement_id}` 必须返回 404？
8. OFFSET 分页的两个 bug 分别是什么？keyset 为什么两个都解决了？
9. 为什么 handler 的响应类型不直接用 sqlc 的 model？（EP3 明明说别名是好事）
10. 存款测试最后那句"余额必须恰好 2500"在测什么？为什么它比"成功那笔对不对"更重要？
