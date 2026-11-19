# payments 课程笔记

这是 [`dev-marker/payments`](https://github.com/dev-marker/payments) 的私人笔记，
一个 **orphan 分支**（`notes`）：和代码历史完全无关，互不干扰。

## 为什么是这个结构

```
~/git/github.com/dev-marker/
├── payments/           # 代码 worktree：切 ep01..ep24、写实验代码
│   └── .git/           # 共享对象库（所有 worktree 共用这一份）
└── payments-notes/     # 笔记 worktree：orphan 分支 notes，只有 markdown
```

两个 worktree **共享同一个 `.git`**，所以：

- 笔记里写代码片段、`git log`、`git grep` 全部可用；
- 笔记的 commit 永远不会出现在代码分支上，代码分支也不会污染笔记；
- 不需要额外的 bare 仓库 —— 共享对象库这件事，worktree 已经替你做了。

## 远端

| remote | 仓库 | 用途 |
|---|---|---|
| `upstream` | `dev-marker/payments` | 作者的更新，只 fetch |
| `origin` | `phakeandy/payments` | 我的 fork，`git push` 默认去这里 |

同步作者更新：

```bash
git fetch upstream
git switch main && git merge --ff-only upstream/main   # 或 gh repo sync
```

## 文件

- `glossary.zh.md` —— 术语表。读注释卡住先查这个。
- `map.zh.md` —— 视频 24 集的带时间戳地图（19:42:46，123 个章节）。
- `tools/lecture.sh` —— 切片 + 转写流水线（`./lecture.sh list` 先看用法）。
- `tools/episodes.tsv` —— 每集起止时间，脚本读它。
- `media/ep01..24.txt` —— 全 24 集逐句转录（141,054 词，绝对时间戳）。

## 讲义进度（12 / 24）

每篇 ~500–1900 行。格式统一：**英文原句（带 `[h:mm:ss]`）+ 中文译文 + 💡 注解**。

| 集 | 文件 | 行数 | 主题 |
|---|---|---|---|
| 01 | `ep01-blueprint.md` | 426 | 五条规则、中间件顺序、优雅关闭 |
| 02 | `ep02-ledger.md` | 510 | 复式记账 schema、触发器 |
| 03 | `ep03-sqlc-pgx.md` | 527 | sqlc / pgx / 事务 / 集成测试 |
| 04 | `ep04-platform.md` | 556 | 配置、slog、request id、错误分层 |
| 05 | `ep05-wallet-api.md` | 624 | 最小单位、settlement 账户、keyset 分页 |
| 06 | `ep06-transfers.md` | 612 | 行锁、死锁 40P01、full jitter |
| 07 | `ep07-idempotency.md` | 601 | 幂等键、claim=lease |
| 11 | `ep11-outbox.md` | 637 | 双写、outbox、JetStream |
| 12 | `ep12-saga.md` | 699 | saga、hold/capture、版本号 |
| 13 | `ep13-notification.md` | 1379 | 至少一次投递、死信、CSV 之外的一切 |
| 18 | `ep18-fx.md` | 1653 | 精确十进制、舍入方向、四笔分录 |
| 20 | `ep20-reconciliation.md` | 1922 | 对账、选主、snapshot、CSV 报表 |

待写（批次 4 / 5）：08 09 10 14 15 16 17 19 21 22 23 24。

## 校验

```bash
# 每一条英文引用都必须有译文（应为 0）
python3 - <<'EOF'
import glob
for f in sorted(glob.glob("ep*.md")):
    L = open(f, encoding="utf-8").read().split("\n")
    n = sum(1 for i, l in enumerate(L)
            if l.startswith("> `[") and "译文" not in "\n".join(L[max(0,i-1):i+8]))
    if n: print(f, n)
EOF
```

## 视频转写

```bash
export LECTURE_URL="https://..."      # 或者写进 tools/url
cd tools
./lecture.sh one 11                    # 下第 11 集音频 + 转写成 srt
```

两个坑已经写进脚本了：本机 `~/.cache/huggingface/token` 里有个过期 token
（不关掉会 401）；另外默认节点（Vless）限速到 80KB/s，模型下载要切到
Hysteria2 节点才快。
