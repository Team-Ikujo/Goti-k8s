#!/usr/bin/env bash
# patch-jwks.sh — prod 8개 values.yaml의 jwks 필드를 일괄 치환.
#
# Usage:
#   JWKS='{"keys":[...]}' ./scripts/patch-jwks.sh
#
# 설계 결정:
# - yq 대신 sed line-replace 사용 — yq v4가 빈 줄/포맷을 재작성해서
#   idempotent 실패 (JWKS 값 동일인데 YAML 포맷 변경됨).
# - 대상 라인 패턴: `^    jwks: '.*'$` (4-space 들여쓰기 고정).
# - 매칭된 파일에 1개 라인만 있어야 함 (sed가 전역 치환해도 안전하지만 guard).
# - idempotent: 동일 JWKS면 파일 내용 변경 없음 (sed는 결과 동일 시 no-op).
#
# 이식성:
# - GNU sed / BSD sed 모두 `-i.bak` 패턴으로 동작 (macOS + ubuntu-latest 호환).

set -euo pipefail

if [[ -z "${JWKS:-}" ]]; then
  echo "error: JWKS env 변수 필수" >&2
  exit 1
fi

# 유효성: JSON 파싱 가능한지 (python 한 줄)
python3 -c "import json,sys; json.loads(sys.argv[1])" "$JWKS" 2>/dev/null || {
  echo "error: JWKS가 유효한 JSON이 아님" >&2
  exit 1
}

# sed replacement 특수문자(&, |, \) 이스케이프. JWKS는 single-quote로 감싸므로
# JWKS 내부에 single quote가 있으면 안 됨 (base64url/JSON에는 없음).
if [[ "$JWKS" == *"'"* ]]; then
  echo "error: JWKS에 single quote 포함 — values.yaml 포맷 충돌" >&2
  exit 1
fi
ESCAPED=$(printf '%s' "$JWKS" | sed -e 's/[\\&|]/\\&/g')

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "environments/prod/goti-payment/values.yaml"
  "environments/prod/goti-queue/values.yaml"
  "environments/prod/goti-resale/values.yaml"
  "environments/prod/goti-stadium/values.yaml"
  "environments/prod/goti-stadium-go/values.yaml"
  "environments/prod/goti-ticketing/values.yaml"
  "environments/prod/goti-ticketing-go/values.yaml"
  "environments/prod/goti-user/values.yaml"
)

cd "$REPO_ROOT"

for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "error: 대상 파일 없음: $f" >&2
    exit 1
  fi

  # 대상 라인 존재 확인 (정확히 1개여야 함)
  COUNT=$(grep -c "^    jwks: '" "$f" || true)
  if [[ "$COUNT" != "1" ]]; then
    echo "error: $f — jwks 라인 개수가 1이 아님 (found: $COUNT)" >&2
    exit 1
  fi

  # 4-space 들여쓰기 jwks 라인 전체 교체
  sed -i.bak "s|^    jwks: '.*'$|    jwks: '${ESCAPED}'|" "$f"
  rm -f "${f}.bak"

  echo "✓ patched: $f"
done

echo "done: ${#FILES[@]} files"
