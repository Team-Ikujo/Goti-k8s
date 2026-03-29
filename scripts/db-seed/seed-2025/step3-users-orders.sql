-- =============================================================================
-- Step 3: 유저 + 주문 + 결제 대량 INSERT
--
-- 대상 테이블:
--   user_service.users              (~33만 추가 → 총 50만)
--   user_service.members            (~33만)
--   user_service.social_providers   (~33만)
--   ticketing_service.orders        (~15만, 광주/대구 경기만)
--   ticketing_service.order_items   (~15만)
--   ticketing_service.orderers      (~15만)
--   ticketing_service.tickets       (~15만)
--   payment_service.payments        (~15만)
--
-- 의존성: Step 1 (game_schedules), Step 2 (seat_statuses — SOLD 좌석 참조)
-- 예상 소요: 5~10분
-- =============================================================================

-- =========================================================================
-- Part A: 유저 33만명 추가 (현재 ~17만 → 총 50만)
-- =========================================================================
BEGIN;

DO $$
DECLARE
  batch_size INT := 50000;
  total_to_create INT := 330000;
  created INT := 0;
  batch_num INT := 0;
  inserted BIGINT;
BEGIN
  WHILE created < total_to_create LOOP
    batch_num := batch_num + 1;

    WITH new_users AS (
      INSERT INTO user_service.users (id, created_at, updated_at, birth_date, gender, mobile, name, role, status)
      SELECT
        gen_random_uuid(),
        NOW() - (random() * INTERVAL '365 days'),  -- 과거 1년 내 랜덤 가입일
        NOW(),
        ('1980-01-01'::DATE + (random() * 15000)::INT),  -- 1980~2021 랜덤 생년월일
        CASE WHEN random() < 0.5 THEN 'MALE' ELSE 'FEMALE' END,
        -- 모바일: 9 + batch_num(2자리) + seq(6자리) = 11자리
        '9' || LPAD(batch_num::TEXT, 2, '0') || LPAD(s::TEXT, 6, '0'),
        '시드유저-' || batch_num || '-' || s,
        'MEMBER',
        'ACTIVATED'
      FROM generate_series(1, LEAST(batch_size, total_to_create - created)) s
      RETURNING id
    ),
    -- members (1:1, 같은 ID)
    new_members AS (
      INSERT INTO user_service.members (id)
      SELECT id FROM new_users
      RETURNING id
    )
    -- social_providers
    INSERT INTO user_service.social_providers (id, created_at, updated_at, email, provider, provider_id, member_id)
    SELECT
      gen_random_uuid(),
      NOW(),
      NOW(),
      'seed-' || id::TEXT || '@goti.test',
      'KAKAO',
      'kakao-seed-' || id::TEXT,
      id
    FROM new_members;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    created := created + batch_size;
    RAISE NOTICE 'Users batch %: % providers created (total users ~%)', batch_num, inserted, LEAST(created, total_to_create);
  END LOOP;
END $$;

-- 검증
SELECT 'users' AS tbl, COUNT(*) FROM user_service.users
UNION ALL SELECT 'members', COUNT(*) FROM user_service.members
UNION ALL SELECT 'social_providers', COUNT(*) FROM user_service.social_providers;

COMMIT;

-- =========================================================================
-- Part B: 주문 + 결제 (광주/대구 2025 경기, SOLD 좌석 기반)
--
-- 로직:
--   1. 2025 SOLD seat_statuses에서 경기별로 일부 좌석을 주문 데이터로 변환
--   2. 경기당 최대 1000건 주문 (1인 1~4석)
--   3. orders → order_items → orderers → tickets → payments 순서
--
-- SOLD 좌석 ~280만 (350만 × 80%) 중 경기당 1000건 → ~14만 주문
-- =========================================================================
BEGIN;

-- 주문에 사용할 유저 풀 (기존 + 신규 합쳐서 랜덤 선택)
CREATE TEMP TABLE user_pool AS
SELECT id AS user_id, mobile, name,
       ROW_NUMBER() OVER (ORDER BY random()) AS rn
FROM user_service.users
LIMIT 200000;  -- 20만명 풀

-- 2025 광주/대구 경기 목록
CREATE TEMP TABLE order_target_games AS
SELECT gs.id AS game_id, gs.start_at, gs.stadium_id,
       ROW_NUMBER() OVER (ORDER BY gs.start_at) AS game_seq
FROM ticketing_service.game_schedules gs
WHERE gs.start_at >= '2025-01-01' AND gs.start_at < '2026-01-01'
  AND gs.stadium_id IN (
    '4553f1c7-f5c1-468f-8ac9-f4883eb59ebc',
    '49f8dfd8-ee9c-439b-bd6e-b31f01252d47'
  );

SELECT COUNT(*) AS order_target_game_count FROM order_target_games;

-- ─────────────────────────────────────────────────────────────────────────────
-- 경기별 배치 처리
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  g RECORD;
  orders_per_game INT := 1000;
  game_count INT := 0;
  total_orders BIGINT := 0;
  batch_inserted BIGINT;
