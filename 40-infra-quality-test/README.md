# 40-infra-quality-test

SecureVoice 인프라 품질 테스트 스크립트 모음입니다.  
**팀 공유 Terraform 코드(10-/20-/30-)는 수정하지 않으며**, AWS 리소스를 직접 조회·검증합니다.

> SQS/DLQ 카오스 시나리오는 `01_sqs_dlq` 모듈로 통합되어 함께 제공됩니다.

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
| `01_sqs_dlq` | SQS/DLQ 이관 흐름, DLQ 알람, Redrive 및 멱등성 | `bash 01_sqs_dlq/run.sh` |
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
| SQS/DLQ | DLQ 이관 60s 이내, CloudWatch Alarm 발생, Redrive 메시지 소모, 멱등성 만족 |
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

# 테스트 이동
cd mzc-terraform/40-infra-quality-test
# 09만 단독 실행
bash run_all.sh 09
# 전체 실행 (09 포함)
bash run_all.sh

---

## 💡 모듈 상세 가이드 (Why, What, How)

### 왜 필요한가? (Why)
* **인프라 설정의 정합성 보증**: 테라폼으로 배포된 AWS 리소스들(VPC, Subnet, RDS, ECS, S3, IAM 등)이 최초에 의도한 설계 표준 및 보안 요구사항(예: Multi-AZ 활성화 여부, S3 퍼블릭 차단 등)을 충족하는지 자동화된 방식으로 확인하기 위해 필요합니다.
* **무중단 점검**: 팀의 메인 인프라 정의 코드(00-~20-)를 전혀 수정하지 않은 채, 읽기 전용(Read-Only) API 조회를 통해 실행 중인 운영 환경에 부작용 없이 인프라의 품질을 검증할 수 있습니다.

### 무슨 기능을 하는가? (What)
* **영역별 자동 검증 스크립트**:
  - `ecs_health`: 모든 ECS 서비스의 실행 상태(RUNNING) 및 API HTTP 응답 상태를 검증합니다.
  - `autoscaling`: CloudWatch Alarm의 임계치 및 알람 동작 조건 설정값을 확인합니다.
  - `rds_connectivity`: 데이터베이스의 고가용성(Multi-AZ), 삭제 방지 설정, 백업 주기 등을 점검합니다.
  - `alb_routing`: 로드밸런서의 상태, DNS 확인 및 API 엔드포인트 라우팅을 점검합니다.
  - `s3_security`: 중요 저장소(S3)의 KMS 암호화와 퍼블릭 접근 차단 여부를 체크합니다.
  - `iam_security`: ECS 태스크가 최소 권한 원칙에 맞추어 Secrets Manager 시크릿에 접근하고 있는지 검증합니다.
* **종합 결과 레포팅**: `run_all.sh` 스크립트를 통해 전체 테스트를 실행한 뒤 각 항목의 합격(PASS) / 불합격(FAIL) 상태를 요약 테이블 형태로 요약 제공합니다.

### 어떻게 사용하는가? (How)
1. `40-infra-quality-test` 디렉터리로 이동합니다.
2. 검증 도구용 의존성을 설치합니다: `pip install -r requirements.txt`
3. AWS STS 자격 증명을 활성화합니다.
4. `bash run_all.sh`를 실행하여 전체 품질 검사를 수행하고, 최종 요약 테이블을 분석하여 `[FAIL]` 항목이 존재할 경우 해당 인프라 설정을 수정합니다.