# Goti-k8s

> Goti 티켓팅 플랫폼의 **GitOps 레포지토리**.
> ArgoCD ApplicationSet + Istio Service Mesh + Helm Library Chart로 3개 클러스터(Kind dev / AWS EKS / GCP GKE)를 단일 소스로 선언적 운영한다.

---

## 프로젝트 요약

- **관리 대상**: MSA 서비스 7종 + 모니터링 스택 7종
- **클러스터 수**: 3 (dev-kind · prod-aws-eks · prod-gcp-gke)
- **GitOps 엔진**: ArgoCD v3.3 + ApplicationSet (List · Matrix Generator)
- **Service Mesh**: Istio 1.29 (sidecar + STRICT mTLS + AuthorizationPolicy)
- **핵심 디자인**: Library Chart(`goti-common`) + 3단 values overlay + Sync Wave 부트스트랩

---

## 왜 이런 구조인가

티켓팅 서비스는 한 순간의 트래픽 피크가 전체 시스템을 흔들기 때문에, 배포/롤백은 **사람의 개입 없이 Git 커밋만으로** 완결되어야 한다.
또 Multi-Cloud에서 7개 MSA를 관리하려면 **Chart 중복 없이 환경·클라우드별 편차만 오버라이드**할 수 있어야 한다.

이 두 요구사항을 다음 설계로 해결했다:

1. **goti-common** (Helm Library Chart) — Deployment / Service / Istio 정책 / HPA 템플릿 공유
2. **환경 × 클라우드 values overlay** — `values.yaml` → `values-aws.yaml` → 최종 merged
3. **ApplicationSet** — 7개 MSA를 List Generator로, 모니터링 스택 7개를 Matrix Generator로 자동 생성
4. **Sync Wave** — AppProject → Infrastructure → ApplicationSet 순서 보장

---

## 아키텍처

```
                  ┌───────────────── Git (Goti-k8s) ─────────────────┐
                  │ charts · environments · gitops · clusters · infra│
                  └───────────────────────┬──────────────────────────┘
                                          │
               ┌──────────────────────────┼──────────────────────────┐
               ▼                          ▼                          ▼
      ┌────────────────┐         ┌────────────────┐         ┌────────────────┐
      │   Kind (dev)   │         │  AWS EKS prod  │         │  GCP GKE prod  │
      │  4 nodes (1CP) │         │  Karpenter +   │         │  Regional +    │
      │  Istio + ArgoCD│         │  IRSA + Harbor │         │  WIF + Artif.  │
      └────────────────┘         └────────────────┘         └────────────────┘
             │                          │                          │
             └───────── ApplicationSet + Sync Wave 자동 ────────────┘
```

---

## 디렉토리

```
Goti-k8s/
├── charts/                     # Helm Charts
│   ├── goti-common/            #   Library Chart — 공통 템플릿
│   ├── goti-server/            #   Application Chart — MSA 7
│   ├── swagger-ui/             #   통합 Swagger 드롭다운 UI
│   └── synthetic-traffic/      #   K6 CronJob (smoke traffic)
├── environments/               # 환경별 values overlay
│   ├── dev/                    #   Kind
│   ├── prod/                   #   AWS (values.yaml + values-aws.yaml)
│   └── prod-gcp/               #   GCP (Workload Identity / Secret Manager)
├── gitops/                     # ArgoCD 리소스
│   └── {dev,prod,prod-gcp}/
│       ├── projects/           #   AppProject (RBAC / resource whitelist)
│       └── applicationsets/    #   MSA / Monitoring / Istio Policy
├── clusters/                   # 클러스터별 부트스트랩 진입점
│   └── {dev,prod,prod-gcp}/bootstrap/
│       ├── root-appsets.yaml   #   Sync Wave -2 / -1 / 0
│       ├── argocd-install.yaml #   ArgoCD Helm
│       └── istio-install.yaml  #   Istio CRD 사전 적용
├── infrastructure/             # 인프라 Helm 래퍼
│   ├── dev/                    #   ESO mock · Strimzi · OTEL Operator
│   ├── istio/                  #   Istio base / istiod / gateway
│   └── prod/                   #   Karpenter · Harbor · cert-manager
├── kind/cluster-config.yaml    # Kind 4노드 설정
├── manifests/
│   └── ecr-credential-renewer.yaml  # CronJob (6시간마다 ECR 토큰 갱신)
├── scripts/                    # setup / teardown / validate / db-seed
├── Makefile
└── README.md
```

---

## 주요 차트

| Chart | 타입 | 역할 |
|-------|------|------|
| `goti-common` | **Library** | Deployment, Service, VirtualService, DestinationRule, AuthorizationPolicy, RequestAuthentication, Sidecar, HPA(+KEDA), PDB, ServiceMonitor 템플릿 |
| `goti-server` | Application | 모든 MSA 공통 Chart — `goti-common`을 include하고 values만 교체 |
| `swagger-ui` | Application | 7개 서비스 OpenAPI 통합 드롭다운 |
| `synthetic-traffic` | Application | K6 CronJob으로 배포 직후 상시 smoke |

