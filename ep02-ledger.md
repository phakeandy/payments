# EP2 讲义：Designing a Double-Entry Ledger

- **视频** Go Microservices Full Course — `0:36:29 – 1:17:49`（41 分 29 秒）
- **分支** `ep02` ｜ **代码** `db/wallet/migrations/000001_init_ledger.up.sql`（118 行）
- **转录** whisper `small.en`（RTF 0.33，8 线程，13 分钟）｜全文见 `media/ep02.txt`
- 所有时间戳都是**视频的绝对时间**，可以直接拖进度条

用法：先看每节的「关键句」，卡住再回头听原声。带 💡 的是我的注解，不是他说的。

---

## 0. 本集的承诺

> **原文** `[0:36:45]` Today is one of the most important episodes in the whole series, because today we design the thing every other part of the system leans on: the ledger.
> **译文** 今天是整个系列最重要的几集之一，因为今天我们设计的是其它所有部分都倚赖的东西：账本。

> **原文** `[0:36:57]` …we'll have a Postgres schema for a real double-entry ledger, with rules so strict that the database itself refuses to store money that doesn't add up — and we'll prove it live by trying our best to break it.
> **译文** ……我们会做出一个真正的复式记账 Postgres schema，规则严到**数据库自己拒绝存储加不起来的钱**——而且我们会现场尽力去破坏它，证明这一点。

💡 注意他的措辞：不是"我写了一个账本"，是"我让**数据库**拒绝"。这句话是整个 41 分钟的主题。

---

## 1. 理论：复式记账（36:39 – 47:21）

### 1.1 钱只移动，不凭空生灭

> `[0:38:06]` Money never just appears and it never just disappears. It always moves from somewhere to somewhere. So every movement is recorded twice — once on the account it leaves, and once on the account it arrives in.

**译文**：钱不会凭空出现，也不会凭空消失，它永远是从某处移动到某处。所以每一次移动都要记两次——一次记在它离开的账户上，一次记在它到达的账户上。

> `[0:39:14]` In every single transaction, the total of the debits equals the total of the credits. That one invariant is incredibly powerful. If it ever breaks, you know instantly that something is wrong, and you know exactly which transaction caused it.

**译文**：每一笔交易里，借方合计必须等于贷方合计。这一条不变量极其强大——它一旦被打破，你立刻知道出事了，而且**精确知道是哪一笔交易**出的问题。

> `[0:39:31]` Accountants run this check and call it a trial balance. We're going to go one step further and make Postgres enforce it, so a broken transaction can never even be saved.

**译文**：会计会跑这个检查，叫它「试算平衡」。我们要更进一步，让 Postgres 强制执行它，让一笔不平的交易**根本存不进去**。

### 1.2 外部世界也要有账户

> `[0:39:46]` Money that enters our platform has to come from somewhere too, so we modeled the outside world with system accounts, like this bank account. … That means even money arriving from outside is fully accounted for.

**译文**：进入我们平台的钱也得有来源，所以我们用**系统账户**（比如这个银行账户）给外部世界建了模型。……这意味着即使是从外部进来的钱，也是完全可追溯的。

💡 这就是为什么后面 demo 里要建三个账户而不是两个：`bank`（资产）、`alice`、`bob`（负债）。**没有"外部世界"这个账户，充值这条分录就永远平不了。**

### 1.3 为什么不用 `transfers(from, to, amount)`

> `[0:40:11]` You might be wondering why not just a transfers table with a from account, a to account and an amount… real money movements aren't always one to one. A payment with a fee has three legs, a currency exchange touches four accounts — double-entry handles every one of those with the same two tables.

**译文**：你可能在想，为什么不用一张 `transfers(from, to, amount)` 的表……真实的资金流动不总是一对一的。带手续费的一笔支付有**三条腿**，一次货币兑换要碰**四个账户**——复式记账用同样的两张表就能处理全部这些情况。

💡 "currency exchange touches four accounts" 就是 EP18 的 four-entry posting，这里已经埋好了伏笔。

### 1.4 借贷不是加减（全片最容易搞错的一段）

> `[0:40:49]` Debit and credit don't mean minus and plus. Every account has a normal side.

**译文**：借和贷**不是**减和加的意思。每一个账户都有一个「正常方向」（normal side）。

> `[0:40:58]` Our bank account is an asset, it's money we actually hold, and assets grow with debits. … Its balance is its debits minus its credits.

