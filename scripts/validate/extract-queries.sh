#!/usr/bin/env bash
# extract-queries.sh — Grafana 대시보드 JSON에서 PromQL/LogQL/TraceQL 추출
# Usage: ./extract-queries.sh [MONITORING_REPO_PATH] [OUTPUT_DIR]
# Default: MONITORING_REPO=../../../Goti-monitoring, OUTPUT=./extracted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_REPO="${1:-$(cd "${SCRIPT_DIR}/../../../Goti-monitoring" 2>/dev/null && pwd || echo "")}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/extracted}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${CYAN}── $* ──${NC}"; }

if [[ -z "$MONITORING_REPO" ]] || [[ ! -d "$MONITORING_REPO" ]]; then
  error "Goti-monitoring 레포를 찾을 수 없습니다: ${MONITORING_REPO}"
  error "Usage: $0 /path/to/Goti-monitoring"
  exit 1
fi

# jq 확인
if ! command -v jq &>/dev/null; then
  error "jq가 필요합니다. brew install jq"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# 템플릿 변수 치환 함수
substitute_vars() {
  local expr="$1"
  expr="${expr//\$service_name/goti/goti-server}"
  expr="${expr//\$\{service_name\}/goti/goti-server}"
  expr="${expr//\$svc/goti-server}"
  expr="${expr//\$\{svc\}/goti-server}"
  expr="${expr//\$interval/5m}"
  expr="${expr//\$\{interval\}/5m}"
  expr="${expr//\$__rate_interval/5m}"
  expr="${expr//\$\{__rate_interval\}/5m}"
  expr="${expr//\$__interval/1m}"
  expr="${expr//\$\{__interval\}/1m}"
  expr="${expr//\$log_type/.*}"
  expr="${expr//\$\{log_type\}/.*}"
  expr="${expr//\$service/.*}"
  expr="${expr//\$\{service\}/.*}"
  expr="${expr//\$level/.*}"
  expr="${expr//\$\{level\}/.*}"
  expr="${expr//\$severity/.*}"
  expr="${expr//\$\{severity\}/.*}"
  expr="${expr//\$search/}"
  expr="${expr//\$\{search\}/}"
  expr="${expr//\$datasource/}"
  expr="${expr//\$\{datasource\}/}"
  # Grafana time range
  expr="${expr//\$__range/1h}"
  expr="${expr//\[\$__auto\]/[5m]}"
  echo "$expr"
}

# ─── 1. Dashboard PromQL 추출 ───
header "Dashboard PromQL 추출"

promql_file="${OUTPUT_DIR}/promql-queries.txt"
: > "$promql_file"

dashboard_count=0
promql_count=0

