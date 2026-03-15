#!/usr/bin/env bash
# check-coverage.sh — 대시보드 메트릭/label/attribute가 테스트 payload에 포함되어 있는지 커버리지 검증
# 대시보드 추가/수정 시 payloads/ 업데이트 누락을 자동 감지
#
# Usage: ./check-coverage.sh [MONITORING_REPO_PATH]
# Default: MONITORING_REPO=../../../Goti-monitoring
#
# 사전 조건:
#   - jq 설치 필요 (brew install jq)
#   - Goti-monitoring 레포가 같은 프로젝트 루트에 있어야 함

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_REPO="${1:-$(cd "${SCRIPT_DIR}/../../../Goti-monitoring" 2>/dev/null && pwd || echo "")}"
PAYLOADS_DIR="${SCRIPT_DIR}/payloads"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
header(){ echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}"; }

# ─── 사전 조건 ───

if [[ -z "$MONITORING_REPO" ]] || [[ ! -d "$MONITORING_REPO" ]]; then
  error "Goti-monitoring 레포를 찾을 수 없습니다: ${MONITORING_REPO}"
  error "Usage: $0 /path/to/Goti-monitoring"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  error "jq가 필요합니다. brew install jq"
  exit 1
fi

if [[ ! -f "${PAYLOADS_DIR}/metrics.json" ]]; then
  error "payloads/metrics.json을 찾을 수 없습니다: ${PAYLOADS_DIR}/metrics.json"
  exit 1
fi

# 카운터
TOTAL_CHECKS=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

record_pass() { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); PASS_COUNT=$((PASS_COUNT + 1)); pass "$*"; }
record_fail() { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); FAIL_COUNT=$((FAIL_COUNT + 1)); fail "$*"; }
record_warn() { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); WARN_COUNT=$((WARN_COUNT + 1)); warn "$*"; }

# ═══════════════════════════════════════════════════════════
# 1. PromQL 메트릭 커버리지
# ═══════════════════════════════════════════════════════════
header "PromQL 메트릭 커버리지"

# 대시보드에서 사용하는 핵심 Prometheus 메트릭 목록
DASHBOARD_METRICS=(
  "http_server_request_duration_seconds"
  "goti_http_server_active_requests"
  "jvm_memory_used_bytes"
  "jvm_memory_limit_bytes"
  "jvm_memory_committed_bytes"
  "jvm_memory_used_after_last_gc_bytes"
  "jvm_gc_duration_seconds"
  "jvm_thread_count"
  "jvm_cpu_recent_utilization_ratio"
  "jvm_cpu_count"
  "jvm_cpu_time_seconds_total"
  "jvm_system_cpu_utilization_ratio"
  "jvm_buffer_memory_used_bytes"
  "jvm_buffer_memory_limit_bytes"
  "jvm_buffer_count"
  "jvm_class_count"
  "jvm_class_loaded_total"
  "jvm_class_unloaded_total"
  "db_client_connections_usage"
  "db_client_connections_max"
  "db_client_connections_pending_requests"
  "db_client_connections_wait_time_milliseconds"
  "db_client_connections_use_time_milliseconds"
  "db_client_connections_create_time_milliseconds"
  "process_cpu_start_time_seconds"
)

