#!/usr/bin/env bash
# capture-dashboards.sh — Grafana 대시보드 스크린샷 자동 캡처
#
# Usage:
#   ./capture-dashboards.sh <step>                  # Step 번호별 캡처
#   ./capture-dashboards.sh <step> --all             # 전체 대시보드 캡처
#   GRAFANA_TOKEN=<token> ./capture-dashboards.sh 1  # API key 지정
#
# 사전 조건:
#   - grafana-image-renderer 활성화 (kube-prometheus-stack values)
#   - GRAFANA_TOKEN 환경변수 또는 grafana-admin-secret 접근

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../goti-team-controller" 2>/dev/null && pwd || echo "${SCRIPT_DIR}/../..")"

# ─── 인자 파싱 ───
STEP="${1:?Usage: $0 <step-number> [--all]}"
CAPTURE_ALL=false
[[ "${2:-}" == "--all" ]] && CAPTURE_ALL=true

GRAFANA_URL="${GRAFANA_URL:-https://monitoring.go-ti.shop}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
OUTPUT_DIR="${PROJECT_ROOT}/docs/screenshots/step${STEP}"

# 색상
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── 토큰 확인 ───
if [[ -z "$GRAFANA_TOKEN" ]]; then
  error "GRAFANA_TOKEN이 설정되지 않았습니다."
  echo "  export GRAFANA_TOKEN=\$(kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d)"
  echo "  또는 Grafana UI에서 Service Account Token 생성"
  exit 1
fi

# ─── 대시보드 목록 ───
# 핵심 대시보드 (SDD D-3 정의)
CORE_DASHBOARDS=(
  "service-overview"
  "infra-pod-health"
  "db-health"
  "infra-keda"
)

# 전체 대시보드 (--all)
ALL_DASHBOARDS=(
  "${CORE_DASHBOARDS[@]}"
  "slo-error-budget"
  "e2e-latency-waterfall"
  "go-runtime"
  "k6-load-test-command-center"
  "application-logs"
  "cluster-nodes"
  "capacity-planning"
  "istio-mesh"
  "argocd-overview"
  "certs-secrets"
  "security-guardrail"
)

if [[ "$CAPTURE_ALL" == "true" ]]; then
  DASHBOARDS=("${ALL_DASHBOARDS[@]}")
else
  DASHBOARDS=("${CORE_DASHBOARDS[@]}")
fi

# ─── 출력 디렉토리 생성 ───
mkdir -p "$OUTPUT_DIR"
info "출력: ${OUTPUT_DIR}"
info "대상: ${#DASHBOARDS[@]}개 대시보드"
echo ""

# ─── 캡처 실행 ───
SUCCESS=0
FAIL=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

for DASH in "${DASHBOARDS[@]}"; do
  OUTPUT_FILE="${OUTPUT_DIR}/${DASH}-${TIMESTAMP}.png"

  # Grafana Render API: /render/d/<uid>
  HTTP_CODE=$(curl -s -o "$OUTPUT_FILE" -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    "${GRAFANA_URL}/render/d/${DASH}?orgId=1&width=1600&height=900&from=now-1h&to=now&kiosk" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "200" ]] && [[ -s "$OUTPUT_FILE" ]]; then
    FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    if [[ "$FILE_SIZE" -gt 1000 ]]; then
      echo -e "  ${GREEN}+${NC} ${DASH}  (${FILE_SIZE} bytes)"
      SUCCESS=$((SUCCESS + 1))
    else
      echo -e "  ${RED}x${NC} ${DASH}  파일 크기 너무 작음 (${FILE_SIZE} bytes) — renderer 미설치?"
      rm -f "$OUTPUT_FILE"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}x${NC} ${DASH}  HTTP ${HTTP_CODE}"
    rm -f "$OUTPUT_FILE"
    FAIL=$((FAIL + 1))
  fi
done

# ─── 요약 ───
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo -e "  Step ${STEP} 캡처: ${GREEN}${SUCCESS} 성공${NC}, ${RED}${FAIL} 실패${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"

if [[ $FAIL -gt 0 ]]; then
  warn "실패한 대시보드가 있습니다. grafana-image-renderer 설치를 확인하세요."
  warn "  helm upgrade kube-prometheus-stack-prod ... --set grafana.imageRenderer.enabled=true"
fi

info "캡처 파일: ${OUTPUT_DIR}/"
