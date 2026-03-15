#!/usr/bin/env bash
# send-test-data.sh — OTLP HTTP로 테스트 데이터를 Alloy에 전송
# Usage: ./send-test-data.sh [ALLOY_ENDPOINT]
# Default: http://localhost:4318

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOY_ENDPOINT="${1:-http://localhost:4318}"
PAYLOAD_DIR="${SCRIPT_DIR}/payloads"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 타임스탬프 치환: PLACEHOLDER → 현재 시간 기준 나노초
replace_timestamps() {
  local content="$1"
  local now_s
  now_s=$(date +%s)
  local now_ns="${now_s}000000000"

  # start: 10초 전
  local start_s=$(( now_s - 10 ))
  local start_ns="${start_s}000000000"

  content="${content//PLACEHOLDER_TIME/$now_ns}"
  content="${content//PLACEHOLDER_START/$start_ns}"

  # traces용 오프셋 타임스탬프 (초 단위로 계산 후 나노초 자릿수 패딩)
  local end_50ms="${now_s}050000000"
  local end_100ms="${now_s}100000000"
  local end_800ms="${now_s}800000000"
  local start_2ms="${start_s}002000000"
  local start_5ms="${start_s}005000000"
  local start_10ms="${start_s}010000000"
  local start_50ms="${start_s}050000000"
  local end_7ms="${start_s}007000000"
  local end_25ms="${start_s}025000000"
  local end_90ms="${start_s}090000000"
  local end_750ms="${start_s}750000000"

  content="${content//PLACEHOLDER_END_50MS/$end_50ms}"
  content="${content//PLACEHOLDER_END_100MS/$end_100ms}"
  content="${content//PLACEHOLDER_END_800MS/$end_800ms}"
  content="${content//PLACEHOLDER_START_2MS/$start_2ms}"
  content="${content//PLACEHOLDER_START_5MS/$start_5ms}"
  content="${content//PLACEHOLDER_START_10MS/$start_10ms}"
  content="${content//PLACEHOLDER_START_50MS/$start_50ms}"
  content="${content//PLACEHOLDER_END_7MS/$end_7ms}"
  content="${content//PLACEHOLDER_END_25MS/$end_25ms}"
  content="${content//PLACEHOLDER_END_90MS/$end_90ms}"
  content="${content//PLACEHOLDER_END_750MS/$end_750ms}"

  echo "$content"
}

send_payload() {
  local signal="$1"
  local file="$2"
  local endpoint="$3"

  if [[ ! -f "$file" ]]; then
    error "$signal payload not found: $file"
    return 1
  fi

  local content
  content=$(cat "$file")
  content=$(replace_timestamps "$content")

  local http_code
  http_code=$(echo "$content" | curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${endpoint}" \
    -H "Content-Type: application/json" \
    -d @-)

  if [[ "$http_code" == "200" ]] || [[ "$http_code" == "202" ]]; then
    info "$signal → ${endpoint} (HTTP $http_code)"
    return 0
  else
    error "$signal → ${endpoint} (HTTP $http_code)"
    return 1
  fi
}

# -- 연결 확인 --
info "Alloy endpoint: ${ALLOY_ENDPOINT}"
if ! curl -s -o /dev/null -w "" --connect-timeout 3 "${ALLOY_ENDPOINT}" 2>/dev/null; then
  warn "Alloy endpoint에 연결할 수 없습니다. port-forward가 실행 중인지 확인하세요."
fi

# -- 메트릭 전송 --
info "=== Metrics 전송 ==="
send_payload "metrics" "${PAYLOAD_DIR}/metrics.json" "${ALLOY_ENDPOINT}/v1/metrics"

# -- 로그 전송 --
info "=== Logs 전송 ==="
send_payload "logs" "${PAYLOAD_DIR}/logs.json" "${ALLOY_ENDPOINT}/v1/logs"

# -- 트레이스 전송 --
info "=== Traces 전송 ==="
send_payload "traces" "${PAYLOAD_DIR}/traces.json" "${ALLOY_ENDPOINT}/v1/traces"

# -- 반복 전송 (메트릭은 여러 번 보내야 rate() 계산 가능) --
info "=== 메트릭 추가 전송 (rate 계산용, 3회 x 15초 간격) ==="
for i in 1 2 3; do
  sleep 15
  info "추가 전송 $i/3..."
  send_payload "metrics-$i" "${PAYLOAD_DIR}/metrics.json" "${ALLOY_ENDPOINT}/v1/metrics"
done

echo ""
info "테스트 데이터 전송 완료. Mimir/Loki/Tempo 인제스트까지 약 30초 대기 권장."
