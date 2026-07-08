#!/usr/bin/env bash

PROFILE="bya"
DB_INSTANCE_NAME="securevoice-dev-mysql"
RESTORE_DB_ID="securevoice-dev-mysql-restore-pitr1"

# 🔍 확인된 실제 서브넷 그룹 이름을 지정했습니다.
SUBNET_GROUP_NAME="securevoice-dev-db-subnet-group" 

echo "=== RDS Point-in-Time Recovery (PITR) 테스트 시작 ==="

# 5분 전의 UTC 시간 계산 (정확한 시점 지정을 위해 UTC 포맷 변환)
RESTORE_TIME=$(date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "복원 대상 원본 DB: $DB_INSTANCE_NAME"
echo "시점 복구 기준 시각 (5분 전 UTC): $RESTORE_TIME"
echo "생성할 임시 DB: $RESTORE_DB_ID (Multi-AZ 적용)"
echo "대상 서브넷 그룹: $SUBNET_GROUP_NAME"
echo "시작 시각: $(date)"

START_TIME=$(date +%s)

# 1. 시점 복구 명령 전송
echo "RDS 시점 복구 요청 중..."
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$DB_INSTANCE_NAME" \
  --target-db-instance-identifier "$RESTORE_DB_ID" \
  --restore-time "$RESTORE_TIME" \
  --db-subnet-group-name "$SUBNET_GROUP_NAME" \
  --profile "$PROFILE" \
  --multi-az > /dev/null

# 복원 명령 실패 시 즉시 예외 처리
if [ $? -ne 0 ]; then
  echo -e "\n❌ [ERROR] RDS 시점 복구 요청이 실패했습니다. 스크립트를 종료합니다."
  exit 1
fi

# 2. available 상태가 될 때까지 10초 간격 폴링
echo "복원 완료 대기 중 (available 상태가 될 때까지)..."
while true; do
  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RESTORE_DB_ID" \
    --profile "$PROFILE" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>/dev/null)
  
  if [ -z "$STATUS" ]; then
    STATUS="fetching"
  fi
  
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  echo -ne "진행 시간: $((ELAPSED / 60))분 $((ELAPSED % 60))초 | 현재 상태: $STATUS\r"
  
  if [ "$STATUS" = "available" ]; then
    break
  fi
  
  if [ "$STATUS" = "failed" ] || [ "$STATUS" = "incompatible-restore" ]; then
    echo -e "\n❌ [ERROR] DB 생성 중 오류가 발생했습니다. 상태: $STATUS"
    exit 1
  fi

  sleep 10
done

echo ""
END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

echo "=== RDS 복원 완료 ==="
echo "총 소요 시간: $((TOTAL_ELAPSED / 60))분 $((TOTAL_ELAPSED % 60))초 (${TOTAL_ELAPSED}초)"