# 📋 SecureVoice 보안(pmg-security) — 작업 리스트

> 내가 `pmg-security` 레이어에서 실제로 수행한 보안 작업 목록. 발표 흐름(예방→경계→탐지→알림→대응→운영) 순서.
> 표기: ✅ 완료(apply) · 🔧 정리/다듬기 예정 · 👥 팀 공용영역 협업

---

## 🔒 예방 (Prevention) — 데이터·접근 통제
- ✅ **S3 퍼블릭 액세스 전면 차단** (audio/model/web/state 4개 버킷)
- ✅ **등급별 스토리지 수명주기 정책** (guest 7일 파기 / free 90일·30일Glacier / paid 365일·30일Glacier) — 비용 + 생체정보 최소보관
- ✅ **AWS KMS 고객관리형 마스터키(CMK) + 가드레일 구축** (키 자동회전 / 삭제 30일 타임록 / 키정책 옵션A: 루트+ECS역할 분리)
- ✅ **SSE-KMS 정적 암호화 강제** (audio/model) + **S3 Bucket Key**로 KMS 호출·비용 절감
- ✅ **OAC(Origin Access Control)** — CloudFront(SigV4)만 S3 접근 허용, 버킷 직접접근 차단
- ✅ **보안 그룹 체이닝** (ECS→RDS 3306 / CloudFront Managed Prefix List→ALB 443 = 오리진·WAF 우회 차단)
- ✅ **비동기 AI 워커 네트워크 완전 격리** — 인바운드 0(Zero-Inbound) 전용 SG 분리 수립
- ✅ **IAM 하드닝 (최소 권한)** — 팀 ECS 역할 수정 없이 내 레이어에서 정책 attach, `s3:ListBucket`을 특정 버킷으로 한정(`*` 제거)
- ✅ **security_groups.tf 리팩토링** (데이터소스 룩업 기반 체이닝 구조화)
- 🔧 **`audio_oac_policy` 죽은설정 제거 예정** — audio는 SSE-KMS라 CloudFront 복호화 불가 → 실효 없는 정책 정리

## 🌐 경계 (Perimeter)
- ✅ **AWS WAFv2 Web ACL 규칙 고도화 및 하드닝** (관리형 룰셋 5종)
- ✅ **Rate-based Rule (DDoS 완화)** — 2000요청/5분 초과 시 Block
- ✅ **Managed Prefix List로 ALB 우회 차단** (CloudFront 엣지만 진입)

## 🔍 탐지·감사 (Detection / Audit)
- ✅ **CloudTrail 멀티리전 + 로그 무결성 검증** + **audio `uploads/` 객체 데이터이벤트**(생체정보 접근 감사)
- ✅ **VPC Flow Logs → S3 저장** (parquet + Hive 시간 파티션, Athena 비용 최적화) + 30일 수명주기
- ✅ **Athena 보안 조사 쿼리 8종** + 결과 전용 버킷·워크그룹 분리(CloudTrail/Flowlogs)
- ✅ **GuardDuty (서울 + 버지니아) 최신화** (`datasources`→`detector_feature`) + **EventBridge로 finding→SNS 알림**
- ✅ **IAM Access Analyzer** (외부/퍼블릭 노출 자동 탐지, 서울+버지니아, 무료)

## 🚨 알림 (Alerting)
- ✅ **EventBridge 고위험 정책이벤트 알림→SNS** (루트 사용 / IAM 민감변경 / 보안그룹 변경 / CloudTrail 변조)
- ✅ **실시간 위협 탐지 및 알림 배선** (SNS 토픽 + 이메일 구독, 토픽 정책)

## 🛠️ 대응 — 자동화 (Response / Self-Healing)
- ✅ **SG `0.0.0.0/0` 자동회수 Lambda** — 위험포트(22/3306 등) 인터넷 개방 시 자동 revoke
  - 안전장치: 드라이런 토글(기본 알림만) / 예외태그(`AutoRemediate=false`) / 최소권한 IAM
  - `AuthorizeSecurityGroupIngress` + **`ModifySecurityGroupRules`(기존 규칙 편집) 사각지대 커버**
- ✅ **CloudTrail 자동복구 Lambda** — StopLogging→재가동 / DeleteTrail→원설정대로 재생성+데이터이벤트 재적용
  - 안전장치: 드라이런 토글 / 우리 트레일만 / UpdateTrail·PutEventSelectors는 알림만(Terraform 변경과 충돌 방지)

## 🧯 운영·실전 (Operations)
- ✅ **드리프트 사고 탐지·조사·복원** — 팀원의 ALB/VPCE 보안규칙 회수를 CloudTrail/Athena로 추적·특정 → ALB 복원, VPCE는 팀 `/25`에 일임(코드 정리)
- ✅ **보안 운영 런북 작성** (`SECURITY_RUNBOOK.md` — 사고 유형별 대응 절차)
- ✅ **의도적 제외 결정 문서화** (비용 대비 효과 판단)

## 🧠 판단력 — 의도적으로 "안 한" 것 (발표 차별화 포인트)
- ❎ **Config / Security Hub** — 멀티계정·상시 자동감시가 본질, 단일 dev엔 과함($10~30/월). 예방은 IaC 고정+plan 드리프트, 탐지는 GuardDuty로 대체
- ❎ **Macie / Shield Advanced / SIEM** — 동일하게 비용 대비 효과로 제외
- ❎ **NAT Gateway → VPC 엔드포인트 전환** — NAT 데이터처리 비용 폭탄 회피(S3 Gateway 엔드포인트 무료)
- ❎ **KMS 옵션 B(엄격 잠금)** — 키 lockout 위험 대비 효과 낮아 보류
- 👥 **Trivy CI/CD** — CI/CD 담당자(팀) 영역
- ⏸️ **IAM MFA 강제 / 비밀번호 정책** — 팀 공용계정·CLI키 lockout 위험으로 조율 후 결정

---

### 한 줄 요약
> 생체정보(음성) 보호를 위해 **예방(암호화·격리·최소권한) → 경계(WAF) → 탐지(CloudTrail·GuardDuty·Athena) → 알림 → 자동대응(자가복구 Lambda)**의 전 주기를 구축하고, **비용 대비 효과로 도구를 취사선택**했으며, 실제 **드리프트 사고를 탐지·복원**했다.
