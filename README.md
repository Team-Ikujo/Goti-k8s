# Goti-k8s

Goti 티켓팅 서비스의 Kubernetes GitOps 레포지토리.

## 전제조건

- [Kind](https://kind.sigs.k8s.io/) v0.31+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.33+
- [Helm](https://helm.sh/) v3.14+
- Docker Desktop 또는 Docker Engine

## 빠른 시작

```bash
# 1. 클러스터 생성 + 전체 스택 설치 (원커맨드)
make up

# 2. 포트포워딩 (Grafana, Prometheus, goti-server)
make port-forward

# 3. 상태 확인
make status

# 4. 클러스터 삭제
make down
```

## 접속 정보 (dev-kind)

| 서비스 | URL | 비고 |
|--------|-----|------|
| ArgoCD | http://localhost:30080 | admin / (초기 비밀번호) |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | - |
| goti-server | http://localhost:8080 | port-forward 필요 |
| Istio Gateway | http://localhost:31080 | - |

## 디렉토리 구조

```
Goti-k8s/
├── .github/                    # 이슈/PR 템플릿
├── kind/                       # Kind 클러스터 설정
│   └── cluster-config.yaml
├── infrastructure/             # 인프라 Helm 래퍼
│   ├── argocd/
│   └── istio/                  # Istio 서비스 메시
│       ├── base/               # CRDs
│       ├── istiod/             # Control Plane
│       └── gateway/            # Ingress Gateway
├── charts/                     # Helm Charts
│   ├── goti-common/            # Library Chart (공통 템플릿)
│   └── goti-server/            # Application Chart
├── environments/               # 환경별 values
│   └── dev/
│       ├── goti-server/
│       └── monitoring/
├── gitops/                     # ArgoCD 리소스
│   ├── projects/               # AppProject
│   └── applicationsets/        # ApplicationSet
├── clusters/                   # 클러스터별 부트스트랩
│   └── dev/bootstrap/
├── scripts/                    # 자동화 스크립트
├── Makefile
└── README.md
```

## 아키텍처

- **GitOps**: ArgoCD ApplicationSet (하이브리드 패턴)
- **서비스 메시**: Istio (sidecar injection + mTLS)
- **모니터링**: Prometheus + Grafana + Loki + Tempo + Alloy
- **Helm 패턴**: Library Chart (goti-common) + Application Chart

## Helm Commands

```bash
# Lint
make lint

# Template 렌더링 + dry-run 검증
make validate

# 캐시 정리
make clean
```

## 트러블슈팅

### ArgoCD 초기 비밀번호
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Pod 상태 확인
```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Istio sidecar 상태 확인
```bash
istioctl analyze -n goti
kubectl get pods -n goti -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
```

### ArgoCD Application 동기화
```bash
# 개별 앱 동기화
kubectl -n argocd patch application <app-name> --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# 또는 ArgoCD CLI
argocd app sync <app-name>
```

## 컨벤션

- Commit: `[TYPE] 설명 (#이슈번호)` (FEAT, BUG, REFACTOR, TEST, DOCS, CHORE)
- Branch: `feature/*`, `chore/*`, `hotfix/*`
- PR 템플릿: `.github/PULL_REQUEST_TEMPLATE.md` 참고
