#!/usr/bin/env bash
# =============================================================================
# upload-samples.sh
#
# mzc-ai-worker/samples/ 에 있는 샘플 WAV를 S3 load-test-samples/ prefix에 업로드
# 부하테스트 실행 전 1회만 수행하면 된다.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLES_DIR="${SCRIPT_DIR}/../mzc-ai-worker/samples"

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
AWS_PROFILE="${AWS_PROFILE:-bya}"
BUCKET="${BUCKET:-mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an}"
PREFIX="load-test-samples/"

echo "[INFO] 샘플 파일을 S3에 업로드합니다..."
echo "  버킷  : ${BUCKET}"
echo "  prefix: ${PREFIX}"
echo ""

for f in "${SAMPLES_DIR}"/*.{wav,flac,mp3} 2>/dev/null; do
  [[ -f "${f}" ]] || continue
  filename="$(basename "${f}")"
  echo "  업로드: ${filename}"
  aws s3 cp "${f}" "s3://${BUCKET}/${PREFIX}${filename}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}"
done

echo ""
echo "[DONE] 샘플 업로드 완료"
echo "  aws s3 ls s3://${BUCKET}/${PREFIX}"
