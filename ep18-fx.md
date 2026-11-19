# EP18 讲义：多币种与 FX —— 「乘以一个汇率」里藏着六个 bug

- **视频** `13:53:37 – 14:45:43`（52 分）｜分支 `ep18` ｜ diff：`+1167 / -18`（24 个文件）
- **转录** `media/ep18.txt`（185 句，5,950 词）
- 时间戳是视频绝对时间

一句话：**汇率不是数字，是一个精确的十进制小数的编码；换算不是乘法，是一次有方向的舍入。**

> `[13:54:36]` **Converting money sounds like one multiplication** — $100 times the rate is so many euros. **In a payment system, almost every word of that sentence hides a bug.**

> **译文**：**换钱听起来就是一次乘法**——\$100 乘以汇率就是多少欧元。**在一个支付系统里，那句话几乎每个词背后都藏着一个 bug。**

💡 这句话是本集的**目录**。把它拆开：

| 句子里的词 | 藏着的 bug |
|---|---|
| **money** | 最小单位不是处处 100（日元 0 位，科威特第纳尔 3 位） |
| **multiplying** | `float64` 存不下 0.9215；`int64` 相乘会**静默溢出** |
| **rate** | 汇率每秒钟在变 → 你需要一个**报价**（quote） |
| **is** | 结果很少落在整分上 → **舍入方向是一个商业决定** |
| **so many euros** | 复式记账要求**每种货币各自平衡** → 两笔分录不够，要四笔 |

---

## 0. 最小单位不是处处 100

> `[13:54:52]` we've stored money as **integer minor units since episode 5**, but **minor units aren't the same everywhere**. **A dollar has a hundred cents, the yen has no minor unit at all**, and **the Kuwaiti dinar has a thousand fils**, so **every currency needs its exponent from the ISO 4217 standard**.

> **译文**：我们从第 5 集起就把钱存成**整数最小单位**，但**最小单位到处都一样**——不。**美元有一百分，日元根本没有最小单位**，而**科威特第纳尔有一千费尔**，所以**每种货币都需要从 ISO 4217 标准里拿到它的指数**。

```go
// internal/fx/convert.go
var exponents = map[string]int{
	"EUR": 2,
	"GBP": 2,
	"JPY": 0,
	"KWD": 3,
	"USD": 2,
}
```

> `[13:56:19]` **the yen has zero: 100 yen is the integer 100**, and **if an app ever shows 100.00 yen, someone's going to file a bug report**.

> **译文**：**日元的指数是 0：100 日元就是整数 100**，而**如果一个 app 曾经显示 100.00 日元，就会有人提 bug 报告**。

💡 EP05 的 `money()` 里有一个 `if currency == "JPY"` 的特例。**这一集把它变成了表。**

这就是"**先一行 if，等第二个特例出现再建表**"的兑现时刻：

```go
// EP13 的写法（能跑，但是硬编码）
func money(amount int64, currency string) string {
	if currency == "JPY" { ... }
	return fmt.Sprintf("%d.%02d %s", ...)
}
```

而如果当时就建表，会遇到一个问题：**只有两个例子（USD=2, JPY=0）的时候，你不知道第三个数是 3 还是别的**。现在有了 KWD=3，表才**真的比 if 有信息量**。

> `[13:56:38]` **This table is data, and it does change — rarely. Currencies are born, retired, or re-denominated. When that happens, it's a reviewed code change, with tests, not something a customer discovers.**

> **译文**：**这张表是数据，而它确实会变——很少见。货币会诞生、退役、或者重新定值。当那发生时，它是一次被 review 过的代码改动，带测试，而不是客户发现的东西。**

💡 "**re-denominated**"（重新定值）值得解释：真实历史里发生过多次，比如**土耳其里拉 2005 年去掉六个零**（1,000,000 TRL → 1 TRY），**保加利亚列弗 1999 年去掉三个零**。

> 后果：**存着旧金额的历史数据，加上新表，读出来会差 100 万倍**。
>
> 所以"改这张表"从来不是一个 PR——它是一个**带数据迁移的变更**。作者说"reviewed change, with tests"，指的是这个级别。

**这就是为什么这一段值得单独讲：一个 5 行的 map，背后是一类会让账本整体错位的事件。**

---

## 1. 汇率为什么不能用 `float64`

> `[13:57:37]` here's a dollar fifteen, **enough float times a hundred, convert it to cents: 114.** **Floats are binary fractions, and most decimals like 1.15 or 0.1 have no exact binary form** — **even our rate 0.9215 is really 0.9214999 and so on**.

> **译文**：这是 \$1.15，**用 `double` 乘一百、再转成整数分：114。** **浮点是二进制分数，大多数十进制小数——比如 1.15 或 0.1——没有精确的二进制形式**——**连我们的汇率 0.9215 其实也是 0.9214999……**

```go
1.15 * 100              // = 114.99999999999999
int64(1.15 * 100)       // = 114      ← 少了一分
```

> `[13:57:57]` **usually it rounds back, sometimes it doesn't, and it's always the day somebody notices.**

> **译文**：**通常它会舍回来，有时候不会，而它总在有人发现的那一天。**

💡 这句话的杀伤力在 "**usually**"：**大部分测试会通过**。所以这个 bug 不会被 CI 抓住，它会在**生产环境，某个特定金额上**出现一次。

> 这是最恶劣的一类 bug：**不可复现、不可预测、量级看起来又很小**。
>
> 一分钱。乘以 100 万笔交易，是 1 万美元。

而更隐蔽的是**汇率本身**：

```
0.9215 → float64 → 0.92149999999999998668...
                         ↑ 第 17 位开始不一样
```

如果金额是 \$10,000,000.00：

```
10^9 分 × 0.92149999999999998... ≈ 921499999.99...   ← 差了一分，甚至更多
```

**"浮点误差很小"这句话，在乘以 10^9 之后就不成立了。**

---

## 2. 换成 `int64` 也有坑：静默溢出

> `[13:57:57]` so **a rate is an int64: a whole number of ten-billionths. 10 decimal places is more than any provider quotes.**

> **译文**：所以**汇率是一个 int64：以百亿分之一为单位的整数。10 位小数比任何提供商的报价都多。**

```go
type Rate int64                       // 0.9215 存成 9_215_000_000
const RateDecimals = 10               // 10^-10
const one = 10_000_000_000
```

> `[13:58:15]` but **multiplying has a trap of its own**: a million dollars in cents, **times a rate in ten-billionths, is about 10^20**. **The largest int64 is about 9 × 10^18**, and **Go doesn't complain when an int64 overflows — it wraps around silently to a nonsense number.**

> **译文**：但**乘法有它自己的陷阱**：一百万美元换成以分为单位，**乘以一个以百亿分之一为单位的汇率，大约是 10^20**。**最大的 int64 大约是 9 × 10^18**，而 **Go 在 int64 溢出时不会报错——它会静默回绕成一个毫无意义的数。**

💡 算一下这两个量级：

```
金额上限   100,000,000 分        （EP05 的上限，一百万美元）
汇率       9,215,000,000        （0.9215）
乘积       9.2 × 10^17          ← 还在 int64 内
```

**但把金额放大 100 倍**（一亿美元 = 10^10 分）：

```
10^10 × 9.2 × 10^9 = 9.2 × 10^19   > 9.2 × 10^18   ← 溢出
```

**溢出的结果是什么？** 不是 panic，不是 error，而是：

```
9223372036854775807 + 1  →  -9223372036854775808     ← 正数变负数
```

> **一笔 1 亿美元的换汇，结果是一个负数。** 而 Go **不会告诉你**。

> `[13:58:35]` so **the products go through `math/big`, which never overflows**.

> **译文**：所以**乘积走 `math/big`，它永远不会溢出**。

```go
// mulDiv returns amount × num ÷ den, rounded r.
func mulDiv(amount int64, num, den *big.Int, r Rounding) (int64, error) {
	n := new(big.Int).Mul(big.NewInt(amount), num)
	q, rem := n.QuoRem(n, den, new(big.Int))     // 商和余数一次拿到
	if r == Up && rem.Sign() > 0 {
		q.Add(q, big.NewInt(1))                   // 有余数才进位
	}
	if !q.IsInt64() {                             // ← 出口处才检查
		return 0, ErrTooLarge
	}
	return q.Int64(), nil
}
```

💡 三个细节：

**① `QuoRem` 一次拿商和余数** —— 舍入需要知道"有没有余数"，而 `Div` 只给商，`Mod` 要再算一遍。

**② `if r == Up && rem.Sign() > 0`** —— **只在有余数时才进位**。如果结果是精确的（余数为 0），`Up` 和 `Down` 得到同一个数。

> 少了 `rem.Sign() > 0` 这个条件会怎样？精确的 9215000000 会被加成 9215000001——**多收一分钱，而且是每一笔都多收**。

**③ `IsInt64()` 在出口检查** —— 中间用 `big.Int` 无限精度，**只在最后一步检查结果装不装得下**。这让"溢出"从一个**静默的错误**变成一个**显式的 error**。

> **`math/big` 在这里的成本是什么？** 每笔换汇两三次大数运算，几微秒。对照：一次 SMTP 几百毫秒，一次 Postgres 往返 1 毫秒。
>
> **为了消除一个"静默给出错误金额"的类别，付几微秒，这是本课程最划算的交易之一。**

---

## 3. `Rate` 类型：精确解析 + JSON 字符串

```go
// A Rate is how many units of one currency buy one unit of another, as an
// exact decimal: a whole number of ten-billionths. 0.9215 is 9_215_000_000.
// Never a float64: 0.1 has no exact binary value, and a tiny error, times a
// million dollars, is real money.
type Rate int64
```

> `[14:08:19]` `ParseRate` **reads a decimal string exactly, without ever going through a float**: **cut it at the dot, into the whole part and the fraction, both may only hold digits, and the fraction at most 10 of them**, then **glue them together, pad the fraction with zeros to 10 digits, and parse the result as one integer**. **0.9215 becomes 9,215,000,000.**

> **译文**：`ParseRate` **精确地读一个十进制字符串，从不让它经过 float**：**在点处切开，分成整数部分和小数部分，两半都只能含数字，小数部分最多 10 位**，然后**把它们粘起来，小数部分补零到 10 位，把结果当成一个整数解析**。**0.9215 变成 9,215,000,000。**

```go
func ParseRate(s string) (Rate, error) {
	whole, frac, _ := strings.Cut(s, ".")
	if whole == "" || len(frac) > RateDecimals ||
		strings.Trim(whole+frac, "0123456789") != "" {
		return 0, fmt.Errorf("fx: invalid rate %q", s)
	}
	n, err := strconv.ParseInt(whole+frac+strings.Repeat("0", RateDecimals-len(frac)), 10, 64)
	if err != nil || n == 0 {
		return 0, fmt.Errorf("fx: invalid rate %q", s)
	}
	return Rate(n), nil
}
```

💡 这一小段里有**四个防御**，每个都对应一类真实的坏输入：

| 检查 | 挡住什么 |
|---|---|
| `whole == ""` | `".9215"`（有人从 CSV 里切出来的） |
| `len(frac) > 10` | 精度超出类型能力 → **必须报错，不能截断** |
| `Trim(...) != ""` | `"0.92x5"`、`"-0.5"`、`"+0.5"`、`"1e-3"` |
| `n == 0` | **汇率 0** → 见下 |