**译文**：我们的银行账户是**资产**，是我们真正持有的钱，而资产随借方增长。……它的余额 = 借方 − 贷方。

> `[0:41:15]` The money in Alice's wallet isn't ours, it's hers, and we owe it to her. It makes it a liability, and liabilities grow with credits. So her balance is her credits minus her debits. 5,000 in, 2,000 out, 3,000 left.

**译文**：Alice 钱包里的钱不是我们的，是她的，我们欠她。所以它是**负债**，而负债随贷方增长。所以她的余额 = 贷方 − 借方。进来 5,000，出去 2,000，剩 3,000。

> `[0:41:33]` So to compute any balance, we need two things: the entries, and the account's normal side. That's why we'll store the normal side on every account.

**译文**：所以要算任何余额，我们需要两样东西：**分录**，和这个账户的**正常方向**。这就是为什么我们要在每个账户上存 normal side。

💡 这一段是本集的理论核心。会计恒等式是：
```
资产 + 费用 = 负债 + 权益 + 收入
   （借方侧）        （贷方侧）
```
资产/费用 → 正常在借；负债/权益/收入 → 正常在贷。用户钱包是负债（我们欠用户钱），所以 `normal_balance = credit`。

### 1.5 为什么余额不能存成一列（四条失败）

> `[0:42:05]` Two requests updating the same row at the same time can overwrite each other, and you silently lose an update.

**译文**：两个请求同时更新同一行，会互相覆盖，你**悄无声息地丢掉一次更新**。

> `[0:42:13]` And even when it works, you've thrown away the history. When a customer asks why their balance is $42, all you have is the number 42.

**译文**：就算它工作正常，你也把历史扔掉了。当客户问"我的余额为什么是 42 美元"，你手上只有一个数字 42。

> `[0:42:23]` If a bug writes a wrong number, that number simply becomes the new truth, and there's nothing to reconcile it against.

**译文**：如果某个 bug 写进一个错的数字，这个数字就**变成了新的真相**，你没有任何东西可以用来对账。

> `[0:43:01]` The trade-off is that summing entries costs more than reading one column. For now, an index on the account makes that cheap, and when an account has millions of entries, you can add cached balances or periodic snapshots. The key is that any cache is derived from the entries, so you can throw it away and rebuild it at any time.

**译文**：代价是求和比读一列更贵。眼下账户上的索引让它很便宜；当一个账户有几百万条分录时，你可以加缓存余额或定期快照。关键是**任何缓存都是从分录推导出来的**，所以你可以随时扔掉重建。

> `[0:43:28]` If you've heard of event sourcing, this should sound familiar. A ledger is basically event sourcing for money… Accountants just figured it out about 500 years before we gave it a name.

**译文**：如果你听过 event sourcing（事件溯源），这听起来应该很熟。账本本质上就是**钱的事件溯源**……会计只是在我们给它起名字的 500 年前就想明白了。

### 1.6 金额：整数分，永远不是浮点

> `[0:44:33]` Floats are binary approximations, and in a payment system those tiny errors add up into real money that nobody can account for.

**译文**：浮点是二进制近似值，在支付系统里那些微小的误差会累积成**没人能对得上的真钱**。

> `[0:44:47]` So we store money as an integer number of minor units — which for dollars means cents. $19.99 becomes the integer 1999.

**译文**：所以我们把钱存成**最小货币单位的整数**——对美元来说就是分。19.99 美元变成整数 1999。

> `[0:45:02]` A signed 64-bit integer goes up to about 9 quintillion cents. That's around 92 quadrillion dollars, so I think we'll be fine.

**译文**：有符号 64 位整数能到约 9 百亿亿分，大约 92 千万亿美元，我想我们够用了。

> `[0:45:11]` One catch: not every currency has two decimal places. The Japanese yen has none, so 500 yen is stored as 500. The Kuwaiti dinar has three.

**译文**：有个坑：不是每种货币都是两位小数。日元没有小数位，所以 500 日元就存 500。科威特第纳尔有三位。

> `[0:45:52]` Say we split a $10 bill three ways, that's 1,000 cents divided by 3, which is 333, with 1 cent left over. With floats that cent quietly disappears; with integers it's sitting right there, and your code has to decide explicitly who gets it.

