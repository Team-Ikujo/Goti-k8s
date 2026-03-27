#!/usr/bin/env python3
"""
Step 1: 2025 KBO 720경기 INSERT SQL 생성
CSV → SQL VALUES 인라인 변환

출력: /tmp/seed-2025-step1.sql
"""
import csv

# 팀 매핑
TEAM_MAP = {
    'KIA': 'e5f58f8c-fcde-4017-8033-d8deb34fd4a2',
    'KT':  '1e4022c6-3887-44f6-b510-d98aad5a4192',
    'LG':  'f44d1e89-e2fe-40e7-a587-1157d7a9c80a',
    'NC':  '72c57b65-9f68-4b6e-b9e3-2ec9074861f6',
    'SSG': 'c33af471-d869-4af1-9b68-d085472e4408',
    '두산': 'd64b4220-6479-4e77-986a-f52447a433a6',
    '롯데': 'd7b12b0f-c69d-4a7f-badc-04226daabb5f',
    '삼성': '412cfc77-2c5d-4583-8e79-968339223864',
    '키움': '520af775-e84b-4112-aa02-18ed1a6c8458',
    '한화': '34159d27-2497-44d4-a4a2-c461dc3585c8',
}

# 구장 매핑
STADIUM_MAP = {
    '잠실': '51ed7860-a8cc-4114-91da-17819a32477d',
    '문학': '4e549730-9335-4cf4-8feb-d925b533dcda',
    '대구': '49f8dfd8-ee9c-439b-bd6e-b31f01252d47',
    '수원': '4a847659-3f7a-4095-b607-04aaccc1bfc2',
    '광주': '4553f1c7-f5c1-468f-8ac9-f4883eb59ebc',
    '사직': '0e4267d9-5165-4721-b353-c45e9650a801',
    '창원': 'fb13ef6c-5395-4dbe-8798-11be620f8893',
    '고척': 'f1d93bc6-789e-4bc9-93cc-f1195c763114',
    '대전': 'd9e206dc-b968-4aeb-8198-8f5d55f6c1dd',
    '포항': '49f8dfd8-ee9c-439b-bd6e-b31f01252d47',  # 삼성 홈
    '울산': '0e4267d9-5165-4721-b353-c45e9650a801',   # 사직
}

def game_result(home_score, away_score):
    if home_score > away_score:
        return 'HOME_WIN'
    elif home_score < away_score:
        return 'AWAY_WIN'
    return 'DRAW'

# CSV 로드
with open('/tmp/kbo_2025_schedule.csv') as f:
    reader = csv.DictReader(f)
    games = [r for r in reader if r['status'] == 'completed']

print(f'{len(games)}경기 로드')

out = '/tmp/seed-2025-step1.sql'
with open(out, 'w') as f:
    f.write("-- Auto-generated: 2025 KBO 720경기 INSERT\n")
    f.write("-- 테이블: game_schedules, game_statuses, game_ticketing_statuses\n\n")
    f.write("BEGIN;\n\n")

    # game_schedules
    f.write("-- 1. game_schedules\n")
    f.write("INSERT INTO ticketing_service.game_schedules (id, created_at, updated_at, away_team_id, home_team_id, league_type, stadium_id, start_at) VALUES\n")
    values = []
    game_ids = []  # (idx, start_at, home, away, home_score, away_score) 보관
    for i, g in enumerate(games):
        home_id = TEAM_MAP[g['home_team']]
        away_id = TEAM_MAP[g['away_team']]
        stadium_id = STADIUM_MAP[g['stadium']]
        start_at = f"{g['date']} {g['time']}"
        # 고정 UUID: md5 해시 기반으로 재실행 시 충돌 방지
        values.append(
            f"  (gen_random_uuid(), NOW(), NOW(), '{away_id}', '{home_id}', 'REGULAR', '{stadium_id}', '{start_at}'::TIMESTAMP)"
        )
        game_ids.append({
            'start_at': start_at,
            'home': g['home_team'],
            'away': g['away_team'],
            'home_score': int(g['home_score']),
            'away_score': int(g['away_score']),
            'stadium': g['stadium'],
        })
    f.write(',\n'.join(values) + ';\n\n')

    # 방금 INSERT한 game_id 수집 (2025년 + game_statuses 없는 것)
    f.write("-- 2025 신규 경기 ID 수집\n")
    f.write("""CREATE TEMP TABLE new_2025_games AS
SELECT gs.id AS game_id, gs.start_at, gs.home_team_id, gs.away_team_id, gs.stadium_id
FROM ticketing_service.game_schedules gs
WHERE gs.start_at >= '2025-01-01' AND gs.start_at < '2026-01-01'
  AND NOT EXISTS (SELECT 1 FROM ticketing_service.game_statuses gst WHERE gst.game_schedule_id = gs.id);

""")

    # game_statuses: 경기 결과를 start_at + team_id로 매칭
    f.write("-- 2. game_statuses (경기 결과)\n")
    f.write("CREATE TEMP TABLE game_results (start_at TIMESTAMP, home_team_id UUID, home_score INT, away_score INT, result TEXT);\n")
    f.write("INSERT INTO game_results VALUES\n")
    result_values = []
    for g in game_ids:
        home_id = TEAM_MAP[g['home']]
        result = game_result(g['home_score'], g['away_score'])
        result_values.append(
            f"  ('{g['start_at']}'::TIMESTAMP, '{home_id}', {g['home_score']}, {g['away_score']}, '{result}')"
        )
    f.write(',\n'.join(result_values) + ';\n\n')

    f.write("""INSERT INTO ticketing_service.game_statuses (id, created_at, updated_at, away_team_score, game_result, game_status, home_team_score, game_schedule_id)
SELECT
  gen_random_uuid(), NOW(), NOW(),
  gr.away_score, gr.result, 'FINISHED', gr.home_score,
  ng.game_id
FROM new_2025_games ng
JOIN game_results gr ON gr.start_at = ng.start_at AND gr.home_team_id = ng.home_team_id;

""")

    # game_ticketing_statuses
    f.write("-- 3. game_ticketing_statuses (TERMINATED — 과거 종료 경기)\n")
    f.write("""INSERT INTO ticketing_service.game_ticketing_statuses (id, created_at, updated_at, status, ticketing_end_at, ticketing_opened_at, game_schedule_id)
SELECT
  gen_random_uuid(), NOW(), NOW(),
  'TERMINATED',
  ng.start_at + INTERVAL '1 hour',
  ng.start_at - INTERVAL '2 days',
  ng.game_id
FROM new_2025_games ng;

""")

    # 검증
    f.write("-- 검증\n")
    f.write("""SELECT '신규 2025 경기' AS label, COUNT(*) FROM new_2025_games
UNION ALL SELECT '총 game_schedules', COUNT(*) FROM ticketing_service.game_schedules
UNION ALL SELECT '총 game_statuses', COUNT(*) FROM ticketing_service.game_statuses
UNION ALL SELECT '총 game_ticketing_statuses', COUNT(*) FROM ticketing_service.game_ticketing_statuses;

""")

    f.write("DROP TABLE IF EXISTS new_2025_games;\n")
    f.write("DROP TABLE IF EXISTS game_results;\n")
    f.write("COMMIT;\n")

print(f'SQL 생성 완료: {out}')
