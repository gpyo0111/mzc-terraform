# 🔐 SecureVoice 보안 작업 정리 (멘토 리뷰용)

> **담당 범위:** `mzc-terraform/pmg-security` 레이어 (보안 전담). 다른 레이어 리소스는 `data`로 읽기만, 변경은 내 레이어에서만.
> **대상 서비스:** SecureVoice — 사용자 **음성(생체정보)** 을 처리하는 dev 환경. 계정 `455535733131` / 서울(ap-northeast-2) + 글로벌(us-east-1).
> **핵심 철학:** 생체정보 보호를 위해 **예방→경계→탐지→알림→자동대응** 전 주기를 IaC(Terraform)로 구축 + **비용 대비 효과로 도구 취사선택.**

---

## 1. 보안 아키텍처 한눈에

```
                            🛡️ WAF (CloudFront 엣지, 5룰)
사용자 ──► CloudFront ──────► ALB ──► ECS(api/worker) ──► RDS
            │  (OAC)          │(443:CloudFront only)  │(3306:ECS SG only)
            ▼                 ▼                        ▼
          S3(web/audio)    [SG 체이닝]            [SG 체이닝]
          SSE-KMS 암호화    워커=제로인바운드

[전 구간 감시] CloudTrail(멀티리전+무결성+음성객체감사) · VPC Flow Logs(S3/Athena)
              · GuardDuty(서울+버지니아) · IAM Access Analyzer
[알림] EventBridge → SNS 이메일 (루트사용/IAM변경/SG변경/CloudTrail변조/WAF차단)
[자동대응] Lambda 자가복구 — SG 위험개방 자동회수 · CloudTrail 변조 자동복구
```

---

## 2. 단계별로 한 일

### 🔒 예방 (Prevention) — 데이터·접근 통제
- **S3 퍼블릭 액세스 전면 차단** (audio/model/web/state 등 버킷)
- **등급별 수명주기** (guest 7일 / free 90일·30일Glacier / paid 365일·30일Glacier) — 비용 + 생체정보 최소보관
- **KMS 고객관리형 키(CMK)** — 자동 회전 + 삭제 30일 타임록 + 키정책(루트/ECS역할 분리, 최소권한)
- **SSE-KMS 정적 암호화 강제** (audio/model) + **S3 Bucket Key** 로 KMS 호출·비용 절감
- **OAC(Origin Access Control, SigV4)** — CloudFront만 S3 접근, 버킷 직접접근 차단
- **보안그룹 체이닝** — ECS→RDS(3306), CloudFront Prefix List→ALB(443, 오리진/WAF 우회 차단)
- **AI 워커 제로 인바운드 격리** — 인바운드 0, 큐 폴링(아웃바운드)만
- **IAM 최소권한 보강** — 팀 ECS 역할 코드 수정 없이 정책 attach, `ListBucket`을 특정 버킷으로 한정(`*` 제거)

### 🌐 경계 (Perimeter)
- **WAFv2 Web ACL 5룰** (AWS 관리형 4종: IP평판/Common/KnownBadInputs/SQLi + 커스텀)
- **Rate-based Rule (DDoS 완화)** — 2000요청/5분 초과 시 Block
- **Managed Prefix List로 ALB 우회 차단** — CloudFront 엣지만 진입

### 🔍 탐지·감사 (Detection)
- **CloudTrail 멀티리전 + 로그 무결성 검증** + **audio `uploads/` 객체 데이터이벤트**(생체정보 접근 감사)
- **VPC Flow Logs → S3** (parquet + 시간 파티션, Athena 비용 최적화) + 30일 수명주기
- **Athena 보안 조사 쿼리 8종** + 결과 전용 버킷·워크그룹 분리
- **GuardDuty (서울 + 버지니아)** + EventBridge로 finding→SNS 알림
- **IAM Access Analyzer** (외부/퍼블릭 노출 자동 탐지, 무료)

### 🚨 알림 (Alerting)
- **EventBridge 고위험 이벤트 → SNS 이메일** — 루트 사용 / IAM 민감변경 / SG 변경 / CloudTrail 변조 / WAF 차단

