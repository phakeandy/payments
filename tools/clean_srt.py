#!/usr/bin/env python3
"""把 whisper 的 srt 清洗成带绝对时间戳的连续文本。

whisper 的 srt 有三个毛病：
1. 句子被切得太碎（每 3-6 秒一段）
2. 有时几乎不输出句号（ep01：338 段里只有 44 段以句末标点结尾），
   合并后会变成 48 秒一条的巨行
3. 开头常有一句重复/残句

这里：合并成句 → 过长的按逗号再切 → 时间戳按词数比例分摊到真实区间内。

    clean_srt.py <ep02.srt> <输出.txt> [偏移秒数]
"""
import re
import sys

PUNCT_END = re.compile(r'[.?!]["\')]?$')


def parse_srt(path):
    raw = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
    segs = []
    for block in re.split(r"\n\n+", raw.strip()):
        lines = [l for l in block.split("\n") if l.strip()]
        if len(lines) < 2:
            continue
        m = re.match(
            r"(\d+):(\d+):(\d+)[,.](\d+) --> (\d+):(\d+):(\d+)[,.](\d+)", lines[1]
        )
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2]
        end = g[4] * 3600 + g[5] * 60 + g[6]
        segs.append((start, end, " ".join(lines[2:]).strip()))

    # 去掉相邻重复（whisper 偶尔把同一句再吐一遍）
    clean = []
    for s, e, txt in segs:
        if clean and clean[-1][2] == txt:
            continue
        clean.append((s, e, txt))
    return clean


def to_sentences(segs):
    """按句末标点合并，返回 (start, end, text)。"""
    out, buf, start, end = [], "", None, None
    for s, e, txt in segs:
        if start is None:
            start = s
        end = e
        buf += " " + txt
        if PUNCT_END.search(txt):
            out.append((start, max(end, start), re.sub(r"\s+", " ", buf).strip()))
            buf, start, end = "", None, None
    if buf.strip():
        out.append((start, max(end or start, start), re.sub(r"\s+", " ", buf).strip()))
    return out


def split_long(start, end, text, limit=28):
    """过长的句子按逗号/分号切开，时间戳按词数比例分摊到 [start, end] 内。

    但有的集（ep04）whisper 一个逗号都不吐，靠逗号切会整集变一行，
    所以再加一条硬限：超过 2*limit 词就按词边界强制切。
    """
    words = text.split()
    if len(words) <= limit:
        return [(start, text)]

    pieces, cur = [], []
    for w in words:
        cur.append(w)
        if len(cur) < limit:
            continue
        if w.endswith((",", ";", ":")) or len(cur) >= 2 * limit:
            pieces.append(" ".join(cur))
            cur = []
    if cur:
        pieces.append(" ".join(cur))
    if len(pieces) == 1:
        return [(start, text)]

    total = sum(len(p.split()) for p in pieces)
    out, acc = [], 0
    for p in pieces:
        out.append((start + (end - start) * acc // max(total, 1), p))
        acc += len(p.split())
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    arg = sys.argv[3].strip() if len(sys.argv) > 3 else ""
    offset = int(float(arg)) if arg else 0  # 空串不能崩：上游算错时按 0 处理

    lines = []
    for s, e, text in to_sentences(parse_srt(src)):
        lines.extend(split_long(s, e, text))

    lines.sort(key=lambda x: x[0])  # 分摊后保证时间严格不减
    with open(dst, "w", encoding="utf-8") as f:
        for t, line in lines:
            a = t + offset
            f.write(f"[{a // 3600}:{a % 3600 // 60:02d}:{a % 60:02d}] {line}\n")
    print(f"{dst}: {len(lines)} 句, {sum(len(l.split()) for _, l in lines)} 词")


if __name__ == "__main__":
    main()
