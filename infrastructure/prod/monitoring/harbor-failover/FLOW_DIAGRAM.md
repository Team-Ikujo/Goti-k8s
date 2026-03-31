# Harbor Failover 전체 흐름도

## 🔴 Harbor 장애 발생 시

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 모니터링 감지                                                      │
└─────────────────────────────────────────────────────────────────────┘
  Blackbox Exporter (30초마다)
    ↓ probe harbor.go-ti.shop/api/v2.0/health
  probe_success == 0 (2분 연속)
    ↓
  PrometheusRule: HarborDown alert 발생

┌─────────────────────────────────────────────────────────────────────┐
│ 2. AlertManager 라우팅                                                │
└─────────────────────────────────────────────────────────────────────┘
  AlertManager
    ├─→ [Route 1] webhook-bridge (GitHub Actions 트리거)
    │     ↓
    │   webhook-bridge Pod
    │     ↓ POST /repos/Team-Ikujo/Goti-k8s/dispatches
    │   GitHub API
    │     ↓ repository_dispatch event
    │   GitHub Actions: harbor-failover.yml
    │     ├─ Harbor 헬스체크 재확인
    │     ├─ values.yaml 수정 (Harbor → ECR)
    │     ├─ PR 생성
    │     └─ Slack 알림 (C0AHGKSGD5Y)
    │
    └─→ [Route 2] slack-critical (즉시 팀 알림) ⚠️ 현재 미설정!
          ↓
        Slack 채널 (C0AHGKSGD5Y)
          "🚨 Harbor registry 장애 감지"

┌─────────────────────────────────────────────────────────────────────┐
│ 3. 수동 대응                                                          │
└─────────────────────────────────────────────────────────────────────┘
  팀원이 PR 확인
    ↓
  PR 머지
    ↓
  ArgoCD 자동 동기화
    ↓
  모든 서비스가 ECR에서 이미지 pull
```

## 🟢 Harbor 복구 시

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 복구 감지                                                          │
└─────────────────────────────────────────────────────────────────────┘
  Blackbox Exporter
    ↓ probe_success == 1 (2분 연속)
  PrometheusRule: HarborRecovered alert 발생

┌─────────────────────────────────────────────────────────────────────┐
│ 2. AlertManager 라우팅                                                │
└─────────────────────────────────────────────────────────────────────┘
  AlertManager
    ├─→ webhook-bridge → GitHub Actions
    │     ├─ values.yaml 수정 (ECR → Harbor)
    │     ├─ PR 생성
    │     └─ Slack 알림
    │
    └─→ slack-critical ⚠️ 현재 미설정!
          "✅ Harbor registry 복구 감지"
```

---

## ⚠️ 현재 문제점

### 1. AlertManager → Slack 직접 알림 없음
- **현재**: webhook-bridge로만 전송
- **필요**: slack-critical receiver 추가
- **영향**: Harbor 장애 시 GitHub Actions 실행 후에만 Slack 알림

### 2. 알림 타이밍 차이
| 알림 경로 | 타이밍 | 현재 상태 |
|---------|--------|----------|
| AlertManager → Slack | 장애 감지 즉시 (2분 후) | ❌ 미설정 |
| GitHub Actions → Slack | PR 생성 후 (~30초 추가) | ✅ 설정됨 |

---

## ✅ 완전한 설정을 위한 체크리스트

### Goti-k8s 레포 (현재 레포) ✅
- [x] ExternalSecret 생성 (alertmanager-slack-externalsecret.yaml)
- [x] GitHub Actions Slack 알림 추가
- [x] AWS OIDC 인증 설정

### Goti-monitoring 레포 ⚠️
- [ ] kube-prometheus-stack-values.yaml에 alertmanager 설정 추가
  - [ ] slack_api_url_file 설정
  - [ ] harbor-failover route (continue: true)
  - [ ] slack-critical receiver
  - [ ] alertmanagerSpec.secrets 추가

### AWS/Slack 설정 ⚠️
- [ ] SSM에 Slack webhook URL 저장
  ```bash
  aws ssm put-parameter \
    --name /prod/monitoring/SLACK_WEBHOOK_URL \
    --value "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" \
    --type SecureString \
    --region ap-northeast-2
  ```
- [ ] GitHub Secrets에 AWS_GITHUB_ACTIONS_ROLE_ARN 설정

---

## 🎯 최종 알림 흐름 (완전 설정 후)

Harbor 장애 발생 시:
1. **즉시 (2분 후)**: AlertManager → Slack "🚨 Harbor 장애 감지"
2. **30초 후**: GitHub Actions → Slack "🚨 PR 생성됨 (Harbor → ECR)"
3. **수동**: 팀원이 PR 머지 → ArgoCD 동기화

Harbor 복구 시:
1. **즉시 (2분 후)**: AlertManager → Slack "✅ Harbor 복구 감지"
2. **30초 후**: GitHub Actions → Slack "✅ PR 생성됨 (ECR → Harbor)"
3. **수동**: 팀원이 PR 머지 → ArgoCD 동기화
