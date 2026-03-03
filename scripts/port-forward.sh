#!/usr/bin/env bash
set -euo pipefail

# 백그라운드 프로세스 정리
cleanup() {
  echo ""
  echo "포트포워딩 종료..."
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== 포트포워딩 시작 ==="
echo "ArgoCD:      http://localhost:30080 (NodePort, 포트포워딩 불필요)"
echo "Grafana:     http://localhost:3000"
echo "Prometheus:  http://localhost:9090"
echo "goti-server: http://localhost:8080"
echo ""
echo "종료: Ctrl+C"
echo ""

# Background port-forwards
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl port-forward -n goti svc/goti-server 8080:8080 &

# Wait for all background processes
wait