### 🛠️ 자동대응 (Response / Self-Healing) ⭐
- **SG `0.0.0.0/0` 자동회수 Lambda** — 위험포트(22/3306 등) 인터넷 개방 시 자동 revoke
  - 안전장치: 드라이런 토글 / 예외태그(`AutoRemediate=false`) / 최소권한 IAM / SG 재조회 / `ModifySecurityGroupRules` 사각지대 커버
- **CloudTrail 자동복구 Lambda** — StopLogging→재가동 / DeleteTrail→원설정대로 재생성+데이터이벤트 재적용
  - 안전장치: 드라이런 토글 / 우리 트레일만 / 정상 변경(Update/PutEventSelectors)은 알림만

### 🧯 운영·실전 (Operations)
- **드리프트 사고 탐지·조사·복원** — 팀원의 ALB/VPCE 보안규칙 회수를 CloudTrail/Athena로 추적·특정 → ALB 복원, VPCE는 팀 소유에 일임
- **보안 운영 런북** (`SECURITY_RUNBOOK.md`) + **발표용 단계 문서** (`docs/00~06`)

---

## 3. 판단력 — 의도적으로 "안 한 것" (차별화 포인트)

| 안 한 것 | 이유 |
|---|---|
| **Config / Security Hub** | 멀티계정·상시 자동감시가 본질 → 단일 dev엔 과함(월 $10~30). 예방은 IaC 고정 + `plan` 드리프트 점검, 탐지는 GuardDuty로 대체 |
| **Macie / Shield Advanced / SIEM** | 동일하게 비용 대비 효과로 제외 |
| **KMS 옵션 B(엄격 잠금)** | 키 lockout(복구불가) 위험 대비 효과 낮아 보류 |
| **IAM MFA 강제** | 팀 공용계정·CLI키 lockout 위험 → 팀 조율 후 결정 |
| **WAF 전체 Block 전환** | 오탐 방지 위해 관리형 4룰은 Count(관찰) 유지 — 로그 관찰 후 단계적 Block이 정석 |

> 핵심 메시지: **"많이 켜는 것"이 아니라 "왜 켜고 왜 안 켜는지"를 비용·위험으로 판단**했다.

---

## 4. 실전에서 배운 것 (드리프트 사고)

- 보안 통제를 **코드에 박아둬도**, 공용계정에서 팀원의 apply/콘솔 변경으로 **드리프트**가 발생.
- `terraform plan`으로 코드↔실제 차이를 포착 → CloudTrail/Athena로 **누가 언제 바꿨는지 추적·특정** → 복원.
- 교훈: ⓐ 정기 `plan` 점검의 가치, ⓑ 공용 리소스는 단일 레이어 소유·변경창구 일원화, ⓒ 자동화가 못 잡는 "설계상 위반"은 코드리뷰/탐지로 보완.

---

## 5. 진행 상태 & 남은 작업

- **구축·apply 완료:** 위 1~4 전부 운영 반영 완료(무중단).
- **자동대응 Lambda 2종:** 현재 **드라이런(알림만)** 으로 배포 → 데모 시 자동회수·복구 활성화 예정.
- **진행 중:** 발표/포트폴리오용 **콘솔·코드 캡쳐** 정리 (`docs/CAPTURE_CHECKLIST.md`).
- **남은 정리:** ALB 80-from-`0.0.0.0/0`(팀 작업용) prod 전 정리, WAF↔CloudFront 연결 콘솔 확인.

---

## 6. 참고 문서
- `docs/00_OVERVIEW.md` ~ `06_RESPONSE.md` — 발표 흐름별 상세 설명
- `SECURITY_RUNBOOK.md` — 사고 유형별 대응 절차
- `SECURITY_ASSESSMENT.md` — 의도적 제외 결정 근거
- `ATHENA_SECURITY_QUERIES.md` — 보안 조사 쿼리 8종
- `SECURITY_PROGRESS.md` — 전체 작업 진행 이력
