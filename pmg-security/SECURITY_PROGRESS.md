# 🔐 SecureVoice 보안 작업 진행상황 (pmg-security)

> 이 파일은 Claude와 사용자가 보안 작업을 이어서 진행하기 위한 **진행상황 추적 문서**입니다.
> 새 대화를 시작하면 Claude가 이 파일을 먼저 읽고 마지막 지점부터 이어갑니다.

## 0. 기본 전제 (Ground Rules)

- **작업 범위:** `mzc-terraform/pmg-security` 폴더 **안에서만** 코드 작성/수정. 다른 레이어 리소스는 `data` / `terraform_remote_state`로 읽기만.
- **배포 상태:** pmg-security는 **이미 AWS에 apply 완료(운영 중)**. → 모든 변경은 **무중단**을 전제로, apply 시 기존 리소스 영향도를 반드시 확인.
- **설명 방식:** 초등학생 눈높이 비유 + 보안 이점 + 운영 오버헤드(비용/관리) + apply 위험 함께 설명.
- **추가 범위:** Trivy CI/CD(GitHub Actions)까지 포함. 보안 런북 .md 문서까지 포함.
- **계정/리전:** account `455535733131`, 메인 `ap-northeast-2`(서울), 글로벌(WAF/CloudFront/SNS) `us-east-1` alias.

---

## 1. 전체 상태 요약 (체크리스트 대조)

범례: ✅ 완료 · 🟡 부분/주의 · ❌ 미완료 · ⏸️ 보류(결정필요) · 👥 팀 폴더에서 완료(범위 밖)

### 섹션 1. 자격증명 / 감사 로그
| 항목 | 상태 | 비고 |
|------|------|------|
| S3 수명주기(Lifecycle) | ✅ | 등급별 guest 7d / free 90d(30d Glacier) / paid 365d(30d Glacier) |
| CloudWatch 로그 30일 만료 | 🟡 | VPC flow log만 30일. 다른 로그그룹은 팀 폴더(20-runtime 14일) |
| Secrets Manager 격리 | 👥 | 10-persistent |
| ECS valueFrom 주입 | 👥 | 20-runtime |
| CloudTrail 멀티리전+무결성 | ✅ | monitoring_security.tf |
| CloudTrail→CloudWatch 스트리밍 | ⏸️ | 비용/필요성 설명 후 결정 |
| VPC Flow Logs | ✅ | CloudWatch行. Athena 쓰려면 S3行 추가 필요 |

### 섹션 2. 암호화 / 네트워크 격리
| 항목 | 상태 | 비고 |
|------|------|------|
| KMS CMK + 키순환 | ✅ | kms_security.tf |
| **KMS Key Policy 최소권한** | ❌ | 키 정책 없음 = 기본(루트 전체허용). **운영중 변경 시 고위험** |
| S3 SSE-KMS 강제 | ✅ | audio/model |
| Gateway/Interface 엔드포인트 | 👥 | 10-persistent / 20-runtime |
| 엔드포인트 아웃바운드 통제 | ✅ | VPCE SG inbound 10.0.0.0/22:443 |
| S3 퍼블릭 차단 | ✅ | 5개 버킷 |
| 보안그룹 체이닝 | ✅ | ECS→RDS, CloudFront PrefixList→ALB |

### 섹션 3. 접근통제 / DevSecOps
| 항목 | 상태 | 비고 |
|------|------|------|
| Execution/Task Role 분리 | 👥 | 20-runtime |
| IAM 와일드카드 제거 | 🟡 | S3는 타이트. flow-logs 정책에 `Resource="*"` 남음 |
| Trivy 스캐너 (CI/CD) | ❌ | GitHub Actions, Terraform 밖 |
| Trivy 크리티컬 차단+Slack | ❌ | |

### 섹션 4. 경계 보안 / 모니터링
| 항목 | 상태 | 비고 |
|------|------|------|
| WAFv2 (5룰) | ✅ | waf.tf. CloudFront 연결은 콘솔/수동 (확인 필요) |
| Managed Prefix List ALB우회차단 | ✅ | |
| Rate-based Rule (디도스) | ✅ | 2000/5분 Block |
| WAF Count 모드 | ✅ | 룰1~4 Count, 룰5만 Block → 나중에 Block 전환 튜닝 |
| GuardDuty | ⏸️ | 코드 존재. 비용/필요성 설명 후 결정. Slack연동 미완 |
| CloudWatch Logs Insights 보안쿼리 | ❌ | aws_cloudwatch_query_definition 없음 |
| 보안 런북(.md) | ❌ | |