> `[14:08:51]` **a rate of 0 is refused too: it would make every conversion free.**

> **译文**：**0 的汇率也被拒绝：它会让每一次换汇都免费。**

💡 这一句是**类型级防护**的典范。`Rate(0)` 是一个合法的 `int64`——**编译器不知道它没意义**。所以只能在**构造函数**里挡。

```
如果 0 进来了：
  卖出 100 美元 → 买到 0 欧元
  而美元那边照常扣 100
  → 客户损失 100 美元，钱进了 fx 账户
```

**"免费换汇"不是一个小 bug，是一个能让人一夜暴富的 bug。** 而它只需要一个 `"0"` 字符串。

> 这就是为什么**类型不够，还要有构造函数**。`Rate` 包装的目的是让"是一个 int64"和"是一个有效汇率"**不能混淆**。

### JSON：为什么汇率要作为字符串出行

> `[13:58:54]` ...and **at the edges rates are strings, passed digit by digit, and sent in JSON as a string, because to JavaScript every JSON number is a float**.

> **译文**：……而**在边界上，汇率是字符串，一位一位地传，在 JSON 里也作为字符串发送，因为对 JavaScript 来说，每个 JSON 数字都是 float**。

```go
func (r Rate) MarshalText() ([]byte, error) { return []byte(r.String()), nil }
func (r *Rate) UnmarshalText(b []byte) (err error) { *r, err = ParseRate(string(b)); return err }
```

💡 这里有一个**两层推理**，很值得学：

```
第 1 层：我们的服务用 int64 存，精确。
第 2 层：但只要它变成 JSON 数字，接收端的 JS 就会 JSON.parse 成 double，
        9_215_000_000 → 9215000000 → double 精确吗？
```

`9.215 × 10^9` 在 double 里**恰好精确**（小于 2^53）。所以对这个具体的数，JSON 数字**暂时**没问题。

**但问题是"暂时"：**

| 汇率 | 作为十进制 | 作为 JSON 数字的 double |
|---|---|---|
| USD/EUR | 0.9215 | 0.92149999999999998... |
| USD/JPY | 151.37 | 151.36999999999999... |
| JPY/USD | 0.0066063 | 0.0066062999999999999... |

**注意这里有两个不同的东西**：

1. **我们的 `int64` 表示**：精确
2. **我们把它格式化成十进制字符串**：`"0.9215"` 精确
3. **但如果我们输出 JSON 数字 `0.9215`**：接收端解析成 double → **不精确**

> 所以 `MarshalText` 输出的是 **`"0.9215"` 这个字符串**，接收端用 `ParseRate` 精确读回。
>
> **"以字符串传十进制"是跨语言传递小数的唯一安全方式。** 这是 Stripe / Square / 所有支付 API 的共同做法，不是我们的怪癖。

💡 而 `String()` 里的这一行也有讲究：

```go
s := fmt.Sprintf("%d.%0*d", r/one, RateDecimals, r%one)
return strings.TrimSuffix(strings.TrimRight(s, "0"), ".")
```

```
9215000000 → "0.9215000000" → 去尾零 → "0.9215"
15137000000 → "151.3700000000" → "151.37"
6000000000 → "0.6000000000" → "0.6"
```

**注意两层的顺序**：先 `TrimRight("0")`，再 `TrimSuffix(".")`。反了会出问题：

```
"100.0000000000" → TrimSuffix(".") 先做？点不在末尾，不动
                 → TrimRight("0") → "100."     ← 留下一个裸点
```

**顺序是对的，但很容易写反。** 这种"两行看起来可交换、其实不可交换"的地方，是 code review 最该看的地方。

---

## 4. 舍入：这是商业决定，不是数学问题

> `[13:59:10]` now **rounding**. What we pay must be whole cents, so the question is **which way**. **$10 at 0.9215 is 921 and a half euro cents.** **Half up** — the rule from school — says **922**. **Bankers' rounding, half to even**, sends a half to the even neighbor: up here (**922**), but **920.5 goes down to 920**. **Over millions of roundings, half of the halves go up and half go down, so totals don't drift.**

> **译文**：现在说**舍入**。我们付出的必须是整分，所以问题是**往哪个方向**。**\$10 按 0.9215 是 921.5 欧分。** **四舍五入（half up）**——学校里那条规则——说 **922**。**银行家舍入（half to even）**把一个半送到偶数邻居：这里向上（**922**），但 **920.5 会向下变成 920**。**在几百万次舍入里，一半的半向上、一半向下，所以总额不会漂移。**

> `[13:59:50]` **Half even is right for sums, interest accruals, statistics, reports.** But **a single conversion is a promise to one customer, and every rounding is either our money or theirs** — so **we use directed rounding**: **what we pay out rounds down, never a fraction we don't have**; **what we charge rounds up**.

> **译文**：**half even 对求和、利息计提、统计、报表是对的。** 但**一次换汇是对一个客户的承诺，而每一次舍入不是我们的钱就是他们的钱**——所以我们**用有方向的舍入**：**我们付出的向下取整，绝不给出我们没有的那一分**；**我们收进的向上取整**。

💡 这是本集**最重要的一个决策**，而它**不是技术决策**。三种舍入并列：

| 方式 | 921.5 → | 920.5 → | 适合 |
|---|---|---|---|
| half up | 922 | 921 | 学校、日常 |
| **half to even** | 922 | **920** | **求和、计提、统计**（无偏） |
| **directed（Down/Up）** | **921 / 922** | **920 / 921** | **单笔交易**（有方向） |

**为什么 half-even 不适合单笔交易**：它是**无偏**的——长期看总额不漂移。但**单笔交易没有"长期"**：

```
客户卖出 10 美元，应该得到 921.5 欧分
  half-even → 922（客户多得了半分，我们付了）
  half-even → 920（客户少得了半分，我们赚了）
```

而 half-even 会**根据邻居的奇偶**决定方向——**客户无法预测自己会被怎么舍**，这在支付里是不能接受的不透明。

**directed rounding 给出的是可解释的规则：**

```
Convert(卖出) → Down   我们付出去的，向下
Cost(买进)    → Up     你买到手的，向上（你付得更多一点）
```

> `[14:00:08]` **what we pay out rounds down, never a fraction we don't have; what we charge rounds up: 5425 wouldn't quite buy 50 euros.**

> **译文**：**我们付出去的向下取整，绝不给出一分我们没有的钱；我们收进的向上取整：5425 买不到 50 欧元。**

💡 看到 `5425.94` 那个例子：客户要**恰好 50 欧元**，按汇率需要 **5425.94 分**。

```
Down → 5425 分  →  换出来是 49.999... 欧元  →  客户拿不到 50 ❌
Up   → 5426 分  →  换出来是 50.000... 欧元  →  客户拿到 50 ✅
```

**规则的一句话版本**：**"客户要求的，我们一定给足；客户多出来的零头，归我们。"**

### 零头去哪了

> `[14:00:24]` and **the fraction in between isn't lost — it stays in our FX accounts. That's a decision, and we write it down in the code, which is the part most systems forget.**

> **译文**：而**中间那个零头并没有丢——它留在我们的 FX 账户里。这是一个决定，而我们把它写在代码里——这正是大多数系统忘记的部分。**

💡 这句话在 §15 会有一个**具体的账本证据**：

```
客户付    5426 分
我们需要   5425.94 分
零头         0.06 分  →  留在 fx 账户里
```

**它不是"手续费"（手续费是另外收的 50bp），它是舍入残差。** 而它有一个**账本里的地址**，所以：

- 不会被"消失"（那会让账不平）
- 可以**被统计**（"我们靠舍入赚了多少"——真实答案是很少，但它是可查的）
- 是**对账时的解释**（`fx` 账户余额 = 头寸 + 舍入残差）

> **"把它写下来"比"把它算对"更重要**：算对只保证这一次对，写下来保证**下一个人**知道这是故意的。

**代码里的写法**（`convert.go` 的注释就是这个"写下来"）：

```go
const (
	// Down is for what we pay out: never a fraction of a cent more than the rate gives.
	Down Rounding = iota
	// Up is for what we charge: never a fraction of a cent less than the rate asks.
	Up
)
```

> `[14:10:15]` ...`Convert` takes **an amount in minor units of one currency, the two currency codes, a rate and a rounding**, and returns **minor units of the other**. And **`Cost` is `Convert` backwards**: how much of the first currency it takes to buy an amount of the second. **It always rounds up**, to **the smallest amount that `Convert`, rounding down, turns into at least what you asked for**.

> **译文**：……`Convert` 拿**一个以某货币最小单位计的金额、两个货币代码、一个汇率和一个舍入方向**，返回**另一种货币的最小单位**。而 **`Cost` 是 `Convert` 反过来**：要花多少第一种货币才能买到一定量的第二种。**它永远向上取整**，取到**最小的那个金额，使得 `Convert` 用向下取整能换出至少你要的数量**。

💡 `Cost` 的定义里藏着一个**配对不变式**，后面的测试会验证它：

```
Convert(Cost(B, Up), Down) >= B        ← 你付了这么多，一定换得到 B
Convert(Cost(B, Up) - 1, Down) <  B    ← 少付一分，就换不到 B
```

**这两条合起来，说明 `Cost` 是"最小的足够金额"。** 这就是 §16 里那个"比行更有价值的检查"。

---

## 5. 手续费：为什么显式收，不做点差

> `[14:00:41]` **how does the house earn its money?** There are two ways: **a spread** — quote a slightly worse rate than the market, and keep the difference; **the customer sees 0.9169 and never sees a fee; in the books, that income hides inside the conversion, and the customer can't easily tell what it really cost them**. Or **an explicit fee**: the market's rate, **plus a fee you can see, as a line of its own, in a revenue account**. **Finance reads our FX income straight off the ledger, and the customer can compare us with anyone.**

> **译文**：**这家公司怎么赚钱？** 有两种方式：**点差**——报一个比市场略差的汇率，把差价留下；**客户看到 0.9169，永远看不到手续费；在账上，那笔收入藏在换汇里面，而客户没法轻易知道自己到底花了多少**。或者**显式手续费**：市场汇率，**加上一笔你看得见的手续费，作为独立的一行，进一个收入账户**。**财务直接从账本读出我们的 FX 收入，而客户可以拿我们和任何人比价。**

💡 这是一个**产品/财务决策**，作者把它讲成了工程决策：

| | 点差（spread） | 显式手续费（explicit fee） |
|---|---|---|
| 客户看到 | 汇率 0.9169（**不知道被收了钱**） | 汇率 0.9215 + 手续费 \$0.50 |
| 收入在账本里 | **藏在 fx 账户的残差里** | **独立的 `fx_fees` 账户** |
| 财务能直接读吗 | ❌ 要反推 | ✅ `SELECT sum(...) FROM entries WHERE account = fx_fees` |
| 客户能比价吗 | ❌ | ✅ |

**而"能比价"在受监管的支付业务里不是加分项，是合规要求。**（欧盟 PSD2、美国很多州都要求显式披露换汇成本。）

