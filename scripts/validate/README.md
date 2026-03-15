# Kind 클러스터 모니터링 검증 스크립트

Kind 클러스터의 모니터링 스택(Alloy → Mimir/Loki/Tempo)이 정상 동작하는지 검증하는 도구.

## 사전 조건

- `kubectl`이 Kind 클러스터에 연결되어 있어야 함
- `jq` 설치 (`brew install jq`)
- `yq` 설치 권장 (`brew install yq`) — 없으면 grep fallback
- Goti-monitoring 레포가 같은 프로젝트 루트에 있어야 함

## 사용법

### 전체 실행 (권장)

```bash
cd scripts/validate
./validate.sh
```

lint → port-forward → 테스트 데이터 전송 → 쿼리 추출 → 검증 → 리포트 순서로 자동 실행.

### 오프라인 Lint만 (클러스터 불필요, push 전 권장)

```bash
./validate.sh --lint-only
# 또는 직접 실행
./lint-dashboards.sh
./check-coverage.sh
```

대시보드 JSON의 pitfalls 위반을 검증 (TraceQL 변수, LogQL level, PromQL histogram 등 8개 체크).

### 테스트 데이터 전송 건너뛰기

이미 실제 트래픽 데이터가 있는 경우:

```bash
./validate.sh --skip-send
```

### 쿼리 추출만

```bash
./validate.sh --extract-only
```

### 개별 실행

```bash
# 1. 테스트 데이터 전송 (port-forward 선행 필요)
./send-test-data.sh http://localhost:14318

# 2. 쿼리 추출
./extract-queries.sh /path/to/Goti-monitoring

# 3. 쿼리 검증
MIMIR_URL=http://localhost:18080 \
LOKI_URL=http://localhost:13100 \
TEMPO_URL=http://localhost:13200 \
./validate-queries.sh ./extracted
```

## 파일 구조

```
scripts/validate/
├── validate.sh              # 메인 실행 (port-forward + lint + 전체 파이프라인)
├── lint-dashboards.sh       # 오프라인 pitfalls 검증 (클러스터 불필요)
├── check-coverage.sh        # 대시보드 ↔ 테스트 데이터 커버리지 확인
├── send-test-data.sh        # OTLP HTTP로 테스트 데이터 전송
├── extract-queries.sh       # 대시보드 JSON에서 PromQL/LogQL/TraceQL 추출
├── validate-queries.sh      # 추출된 쿼리를 API로 실행 검증
├── payloads/
│   ├── metrics.json         # OTel OTLP 메트릭 (HTTP, JVM, HikariCP, Buffer, Class)
│   ├── logs.json            # OTel OTLP 로그 (app/payment/audit, logger 포함)
│   └── traces.json          # OTel OTLP 트레이스 (정상/에러/느린, DB/Redis span)
├── extracted/               # (자동 생성) 추출된 쿼리 + 검증 리포트
└── README.md
```

## 테스트 데이터 사양

### Resource Attributes (모든 시그널 공통)

| Attribute | 값 |
|---|---|
| `service.name` | `goti-server` |
| `service.namespace` | `goti` |
| `deployment.environment.name` | `dev` |
| `service.version` | `test-0.0.1` |

### 메트릭

- `http.server.request.duration` — HTTP 요청 히스토그램 (GET 200, POST 201, GET 500)
- `goti.http.server.active_requests` — 활성 요청 수
- `jvm.memory.used/limit/committed` — JVM 메모리
- `jvm.gc.duration` — GC 시간
- `jvm.thread.count` — 스레드 수
- `jvm.cpu.recent_utilization` — CPU 사용률
- `db.client.connections.*` — HikariCP 커넥션 풀

### 로그

| log_type | 내용 |
|---|---|
| `app` | INFO 시작 로그, ERROR NullPointerException (trace_id 포함) |
| `payment` | SUCCESS/FAILED JSON 구조 로그 |
| `audit` | login 성공/실패 JSON 구조 로그 |

### 트레이스

| 시나리오 | 경로 | 특징 |
|---|---|---|
| 정상 | GET /api/tickets → DB + Redis | 50ms, status OK |
| 에러 | POST /api/orders → DB error | 100ms, status ERROR |
| 느린 | GET /api/tickets/search → slow DB | 800ms, status OK |

## 포트 매핑

| 서비스 | 클러스터 포트 | 로컬 포트 |
|---|---|---|
| Alloy OTLP HTTP | 4318 | 14318 |
| Mimir Query Frontend | 8080 | 18080 |
| Loki | 3100 | 13100 |
| Tempo | 3200 | 13200 |