---

## Values Overlay 전략 (3단계)

```
charts/goti-server/values.yaml                      # ① Chart 기본값
  + environments/{env}/{service}/values.yaml        # ② 환경 공통 (replica, autoscaling, routing)
  + environments/{env}/{service}/values-{cloud}.yaml# ③ 클라우드 특화 (image registry, secret store)
                        ↓  Helm merge
                최종 manifest
```

이 구조 덕분에 환경·클라우드 편차(이미지 레지스트리, Secret Store, replica 수, Gateway 소속 namespace)가 **오버레이 한 파일**에만 격리된다. 예컨대 AWS 는 IRSA + SSM, GCP 는 Workload Identity + Secret Manager 로 서로 다른 Secret 주입 경로를 가지지만, 같은 Chart 와 같은 기본 values 를 공유한다.

---

## ApplicationSet 패턴

### 1) List Generator — MSA 7종을 단일 선언으로
```yaml
generators:
  - list:
      elements:
        - { service: user,     valuesFile: environments/prod/goti-user/values.yaml }
        - { service: stadium,  valuesFile: environments/prod/goti-stadium/values.yaml }
        # ... 7개
template:
  metadata:
    name: "goti-{{service}}-prod"
  spec:
    source:
      path: charts/goti-server
      helm:
        valueFiles:
          - "../../{{valuesFile}}"
          - "../../{{cloudValuesFile}}"
```

### 2) Matrix Generator — 모니터링 스택 자동 조립
`(env) × (component)` 매트릭스로 Prometheus / Loki / Tempo / Mimir / Pyroscope / OTEL Collector / Alertmanager를 한번에 동기화.

### 3) Sync Wave 부트스트랩
```
Wave -2 : AppProject (RBAC / 화이트리스트)
Wave -1 : Infrastructure (Istio CRD · ESO · cert-manager)
Wave  0 : ApplicationSet (MSA · 모니터링 · Istio Policy)
```

---

## 운영 자동화

- **ECR Credential Renewer**: 6시간 주기 CronJob이 ECR 토큰을 재발급해 `ecr-creds` Secret을 갱신. ArgoCD·Pod이 ImagePullBackOff에 빠지지 않는다.
- **DB Seeder**: `scripts/db-seed/` — 테스트 데이터(사용자·경기·좌석)를 idempotent하게 초기화.
- **Validate**: `scripts/validate/` — Helm lint / template dry-run으로 PR 전 차트 검증.

---

## 핵심 설계 결정

| # | 결정 | 효과 |
|---|------|------|
| 1 | Library Chart로 공통 템플릿 통합 | 서비스별 Chart 경량화, 정책 변경이 단일 커밋으로 전파 |
| 2 | 3단 values overlay | 환경·클라우드 편차만 격리, DRY 유지 |
| 3 | ApplicationSet List + Matrix | 7개 MSA + 7개 모니터링 스택을 선언 한 곳으로 |
| 4 | Sync Wave 부트스트랩 | CRD 선행, ESO 중간, 앱 마지막 — 순서 꼬임 제거 |
| 5 | STRICT mTLS + AuthorizationPolicy | 모든 in-mesh 트래픽 암호화 + JWT DENY 정책 |
| 6 | ServerSideApply + Force Sync 금지 | 대형 manifest diff 안정화, drift 방지 (ADR 명문화) |

---

## 기술 스택

**GitOps** ArgoCD v3.3 · ApplicationSet · AppProject · Helm v3
**Service Mesh** Istio 1.29 · Gateway API · AuthorizationPolicy · RequestAuthentication
**Scaling** KEDA · HPA · Karpenter · Cluster Autoscaler
**Secrets** External Secrets Operator (AWS SSM · GCP Secret Manager)
**Observability** kube-prometheus-stack · Loki · Tempo · Mimir · Pyroscope · OTEL Collector
**Security** Kyverno · NetworkPolicy · PodSecurity labels

---

## 연관 레포

| 레포 | 역할 |
|------|------|
| [Goti-Terraform](../Goti-Terraform) | 클러스터·DB·네트워크 프로비저닝 |
| [Goti-monitoring](../Goti-monitoring) | 모니터링 스택 values / 대시보드 |
| [Goti-server](../Goti-server) | 애플리케이션 (Spring Boot MSA) |

---

## 컨벤션

- **Commit**: `[TYPE] 설명 (#이슈번호)` — TYPE ∈ {FEAT, BUG, REFACTOR, TEST, DOCS, CHORE}
- **Branch**: `feature/*`, `chore/*`, `hotfix/*`
- **PR 템플릿**: `.github/pull_request_template.md`