find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f | sort | while read -r json_file; do
  dashboard_name=$(basename "$json_file" .json)

  # Prometheus datasource를 사용하는 패널에서 expr 추출
  queries=$(jq -r '
    .. | objects |
    select(.expr? and .expr != "" and (.datasource?.type? == "prometheus" or (.datasource?.uid? | tostring | test("mimir|prometheus"; "i")) or (.datasource? == null and .type? != "logs"))) |
    .expr
  ' "$json_file" 2>/dev/null | sort -u || true)

  if [[ -n "$queries" ]]; then
    echo "# Dashboard: ${dashboard_name}" >> "$promql_file"
    while IFS= read -r q; do
      substituted=$(substitute_vars "$q")
      echo "$substituted" >> "$promql_file"
      promql_count=$((promql_count + 1))
    done <<< "$queries"
    echo "" >> "$promql_file"
    dashboard_count=$((dashboard_count + 1))
  fi
done

info "PromQL: ${promql_file}"

# ─── 2. Dashboard LogQL 추출 ───
header "Dashboard LogQL 추출"

logql_file="${OUTPUT_DIR}/logql-queries.txt"
: > "$logql_file"

logql_count=0

find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f | sort | while read -r json_file; do
  dashboard_name=$(basename "$json_file" .json)

  queries=$(jq -r '
    .. | objects |
    select(.expr? and .expr != "" and (.datasource?.type? == "loki" or (.datasource?.uid? | tostring | test("loki"; "i")))) |
    .expr
  ' "$json_file" 2>/dev/null | sort -u || true)

  if [[ -n "$queries" ]]; then
    echo "# Dashboard: ${dashboard_name}" >> "$logql_file"
    while IFS= read -r q; do
      substituted=$(substitute_vars "$q")
      echo "$substituted" >> "$logql_file"
      logql_count=$((logql_count + 1))
    done <<< "$queries"
    echo "" >> "$logql_file"
  fi
done

info "LogQL: ${logql_file}"

# ─── 3. Dashboard TraceQL 추출 ───
header "Dashboard TraceQL 추출"

traceql_file="${OUTPUT_DIR}/traceql-queries.txt"
: > "$traceql_file"

find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f | sort | while read -r json_file; do
  dashboard_name=$(basename "$json_file" .json)

  queries=$(jq -r '
    .. | objects |
    select(.expr? and .expr != "" and (.datasource?.type? == "tempo" or (.datasource?.uid? | tostring | test("tempo"; "i")))) |
    .expr
  ' "$json_file" 2>/dev/null | sort -u || true)

  if [[ -n "$queries" ]]; then
    echo "# Dashboard: ${dashboard_name}" >> "$traceql_file"
    while IFS= read -r q; do
      substituted=$(substitute_vars "$q")
      echo "$substituted" >> "$traceql_file"
    done <<< "$queries"
    echo "" >> "$traceql_file"
  fi
done

info "TraceQL: ${traceql_file}"

# ─── 4. Prometheus Recording Rules 추출 ───
header "Prometheus Recording/Alert Rules 추출"

rules_file="${OUTPUT_DIR}/recording-rules.txt"
: > "$rules_file"

rules_dir="${MONITORING_REPO}/prometheus/rules"
if [[ -d "$rules_dir" ]]; then
  find "$rules_dir" -name "*.yml" -o -name "*.yaml" | sort | while read -r rule_file; do
    rule_name=$(basename "$rule_file")
    echo "# Rules file: ${rule_name}" >> "$rules_file"

    # yq가 있으면 사용, 없으면 grep fallback
    if command -v yq &>/dev/null; then
      yq -r '.. | objects | select(.expr?) | .expr' "$rule_file" 2>/dev/null | while IFS= read -r expr; do
        substituted=$(substitute_vars "$expr")
        echo "$substituted" >> "$rules_file"
      done
    else
      # grep fallback: expr: 뒤의 값 추출
      grep -E '^\s+expr:' "$rule_file" | sed 's/.*expr:\s*//' | while IFS= read -r expr; do
        substituted=$(substitute_vars "$expr")
        echo "$substituted" >> "$rules_file"
      done
    fi
    echo "" >> "$rules_file"
  done
fi

info "Recording/Alert Rules: ${rules_file}"

# ─── 5. Loki Alert Rules 추출 ───
header "Loki Alert Rules 추출"

loki_rules_file="${OUTPUT_DIR}/loki-alert-rules.txt"
: > "$loki_rules_file"

loki_rules_dir="${MONITORING_REPO}/loki/rules"
if [[ -d "$loki_rules_dir" ]]; then
  find "$loki_rules_dir" -name "*.yml" -o -name "*.yaml" | sort | while read -r rule_file; do
    rule_name=$(basename "$rule_file")
    echo "# Loki rules: ${rule_name}" >> "$loki_rules_file"

    if command -v yq &>/dev/null; then
      yq -r '.. | objects | select(.expr?) | .expr' "$rule_file" 2>/dev/null | while IFS= read -r expr; do
        substituted=$(substitute_vars "$expr")
        echo "$substituted" >> "$loki_rules_file"
      done
    else
      grep -E '^\s+expr:' "$rule_file" | sed 's/.*expr:\s*//' | while IFS= read -r expr; do
        substituted=$(substitute_vars "$expr")
        echo "$substituted" >> "$loki_rules_file"
      done
    fi
    echo "" >> "$loki_rules_file"
  done
fi

info "Loki Alert Rules: ${loki_rules_file}"

# ─── Summary ───
header "추출 완료"
info "출력 디렉토리: ${OUTPUT_DIR}"
echo ""
ls -la "${OUTPUT_DIR}/"
