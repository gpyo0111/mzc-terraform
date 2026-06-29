# 🔐 SecureVoice 클라우드 보안 구축 — 포트폴리오 입력 브리프

> **용도:** 이력서 첨부 / 프로젝트 발표용 포트폴리오를 (브라우저 Claude 등으로) 생성할 때 넣는 **자체완결 컨텍스트 문서**. 이 파일 하나로 "무엇을·왜·어떻게 했는가"가 전부 파악되도록 작성됨. (코드·캡처는 별도 첨부)

---

## 0. 한 줄 소개
사용자 **음성(=생체정보)** 을 처리하는 서비스 **SecureVoice**의 AWS 인프라 보안을 **Terraform(IaC)** 으로 전담 설계·구축. **예방→경계→탐지→알림→자동대응→운영**의 보안 생애주기 전 구간을 코드로 구현하고, 비용 대비 효과로 도구를 취사선택했으며, 실제 운영 중 발생한 **드리프트 사고를 탐지·추적·복원**함.

- **담당 범위:** `pmg-security` 레이어(보안 전담). 타 레이어 리소스는 `data`로 읽기만, 변경은 내 레이어에서만 → 공용 인프라에 안전하게 보안 계층을 얹는 설계.
- **환경:** AWS 단일 계정 dev / 서울(ap-northeast-2) + 글로벌(us-east-1) 2리전 / 운영 중 무중단 적용.
- **핵심 컨셉:** 생체정보 보호 = ISMS-P 안전성 확보조치(암호화·접근통제·접속기록·파기)를 클라우드에서 IaC로 구현.

---

## 1. 보안 아키텍처 한눈에

```
                            🛡️ WAF (CloudFront 엣지, 5룰 + Rate-limit)
사용자 ─► Route53 ─► CloudFront ─────► ALB ─► ECS(api/worker) ─► RDS(Multi-AZ)
                      │ (OAC,SigV4)    │ 443:CloudFront PL only   │ 3306:ECS SG only
                      ▼                ▼                          ▼
                   S3(web/audio)    [SG 체이닝]              [SG 체이닝]
                   SSE-KMS 암호화    워커=Zero-Inbound(SQS 폴링만)

[전 구간 감시] CloudTrail(멀티리전+무결성+음성객체 데이터이벤트) · VPC Flow Logs(S3/Athena)
              · GuardDuty(서울+버지니아) · IAM Access Analyzer
[알림] EventBridge → SNS 이메일 (루트사용 / IAM변경 / SG변경 / CloudTrail변조 / WAF차단)
[자동대응] Lambda 자가복구 — SG 위험개방 자동회수 · CloudTrail 변조 자동복구
```
- 네트워크: 서울 VPC `10.0.0.0/22`, 2 AZ(A·C) × 3단 서브넷(Public: ALB·NAT / Private App: ECS·베스천 / Private Data: RDS) + S3 Gateway 엔드포인트(무료).

---

## 2. 단계별로 한 일 (보안 생애주기)

### 🔒 예방 (Prevention) — 데이터·접근 통제
- **S3 퍼블릭 액세스 전면 차단**(audio/model/web/state + 로그버킷) — 계정·버킷 레벨 4종 가드레일.
- **등급별 수명주기 자동 파기** — guest 7일 / free 90일(30일 Glacier) / paid 365일(30일 Glacier). 비용 + **생체정보 최소보관**.
- **KMS 고객관리형 키(CMK)** — 자동 회전 + 삭제 30일 타임록 + 키정책(루트/ECS 역할 분리, 최소권한 옵션A).
- **SSE-KMS 정적 암호화 강제**(audio/model) + **S3 Bucket Key**로 KMS 호출·비용 절감(보안 동일).
- **OAC(Origin Access Control, SigV4)** — CloudFront만 S3 접근, 버킷 직접 접근 차단.
- **보안그룹 체이닝** — ECS→RDS(3306), CloudFront Managed Prefix List→ALB(443) = 오리진·WAF 우회 차단.
- **AI 워커 Zero-Inbound 격리** — 인바운드 0, 큐(SQS) 폴링(아웃바운드)만으로 동작 → 공격 표면 제거.
- **IAM 최소권한 보강** — 팀 ECS 역할 코드 수정 없이 정책 attach, `s3:ListBucket`을 특정 버킷으로 한정(`*` 제거).

### 🌐 경계 (Perimeter)
- **WAFv2 Web ACL 5룰**(AWS 관리형: IP평판/Common/KnownBadInputs/SQLi + 커스텀) — CloudFront 엣지 적용.
- **Rate-based Rule (DDoS 완화)** — 2,000요청/5분 초과 IP Block.
- **Managed Prefix List로 ALB 우회 차단** — CloudFront 엣지만 진입.