---

## 2. 남은 작업 백로그 (진행 순서)

> **의존성 + 위험도 + 확정된 결정**을 반영해 갱신(2026-06-16). 각 항목 진행 시 상세 설명 + apply 위험 안내.

| # | 작업 | 위험도 | 상태 |
|---|------|--------|------|
| 1 | 코드 정리: `output "test"` 제거, 알림 이메일 변수화 | 낮음 | ✅ 완료 |
| 2 | CloudTrail→CloudWatch 풀스트리밍 → **생략 확정** (검색=Athena, 알람=EventBridge로 대체) | — | ❌ 취소 |
| 3 | VPC Flow Logs → S3 전환(+Athena), 기존 CloudWatch log group/IAM role 제거 | 중 | ✅ 완료 |
| 4 | GuardDuty 유지(평가판 지속) + `datasources` 최신화 + EventBridge로 finding→SNS 알림 | 낮음~중 | ✅ 완료 |
| 5 | EventBridge 정책 이벤트 룰(root 로그인 / SG 0.0.0.0/0 개방 / CloudTrail 중지 등) → SNS | 낮음 | ✅ 완료 |
| 6 | WAF Count→Block 전환 튜닝 (로그 관찰 후) | 중 | ⏸️ 보류 (프로젝트 기간상 미실시, 발표 시 구두 설명) |
| 7 | KMS Key Policy 최소권한 적용 (옵션 A: 안전한 명시적 정책) | **높음** | ✅ 완료 |
| 8 | Trivy CI/CD (GitHub Actions) + 크리티컬 차단 + Slack | — | ❌ 범위 외 (프로젝트 CI/CD 담당자가 진행) |
| 9 | 보안 운영 런북 .md 작성 (최종 상태 문서화) | 없음 | ✅ 완료 (SECURITY_RUNBOOK.md) |

### 확정된 결정 / 변경 (2026-06-16)
- ✅ **GuardDuty 유지**: 현재 평가판(무료) 사용 중, 종료 후에도 이어서 사용하기로 결정. (광범위·미지 위협 탐지의 핵심)
- ✅ **Shield**: Shield Standard(무료·자동)만 사용 — 추가 비용 없음. 별도 작업 불필요.
- ❌ **CloudTrail→CloudWatch 풀스트리밍 생략**: 이미 Athena(S3)로 CloudTrail 검색 중이라 풀스트리밍은 비용 낭비. 실시간 알람은 EventBridge로 대체.
- 🔄 **VPC Flow Logs → S3 전환**: 비용 절감 + Athena 통일. GuardDuty는 flow log를 자체적으로 읽으므로 CloudWatch 제거해도 탐지 영향 없음.
- ⛔ **구 항목 자동 해소**: IAM 와일드카드 제거(구 항목)는 flow-logs용 IAM role을 삭제하면서 자동 해결됨. Logs Insights(구 항목)는 로그가 S3로 이동하므로 Athena로 대체(별도 작업 불필요).

---

## 3. 작업 로그 (완료 기록)

> 작업을 끝낼 때마다 여기에 "무엇을/왜/어떻게" 한 줄씩 추가.

