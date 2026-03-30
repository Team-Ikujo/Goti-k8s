#!/usr/bin/env bash
# =============================================================================
# Goti DB 시드 실행
#
# 사용법:
#   ./scripts/db-seed/seed-2025/run.sh step0    # 마스터 데이터 (팀+경기장+좌석+가격+2026경기)
#   ./scripts/db-seed/seed-2025/run.sh step1    # 2025 과거 경기 데이터 (720경기)
#   ./scripts/db-seed/seed-2025/run.sh step2    # 좌석 상태 (~350만 행)
#   ./scripts/db-seed/seed-2025/run.sh step3    # 유저 + 주문 + 결제
#   ./scripts/db-seed/seed-2025/run.sh all      # 전부 순서대로
#
# 환경변수 설정:
#   1) scripts/db-seed/seed.env 파일 생성 (seed.env.example 참고)
#   2) 또는 환경변수 직접 export
#
# DB credential 조회 우선순위:
#   AWS_SECRET_NAME 있으면 → Secrets Manager에서 자동 조회
#   없으면 → DB_HOST, DB_USER, DB_PASS 환경변수 사용
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_SEED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- .env 로드 ---
ENV_FILE="${SEED_ENV_FILE:-$DB_SEED_DIR/seed.env}"
if [[ -f "$ENV_FILE" ]]; then
  echo ">>> 환경변수 로드: $ENV_FILE"
  set -a; source "$ENV_FILE"; set +a
fi

# --- AWS Secrets Manager 연동 (optional) ---
if [[ -n "${AWS_SECRET_NAME:-}" ]]; then
  echo ">>> AWS Secrets Manager에서 DB credential 조회: $AWS_SECRET_NAME"

  if ! command -v aws &>/dev/null; then
    echo "ERROR: aws CLI가 설치되어 있지 않습니다." >&2
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq가 설치되어 있지 않습니다." >&2
    exit 1
  fi

  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$AWS_SECRET_NAME" \
    --region "${AWS_REGION:-ap-northeast-2}" \
    --query SecretString --output text)

  DB_HOST="${DB_HOST:-$(echo "$SECRET_JSON" | jq -r '.host')}"
  DB_PORT="${DB_PORT:-$(echo "$SECRET_JSON" | jq -r '.port')}"
  DB_NAME="${DB_NAME:-$(echo "$SECRET_JSON" | jq -r '.dbname // .database // "goti"')}"
  DB_USER="${DB_USER:-$(echo "$SECRET_JSON" | jq -r '.username')}"
  DB_PASS="${DB_PASS:-$(echo "$SECRET_JSON" | jq -r '.password')}"
fi

# --- 필수 환경변수 확인 ---
: "${DB_HOST:?ERROR: DB_HOST가 설정되지 않았습니다. seed.env를 확인하세요.}"
: "${DB_USER:?ERROR: DB_USER가 설정되지 않았습니다.}"
: "${DB_PASS:?ERROR: DB_PASS가 설정되지 않았습니다.}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-goti}"
NAMESPACE="${K8S_NAMESPACE:-goti}"

echo ""
echo "=== DB 접속 정보 ==="
echo "  Host:      $DB_HOST"
echo "  Port:      $DB_PORT"
echo "  Database:  $DB_NAME"
echo "  User:      $DB_USER"
echo "  Namespace: $NAMESPACE"
echo "  K8s Context: $(kubectl config current-context 2>/dev/null || echo 'unknown')"
echo ""
read -r -p "이 설정으로 진행하시겠습니까? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

# --- 공통 함수 ---
run_sql() {
  local sql_file="$1"
  local label="$2"
  local file_size
  local pod_name="psql-seed-$(date +%s)"
  file_size=$(wc -c < "$sql_file" | tr -d ' ')
  echo ""
  echo "=== $label ==="
  echo "SQL: $sql_file ($(( file_size / 1024 )) KB)"
  echo ""

  kubectl run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
    --image=postgres:17-alpine \
    --labels="app=psql-seed,version=seed" \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "'"$pod_name"'",
          "image": "postgres:17-alpine",
          "stdin": true,
          "env": [{"name": "PGPASSWORD", "value": "'"$DB_PASS"'"}],
          "securityContext": {"allowPrivilegeEscalation": false},
          "resources": {
            "requests": {"cpu": "100m", "memory": "256Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"}
          }
        }]
      }
    }' \
    -- psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    < "$sql_file"

  echo ""
  echo "=== $label 완료 ==="
}

step0() {
  run_sql "$SCRIPT_DIR/step0-master-data.sql" "Step 0-1: 마스터 데이터 (팀+경기장+연고지+등급+구역+가격)"
  run_sql "$SCRIPT_DIR/step0-seats.sql" "Step 0-2: 좌석 데이터 (~50K석)"
  run_sql "$SCRIPT_DIR/step0-games-2026.sql" "Step 0-3: 2026 경기 일정 (695경기)"
}

step1() {
  echo ">>> Python으로 Step 1 SQL 생성 중..."
  python3 "$SCRIPT_DIR/generate-step1.py"
  run_sql "/tmp/seed-2025-step1.sql" "Step 1: 2025 과거 경기 데이터 720건"
}

step2() {
  run_sql "$SCRIPT_DIR/step2-seat-statuses.sql" "Step 2: 좌석 상태 ~350만 행"
}

step3() {
  run_sql "$SCRIPT_DIR/step3-users-orders.sql" "Step 3: 유저 33만 + 주문/결제 ~15만"
}

case "${1:-}" in
  step0) step0 ;;
  step1) step1 ;;
  step2) step2 ;;
  step3) step3 ;;
  all)
    step0
    step1
    step2
    step3
    echo ""
    echo "=== 전체 시드 완료 ==="
    ;;
  *)
    echo "사용법: $0 {step0|step1|step2|step3|all}"
    echo ""
    echo "  step0  — 마스터 데이터 (팀, 경기장, 좌석, 가격, 2026 경기일정)"
    echo "  step1  — 2025 과거 경기 데이터 720건 (game_schedules, game_statuses)"
    echo "  step2  — 좌석 상태 ~350만 행 (seat_statuses, 광주/대구 홈경기)"
    echo "  step3  — 유저 33만 + 주문/결제 ~15만 (users, orders, payments 등)"
    echo "  all    — 전부 순서대로 실행 (step0→1→2→3)"
    echo ""
    echo "환경변수: seed.env.example 참고"
    exit 1
    ;;
esac