> `[14:01:28]` we'll charge **half a percent, 50 basis points on top, in the currency the customer sells, rounded up**, and **it's a setting, because pricing is a business decision, not ours**.

> **译文**：我们收**半个百分点，也就是在上面加 50 个基点，用客户卖出的那种货币计价，向上取整**，而且**它是一个配置项，因为定价是商业决定，不是我们的**。

```go
// Fee returns bps basis points of amount, a hundredth of a percent each,
// rounded up: 50 basis points of 54.26 dollars is 28 cents, not 27.13.
func Fee(amount, bps int64) int64 {
	return (amount*bps + 9_999) / 10_000
}
```

> `[14:11:55]` **adding 9999 before dividing by 10000 is the classic way to round a positive division up.**

> **译文**：**在除以 10000 之前加上 9999，是让一个正数除法向上取整的经典做法。**

💡 这是**整数向上取整的标准技巧**，值得记住：

```
向上取整(a / b)  ==  (a + b - 1) / b        （a >= 0, b > 0）
```

验算：

| a | b | a/b | 真向上 | (a+9999)/10000 |
|---|---|---|---|---|
| 5426×50 = 271300 | 10000 | 27.13 | 28 | (271300+9999)/10000 = 281299/10000 = **28** ✅ |
| 100×50 = 5000 | 10000 | 0.5 | 1 | (5000+9999)/10000 = 14999/10000 = **1** ✅ |
| 0 | 10000 | 0 | 0 | 9999/10000 = **0** ✅ |

第三行很重要：**金额为 0 时结果必须是 0**，而不是被 `+9999` 顶成 1。

> 为什么不用 `math.Ceil(float64(a)/float64(b))`？**因为那会引入浮点。** 而这整个函数存在的理由就是避开浮点。
>
> 为什么不用 `math/big`？`[14:11:55]` 说得清楚：**"our largest amount, times 10000 basis points, is nowhere near overflowing"**——`10^8 × 10^4 = 10^12`，远小于 `9×10^18`。**能用整数就不用大数**，因为大数慢且啰嗦。

---

## 6. 为什么 FX 住在 wallet 里，而不是第 7 个服务

这是本集**最大的架构决策**，也是作者讲得最细的一段。

> `[14:01:44]` where should all this live? **An FX service sounds tidy**, but **a conversion is a change to the ledger, and the wallet owns the ledger.** **Inside the wallet, marking a quote used and writing its entries happen in one database transaction.** **In a service of its own, a conversion becomes a saga** — like our transfers: **reserve the dollars, convert, credit the euros, and compensate when a step fails. A crash in the middle leaves someone's money in flight. That's a lot of machinery for something one transaction does perfectly.**

> **译文**：这一切该住在哪？**一个 FX 服务听起来很整齐**，但**一次换汇是对账本的改动，而账本属于 wallet**。**在 wallet 内部，把报价标记为已使用和写它的分录发生在同一个数据库事务里。** **在一个独立服务里，一次换汇就变成一个 saga**——像我们的转账那样：**预留美元、换汇、贷记欧元，某一步失败时补偿。中途崩溃会把某个人的钱留在半空中。为了一个单事务就能完美完成的事，这是一大堆机械。**

💡 这是一段**教科书级别的取舍陈述**，因为它把"听起来整齐"和"实际成本"分开算了：

| | FX 在 wallet 内 | FX 是独立服务 |
|---|---|---|
| 换汇的实现 | **一个数据库事务**（6 笔分录） | **一个 saga**（3~4 步 + 补偿 + 状态机 + 恢复） |
| 崩溃语义 | 全回滚，钱不动 | **钱在飞行中**（EP12 那整套） |
| 代码量 | ~250 行 `fx.go` | EP12 的 `transfer` 服务（约 3000 行） |
| 复用已有 | 复式记账触发器的保证 | 需要**自己保证**跨服务一致性 |

> **"一个 saga 换一个事务"是本集的核心算术。** 你为了一个"整洁的服务边界"，付出了 EP12 整集的复杂度。

而这背后是一条**硬约束**：

> EP02 的 balance trigger 在**同一个 Postgres**里。跨服务意味着**跨数据库**，而**跨数据库没有事务**。

**所以问题不是"要不要整洁"，是"你能不能承受失去事务"。**

> `[14:02:37]` **rates are different — they can come from anywhere, so they go behind an interface.**

> **译文**：**汇率不一样——它可以从任何地方来，所以它走到一个接口后面。**

> `[14:02:52]` ...**so FX lives in the wallet, the math goes in a package of its own, with no database, and if one day rates need a service — say one that caches a market feed for everyone — it's the rate provider that moves out, not the conversion.**

> **译文**：……**所以 FX 住在 wallet 里，而数学放在它自己的包里，没有数据库；如果有一天汇率需要一个服务——比如一个为所有人缓存行情源的——搬出去的是汇率提供者，不是换汇。**

💡 这句话是**可演进设计**的范本。把它画成层次：

```
internal/wallet/fx.go            ← 换汇：账本操作，永远在 wallet 里
        │
        ▼
internal/fx/                     ← 数学：纯函数，无 DB、无网络
        │
        ▼
internal/fx/provider.go          ← 汇率来源：接口
        │
        ├── DevRates（embed JSON，编译进二进制）
        └── 将来：BankFeed（独立服务、缓存行情）
```

**"将来会变的那一层，被一个接口隔离在最小的地方。"**

> 而**搬出去的边界选得很准**：`RateProvider` 是一个**单方法接口**（`Rate(ctx) (fx.Rate, error)`）。把一个单方法接口实现搬到别的进程，**代价是一次 RPC**。
>
> 反过来，如果把"换汇"搬出去，代价是**跨服务事务**。

**这就是"接口应该画在哪里"的判据：画在**变化的那条缝**上，而不是画在**你想要整洁的那条线**上。**

---

## 7. 报价（quote）：三个属性缺一不可

> `[14:03:12]` here's the flow: **the client asks for a quote, "sell $100 for euros". We price it, and store it: the rate, both amounts, the fee, and an expiry 30 seconds from now.** The response shows all of that, so **the customer can decide to accept**. **The client sends back the quote's ID, nothing else.**

> **译文**：流程是这样：**客户端要一个报价，「卖掉 \$100 换欧元」。我们算价，并把它存起来：汇率、两个金额、手续费，以及一个 30 秒后到期的时刻。** 响应把这一切都给出来，这样**客户可以决定接受**。**客户端只把报价的 ID 发回来，别的什么都不发。**

> `[14:04:02]` **if the client sent back the rate and the amounts, anyone could edit them on the way.**

> **译文**：**如果客户端把汇率和金额发回来，路上的任何人都能改它们。**

💡 这是一条**安全规则**，而且极其容易违反。看两种 API 设计：

```http
# ❌ 危险：客户端回传条款
POST /v1/fx/conversions
{ "from":"USD", "sell":10000, "to":"EUR", "buy":9215, "rate":"0.9215", "fee":50 }

# ✅ 我们的：客户端只回传 ID
POST /v1/fx/conversions
{ "quote_id": "0190f3..." }
```

**第一种的漏洞**：客户端可以把 `rate` 改成 `"5.0"`，然后把 `buy` 改成 `50000`。服务端如果"信任客户端的条款"，就会给他 500 欧元。

> 这就是**"不要相信客户端送来的派生数据"**。所有能推导出来的东西，**都在服务端推导**。
>
> 这个规则在 EP05 已经出现过一次：`DepositRequest` 里有 `currency`，而且服务端**校验它和钱包币种一致**（不是直接用）。

### 属性 1：服务端存储

> `[14:03:45]` ...**a good app shows the rate, the fee, the total, and a countdown, so nobody is surprised when the price runs out. That's the point of storing it.**

> **译文**：……**一个好的 app 会显示汇率、手续费、总额，和一个倒计时，这样价格过期时没有谁会觉得意外。这就是把它存起来的理由。**

### 属性 2：30 秒过期

> `[14:04:18]` **it expires because the market keeps moving. While a quote is open, we've promised a price, and if the rate moves against us, that's our loss. 30 seconds bounds the risk.**

> **译文**：**它会过期，因为市场一直在动。一个报价开放期间，我们承诺了一个价格，而如果汇率朝不利方向移动，那是我们的损失。30 秒给这个风险封顶。**

💡 这句是**期权定价**的直觉：**一个未使用的报价，是一份我们免费送给客户的短期期权**。

```
客户拿了一个报价 → 相当于拿到"30 秒内按 0.9215 换汇"的权利
汇率朝对我们不利的方向动 → 客户会行使（他赚）
汇率朝对我们有利的方向动 → 客户不行使（我们不赚）
```

**这个期权的价值随过期时间线性增长。** 所以：

| 过期时间 | 风险 | 客户体验 |
|---|---|---|
| 1 秒 | 几乎为零 | 网络抖一下就失败 |
| **30 秒** | 可控 | 够点一下"确认" |
| 5 分钟 | 可能亏 | 非常舒服 |
| 1 小时 | **投机温床** | 客户会拿去套利 |

> `[14:16:11]` **big players go one step further, and cover each quote with their own bank the moment it's accepted, so a market move can't hurt them. At our size, 30 seconds and their fee are enough.**

> **译文**：**大型玩家更进一步：每个报价被接受的那一刻，他们就在自己的银行那边做对冲，这样市场波动伤不到他们。我们这个体量，30 秒加上那笔手续费就够了。**

💡 "**cover**"（对冲/平仓）是真实的银行操作：你承诺给客户 0.9215，同时立刻在银行按 0.9217 卖出欧元。**价差被锁定，风险为零。**

**但那需要银行授信、ISDA 协议、实时接口。** 在课程里，**"30 秒 + 50bp"就是那个风险的定价**——50bp 里有一部分就是在为这 30 秒的波动付账。

> **这就是为什么手续费高低和过期时间长短期相关**：它们共同决定了**你承担多少市场风险**。

### 属性 3：一次性

> `[14:04:35]` **and it's used once**: a quote is a promise for one conversion. **If it could be used again, a customer could watch the market move, and keep converting at the old rate, at our expense.**

> **译文**：**而且它只能用一次**：一个报价是对一次换汇的承诺。**如果它能被重复使用，客户可以看着市场走，然后一直按旧汇率换汇，代价由我们承担。**

💡 这是**属性 2 的补充**，而不是重复：

```
只有"过期"没有"一次性"：
  客户拿到报价 → 30 秒内反复换汇 1000 次 → 全部按旧汇率
  （只要汇率有利，他能把我们的 fx 账户抽干）

只有"一次性"没有"过期"：
  客户拿到报价 → 三年后市场变了 10 倍 → 他仍然能按旧汇率换
```

**两个属性各自关闭一个套利窗口。缺一个，另一个就失效。**

数据库层面（`000007_fx.up.sql`）：

```sql
    -- the conversion that used it: a quote is used once, at most
    transaction_id uuid        UNIQUE REFERENCES transactions (id)
```

> `[14:19:29]` ...and **transaction id, the conversion that used it, unique, and set only once — that column is the quote's single use, written into the schema.**

> **译文**：……以及 **transaction id，用了它的那次换汇，唯一，而且只被设置一次——那一列就是报价的"一次性"，写进了 schema。**

