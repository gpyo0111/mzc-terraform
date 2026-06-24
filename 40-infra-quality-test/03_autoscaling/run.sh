#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"
echo ""
echo "=================================================="
echo " 03: Auto Scaling 반응성 검증"
echo "=================================================="
python3 "$(dirname "${BASH_SOURCE[0]}")/test_autoscaling.py"
