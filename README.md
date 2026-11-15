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
- `ep11-events.md` —— 逐集精读笔记（待写）。

## 视频转写

```bash
export LECTURE_URL="https://..."      # 或者写进 tools/url
cd tools
./lecture.sh one 11                    # 下第 11 集音频 + 转写成 srt
```

两个坑已经写进脚本了：本机 `~/.cache/huggingface/token` 里有个过期 token
（不关掉会 401）；另外默认节点（Vless）限速到 80KB/s，模型下载要切到
Hysteria2 节点才快。