**译文**：假设把 10 美元三等分，1000 分除以 3 = 333，余 1 分。用浮点，这 1 分悄悄消失；用整数，它就明晃晃地躺在那儿，**你的代码必须明确决定给谁**。

💡 这段是 EP18 汇率取整的伏笔（`Down` 给付出，`Up` 给收取）。

### 1.7 规则清单，以及为什么放在数据库

> `[0:46:47]` Amounts must be positive, because the direction already says which way the money moves. Currency codes must look like real ISO codes. And an entry's currency must match its account's currency. Every transaction must balance, and the ledger can only ever be appended to.

**译文**：金额必须是正数，因为方向已经说明了钱往哪走。币种代码必须像真正的 ISO 代码。分录的币种必须和它账户的币种一致。每笔交易必须平衡，账本只能追加。

> `[0:47:10]` Application code has bugs, and some day someone will run a manual fix in production. The database is the last line of defense, so that's where the guarantees go.

**译文**：应用代码有 bug，而且总有一天有人会在生产环境手动改数据。**数据库是最后一道防线**，所以保证要放在那里。

---

## 2. 一服务一库（47:23 – 50:10）

> `[0:47:26]` Every service owns its data. The wallet service is the only one that ever touches the wallet database… Locally they share one PostgreSQL server to keep things light, but they never share tables. That's what lets us change one service's schema without breaking another.

**译文**：每个服务拥有自己的数据。wallet 服务是唯一会碰 wallet 数据库的……本地为了轻量共用一个 PostgreSQL 实例，但**它们从不共享表**。这才让我们能改一个服务的 schema 而不弄坏另一个。

> `[0:47:54]` Any SQL or shell script we mount into a folder called `docker-entrypoint-initdb.d` runs when the database is first created.

**译文**：挂在 `docker-entrypoint-initdb.d` 里的任何 SQL 或 shell 脚本，都会在数据库**首次创建**时执行。

> `[0:49:04]` And here's a gotcha that catches everyone: init scripts only run when the data directory is empty. Our Postgres volume already exists from the last episode, so if we simply restart the container, nothing happens.

**译文**：这里有个坑，人人都中过：初始化脚本只在**数据目录为空**时运行。我们的 Postgres 数据卷在上一集已经存在了，所以简单重启容器什么也不会发生。

💡 我上一条消息里提过这个坑。你会踩它的概率接近 100%，记住 `docker compose down -v`。

> `[0:54:13]` And notice there's no foreign key here. The user's table lives in a different database, and that's one of the trade-offs of database per service.

**译文**：注意这里**没有外键**。用户表活在另一个数据库里，这是「一服务一库」的代价之一。

💡 这是全片唯一一处"约束做不到"的地方——跨库约束必須靠应用层或对账来兜。这个洞到 EP20 的对账才被补上。

---

## 3. 迁移工具（50:10 – 53:02）

> `[0:50:20]` You never want to change a production database by hand. Instead, every change is a migration — a numbered SQL file that's reviewed and committed like any other code, and applied in order, the same way on your laptop, in CI, and in production.

**译文**：你永远不该手动改生产库。每个变更都是一次迁移——一个编号的 SQL 文件，像普通代码一样被 review 和提交，按顺序执行，在你的笔记本上、在 CI 里、在生产里，**方式完全相同**。

> `[0:50:50]` Some apps run their migrations automatically on startup. It's convenient, but picture five replicas starting at the same time, racing to migrate the same database, while a slow migration keeps your app from starting at all. We'll keep migrations as a separate explicit step… That keeps deploys boring, and boring is exactly what you want.

**译文**：有些应用在启动时自动跑迁移。方便，但想象五个副本同时启动、抢着迁移同一个库，而一个慢迁移让应用根本起不来。我们把迁移保持为一个**独立的显式步骤**……这让部署变得无聊，而无聊正是你要的。

> `[0:52:37]` Sequential numbers are easy to read, but if two people both create migration number two on different branches, they'll collide. … On a small team, sequential numbers are a great default, and the collision is actually useful, because it forces you to look at both changes together.

**译文**：顺序编号好读，但如果两个人在不同分支上都建了 2 号迁移，它们会撞车。……小团队里顺序编号是很好的默认，而且撞车其实**有用**，因为它强迫你把两个变更放在一起看。

---

## 4. 逐段读 up 迁移（53:02 – 1:03:14）

