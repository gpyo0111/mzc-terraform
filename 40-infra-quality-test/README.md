# 40-infra-quality-test

SecureVoice 인프라 품질 테스트 스크립트 모음입니다.  
**팀 공유 Terraform 코드(10-/20-/30-)는 수정하지 않으며**, AWS 리소스를 직접 조회·검증합니다.

> SQS/DLQ 카오스 시나리오는 `mzc-chaos-testing/scenarios/01_sqs_dlq` 에서 별도 관리합니다.

---

## 사전 준비

```bash
# 1. Python 패키지 설치
pip install -r requirements.txt

# 2. AWS 자격증명 확인
aws sts get-caller-identity --profile bya

# 3. 환경변수 확인 (필요 시 config.sh 수정)
cat config.sh
```

---

## 모듈별 실행

| 모듈 | 검증 영역 | 실행 |
|------|----------|------|
| `02_ecs_health` | ECS 서비스 상태, 태스크 RUNNING, 헬스체크 | `bash 02_ecs_health/run.sh` |
| `03_autoscaling` | CloudWatch Alarm, 스케일링 정책 설정값 | `bash 03_autoscaling/run.sh` |
| `04_rds_connectivity` | Multi-AZ, 백업 보존, Deletion Protection | `bash 04_rds_connectivity/run.sh` |
| `05_alb_routing` | ALB 헬스체크, 라우팅 규칙, DNS 응답 | `bash 05_alb_routing/run.sh` |
| `06_s3_security` | 퍼블릭 차단, KMS 암호화, IAM 접근 제어 | `bash 06_s3_security/run.sh` |
| `07_iam_security` | Task Role 정책, Secrets Manager 시크릿 | `bash 07_iam_security/run.sh` |

---

## 전체 실행

```bash
bash run_all.sh
```

`[PASS]` / `[FAIL]` 결과를 카운팅해서 최종 요약 테이블로 출력합니다.

---

## 합격 기준 요약

| 모듈 | 핵심 기준 |
|------|---------|
| ECS | api/free-worker/paid-worker 모두 RUNNING, Health Check 200 |
| AutoScaling | Scale-out Alarm threshold 설정값 정확 (free≥2, paid≥3) |
| RDS | Multi-AZ=true, BackupRetention=7, DeletionProtection=true |
| ALB | `/api/health` HTTP 200, `/api/*` 라우팅 규칙 존재 |
| S3 | 퍼블릭 차단 4개 플래그 ALL true, SSE-KMS 적용 |
| IAM | Task Role 정책 내 최소 권한 Action 목록, Secret 2개 존재 |

---

## 주의사항

- 이 테스트는 **읽기 전용(Read-Only)** 검증이 원칙입니다. 인프라 리소스를 변경하지 않습니다.
- `05_alb_routing/test_alb.py` 는 실제 HTTP 요청을 보내므로 ALB가 ACTIVE 상태여야 합니다.
- AWS CLI/SDK 권한이 필요합니다: `ecs:Describe*`, `rds:Describe*`, `s3:GetBucketPolicy`, `iam:GetRole`, `cloudwatch:DescribeAlarms`