### 🔍 탐지·감사 (Detection)
- **CloudTrail 멀티리전 + 로그 무결성 검증** + **audio `uploads/` 객체 데이터이벤트**(생체정보 접근 감사).
- **VPC Flow Logs → S3**(parquet + Hive 시간 파티션, Athena 비용 최적화) + 30일 수명주기.
- **Athena 보안 조사 쿼리 8종** + 결과 전용 버킷·워크그룹 분리.
- **GuardDuty (서울 + 버지니아)** + EventBridge로 finding→SNS 알림.
- **IAM Access Analyzer**(외부/퍼블릭 노출 자동 탐지, 무료).

### 🚨 알림 (Alerting)
- **EventBridge 고위험 이벤트 → SNS 이메일** — 루트 사용 / IAM 민감변경 / SG 변경 / CloudTrail 변조 / WAF 차단.

### 🛠️ 자동대응 (Response / Self-Healing) ⭐ 핵심 차별점
- **SG `0.0.0.0/0` 자동회수 Lambda** — 위험포트(22/3306 등) 인터넷 개방 시 자동 revoke.
  - 안전장치: 드라이런 토글 / 예외태그(`AutoRemediate=false`) / 최소권한 IAM / SG 재조회 / `ModifySecurityGroupRules` 사각지대 커버.
- **CloudTrail 자동복구 Lambda** — StopLogging→재가동 / DeleteTrail→원설정대로 재생성+데이터이벤트 재적용.
  - 안전장치: 드라이런 토글 / 우리 트레일만 / 정상 변경(Update/PutEventSelectors)은 알림만.

### 🧯 운영·실전 (Operations)
- **드리프트 사고 탐지·조사·복원**(아래 6장 트러블슈팅 참조).
- **보안 운영 런북** + **발표용 단계 문서**(docs/00~06) 작성.

---

## 3. 기술 스택 / 사용 서비스
- **IaC:** Terraform(v1.14.x), 멀티 프로바이더(서울 + us-east-1 alias), archive 프로바이더(Lambda 패키징).
- **AWS:** S3, KMS, CloudFront, WAFv2, ALB, ECS, RDS, VPC/Security Group, CloudTrail, VPC Flow Logs, Athena, GuardDuty, IAM Access Analyzer, EventBridge, SNS, Lambda(Python/boto3).
- **언어:** HCL(Terraform), Python(자동대응 Lambda), SQL(Athena 조사).

---

## 4. 판단력 — 의도적으로 "안 한 것" (차별화 포인트)

| 안 한 것 | 이유 |
|---|---|
| **Config / Security Hub** | 멀티계정·상시 자동감시가 본질 → 단일 dev엔 과함(월 $10~30). 예방은 IaC 고정 + `plan` 드리프트 점검, 탐지는 GuardDuty로 대체 |
| **Macie / Shield Advanced / SIEM** | 동일하게 비용 대비 효과로 제외 |
| **KMS 옵션 B(엄격 잠금)** | 키 lockout(복구불가) 위험 대비 효과 낮아 보류 |
| **IAM MFA 강제** | 팀 공용계정·CLI키 lockout 위험 → 팀 조율 후 결정 |
| **WAF 전체 Block 전환** | 오탐 방지 위해 관리형 룰은 Count(관찰) 유지 — 로그 관찰 후 단계적 Block이 정석 |

> 핵심 메시지: **"많이 켜는 것"이 아니라 "왜 켜고 왜 안 켜는지"를 비용·위험으로 판단**했다.

---

## 5. ISMS-P 매핑 (음성 = 민감정보/생체정보)

### 강한 매칭
| ISMS-P 통제항목 | 한 일 |
|---|---|
| **2.7.1 암호정책 적용** | SSE-KMS 정적 암호화 강제(audio/model) |
| **2.7.2 암호키 관리** | KMS CMK + 자동회전 + 삭제 타임록 + 키정책(루트/ECS 분리) — 키 생애주기 통제 |
| **2.6.1 네트워크 접근** | SG 체이닝, 워커 Zero-Inbound, S3 퍼블릭 차단 |
| **2.6.4 데이터베이스 접근** | RDS 3306 ← ECS SG에서만 |
| **2.6.7 인터넷 접속 통제** | CloudFront PrefixList→ALB, OAC, WAF |
| **2.9.4 로그 및 접속기록 관리** | CloudTrail(멀티리전+무결성), Flow Logs, audio `uploads/` 데이터이벤트 |
| **2.9.5 로그 점검** | Athena 보안조사 쿼리 8종 |
| **2.10.2 클라우드 보안** | 전체 IaC 보안설정(Terraform 고정) |
| **2.11.3 이상행위 분석·모니터링** | GuardDuty + EventBridge→SNS, 고위험 정책이벤트 알림 |
| **2.11.5 사고 대응 및 복구** | SG 자동회수 Lambda, CloudTrail 자동복구 Lambda, 드리프트 실전 복원 |
| **3.4.1 개인정보 파기** | 등급별 수명주기 자동 파기(보유기간 경과 시 삭제) |

