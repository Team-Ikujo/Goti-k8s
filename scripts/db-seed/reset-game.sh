#!/usr/bin/env bash
# 부하테스트 후 특정 경기의 모든 데이터를 초기화하는 스크립트
# 사용법: ./scripts/db-seed/reset-game.sh <game_schedule_id>
#         ./scripts/db-seed/reset-game.sh all   # 4월 삼성/KIA 홈 전체 리셋
#
# 환경변수: scripts/db-seed/seed.env (seed.env.example 참고)
#
# 초기화 대상: payments → tickets → order_items → orderers →
#             order_cancellations → orders → seat_holds → seat_statuses(→AVAILABLE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- .env 로드 ---
ENV_FILE="${SEED_ENV_FILE:-$SCRIPT_DIR/seed.env}"
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
NAMESPACE="${K8S_NAMESPACE:-default}"

GAME_ID="${1:-}"

if [[ -z "$GAME_ID" ]]; then
  echo "사용법: $0 <game_schedule_id | all>"
  echo ""
  echo "예시:"
  echo "  $0 c99d4eae-dae2-42a4-b81b-0005bc4a91f1   # 특정 경기"
  echo "  $0 all                                       # 4월 삼성/KIA 홈 전체"
  echo ""
  echo "환경변수: seed.env.example 참고"
  exit 1
fi

# game_schedule_id 필터 조건 생성
if [[ "$GAME_ID" == "all" ]]; then
  GAME_FILTER="IN (
    SELECT sch.id FROM ticketing_service.game_schedules sch
    JOIN stadium_service.baseball_teams ht ON ht.id = sch.home_team_id
    WHERE ht.display_name IN ('삼성', 'KIA')
      AND sch.start_at BETWEEN '2026-03-27' AND '2026-05-01'
  )"
  echo "리셋 대상: 4월 삼성/KIA 홈 전체 경기"
else
  GAME_FILTER="= '${GAME_ID}'"
  echo "리셋 대상: ${GAME_ID}"
fi

echo ""
echo "=== DB 접속 정보 ==="
echo "  Host:      $DB_HOST"
echo "  Database:  $DB_NAME"
echo "  Context:   $(kubectl config current-context 2>/dev/null || echo 'unknown')"
echo "  Namespace: $NAMESPACE"
echo ""
read -r -p "이 설정으로 리셋을 진행하시겠습니까? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

SQL=$(cat <<EOSQL
BEGIN;

-- 1. payments (order_id → orders.game_schedule_id)
DELETE FROM payment_service.payments
WHERE order_id IN (
  SELECT id FROM ticketing_service.orders WHERE game_schedule_id ${GAME_FILTER}
);

-- 2. tickets (order_item_id → order_items.order_id → orders.game_schedule_id)
DELETE FROM ticketing_service.tickets
WHERE order_item_id IN (
  SELECT oi.id FROM ticketing_service.order_items oi
  JOIN ticketing_service.orders o ON o.id = oi.order_id
  WHERE o.game_schedule_id ${GAME_FILTER}
);

-- 3. order_cancellations
DELETE FROM ticketing_service.order_cancellations
WHERE order_id IN (
  SELECT id FROM ticketing_service.orders WHERE game_schedule_id ${GAME_FILTER}
);

-- 4. order_items
DELETE FROM ticketing_service.order_items
WHERE order_id IN (
  SELECT id FROM ticketing_service.orders WHERE game_schedule_id ${GAME_FILTER}
);

-- 5. orderers
DELETE FROM ticketing_service.orderers
WHERE order_id IN (
  SELECT id FROM ticketing_service.orders WHERE game_schedule_id ${GAME_FILTER}
);

-- 6. orders
DELETE FROM ticketing_service.orders WHERE game_schedule_id ${GAME_FILTER};

-- 7. seat_holds
DELETE FROM ticketing_service.seat_holds WHERE game_schedule_id ${GAME_FILTER};

-- 8. seat_statuses → AVAILABLE
UPDATE ticketing_service.seat_statuses
SET status = 'AVAILABLE', updated_at = NOW()
WHERE game_schedule_id ${GAME_FILTER}
  AND status != 'AVAILABLE';

COMMIT;
EOSQL
)

echo "실행 중..."

kubectl run "reset-game-$(date +%s)" -n "$NAMESPACE" \
  --rm -it --restart=Never \
  --image=postgres:17-alpine \
  --timeout=300s \
  --env="PGPASSWORD=${DB_PASS}" \
  -- psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "${SQL}"

echo "리셋 완료"
