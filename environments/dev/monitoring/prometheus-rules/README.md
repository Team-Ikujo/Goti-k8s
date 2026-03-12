# Prometheus Rules (Auto-Generated)

이 디렉토리의 `goti-*-rules.yaml` 파일은 **Goti-monitoring**에서 자동 생성됩니다.

## 수정 방법

1. **Goti-monitoring** 레포의 `prometheus/rules/` 에서 YAML 파일 수정
2. main에 push하면 `sync-to-k8s` workflow가 자동 실행
3. 이 레포에 sync PR이 생성됨 → 리뷰 후 머지

## 직접 수정 금지

이 디렉토리의 YAML 파일을 직접 수정하면 다음 sync에서 덮어씌워집니다.
규칙 변경은 반드시 Goti-monitoring에서 진행하세요.

## 생성 스크립트

`Goti-monitoring/scripts/generate-k8s-rules.sh`
