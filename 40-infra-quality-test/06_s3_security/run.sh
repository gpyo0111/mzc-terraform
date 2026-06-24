#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"
echo ""
echo "=================================================="
echo " 06: S3 보안 및 암호화 검증"
echo "=================================================="
python3 "$(dirname "${BASH_SOURCE[0]}")/test_s3.py"