💡 注意三点：

1. **`UNIQUE REFERENCES transactions(id)`** —— 一个事务只能"消耗"一个报价（`UNIQUE`），而且它必须是一个真实存在的事务（外键）
2. **可空** —— 未使用的报价 `transaction_id IS NULL`
3. **"set only once" 靠什么保证？** 靠 §12 的 `LockQuote` 行锁 + `TransactionID != nil` 检查。**数据库单独保证不了**"只写一次"，但**行锁 + 检查**做到了。

> 一个**更好的**数据库级保证是 `CHECK` 或者触发器的状态机，但那会让"读起来简单"的设计变复杂。**这里选了应用层保证，而它是对的**——因为只有一个地方写这一列。

---

## 8. 为什么两笔分录不够：四笔 + 两笔

> `[14:04:52]` **Alice sells $100 at 0.9215. Two entries — dollars out, euros in — can't work: they'd balance in no currency at all**, and **our trigger from episode 2 rejects them, because it checks debits and credits per currency**.

> **译文**：**Alice 按 0.9215 卖 \$100。两笔分录——美元出去、欧元进来——不行：它们在**任何**货币里都不平衡**，而我们第 2 集的触发器会拒绝它们，因为它按货币检查借和贷。**

💡 这是本集**最美的一处"旧代码收了新账"**。先看为什么两笔不行：

```
分录 1: Alice 的美元钱包  借 10000 分  币种 USD
分录 2: Alice 的欧元钱包  贷  9215 分  币种 EUR
```

按 EP02 的触发器（`GROUP BY currency`）：

| 币种 | 借方合计 | 贷方合计 | 平衡？ |
|---|---|---|---|
| USD | 10000 | **0** | ❌ |
| EUR | **0** | 9215 | ❌ |

**两种货币各自都不平衡。** 而这**不是 bug**——它是复式记账的正确行为：

> **一笔交易不能"用一种货币的钱换另一种货币的钱"，因为那是两种不同的资产。**

正确的记法是**通过中间账户**：

> `[14:05:09]` so **the dollar side**: Alice's dollar wallet is **debited $100**, and **our FX account in dollars is credited $100** — **balanced in dollars**. **The euro side**: **our FX account in euros is debited 9215**, and **Alice's euro wallet is credited 9215** — **balanced in euros**. **That's four entries, and our FX accounts are the bridge: the house buys her dollars and sells her euros.**

> **译文**：所以**美元这一侧**：Alice 的美元钱包**借 \$100**，而**我们的美元 FX 账户贷 \$100**——**在美元上平衡**。**欧元这一侧**：**我们的欧元 FX 账户借 9215**，而 **Alice 的欧元钱包贷 9215**——**在欧元上平衡**。**这是四笔分录，而我们的 FX 账户就是那座桥：这家公司买下她的美元，再卖给她欧元。**

```
        USD 侧（平衡）                        EUR 侧（平衡）
   ┌──────────────────┐                 ┌──────────────────┐
借 │ Alice 美元钱包    │ 10000      借 │ FX 账户 (EUR)     │ 9215
贷 │ FX 账户 (USD)     │ 10000      贷 │ Alice 欧元钱包     │ 9215
   └──────────────────┘                 └──────────────────┘
```

**加上手续费两笔：**

> `[14:05:45]` then **the fee, as two more entries: 50 cents from her dollar wallet to our fees account**. **Every currency balances on its own: a hundred dollars and 50 cents of debits and of credits, and 9215 in euros. One transaction, six entries, all or nothing.**

> **译文**：然后是**手续费，作为另外两笔分录：50 分从她的美元钱包到我们的手续费账户**。**每种货币各自平衡：借方和贷方各是 100 美元 50 分，以及 9215 欧元。一个事务，六笔分录，全成或全不成。**

```
借 Alice 美元钱包   50   （再扣一次）
贷 fx_fees (USD)    50
```

**最终：6 笔分录，USD 侧 10050/10050，EUR 侧 9215/9215。**

> `[14:20:06]` **and the rule that makes a two-entry conversion impossible is already here, in migration one, from episode two.** The balance trigger **groups a transaction's entries by currency, and in each one, debits must equal credits**. **We wrote that a long time ago, for exactly this day.**

> **译文**：**而让两笔分录的换汇变得不可能的规则，早就在这里了——第 2 集的 migration one 里。** balance 触发器**把一个事务的分录按货币分组，而在每一组里，借必须等于贷**。**我们很久以前就写了它，就是为了这一天。**

💡 "**for exactly this day**" 有点浪漫化——真实原因通常只是"复式记账就该这样"。但它点出了一个**事实**：

> **EP02 写触发器时，你不可能预见 FX。但因为你遵守了一条通用规则（每种货币独立平衡），你在 16 集之后免费得到了一个保护。**

**这正是"通用规则"比"针对当前需求"更值钱的地方。** 而且它会在 §16 的测试里被**主动验证**：

> `[14:37:02]` **one last test, the one that shows why we need four entries: a conversion posted as two — dollars out of one wallet, and euros into the other — Postgres refuses it at commit, with a check violation from the balance trigger.**

> **译文**：**最后一个测试，它说明了为什么我们需要四笔：一次换汇被记成两笔——一个钱包出美元、另一个钱包进欧元——Postgres 在提交时拒绝它，报出来自 balance 触发器的 check violation。**

💡 **这个测试的价值**：它验证的不是"我们的代码正确"，而是"**数据库不允许错误的记法**"。

```
测试 1：Convert(10000 USD) → 9215 EUR        ← 验证正常路径
测试 2：手写两笔分录 → Postgres 拒绝          ← 验证防线存在
```

**第二个测试永远不会在生产里跑到**（因为代码只走 `postings` 那条路）。那为什么还要写？

> 因为它是**文档**：下一个人如果想"简化一下，两笔就够了"，这个测试会告诉他不行的原因。
>
> **测试也是一种"把决定写下来"的方式。**

---

## 9. 账户设计：per currency，不是 per pair

> `[14:18:07]` now the ledger, **migration 7, fx**. First **the house's accounts: an FX account in each currency — our side of every conversion — and an FX fees account in each currency for the revenue.** All **credit-normal**, so **a balance of +100 dollars means we took in 100 dollars from customers, and −92.15 in euros means we paid out euros we have to buy back. Together, that's our position.**

> **译文**：现在说账本，**migration 7，fx**。首先是**这家公司的账户：每种货币一个 FX 账户——我们在每次换汇里的那一侧——以及每种货币一个 FX 手续费账户，用于收入**。全部**贷方为正**，所以**+100 美元的余额意味着我们从客户那里收进了 100 美元，而 −92.15 欧元意味着我们付出了需要买回来的欧元。合起来，那就是我们的头寸。**

```sql
INSERT INTO accounts (kind, name, currency, normal_balance) VALUES
    ('system', 'fx', 'EUR', 'credit'),
    ('system', 'fx', 'GBP', 'credit'),
    ('system', 'fx', 'JPY', 'credit'),
    ('system', 'fx', 'USD', 'credit'),
    ('system', 'fx_fees', 'EUR', 'credit'),
    ...
```

> `[14:18:41]` **one account per currency, and not one per currency pair, because our position is per currency: the dollars we hold are the same dollars, whatever we sold for them.**

> **译文**：**每种货币一个账户，而不是每个货币对一个，因为我们的头寸是按货币算的：我们手里的美元就是同一批美元，不管我们是为了什么把它们卖出去的。**

💡 这条设计规则值得展开。假设我们按货币对建账户：

```
fx_USD_EUR、fx_EUR_USD、fx_USD_JPY、fx_JPY_USD、fx_EUR_GBP...
4 种货币 → 12 个有向对 → 12 组账户（×2 for fees = 24）
```

**问题**：

1. **"我们有多少美元"需要求和 3 个账户**（USD_EUR、USD_JPY、USD_GBP）
2. **USD→EUR 和 EUR→USD 是两个不同的账户**，但它们在**经济上是同一个头寸的相反面**
3. 加第 5 种货币 → 加 8 个账户（4 对 × 2 方向）

**而按货币建账户**：

```
4 种货币 → 4 个 fx 账户 → "我们有多少美元" = fx(USD) 的余额
```

> **判据是"这个余额在会计上是不是一个东西"**：我们欠/持有的**美元**是一个东西，与"通过哪个货币对得到它"无关。
>
> 这就是复式记账的**维度选择**：账户的维度应该匹配**你想要单独看什么**。你想要"每种货币的头寸"，所以维度是 currency。

> `[14:18:57]` ...**in the quotes**: `id`, the owner, the currency and amount sold, the currency and amount bought, **with checks: positive amounts, and two different currencies**, the fee in the currency sold on top, **the rate as a bigint of ten-billionths — exactly our `Rate` type** — when it expires, and **transaction id: the conversion that used it, unique, and set only once.**

> **译文**：……**quotes 表里**：`id`、所有者、卖出的币种和金额、买入的币种和金额，**带检查：金额为正，且两种货币不同**；手续费以卖出的货币计，加在上面；**汇率作为以百亿分之一为单位的 bigint——正是我们的 `Rate` 类型**；它什么时候过期；以及 **transaction id：用了它的那次换汇，唯一，而且只被设置一次**。

```sql
CREATE TABLE fx_quotes (
    id             uuid        PRIMARY KEY,
    owner_id       uuid        NOT NULL,
    sell_currency  text        NOT NULL,
    sell_amount    bigint      NOT NULL CHECK (sell_amount > 0),
    buy_currency   text        NOT NULL CHECK (buy_currency <> sell_currency),
    buy_amount     bigint      NOT NULL CHECK (buy_amount > 0),
    fee            bigint      NOT NULL CHECK (fee >= 0),
    rate           bigint      NOT NULL CHECK (rate > 0),
    expires_at     timestamptz NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    transaction_id uuid        UNIQUE REFERENCES transactions (id)
);
```

💡 注意 `CHECK (buy_currency <> sell_currency)` —— **同一货币对同一货币的换汇被数据库挡住了**。

如果放进去会怎样？

```
卖 100 USD → 买 100 USD
USD 侧：借钱包 10000 / 贷 fx(USD) 10000          ← 平衡
USD 侧：借 fx(USD) 10000 / 贷钱包 10000          ← 平衡（但同一个外币！）
```

其实……**它会在同一种货币里平衡**，但结果是：**客户付了 50bp 的手续费，什么也没换到**。

> **这是一个"技术上能通过、业务上是骗钱"的操作。** 所以正确的位置是**业务校验 + 数据库 CHECK 双层**。

### 数据库是那个时钟

> `[14:20:43]` ...**the database is the clock that will check it**, so **a quote's 30 seconds can't be stretched, or cut short by a server whose clock is off.**

> **译文**：……**数据库是那个会去检查它的时钟**，所以**一个报价的 30 秒既不会被拉长，也不会被一台时钟不准的服务器缩短。**

```sql
-- name: CreateQuote :one
INSERT INTO fx_quotes (...)
VALUES (..., now() + make_interval(secs => @ttl_seconds))
RETURNING *;

-- name: LockQuote :one
SELECT *, (expires_at <= now()) AS expired        -- ← 由 Postgres 算，不是 Go
FROM fx_quotes WHERE id = $1 AND owner_id = $2
FOR UPDATE;
```