### 4.1 整个文件包在事务里

> `[0:53:07]` Postgres has transactional DDL, which means even `CREATE TABLE` can be rolled back, so if any statement in this file fails, nothing at all is applied, and we never end up with a half-migrated database.

**译文**：Postgres 支持**事务性 DDL**，连 `CREATE TABLE` 都能回滚，所以这个文件里任何一条语句失败，就一条都不会生效，我们永远不会得到半个迁移完的数据库。

### 4.2 enum 的取舍

> `[0:53:42]` Enums do have a trade-off: adding a value is easy, but removing one is painful. For debit and credit, which will never change, an enum is perfect.

**译文**：枚举有代价：加值容易，删值很痛。对借和贷这种永远不会变的东西，枚举完美。

💡 对比 EP19 的 transfer `state` 用 text 而不是 enum——因为状态机未来可能加状态。**这是同一个作者在不同场景下的相反选择，值得记住。**

### 4.3 `UNIQUE (id, currency)` 的用途

> `[0:54:58]` The ID is already unique on its own, so why make the pair of ID and currency unique too? It's so that entries can reference both columns together, and you'll see why in a minute.

**译文**：ID 本身已经唯一了，为什么还要把 (ID, currency) 这对做成唯一？是为了让 entries 能同时引用这两列，等一下你就明白为什么了。

### 4.4 时间戳必须带时区

> `[0:54:43]` Always use `timestamp with time zone` in Postgres. Plain timestamp throws the time zone away, and that bites you the moment two servers disagree about local time.

**译文**：Postgres 里永远用 `timestamptz`。不带时区的 timestamp 把时区扔掉了，两台服务器对本地时间的看法不一致的那一刻，你就会疼。

### 4.5 币种正则 vs 币种表

> `[0:55:20]` A regular expression accepts any three capital letters, even codes that don't exist. The stricter option is a currencies table with a foreign key to it. That's a great idea once you support a fixed list of currencies, and it's an easy migration to add later.

**译文**：正则接受任意三个大写字母，包括不存在的代码。更严的做法是一张 currencies 表加外键。等你支持固定币种清单时这是个好主意，而且以后很容易加一次迁移。

### 4.6 金额正数 + 方向（拒绝"两种写法"）

> `[0:57:21]` We could store signed amounts with debits as negative numbers, but then there are two ways to say the same thing, and the sign bug silently flips the money around. With a positive amount plus a direction, there's exactly one way to record each line, and a negative amount is always a bug.

**译文**：我们本可以存带符号的金额、用负数表示借方，但那样**同一件事有两种说法**，一个符号 bug 就会悄悄把钱翻过来。用正数金额加方向，每一行的记录方式**只有一种**，负数永远是 bug。

💡 这就是「让非法状态无法表达」。和前面"余额不存成列"是同一个思路的两个应用。

### 4.7 复合外键：欧元分录不可能落在美元钱包上

> `[0:57:52]` So an entry can't just point at any account, it has to point at an account **with the same currency**. A euro entry on a dollar wallet is now impossible, and that's the kind of bug that would be really nasty to track down later.

**译文**：所以一条分录不能随便指向任何账户，它必须指向**币种相同**的账户。欧元分录落在美元钱包上现在是不可能的，而那种 bug 在以后真的非常难查。

### 4.8 索引：主键和唯一约束自动有，外键没有

> `[0:58:08]` This is a really common mistake: PostgreSQL automatically indexes primary keys and unique constraints, but **not foreign keys**. Without these two indexes, loading a transaction's entries or summing up an account's balance would scan the whole entries table.

**译文**：这是个非常常见的错误：PostgreSQL 会自动给主键和唯一约束建索引，但**不会给外键建**。没有这两个索引，加载一笔交易的分录、或者汇总一个账户的余额，都要全表扫 entries。

### 4.9 为什么必须 DEFERRED（本集技术核心）

> `[0:58:34]` A check constraint can't do this, because a check only ever sees one row, and this rule is about all the entries of a transaction together.

**译文**：CHECK 约束做不到这件事，因为 CHECK 只能看见一行，而这条规则是关于一笔交易的**所有分录**的。

> `[0:58:43]` There's a timing problem too: we insert the entries one at a time, so right after the first insert, the transaction is unbalanced — and that's completely fine. What we care about is that it balances **by the time we commit**.

