#!/usr/bin/env bash
# =============================================================================
# config.sh — SecureVoice 인프라 품질 테스트 공통 설정
# 모든 테스트 스크립트에서 source ./config.sh 로 로드해서 사용합니다.
# =============================================================================

# ── AWS 기본 ──────────────────────────────────────────────────────────────────
export AWS_REGION="ap-northeast-2"
export AWS_PROFILE="${AWS_PROFILE:-bya}"
export ACCOUNT_ID="455535733131"
export PROJECT="securevoice"
export ENV="dev"

# ── SQS ──────────────────────────────────────────────────────────────────────
export FREE_QUEUE_NAME="free-queue"
export PAID_QUEUE_NAME="paid-queue"
export FREE_DLQ_NAME="free-dlq"
export PAID_DLQ_NAME="paid-dlq"

export FREE_QUEUE_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${FREE_QUEUE_NAME}"
export PAID_QUEUE_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${PAID_QUEUE_NAME}"
export FREE_DLQ_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${FREE_DLQ_NAME}"
export PAID_DLQ_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${PAID_DLQ_NAME}"

export FREE_QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${FREE_QUEUE_NAME}"
export PAID_QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${PAID_QUEUE_NAME}"
export FREE_DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${FREE_DLQ_NAME}"
export PAID_DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${PAID_DLQ_NAME}"

# ── ECS ───────────────────────────────────────────────────────────────────────
export ECS_CLUSTER="${PROJECT}-${ENV}-cluster"
export ECS_SERVICE_API="${PROJECT}-${ENV}-api-service"
export ECS_SERVICE_FREE_WORKER="${PROJECT}-${ENV}-free-worker-service"
export ECS_SERVICE_PAID_WORKER="${PROJECT}-${ENV}-paid-worker-service"

export LOG_GROUP_API="/ecs/${PROJECT}-${ENV}-api"
export LOG_GROUP_FREE_WORKER="/ecs/${PROJECT}-${ENV}-free-worker"
export LOG_GROUP_PAID_WORKER="/ecs/${PROJECT}-${ENV}-paid-worker"

# ── ALB ───────────────────────────────────────────────────────────────────────
export ALB_NAME="${PROJECT}-${ENV}-api-alb"
export API_HOST="${API_HOST:-http://api-origin.mzmt.shop}"   # 환경변수로 override 가능

# ── RDS ───────────────────────────────────────────────────────────────────────
export RDS_IDENTIFIER="${PROJECT}-${ENV}-mysql"
export RDS_BACKUP_RETENTION_DAYS=7

# ── S3 ────────────────────────────────────────────────────────────────────────
export MODEL_BUCKET="mzc-securevoiceguard-model-dev-${ACCOUNT_ID}-${AWS_REGION}"
export AUDIO_BUCKET="mzc-securevoiceguard-audio-dev-${ACCOUNT_ID}-${AWS_REGION}-an"

# ── IAM ───────────────────────────────────────────────────────────────────────
export ROLE_API_TASK="${PROJECT}-${ENV}-api-task-role"
export ROLE_WORKER_TASK="${PROJECT}-${ENV}-worker-task-role"
export ROLE_ECS_EXEC="${PROJECT}-${ENV}-ecs-task-execution-role"

# ── Secrets Manager ───────────────────────────────────────────────────────────
export SECRET_DB_APP="${PROJECT}/${ENV}/db-password"
export SECRET_JWT="${PROJECT}/${ENV}/jwt-secret-key"

# ── CloudWatch Alarms ────────────────────────────────────────────────────────
export ALARM_FREE_SCALE_OUT="${PROJECT}-free-queue-visible-high"
export ALARM_PAID_SCALE_OUT="${PROJECT}-paid-queue-visible-high"
export ALARM_FREE_SCALE_IN="${PROJECT}-free-queue-empty"
export ALARM_PAID_SCALE_IN="${PROJECT}-paid-queue-empty"
export ALARM_FREE_DLQ="${PROJECT}-${ENV}-free-dlq-not-empty"
export ALARM_PAID_DLQ="${PROJECT}-${ENV}-paid-dlq-not-empty"

# ── 색상 출력 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"
FAIL="${RED}[FAIL]${NC}"
INFO="${BLUE}[INFO]${NC}"
WARN="${YELLOW}[WARN]${NC}"