> `[14:22:19]` ...and **one more field: `expired`, a plain bool computed by Postgres — no time zone arithmetic in Go at all.**

> **译文**：……还有**一个字段：`expired`，一个由 Postgres 算出来的普通 bool——Go 里完全没有时区运算。**

💡 这是**"一个时钟"原则**。对比一下两种做法：

| | 写入时钟 | 判断时钟 | 后果 |
|---|---|---|---|
| **多实例 + Go 时间** | 实例 A 的 `time.Now()` | 实例 B 的 `time.Now()` | **A 快 2 秒 → 报价被缩短 2 秒** |
| **数据库时钟** | `now()` | `now()` | **同一个时钟，同一个 Postgres** |

**为什么"缩短"也是问题**？因为**客户拿到的响应里写着"30 秒"**。如果实际只有 28 秒，客户点了"确认"却收到 `quote expired`——**这是一个无法解释的失败**。

> 而更糟的是相反方向：**时钟慢的实例**会让报价**活过 30 秒**，那正是 §7 说的**风险敞口**。

💡 顺带一个 NTP 常识：容器里 `time.Now()` 走的是**宿主机时钟**。多台宿主机之间差几十毫秒是常态，差几秒是故障。**而"差几秒"在生产里发生过无数次。**

> **凡是"两个进程都要对同一件事判断时间"的地方，选一个时钟。** 这里选了 Postgres——因为它已经在事务里了。

---

## 10. `LockQuote`：两笔请求抢一个报价

> `[14:26:24]` **what happens when two requests for the same quote arrive together?** Both run `LockQuote`; **the first gets the row lock, the second waits right there until the first commits. Then, under READ COMMITTED, PostgreSQL reads the row again, as it is after that commit, and the second request sees a transaction id — quote used. No double conversion, and no error to retry, just a clear answer.**

> **译文**：**同一个报价的两笔请求同时到达会怎样？** 两个都跑 `LockQuote`；**第一个拿到行锁，第二个就在那里等到第一个提交。然后，在 READ COMMITTED 下，PostgreSQL 重新读那一行——读的是那次提交之后的样子——于是第二个请求看到一个 transaction id：报价已使用。没有双重换汇，也没有需要重试的错误，只有一个清楚的回答。**

💡 这一段是 **EP06 那个知识点在 `FOR UPDATE` 上的精确应用**，而且它解释了 **`FOR UPDATE` 的一个常被误解的行为**：

```
时刻 T1  请求 A: SELECT ... FOR UPDATE   → 拿到锁，读到 transaction_id = NULL
时刻 T2  请求 B: SELECT ... FOR UPDATE   → 阻塞（等锁）
时刻 T3  请求 A: UPDATE ... SET transaction_id = X; COMMIT
时刻 T4  请求 B: 解除阻塞，PostgreSQL 重新读这一行
          → 读到 transaction_id = X     ← 关键：重读，不是用旧快照！
          → 于是 B 看到 "已使用"
```

**为什么在 READ COMMITTED 下会重读？** 因为这是 `FOR UPDATE` 的**规定行为**（PostgreSQL 文档明确写了）：

> 在 READ COMMITTED 隔离级别下，`SELECT ... FOR UPDATE` 如果遇到一个已被并发事务更新并提交的行，会**重新评估该行的 WHERE 条件**，并返回**更新后的版本**。

> **这正是 `FOR UPDATE` 和普通 `SELECT` 的区别**：普通 `SELECT` 在 READ COMMITTED 下读到的是**语句开始时的快照**，不会重读。

所以这个流程**不需要重试**：

| 方案 | 结果 |
|---|---|
| `SELECT` 检查 + `UPDATE`（无锁） | 两个都读到 NULL → **两个都换汇** ❌ |
| `SELECT ... FOR UPDATE` + 检查 | 第二个**重读**，看到 X → 返回"已使用" ✅ |
| 乐观锁（`UPDATE ... WHERE transaction_id IS NULL`） | 第二个更新 0 行 → 需要**自己**判断成"已使用" |

> 作者选了第二种，理由是 "**no error to retry, just a clear answer**"——**悲观锁把并发冲突变成了一个业务答案，而不是一个技术错误。**
>
> 这和 EP06 的"用锁而不是 SERIALIZABLE"是同一条思路：**能让冲突变成"排队"，就不要让它变成"重试"。**

### 检查的顺序：used 在 expired 之前

> `[14:26:07]` **the order of the checks matters: used comes before expired. A quote that was used, and has since expired, is, first of all, used.** **That's the answer a client retrying an old request needs to see.**

> **译文**：**检查的顺序很重要：used 在 expired 之前。一个被使用过、之后又过期的报价，首先是"已使用"。** **那正是一个重试旧请求的客户端需要看到的答案。**

```go
switch {
case errors.Is(err, pgx.ErrNoRows):
	return ErrQuoteNotFound                          // 404
case err != nil:
	return fmt.Errorf("lock quote %s: %w", id, err)
case quote.TransactionID != nil:
	return fmt.Errorf("quote %s: %w", id, ErrQuoteUsed)      // 422 used
case quote.Expired:
	return fmt.Errorf("quote %s: %w", id, ErrQuoteExpired)   // 422 expired
}
```

💡 这个顺序的理由极其具体，值得还原现场：

```
T+0    客户发出换汇请求（quote 有效期 30 秒）
T+1    服务端完成换汇，返回 201
       但响应在路上丢了
T+45   客户端重试同一个请求（同一个 quote id + 同一个幂等键）
```

**服务端看到的是什么？** 那个 quote **既是"已使用"，也是"已过期"**。

- 如果先判 `expired` → 返回 `422 quote expired` → **客户端会以为要重新报价、重新换汇**（可能真的又换一次！）
- 如果先判 `used` → 返回 `422 quote used` → **客户端知道"这笔已经做过了"**

> **同一个事实，两种回答，导致两种客户端行为。** 这就是"错误信息的顺序是一个 API 设计"。

💡 而这里还有一个**分层**值得注意：

| 层 | 机制 | 覆盖什么 |
|---|---|---|
| **幂等键**（EP07） | 同一个 key → 返回**存下来的响应**（201） | **同一个请求的完整重试** |
| **quote 一次性** | 已使用 → 422 | **不同请求用同一个报价** |

> `[14:31:53]` ...**a new request with a different key for a quote that's been used — it's the quote's own check. Two layers, one for retries, and one for the quote.**

> **译文**：……**一个用不同幂等键、针对一个已被使用过的报价的新请求——那是报价自己的检查。两层，一层管重试，一层管报价。**

💡 这两层**不能合并**，因为它们的语义不同：

```
幂等键层：这是"同一个请求"吗？    → 是 → 返回原来的响应（201）
报价层  ：这个报价还能用吗？      → 不能 → 422

如果只有幂等键：
  客户端换个 key 再发一次同 quote → 没有记录 → 又换一次汇  ❌
如果只有报价层：
  同一个请求重试 → 422 quote used → 客户端以为失败了  ❌（其实成功了！）
```

**第一层的失败模式是"重复执行"，第二层的失败模式是"成功被误报为失败"。** 两个都必须有。

---

## 11. 锁顺序：把 EP06 的代码提取出来

> `[14:29:02]` `lockInOrder` **lives in `transfer.go`**. Here's **our locking from episode 6**: both accounts, **the lower id first, so two transactions can never wait on each other in a circle**. **Our conversion locks two wallets, so it needs the same order and the same code**: **the loop becomes a call**.

> **译文**：`lockInOrder` **住在 `transfer.go` 里**。这是**我们第 6 集的加锁方式**：两个账户，**id 小的先锁，这样两个事务永远不会绕成圈互相等**。**我们的换汇要锁两个钱包，所以它需要同样的顺序和同样的代码**：**那个循环变成了一次调用**。

```go
// EP06 之前：transfer.go 里内联的一段
for _, id := range []uuid.UUID{fromID, toID} { ... }     // 排过序

// EP18：提取成函数，两条路径共用
if err := lockInOrder(ctx, q, from.ID, to.ID); err != nil { ... }
```

> `[14:29:36]` ...**now every path that locks two wallets goes through one place.**

> **译文**：……**现在每一条锁两个钱包的路径都经过同一个地方。**

💡 这是**"第二个用户出现时才提取"**的教科书时刻，和 §0 的 exponent 表**完全同构**：

| | 第一次出现 | 第二次出现 | 做法 |
|---|---|---|---|
| exponent | EP05/EP13（`if JPY`） | EP18（KWD=3） | **变成表** |
| `lockInOrder` | EP06（内联在 transfer） | EP18（fx 也要锁两个钱包） | **变成函数** |

> **"三次法则"的实用版本是两次**：当第二处需要同一段逻辑时，提取。**早于两次是猜测，晚于两次是复制。**

而它的价值在**死锁**这个场景上是决定性的：

```
转账：  锁 Alice → 锁 Bob
换汇：  锁 Alice 的美元 → 锁 Alice 的欧元
        （两个不同的钱包，但 id 顺序必须一致）
```

**如果换汇的锁顺序不按 id**（比如"先锁卖出的、再锁买入的"），那么：

```
T1: 换汇 A 锁 USD_wallet(5)
T2: 转账  锁 wallet(3) → 想锁 wallet(5)   ← 等 T1
T3: 换汇 A 想锁 EUR_wallet(3)              ← 等 T2
        → 死锁（40P01）
```

> `[14:29:55]` **notice the quote's row is locked first, before any wallet, and nothing else ever locks a quote, so that can't form a cycle either.**

> **译文**：**注意报价那一行是**最先**被锁的，在任何钱包之前，而没有别的东西会锁报价，所以那也不会形成环。**

💡 这句是**死锁分析里最容易被忽略的一步**：你不能只保证"钱包之间的顺序一致"，还要保证**"钱包和其他东西之间的顺序一致"**。

```
锁的顺序（全部路径）：  fx_quotes  →  accounts（按 id 升序）
```

**只要所有事务都遵守这个全序，就不可能成环。** 这是一个**偏序扩展成全序**的技巧：

> **死锁的充分条件是"存在一个环"。只要你给所有锁一个全局全序、并且每个事务都按序获取，环就不可能存在。**
>
> 这就是为什么数据库教材里说"按固定顺序加锁"——它有一个**可以证明的**正确性，而不只是"经验上有效"。

---

## 12. 那个"静默丢掉字段"的 bug

这是本集**最值得单独讲的一段工程教训**。

> `[14:22:34]` it gets **a field `fx` with its FX settings**. And **here's a subtle one**: `WithTx` **built a new `Service` by listing its fields: `store` and `users`** — **with a third field `fx` that it silently dropped**, so **the service acting for a user couldn't quote anymore**.

> **译文**：它拿到**一个 `fx` 字段，装它的 FX 配置**。而**这里有一个微妙的问题**：`WithTx` **通过列出字段来构造一个新的 `Service`：`store` 和 `users`**——**而第三个字段 `fx` 被它静默地丢掉了**，于是**那个"以用户身份行事"的服务再也不能报价了**。

代码形态（问题版）：

