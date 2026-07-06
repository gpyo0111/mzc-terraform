# 📸 발표자료용 캡쳐 체크리스트 (콘솔/코드)

> 목적: 발표/포트폴리오용 스크린샷을 빠짐없이·일관되게 확보. 발표 흐름(예방→경계→탐지→알림→대응→운영) 순.
> 계정 `455535733131` / 메인 리전 **서울(ap-northeast-2)** / 글로벌 **버지니아(us-east-1)**.
> ⚠️ **리전 함정:** WAF·CloudFront·GuardDuty(버지니아)·SNS(security_alerts)·EventBridge(글로벌 룰)는 **us-east-1**에서 찍어야 보임. 서울에서 찾으면 "없음"으로 보임.

## 캡쳐 공통 팁
- 콘솔 우상단 **리전 표시가 보이게** 찍기(서울/버지니아 증빙). 계정ID 일부 보여도 OK.
- 코드 스크린샷은 VS Code에서 해당 블록 + 파일명 탭 보이게.
- 파일명 규칙(권장): `01-prevention-kms.png` 처럼 `단계-주제` 로 저장 → 슬라이드 삽입 편함.
- 한 슬라이드 = 콘솔(증거) + 코드(IaC 근거) 2장 페어로 가면 설득력↑.

---

## ① 예방 (Prevention) — docs/02

### S3
- [v] **S3 버킷 목록** (audio/model/web-static/state/cloudtrail-logs/vpc-flow-logs/athena-results) — 한 화면. *전체 그림*
- [v] audio 버킷 → **권한 탭 → 퍼블릭 액세스 차단(4개 ON)**. `s3_security.tf`
- [v] audio 버킷 → **관리 탭 → 수명주기 규칙** (guest 7일 / free·paid Glacier) 목록.
- [v] audio 버킷 → **속성 탭 → 기본 암호화 = SSE-KMS(securevoice 키) + Bucket Key 켜짐**.
- [x] 코드: `s3_security.tf` 퍼블릭차단/수명주기/SSE-KMS 블록.

### KMS
- [v] KMS(서울) → 고객관리형 키 → **securevoice-dev-master-key → 키 정책 탭**(statement 2개: EnableIAM + ECS역할). `kms_security.tf`
- [v] 같은 키 → **키 회전 ON / 삭제 대기 30일** 설정 화면.

### 네트워크/접근통제
- [v] EC2(서울) → 보안그룹 → **RDS SG 인바운드 3306 = ECS SG에서만**(소스가 SG). `security_groups.tf`
- [v] **ALB SG 인바운드 443 = CloudFront Managed Prefix List**(`pl-...`). ⚠️ 80-from-0.0.0.0/0 보이면 그건 정직포인트(발표서 언급).
- [v] **워커 SG = 인바운드 0건**(제로 인바운드) 화면. `worker_security_group.tf`
- [v] IAM → 역할 → ECS api/worker 역할 → **attach된 ListBucket(버킷 한정) 정책**. `iam_hardening.tf`

---

## ② 경계 (Perimeter) — docs/03
- [ ] **WAF & Shield(반드시 us-east-1) → Web ACLs → securevoice-dev-waf**. `waf.tf`
- [v] 해당 Web ACL → **Rules 탭**: 5개 규칙 목록(1~4 Count, 5 Block 보이게).
- [v] 규칙5 **DDoS-Rate-Limit-Rule** 상세(2000/5분, Block).
- [v] ⭐ **Associated AWS resources 탭** → CloudFront(mzmt.shop)에 연결 **✅완료(2026-06-30, 플랜취소 후 IaC WAF로 교체)** → 지금 연결된 화면 캡쳐. 또는 CloudFront→보안탭에 `securevoice-dev-waf (WAFv2)` 표시 캡쳐.
- [ ] (선택) WAF → **Sampled requests / CloudWatch 메트릭**(트래픽 잡히는 증거).

---

