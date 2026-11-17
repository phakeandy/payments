#!/usr/bin/env python3
"""把 whisper 的 srt 清洗成带绝对时间戳的连续文本。

whisper 的 srt 有两个毛病：句子被切得太碎（每 3-6 秒一段），
以及开头常有一句重复/残句。这里合并句子，并把时间换算到视频时间轴。

    clean_srt.py <ep02.srt> <输出.txt> [偏移秒数]
"""
import re
import sys


def parse_srt(path):
    raw = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
    segs = []
    for block in re.split(r"\n\n+", raw.strip()):
        lines = [l for l in block.split("\n") if l.strip()]
        if len(lines) < 2:
            continue
        m = re.match(r"(\d+):(\d+):(\d+)[,.](\d+) --> ", lines[1])
        if not m:
            continue
        # 时间戳在 srt 里是相对切片起点的
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        segs.append((t, " ".join(lines[2:]).strip()))

    clean = []
    for t, txt in segs:
        if clean and clean[-1][1] == txt:
            continue
        clean.append((t, txt))
    return clean


def to_sentences(segs):
    out, buf, buf_t = [], "", None
    for t, txt in segs:
        if buf_t is None:
            buf_t = t
        buf += " " + txt
        if re.search(r'[.?!]["\')]?\s*$', txt):
            out.append((buf_t, re.sub(r"\s+", " ", buf).strip()))
            buf, buf_t = "", None
    if buf.strip():
        out.append((buf_t, re.sub(r"\s+", " ", buf).strip()))
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    offset = int(float(sys.argv[3])) if len(sys.argv) > 3 else 0
    sents = to_sentences(parse_srt(src))
    with open(dst, "w", encoding="utf-8") as f:
        for t, line in sents:
            a = t + offset
            f.write(f"[{a // 3600}:{a % 3600 // 60:02d}:{a % 60:02d}] {line}\n")
    words = sum(len(l.split()) for _, l in sents)
    print(f"{dst}: {len(sents)} 句, {words} 词")


if __name__ == "__main__":
    main()
