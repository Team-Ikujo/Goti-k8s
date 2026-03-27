-- =============================================================================
-- Step 2: 좌석 상태 대량 INSERT (~350만 행)
--
-- 대상 테이블:
--   ticketing_service.seat_statuses
--
-- 의존성: Step 1 (game_schedules 존재해야 함)
-- 범위: 광주(KIA홈) + 대구(삼성홈) 경기만 (좌석 데이터가 이 2개 구장에만 존재)
--
-- 광주 좌석: 25,020석 × ~71경기 = ~178만
-- 대구 좌석: 25,116석 × ~68경기 = ~171만
-- 합계: ~350만 행
--
-- 예상 소요: 2~5분 (로컬 PostgreSQL 기준)
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 좌석 데이터가 있는 구장 ID
-- ─────────────────────────────────────────────────────────────────────────────
-- 광주-기아 챔피언스필드: 4553f1c7-f5c1-468f-8ac9-f4883eb59ebc (25,020석)
-- 대구삼성라이온즈파크:   49f8dfd8-ee9c-439b-bd6e-b31f01252d47 (25,116석)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2025 광주/대구 홈경기 중 아직 seat_statuses가 없는 경기
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE target_games AS
SELECT gs.id AS game_id, gs.stadium_id
FROM ticketing_service.game_schedules gs
WHERE gs.start_at >= '2025-01-01' AND gs.start_at < '2026-01-01'
  AND gs.stadium_id IN (
    '4553f1c7-f5c1-468f-8ac9-f4883eb59ebc',  -- 광주
    '49f8dfd8-ee9c-439b-bd6e-b31f01252d47'    -- 대구
  )
  AND NOT EXISTS (
    SELECT 1 FROM ticketing_service.seat_statuses ss
    WHERE ss.game_schedule_id = gs.id
  );

SELECT COUNT(*) AS target_game_count FROM target_games;

-- ─────────────────────────────────────────────────────────────────────────────
-- seat_statuses INSERT
-- 과거 경기이므로 전부 SOLD 처리 (약 80%)  + AVAILABLE (20% — 빈 좌석)
-- generate_series 대신 seats 테이블과 cross join
-- ─────────────────────────────────────────────────────────────────────────────

-- 배치 처리: 경기 10개씩 나눠서 INSERT (메모리 절약)
DO $$
DECLARE
  batch_size INT := 10;
  total_games INT;
  processed INT := 0;
  batch_start INT := 0;
  inserted BIGINT;
BEGIN
  SELECT COUNT(*) INTO total_games FROM target_games;
  RAISE NOTICE 'Total target games: %', total_games;

  WHILE batch_start < total_games LOOP
    INSERT INTO ticketing_service.seat_statuses (id, created_at, updated_at, status, game_schedule_id, seat_id)
    SELECT
      gen_random_uuid(),
      NOW(),
      NOW(),
      -- 80% SOLD, 20% AVAILABLE (과거 경기 잔여석 시뮬레이션)
      CASE WHEN random() < 0.8 THEN 'SOLD' ELSE 'AVAILABLE' END,
      tg.game_id,
      s.id
    FROM (
      SELECT game_id, stadium_id, ROW_NUMBER() OVER () AS rn
      FROM target_games
    ) tg
    JOIN ticketing_service.seat_sections ss ON ss.stadium_id = tg.stadium_id
    JOIN ticketing_service.seats s ON s.section_id = ss.id
    WHERE tg.rn > batch_start AND tg.rn <= batch_start + batch_size;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    processed := processed + inserted;
    batch_start := batch_start + batch_size;
    RAISE NOTICE 'Batch done: % rows inserted (total: %)', inserted, processed;
  END LOOP;

  RAISE NOTICE 'All done! Total seat_statuses inserted: %', processed;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 검증
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  '2025 seat_statuses' AS label,
  COUNT(*) AS count
FROM ticketing_service.seat_statuses ss
JOIN ticketing_service.game_schedules gs ON ss.game_schedule_id = gs.id
WHERE gs.start_at >= '2025-01-01' AND gs.start_at < '2026-01-01'
UNION ALL
SELECT '총 seat_statuses', COUNT(*) FROM ticketing_service.seat_statuses;

DROP TABLE IF EXISTS target_games;

COMMIT;