**译文**：还有个时序问题：我们是一条一条插入分录的，所以刚插完第一条时，这笔交易是不平的——这完全没问题。我们关心的是它**在 COMMIT 时**是平的。

> `[0:58:58]` That's exactly what a deferred constraint trigger is for: it's a trigger that PostgreSQL can postpone until commit.

**译文**：这正是 deferred constraint trigger 的用途：一种 Postgres 可以**推迟到 COMMIT** 才执行的触发器。

> `[0:59:19]` The same function is used by two triggers, one on transactions and one on entries. So first we work out which transaction we're checking, based on the table that fired it.

**译文**：同一个函数被两个触发器使用，一个在 transactions 上，一个在 entries 上。所以我们先根据是哪个表触发，算出要检查哪笔交易。

> `[0:59:34]` A journal row with nothing in it means something went wrong halfway through… we raise an error with the standard check violation error code. That code matters, because later our Go code can recognize it and turn it into a clean error for the client instead of a generic failure.

**译文**：一条空的分录头意味着中途出错了……我们抛出一个标准 check violation 错误码。**这个错误码很重要**，因为以后我们的 Go 代码能识别它，把它转成给客户的干净错误，而不是通用失败。

💡 那个码就是 **`23514`**（`check_violation`）。EP4 的 `apperr` 包和 EP5 的 handler 会用到它。

> `[1:00:12]` Grouping by currency matters, because $100 of debits and €100 of credits are definitely not balanced. And because `sum()` over bigint returns numeric in PostgreSQL, this can't overflow.

**译文**：按币种分组很重要，因为 100 美元借方和 100 欧元贷方**绝对不平**。而且因为 PostgreSQL 里对 bigint 求和返回 numeric，这里不会溢出。

> `[1:00:46]` One trigger fires when a transaction is inserted, which catches a journal row with no entries. The other fires for every entry, which catches entries sneaking into an existing transaction later.

**译文**：一个触发器在插入交易时触发，抓住没有分录的空头；另一个对每条分录触发，抓住**事后往已有交易里偷偷塞分录**。

> `[1:01:00]` And if you ever want the check to run earlier — say, in the middle of a test — `SET CONSTRAINTS ... IMMEDIATE` runs it on the spot.

**译文**：如果你想让检查提前跑——比如在测试中间——`SET CONSTRAINTS ... IMMEDIATE` 会当场执行它。

图灵完备的一条命令，测试里非常好用：
```sql
SET CONSTRAINTS ALL IMMEDIATE;   -- 立刻检查，用于断言"这里应该已经不平了"
```

### 4.10 他自己承认的代价

> `[1:01:11]` The check runs once per inserted row, so a transaction with four entries gets checked four times at commit. Payments have two to four lines and thanks to our index each check is a quick lookup, so the cost is tiny.

**译文**：检查是**每插入一行跑一次**，所以一笔有四条分录的交易在 COMMIT 时会被检查四次。支付只有两到四行，而且靠索引每次检查都是一次快速查找，所以代价很小。

### 4.11 append-only 的边界（诚实的一段）

> `[1:02:15]` One thing to be aware of: **row triggers don't fire on TRUNCATE**, and an admin can always drop a trigger. So this protects us from application bugs and careless manual fixes. In production, you also lock down database permissions.

**译文**：要注意：**行触发器不会在 TRUNCATE 时触发**，而且管理员总能删掉触发器。所以这保护我们免受应用 bug 和粗心的手动修改。生产环境里你还要收紧数据库权限。

💡 这段话很有价值——他没有吹"这绝对安全"，而是划出了边界。补两个解法：
```sql
-- ① TRUNCATE 也能拦（语句级触发器，不是行级）
CREATE TRIGGER entries_no_truncate BEFORE TRUNCATE ON entries
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_ledger_changes();
-- ② 权限层面直接堵
REVOKE TRUNCATE, UPDATE, DELETE ON entries, transactions FROM wallet_app;
```
② 就是 EP21 的 least-privilege 数据库角色。

### 4.12 视图

> `[1:02:54]` The LEFT JOIN together with coalesce means an account with no entries yet shows a balance of zero instead of disappearing from the results. And the cast back to bigint keeps it an int64 for Go.

**译文**：`LEFT JOIN` 配 `coalesce` 意味着还没有任何分录的账户显示余额 0，而不是从结果里消失。转回 `bigint` 让它对 Go 来说是 int64。

