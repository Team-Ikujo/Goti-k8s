#!/usr/bin/env bash
# validate-queries.sh — 추출된 쿼리를 Mimir/Loki/Tempo API로 실행하여 검증
# Usage: ./validate-queries.sh [EXTRACTED_DIR]
# 사전 조건: port-forward 실행 중 (Mimir:8080, Loki:3100, Tempo:3200)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTED_DIR="${1:-${SCRIPT_DIR}/extracted}"

MIMIR_URL="${MIMIR_URL:-http://localhost:8080}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
TOTAL=0
FAIL_DETAILS=()

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
pass()  { echo -e "  ${GREEN}✅${NC} $*"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail()  { echo -e "  ${RED}❌${NC} $*"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); FAIL_DETAILS+=("$*"); }
skip()  { echo -e "  ${YELLOW}⏭️${NC}  $*"; SKIP=$((SKIP + 1)); }
header(){ echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

# PromQL 쿼리 실행
run_promql() {
  local query="$1"
  local label="$2"

  # 빈 쿼리나 주석 건너뛰기
  [[ -z "$query" ]] && return
  [[ "$query" == \#* ]] && return

  local response
  response=$(curl -s --connect-timeout 5 --max-time 10 \
    "${MIMIR_URL}/prometheus/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null || echo '{"status":"error","error":"connection failed"}')

  local status
  status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "error")

  if [[ "$status" == "success" ]]; then
    local result_count
    result_count=$(echo "$response" | jq -r '.data.result | length' 2>/dev/null || echo "0")

    if [[ "$result_count" -gt 0 ]]; then
      local sample_value
      sample_value=$(echo "$response" | jq -r '.data.result[0].value[1] // .data.result[0].values[-1][1] // "N/A"' 2>/dev/null || echo "N/A")
      pass "${label}  ${result_count} series (sample: ${sample_value})"
    else
      fail "${label}  0 series — 데이터 없음"
    fi
  else
    local err_msg
    err_msg=$(echo "$response" | jq -r '.error // "unknown"' 2>/dev/null | head -c 80)
    fail "${label}  구문 오류: ${err_msg}"
  fi
}

# LogQL 쿼리 실행
run_logql() {
  local query="$1"
  local label="$2"

  [[ -z "$query" ]] && return
  [[ "$query" == \#* ]] && return

  # LogQL instant query (metric 쿼리) vs range query (log 쿼리) 분기
  local endpoint
  if [[ "$query" == *"rate("* ]] || [[ "$query" == *"count_over_time("* ]] || [[ "$query" == *"sum("* ]] || [[ "$query" == *"avg("* ]] || [[ "$query" == *"topk("* ]]; then
    endpoint="${LOKI_URL}/loki/api/v1/query"
  else
    endpoint="${LOKI_URL}/loki/api/v1/query_range"
  fi

  local response
  local now_ns=$(($(date +%s) * 1000000000))
  local start_ns=$(( ($(date +%s) - 3600) * 1000000000 ))

  if [[ "$endpoint" == *"query_range" ]]; then
    response=$(curl -s --connect-timeout 5 --max-time 10 \
      "${endpoint}" \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start_ns}" \
      --data-urlencode "end=${now_ns}" \
      --data-urlencode "limit=10" 2>/dev/null || echo '{"status":"error","error":"connection failed"}')
  else
    response=$(curl -s --connect-timeout 5 --max-time 10 \
      "${endpoint}" \
      --data-urlencode "query=${query}" 2>/dev/null || echo '{"status":"error","error":"connection failed"}')
  fi

  local status
  status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "error")

  if [[ "$status" == "success" ]]; then
    local result_count
    result_count=$(echo "$response" | jq -r '.data.result | length' 2>/dev/null || echo "0")

    if [[ "$result_count" -gt 0 ]]; then
      pass "${label}  ${result_count} series/streams"
    else
      fail "${label}  0 results — 데이터 없음"
    fi
  else
    local err_msg
    err_msg=$(echo "$response" | jq -r '.error // "unknown"' 2>/dev/null | head -c 80)
    fail "${label}  구문 오류: ${err_msg}"
  fi
}

# TraceQL 검색
run_traceql() {
  local query="$1"
  local label="$2"

  [[ -z "$query" ]] && return
  [[ "$query" == \#* ]] && return

  local response
  response=$(curl -s --connect-timeout 5 --max-time 10 \
    "${TEMPO_URL}/api/search" \
    --data-urlencode "q=${query}" \
    --data-urlencode "limit=5" 2>/dev/null || echo '{"traces":[]}')

  local trace_count
  trace_count=$(echo "$response" | jq -r '.traces | length' 2>/dev/null || echo "0")

  if [[ "$trace_count" -gt 0 ]]; then
    pass "${label}  ${trace_count} traces"
  else
    # Tempo 연결 실패 vs 데이터 없음 구분
    local has_error
    has_error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null || echo "")
    if [[ -n "$has_error" ]]; then
      fail "${label}  API 오류: ${has_error}"
    else
      fail "${label}  0 traces — 데이터 없음"
    fi
  fi
}

# Mimir Recording Rules 상태 확인
check_recording_rules() {
  header "Recording Rules 상태 (Mimir Ruler)"

  local response
  response=$(curl -s --connect-timeout 5 --max-time 10 \
    "${MIMIR_URL}/prometheus/api/v1/rules" 2>/dev/null || echo '{"status":"error"}')

  local status
  status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "error")

  if [[ "$status" != "success" ]]; then
    warn "Mimir ruler API에 접근할 수 없습니다"
    return
  fi

  # 각 rule group의 rules 순회
  echo "$response" | jq -r '
    .data.groups[]? |
    .rules[]? |
    select(.type == "recording" or .type == "alerting") |
    "\(.type)|\(.name)|\(.health)|\(.state // "N/A")"
  ' 2>/dev/null | while IFS='|' read -r rtype rname rhealth rstate; do
    if [[ "$rhealth" == "ok" ]]; then
      if [[ "$rtype" == "alerting" ]]; then
        pass "${rname}  health=ok, state=${rstate}"
      else
        pass "${rname}  health=ok (recording)"
      fi
    else
      fail "${rname}  health=${rhealth}"
    fi
  done
}

# ═══════════════════════════════════════════
# 메인
# ═══════════════════════════════════════════

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║      Monitoring Query Validation                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
info "Mimir: ${MIMIR_URL}"
info "Loki:  ${LOKI_URL}"
info "Tempo: ${TEMPO_URL}"
info "Queries: ${EXTRACTED_DIR}"

# ─── PromQL ───
if [[ -f "${EXTRACTED_DIR}/promql-queries.txt" ]]; then
  current_dashboard=""
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      current_dashboard="${line#\# }"
      header "PromQL — ${current_dashboard}"
    elif [[ -n "$line" ]]; then
      # 쿼리에서 간략한 라벨 생성
      short_label=$(echo "$line" | head -c 60)
      run_promql "$line" "$short_label"
    fi
  done < "${EXTRACTED_DIR}/promql-queries.txt"
else
  warn "promql-queries.txt 없음 — 건너뜀"
fi

# ─── LogQL ───
if [[ -f "${EXTRACTED_DIR}/logql-queries.txt" ]]; then
  current_dashboard=""
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      current_dashboard="${line#\# }"
      header "LogQL — ${current_dashboard}"
    elif [[ -n "$line" ]]; then
      short_label=$(echo "$line" | head -c 60)
      run_logql "$line" "$short_label"
    fi
  done < "${EXTRACTED_DIR}/logql-queries.txt"
else
  warn "logql-queries.txt 없음 — 건너뜀"
fi

# ─── TraceQL ───
if [[ -f "${EXTRACTED_DIR}/traceql-queries.txt" ]]; then
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      header "TraceQL — ${line#\# }"
    elif [[ -n "$line" ]]; then
      short_label=$(echo "$line" | head -c 60)
      run_traceql "$line" "$short_label"
    fi
  done < "${EXTRACTED_DIR}/traceql-queries.txt"
else
  warn "traceql-queries.txt 없음 — 건너뜀"
fi

# ─── Recording/Alert Rules (파일 기반) ───
if [[ -f "${EXTRACTED_DIR}/recording-rules.txt" ]]; then
  current_file=""
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      current_file="${line#\# }"
      header "Recording/Alert Rules — ${current_file}"
    elif [[ -n "$line" ]]; then
      short_label=$(echo "$line" | head -c 60)
      run_promql "$line" "$short_label"
    fi
  done < "${EXTRACTED_DIR}/recording-rules.txt"
else
  warn "recording-rules.txt 없음 — 건너뜀"
fi

# ─── Loki Alert Rules ───
if [[ -f "${EXTRACTED_DIR}/loki-alert-rules.txt" ]]; then
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      header "Loki Alert — ${line#\# }"
    elif [[ -n "$line" ]]; then
      short_label=$(echo "$line" | head -c 60)
      run_logql "$line" "$short_label"
    fi
  done < "${EXTRACTED_DIR}/loki-alert-rules.txt"
else
  warn "loki-alert-rules.txt 없음 — 건너뜀"
fi

# ─── Mimir ruler 내장 rules 상태 ───
check_recording_rules

# ═══════════════════════════════════════════
# 리포트 출력
# ═══════════════════════════════════════════
echo ""
echo -e "${BOLD}"
echo "══════════════════════════════════════════════════"
echo -e "  Summary: ${GREEN}${PASS} PASS${NC}, ${RED}${FAIL} FAIL${NC}, ${YELLOW}${SKIP} SKIP${NC}  (Total: ${TOTAL})"
echo "══════════════════════════════════════════════════"
echo -e "${NC}"

if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
  echo -e "${RED}${BOLD}Failed queries:${NC}"
  for detail in "${FAIL_DETAILS[@]}"; do
    echo -e "  ${RED}•${NC} ${detail}"
  done
  echo ""
fi

# 결과를 파일로도 저장
REPORT_FILE="${EXTRACTED_DIR}/validation-report-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "Monitoring Validation Report"
  echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "PASS: ${PASS}, FAIL: ${FAIL}, SKIP: ${SKIP}, TOTAL: ${TOTAL}"
  echo ""
  if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
    echo "Failed:"
    for detail in "${FAIL_DETAILS[@]}"; do
      echo "  - ${detail}"
    done
  fi
} > "$REPORT_FILE"

info "리포트 저장: ${REPORT_FILE}"

exit $FAIL
