#!/usr/bin/env bash
# validate-queries.sh — 추출된 쿼리를 Mimir/Loki/Tempo API로 실행하여 검증
#
# Usage:
#   ./validate-queries.sh [EXTRACTED_DIR]                    # 기본 검증
#   ./validate-queries.sh --check-metrics-exist              # 메트릭 존재 확인
#   ./validate-queries.sh --analyze-efficiency               # 효율성 분석
#   ./validate-queries.sh --target prod                      # prod Mimir 자동 port-forward
#   ./validate-queries.sh --diff-report                      # 이전 결과 대비 비교
#   ./validate-queries.sh --output json                      # JSON 리포트 출력
#
# 사전 조건: port-forward 실행 중 (Mimir:8080, Loki:3100, Tempo:3200)
#            --target prod 사용 시 자동 port-forward

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 옵션 파싱 ───
CHECK_METRICS=false
ANALYZE_EFFICIENCY=false
TARGET=""
DIFF_REPORT=false
OUTPUT_FORMAT="text"
EXTRACTED_DIR="${SCRIPT_DIR}/extracted"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-metrics-exist) CHECK_METRICS=true; shift ;;
    --analyze-efficiency)  ANALYZE_EFFICIENCY=true; shift ;;
    --target)              TARGET="${2:-}"; shift 2 ;;
    --diff-report)         DIFF_REPORT=true; shift ;;
    --output)              OUTPUT_FORMAT="${2:-text}"; shift 2 ;;
    --help|-h)
      head -12 "$0" | tail -10
      exit 0
      ;;
    *)
      # 하위 호환: 위치 인자를 EXTRACTED_DIR로
      if [[ -d "$1" ]]; then
        EXTRACTED_DIR="$1"
      fi
      shift
      ;;
  esac
done

MIMIR_URL="${MIMIR_URL:-http://localhost:8080}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"

