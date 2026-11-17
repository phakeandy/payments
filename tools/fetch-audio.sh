#!/usr/bin/env bash
# 并行 Range 下载器。
#
# 为什么需要它：yt-dlp 的原生下载器被 YouTube 限流到 ~20KB/s，
# 但对同一个 googlevideo 直链发带 Range 的 curl 请求能跑到 1.7MB/s。
# 所以：用 yt-dlp 只负责"取出直链"，真正搬字节用这里。
#
#   ./fetch-audio.sh <url文件> <输出文件> [块数] [并发数]

set -euo pipefail

URLFILE=${1:?用法: fetch-audio.sh <url文件> <输出文件> [块数] [并发数]}
OUT=${2:?}
CHUNKS=${3:-48}
PAR=${4:-6}

URL=$(tr -d '\n' <"$URLFILE")
[ -n "$URL" ] || { echo "URL 文件是空的" >&2; exit 1; }

SIZE=$(curl -sS -L --max-redirs 5 -D - -o /dev/null -r 0-1023 "$URL" | tr -d "\r" |
	awk 'tolower($1) == "content-range:" { split($3, a, "/"); print a[2] }')
[ -n "${SIZE:-}" ] && [ "$SIZE" -gt 0 ] 2>/dev/null || { echo "拿不到文件大小（直链可能已过期，重跑 yt-dlp -g）" >&2; exit 1; }

CS=$(((SIZE + CHUNKS - 1) / CHUNKS))
TMP=$(mktemp -d)
echo "总大小 $((SIZE / 1024 / 1024)) MB，分 $CHUNKS 块（每块 ~$((CS / 1024 / 1024)) MB），$PAR 并发" >&2

export URL CS SIZE TMP
seq 0 $((CHUNKS - 1)) | xargs -P "$PAR" -I{} bash -c '
	i={}
	start=$((i * CS))
	end=$((start + CS - 1))
	[ "$end" -ge "$SIZE" ] && end=$((SIZE - 1))
	curl -sS -L --max-redirs 5 --retry 8 --retry-delay 2 --retry-all-errors \
	     -r "$start-$end" -o "$TMP/part$(printf %03d "$i")" "$URL"
' 

cat "$TMP"/part* >"$OUT"
GOT=$(stat -c %s "$OUT")
rm -rf "$TMP"

if [ "$GOT" -ne "$SIZE" ]; then
	echo "大小不符：期望 $SIZE，得到 $GOT" >&2
	exit 1
fi
echo "完成：$OUT（$((GOT / 1024 / 1024)) MB）" >&2