```go
// EP07 写的
func (s *Service) WithTx(tx pgx.Tx) *Service {
	return &Service{store: s.store.WithTx(tx), users: s.users}   // ← 手写字段列表
}
```

EP18 加了第三个字段 `fx`：

```go
type Service struct {
	store *Store
	users Users
	fx    FXSettings        // ← 新加的
}
```

于是 `WithTx` 返回的 `Service` **`fx` 是零值**。

> `[14:22:50]` ...**so now they copy the whole service, and change just the one field**:

> **译文**：……**所以现在他们复制整个 service，只改那一个字段**：

```go
// 修复版
func (s *Service) WithTx(tx pgx.Tx) *Service {
	c := *s                     // 复制全部字段
	c.store = s.store.WithTx(tx) // 只改一个
	return &c
}
```

💡 **这是一个极其常见的 Go bug**，而且**编译器不会提醒你**：

| | 手写字段列表 | 复制结构体 |
|---|---|---|
| 加新字段 | **静默丢失** ❌ | 自动带上 ✅ |
| 字段改名 | 编译错误 ✅ | 编译错误 ✅ |
| 可读性 | 高（一眼看到构造了什么） | 中（需要知道有个新副本） |
| 指针/共享字段 | 明确 | **需要小心**（浅拷贝——切片/map 会共享） |

**为什么"静默丢失"这么危险？** 因为**它不会崩溃**：

```
换汇接口 → WithTx(以用户身份行事) → fx 字段为零值
→ QuoteTTL = 0，FeeBps = 0
→ 报价立刻过期（0 秒）？或者费率变成 0（免费换汇！）
```

> **零值 `FeeBps = 0` 意味着手续费为 0。** 如果测试没覆盖"以用户身份的路径"，**这个 bug 会直接变成收入损失**。

**这暴露了一个通用的架构风险**：

> **`WithTx` 这种"包装并替换一个字段"的方法，天然容易在字段增加时失配。**
>
> 因为它是**手动的手工复制**，而不是**类型系统保证的**。

**能不能让编译器保证？** 在 Go 里没有完美方案，但有几个选择：

| 方案 | 效果 |
|---|---|
| `c := *s; c.store = ...` | **最好**：不会漏 |
| 用接口而不是结构体 | 会强制实现所有方法，但**不保证字段** |
| `WithTx` 返回 `(*Store, error)` 而不是包装 Service | 消灭这个模式本身 |
| 加一个测试：`WithTx(x).fx == s.fx` | 兜底，但需要想到 |

> 作者选了第一种，并**在讲义里明确说了这件事**。这比"悄悄改掉"有价值得多——**它让读者知道"加字段时要检查所有手写字段列表的地方"**。

💡 **给你的行动项**：如果你的 Go 代码里有 `&T{...}` 这种**手写全字段**的构造，那么每次给 `T` 加字段时，**`grep` 一下所有构造点**。

```bash
rg '&Service\{' --type go
```

**这就是"Go 没有默认值陷阱"的另一面：零值很安全，但"漏掉一个字段"很安静。**

---

## 13. `sqlc` 配置：把 `int64` 变成 `fx.Rate`，把时间运算交给 Postgres

```yaml
overrides:
  - db_type: "pg_catalog.int8"
    go_type: "github.com/fiston-user/payments/internal/fx.Rate"
    column: "fx_quotes.rate"
```

> `[14:21:33]` in `sqlc.yaml`, two things: **`fx` is an initialism, so the model is called `FXQuote`, in capitals — the `go` away** — and **an override: the rate column comes out as our `fx.Rate`, not a bare `int64`. pgx scans a `bigint` straight into it, because its underlying type is `int64`.**

> **译文**：在 `sqlc.yaml` 里，两件事：**`fx` 是一个首字母缩写，所以模型叫 `FXQuote`，大写——那个 `go` 去掉**——以及**一个 override：rate 那一列出来的是我们的 `fx.Rate`，而不是裸的 `int64`。pgx 能把 `bigint` 直接扫进它，因为它的底层类型是 `int64`。**

💡 `go_type` override 的**价值**在于**让类型信息跨过生成边界**：

```
没有 override：  Rate int64（生成的模型）
                 ↓ 需要手动转换
                 quote.Rate → fx.Rate(quote.Rate)     ← 每处都写
```

```
有 override：    quote.Rate 直接就是 fx.Rate
                 → Convert(..., quote.Rate, ...)      ← 不用转
```

**为什么这很重要？** 因为如果它是裸 `int64`，那么：

```go
fx.Convert(amount, "USD", "EUR", quote.Rate, fx.Down)
                                 ^^^^^^^^^^ 类型错误，编译不过
```

你会被迫写 `fx.Rate(quote.Rate)`——**而这个转换是"我没有检查它是否有效"的通行证**。`ParseRate` 里那个 `n == 0` 的检查，就被这种转换绕过了。

> **类型别名 `type Rate int64` 的保护是"提示性"的，不是"强制性"的**（因为显式转换总是可以）。但**每次都多写一个转换，就是在提醒你"这里有一个有效性约束"**。
>
> 而 `sqlc` 的 override 让**这个提醒出现在正确的地方**：列定义处，而不是每个使用处。

💡 注意 "`fx` is an initialism, so the model is called `FXQuote`, in capitals — the `go` away" 是 whisper 的错听，应该是 "**the `Fx` goes away**"：

```
默认：FxQuote（sqlc 只把首字母大写）
配置：FXQuote（fx 是 acronym，全部大写）
```

**这是 Go 的命名惯例**（`HTTPServer` 而不是 `HttpServer`），而 `sqlc` 允许你配置。

### `expired` 是一个 Postgres 算出来的 bool

> `[14:22:19]` ...**one more field: `expired`, a plain bool computed by Postgres.**
> **译文**：……还有**一个字段：`expired`，一个由 Postgres 算出来的普通 bool**——**Go 里完全没有时区运算**。

```sql
-- name: LockQuote :one
SELECT *, (expires_at <= now()) AS expired
FROM fx_quotes
WHERE id = @id AND owner_id = @owner_id
FOR UPDATE;
```

💡 这一行里的 `AS expired` 让 **Go 侧一个时间比较都没有**：

```go
case quote.Expired:              // 而不是 time.Now().After(quote.ExpiresAt)
	return ErrQuoteExpired
```

**三个好处**：

1. **一个时钟**（§9 已讲）
2. **不用处理时区**（`timestamptz` 在 Postgres 里，Go 里根本不用出现 `time.Time` 比较）
3. **测试可以只关心 bool**——`fx_test.go` 里那个"过期"测试不需要 mock 时钟

> 第 3 点尤其重要：**把时间逻辑推到数据库，测试就变简单了**（§17 会看到 "a sleep in a test is usually a smell" 的例外）。

---

## 14. 事件：sold / fee / bought 分开

> `[14:30:11]` a new type, **`ConversionCompleted`, version 1**. Its data: **the transaction, the quote, both wallets, what was sold, the fee, what was bought, and the rate — which goes out as a string, thanks to `MarshalText`**.

> **译文**：一个新类型，**`ConversionCompleted`，version 1**。它的数据：**事务、报价、两个钱包、卖出了什么、手续费、买到了什么，以及汇率——它作为字符串出去，多亏 `MarshalText`**。

> `[14:30:29]` **`sold`, `fee` and `bought` are separate, so a consumer never has to work the fee out from a rate.** Nothing consumes it yet; **it's there for notifications, for webhooks, and for the reconciliation job in episode 20.**

> **译文**：**`sold`、`fee` 和 `bought` 是分开的，所以消费者永远不需要从汇率里反算手续费。** 现在还没有东西消费它；**它是为通知、webhook，以及第 20 集的对账任务准备的。**

💡 这是 EP11 那条规则（"事件里放**事实**，不放**推导**"）的又一次应用：

```go
// ❌ 消费者会这么写（容易写错）
fee := amount * bps / 10000        // bps 从哪来？舍入方向是什么？

// ✅ 我们发的是
Sold: 10000, Fee: 50, Bought: 9215, Rate: fx.Rate(9215000000)
```

**为什么"分开"比"少发几个字段"更好**：

| 理由 | 说明 |
|---|---|
| **舍入方向是内隐知识** | 消费者不知道是 Up 还是 Down |
| **费率会变** | 三年后回放这个事件，用**今天的** bps 算 → **算错** |
| **事件是不可变的** | 发了就不能改，**所以发的时候就该是终态** |

> **"事件里的每个金额都应该是已确定的终态。"** 任何需要"用当前配置再算一遍"的字段，都是**未来的 bug**。

### 汇率作为字符串

```go
Rate fx.Rate `json:"rate"`      // MarshalText → "0.9215"
```

💡 这就是 §3 那个 `MarshalText` 的**实际用途**。看一下事件的 JSON：

```json
{
  "sold": 10000,
  "fee": 50,
  "bought": 9215,
  "rate": "0.9215"
}
```

**注意 `sold`/`fee`/`bought` 是数字，而 `rate` 是字符串。** 看起来不一致，但**这是对的**：

| 字段 | 语义 | 编码 |
|---|---|---|
| `sold` | **整数**个最小单位 | JSON number（整数，double 精确到 2^53） |
| `bought` | 同上 | JSON number |
| `rate` | **小数**（10 位精度） | **JSON string** |

> **判据是"这个值是不是整数"**：整数在 JSON 里安全（只要 < 2^53），小数不安全。**所以只有小数需要变成字符串。**

---

## 15. 现场：trial balance 和头寸

调试到这一步，用 `psql` 直接看账本：

> `[14:41:20]` now **let's look at the ledger itself**, with `psql`. First **the entries of that last conversion**, by the transaction id pasted from the response: **six entries** — **Alice's dollar wallet, debited twice** (the conversion, and the fee), **our FX account in dollars, credited; our FX account in euros, debited; Alice's euro wallet, credited; and the fee, credited to `fx_fees`**.

> **译文**：现在**看账本本身**，用 `psql`。先看**最后一次换汇的分录**，用从响应里粘出来的事务 id：**六笔分录**——**Alice 的美元钱包，被借了两次**（换汇和手续费）、**我们的美元 FX 账户，被贷；我们的欧元 FX 账户，被借；Alice 的欧元钱包，被贷；以及手续费，贷到 `fx_fees`**。

> `[14:41:55]` **the trial balance: debits and credits per currency, across the whole ledger — equal in dollars, and equal in euros. Each currency balances on its own, exactly as on the slide, for every transaction we've ever posted.**

> **译文**：**试算平衡表：按货币统计整个账本的借方和贷方——美元相等，欧元也相等。每种货币各自平衡，和幻灯片上完全一样，对我们曾经记过的每一笔交易都成立。**

```sql
SELECT currency, 
       sum(CASE WHEN direction='debit'  THEN amount ELSE 0 END) AS debits,
       sum(CASE WHEN direction='credit' THEN amount ELSE 0 END) AS credits
FROM entries
GROUP BY currency;
```

```
 currency | debits  | credits
----------+---------+---------
 EUR      |  ...    |  ...      ← 相等
 GBP      |  ...    |  ...
 JPY      |  ...    |  ...
 USD      |  ...    |  ...      ← 相等
```

💡 **这个查询为什么重要？** 它是**复式记账最本质的检验**：

