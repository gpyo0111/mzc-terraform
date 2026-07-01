#!/usr/bin/env bash

SNAPSHOT_ID="rds:securevoice-dev-mysql-2026-06-24-18-12"
RESTORE_DB_ID="securevoice-dev-mysql-restore-test"
PROFILE="bya"

# 🔍 확인된 실제 서브넷 그룹 이름을 지정했습니다.
SUBNET_GROUP_NAME="securevoice-dev-db-subnet-group" 

echo "=== RDS Restore 테스트 시작 ==="
echo "대상 스냅샷: $SNAPSHOT_ID"
echo "생성할 임시 DB: $RESTORE_DB_ID (Multi-AZ 적용)"
echo "대상 서브넷 그룹: $SUBNET_GROUP_NAME"
echo "시작 시각: $(date)"

START_TIME=$(date +%s)

# 1. 복원 명령 전송
echo "RDS 복원 요청 중..."
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$RESTORE_DB_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-subnet-group-name "$SUBNET_GROUP_NAME" \
  --profile "$PROFILE" \
  --multi-az > /dev/null

# 복원 명령 실패 시 즉시 예외 처리
if [ $? -ne 0 ]; then
  echo -e "\n❌ [ERROR] RDS 복원 요청이 실패했습니다. 스크립트를 종료합니다."
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

echo "=== RDS Restore 완료 ==="
echo "총 소요 시간: $((TOTAL_ELAPSED / 60))분 $((TOTAL_ELAPSED % 60))초 (${TOTAL_ELAPSED}초)"