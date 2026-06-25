#!/usr/bin/env bash
# =============================================================================
# run_all.sh — SecureVoice 인프라 품질 테스트 전체 실행
#
# 사용법:
#   bash run_all.sh             # 전체 실행
#   bash run_all.sh 02 04 06    # 특정 모듈만 실행 (번호 지정)
#
# 각 모듈의 종료 코드(0=전체PASS, 1=FAIL 있음)를 수집해 최종 요약 출력
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ── 실행 대상 모듈 목록 ───────────────────────────────────────────────────────
ALL_MODULES=(
    "02_ecs_health"
    "03_autoscaling"
    "04_rds_connectivity"
    "05_alb_routing"
    "06_s3_security"
    "07_iam_security"
    "09_recovery_stability"
)

# 인수로 특정 모듈 번호 지정 시 필터링
if [[ $# -gt 0 ]]; then
    SELECTED=()
    for num in "$@"; do
        for mod in "${ALL_MODULES[@]}"; do
            if [[ "${mod}" == "${num}"* ]]; then
                SELECTED+=("${mod}")
            fi
        done
    done
    MODULES=("${SELECTED[@]}")
else
    MODULES=("${ALL_MODULES[@]}")
fi

# ── 결과 집계 ─────────────────────────────────────────────────────────────────
declare -A MODULE_STATUS
TOTAL_PASS=0
TOTAL_FAIL=0
START_TIME=$(date +%s)

# ── 헤더 출력 ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     SecureVoice 인프라 품질 테스트 전체 실행                     ║"
echo "║     실행 시각: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "실행 모듈: ${MODULES[*]}"
echo ""

# ── 각 모듈 실행 ──────────────────────────────────────────────────────────────
for mod in "${MODULES[@]}"; do
    run_script="${SCRIPT_DIR}/${mod}/run.sh"

    if [[ ! -f "${run_script}" ]]; then
        echo "${WARN} 모듈 스크립트 미존재: ${run_script}"
        MODULE_STATUS["${mod}"]="SKIP"
        continue
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    MOD_START=$(date +%s)

    # 실행 (실패해도 계속 진행)
    if bash "${run_script}"; then
        MODULE_STATUS["${mod}"]="PASS"
        ((TOTAL_PASS++)) || true
    else
        MODULE_STATUS["${mod}"]="FAIL"
        ((TOTAL_FAIL++)) || true
    fi

    MOD_END=$(date +%s)
    MOD_ELAPSED=$((MOD_END - MOD_START))
    echo "(소요: ${MOD_ELAPSED}s)"
done

# ── 최종 요약 테이블 ──────────────────────────────────────────────────────────
END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                     최종 결과 요약                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-35s  %-10s  %-8s ║\n" "모듈" "상태" ""
echo "╠══════════════════════════════════════════════════════════════╣"

for mod in "${MODULES[@]}"; do
    status="${MODULE_STATUS[${mod}]:-SKIP}"
    if [[ "${status}" == "PASS" ]]; then
        icon="✅ PASS"
    elif [[ "${status}" == "FAIL" ]]; then
        icon="❌ FAIL"
    else
        icon="⏭ SKIP"
    fi
    printf "║  %-35s  %-10s           ║\n" "${mod}" "${icon}"
done

echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  전체 모듈: ${#MODULES[@]}개 | PASS: ${TOTAL_PASS}개 | FAIL: ${TOTAL_FAIL}개 | 소요: ${TOTAL_ELAPSED}s     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "${TOTAL_FAIL}" -eq 0 ]]; then
    echo -e "${GREEN}✅ 모든 모듈 PASS — 인프라 품질 검증 완료${NC}"
    read -p "창을 닫으려면 엔터 키를 누르세요..."  # <== 추가
    exit 0
else
    echo -e "${RED}❌ ${TOTAL_FAIL}개 모듈 FAIL — 상세 로그 확인 필요${NC}"
    read -p "창을 닫으려면 엔터 키를 누르세요..."  # <== 추가
    exit 1
fi