> **如果全世界所有账户的余额加起来不等于零，那么这个账本一定错了。**

而按货币分组之后，它变成**每种货币各自的守恒律**：

```
∀ currency c:  Σ debits(c) = Σ credits(c)
```

**这条不变式覆盖了所有历史**（不只是这次换汇），所以**任何一次记账错误都会让它失败**。

> 这就是为什么 §17 的测试里 `checkbooks` 在**每个测试结束时**都跑——**它是一个 O(全表) 的断言，但它抓住了所有类别。**

### 头寸

> `[14:42:28]` and **the house's accounts**: `[14:42:44]` **FX in dollars: 154.26 we've taken in; FX in euros: −142.15, the euros we've paid out; and 78 cents of fees. That's our FX position, straight off the ledger.**

> **译文**：还有**这家公司的账户**：**美元 FX：我们收进了 154.26；欧元 FX：−142.15，是我们付出的欧元；以及 78 分的手续费。那就是我们的 FX 头寸，直接从账本上读出来。**

> `[14:43:03]` **and the rounding is in there too: 54.26 was worth a little more than 50 euros, and that fraction of a cent sits in our FX accounts — not lost, and not invented.**

> **译文**：**舍入的残差也在里面：54.26 比 50 欧元值多一点点，而那零点几分钱坐在我们的 FX 账户里——没有丢失，也没有被凭空造出来。**

💡 "**not lost, and not invented**"（没有丢失，也没有被凭空造出来）是**复式记账对舍入残差的承诺**：

```
如果你把零头"丢掉"（不入账）：
  → 借方 ≠ 贷方 → 账不平 → 触发器报警（或者悄悄错）
如果你把零头"吞进"某个账户但没有分录：
  → 同上
正确做法：零头必须有分录，所以它一定在某个账户里
```

**这就是为什么 "四笔 + 两笔" 的分录里，`buy_amount` 和 `sell_amount` 都是**报价时算好并存下来的**，而不是**记账时重算的**：

> **算一次、存下来、记这个数** —— 如果你在记账时重算，**两处的舍入可能不同**，于是**账不平**。

`[14:19:29]` 那句 "the rate as a bigint of ten-billionths... the currency and amount bought with checks" 就在说这件事：**quote 存的是"已经决定好的金额"，记账只是把它们搬进分录。**

---

## 16. 测试：table tests 是"舍入政策"的可执行版本

> `[14:12:12]` the **table tests** in `fx_test.go`, **in package `fx_test`, so they use the package exactly the way everyone else will.**

> **译文**：**table tests** 在 `fx_test.go` 里，**放在 `fx_test` 包里，这样它们用这个包的方式和别人完全一样。**

💡 `package fx_test`（外部测试包）是一个**刻意的选择**：

| | `package fx`（内部） | `package fx_test`（外部） |
|---|---|---|
| 能访问未导出标识符 | ✅ | ❌ |
| 强制只用公开 API | ❌ | ✅ |
| 能测内部实现细节 | ✅ | ❌ |

**选外部包 = "我承诺只用导出的 API 就够测了"。** 如果哪天测试需要 `one` 常量，那说明**API 缺了什么**。

> EP04 的 `config_test` 也是这么做的（"so we only use the exported API"）。**同一个选择出现三次，就是模式。**

```go
tests := []struct {
	amount      int64
	from, to    string
	rate        string
	rounding    fx.Rounding
	want        int64
}{
	{10000, "USD", "EUR", "0.9215", fx.Down, 9215},   // 恰好
	{1000,  "USD", "EUR", "0.9215", fx.Down, 921},    // 921.5 → 下
	{1000,  "USD", "EUR", "0.9215", fx.Up,   922},    // 921.5 → 上
	{1000,  "USD", "JPY", "151.37", fx.Down, 1513},   // 1513.7，日元无小数
	{100000, "JPY", "USD", "0.0066063", fx.Down, 660},
	{1,     "JPY", "USD", "0.0066063", fx.Down, 0},   // 一日元买不到一分
	{10000, "USD", "KWD", "0.30710", fx.Down, 3071},  // 三位小数
	{100000000, "USD", "JPY", "151.37", fx.Down, ...} // 乘积超 int64
}
```

> `[14:14:53]` **those rows are the rounding policy, written as tests. If anyone ever changes a rule, a row turns red and the conversation happens before the change ships.**

> **译文**：**那些行就是舍入政策，写成测试。如果哪天有人改了一条规则，一行会变红，而对话发生在改动上线之前。**

💡 **"the rounding policy, written as tests"** 是本集最实用的一句话。对比一下：

```
❌ 文档里写："我们向上取整收取，向下取整付出"
   → 三年后新人改了 Convert 的实现 → 文档没人看 → 静默改变

✅ 测试里写：{1000, USD→EUR, Up, 922}, {1000, USD→EUR, Down, 921}
   → 三年后新人改了 → 测试红 → 他必须来问你
```

**测试是唯一一种"会主动反对你的文档"。**

### 那个"比行更有价值"的检查

> `[14:14:02]` then **a check that's worth more than the rows: the cost buys enough, and one cent less doesn't — so `Cost` is never too cheap and never too expensive.**

> **译文**：然后**一个比那些行更有价值的检查：cost 买得到足够的量，而少一分就买不到——所以 `Cost` 既不会太便宜，也不会太贵。**

```go
// 换出 >= 客户要的
got, _ := fx.Convert(cost, from, to, rate, fx.Down)
if got < want { t.Errorf("cost too cheap: %d buys %d, want %d", cost, got, want) }

// 少一分就换不到
got2, _ := fx.Convert(cost-1, from, to, rate, fx.Down)
if got2 >= want { t.Errorf("cost too expensive: %d buys %d", cost-1, got2) }
```

💡 这是**性质测试（property test）**，而不是**例子测试（example test）**：

| | 例子测试 | 性质测试 |
|---|---|---|
| 断言 | `Cost(5000) == 5426` | `Convert(Cost(x)-1) < x <= Convert(Cost(x))` |
| 覆盖 | **一个点** | **一个性质的所有点** |
| 抓 bug | 手算错一个数就放过 | **任何方向错都抓** |
| 可读性 | 高 | 需要想一下 |

**这两行合起来，正好定义了 `Cost` 的语义边界**：

```
Convert(Cost(B) - 1) < B  <=  Convert(Cost(B))
        ↑                          ↑
    少付一分不够            付这个刚好够
```

**任何"最小足够金额"的定义都可以这样写成两条断言。** 这个模式值得记住。

### 真实时钟的那个例外

> `[14:36:26]` `TestConvertRefuses`: with quotes that **expire in 50 milliseconds**. Someone else trying to use it → **not found, because to them it doesn't exist**. Then **wait 100 milliseconds**, and the owner's own conversion is refused → **expired**. **A sleep in a test is usually a smell; here, the clock is the database's, which we can't fake, so a tiny TTL is the honest way to test it.**

> **译文**：`TestConvertRefuses`：报价 **50 毫秒后过期**。别人试图用它 → **not found，因为对他来说它不存在**。然后**等 100 毫秒**，所有者自己的换汇被拒 → **expired**。**测试里的 sleep 通常是一种坏味道；但这里，时钟是数据库的，我们没法伪造，所以一个极小的 TTL 是诚实的测试方式。**

💡 这段话值得逐句拆：

**① "a sleep in a test is usually a smell"** —— 因为 `sleep` 让测试**慢且不稳定**。

**② "here, the clock is the database's, which we can't fake"** —— 这是 §9 那个决策的**代价**：

> 把时间推到数据库 → 换来"一个时钟" → **但失去了"可以在测试里冻结时间"的能力**。

**③ "a tiny TTL is the honest way"** —— 所以用 **50ms** 而不是 30 秒。

**这是一个完整的取舍闭环**：

```
决策：用数据库时钟（正确性）
代价：测试里没法冻结时间
应对：把 TTL 做成参数，测试里传 50ms
```

> **"把时间做成参数"是设计的一个必需要求**，否则你**根本没法测过期逻辑**。
>
> 而这里 `TTL` 来自 `s.fx.QuoteTTL`（配置），测试里直接塞一个 50ms。**配置化在这里的第二个好处就是可测性。**

**④ "not found, because to them it doesn't exist"** —— 这条断言验证的是 **§8 里 `LockQuote` 的 `owner_id` 条件**：

```sql
WHERE id = @id AND owner_id = @owner_id
```

别人的 quote **查不到** → `pgx.ErrNoRows` → `ErrQuoteNotFound` → **404**（而不是 403）。

> 和 EP05 的 settlement 账户一样：**"不存在"和"不是你的"在响应上必须一样**，否则就是一个存在性探测漏洞。

---

## 17. 并发测试：10 个请求抢一个报价

> `[14:35:33]` **convert once**: one quote, and **10 requests for it, at the same moment, with our `concurrently` helper**. **Exactly one converts, and nine find it used.** **That's the row lock and the check doing their job under real concurrency.**

> **译文**：**换一次**：一个报价，**10 个请求同时打它，用我们的 `concurrently` helper**。**恰好一个换成，九个发现它已使用。** **那就是行锁和检查在真实并发下各司其职。**

💡 这是 **EP06 的 `concurrently` helper 的第四次复用**（EP06 转账、EP07 幂等风暴、EP12 saga claim、EP18 报价）。**它已经是一个平台工具了。**

而这个测试的价值在于它**测试了一个不可能用单线程验证的性质**：

```
单线程测试：Convert(quote) 两次 → 第二次 422 used     ← 只测了顺序执行
并发测试  ：10 个 goroutine 同时 Convert(quote)
            → 1 个成功，9 个 422 used                 ← 测了 "同一时刻"
```

**"同一时刻"才是 `FOR UPDATE` 存在的原因。** 顺序执行的测试**根本不会触发锁**。

> **判据：如果你的代码里有锁/事务隔离/CAS，那么没有并发测试就等于没测。**

### `checkbooks`：免费的全账本断言

> `[14:35:51]` ...then the balances: **399.50 in dollars, and 92.15 in euros**. And **notice what we don't check here: that every currency balances. We don't need to — since episode 15, every test in this package ends with `checkbooks`, which fails if any currency's debits and credits differ anywhere in the ledger.** **Every conversion, every test makes, gets checked for free.**

> **译文**：……然后是余额：**美元 399.50，欧元 92.15**。而**注意我们这里没检查什么：每种货币是否平衡。我们不需要——从第 15 集起，这个包里的每个测试都以 `checkbooks` 结尾，只要账本里任何地方的任何货币借贷不等，它就失败。** **每一个换汇、每一个测试产生的记账，都被免费检查了。**

💡 这是**测试基础设施的复利**：

```
写 checkbooks 的成本：一次，约 30 行（EP15）
每次使用的成本：一行
收益：所有测试 × 所有历史交易 的账本一致性
```

**关键在于它是"全局断言"而不是"局部断言"**：

| | 局部断言 | `checkbooks`（全局） |
|---|---|---|
| 检查范围 | 这一次换汇的分录 | **整个账本，所有货币** |
| 能抓到的 bug | 算错金额 | 算错金额 + **漏一笔分录** + **币种错位** + **旧测试留下的脏数据** |