- **[#1 완료]** 코드 정리 (저위험, terraform validate 통과)
  - `output "test"` 제거 + 고아 `data.aws_lb.target_alb` 제거 (outputs.tf, variables.tf) — 디버깅 잔재 + 매 plan마다 불필요 API 호출 제거
  - 보안 경보 이메일 하드코딩 → `var.security_alert_email` 변수화 (variables.tf, monitoring_alerts.tf), 기본값은 기존 이메일 유지 → apply 시 변화 없음
  - ※ GuardDuty `datasources` deprecated 정리는 #4(유지/제거 결정)와 묶여서 그때 처리하기로 이동
- **[#3 완료]** VPC Flow Logs CloudWatch → S3 전환 (monitoring_security.tf, terraform validate 통과)
  - flow log 전용 버킷 `securevoice-dev-vpc-flow-logs-455535733131` 신설(+퍼블릭 차단, +30일 수명주기, +delivery.logs.amazonaws.com 쓰기 정책)
  - `aws_flow_log.main`을 S3 대상으로 변경 + parquet/Hive/시간파티션(Athena 비용 최적화)
  - CloudWatch `aws_cloudwatch_log_group.vpc_flow_logs`, `aws_iam_role.vpc_flow_logs`, `aws_iam_role_policy.vpc_flow_logs` 삭제 → 이 과정에서 flow-logs IAM 정책의 `Resource="*"` 와일드카드도 자동 제거됨
  - CloudTrail 버킷에도 30일 수명주기 추가(요청사항: flow/cloudtrail 모두 30일)
  - **apply 시 주의:** `aws_flow_log`는 교체(destroy→create)되어 flow log 수집이 수십 초~1분 끊김(서비스 트래픽 영향 없음). 기존 CloudWatch flow log 데이터는 삭제됨.
  - **[apply 확인됨]** 사용자가 정상 apply 확인 완료.
- **[#4 완료]** GuardDuty 최신화 + finding 알림 배선 (guardduty_security.tf, terraform validate 통과)
  - `datasources { s3_logs }`(deprecated) → `aws_guardduty_detector_feature`(S3_DATA_EVENTS) 분리 (서울+us-east-1 둘 다), 태그 `common_tags`로 정리
  - **서울**: 신규 SNS 토픽 `security-alerts-seoul` + 이메일 구독 + EventBridge 규칙(GuardDuty Finding, severity>=4) → SNS
  - **us-east-1**: 기존 WAF용 SNS 토픽 재사용 + 토픽 정책(기본 statement 보존 + EventBridge 발행 허용) + EventBridge 규칙 → SNS
  - 두 리전 모두 Medium 이상 finding을 이메일 알림. WAF 알람은 기본 statement 보존으로 정상 유지.
  - **apply 시 주의:** ① 서울 SNS 신규 구독 → AWS 확인 메일에서 **Confirm 눌러야 알림 수신**. ② GuardDuty 디텍터는 in-place 업데이트(S3 보호는 ENABLED 유지). ③ GuardDuty S3 Protection은 비용 요인이므로 부담되면 `aws_guardduty_detector_feature` status를 DISABLED로 끌 수 있음.
  - **[apply 확인됨]** 사용자가 apply + 이메일 인증 완료.
- **[#5 완료]** EventBridge 고위험 정책 이벤트 알림 (security_event_alerts.tf, terraform validate 통과)
  - us-east-1: 루트 계정 사용 / IAM 민감 변경 → 기존 us-east-1 토픽
  - 서울: 보안그룹 규칙 변경 / CloudTrail 변조 → 서울 토픽
  - CloudTrail 관리 이벤트가 EventBridge 기본 버스로 자동 전달되는 점 활용(CloudWatch 수집비 없이 동작, 저비용)
  - apply 위험: 순수 additive(규칙4+타깃4), 서비스 영향 없음. 토픽 정책은 #4에서 이미 events 발행 허용 상태.

## 5. 앞으로의 작업 방식 메모
- apply는 사용자가 직접 수행. 각 작업마다 Claude가 **plan 예상 / apply 위험 / 콘솔 확인 방법**을 함께 제공한다.
- 진행 전략: **남은 작업 먼저 완주 → 2회차에서 전체를 다시 돌며 깊게 검토**.

## 6. ⏯️ 현재 중단 지점 (다음 세션 여기서 이어서)

**작업 #7 (KMS Key Policy 최소권한) 조사 중 — 가장 고위험 작업.**

조사된 사실:
- `aws_kms_key.securevoice_master`(kms_security.tf)에는 **현재 key policy가 없음** → 기본값(루트 계정 전체 허용) → IAM 정책으로 접근 통제 중.
- 이 키 사용처(consumer)로 확인된 것:
  - **S3 SSE-KMS**: audio/model 버킷 (s3_security.tf) — S3 서비스 + 객체 Get/Put 하는 주체.
  - **ECS api_task / worker_task 역할**: 20-runtime/iam.tf:179 에서 하드코딩 ARN에 kms:Decrypt + GenerateDataKey 부여. **[확인됨] 이 ARN(`5b711458...`)은 securevoice_master와 동일 키.**
  - **RDS**: 10-persistent main.tf:88 `storage_encrypted = true`이나 `kms_key_id` 미지정 → **[확인됨] aws/rds 기본키 사용, 이 키의 consumer 아님.**
  - **CloudFront OAC**: 현재 키 정책이 없어 암호화 객체 복호화 불가 상태 → 지금은 CloudFront로 SSE-KMS audio를 서빙하지 않음(추정). 키 정책에 추가하지 않으면 현 동작 유지.

다음 세션 할 일 (순서):
1. ~~키 ARN 대조~~ ✅ 완료 — 동일 키 확인.
2. ~~RDS 키 확인~~ ✅ 완료 — aws/rds 기본키.
3. 그 뒤 방향 선택:
   - **(안전) 옵션 A**: 루트 'Enable IAM' statement 유지 + key admin/서비스 사용 명시 → 잠금사고 위험 거의 없음, 단 엄격한 제한은 아님.
   - **(엄격·위험) 옵션 B**: 루트 enable 제거하고 사용 주체 전부 열거 → **누락 시 서비스 중단 / 키 lockout(복구 불가)** 위험. 비운영 환경 테스트 필수 → 2회차 권장.

> ⚠️ KMS key policy는 잘못 쓰면 키에서 스스로 잠겨 AWS 지원 없이 복구 불가. 반드시 'Enable IAM' 또는 key admin 접근을 보존할 것.

**[#7 완료]** 옵션 A 적용 (kms_security.tf, terraform validate 통과)
- securevoice_master에 키 정책 추가: statement1 `EnableIAMUserPermissions`(루트 kms:*, 잠금/기존동작 보존) + statement2 `AllowECSTaskRolesUseOfKey`(api/worker 역할만 Decrypt/GenerateDataKey/DescribeKey, iam_hardening.tf의 data 소스 ARN 재사용).
- apply 예상: kms key **in-place 수정 1건**(정책 추가), 키 재생성 아님. statement1이 현재 기본동작과 동일해 기능 변화 없음 → 서비스 영향 없음.
- 콘솔 확인: KMS → 고객관리형 키 → securevoice-dev-master-key → 키 정책 탭에서 두 statement 확인.
- 2회차 강화 후보: statement1 제거 + `kms:ViaService=s3` 제한 (비운영 테스트 후).

**[#9 완료]** 보안 운영 런북 작성 → `SECURITY_RUNBOOK.md` (사고 유형별 대응 절차, 조사 쿼리, 리소스 인벤토리, 정기 점검 체크리스트).

---

## 🏁 1회차 완료 (2026-06-17)
완료: #1 코드정리 · #3 Flow Logs→S3 · #4 GuardDuty+알림 · #5 EventBridge 알림 · #7 KMS 키정책(옵션A) · #9 런북
취소/보류/범위외: #2 풀스트리밍(취소) · #6 WAF Count→Block(보류, 발표 구두) · #8 Trivy(CI/CD 담당)

### 2회차(심화) 후보
1. #7 KMS 옵션 B (Enable IAM 제거 + ViaService 제한) — 비운영 테스트 후
2. #6 WAF Count→Block 전환 (로그 관찰 후 오탐 점검)
3. audio_oac_policy(죽은 설정) 제거 (s3_security.tf)
4. CloudTrail 버킷 무결성/접근 추가 점검, flow log Athena 테이블 DDL 작성(발표용)
5. 전체 코드 리뷰 + GitHub push 정리(.gitignore로 .terraform/state/*.bak 제외)

## 8. 추가 보강 작업 (확정, 잔여 ~10일) — 실무 평가 기반
> 상세 평가/근거: `SECURITY_ASSESSMENT.md`. 전부 저비용·고가치만 선별.

| # | 작업 | 위험도 | 상태 |
|---|------|--------|------|
| A | S3 Bucket Keys 활성화 (SSE-KMS 버킷) — KMS 호출/비용 절감 | 낮음(additive) | ✅ 완료 |
| B | audio 버킷에만 CloudTrail Data Events — 생체정보 객체 감사 | 낮음~중 | ⬜ 대기 |
| C | AWS Security Hub(FSBP) + Config(스코핑) — 준수 점수·통합 | 중 | ⬜ 대기 |
| D | IAM 비밀번호 정책 + MFA 강제 | 낮음(단 MFA 강제는 팀원 영향 주의) | ⬜ 대기 |

> ⚠️ D의 MFA 강제: IAM 사용자가 MFA 미설정 시 잠길 수 있음 → 팀 IAM 사용자 존재 여부/조율 확인 후 진행.

---

## 4. 결정 대기 / 질문 (Open Questions)

- GuardDuty: 유지할지 제거할지 (비용 vs 위협탐지 가치) — #4에서 다룸
- CloudTrail→CloudWatch 스트리밍: 전 워크로드에 필요한지 — #5에서 다룸
- WAF CloudFront 연결이 실제로 콘솔에서 돼 있는지 확인 필요