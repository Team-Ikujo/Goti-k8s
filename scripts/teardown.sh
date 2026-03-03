#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="goti-dev"

echo "=== Goti Dev 환경 삭제 ==="
read -p "정말 '${CLUSTER_NAME}' 클러스터를 삭제하시겠습니까? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

kind delete cluster --name "${CLUSTER_NAME}"
echo "클러스터 삭제 완료"