> **"漏一笔分录"这类 bug，局部断言抓不到**（因为你没检查"应该有几笔"）。而全局平衡一定抓得到——**少一笔就必然不平**。

**这就是复式记账作为"可测试性设计"的价值**：它把"数据正确"变成了一个**O(1) 可验证的断言**（求和比较）。

---

## 18. HTTP 层：两条路由，一层复用

```go
// internal/wallet/http.go
mux.Handle("POST /v1/fx/quotes",      ...)      // 报价 → 201
mux.Handle("POST /v1/fx/conversions", ...)      // 换汇 → 201
```

> `[14:31:01]` ...**a response type for quotes: what sold and bought, as money, the fee, the rate, and when it expires — and the transaction id, left out when it's empty.** **A conversion is a used quote, so the same type serves both.**

> **译文**：……**一个报价的响应类型：卖了什么、买了什么、以 money 表示、手续费、汇率、什么时候过期——以及 transaction id，在它是空的时候省略**。**一次换汇就是一个已使用的报价，所以同一个类型服务两个接口。**

💡 **一个类型服务两个端点**，判据是"**它们的差别只是一个可选字段**"：

```json
// POST /v1/fx/quotes 的响应
{ "id":"0190f3...", "sell":{...}, "buy":{...}, "fee":{...}, "rate":"0.9215",
  "expires_at":"...", "transaction_id": null }        ← 省略

// POST /v1/fx/conversions 的响应
{ ...同上..., "transaction_id":"0190f4..." }          ← 有值
```

> **"a conversion is a used quote"** 这句话是**领域洞察**，不是技术观察。它让两个端点的响应**天然同构**。
>
> 如果分开定义两个类型，你会写两遍 7 个字段，然后**有一天它们会不一致**。

### `idempotency` 的复用

> `[14:31:35]` and `convert`: **it decodes the quote's id, and runs through `idempotent`, our helper from episode 7**. **With an idempotency key, a retry of the same request gets the same response, stored with the conversion in the same transaction.**

> **译文**：而 `convert`：**它解码报价的 id，然后走 `idempotent`——我们第 7 集的 helper**。**带一个幂等键，同一个请求的重试会拿到同一个响应，而那个响应和换汇在同一个事务里被存下来。**

💡 这是**平台化的红利**：

```go
// EP18 的 handler（简化）
w, ok := idempotent(w, r, store, func(ctx context.Context) (any, error) {
	return svc.Convert(ctx, owner, quoteID)
})
```

**`idempotency` 这个 helper 在 EP07 是为"存款和转账"写的，现在第三次复用（deposit / transfer / convert）。**

> **一个机制被复用的次数，是它抽象得好不好的最直接证据。** 而这里它**一行都没改**——因为它的接口是"给我一个函数，我帮你做幂等"，而不是"帮存款做幂等"。

> `[14:38:26]` ...and **as the idempotency key too** — **the quote's id is exactly the key it needs**.

> **译文**：……而且**也作为幂等键**——**报价的 id 正是它需要的那个键**。

💡 这是一个**很优雅的巧合**，值得说清为什么它成立：

| 需要的性质 | `quote_id` 提供吗 |
|---|---|
| 每次操作唯一 | ✅ 一个 quote 只对应一次换汇 |
| 客户端能拿到 | ✅ 上一响应里就有 |
| 重试用同一个 | ✅ 同一个 quote 只能换一次 |
| 不会被猜中/碰撞 | ✅ UUID v7 |

**所以客户端不需要"另外生成一个 UUID"**：

```http
POST /v1/fx/conversions
Idempotency-Key: 0190f3a2-...        ← 就是 quote id
{ "quote_id": "0190f3a2-..." }
```

> **"幂等键"的正确定义是"这个操作的身份"**，而**报价 id 天然就是"这次换汇的身份"**。
>
> EP07 里转账需要客户端自己生成 UUID，是因为"转账"没有别的天然身份。**而换汇有。**

---

## 19. Gateway：代理 REST，而不是加新的 gRPC

> `[14:32:59]` **the gateway talks to the wallet over gRPC for its own routes.** **Quotes and conversions only have one kind of caller, our users**, so **instead of new RPCs, the gateway proxies them to the wallet's REST API**, the way it proxies transfers and webhooks.

> **译文**：**网关对它自己的路由是通过 gRPC 和 wallet 说话的。** **报价和换汇只有一种调用者——我们的用户**，所以**不用新增 RPC，网关把它们代理到 wallet 的 REST API**，就像它代理转账和 webhook 那样。

```go
// cmd/gateway/config.go
WalletAPIURL string        // 默认 http://localhost:8081

// internal/gateway/gateway.go
mux.Handle("/v1/fx/", proxy(cfg.WalletAPIURL))     // 走 token 校验 + 每用户限流
```

💡 这条决策的判据是 **"谁是调用者"**：

| 端点 | 调用者 | 用 gRPC 还是 REST |
|---|---|---|
| 余额查询 | **gateway 自己**（要聚合、要转换格式） | gRPC（强类型、快） |
| 转账创建 | **gateway 自己**（要编排幂等、映射状态码） | gRPC |
| **报价/换汇** | **只有用户**（gateway 只是转手） | **REST 代理** |

> **差别在于"网关要不要理解这个请求"**：
> - 如果网关要**读字段、改字段、组合多个调用** → gRPC（有类型）
> - 如果网关只是**透传** → REST 代理（零代码）

**为什么不做成 gRPC？** 因为那需要：wallet 写 proto、生成代码、gateway 写映射、**而且每次加一个字段都要两边改**。

> **"透明代理"是网关最便宜的能力**：加一条 `mux.Handle` 就完了。

而 `[14:33:15]` 那句 "**behind the token check and the rate limit per user**" 说明了**代理不是"绕过"**：**鉴权和限流在网关这层照样生效**。

---

## 20. 一页总结

### 本集建立的七条规则

| # | 规则 | 为什么 |
|---|---|---|
| 1 | **exponent 从 ISO 4217 查表** | 日元 0 位、第纳尔 3 位 |
| 2 | **汇率是 `int64`，10 位小数** | `float64` 存不下 0.9215 |
| 3 | **乘积走 `math/big`** | 10^20 会静默溢出 `int64` |
| 4 | **付出向下、收入向上** | 单笔交易没有"长期平均" |
| 5 | **报价存服务端、30 秒、一次性** | 客户端回传条款 = 可被篡改 |
| 6 | **换汇四笔 + 手续费两笔** | 每种货币必须各自平衡 |
| 7 | **FX 住在 wallet 里** | 独立服务 = 一个 saga 换一个事务 |

### 四个"旧代码收了新账"

| EP | 当时写了什么 | EP18 用在哪 |
|---|---|---|
| **EP02** | balance trigger 按货币分组 | **两笔分录的换汇被拒绝** |
| **EP02** | `entries.currency` 外键校验账户币种 | **欧元不可能落进美元钱包** |
| **EP06** | `lockInOrder`（按 id 升序） | **换汇锁两个钱包不死锁** |
| **EP07** | `idempotent` helper | **换汇的重试返回同一响应** |

> **这四条里，有两条从来没被"为了 EP18"设计过。**
>
> 它们当初只是**遵守了一条通用规则**（复式记账、固定加锁顺序），而**通用规则的回报是延后支付的**。

### 值得背下来的三句

> `[13:54:36]` **"In a payment system, almost every word of that sentence hides a bug."**
> **译文**：在一个支付系统里，那句话几乎每个词背后都藏着一个 bug。

> `[14:00:24]` **"That's a decision, and we write it down in the code, which is the part most systems forget."**
> **译文**：那是一个决定，而我们把它写在代码里——这正是大多数系统忘记的部分。

> `[14:02:18]` **"That's a lot of machinery for something one transaction does perfectly."**
> **译文**：为了一个单事务就能完美完成的事，这是一大堆机械。

---

## 21. 自己动手

```bash
# 1. 纯数学部分，不需要 Postgres
go test ./internal/fx/ -race -v
#    看那些 table 行：921.5 向下是 921、向上是 922

# 2. 自己验证一遍浮点的坑
cat > /tmp/f.go <<'EOF'
package main
import "fmt"
func main() {
	fmt.Printf("%.20f\n", 0.9215)
	fmt.Printf("%d\n", int64(1.15*100))
}
EOF
go run /tmp/f.go
#    → 0.92149999999999998668
#    → 114

# 3. SQL 里看十进制/浮点的差别
psql -c "SELECT 0.9215::decimal, 0.9215::float8, (0.9215::float8)*1000000000;"

# 4. 跑起来，走一遍 gateway
#    api/fx.http 里是一整个流程：报价 → 换汇 → 重试 → 重放 → 过期
open api/fx.http

# 5. 最关键的一步：自己验证账本
psql -c "SELECT currency,
                sum(CASE WHEN direction='debit' THEN amount ELSE 0 END) AS d,
                sum(CASE WHEN direction='credit' THEN amount ELSE 0 END) AS c
         FROM entries GROUP BY currency;"
#    每种货币 d == c，一行都不能差

# 6. 头寸
psql -c "SELECT name, currency, balance FROM account_balances
         WHERE name IN ('fx','fx_fees') ORDER BY name, currency;"
```

### 三个可以拿去问自己的问题

1. **如果把 `Convert` 里的 `math/big` 换回 `int64` 乘法**，什么时候会出错？（提示：`MaxAmount` = 10^8 分，乘以 USD→JPY 的 `151.37×10^10` ≈ **1.5×10^20**，远超 `9.2×10^18`；而 JPY→USD 方向只有 6.6×10^17，恰好不出错——**所以溢出只在某些方向上发生**，这才是最坑的地方）
2. **如果 `fx_quotes` 少存 `buy_amount`、记账时重算**，会发生什么？（提示：两次舍入可能不同 → 账不平）
3. **为什么 `Cost` 定义成"最小足够金额"，而不是"`Convert` 的逆运算"？**（提示：逆运算不是函数——一个金额可能对应多个源金额）

---

## 22. 下一集

> `[14:45:12]` our wallets **now speak more than one currency**, and **not a cent goes missing between them**. Next time: **we stop money that shouldn't move — fraud and risk checks, velocity limits in Redis, a small rules engine, risky transfers held as pending instead of going through, and manual review states, so a human can approve or decline them.**

> **译文**：我们的钱包**现在会说不止一种货币**，而且**没有一分钱在它们之间丢失**。下一次：**我们拦住不该动的钱——欺诈与风险检查、Redis 里的速度限制、一个小规则引擎、把有风险的转账挂成 pending 而不是直接放行，以及人工审核状态，让人可以批准或拒绝它们。**

💡 EP19 会**第一次**让一笔转账**停下来等人**。这意味着 EP12 的状态机要加**"需要人来决定"的状态**——而这一类状态会带来一个 EP12 没处理过的问题：

> **人的反应时间是几个小时，而 saga 的 claim lease 是 10 秒。**
>
> 一个等待人工的转账**不能在 pending 里被反复 claim**——那会每秒打一次"还没决定"。
>
> 所以 EP19 必须重新审视 **"哪些状态要跑步骤，哪些状态只是等着"**。

**这是"状态机"和"工作队列"两个概念的分界点**，也是 EP19 最值得看的部分。