## ③ 탐지·감사 (Detection) — docs/04
### CloudTrail
- [ ] CloudTrail → 추적 → **securevoice-dev-trail**: 멀티리전 ON / 로그파일 검증 ON. `monitoring_security.tf`
- [ ] 같은 트레일 → **데이터 이벤트 섹션: S3 / audio .../uploads/** 표시.
- [ ] cloudtrail-logs **S3 버킷에 로그 객체 쌓인 화면**(AWSLogs/...).

### Flow Logs
- [ ] VPC → 해당 VPC → **플로우 로그 탭**: 대상=S3, parquet, Hive 파티션. `monitoring_security.tf`
- [ ] vpc-flow-logs S3 버킷에 **파티션 폴더(연/월/일/시) 적재** 화면.

### GuardDuty (서울 + 버지니아 각각)
- [ ] GuardDuty(서울) → **활성화됨 + S3 보호 ENABLED**. `guardduty_security.tf`
- [ ] GuardDuty(**us-east-1**) → 활성화됨(2리전 증빙).
- [ ] (있으면) Findings 목록 1장.

### Access Analyzer
- [ ] IAM → 액세스 분석기 → **securevoice-dev-account-analyzer 활성**(서울). `access_analyzer.tf`
- [ ] (있으면) 외부 노출 finding.

### Athena
- [ ] Athena → **워크그룹 2개**(cloudtrail/flowlogs). `athena_results.tf`
- [ ] ⭐ Athena 쿼리 1개 **실제 실행 결과** (예: REJECT 상위 출발지 / uploads 접근) — `ATHENA_SECURITY_QUERIES.md`에서 골라 실행 후 캡쳐. *수사 시연*
- [ ] athena-results 버킷에 결과 CSV가 cloudtrail//flowlogs/ 폴더로 분리 적재.

---

## ④ 알림 (Alerting) — docs/05
- [ ] SNS → 토픽 **security-alerts-seoul(서울)** + **security-alerts-topic(us-east-1)** 각각 + 이메일 구독 **Confirmed**. `monitoring_alerts.tf`/`guardduty_security.tf`
- [ ] EventBridge(서울) → 규칙: **sg-rule-changes / cloudtrail-tampering**. `security_event_alerts.tf`
- [ ] EventBridge(**us-east-1**) → 규칙: **root-account-usage / iam-sensitive-changes / guardduty-findings / access-analyzer-findings**.
- [ ] CloudWatch(us-east-1) → 경보 **waf-any-blocked-alarm**. `monitoring_alerts.tf`
- [ ] ⭐ **실제 수신한 보안 알림 이메일** 스크린샷(가장 설득력 있음).

---

## ⑤ 대응·자동화 (Response) — docs/06  ⭐ 데모 핵심
- [ ] Lambda → **securevoice-dev-sg-auto-remediate** 함수 화면(트리거=EventBridge 보이게). `lambda_auto_remediation.tf`
- [ ] Lambda → **securevoice-dev-cloudtrail-auto-recover** 함수 화면. `cloudtrail_auto_recovery.tf`
- [ ] 각 Lambda **환경변수**(AUTO_REVOKE/AUTO_RECOVER) — 드라이런/활성 상태 증빙.
- [ ] 코드: index.py 핵심 로직(위험포트 판정 / SG 재조회 / 트레일 재생성) 블록.

### 🔴 라이브 데모 캡쳐 (활성화 후 — 발표 백미)
> 데모 직전 `-var sg_auto_revoke_enabled=true` / `-var cloudtrail_auto_recover_enabled=true` 로 apply 후 진행.
- [ ] **SG 데모:** 테스트 SG에 22번 `0.0.0.0/0` 추가 → ⓐ 알림 이메일 수신 ⓑ 잠시 후 **규칙이 자동 사라진 화면**(before/after) ⓒ Lambda CloudWatch Logs 실행로그.
- [ ] **CloudTrail 데모:** 트레일 StopLogging → ⓐ "[보안경보] CloudTrail 변조" 이메일 ⓑ **로깅이 자동 재가동된 화면** ⓒ Lambda 로그.
- [ ] 끝나면 토글 다시 false 로 원복(드라이런 복귀) — 정리.

---

## 🧯 운영·판단력 (발표 차별화) — WORK_LIST / SECURITY_ASSESSMENT
- [ ] **드리프트 사고 증빙:** `terraform plan` 출력(드리프트 잡히는 화면) 또는 Athena로 ALB SG 회수 추적한 쿼리 결과. *plan 기반 드리프트 점검 가치*
- [ ] 코드: `security_groups.tf`의 VPCE /22 제거 주석(소유권/변경창구 일원화 교훈).
- [ ] 문서 캡쳐: `SECURITY_RUNBOOK.md`, `SECURITY_ASSESSMENT.md`(의도적 제외 결정) 한 장씩.

---

## 진행 순서 제안
1. 먼저 **콘솔 정적 캡쳐**(①~④ + ⑤ 함수화면)를 리전별로 몰아서 — 서울 한 바퀴 → 버지니아 한 바퀴(리전 전환 최소화).
2. **Athena 쿼리 1~2개 실행** 캡쳐.
3. 마지막에 **라이브 데모**(Lambda 활성화) — 시간 들고 되돌려야 하므로 별도 블록으로.
4. 캡쳐하며 빠진 코드 근거는 docs/0N 문서에서 바로 인용.
