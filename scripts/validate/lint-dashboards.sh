#!/usr/bin/env bash
# lint-dashboards.sh — Grafana 대시보드 JSON의 pitfalls 위반을 오프라인 검증
# Usage: ./lint-dashboards.sh [MONITORING_REPO_PATH]
# Default: MONITORING_REPO=../../../Goti-monitoring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_REPO="${1:-$(cd "${SCRIPT_DIR}/../../../Goti-monitoring" 2>/dev/null && pwd || echo "")}"
OUTPUT_DIR="${SCRIPT_DIR}/extracted"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT_FILE="${OUTPUT_DIR}/lint-report-${TIMESTAMP}.txt"

# ─── 색상 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── 유틸리티 함수 ───
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
pass()  { echo -e "  ${GREEN}✅${NC} $*"; }
fail()  { echo -e "  ${RED}❌${NC} $*"; }
header(){ echo -e "\n${CYAN}── $* ──${NC}"; }

PASS_COUNT=0
FAIL_COUNT=0
FAILED_ITEMS=()

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_ITEMS+=("$1")
}

# ─── 사전 검증 ───
if [[ -z "$MONITORING_REPO" ]] || [[ ! -d "$MONITORING_REPO" ]]; then
  error "Goti-monitoring 레포를 찾을 수 없습니다: ${MONITORING_REPO}"
  error "Usage: $0 /path/to/Goti-monitoring"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  error "jq가 필요합니다. brew install jq"
  exit 1
fi

DASHBOARD_DIR="${MONITORING_REPO}/grafana/dashboards"
if [[ ! -d "$DASHBOARD_DIR" ]]; then
  error "대시보드 디렉토리를 찾을 수 없습니다: ${DASHBOARD_DIR}"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# tee로 stdout과 파일 동시 출력
exec > >(tee "${REPORT_FILE}")
exec 2>&1

echo -e "${BOLD}═══ Grafana Dashboard Lint ═══${NC}"
info "대상: ${DASHBOARD_DIR}"
info "리포트: ${REPORT_FILE}"

# 대시보드 파일 목록 수집
DASHBOARD_FILES=()
while IFS= read -r f; do
  DASHBOARD_FILES+=("$f")
done < <(find "${DASHBOARD_DIR}" -name "*.json" -type f | sort)