> `[1:03:49]` Every one of those is a bug we'll never have to debug in production.

**译文**：上面每一条，都是一个我们**永远不必在生产环境调试**的 bug。

---

## 5. down 迁移与两条迁移纪律（1:03:54 – 1:05:12）

> `[1:04:00]` The view goes first because it depends on the tables, then entries before transactions and accounts, because entries reference both of them, then the functions and finally the enum type.

**译文**：视图先删，因为它依赖表；然后 entries 在 transactions 和 accounts 之前，因为 entries 引用它们两个；然后是函数，最后是枚举类型。

> `[1:04:30]` Always write the down migration in the same commit as the up migration, **and actually run it**. A down migration that has never been tested is a down migration that doesn't work, and you'll find that out at the worst possible moment.

**译文**：down 迁移永远和 up 写在同一个 commit 里，**并且真的跑一遍**。一个从没测过的 down 迁移，就是一个不管用的 down 迁移，而你会在最糟的时刻发现这一点。

> `[1:04:50]` Once a migration has been applied anywhere outside your laptop, **never edit it again**. Migrate records only the version number, so it will never notice that the file changed, and your databases quietly drift apart. If you need a change, write a new migration. **Migrations are history, just like our ledger.**

**译文**：一个迁移只要在你笔记本之外的地方跑过，**就永远别再改它**。Migrate 只记版本号，它永远不会发现文件变了，于是你的数据库悄悄漂移。要改就写新迁移。**迁移就是历史，和我们的账本一样。**

💡 全片最好的一句类比：**迁移文件 = append-only**。同一个纪律在两层出现，说明它是原则不是技巧。

---

## 6. 应用迁移、看结果（1:05:12 – 1:06:23）

> `[1:05:43]` While it runs, Migrate holds a Postgres **advisory lock**, so if two deploys try to migrate the same database at the same moment, one of them simply waits for the other.

**译文**：执行期间 Migrate 持有一个 **advisory lock**，所以两个部署同时迁移同一个库时，其中一个会等另一个。

> `[1:06:03]` `dirty` means a migration failed halfway through, and Migrate will refuse to run anything else until a human looks at the database, fixes it, and resets the version with the `force` command. Thanks to our `BEGIN`/`COMMIT`, a failing migration rolls back cleanly, so we should rarely see that.

**译文**：`dirty` 表示某个迁移中途失败了，Migrate 会拒绝再跑任何东西，直到有人类看一眼数据库、修好它、用 `force` 命令重置版本。多亏了我们的 `BEGIN`/`COMMIT`，失败的迁移会干净回滚，所以我们应该很少见到这种情况。

💡 这两条合起来说明一件事：**`BEGIN`/`COMMIT` 包住整个迁移文件，不只是好习惯，它把 `dirty` 状态从"常见"降级成"罕见"**。

---

## 7. Makefile（1:06:23 – 1:08:38）

> `[1:07:07]` They're marked `.PHONY` because they don't produce files with those names.

> `[1:07:14]` `migrate-down` rolls back **exactly one** migration, and I'm passing the `1` on purpose. Without a number, Migrate offers to roll back **everything**, and that's not a habit you want.

**译文**：`migrate-down` 回滚**恰好一个**迁移，那个 `1` 是故意的。不写数字的话 Migrate 会问你要不要回滚**全部**，那不是你想要养成的习惯。

> `[1:07:29]` The `@` sign in front of each recipe tells make not to echo the command, which keeps our terminal clean and keeps a long database URL out of the output.

**译文**：每条命令前面的 `@` 让 make 不回显命令，既保持终端干净，也避免把一长串数据库 URL 打到输出里。

> `[1:07:42]` Recipe lines must be indented with a **real tab**, not spaces.

**译文**：recipe 行必须用**真 tab** 缩进，不能用空格。

> `[1:08:33]` We're at version one again — up, down, and up again. When that round trip works, we can trust our migration.

**译文**：我们又回到版本 1 了——up、down、再 up。**当这个往返能跑通，我们才能信任这个迁移。**

💡 这是可以立刻抄走的习惯：**每个迁移都要 up → down → up 走一遍**，才允许提交。

---

## 8. 现场破坏（1:08:42 – 1:15:48）← 全片精华

### 8.1 先确认约束真的存在

