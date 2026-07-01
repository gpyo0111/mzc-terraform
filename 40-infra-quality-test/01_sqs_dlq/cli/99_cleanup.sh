#!/usr/bin/env bash
# [SecureVoice] 01_sqs_dlq / 99_cleanup.sh
set -euo pipefail
[ -f "$(dirname "$0")/../../.env" ] && source "$(dirname "$0")/../../.env" || true
[ -f "$(dirname "$0")/../../../.env" ] && source "$(dirname "$0")/../../../.env" || true

MAIN_QUEUE_URL="${SV_MAIN_QUEUE_URL:-}"; DLQ_URL="${SV_DLQ_URL:-}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
GRN='\033[0;32m'; BLU='\033[0;34m'; RST='\033[0m'; BOLD='\033[1m'
ok() { echo -e "  ${GRN}[DONE]${RST} $1"; }; info() { echo -e "  ${BLU}[INFO]${RST} $1"; }

echo -e "\n${BOLD}━━━ [01_sqs_dlq] 정리 ━━━${RST}\n"
read -rp "  SQS/DLQ 큐 purge 하시겠습니까? (y/N): " C
if [ "$C" = "y" ] || [ "$C" = "Y" ]; then
  [ -n "$MAIN_QUEUE_URL" ] && aws sqs purge-queue --queue-url "$MAIN_QUEUE_URL" --region "$REGION" 2>/dev/null && ok "Main Queue purge"
  [ -n "$DLQ_URL" ]        && aws sqs purge-queue --queue-url "$DLQ_URL"        --region "$REGION" 2>/dev/null && ok "DLQ purge"
else
  info "purge 스킵"
fi
echo -e "\n${GRN}정리 완료${RST}\n"