if [[ ${#DASHBOARD_FILES[@]} -eq 0 ]]; then
  warn "대시보드 JSON 파일이 없습니다."
  exit 0
fi

# ════════════════════════════════════════
# 1. JSON 유효성 검증
# ════════════════════════════════════════
header "JSON Validity"

for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")
  if jq empty "$json_file" 2>/dev/null; then
    pass "$name"
    record_pass
  else
    fail "$name — JSON 파싱 실패"
    record_fail "${name} — JSON 파싱 실패"
  fi
done

# ════════════════════════════════════════
# 2. TraceQL =~ regex + 변수
# ════════════════════════════════════════
header "TraceQL Variable Regex"

traceql_regex_found=false
for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")

  # Tempo 쿼리에서 =~"$ 패턴 검색
  matches=$(jq -r '
    [.. | objects |
     select(.datasource?.type? == "tempo" or .datasource?.uid? == "tempo") |
     .targets[]? | select(.query? and .query != "") |
     select(.query | test("=~\"\\$")) |
     .query] | .[]
  ' "$json_file" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    traceql_regex_found=true
    while IFS= read -r q; do
      fail "${name} — TraceQL에서 Grafana 변수 regex 사용 금지 (400 에러): ${q}"
      record_fail "${name} — TraceQL =~ variable regex 사용"
    done <<< "$matches"
  fi
done

if [[ "$traceql_regex_found" == "false" ]]; then
  pass "No =~ variable usage found"
  record_pass
fi

# ════════════════════════════════════════
# 3. TraceQL unscoped intrinsic
# ════════════════════════════════════════
header "TraceQL Unscoped Intrinsic"

unscoped_found=false
for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")

  # Tempo 쿼리에서 kind= 가 있지만 span.kind= 가 아닌 경우
  # kind= 앞에 span. 이 없는 경우를 찾는다 (intrinsic은 원래 scope 없이 사용 가능하지만 lint에서 경고)
  matches=$(jq -r '
    [.. | objects |
     select(.datasource?.type? == "tempo" or .datasource?.uid? == "tempo") |
     .targets[]? | select(.query? and .query != "") |
     select(.query | test("(?<!span\\.)kind\\s*=")) |
     .query] | .[]
  ' "$json_file" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    unscoped_found=true
    while IFS= read -r q; do
      fail "${name} — unscoped intrinsic 사용 — span.kind= 으로 변경 필요: ${q}"
      record_fail "${name} — unscoped kind= 사용"
    done <<< "$matches"
  fi
done

if [[ "$unscoped_found" == "false" ]]; then
  pass "No unscoped intrinsic usage found"
  record_pass
fi

# ════════════════════════════════════════
# 4. LogQL level vs detected_level
# ════════════════════════════════════════
header "LogQL detected_level"

logql_level_found=false
for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")

  # Loki 쿼리에서 | level= 또는 | level=~ 패턴 탐지
  # detected_level= 은 정상, log_level 변수도 정상
  matches=$(jq -r '
    [.. | objects |
     select(.datasource?.type? == "loki" or .datasource?.uid? == "loki") |
     .targets[]? | select(.expr? and .expr != "") |
     select(.expr | test("\\|\\s*level\\s*=~?")) |
     select(.expr | test("detected_level") | not) |
     .expr] | .[]
  ' "$json_file" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    logql_level_found=true
    while IFS= read -r q; do
      fail "${name} — level= 대신 detected_level= 사용 필요 (Native OTLP): ${q}"
      record_fail "${name} — level= 대신 detected_level= 사용 필요"
    done <<< "$matches"
  fi
done

if [[ "$logql_level_found" == "false" ]]; then
  pass "All Loki queries use detected_level correctly"
  record_pass
fi

# ════════════════════════════════════════
# 5. PromQL histogram_quantile by (le)
# ════════════════════════════════════════
header "PromQL histogram_quantile"

histo_fail_found=false
for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")

  # histogram_quantile( 가 있지만 by (le 가 없는 쿼리
  # 또는 by ( ... le ... ) 패턴이 없는 경우
  matches=$(jq -r '
    [.. | objects |
     select(.datasource?.type? == "prometheus" or .datasource?.uid? == "prometheus") |
     .targets[]? | select(.expr? and .expr != "") |
     select(.expr | test("histogram_quantile\\(")) |
     select(.expr | test("by\\s*\\([^)]*le[^)]*\\)") | not) |
     .expr] | .[]
  ' "$json_file" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    histo_fail_found=true
    while IFS= read -r q; do
      fail "${name} — histogram_quantile에 by (le) 누락: ${q}"
      record_fail "${name} — histogram_quantile by (le) 누락"
    done <<< "$matches"
  fi
done

if [[ "$histo_fail_found" == "false" ]]; then
  pass "All queries include by (le)"
  record_pass
fi

# ════════════════════════════════════════
# 6. Datasource UID 검증
# ════════════════════════════════════════
header "Datasource UID"

ALLOWED_UIDS='["prometheus","loki","tempo","pyroscope","-- Grafana --","$datasource","${datasource}","-- Dashboard --","-- Mixed --","grafana"]'

uid_fail_found=false
for json_file in "${DASHBOARD_FILES[@]}"; do
  name=$(basename "$json_file")

  # 패널 datasource uid 중 허용 목록에 없는 것 찾기
  bad_uids=$(jq -r --argjson allowed "$ALLOWED_UIDS" '
    [.. | objects | select(.datasource?.uid?) |
     .datasource.uid as $uid |
     select($uid != null and ($uid | IN($allowed[]) | not)) |
     $uid] | unique | .[]
  ' "$json_file" 2>/dev/null || true)

  if [[ -n "$bad_uids" ]]; then
    uid_fail_found=true
    while IFS= read -r uid; do
      fail "${name} — 허용되지 않은 datasource UID: ${uid}"
      record_fail "${name} — 미허용 datasource UID: ${uid}"
    done <<< "$bad_uids"
  else
    pass "$name"
    record_pass
  fi
done

# ════════════════════════════════════════
# 7. Tempo datasource tags scoped
# ════════════════════════════════════════
header "Tempo Datasource Tags Scoped"

KPS_VALUES="${MONITORING_REPO}/values-stacks/dev/kube-prometheus-stack-values.yaml"

if [[ -f "$KPS_VALUES" ]]; then
  # yq 사용 가능 시 정확한 파싱, 없으면 grep fallback
  if command -v yq &>/dev/null; then
    unscoped_tags=$(yq eval '
      .. | select(has("tags")) | .tags[]? | select(.key? == "service.name") | .key
    ' "$KPS_VALUES" 2>/dev/null || true)
  else
    # grep fallback: key: "service.name" (resource.service.name이 아닌)
    unscoped_tags=$(grep -n 'key:\s*"service\.name"' "$KPS_VALUES" 2>/dev/null | grep -v 'resource\.service\.name' || true)
  fi

  if [[ -n "$unscoped_tags" ]]; then
    fail "kps-values — unscoped tag key: \"service.name\" → \"resource.service.name\" 으로 변경 필요"
    record_fail "kps-values — unscoped tag key: service.name"
  else
    pass "All Tempo datasource tags are scoped"
    record_pass
  fi
else
  warn "kps values 파일을 찾을 수 없습니다: ${KPS_VALUES}"
fi

# ════════════════════════════════════════
# 8. Loki alert rules level
# ════════════════════════════════════════
header "Loki Alert Rules level"

LOKI_RULES_DIR="${MONITORING_REPO}/loki/rules"

loki_rules_fail=false
if [[ -d "$LOKI_RULES_DIR" ]]; then
  while IFS= read -r rule_file; do
    rule_name=$(basename "$rule_file")

    # level= 또는 level=~ 사용 중 detected_level 이 아닌 것 찾기
    # grep -n으로 라인 번호 포함
    if command -v yq &>/dev/null; then
      # yq로 expr 필드 추출 후 level= 검사
      bad_exprs=$(yq eval '.. | select(has("expr")) | .expr' "$rule_file" 2>/dev/null \
        | grep -n 'level=\|level=~' \
        | grep -v 'detected_level' || true)
    else
      bad_exprs=$(grep -n 'level=' "$rule_file" 2>/dev/null \
        | grep -v 'detected_level' \
        | grep -v '^\s*#' || true)
    fi

    if [[ -n "$bad_exprs" ]]; then
      loki_rules_fail=true
      while IFS= read -r line; do
        line_num=$(echo "$line" | cut -d: -f1)
        content=$(echo "$line" | cut -d: -f2-)
        fail "${rule_name}:${line_num} — ${content} → detected_level 사용 필요"
        record_fail "${rule_name}:${line_num} — level= 대신 detected_level= 사용 필요"
      done <<< "$bad_exprs"
    fi
  done < <(find "$LOKI_RULES_DIR" -name "*.yml" -o -name "*.yaml" | sort)

  if [[ "$loki_rules_fail" == "false" ]]; then
    pass "All Loki alert rules use detected_level correctly"
    record_pass
  fi
else
  warn "Loki rules 디렉토리를 찾을 수 없습니다: ${LOKI_RULES_DIR}"
fi

# ════════════════════════════════════════
# Summary
# ════════════════════════════════════════
TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "  ${GREEN}Summary: ${PASS_COUNT} PASS, ${FAIL_COUNT} FAIL  (Total: ${TOTAL})${NC}"
else
  echo -e "  ${RED}Summary: ${PASS_COUNT} PASS, ${FAIL_COUNT} FAIL  (Total: ${TOTAL})${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════${NC}"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo ""
  echo -e "${RED}Failed:${NC}"
  for item in "${FAILED_ITEMS[@]}"; do
    echo -e "  • ${item}"
  done
fi

echo ""
info "리포트 저장: ${REPORT_FILE}"

exit "${FAIL_COUNT}"