# OTel → Prometheus 메트릭명 매핑
# OTel SDK는 . → _ 변환 + unit suffix 추가
declare -A OTEL_TO_PROM
OTEL_TO_PROM=(
  ["http.server.request.duration"]="http_server_request_duration_seconds"
  ["goti.http.server.active_requests"]="goti_http_server_active_requests"
  ["jvm.memory.used"]="jvm_memory_used_bytes"
  ["jvm.memory.limit"]="jvm_memory_limit_bytes"
  ["jvm.memory.committed"]="jvm_memory_committed_bytes"
  ["jvm.memory.used_after_last_gc"]="jvm_memory_used_after_last_gc_bytes"
  ["jvm.gc.duration"]="jvm_gc_duration_seconds"
  ["jvm.thread.count"]="jvm_thread_count"
  ["jvm.cpu.recent_utilization"]="jvm_cpu_recent_utilization_ratio"
  ["jvm.cpu.count"]="jvm_cpu_count"
  ["jvm.cpu.time"]="jvm_cpu_time_seconds_total"
  ["jvm.system_cpu.utilization"]="jvm_system_cpu_utilization_ratio"
  ["jvm.buffer.memory.used"]="jvm_buffer_memory_used_bytes"
  ["jvm.buffer.memory.limit"]="jvm_buffer_memory_limit_bytes"
  ["jvm.buffer.count"]="jvm_buffer_count"
  ["jvm.class.count"]="jvm_class_count"
  ["jvm.class.loaded"]="jvm_class_loaded_total"
  ["jvm.class.unloaded"]="jvm_class_unloaded_total"
  ["db.client.connections.usage"]="db_client_connections_usage"
  ["db.client.connections.max"]="db_client_connections_max"
  ["db.client.connections.pending_requests"]="db_client_connections_pending_requests"
  ["db.client.connections.wait_time"]="db_client_connections_wait_time_milliseconds"
  ["db.client.connections.use_time"]="db_client_connections_use_time_milliseconds"
  ["db.client.connections.create_time"]="db_client_connections_create_time_milliseconds"
  ["process.cpu.start_time"]="process_cpu_start_time_seconds"
)

