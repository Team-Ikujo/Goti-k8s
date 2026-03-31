# Harbor Failover 설정 검증 및 테스트 가이드

## ✅ AlertManager 설정 검증 완료

Goti-monitoring 레포에 작성하신 설정이 완벽합니다!

### 핵심 포인트
1. **continue: true** → HarborDown이 여러 receiver로 전송됨
2. **harbor-failover-receiver** → Slack + Webhook 동시 실행
3. **slack-critical** → Critical 알림 추가 전송

---

## ⚠️ 한 가지 수정 필요

현재 `api_url: "SLACK_WEBHOOK_URL_PLACEHOLDER"`로 되어 있는데,
실제로는 다음과 같이 수정해야 합니다:

### 권장 방법: global에서 파일 참조

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      slack_api_url_file: /etc/alertmanager/secrets/alertmanager-slack-webhook/url
    route:
      # ... (기존 설정 유지)
    receivers:
      - name: "harbor-failover-receiver"
        slack_configs:
          - channel: "C0AHGKSGD5Y"
            title: "[{{ .Status | toUpper }}] Harbor 레지스트리 상태 변경"
            text: >-
              *Description*: {{ .CommonAnnotations.description }}
              *Action*: Harbor 장애 감지로 인해 ECR 전환 파이프라인(PR)이 트리거됩니다.
            # api_url 생략 → global.slack_api_url_file 사용
        webhook_configs:
          - url: "http://webhook-bridge.monitoring.svc:8080"
```

이렇게 하면 모든 receiver가 ExternalSecret으로 마운트된 webhook URL을 사용합니다.

---

## 🎯 Harbor 장애 시 실제 동작

```
Harbor 다운 (2분 이상)
  ↓
PrometheusRule: HarborDown (severity: critical)
  ↓
AlertManager 라우팅
  ├─→ harbor-failover-receiver
  │   ├─ Slack: "[FIRING] Harbor 레지스트리 상태 변경"
  │   └─ Webhook → GitHub Actions
  │       ├─ values.yaml 수정
  │       ├─ PR 생성
  │       └─ Slack: "🚨 Harbor 장애 감지 — ECR로 전환"
  │
  └─→ slack-critical (continue: true)
      └─ Slack: "[CRITICAL] HarborDown"
```

**Slack 채널 C0AHGKSGD5Y에 총 3개 알림 도착**

---

## 📋 배포 전 체크리스트

### 1. SSM 파라미터 저장
```bash
aws ssm put-parameter \
  --name /prod/monitoring/SLACK_WEBHOOK_URL \
  --value "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" \
  --type SecureString \
  --region ap-northeast-2
```

### 2. GitHub Secrets 설정
- `AWS_GITHUB_ACTIONS_ROLE_ARN`: OIDC role ARN

### 3. Goti-monitoring 레포 수정
- `global.slack_api_url_file` 추가
- 각 receiver에서 `api_url` 제거 (global 사용)

### 4. ArgoCD 동기화
```bash
# ExternalSecret 배포
argocd app sync external-secrets-config-prod

# monitoring-custom 동기화 (webhook-bridge 등)
argocd app sync monitoring-custom

# kube-prometheus-stack 동기화 (AlertManager 설정)
argocd app sync kube-prometheus-stack-prod
```

---

## 🧪 테스트 방법

### 방법 1: GitHub Actions 수동 실행 (안전)
```bash
gh workflow run harbor-failover.yml -f action=activate
```
- PR 생성 + Slack 알림만 테스트
- AlertManager는 테스트 안 됨

### 방법 2: AlertManager 테스트 (권장)
```bash
# AlertManager pod 이름 확인
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager

# 테스트 alert 전송
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-prod-alertmanager-0 -- \
  amtool alert add \
    alertname=HarborDown \
    severity=critical \
    summary="Harbor registry 장애 감지" \
    description="harbor.go-ti.shop 헬스체크 2분 이상 실패"
```

예상 결과:
- Slack 3개 알림
- GitHub Actions 트리거
- PR 자동 생성

---

## ✅ 최종 확인

모든 설정이 완료되면 Harbor 장애 시:
1. **즉시 (2분 후)**: Slack 알림 2개 (AlertManager)
2. **30초 후**: Slack 알림 1개 + PR 생성 (GitHub Actions)
3. **수동**: 팀원이 PR 머지 → ArgoCD 동기화 → ECR 전환 완료
