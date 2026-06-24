#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"
echo ""
echo "=================================================="
echo " 05: ALB 트래픽 처리 검증"
echo "=================================================="
python3 "$(dirname "${BASH_SOURCE[0]}")/test_alb.py"
