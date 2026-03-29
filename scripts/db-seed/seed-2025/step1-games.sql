-- =============================================================================
-- Step 1: 2025 KBO 경기 데이터 (720경기 + 결과 + 티켓팅 상태)
--
-- 대상 테이블:
--   ticketing_service.game_schedules          (720행)
--   ticketing_service.game_statuses           (720행)
--   ticketing_service.game_ticketing_statuses (720행)
--
-- 의존성: 없음 (팀/구장 ID는 하드코딩)
-- 예상 소요: ~10초
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 팀 ID 매핑 (stadium_service.baseball_teams 기준)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE team_map (kbo_name TEXT, team_id UUID) ON COMMIT DROP;
INSERT INTO team_map VALUES
  ('KIA',  'e5f58f8c-fcde-4017-8033-d8deb34fd4a2'),
  ('KT',   '1e4022c6-3887-44f6-b510-d98aad5a4192'),
  ('LG',   'f44d1e89-e2fe-40e7-a587-1157d7a9c80a'),
  ('NC',   '72c57b65-9f68-4b6e-b9e3-2ec9074861f6'),
  ('SSG',  'c33af471-d869-4af1-9b68-d085472e4408'),
  ('두산',  'd64b4220-6479-4e77-986a-f52447a433a6'),
  ('롯데',  'd7b12b0f-c69d-4a7f-badc-04226daabb5f'),
  ('삼성',  '412cfc77-2c5d-4583-8e79-968339223864'),
  ('키움',  '520af775-e84b-4112-aa02-18ed1a6c8458'),
  ('한화',  '34159d27-2497-44d4-a4a2-c461dc3585c8');

-- ─────────────────────────────────────────────────────────────────────────────
-- 구장 매핑 (CSV stadium → DB stadium_id)
-- 포항/울산은 홈팀 구장으로 대체
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE stadium_map (csv_name TEXT, stadium_id UUID) ON COMMIT DROP;
INSERT INTO stadium_map VALUES
  ('잠실',  '51ed7860-a8cc-4114-91da-17819a32477d'),
  ('문학',  '4e549730-9335-4cf4-8feb-d925b533dcda'),
  ('대구',  '49f8dfd8-ee9c-439b-bd6e-b31f01252d47'),
  ('수원',  '4a847659-3f7a-4095-b607-04aaccc1bfc2'),
  ('광주',  '4553f1c7-f5c1-468f-8ac9-f4883eb59ebc'),
  ('사직',  '0e4267d9-5165-4721-b353-c45e9650a801'),
  ('창원',  'fb13ef6c-5395-4dbe-8798-11be620f8893'),
  ('고척',  'f1d93bc6-789e-4bc9-93cc-f1195c763114'),
  ('대전',  'd9e206dc-b968-4aeb-8198-8f5d55f6c1dd'),
  -- 포항/울산 → 홈팀 구장으로 매핑
  ('포항',  '49f8dfd8-ee9c-439b-bd6e-b31f01252d47'),  -- 삼성 홈
  ('울산',  '0e4267d9-5165-4721-b353-c45e9650a801');   -- 롯데 홈(사직)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2025 KBO 경기 데이터 (CSV에서 추출한 720경기)
-- 임시 테이블에 먼저 적재 후 정규 테이블로 INSERT
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE raw_games (
  game_date   TEXT,
  game_time   TEXT,
  away_team   TEXT,
  home_team   TEXT,
  away_score  INT,
  home_score  INT,
  stadium     TEXT
) ON COMMIT DROP;

\copy raw_games FROM '/tmp/kbo_2025_completed.csv' WITH (FORMAT csv, HEADER true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. game_schedules INSERT
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO ticketing_service.game_schedules (id, created_at, updated_at, away_team_id, home_team_id, league_type, stadium_id, start_at)
SELECT
  gen_random_uuid(),
  NOW(),
  NOW(),
  at.team_id,
  ht.team_id,
  'REGULAR',
  sm.stadium_id,
  (rg.game_date || ' ' || rg.game_time)::TIMESTAMP
FROM raw_games rg
JOIN team_map ht ON ht.kbo_name = rg.home_team
JOIN team_map at ON at.kbo_name = rg.away_team
JOIN stadium_map sm ON sm.csv_name = rg.stadium;

-- 방금 INSERT한 2025 경기 ID 수집
CREATE TEMP TABLE new_game_ids AS
SELECT gs.id AS game_id, gs.start_at, gs.home_team_id, gs.away_team_id
FROM ticketing_service.game_schedules gs
WHERE gs.start_at >= '2025-01-01' AND gs.start_at < '2026-01-01'
  AND gs.id NOT IN (SELECT game_schedule_id FROM ticketing_service.game_statuses);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. game_statuses INSERT (경기 결과)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO ticketing_service.game_statuses (id, created_at, updated_at, away_team_score, game_result, game_status, home_team_score, game_schedule_id)
SELECT
  gen_random_uuid(),
  NOW(),
  NOW(),
  rg.away_score,
  CASE
    WHEN rg.home_score > rg.away_score THEN 'HOME_WIN'
    WHEN rg.home_score < rg.away_score THEN 'AWAY_WIN'
    ELSE 'DRAW'
  END,
  'FINISHED',
  rg.home_score,
  ngi.game_id
FROM new_game_ids ngi
JOIN raw_games rg ON (rg.game_date || ' ' || rg.game_time)::TIMESTAMP = ngi.start_at
JOIN team_map ht ON ht.team_id = ngi.home_team_id AND ht.kbo_name = rg.home_team;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. game_ticketing_statuses INSERT (티켓팅 종료 상태)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO ticketing_service.game_ticketing_statuses (id, created_at, updated_at, status, ticketing_end_at, ticketing_opened_at, game_schedule_id)
SELECT
  gen_random_uuid(),
  NOW(),
  NOW(),
  'CLOSED',
  ngi.start_at + INTERVAL '1 hour',          -- 경기 시작 1시간 후 마감
  ngi.start_at - INTERVAL '2 days',          -- 경기 2일 전 오픈
  ngi.game_id
FROM new_game_ids ngi;

-- ─────────────────────────────────────────────────────────────────────────────
-- 검증
-- ─────────────────────────────────────────────────────────────────────────────
SELECT '2025 game_schedules' AS label, COUNT(*) FROM new_game_ids
UNION ALL
SELECT '총 game_schedules', COUNT(*) FROM ticketing_service.game_schedules
UNION ALL
SELECT '총 game_statuses', COUNT(*) FROM ticketing_service.game_statuses
UNION ALL
SELECT '총 game_ticketing_statuses', COUNT(*) FROM ticketing_service.game_ticketing_statuses;

COMMIT;
