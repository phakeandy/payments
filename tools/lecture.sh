#!/usr/bin/env bash
# 课程视频切片 + 转写流水线。
#
#   ./lecture.sh list                  # 24 集的起止时间和时长
#   ./lecture.sh audio 11              # 只下第 11 集的音频（约 50 分钟）
#   ./lecture.sh transcribe media/ep11.m4a
#   ./lecture.sh one 11                # 下载 + 转写，一步到位
#   ./lecture.sh slice 0:24 11:09 intro   # 任意区间（这里是开头的全系统演示）
#
# 视频地址：export LECTURE_URL="https://..."  或者写进 tools/url 文件。
# 环境变量：MODEL（默认 small.en）、THREADS（默认 nproc）、OUT（默认 ../media）

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$HERE/../media}
MODEL=${MODEL:-small.en}
THREADS=${THREADS:-$(nproc)}

# 领域词表：whisper 会把 outbox 听成 outer box、saga 听成 sagger，
# 把这些词喂给它当先验，术语准确率提升非常明显。
HOTWORDS="idempotency key, outbox, transactional outbox, relay, JetStream, NATS, PostgreSQL, pgx, sqlc, saga, compensation, ledger, double-entry, debit, credit, hold, capture, release, reconciliation, leader election, middleware, gRPC, protobuf, context deadline, row lock, deadlock, backoff, jitter, dead letter, at-least-once, exactly-once, keyset pagination, mTLS, distroless, testcontainers, race detector, Helm, Kubernetes, Toxiproxy, pprof"

# 解析视频地址到全局变量：不能放在 $( ) 里，否则 exit 只退出子 shell。
VIDEO=""
resolve_url() {
	local u=${LECTURE_URL:-}
	if [ -z "$u" ] && [ -f "$HERE/url" ]; then u=$(tr -d '[:space:]' <"$HERE/url"); fi
	if [ -z "$u" ]; then
		echo "缺少视频地址：export LECTURE_URL=... 或写进 $HERE/url" >&2
		exit 1
	fi
	VIDEO=$u
}

row() { # 集号 → "start<TAB>end"，没有就空
	awk -F'\t' -v n="$1" '!/^#/ && $1 == n { print $2 "\t" $3 }' "$HERE/episodes.tsv"
}

cmd_list() {
	printf '%-4s %-9s %-9s %-5s %s\n' 集 起 止 分钟 主题
	awk -F'\t' '!/^#/ { printf "%-4s %-9s %-9s %-5s %s\n", $1, $2, $3, $4, $6 }' \
		"$HERE/episodes.tsv"
}

# 用时间区间下音频： $1=name $2=start $3=end
fetch() {
	local name=$1 start=$2 end=$3
	resolve_url
	mkdir -p "$OUT"
	echo "→ $name  $start – $end   →  $OUT/$name.m4a" >&2
	yt-dlp -f bestaudio -x --audio-format m4a \
		--download-sections "*${start}-${end}" \
		--no-playlist \
		-o "$OUT/$name.%(ext)s" "$VIDEO"
}

cmd_audio() {
	local ep=${1:?用法: lecture.sh audio <集号>} r
	r=$(row "$ep") || true
	[ -n "$r" ] || {
		echo "没有第 $ep 集，试试 lecture.sh list" >&2
		exit 1
	}
	fetch "$(printf 'ep%02d' "$ep")" "${r%%$'\t'*}" "${r##*$'\t'}"
}

cmd_slice() { # 任意区间
	local start=${1:?用法: lecture.sh slice <起> <止> [名字]} end=${2:?} name=${3:-slice}
	fetch "$name" "$start" "$end"
}

cmd_transcribe() {
	local f=${1:?用法: lecture.sh transcribe <音频文件>}
	[ -f "$f" ] || {
		echo "没有文件 $f" >&2
		exit 1
	}
	echo "→ 转写 $(basename "$f")，模型 $MODEL，$THREADS 线程" >&2
	# HF_HUB_DISABLE_IMPLICIT_TOKEN: 本机 ~/.cache/huggingface/token 是个过期 token，
	# 带着它请求会 401，必须关掉全局 token 才下得动模型。
	HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_XET_HIGH_PERFORMANCE=1 \
	whisper-ctranslate2 "$f" \
		--model "$MODEL" \
		--compute_type int8 \
		--device cpu \
		--language en \
		--task transcribe \
		--vad_filter True \
		--threads "$THREADS" \
		--hotwords "$HOTWORDS" \
		--output_format srt \
		--output_dir "$(dirname "$f")"
	echo "→ 完成：${f%.*}.srt" >&2
}

cmd_one() { # 下载 + 转写
	local ep=${1:?用法: lecture.sh one <集号>}
	cmd_audio "$ep"
	cmd_transcribe "$OUT/$(printf 'ep%02d' "$ep").m4a"
}

case ${1:-list} in
list | ls) cmd_list ;;
audio | a) shift && cmd_audio "$@" ;;
slice | s) shift && cmd_slice "$@" ;;
transcribe | t) shift && cmd_transcribe "$@" ;;
one | o) shift && cmd_one "$@" ;;
*)
	echo "用法: lecture.sh {list|audio <集>|slice <起> <止> [名字]|transcribe <文件>|one <集>}" >&2
	exit 1
	;;
esac
