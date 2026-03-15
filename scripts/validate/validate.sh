#!/usr/bin/env bash
# validate.sh — Kind 클러스터 모니터링 스택 통합 검증
# port-forward → 테스트 데이터 전송 → 쿼리 추출 → 검증 → 리포트
#
# Usage:
#   ./validate.sh                    # 전체 실행 (전송 + 추출 + 검증)
#   ./validate.sh --skip-send        # 테스트 데이터 전송 건너뛰기 (기존 데이터로 검증)
#   ./validate.sh --extract-only     # 쿼리 추출만 수행
#
# 사전 조건:
#   - kubectl이 Kind 클러스터에 연결되어 있어야 함
#   - jq 설치 필요 (brew install jq)
#   - Goti-monitoring 레포가 같은 프로젝트 루트에 있어야 함

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 설정
NAMESPACE="monitoring"
ALLOY_SVC="alloy-dev"
MIMIR_SVC="mimir-dev-query-frontend"
LOKI_SVC="loki-dev"
TEMPO_SVC="tempo-dev"

ALLOY_PORT=4318
MIMIR_PORT=8080
LOKI_PORT=3100
TEMPO_PORT=3200

LOCAL_ALLOY_PORT=14318
LOCAL_MIMIR_PORT=18080
LOCAL_LOKI_PORT=13100
LOCAL_TEMPO_PORT=13200

MONITORING_REPO="${MONITORING_REPO:-$(cd "${SCRIPT_DIR}/../../../Goti-monitoring" 2>/dev/null && pwd || echo "")}"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}"; }

# PID 배열 (cleanup용)
PF_PIDS=()

cleanup() {
  info "port-forward 프로세스 정리 중..."
  for pid in "${PF_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  info "정리 완료"
}
trap cleanup EXIT

# ─── 옵션 파싱 ───
SKIP_SEND=false
EXTRACT_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --skip-send) SKIP_SEND=true ;;
    --extract-only) EXTRACT_ONLY=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-send] [--extract-only]"
      echo "  --skip-send     테스트 데이터 전송 건너뛰기"
      echo "  --extract-only  쿼리 추출만 수행 (port-forward 불필요)"
      exit 0
      ;;
  esac
done

# ─── 사전 검증 ───
header "사전 검증"

# kubectl 연결 확인
if ! kubectl cluster-info &>/dev/null; then
  error "kubectl이 클러스터에 연결되어 있지 않습니다"
  exit 1
fi

CONTEXT=$(kubectl config current-context)
info "K8s context: ${CONTEXT}"

# monitoring 네임스페이스 확인
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  error "${NAMESPACE} 네임스페이스가 존재하지 않습니다"
  exit 1
fi

# jq 확인
if ! command -v jq &>/dev/null; then
  error "jq가 필요합니다. brew install jq"
  exit 1
fi

# Goti-monitoring 레포 확인
if [[ -z "$MONITORING_REPO" ]] || [[ ! -d "$MONITORING_REPO" ]]; then
  error "Goti-monitoring 레포를 찾을 수 없습니다"
  error "MONITORING_REPO 환경변수를 설정하거나, Goti-monitoring이 같은 프로젝트 루트에 있어야 합니다"
  exit 1
fi
info "Monitoring repo: ${MONITORING_REPO}"

# extract-only 모드
if [[ "$EXTRACT_ONLY" == true ]]; then
  header "쿼리 추출 (extract-only)"
  bash "${SCRIPT_DIR}/extract-queries.sh" "${MONITORING_REPO}"
  exit 0
fi

# ─── Pod 상태 확인 ───
header "Pod 상태 확인"

for svc in "$ALLOY_SVC" "$MIMIR_SVC" "$LOKI_SVC" "$TEMPO_SVC"; do
  # 서비스 존재 확인
  if kubectl get svc "$svc" -n "$NAMESPACE" &>/dev/null; then
    info "${svc} 서비스 확인 ✓"
  else
    # 서비스 이름이 다를 수 있으므로 경고만
    warn "${svc} 서비스를 찾을 수 없습니다. 이름이 다를 수 있습니다."
  fi
done

# ─── Port Forward 시작 ───
header "Port Forward 시작"

start_port_forward() {
  local svc="$1" remote_port="$2" local_port="$3" label="$4"

  # 이미 사용 중인 포트 확인
  if lsof -i ":${local_port}" &>/dev/null; then
    warn "포트 ${local_port}이(가) 이미 사용 중 — 기존 연결 사용"
    return 0
  fi

  kubectl port-forward "svc/${svc}" "${local_port}:${remote_port}" -n "${NAMESPACE}" &>/dev/null &
  local pid=$!
  PF_PIDS+=("$pid")

  # 연결 대기 (최대 10초)
  local retries=0
  while ! curl -s --connect-timeout 1 "http://localhost:${local_port}" &>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 10 ]]; then
      error "${label} port-forward 실패 (localhost:${local_port})"
      return 1
    fi
    sleep 1
  done

  info "${label}: localhost:${local_port} → ${svc}:${remote_port}"
}

start_port_forward "$ALLOY_SVC" "$ALLOY_PORT" "$LOCAL_ALLOY_PORT" "Alloy"
start_port_forward "$MIMIR_SVC" "$MIMIR_PORT" "$LOCAL_MIMIR_PORT" "Mimir"
start_port_forward "$LOKI_SVC" "$LOKI_PORT" "$LOCAL_LOKI_PORT" "Loki"
start_port_forward "$TEMPO_SVC" "$TEMPO_PORT" "$LOCAL_TEMPO_PORT" "Tempo"

echo ""
info "모든 port-forward 연결 완료"

# ─── 테스트 데이터 전송 ───
if [[ "$SKIP_SEND" == false ]]; then
  header "테스트 데이터 전송"
  bash "${SCRIPT_DIR}/send-test-data.sh" "http://localhost:${LOCAL_ALLOY_PORT}"

  info "인제스트 대기 (60초)..."
  sleep 60
else
  info "테스트 데이터 전송 건너뜀 (--skip-send)"
fi

# ─── 쿼리 추출 ───
header "쿼리 추출"
bash "${SCRIPT_DIR}/extract-queries.sh" "${MONITORING_REPO}" "${SCRIPT_DIR}/extracted"

# ─── 쿼리 검증 ───
header "쿼리 검증"
export MIMIR_URL="http://localhost:${LOCAL_MIMIR_PORT}"
export LOKI_URL="http://localhost:${LOCAL_LOKI_PORT}"
export TEMPO_URL="http://localhost:${LOCAL_TEMPO_PORT}"

bash "${SCRIPT_DIR}/validate-queries.sh" "${SCRIPT_DIR}/extracted" || true

echo ""
info "검증 완료. 리포트는 ${SCRIPT_DIR}/extracted/ 디렉토리를 확인하세요."
