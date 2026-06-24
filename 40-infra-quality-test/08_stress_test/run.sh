#!/usr/bin/env bash
# =============================================================================
# run.sh — 08_stress_test 실행 스크립트
#
# 사용법:
#   bash run.sh              # 전체 5개 테스트
#   STRESS_TESTS=01,04 bash run.sh   # 특정 테스트만
#   STRESS_TESTS=03 bash run.sh      # 스케일아웃 지연만
#
# 주의: 이 테스트는 실제 AWS 리소스에 부하를 가합니다.
#       프로덕션 환경에서는 실행하지 마세요.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo ""
echo "=================================================="
echo " 08: 스트레스 테스트 — 취약점 탐색 및 임계점 측정"
echo " STRESS_TESTS=${STRESS_TESTS:-01,02,03,04,05}"
echo "=================================================="

python "$(dirname "${BASH_SOURCE[0]}")/test_stress.py"
