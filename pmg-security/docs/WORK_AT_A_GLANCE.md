# 📊 SecureVoice 보안 작업 — 한눈에 보기

> 범위: `pmg-security` 레이어 / 계정 `455535733131` / 서울 + 버지니아(글로벌)
> 상태: ✅ apply 완료 · 🟡 드라이런 · ⏸️ 보류 · ❎ 의도적 제외

---

## 🔒 예방 (Prevention)

| 작업 | 핵심 설정 | 목적 | 파일 | 상태 |
|---|---|---|---|---|
| S3 퍼블릭 차단 | block/ignore/restrict 4종 ON | 생체정보 버킷 노출 봉쇄 | s3_security.tf | ✅ |
| 등급별 수명주기 | guest 7d / free 90d / paid 365d (+Glacier) | 비용 + 생체정보 최소보관 | s3_security.tf | ✅ |
| KMS CMK | 자동회전 + 삭제 30일 타임록 + 키정책(루트/ECS 분리) | 키 소유·관리·최소권한 | kms_security.tf | ✅ |
| SSE-KMS 암호화 | audio/model + **Bucket Key** | 정적 암호화 + KMS 비용절감 | s3_security.tf | ✅ |
| OAC (SigV4) | CloudFront만 S3 접근 | 버킷 직접접근 차단 | s3_security.tf | ✅ |
| SG 체이닝 | ECS→RDS(3306) / CloudFront PL→ALB(443) | 우회·횡적이동 차단 | security_groups.tf | ✅ |
| 워커 제로 인바운드 | inbound 0 + egress만 | AI 워커 완전 격리 | worker_security_group.tf | ✅ |
| IAM 최소권한 | ListBucket을 audio/model로 한정(`*` 제거) | 팀역할 안건드리고 보강 | iam_hardening.tf | ✅ |

## 🌐 경계 (Perimeter)

| 작업 | 핵심 설정 | 목적 | 파일 | 상태 |
|---|---|---|---|---|
| WAFv2 5룰 | IP평판·Common·KnownBadInputs·SQLi(Count) + Rate-limit(Block) | L7 공격 차단 | waf.tf | ✅ |
| Rate-based Rule | 2000요청/5분 초과 Block | L7 DDoS 완화 | waf.tf | ✅ |
| Managed Prefix List | ALB 443 ← CloudFront 엣지만 | 오리진/WAF 우회 차단 | security_groups.tf | ✅ |

## 🔍 탐지·감사 (Detection)

| 작업 | 핵심 설정 | 목적 | 파일 | 상태 |
|---|---|---|---|---|
| CloudTrail | 멀티리전 + 무결성검증 | 전 리전 행동 녹화·변조탐지 | monitoring_security.tf | ✅ |
| CloudTrail Data Events | audio `uploads/` 객체 Get/Put | 생체정보 접근 감사 | monitoring_security.tf | ✅ |
| VPC Flow Logs | S3 + parquet + 시간파티션 | 트래픽 장부(저비용) | monitoring_security.tf | ✅ |
| GuardDuty | 서울 + 버지니아 + S3보호 | AI 위협 탐지 | guardduty_security.tf | ✅ |
| Access Analyzer | 외부분석기 2리전(무료) | 외부 노출 자동 탐지 | access_analyzer.tf | ✅ |
| Athena | 워크그룹 2개 + 결과버킷 분리 | 로그 SQL 수사 | athena_results.tf | ✅ |

## 🚨 알림 (Alerting) — 트리거 9개 → SNS 2토픽(서울/버지니아) → 이메일

| 트리거 | 기준 | 방식 | 파일 |
|---|---|---|---|
| 루트 계정 사용 | userIdentity.type=Root | EventBridge | security_event_alerts.tf |
| IAM 민감 변경 | CreateUser/AccessKey/Attach*/DeactivateMFA 등 | EventBridge | security_event_alerts.tf |
| SG 규칙 변경 | Authorize/Modify SecurityGroupRules | EventBridge | security_event_alerts.tf |
| CloudTrail 변조 | Stop/Delete/Update/PutEventSelectors | EventBridge | security_event_alerts.tf |
| GuardDuty finding | severity ≥ 4 (Medium+) | EventBridge | guardduty_security.tf |
| Access Analyzer | status = ACTIVE | EventBridge | access_analyzer.tf |
| WAF 차단 | BlockedRequests > 0 / 5분 | **CloudWatch 경보** | monitoring_alerts.tf |

## 🛠️ 자동대응 (Response / Self-Healing)

| 작업 | 동작 | 안전장치 | 파일 | 상태 |
|---|---|---|---|---|
| SG 위험개방 자동회수 | 위험포트 0.0.0.0/0 → revoke | 드라이런 토글·예외태그·SG재조회·최소권한 | lambda_auto_remediation.tf | 🟡 드라이런 |
| CloudTrail 자동복구 | Stop→재가동 / Delete→재생성 | 드라이런 토글·우리트레일만·정상변경 제외 | cloudtrail_auto_recovery.tf | 🟡 드라이런 |

## 🧯 운영 (Operations)

| 작업 | 내용 | 산출물 |
|---|---|---|
| 드리프트 사고 대응 | 팀원 SG 회수 → CloudTrail/Athena 추적 → 복원 | (실전 경험) |
| 보안 런북 | 사고 유형별 대응 절차 | SECURITY_RUNBOOK.md |
| Athena 조사 쿼리 | 보안 쿼리 8종 | ATHENA_SECURITY_QUERIES.md |
| 발표 문서화 | 단계별 상세 설명 | docs/00~06 |

---

## 🧠 의도적으로 "안 한 것" (판단력)

| 안 한 것 | 이유 | 대안 |
|---|---|---|
| Config / Security Hub | 멀티계정용, 단일 dev엔 과함($10~30/월) | IaC 고정 + plan 드리프트 + GuardDuty |
| Shield Advanced | 월 $3,000 과함 | Shield Standard(무료) + WAF rate-limit |
| Macie / SIEM | 비용 대비 효과 낮음 | — |
| KMS 옵션 B(엄격잠금) | 키 lockout 위험 | 옵션 A(루트 보존) |
| IAM MFA 강제 | 팀 공용계정·CLI키 lockout 위험 | 팀 조율 후 결정 |
| WAF 전체 Block | 오탐 위험 | Count 관찰 후 단계적 전환 |
| WAF 풀 로그 S3 | dev 단계 저장비 | 메트릭+샘플(3h), 필요시 Firehose→S3 |

---

## 🗺️ 계층별 방어 매핑

| 계층 | 방어 |
|---|---|
| L3/L4 (네트워크) | Shield Standard(자동) + 보안그룹 |
| L7 (애플리케이션) | WAF 5룰 + CloudFront(HTTPS/OAC) |
| 데이터 | KMS 암호화 + S3 퍼블릭차단 + 수명주기 |
| 신원·권한 | IAM 최소권한 + KMS 키정책 |
| 감사·탐지 | CloudTrail + Flow Logs + GuardDuty + Access Analyzer |

---

## 📈 숫자로 보는 작업량
- **예방 8 · 경계 3 · 탐지 6 · 알림 9(트리거) · 자동대응 2 · 운영 4**
- SNS 토픽 **2** / EventBridge 규칙 **8** / CloudWatch 경보 **1** / Lambda **2** / 의도적 제외 **7**
