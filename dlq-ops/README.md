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

---

## 💡 모듈 상세 가이드 (Why, What, How)

### 왜 필요한가? (Why)
* **메시지 유실 방지 및 원인 분석**: 비동기 오디오 처리 도중 오류가 발생해 DLQ(Dead Letter Queue)로 유입된 유해(Poison) 메시지를 방치하면 데이터 손실 및 처리 실패로 이어집니다. DLQ에 실패 메시지가 도달하는 즉시 개발자에게 알려 분석 및 조치를 유도하기 위해 필요합니다.
* **독립성 유지**: 런타임 환경의 복잡한 테라폼 상태와 완전히 격리된 독립 모듈로 운영함으로써, 알림 채널(SNS) 및 모니터링 경보(Alarm) 설정의 변경이 핵심 서비스 환경에 부작용을 주는 것을 방지합니다.

### 무슨 기능을 하는가? (What)
* **실시간 DLQ 감시 경보**: `free-dlq`와 `paid-dlq` 큐의 대기 메시지 수를 상시 모니터링하여, 메시지가 1개라도 쌓이면 즉시 경보(Alarm) 상태로 전이되도록 CloudWatch Metric Alarm을 구성합니다.
* **이메일 알림 채널 연동**: 알람 발생 시 개발팀의 이메일로 즉시 경보 사실을 발송할 수 있도록 AWS SNS Topic(`securevoice-dev-dlq-alert`) 및 구독(Subscription) 설정을 연결합니다.

### 어떻게 사용하는가? (How)
1. `dlq-ops` 디렉터리로 이동합니다.
2. `terraform.tfvars` 파일을 생성하고 알림을 수신할 이메일 주소를 입력합니다:
   ```hcl
   dlq_alert_email = "your-team@email.com"
   ```
3. `terraform init` 및 `terraform apply`를 기동하여 알림 리소스를 배포합니다.
4. 지정한 이메일 수신함에서 AWS의 **SNS Subscription Confirmation** 메일을 열고 **Confirm subscription** 링크를 클릭하여 구독 승인을 완료해야 실제 장애 알림을 받을 수 있습니다.
