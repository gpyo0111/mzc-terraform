#!/usr/bin/env bash
# [SecureVoice] 01_sqs_dlq / 00_preflight.sh — 사전 조건 체크
set -euo pipefail
[ -f "$(dirname "$0")/../../.env" ] && source "$(dirname "$0")/../../.env" || true
[ -f "$(dirname "$0")/../../../.env" ] && source "$(dirname "$0")/../../../.env" || true

MAIN_QUEUE_URL="${SV_MAIN_QUEUE_URL:-}"; DLQ_URL="${SV_DLQ_URL:-}"
ECS_CLUSTER="${SV_ECS_CLUSTER:-securevoice}"; WORKER_SERVICE="${SV_WORKER_SERVICE:-securevoice-worker}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; RST='\033[0m'; BOLD='\033[1m'
PASS=0; FAIL=0
# ok()   { echo -e "  ${GRN}[PASS]${RST} $1"; ((PASS++)); }
# fail() { echo -e "  ${RED}[FAIL]${RST} $1"; ((FAIL++)); }
# TO-BE (수정 코드: || true 를 붙여 set -e 회피)
ok()   { echo -e "  ${GRN}[PASS]${RST} $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${RST} $1"; ((FAIL++)) || true; }
info() { echo -e "  ${BLU}[INFO]${RST} $1"; }

echo -e "\n${BOLD}━━━ [01_sqs_dlq] 사전 조건 체크 ━━━${RST}\n"

# AWS 인증
# CALLER=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1) && ok "AWS 인증: $CALLER" || fail "AWS 인증 실패"
if CALLER=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null); then
  ok "AWS 인증: $CALLER"
else
  fail "AWS 인증 실패 (aws configure나 AWS_PROFILE을 확인하세요)"
fi

# 워커 ECS 상태
RUNNING=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$WORKER_SERVICE" \
  --query 'services[0].runningCount' --output text --region "$REGION" 2>/dev/null || echo 0)
[ "${RUNNING:-0}" -gt 0 ] && ok "워커 ECS running=$RUNNING" || fail "워커 ECS running=0 — 서비스 확인 필요"

# SQS 접근
if [ -n "$MAIN_QUEUE_URL" ]; then
  DEPTH=$(aws sqs get-queue-attributes --queue-url "$MAIN_QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo "?")
  ok "Main Queue 접근 확인 (depth=$DEPTH)"
else
  fail "SV_MAIN_QUEUE_URL 미설정"
fi

if [ -n "$DLQ_URL" ]; then
  DLQ_DEPTH=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text --region "$REGION" 2>/dev/null || echo "?")
  ok "DLQ 접근 확인 (depth=$DLQ_DEPTH)"
  [ "${DLQ_DEPTH:-0}" -gt 0 ] && echo -e "  ${YLW}  DLQ에 잔존 메시지 있음 — 01_run.sh 전 purge 고려${RST}"
else
  fail "SV_DLQ_URL 미설정"
fi

# SQS maxReceiveCount 확인
if [ -n "$MAIN_QUEUE_URL" ]; then
  MAX_RC=$(aws sqs get-queue-attributes --queue-url "$MAIN_QUEUE_URL" \
    --attribute-names RedrivePolicy \
    --query 'Attributes.RedrivePolicy' --output text --region "$REGION" 2>/dev/null || echo "{}")
  info "RedrivePolicy: $MAX_RC"
fi

echo -e "\n${BOLD}결과: PASS=$PASS / FAIL=$FAIL${RST}"
[ "$FAIL" -eq 0 ] && echo -e "${GRN}✓ 사전 조건 OK — 01_run.sh 실행 가능${RST}\n" && exit 0 \
  || { echo -e "${RED}✗ FAIL 항목 해결 후 재실행${RST}\n"; exit 1; }
