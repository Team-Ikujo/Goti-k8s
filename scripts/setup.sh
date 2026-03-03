#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="goti-dev"
ARGOCD_NAMESPACE="argocd"

echo "=== Goti Dev 환경 셋업 시작 ==="

# 1. Kind 클러스터 생성
echo "[1/5] Kind 클러스터 생성..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "  클러스터 '${CLUSTER_NAME}'가 이미 존재합니다. 건너뜁니다."
else
  kind create cluster --config "${ROOT_DIR}/kind/cluster-config.yaml" --wait 60s
  echo "  클러스터 생성 완료"
fi

# 2. Istio namespace 생성
echo "[2/5] 네임스페이스 생성..."
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace goti --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# goti namespace에 istio sidecar injection 활성화
kubectl label namespace goti istio-injection=enabled --overwrite

# 3. ArgoCD Helm 설치
echo "[3/5] ArgoCD 설치..."
cd "${ROOT_DIR}/infrastructure/argocd"
helm dependency build
helm upgrade --install argocd . \
  -n ${ARGOCD_NAMESPACE} \
  -f values.yaml \
  -f values-dev.yaml \
  --wait --timeout 5m

# 4. ArgoCD 준비 대기
echo "[4/5] ArgoCD 준비 대기..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n ${ARGOCD_NAMESPACE} --timeout=300s

# 5. 부트스트랩 적용
echo "[5/5] 부트스트랩 매니페스트 적용..."
kubectl apply -f "${ROOT_DIR}/clusters/dev/bootstrap/"

# ArgoCD 초기 비밀번호 출력
echo ""
echo "=== 셋업 완료! ==="
echo ""
echo "ArgoCD 접속 정보:"
echo "  URL: http://localhost:30080"
ARGOCD_PASSWORD=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "비밀번호를 가져올 수 없습니다")
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "포트포워딩: make port-forward"
echo "상태 확인: make status"