```sql
\set VERBOSITY terse
```
> `[1:09:00]` That's a psql setting that keeps each error to a single line.

他用一条系统目录查询列出 `entries` 表上所有约束，然后：
> `[1:09:34]` And notice that `entries_balanced` has type `T`. Our constraint trigger really **is** a constraint, as far as Postgres is concerned.

**译文**：注意 `entries_balanced` 的类型是 `T`。在 Postgres 眼里，我们的约束触发器**真的就是一个约束**。

💡 可以自己重放：
```sql
SELECT conname, contype FROM pg_constraint
WHERE conrelid = 'entries'::regclass;
```

### 8.2 建三个账户，跑真实数据

```sql
INSERT INTO accounts (name, currency, normal_balance) VALUES
  ('bank',  'USD', 'debit'),    -- 资产
  ('alice', 'USD', 'credit'),   -- 负债（我们欠她）
  ('bob',   'USD', 'credit')
RETURNING id \gset
```
> `[1:10:00]` `RETURNING id` followed by `\gset` stores each new id in a psql variable, so we can use it in the statements that follow.

> `[1:10:37]` `:'x'` inserts the variable as a **properly quoted** value.

**译文**：`:'x'` 会把变量作为**正确加引号**的值插入。

（psql 变量三件套：`\gset` 存、`:'x'` 安全引用字符串、`:x` 直接展开——后者有 SQL 注入风险，演示里用前者是对的。）

### 8.3 关键瞬间：没有存过一个余额

> `[1:11:27]` We never stored a single balance. Every number here was computed from the entries.

**译文**：我们**一分钱余额都没存过**。这里的每个数字都是从分录算出来的。

> `[1:11:34]` And the books check out. The $50 our users hold in their wallets is exactly the $50 sitting in our bank.

**译文**：账对上了。用户钱包里持有的 50 美元，正是我们银行里躺着的 50 美元。

（余额：alice 3000、bank 5000、bob 2000。）

> `[1:11:41]` And here's a trial balance across the entire ledger — every entry from every run. Total debits, total credits, and they're identical. They always will be, because Postgres won't let them be anything else.

**译文**：这是整个账本的试算平衡——每一次运行产生的每一条分录。借方合计、贷方合计，完全相等。**它们永远会相等，因为 Postgres 不允许它们不相等。**

> `[1:11:58]` In a real system, you'd run a check like this on a schedule and page someone if it ever fails.

**译文**：在真实系统里，你会定时跑这样的检查，一旦失败就**呼叫值班**。

💡 这就是 EP20 的 `reconcile.go`，提前 18 集埋好了。

### 8.4 破坏一：把钱改小 5 块

> `[1:12:10]` So Alice is debited $20, but Bob only receives $15. And $5 just vanishes. This is exactly the kind of bug that happens in real systems with a rounding error or a fee that gets subtracted twice.

**译文**：Alice 借出 20，但 Bob 只收到 15。**5 美元就那么消失了**。真实系统里就是这种 bug——舍入误差，或者手续费被减了两次。

> `[1:12:36]` **Each insert succeeded on its own**, but at commit, our deferred trigger added everything up and the whole transaction was rolled back. … Not a single cent moved. That's atomicity and our invariant working together.

**译文**：**每一次插入单独都成功了**，但 COMMIT 时我们的延迟触发器把一切加起来，整个事务被回滚。……一分钱都没动。这就是**原子性和不变量协同工作**。

💡 这句话是理解 `DEFERRABLE` 的唯一入口。普通触发器会拦在第 1 条，你就学不到"检查发生在 COMMIT"这件事。

### 8.5 破坏二：五种坏数据全被拒

> `[1:13:34]` A transaction with no entries at all. Then an entry with a negative amount. And then a euro entry on Alice's dollar wallet. Then a new account with a lowercase currency code. And finally, the classic manual fix in production: we update Alice's entries to give her a lot more money… and we delete the deposit transaction entirely.

**译文**：一笔完全没有任何分录的交易。然后一条金额为负的分录。然后一条欧元分录落在 Alice 的美元钱包上。然后一个新账户用了小写币种代码。最后是生产环境最经典的"手动修复"：我们更新 Alice 的分录给她塞一大笔钱……然后把充值交易整个删掉。

