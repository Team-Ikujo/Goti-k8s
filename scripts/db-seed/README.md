# DB Seed & Reset Scripts

EKS 클러스터 내 임시 pod을 띄워 RDS에 시드 데이터를 주입하거나 리셋하는 스크립트.

## 사전 준비

1. **AWS CLI** + **jq** 설치
2. **kubectl** 설치 + EKS context 설정
3. DB 접근 IAM 권한 (Secrets Manager 조회 포함)

```bash
# EKS context 설정
aws eks update-kubeconfig --name goti-cluster --region ap-northeast-2
```

## 환경변수 설정

```bash
cd scripts/db-seed
cp seed.env.example seed.env
# seed.env 편집 — 방법 A(직접 입력) 또는 방법 B(Secrets Manager) 택 1
```

## 시드 데이터 주입

```bash
# 전체 실행 (step0 → step1 → step2 → step3 순서)
./seed-2025/run.sh all

# 개별 실행
./seed-2025/run.sh step0    # 마스터 데이터 (팀+경기장+좌석+가격+2026경기)
./seed-2025/run.sh step1    # 2025 과거 경기 720건
./seed-2025/run.sh step2    # 좌석 상태 ~350만 행
./seed-2025/run.sh step3    # 유저 33만 + 주문/결제 ~15만
```

## 경기 리셋 (부하테스트 후)

```bash
# 4월 삼성/KIA 홈 전체 리셋
./reset-game.sh all

# 특정 경기만 리셋
./reset-game.sh <game_schedule_id>
```

## 실행 순서 및 데이터량

| Step | 내용 | 테이블 | 행 수 | 소요시간 |
|------|------|--------|------:|---------|
| **0-1** | 마스터 데이터 | baseball_teams, stadiums, home_stadiums, seat_grades, seat_sections, ticket_pricing_policies, ticket_prices | ~340 | ~5초 |
| **0-2** | 좌석 | seats | ~50K | ~30초 |
| **0-3** | 2026 경기일정 | game_schedules | 695 | ~5초 |
| **1** | 2025 과거 경기 | game_schedules, game_statuses, game_ticketing_statuses | 720×3 | ~10초 |
| **2** | 좌석 상태 | seat_statuses | ~350만 | ~5분 |
| **3** | 유저+주문 | users, members, orders, payments 등 | ~15만×4 | ~3분 |

> Step 0은 멱등 (ON CONFLICT DO NOTHING) — 재실행해도 안전합니다.

## 파일 구조

```
scripts/db-seed/
├── README.md
├── seed.env.example        # 환경변수 템플릿 (복사해서 seed.env 생성)
├── reset-game.sh           # 경기 리셋
└── seed-2025/
    ├── run.sh              # 메인 실행 스크립트
    ├── step0-master-data.sql   # 팀+경기장+등급+구역+가격 (88KB)
    ├── step0-seats.sql         # 좌석 50K (7.6MB)
    ├── step0-games-2026.sql    # 2026 경기일정 695건 (175KB)
    ├── step1-games.sql         # 2025 과거 경기
    ├── step2-seat-statuses.sql # 좌석 상태
    ├── step3-users-orders.sql  # 유저+주문+결제
    └── generate-step1.py       # Step 1 SQL 생성기
```
