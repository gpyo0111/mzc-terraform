#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo ""
echo "=================================================="
echo " 02: ECS Fargate 컨테이너 안정성 검증"
echo "=================================================="

python3 "$(dirname "${BASH_SOURCE[0]}")/test_ecs_health.py"