### 부분 매칭
- 2.5.5/2.5.6(권한관리·검토): IAM 최소권한, Access Analyzer(외부노출 탐지).
- 2.11.1(대응체계): 보안 운영 런북.
- 2.12.1(재해 대비): KMS 30일 타임록, CloudTrail 자동복구.

### 솔직한 공백 (발표/면접 시 선제 언급)
- **2.5.3/2.5.4 인증·MFA 강제** → 공용계정 lockout 위험으로 보류, 팀 조율 후 적용 예정.
- **1.x 관리체계 / 2.1~2.4(정책·인적·물리)** → 기술 작업 범위 밖. 기술적 보호대책(2.5~2.12)+파기(3.4)에 집중.
- **3.1 수집 동의 / 3.5 정보주체 권리** → 앱/서비스 로직 영역.

---

## 6. 실전 트러블슈팅 (면접 단골 소재)

### ① 공용계정 SG 드리프트 — 코드↔실제 어긋남 탐지·추적·복원
- **상황:** Lambda apply 전 `terraform plan`에서 우리 작업과 무관한 SG 규칙이 변경분으로 잡힘 → 콘솔 확인 결과 실제 진짜 드리프트.
- **문제:** 팀원이 **ALB의 443-from-CloudFront(오리진 우회 차단) 규칙을 회수** → 누구나 ALB에 직접 접근해 **CloudFront/WAF 우회 가능**한 보안 회귀.
- **추적:** CloudTrail + Athena로 "누가 언제 Revoke 했는지" 특정(팀원 `mzc-kjh`, 시각까지). 회수는 실수로 확인.
- **조치:** ALB 443 규칙 코드로 복원(apply), 소유권이 모호하던 VPCE 규칙은 소유 레이어에 일임(코드 정리).
- **교훈:** ⓐ 정기 `plan` 점검의 가치(자동 Config 없이도 드리프트 포착), ⓑ 공용 리소스는 단일 레이어 소유·변경창구 일원화, ⓒ 자동화(Lambda)가 못 잡는 "설계상 위반"은 코드리뷰·탐지로 보완.

### ② 콘솔 클릭이 만든 "그림자 리소스" 30초 추적
- **상황:** 정체불명의 SageMaker/DataZone S3 버킷(버지니아) 발견.
- **추적:** CloudTrail `CreateBucket`(us-east-1) → 생성 주체 = DataZone 서비스역할 → 사람 행위 역추적 → **본인이 콘솔에서 `CreateDomain` 클릭**한 33초 뒤 자동 생성된 것 확인. `mzc-terraform` 전체 grep으로 IaC와 무관 확정.
- **조치:** DataZone 도메인 삭제.
- **교훈:** 콘솔 클릭 한 번이 IaC 밖 "그림자 리소스"를 만든다 → CloudTrail+Athena로 30초 만에 출처 추적 가능. IaC 일원화의 중요성.

---

## 7. 이력서용 불릿 (초안 — 필요시 수정)
- AWS 음성 처리 서비스의 인프라 보안을 Terraform(IaC)으로 전담 설계·구축, 예방·경계·탐지·알림·자동대응 전 구간 구현(2리전).
- 생체정보 보호를 위해 KMS CMK 기반 SSE-KMS 암호화 강제 + S3 등급별 수명주기 자동 파기로 ISMS-P 안전성 확보조치(암호화·파기) 충족.
- CloudTrail(무결성)·VPC Flow Logs(S3/Athena)·GuardDuty로 전 구간 감사·위협 탐지 체계 구축, EventBridge→SNS 실시간 알림 배선.
- 보안그룹 위험개방 자동회수 / CloudTrail 변조 자동복구 Lambda(Self-Healing)를 드라이런·예외태그·최소권한 안전장치와 함께 구현.
- 운영 중 발생한 보안그룹 드리프트(CloudFront 우회 회귀)를 CloudTrail/Athena로 추적·특정 후 복원.
- Config/Security Hub 등은 단일 dev 환경 비용 대비 효과로 의도적 제외, 대안(IaC 고정 + plan 드리프트 점검 + GuardDuty)으로 커버.

---

## 8. 함께 첨부하면 좋은 자료
- **핵심 코드:** `kms_security.tf`, `s3_security.tf`, `security_groups.tf`, `waf.tf`, `monitoring_security.tf`, `guardduty_security.tf`, `lambda_auto_remediation.tf`, `cloudtrail_auto_recovery.tf`, `lambda/*/index.py`.
- **캡처:** `docs/CAPTURE_CHECKLIST.md` 기준 콘솔 스크린샷.
- **상세 설명:** `docs/00_OVERVIEW.md` ~ `06_RESPONSE.md`, `SECURITY_RUNBOOK.md`, `SECURITY_ASSESSMENT.md`, `ATHENA_SECURITY_QUERIES.md`.

> ⚠️ **공개 주의:** 이 문서·코드에 계정ID(`455535733131`), CloudFront 배포ID, 버킷명이 포함됨. 공개 이력서/포트폴리오면 `<ACCOUNT_ID>` 등으로 마스킹 권장.
