#!/usr/bin/env bash
# 批量：从网上下好的完整音频里，切出每一集 → 转写 → 清洗成 txt。
# 幂等：已经转好的集会跳过，所以中途断了重跑即可。
#
#   ./batch.sh            处理全部 24 集
#   ./batch.sh 6 11 12    只处理这几集
#
# 依赖 media/full.webm（用 fetch-audio.sh 下好的完整音频）。

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MEDIA=${MEDIA:-$HERE/../media}
MODEL=${MODEL:-small.en}
THREADS=${THREADS:-8}
FULL=$MEDIA/full.webm

HOTWORDS="idempotency key, outbox, transactional outbox, relay, JetStream, NATS, PostgreSQL, pgx, sqlc, saga, orchestration, compensation, ledger, double-entry, debit, credit, hold, capture, release, reconciliation, leader election, middleware, gRPC, protobuf, interceptor, context deadline, row lock, deadlock, backoff, jitter, dead letter, at-least-once, exactly-once, keyset pagination, mTLS, distroless, testcontainers, race detector, pprof, Toxiproxy, Helm, Kubernetes, autoscaling, webhook, SSRF, HMAC, velocity limit, spread"

[ -f "$FULL" ] || { echo "缺少 $FULL" >&2; exit 1; }

secs() { # 1:17:49 → 秒
	local IFS=:
	set -- $1
	# 10# 前缀：bash 会把 08/09 当八进制，报 "value too great for base"
	echo $((10#${1:-0} * 3600 + 10#${2:-0} * 60 + 10#${3:-0}))
}

episodes=("$@")
if [ ${#episodes[@]} -eq 0 ]; then
	episodes=($(awk -F'\t' '!/^#/ { print $1 }' "$HERE/episodes.tsv"))
fi

for ep in "${episodes[@]}"; do
	row=$(awk -F'\t' -v n="$ep" '!/^#/ && $1 == n { print $2 "\t" $3 }' "$HERE/episodes.tsv")
	[ -n "$row" ] || { echo "跳过未知集号 $ep" >&2; continue; }
	start=${row%%$'\t'*}
	end=${row##*$'\t'}
	name=$(printf 'ep%02d' "$ep")

	if [ -f "$MEDIA/$name.txt" ]; then
		echo "[$name] 已有转录，跳过" >&2
		continue
	fi

	echo "===== [$name] $start – $end  $(date +%H:%M:%S) =====" >&2

	# 16k 单声道、32k aac：语音识别只需这么多，文件从 37MB 降到 10MB 左右
	ffmpeg -y -ss "$start" -to "$end" -i "$FULL" \
		-vn -ac 1 -ar 16000 -c:a aac -b:a 32k \
		"$MEDIA/$name.m4a" -loglevel error || { echo "[$name] 切音频失败" >&2; continue; }

	HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_XET_HIGH_PERFORMANCE=1 \
	whisper-ctranslate2 "$MEDIA/$name.m4a" \
		--model "$MODEL" --compute_type int8 --device cpu \
		--language en --task transcribe --vad_filter True \
		--threads "$THREADS" --hotwords "$HOTWORDS" \
		--output_format srt --output_dir "$MEDIA" || { echo "[$name] 转写失败" >&2; continue; }

	python3 "$HERE/clean_srt.py" "$MEDIA/$name.srt" "$MEDIA/$name.txt" "$(secs "$start")" ||
		echo "[$name] 清洗失败" >&2

	rm -f "$MEDIA/$name.m4a" # 音频用完就删，srt/txt 留着
done

echo "全部完成 $(date +%H:%M:%S)" >&2
touch "$MEDIA/.batch.done"
