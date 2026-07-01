#!/usr/bin/env bash
# [SecureVoice] 01_sqs_dlq / 01_inject_broken.sh — 불량 메시지 주입 & DLQ 이관 확인
set -euo pipefail
[ -f "$(dirname "$0")/../../.env" ] && source "$(dirname "$0")/../../.env" || true
[ -f "$(dirname "$0")/../../../.env" ] && source "$(dirname "$0")/../../../.env" || true

MAIN_QUEUE_URL="${SV_MAIN_QUEUE_URL:-}"; DLQ_URL="${SV_DLQ_URL:-}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"; RESULTS_DIR="$(dirname "$0")/../results"
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; RST='\033[0m'; BOLD='\033[1m'
ok() { echo -e "  ${GRN}[PASS]${RST} $1"; }; fail() { echo -e "  ${RED}[FAIL]${RST} $1"; }
info() { echo -e "  ${BLU}[INFO]${RST} $1"; }; warn() { echo -e "  ${YLW}[WARN]${RST} $1"; }

echo -e "\n${BOLD}━━━ [01_sqs_dlq] 불량 메시지 주입 & DLQ 이관 확인 ━━━${RST}\n"
mkdir -p "$RESULTS_DIR"

# DLQ 기준값 기록
DLQ_BEFORE=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo 0)
info "DLQ 기준값: $DLQ_BEFORE"

# 불량 JSON 주입 (의도적 파싱 오류)
MSG_ID=$(aws sqs send-message --queue-url "$MAIN_QUEUE_URL" \
  --message-body '{"request_id": "broken-test-001", "s3_key":' \
  --query 'MessageId' --output text --region "$REGION")
ok "불량 메시지 주입 완료: MessageId=$MSG_ID"
T_INJECT=$(date +%s)
echo "T_INJECT=$T_INJECT" > "$RESULTS_DIR/dlq_timing.env"
echo "DLQ_BEFORE=$DLQ_BEFORE" >> "$RESULTS_DIR/dlq_timing.env"

info "워커 로그 확인 (별도 터미널):"
info "  aws logs tail ${SV_LOG_GROUP_WORKER:-/ecs/securevoice-worker} --follow --filter-pattern 'JSONDecodeError OR invalid'"

# DLQ 이관 대기 (최대 5분)
info "DLQ 이관 대기 중 (최대 5분)..."
TIMEOUT=900; START=$(date +%s)
while [ $(($(date +%s) - START)) -lt $TIMEOUT ]; do
  DLQ_NOW=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo 0)
  ELAPSED=$(($(date +%s) - T_INJECT))
  printf "  [%3ds] DLQ depth: %s\r" "$ELAPSED" "$DLQ_NOW"
  if [ "${DLQ_NOW:-0}" -gt "${DLQ_BEFORE:-0}" ]; then
    echo ""
    ok "DLQ 메시지 증가 확인: $DLQ_BEFORE → $DLQ_NOW (${ELAPSED}초 소요)"
    [ "$ELAPSED" -le 60 ] && ok "[2026-01-04] 60초 이내 DLQ 이관 → PASS" \
      || fail "[2026-01-04] ${ELAPSED}초 초과 → FAIL"
    echo "DLQ_AFTER=$DLQ_NOW" >> "$RESULTS_DIR/dlq_timing.env"
    echo "ELAPSED_DLQ=$ELAPSED" >> "$RESULTS_DIR/dlq_timing.env"
    break
  fi
  sleep 10
done

echo -e "\n다음: bash cli/02_redrive.sh\n"
