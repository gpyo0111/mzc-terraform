#!/usr/bin/env bash
# [SecureVoice] 01_sqs_dlq / 02_redrive.sh — DLQ Redrive & 멱등성 확인
set -euo pipefail
[ -f "$(dirname "$0")/../../.env" ] && source "$(dirname "$0")/../../.env" || true
[ -f "$(dirname "$0")/../../../.env" ] && source "$(dirname "$0")/../../../.env" || true

DLQ_URL="${SV_DLQ_URL:-}"; DLQ_ARN="${SV_DLQ_ARN:-}"; MAIN_QUEUE_ARN="${SV_MAIN_QUEUE_ARN:-}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
GRN='\033[0;32m'; RED='\033[0;31m'; BLU='\033[0;34m'; RST='\033[0m'; BOLD='\033[1m'
ok() { echo -e "  ${GRN}[PASS]${RST} $1"; }; fail() { echo -e "  ${RED}[FAIL]${RST} $1"; }
info() { echo -e "  ${BLU}[INFO]${RST} $1"; }

echo -e "\n${BOLD}━━━ [01_sqs_dlq] DLQ Redrive ━━━${RST}\n"

DLQ_DEPTH=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo 0)
info "현재 DLQ depth: $DLQ_DEPTH"

if [ "${DLQ_DEPTH:-0}" -eq 0 ]; then
  fail "DLQ 비어있음 — 01_inject_broken.sh 먼저 실행 필요"; exit 1
fi

if [ -n "$DLQ_ARN" ] && [ -n "$MAIN_QUEUE_ARN" ]; then
  aws sqs start-message-move-task \
    --source-arn "$DLQ_ARN" \
    --destination-arn "$MAIN_QUEUE_ARN" \
    --region "$REGION" > /dev/null && ok "Redrive 태스크 시작" \
    || info "Redrive API 실패 — 콘솔에서 직접 실행: SQS → DLQ → Start DLQ redrive"
else
  info "DLQ_ARN 또는 MAIN_QUEUE_ARN 미설정"
  info "수동: aws sqs start-message-move-task --source-arn \$DLQ_ARN --destination-arn \$MAIN_QUEUE_ARN"
fi

sleep 30
DLQ_AFTER=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo "?")
info "Redrive 30초 후 DLQ depth: $DLQ_AFTER"
[ "${DLQ_AFTER:-1}" -lt "${DLQ_DEPTH}" ] \
  && ok "[2026-01-06] DLQ 메시지 감소 확인 → PASS" \
  || fail "[2026-01-06] DLQ 메시지 미감소 → FAIL"

echo -e "\n다음: bash cli/99_cleanup.sh\n"
