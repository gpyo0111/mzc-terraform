#!/usr/bin/env bash
# =============================================================================
# deploy-load-test.sh
#
# 1. Locust Docker 이미지를 빌드하고 ECR에 푸시
# 2. Terraform으로 30-load-test 인프라를 적용
# 3. (선택) 부하테스트 완료 후 인프라 삭제
#
# 사용법:
#   ./deploy-load-test.sh apply   # 배포 (기본값)
#   ./deploy-load-test.sh destroy # 삭제
#
# 환경변수 (필요 시 재정의):
#   TARGET_HOST   : 부하테스트 대상 URL  (기본: ALB DNS 자동 조회)
#   LOCUST_USERS  : 최대 동시 유저 수   (기본: 50)
#   SPAWN_RATE    : 초당 유저 증가 수   (기본: 5)
#   RUN_TIME      : 실행 시간           (기본: 5m)
#   WORKER_COUNT  : Locust 워커 수      (기본: 2)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_TEST_DIR="${SCRIPT_DIR}/../mzc-load-test"
TF_DIR="${SCRIPT_DIR}/30-load-test"

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
AWS_PROFILE="${AWS_PROFILE:-bya}"
ACCOUNT_ID="${ACCOUNT_ID:-455535733131}"
ECR_REPO="securevoice-locust"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "latest")}"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

ACTION="${1:-apply}"

# ── 대상 호스트 자동 조회 (명시하지 않은 경우) ───────────────────────────────
if [[ -z "${TARGET_HOST:-}" ]]; then
  echo "[INFO] TARGET_HOST 미설정 → 20-runtime tfstate에서 ALB DNS 조회 중..."
  ALB_DNS=$(aws s3 cp \
    "s3://securevoice-terraform-state-${ACCOUNT_ID}-${AWS_REGION}/securevoice/dev/20-runtime/terraform.tfstate" - \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    | python3 -c "import sys,json; s=json.load(sys.stdin); \
      print(s['outputs']['alb_dns_name']['value'])" 2>/dev/null || true)

  if [[ -n "${ALB_DNS}" ]]; then
    TARGET_HOST="http://${ALB_DNS}"
    echo "[INFO] TARGET_HOST=${TARGET_HOST}"
  else
    echo "[ERROR] TARGET_HOST 를 자동 조회할 수 없습니다. 직접 지정해 주세요."
    echo "  export TARGET_HOST=http://<alb-dns>"
    exit 1
  fi
fi

LOCUST_USERS="${LOCUST_USERS:-50}"
SPAWN_RATE="${SPAWN_RATE:-5}"
RUN_TIME="${RUN_TIME:-5m}"
WORKER_COUNT="${WORKER_COUNT:-2}"

# =============================================================================
apply() {
  # ── 1. Terraform: ECR 리포지토리만 먼저 생성 ───────────────────────────────
  echo ""
  echo "━━━ [1/4] Terraform init & ECR 생성 ━━━"
  cd "${TF_DIR}"
  terraform init -reconfigure
  terraform apply -auto-approve \
    -target=aws_ecr_repository.locust \
    -target=aws_ecr_lifecycle_policy.locust \
    -var="target_host=${TARGET_HOST}" \
    -var="locust_image_tag=${IMAGE_TAG}" \
    -var="locust_users=${LOCUST_USERS}" \
    -var="locust_spawn_rate=${SPAWN_RATE}" \
    -var="locust_run_time=${RUN_TIME}" \
    -var="locust_worker_count=${WORKER_COUNT}"

  # ── 2. Docker 이미지 빌드 & ECR 푸시 ──────────────────────────────────────
  echo ""
  echo "━━━ [2/4] Docker 이미지 빌드 & ECR 푸시 ━━━"
  aws ecr get-login-password --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  docker build \
    --platform linux/amd64 \
    -t "${ECR_URL}:${IMAGE_TAG}" \
    -t "${ECR_URL}:latest" \
    "${LOAD_TEST_DIR}"

  docker push "${ECR_URL}:${IMAGE_TAG}"
  docker push "${ECR_URL}:latest"

  # ── 3. Terraform: 나머지 리소스 (ECS, SG, IAM, Cloud Map) 생성 ────────────
  echo ""
  echo "━━━ [3/4] Terraform apply (전체 리소스) ━━━"
  terraform apply -auto-approve \
    -var="target_host=${TARGET_HOST}" \
    -var="locust_image_tag=${IMAGE_TAG}" \
    -var="locust_users=${LOCUST_USERS}" \
    -var="locust_spawn_rate=${SPAWN_RATE}" \
    -var="locust_run_time=${RUN_TIME}" \
    -var="locust_worker_count=${WORKER_COUNT}"

  # ── 4. 완료 메시지 ───────────────────────────────────────────────────────
  echo ""
  echo "━━━ [4/4] 부하테스트 시작됨 ━━━"
  echo ""
  echo "  대상 URL    : ${TARGET_HOST}"
  echo "  동시 유저   : ${LOCUST_USERS}"
  echo "  Spawn rate  : ${SPAWN_RATE}/s"
  echo "  실행 시간   : ${RUN_TIME}"
  echo "  워커 수     : ${WORKER_COUNT}"
  echo ""
  echo "  CloudWatch 로그 (Master):"
  echo "    /ecs/securevoice-dev-locust-master"
  echo ""
  echo "  결과 확인 후 삭제:"
  echo "    $0 destroy"
}

# =============================================================================
destroy() {
  echo ""
  echo "━━━ [DESTROY] 부하테스트 인프라 삭제 ━━━"
  cd "${TF_DIR}"
  terraform init -reconfigure
  terraform destroy -auto-approve \
    -var="target_host=${TARGET_HOST}" \
    -var="locust_image_tag=${IMAGE_TAG}"
  echo "[DONE] 삭제 완료"
}

# =============================================================================
case "${ACTION}" in
  apply)   apply   ;;
  destroy) destroy ;;
  *)
    echo "Usage: $0 [apply|destroy]"
    exit 1
    ;;
esac
