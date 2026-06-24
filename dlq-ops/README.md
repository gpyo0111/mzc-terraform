# dlq-ops — DLQ 모니터링 Terraform 모듈

팀 공유 Terraform 디렉토리(00-, 10-, 20-, 30-)와 완전히 분리된 독립 모듈입니다.
20-runtime에서 생성된 `free-dlq` / `paid-dlq` 큐를 **data source**로 참조하므로
20-runtime state에 전혀 영향을 주지 않습니다.

## 생성 리소스

| 리소스 | 이름 | 설명 |
|---|---|---|
| `aws_sns_topic` | `securevoice-dev-dlq-alert` | DLQ 알림 채널 |
| `aws_sns_topic_subscription` | — | 이메일 구독 (옵션) |
| `aws_cloudwatch_metric_alarm` | `...-free-dlq-not-empty` | free-dlq 감시 |
| `aws_cloudwatch_metric_alarm` | `...-paid-dlq-not-empty` | paid-dlq 감시 |

## 설정 방법

```bash
cd mzc-terraform/dlq-ops/

# terraform.tfvars 생성
cat > terraform.tfvars <<EOF
dlq_alert_email = "your-team@email.com"
EOF

terraform init
terraform plan
terraform apply
```

> **참고**: SNS 이메일 구독 후 해당 이메일로 AWS 확인 링크가 발송됩니다.
> 링크를 클릭해야 실제 알림이 수신됩니다.

## Terraform State

- S3 bucket: `securevoice-terraform-state-455535733131-ap-northeast-2`
- Key: `securevoice/dev/dlq-ops/terraform.tfstate`
- 20-runtime state와 완전 분리 — 독립적으로 apply 가능
