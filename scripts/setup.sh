#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="${CLUSTER_NAME:-goti-dev}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

echo "=== Goti Dev 환경 셋업 시작 ==="

# 1. Kind 클러스터 생성
echo "[1/4] Kind 클러스터 생성..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "  클러스터 '${CLUSTER_NAME}'가 이미 존재합니다. 건너뜁니다."
else
  kind create cluster --config "${ROOT_DIR}/kind/cluster-config.yaml" --wait 60s
  echo "  클러스터 생성 완료"
fi

# 2. 네임스페이스 생성
echo "[2/4] 네임스페이스 생성..."
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace goti --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# goti namespace에 istio sidecar injection 활성화
kubectl label namespace goti istio-injection=enabled --overwrite

# 3. ArgoCD Helm 설치
echo "[3/4] ArgoCD 설치..."
(
  cd "${ROOT_DIR}/infrastructure/argocd"
  helm dependency build
  helm upgrade --install argocd . \
    -n "${ARGOCD_NAMESPACE}" \
    -f values.yaml \
    -f values-dev.yaml \
    --wait --timeout 5m
)

# 4. 부트스트랩 적용
echo "[4/4] 부트스트랩 매니페스트 적용..."
kubectl apply -f "${ROOT_DIR}/clusters/dev/bootstrap/"

# ArgoCD 접속 정보 출력
echo ""
echo "=== 셋업 완료! ==="
echo ""
echo "ArgoCD 접속 정보:"
echo "  URL: http://localhost:30080"
echo "  Username: admin"
echo "  Password: 아래 명령으로 확인"
echo "    kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "포트포워딩: make port-forward"
echo "상태 확인: make status"
