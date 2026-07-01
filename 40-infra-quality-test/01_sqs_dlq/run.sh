#!/usr/bin/env bash
# =============================================================================
# run.sh — SQS DLQ 격리 및 재처리 검증 실행기
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 공통 설정 로드
if [[ -f "${PARENT_DIR}/config.sh" ]]; then
    source "${PARENT_DIR}/config.sh"
fi

# 01_sqs_dlq의 CLI 스크립트가 기대하는 환경변수 매핑
export SV_MAIN_QUEUE_URL="${FREE_QUEUE_URL:-}"
export SV_DLQ_URL="${FREE_DLQ_URL:-}"
export SV_MAIN_QUEUE_ARN="${FREE_QUEUE_ARN:-}"
export SV_DLQ_ARN="${FREE_DLQ_ARN:-}"
export SV_ECS_CLUSTER="${ECS_CLUSTER:-}"
export SV_WORKER_SERVICE="${ECS_SERVICE_FREE_WORKER:-}"
export SV_LOG_GROUP_WORKER="${LOG_GROUP_FREE_WORKER:-}"
export AWS_DEFAULT_REGION="${AWS_REGION:-ap-northeast-2}"

echo ""
echo "=================================================="
echo " 01_sqs_dlq: SQS DLQ 격리 & 재처리 검증"
echo "=================================================="

# 1. 사전 조건 체크
echo -e "\n[STEP 1] 사전 조건 체크 실행..."
if ! bash "${SCRIPT_DIR}/cli/00_preflight.sh"; then
    echo "❌ [FAIL] 사전 조건 체크 실패"
    exit 1
fi

# 2. 불량 메시지 주입 및 DLQ 이관 확인
echo -e "\n[STEP 2] 불량 메시지 주입 및 DLQ 이관 검증 실행..."
if ! bash "${SCRIPT_DIR}/cli/01_inject_broken.sh"; then
    echo "❌ [FAIL] DLQ 이관 검증 실패"
    exit 1
fi

# 3. DLQ Redrive 및 복구 확인
echo -e "\n[STEP 3] DLQ Redrive 및 복구 검증 실행..."
if ! bash "${SCRIPT_DIR}/cli/02_redrive.sh"; then
    echo "❌ [FAIL] DLQ Redrive 검증 실패"
    exit 1
fi

# 4. 리소스 정리 (비대화형 모드로 실행하여 블록 방지)
echo -e "\n[STEP 4] 리소스 정리 실행..."
echo "n" | bash "${SCRIPT_DIR}/cli/99_cleanup.sh"

echo -e "\n✅ [PASS] SQS DLQ 격리 & 재처리 검증 완료"