# ─── --target prod: 자동 port-forward ───
PF_PID=""
if [[ "$TARGET" == "prod" ]]; then
  MIMIR_URL="http://localhost:18080"
  echo "[INFO] prod 타겟: Mimir Query Frontend port-forward 시작 (localhost:18080)"
  kubectl port-forward -n monitoring svc/mimir-query-frontend 18080:8080 &>/dev/null &
  PF_PID=$!
  sleep 2
  # 종료 시 정리
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
fi

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
  local start_ns=$(( ($(date +%s) - 21600) * 1000000000 ))  # 6h: dev 저트래픽 환경 false negative 방지

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
# --check-metrics-exist: 메트릭 존재 확인
# ═══════════════════════════════════════════
METRICS_MISSING=()
if [[ "$CHECK_METRICS" == "true" ]]; then
  header "메트릭 존재 확인 (--check-metrics-exist)"

  # Prometheus에서 현재 존재하는 메트릭명 목록 가져오기
  all_metrics=$(curl -s --connect-timeout 5 --max-time 15 \
    "${MIMIR_URL}/prometheus/api/v1/label/__name__/values" 2>/dev/null \
    | jq -r '.data[]?' 2>/dev/null || echo "")

  if [[ -z "$all_metrics" ]]; then
    warn "메트릭 목록을 가져올 수 없습니다 (Mimir 연결 확인)"
  else
    metric_count=$(echo "$all_metrics" | wc -l | tr -d ' ')
    info "Prometheus 메트릭 수: ${metric_count}"

    # PromQL 파일에서 사용되는 메트릭명 추출
    if [[ -f "${EXTRACTED_DIR}/promql-queries.txt" ]]; then
      # grep으로 메트릭명 패턴 추출 (알파벳+숫자+_로 구성, { 앞이나 [ 앞에 위치)
      used_metrics=$(grep -oE '[a-zA-Z_:][a-zA-Z0-9_:]*' "${EXTRACTED_DIR}/promql-queries.txt" \
        | grep -vE '^(sum|rate|histogram_quantile|avg|max|min|count|topk|bottomk|absent|absent_over_time|increase|irate|by|on|group_left|group_right|offset|bool|and|or|unless|ignoring|without|label_replace|label_join|vector|time|ceil|floor|round|clamp|clamp_min|clamp_max|changes|resets|deriv|predict_linear|delta|idelta|sgn|sort|sort_desc|NaN|Inf|scalar|job|le|namespace|pod|container|node|instance|name|severity|status|action|method|code|type|reason|phase|mode|device|mountpoint|fstype|true|false)$' \
        | sort -u || true)

      for metric in $used_metrics; do
        # 메트릭명 형식 검증 (recording rule 포함)
        if [[ "$metric" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || [[ "$metric" =~ : ]]; then
          if echo "$all_metrics" | grep -qx "$metric"; then
            pass "메트릭 존재: ${metric}"
          else
            # recording rule 이름은 별도 체크
            if [[ "$metric" =~ : ]]; then
              # ruler API에서 recording rule 확인
              rule_exists=$(curl -s "${MIMIR_URL}/prometheus/api/v1/rules" 2>/dev/null \
                | jq -r ".data.groups[]?.rules[]? | select(.name == \"${metric}\") | .name" 2>/dev/null || echo "")
              if [[ -n "$rule_exists" ]]; then
                pass "Recording rule 존재: ${metric}"
              else
                fail "Recording rule 미등록: ${metric}"
                METRICS_MISSING+=("$metric")
              fi
            else
              fail "메트릭 미존재: ${metric}"
              METRICS_MISSING+=("$metric")
            fi
          fi
        fi
      done
    fi
  fi
fi

# ═══════════════════════════════════════════
# --analyze-efficiency: 효율성 분석
# ═══════════════════════════════════════════
EFFICIENCY_ISSUES=()
if [[ "$ANALYZE_EFFICIENCY" == "true" ]]; then
  header "효율성 분석 (--analyze-efficiency)"

  if [[ -f "${EXTRACTED_DIR}/promql-queries.txt" ]]; then
    # 1. 고카디널리티 탐지: by 절 없는 histogram_quantile
    hq_no_by=$(grep -n 'histogram_quantile' "${EXTRACTED_DIR}/promql-queries.txt" \
      | grep -v 'by' || true)
    if [[ -n "$hq_no_by" ]]; then
      warn "histogram_quantile에 by(le) 누락 가능:"
      echo "$hq_no_by" | head -5
      EFFICIENCY_ISSUES+=("histogram_quantile without by(le)")
    else
      pass "모든 histogram_quantile에 by 절 존재"
    fi

    # 2. recording rule 후보: 3회 이상 반복되는 동일 서브쿼리
    repeated=$(grep -oE 'rate\([^)]+\)' "${EXTRACTED_DIR}/promql-queries.txt" \
      | sort | uniq -c | sort -rn | awk '$1 >= 3 {print}' || true)
    if [[ -n "$repeated" ]]; then
      warn "Recording rule 후보 (3회 이상 반복):"
      echo "$repeated" | head -5
      EFFICIENCY_ISSUES+=("repeated subqueries found")
    else
      pass "반복 서브쿼리 없음"
    fi

    # 3. 중복 쿼리 탐지: 정확히 동일한 쿼리
    duplicates=$(grep -v '^#' "${EXTRACTED_DIR}/promql-queries.txt" \
      | grep -v '^$' | sort | uniq -d || true)
    if [[ -n "$duplicates" ]]; then
      dup_count=$(echo "$duplicates" | wc -l | tr -d ' ')
      warn "중복 쿼리 ${dup_count}건:"
      echo "$duplicates" | head -5
      EFFICIENCY_ISSUES+=("${dup_count} duplicate queries")
    else
      pass "중복 쿼리 없음"
    fi

    # 4. rate() 범위 비표준 탐지
    nonstandard_rate=$(grep -oE 'rate\([^[]+\[[^]]+\]' "${EXTRACTED_DIR}/promql-queries.txt" \
      | grep -v '\[5m\]' | grep -v '\[1m\]' | grep -v '\[1h\]' | grep -v '\[6h\]' | grep -v '\[24h\]' | grep -v '\[3d\]' \
      | sort -u || true)
    if [[ -n "$nonstandard_rate" ]]; then
      warn "비표준 rate() 범위 (표준: 5m/1m/1h/6h/24h/3d):"
      echo "$nonstandard_rate" | head -5
      EFFICIENCY_ISSUES+=("non-standard rate ranges")
    else
      pass "rate() 범위 표준 준수"
    fi
  fi
fi

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

# 결과 저장 (텍스트)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="${EXTRACTED_DIR}/validation-report-${TIMESTAMP}.txt"
{
  echo "Monitoring Validation Report"
  echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Target: ${TARGET:-local}"
  echo "PASS: ${PASS}, FAIL: ${FAIL}, SKIP: ${SKIP}, TOTAL: ${TOTAL}"
  echo ""
  if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
    echo "Failed:"
    for detail in "${FAIL_DETAILS[@]}"; do
      echo "  - ${detail}"
    done
  fi
  if [[ ${#METRICS_MISSING[@]} -gt 0 ]]; then
    echo ""
    echo "Missing metrics:"
    for m in "${METRICS_MISSING[@]}"; do
      echo "  - ${m}"
    done
  fi
  if [[ ${#EFFICIENCY_ISSUES[@]} -gt 0 ]]; then
    echo ""
    echo "Efficiency issues:"
    for e in "${EFFICIENCY_ISSUES[@]}"; do
      echo "  - ${e}"
    done
  fi
} > "$REPORT_FILE"

info "리포트 저장: ${REPORT_FILE}"

# ─── --output json: JSON 리포트 ───
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  JSON_REPORT="${EXTRACTED_DIR}/validation-report-${TIMESTAMP}.json"
  jq -n \
    --arg date "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --arg target "${TARGET:-local}" \
    --argjson pass "$PASS" \
    --argjson fail "$FAIL" \
    --argjson skip "$SKIP" \
    --argjson total "$TOTAL" \
    --argjson failed "$(printf '%s\n' "${FAIL_DETAILS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    --argjson missing "$(printf '%s\n' "${METRICS_MISSING[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    --argjson efficiency "$(printf '%s\n' "${EFFICIENCY_ISSUES[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    '{
      date: $date,
      target: $target,
      summary: { pass: $pass, fail: $fail, skip: $skip, total: $total },
      failed_queries: $failed,
      missing_metrics: $missing,
      efficiency_issues: $efficiency
    }' > "$JSON_REPORT"
  info "JSON 리포트: ${JSON_REPORT}"
fi

# ─── --diff-report: 이전 결과 비교 ───
if [[ "$DIFF_REPORT" == "true" ]]; then
  header "이전 결과 비교 (--diff-report)"

  # 가장 최근 이전 리포트 찾기
  prev_report=$(ls -t "${EXTRACTED_DIR}"/validation-report-*.txt 2>/dev/null | sed -n '2p' || true)

  if [[ -n "$prev_report" && -f "$prev_report" ]]; then
    prev_pass=$(grep -oP 'PASS: \K[0-9]+' "$prev_report" || echo "0")
    prev_fail=$(grep -oP 'FAIL: \K[0-9]+' "$prev_report" || echo "0")
    prev_date=$(grep -oP 'Date: \K.*' "$prev_report" || echo "unknown")

    info "이전 리포트: ${prev_date}"

    pass_diff=$((PASS - prev_pass))
    fail_diff=$((FAIL - prev_fail))

    if [[ $pass_diff -gt 0 ]]; then
      echo -e "  ${GREEN}↑${NC} PASS: +${pass_diff} (${prev_pass} → ${PASS})"
    elif [[ $pass_diff -lt 0 ]]; then
      echo -e "  ${RED}↓${NC} PASS: ${pass_diff} (${prev_pass} → ${PASS})"
    else
      echo -e "  ${CYAN}=${NC} PASS: 변동 없음 (${PASS})"
    fi

    if [[ $fail_diff -gt 0 ]]; then
      echo -e "  ${RED}↑${NC} FAIL: +${fail_diff} (${prev_fail} → ${FAIL}) — 악화"
    elif [[ $fail_diff -lt 0 ]]; then
      echo -e "  ${GREEN}↓${NC} FAIL: ${fail_diff} (${prev_fail} → ${FAIL}) — 개선"
    else
      echo -e "  ${CYAN}=${NC} FAIL: 변동 없음 (${FAIL})"
    fi
  else
    warn "이전 리포트가 없습니다 (첫 실행)"
  fi
fi

exit $FAIL
