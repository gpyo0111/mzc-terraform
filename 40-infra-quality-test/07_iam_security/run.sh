#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"
echo ""
echo "=================================================="
echo " 07: IAM 최소권한 및 Secrets Manager 검증"
echo "=================================================="
python3 "$(dirname "${BASH_SOURCE[0]}")/test_iam.py"
