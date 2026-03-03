.PHONY: up down port-forward lint validate status clean help

export CLUSTER_NAME ?= goti-dev
export ARGOCD_NAMESPACE ?= argocd
SHELL := /bin/bash

## 클러스터 관리
up: ## Kind 클러스터 생성 + ArgoCD 설치 + 부트스트랩
	@bash scripts/setup.sh

down: ## Kind 클러스터 삭제
	@bash scripts/teardown.sh

port-forward: ## Grafana/Prometheus/goti-server 포트포워딩
	@bash scripts/port-forward.sh

status: ## 클러스터 및 ArgoCD 상태 확인
	@echo "=== 클러스터 노드 ==="
	@kubectl get nodes -o wide 2>/dev/null || echo "클러스터에 연결할 수 없습니다"
	@echo ""
	@echo "=== ArgoCD Applications ==="
	@kubectl get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "ArgoCD가 설치되지 않았습니다"
	@echo ""
	@echo "=== Istio 상태 ==="
	@kubectl get pods -n istio-system 2>/dev/null || echo "Istio가 설치되지 않았습니다"
	@echo ""
	@echo "=== Pods (all namespaces) ==="
	@kubectl get pods -A --sort-by='.metadata.namespace' 2>/dev/null || true

## Helm 검증
lint: ## Helm charts lint
	helm lint charts/goti-server/ -f environments/dev/goti-server/values.yaml

validate: ## Helm template 렌더링 + dry-run 검증
	@echo "=== goti-server 렌더링 ==="
	helm dependency build charts/goti-server/
	helm template goti-server charts/goti-server/ \
		-f environments/dev/goti-server/values.yaml \
		--namespace goti | kubectl apply --dry-run=client -f -
	@echo ""
	@echo "=== 부트스트랩 매니페스트 검증 ==="
	kubectl apply --dry-run=client -f clusters/dev/bootstrap/

## 유틸리티
clean: ## Helm dependency cache 정리
	find charts/ -maxdepth 3 -name "charts" -type d -exec rm -rf {} + 2>/dev/null || true
	find charts/ -maxdepth 3 -name "*.tgz" -delete 2>/dev/null || true

help: ## 도움말 표시
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