BEGIN
  FOR g IN SELECT * FROM order_target_games ORDER BY start_at LOOP
    game_count := game_count + 1;

    -- 이 경기의 SOLD 좌석에서 orders_per_game개만 사용
    CREATE TEMP TABLE batch_sold_seats ON COMMIT DROP AS
    SELECT ss.id AS seat_status_id, ss.seat_id,
           ROW_NUMBER() OVER (ORDER BY random()) AS seat_rn
    FROM ticketing_service.seat_statuses ss
    WHERE ss.game_schedule_id = g.game_id
      AND ss.status = 'SOLD'
    LIMIT orders_per_game;

    -- orders INSERT
    CREATE TEMP TABLE batch_orders ON COMMIT DROP AS
    WITH ins AS (
      INSERT INTO ticketing_service.orders (id, created_at, updated_at, canceled_at, confirmed_at, member_id, order_number, order_status, total_amount, total_quantity, game_schedule_id)
      SELECT
        gen_random_uuid(),
        g.start_at - INTERVAL '2 days' + (random() * INTERVAL '47 hours'),  -- 오픈~경기 1시간 전
        g.start_at,
        NULL,
        g.start_at - INTERVAL '2 days' + (random() * INTERVAL '47 hours'),
        up.user_id,
        'ORD-2025-' || g.game_seq || '-' || bss.seat_rn,
        'CONFIRMED',
        15000,   -- 임의 금액
        1,
        g.game_id
      FROM batch_sold_seats bss
      JOIN user_pool up ON up.rn = ((bss.seat_rn - 1) % 200000) + 1
      RETURNING id, member_id, game_schedule_id, order_number, confirmed_at
    )
    SELECT * FROM ins;

    -- order_items INSERT
    CREATE TEMP TABLE batch_order_items ON COMMIT DROP AS
    WITH ins AS (
      INSERT INTO ticketing_service.order_items (id, created_at, updated_at, item_status, ticket_price, ticket_type, order_id, seat_id, hold_id)
      SELECT
        gen_random_uuid(),
        bo.confirmed_at,
        bo.confirmed_at,
        'PAID',
        15000,
        'ADULT',
        bo.id,
        bss.seat_id,
        gen_random_uuid()  -- 과거 hold ID (참조만)
      FROM batch_orders bo
      JOIN batch_sold_seats bss ON bss.seat_rn = SUBSTRING(bo.order_number FROM '[0-9]+$')::INT
      RETURNING id, order_id, seat_id
    )
    SELECT * FROM ins;

    -- orderers INSERT
    INSERT INTO ticketing_service.orderers (id, created_at, updated_at, email, mobile, name, order_id)
    SELECT
      gen_random_uuid(),
      bo.confirmed_at,
      bo.confirmed_at,
      'seed-' || bo.member_id::TEXT || '@goti.test',
      up.mobile,
      up.name,
      bo.id
    FROM batch_orders bo
    JOIN user_pool up ON up.user_id = bo.member_id;

    -- tickets INSERT
    INSERT INTO ticketing_service.tickets (id, issued_at, updated_at, game_date, game_id, game_title, order_item_id, resale_enabled_status, seat_info, ticket_number, ticket_status, user_id)
    SELECT
      gen_random_uuid(),
      bo.confirmed_at,
      bo.confirmed_at,
      g.start_at,
      g.game_id,
      '2025 KBO 정규시즌',
      boi.id,
      'DISABLED',
      'S' || boi.seat_id::TEXT,
      'TKT-2025-' || g.game_seq || '-' || ROW_NUMBER() OVER (),
      'ISSUED',
      bo.member_id
    FROM batch_order_items boi
    JOIN batch_orders bo ON bo.id = boi.order_id;

    -- payments INSERT (payment_service 스키마)
    INSERT INTO payment_service.payments (id, created_at, updated_at, idempotency_key, order_id, paid_at, payment_amount, payment_method, payment_status, payment_type)
    SELECT
      gen_random_uuid(),
      bo.confirmed_at,
      bo.confirmed_at,
      'seed-pay-' || bo.id::TEXT,
      bo.id,
      bo.confirmed_at,
      15000,
      'CARD',
      'SUCCESS',
      'PAYMENT'
    FROM batch_orders bo;

    GET DIAGNOSTICS batch_inserted = ROW_COUNT;
    total_orders := total_orders + batch_inserted;

    DROP TABLE IF EXISTS batch_sold_seats;
    DROP TABLE IF EXISTS batch_orders;
    DROP TABLE IF EXISTS batch_order_items;

    IF game_count % 20 = 0 THEN
      RAISE NOTICE 'Game %/~140: % payments (total orders ~%)', game_count, batch_inserted, total_orders;
    END IF;
  END LOOP;

  RAISE NOTICE 'All done! Total orders created: %', total_orders;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 검증
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'users' AS tbl, COUNT(*) FROM user_service.users
UNION ALL SELECT 'orders', COUNT(*) FROM ticketing_service.orders
UNION ALL SELECT 'order_items', COUNT(*) FROM ticketing_service.order_items
UNION ALL SELECT 'orderers', COUNT(*) FROM ticketing_service.orderers
UNION ALL SELECT 'tickets', COUNT(*) FROM ticketing_service.tickets
UNION ALL SELECT 'payments', COUNT(*) FROM payment_service.payments;

DROP TABLE IF EXISTS user_pool;
DROP TABLE IF EXISTS order_target_games;

COMMIT;