> `[1:14:27]` **Every single one is rejected.**
> **译文**：每一个都被拒绝了。
> - 空交易 → COMMIT 时 `has no entries`（transactions 表上的延迟触发器）
> - 负数金额 → **立刻**被 CHECK 拦下，行根本没写进去
> - 欧元分录 → 复合外键拒绝（"没有任何账户的 id 是她的 id 且币种是欧元"）
> - 小写币种 → accounts 上的正则 CHECK 拒绝
> - UPDATE / DELETE → append-only 触发器，附带"该怎么做"的提示

> `[1:15:06]` Notice the arrow names the table, which makes it obvious what was blocked when you see it in a log.

**译文**：注意错误信息里那个箭头指明了表名，这样你在日志里看到时能一眼看出被拦的是什么。

### 8.6 收尾金句

> `[1:15:20]` None of these rules depends on our Go code being correct. Whatever happens later — a bug in a handler, a bad deploy, or a tired engineer with a psql console at two in the morning — the database will refuse to store money that doesn't add up.

**译文**：这些规则**没有一条依赖我们的 Go 代码是对的**。不管以后发生什么——handler 里的 bug、一次糟糕的部署，还是一个凌晨两点、疲惫的工程师打开了 psql 控制台——数据库都会拒绝存储加不起来的钱。

> `[1:15:41]` **Validation in the app is for good error messages. Constraints in the database are for guarantees.**

**译文**：**应用层的校验是为了给出好的错误信息；数据库的约束是为了保证。**

💡 全片最好的一句。记住它，你就能回答"为什么两层都要校验"。

---

## 9. 他的 recap（1:16:29 – 1:17:51）

> `[1:17:17]` Our wallet ledger has constraints that make bad data impossible: positive amounts, matching currencies, balanced transactions, and an append-only history — all enforced by Postgres itself.

**译文**：我们的钱包账本有让坏数据**不可能存在**的约束：正数金额、币种匹配、交易平衡、只追加的历史——全部由 Postgres 自己执行。

下一集预告：`1:17:36` 用 sqlc + pgx 连上这个 schema，写第一批集成测试。

---

## 10. 我核对转录时修正的错词

whisper 已经很好，但技术词和专有名词仍会错。你对照视频时注意这几处：

| 转录里 | 实际 |
|---|---|
| "Rotes are binary approximations" | **Floats** are binary approximations |
| "the Kuwaiti dinner has three" | the Kuwaiti **dinar** |
| "the off service" | the **auth** service |
| "the order serial type" | the **old `serial`** type |
| "As signed 64-bit integer" | **A** signed 64-bit integer |
| "backslash set verbose details" | `\set VERBOSITY terse` |
| "Datskolang migrates on bookkeeping" | `\d schema_migrations`（看它的记账表） |
| "Call on quote, the x quote" | `:'x'` |
| "dash5 does" / "dash dash wait" | `docker compose down -v` / `--wait` |
| "a secure console" | a **psql** console |
| "the same two tables" | （正确） |

---

## 11. 他没讲、但你应该知道的四件事

1. **`account_balances` 视图是全账户聚合**。查单个钱包时能不能只算一个，取决于 Planner 会不会把条件下推——别猜，`EXPLAIN ANALYZE`。这是 EP22 的主题（`17:47:21`）。
2. **每行跑一次检查是 `DEFERRABLE` 的代价格**。语句级触发器能只跑一次，但**语句级触发器不能延迟**（SQL 标准限制）。所以"只在 COMMIT 检查一次"和"每行检查"这两件事，Postgres 里你必须选一个——他选了正确性，代价可忽略。
3. **TRUNCATE 的洞可以补**：加一个 `BEFORE TRUNCATE ... FOR EACH STATEMENT` 触发器，或者直接 `REVOKE TRUNCATE`。
4. **跨库没有外键**（`accounts.owner_id` 指向 auth 库里不存在的表）。这是这套架构唯一"数据库管不到"的地方，靠 EP20 的对账兜底。

---

## 12. 三题自测（答不上来就回去看对应时间戳）

1. `[0:41:15]` 用户钱包是**负债**，为什么？它随哪一侧增长？
2. `[0:58:58]` 如果去掉 `DEFERRABLE INITIALLY DEFERRED`，插入一笔两条分录的交易会发生什么？错误会在什么时候报出？
3. `[1:15:41]` 既然数据库已经保证了一切，为什么 Go 代码还要校验？反过来，既然 Go 已经校验了，为什么还要数据库约束？