# payload에서 OTel 메트릭명 추출
payload_otel_metrics=$(jq -r '
  .resourceMetrics[].scopeMetrics[].metrics[].name
' "${PAYLOADS_DIR}/metrics.json" 2>/dev/null | sort -u)

# OTel 메트릭명을 Prometheus 형식으로 변환한 목록 생성
declare -A PAYLOAD_PROM_METRICS
while IFS= read -r otel_name; do
  [[ -z "$otel_name" ]] && continue
  prom_name="${OTEL_TO_PROM[$otel_name]:-}"
  if [[ -n "$prom_name" ]]; then
    PAYLOAD_PROM_METRICS["$prom_name"]=1
  else
    # 알려지지 않은 매핑: 기본 변환 (. → _)
    fallback="${otel_name//./_}"
    PAYLOAD_PROM_METRICS["$fallback"]=1
  fi
done <<< "$payload_otel_metrics"

info "대시보드 필수 메트릭: ${#DASHBOARD_METRICS[@]}개"
info "Payload 메트릭: $(echo "$payload_otel_metrics" | grep -c . || echo 0)개"
echo ""

missing_metrics=()
for metric in "${DASHBOARD_METRICS[@]}"; do
  if [[ -n "${PAYLOAD_PROM_METRICS[$metric]:-}" ]]; then
    record_pass "메트릭 커버: ${metric}"
  else
    record_fail "메트릭 누락: ${metric}"
    missing_metrics+=("$metric")
  fi
done

# 대시보드 JSON에서 실제 사용 메트릭도 동적 추출하여 추가 검증
if [[ -d "${MONITORING_REPO}/grafana/dashboards" ]]; then
  echo ""
  info "대시보드 JSON에서 동적 메트릭 추출 중..."
  dashboard_metrics=$(find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f -exec \
    jq -r '
      .. | objects |
      select(.datasource?.type? == "prometheus" or .datasource?.uid? == "prometheus") |
      .targets[]? | select(.expr? and .expr != "") | .expr
    ' {} \; 2>/dev/null | \
    grep -oE '[a-z][a-z_]*[a-z](\{|[[:space:]])' | \
    sed 's/[{ ]$//' | \
    grep -E '_' | \
    sort -u || true)

  if [[ -n "$dashboard_metrics" ]]; then
    extra_count=0
    while IFS= read -r dm; do
      [[ -z "$dm" ]] && continue
      # 이미 DASHBOARD_METRICS에 있는 것은 건너뜀
      already_checked=false
      for known in "${DASHBOARD_METRICS[@]}"; do
        if [[ "$dm" == "$known" ]]; then
          already_checked=true
          break
        fi
      done
      [[ "$already_checked" == "true" ]] && continue
      # histogram 파생 suffix (_bucket, _count, _sum)는 기본 메트릭이 있으면 OK
      base_metric="${dm%_bucket}"
      base_metric="${base_metric%_count}"
      base_metric="${base_metric%_sum}"
      if [[ "$base_metric" != "$dm" ]] && [[ -n "${PAYLOAD_PROM_METRICS[$base_metric]:-}" ]]; then
        continue
      fi
      # 인프라/Tempo 생성 메트릭은 OTel payload 범위 밖 → WARN
      if [[ "$dm" =~ ^(traces_|process_cpu_seconds|process_resident_memory|up|scrape_) ]]; then
        continue  # 인프라 메트릭, payload 검증 대상 아님
      fi
      if [[ -z "${PAYLOAD_PROM_METRICS[$dm]:-}" ]]; then
        record_warn "동적 추출 메트릭 미확인: ${dm} (매핑 테이블에 없음)"
        extra_count=$((extra_count + 1))
      fi
    done <<< "$dashboard_metrics"
    [[ $extra_count -eq 0 ]] && info "동적 추출: 추가 누락 없음"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 2. LogQL label 커버리지
# ═══════════════════════════════════════════════════════════
header "LogQL label 커버리지"

# 대시보드에서 사용하는 Loki label 목록
DASHBOARD_LOG_LABELS=(
  "service_name"
  "log_type"
  "detected_level"
  "logger"
)

# payload에서 attribute key 추출
payload_log_attrs=$(jq -r '
  .resourceLogs[].scopeLogs[].logRecords[].attributes[]?.key
' "${PAYLOADS_DIR}/logs.json" 2>/dev/null | sort -u)

# resource attribute도 포함
payload_log_resource_attrs=$(jq -r '
  .resourceLogs[].resource.attributes[]?.key
' "${PAYLOADS_DIR}/logs.json" 2>/dev/null | sort -u)

# OTel 로그에서 Loki label로 변환되는 매핑
# service_name ← resource attribute service.name (Loki OTLP 자동 매핑)
# detected_level ← severityText (Loki OTLP 자동 매핑)
# log_type, logger ← log record attribute (otel index label로 설정)
declare -A LOG_LABEL_SOURCE
LOG_LABEL_SOURCE=(
  ["service_name"]="resource:service.name"
  ["log_type"]="attribute:log_type"
  ["detected_level"]="builtin:severityText"
  ["logger"]="attribute:logger"
)

info "대시보드 Loki label: ${#DASHBOARD_LOG_LABELS[@]}개"
echo ""

for label in "${DASHBOARD_LOG_LABELS[@]}"; do
  source="${LOG_LABEL_SOURCE[$label]:-unknown}"
  case "$source" in
    resource:*)
      attr_key="${source#resource:}"
      if echo "$payload_log_resource_attrs" | grep -qF "$attr_key"; then
        record_pass "Loki label 커버: ${label} ← resource.${attr_key}"
      else
        record_fail "Loki label 누락: ${label} ← resource.${attr_key} (payload에 없음)"
      fi
      ;;
    attribute:*)
      attr_key="${source#attribute:}"
      if echo "$payload_log_attrs" | grep -qF "$attr_key"; then
        record_pass "Loki label 커버: ${label} ← attribute.${attr_key}"
      else
        record_fail "Loki label 누락: ${label} ← attribute.${attr_key} (payload에 없음)"
      fi
      ;;
    builtin:*)
      field="${source#builtin:}"
      # severityText는 OTel 표준 필드 → Loki가 detected_level로 자동 매핑
      has_field=$(jq -r "
        .resourceLogs[].scopeLogs[].logRecords[] | select(.${field}? and .${field} != \"\") | .${field}
      " "${PAYLOADS_DIR}/logs.json" 2>/dev/null | head -1)
      if [[ -n "$has_field" ]]; then
        record_pass "Loki label 커버: ${label} ← ${field} (OTel 빌트인)"
      else
        record_fail "Loki label 누락: ${label} ← ${field} (payload에 없음)"
      fi
      ;;
    *)
      record_warn "Loki label 매핑 불명: ${label}"
      ;;
  esac
done

# 대시보드에서 동적 LogQL label 추출
if [[ -d "${MONITORING_REPO}/grafana/dashboards" ]]; then
  echo ""
  info "대시보드 LogQL에서 동적 label 추출 중..."
  logql_labels=$(find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f -exec \
    jq -r '
      .. | objects |
      select(.datasource?.type? == "loki" or .datasource?.uid? == "loki") |
      .targets[]? | select(.expr? and .expr != "") | .expr
    ' {} \; 2>/dev/null | \
    grep -oE '[a-z_]+\s*[=!~]' | \
    sed 's/[=!~ ]//g' | \
    sort -u || true)

  if [[ -n "$logql_labels" ]]; then
    extra_count=0
    while IFS= read -r ll; do
      [[ -z "$ll" ]] && continue
      already_checked=false
      for known in "${DASHBOARD_LOG_LABELS[@]}"; do
        if [[ "$ll" == "$known" ]]; then
          already_checked=true
          break
        fi
      done
      if [[ "$already_checked" == "false" ]]; then
        record_warn "동적 추출 Loki label: ${ll} (매핑 테이블에 없음, 확인 필요)"
        extra_count=$((extra_count + 1))
      fi
    done <<< "$logql_labels"
    [[ $extra_count -eq 0 ]] && info "동적 추출: 추가 label 없음"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 3. TraceQL attribute 커버리지
# ═══════════════════════════════════════════════════════════
header "TraceQL attribute 커버리지"

# payload에서 span attribute key 추출
payload_span_attrs=$(jq -r '
  .resourceSpans[].scopeSpans[].spans[].attributes[]?.key
' "${PAYLOADS_DIR}/traces.json" 2>/dev/null | sort -u)

# payload에서 resource attribute key 추출
payload_trace_resource_attrs=$(jq -r '
  .resourceSpans[].resource.attributes[]?.key
' "${PAYLOADS_DIR}/traces.json" 2>/dev/null | sort -u)

# 대시보드 TraceQL에서 사용하는 attribute 추출
DASHBOARD_SPAN_ATTRS=()
DASHBOARD_RESOURCE_ATTRS=()

if [[ -d "${MONITORING_REPO}/grafana/dashboards" ]]; then
  traceql_queries=$(find "${MONITORING_REPO}/grafana/dashboards" -name "*.json" -type f -exec \
    jq -r '
      .. | objects |
      select(.datasource?.type? == "tempo" or .datasource?.uid? == "tempo") |
      .targets[]? | select(.query? and .query != "") | .query
    ' {} \; 2>/dev/null || true)

  if [[ -n "$traceql_queries" ]]; then
    # span.* attribute 추출
    span_attrs=$(echo "$traceql_queries" | \
      grep -oE 'span\.[a-z_.]+' | \
      sed 's/^span\.//' | \
      sort -u || true)

    # resource.* attribute 추출
    resource_attrs=$(echo "$traceql_queries" | \
      grep -oE 'resource\.[a-z_.]+' | \
      sed 's/^resource\.//' | \
      sort -u || true)

    if [[ -n "$span_attrs" ]]; then
      while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        DASHBOARD_SPAN_ATTRS+=("$attr")
      done <<< "$span_attrs"
    fi

    if [[ -n "$resource_attrs" ]]; then
      while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        DASHBOARD_RESOURCE_ATTRS+=("$attr")
      done <<< "$resource_attrs"
    fi
  fi
fi

# span attribute가 없으면 기본 목록 사용
if [[ ${#DASHBOARD_SPAN_ATTRS[@]} -eq 0 ]]; then
  DASHBOARD_SPAN_ATTRS=(
    "http.request.method"
    "http.response.status_code"
    "http.route"
    "url.path"
    "db.system"
    "db.statement"
    "db.name"
  )
  info "대시보드 TraceQL 미발견 — 기본 span attribute 목록 사용"
fi

if [[ ${#DASHBOARD_RESOURCE_ATTRS[@]} -eq 0 ]]; then
  DASHBOARD_RESOURCE_ATTRS=(
    "service.name"
    "service.namespace"
    "deployment.environment.name"
  )
  info "대시보드 TraceQL 미발견 — 기본 resource attribute 목록 사용"
fi

# Tempo intrinsic attribute (span 자체 필드, OTel attribute가 아님)
TEMPO_INTRINSICS="kind status duration name rootName rootServiceName traceID spanID http.url"

info "span attribute: ${#DASHBOARD_SPAN_ATTRS[@]}개, resource attribute: ${#DASHBOARD_RESOURCE_ATTRS[@]}개"
echo ""

for attr in "${DASHBOARD_SPAN_ATTRS[@]}"; do
  # Tempo intrinsic은 OTel payload에 없어도 정상
  is_intrinsic=false
  for intrinsic in $TEMPO_INTRINSICS; do
    if [[ "$attr" == "$intrinsic" ]]; then
      is_intrinsic=true
      break
    fi
  done
  if [[ "$is_intrinsic" == "true" ]]; then
    record_pass "span attribute 커버: ${attr} (Tempo intrinsic)"
    continue
  fi
  if echo "$payload_span_attrs" | grep -qF "$attr"; then
    record_pass "span attribute 커버: ${attr}"
  else
    record_fail "span attribute 누락: ${attr} (payload에 없음)"
  fi
done

for attr in "${DASHBOARD_RESOURCE_ATTRS[@]}"; do
  if echo "$payload_trace_resource_attrs" | grep -qF "$attr"; then
    record_pass "resource attribute 커버: ${attr}"
  else
    record_fail "resource attribute 누락: ${attr} (payload에 없음)"
  fi
done

# ═══════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════
header "Summary"

echo -e "총 검증: ${BOLD}${TOTAL_CHECKS}${NC}개"
echo -e "  ${GREEN}PASS${NC}: ${PASS_COUNT}개"
echo -e "  ${RED}FAIL${NC}: ${FAIL_COUNT}개"
echo -e "  ${YELLOW}WARN${NC}: ${WARN_COUNT}개"
echo ""

if [[ ${#missing_metrics[@]} -gt 0 ]]; then
  echo -e "${RED}누락된 Prometheus 메트릭 (payload에 OTel 메트릭 추가 필요):${NC}"
  for m in "${missing_metrics[@]}"; do
    # 역매핑: Prometheus → OTel
    otel_name=""
    for otel_key in "${!OTEL_TO_PROM[@]}"; do
      if [[ "${OTEL_TO_PROM[$otel_key]}" == "$m" ]]; then
        otel_name="$otel_key"
        break
      fi
    done
    if [[ -n "$otel_name" ]]; then
      echo "  - ${m} ← OTel: ${otel_name}"
    else
      echo "  - ${m} (OTel 매핑 불명)"
    fi
  done
  echo ""
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo -e "${RED}${BOLD}결과: FAIL${NC} — payload 보강이 필요합니다."
  exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}결과: WARN${NC} — 확인이 필요한 항목이 있습니다."
  exit 0
else
  echo -e "${GREEN}${BOLD}결과: PASS${NC} — 모든 대시보드 메트릭/label/attribute가 payload에 포함되어 있습니다."
  exit 0
fi
