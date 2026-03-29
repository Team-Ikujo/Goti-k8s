#!/usr/bin/env bash
# =============================================================================
# seed-seat-statuses.sh
# AVAILABLE 경기에 대해 해당 구장의 모든 좌석에 seat_statuses 레코드 생성
#
# 사용법:
#   ./scripts/seed-seat-statuses.sh                    # 기본 (localhost)
#   ./scripts/seed-seat-statuses.sh 172.20.0.1         # Kind에서 호스트 PC DB
#
# 전제: 구장/좌석/경기 시드 데이터가 이미 존재해야 함
# =============================================================================

set -euo pipefail

DB_HOST="${1:-localhost}"
DB_PORT="${2:-5432}"
DB_NAME="goti"
DB_USER="goti-db-server"

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

echo "=== seat_statuses 시드 시작 ==="
echo "DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"

# 1. 현재 상태 확인
echo ""
echo "--- 현재 AVAILABLE 경기 수 ---"
$PSQL -t -c "
  SELECT COUNT(*) FROM game_statuses
  WHERE status = 'AVAILABLE';
"

echo "--- 현재 seat_statuses 레코드 수 ---"
$PSQL -t -c "SELECT COUNT(*) FROM seat_statuses;"

# 2. AVAILABLE 경기 + 해당 구장의 좌석 조합으로 seat_statuses INSERT
# game_schedules → stadium_id → seat_sections → seats
echo ""
echo "--- seat_statuses INSERT (AVAILABLE 경기 × 구장 좌석) ---"

INSERTED=$($PSQL -t -c "
  WITH available_games AS (
    SELECT gs.id AS game_id, gs.stadium_id
    FROM game_schedules gs
    JOIN game_statuses gts ON gts.game_schedule_id = gs.id
    WHERE gts.status = 'AVAILABLE'
  ),
  stadium_seats AS (
    SELECT s.id AS seat_id, ss.stadium_id
    FROM seats s
    JOIN seat_sections ss ON s.seat_section_id = ss.id
  ),
  to_insert AS (
    SELECT
      gen_random_uuid() AS id,
      ag.game_id AS game_schedule_id,
      sts.seat_id,
      'AVAILABLE' AS status,
      NOW() AS created_at,
      NOW() AS updated_at
    FROM available_games ag
    JOIN stadium_seats sts ON ag.stadium_id = sts.stadium_id
    WHERE NOT EXISTS (
      SELECT 1 FROM seat_statuses existing
      WHERE existing.game_schedule_id = ag.game_id
        AND existing.seat_id = sts.seat_id
    )
  )
  INSERT INTO seat_statuses (id, game_schedule_id, seat_id, status, created_at, updated_at)
  SELECT id, game_schedule_id, seat_id, status, created_at, updated_at
  FROM to_insert;

  SELECT COUNT(*) FROM seat_statuses;
")

echo "총 seat_statuses 레코드: $INSERTED"

# 3. 검증
echo ""
echo "--- 검증: 경기별 좌석 상태 수 (상위 5건) ---"
$PSQL -c "
  SELECT
    gs.id AS game_id,
    gts.status,
    COUNT(ss.id) AS seat_count
  FROM game_schedules gs
  JOIN game_statuses gts ON gts.game_schedule_id = gs.id
  LEFT JOIN seat_statuses ss ON ss.game_schedule_id = gs.id
  WHERE gts.status = 'AVAILABLE'
  GROUP BY gs.id, gts.status
  ORDER BY seat_count DESC
  LIMIT 5;
"

echo "=== 완료 ==="
