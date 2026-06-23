# 🔐 SecureVoice 보안 (pmg-security) — 발표·면접용 정리 OVERVIEW

> 이 docs/ 폴더는 `pmg-security`의 각 Terraform 파일을 **발표 흐름 순서**로 정리한 학습·발표·면접 대비 문서입니다.
> 각 파일은 고정 템플릿(**무엇 / 왜 / 어떻게 작동 / 🎤발표 위치 / ❓예상 질문**)으로 설명합니다.

---

## 0. 왜 보안을 했나 (발표 도입부)
- SecureVoice가 다루는 핵심 데이터 = **음성 = 생체정보(고민감)**.
- 따라서 보안 목표 = **① 데이터를 끝까지 보호(암호화·접근통제) + ② 누가 만졌는지 증명(감사) + ③ 사고 시 탐지·대응.**

---

## 1. 발표 구조 — "흐름을 뼈대로, 2개 층을 덧씌우기"
보안은 ① 흐름의 길목에 박히는 **예방**과 ② 전체를 감싸는 **탐지·대응**으로 나뉜다.
→ 순수 아키텍처 흐름 순서만 쓰면 탐지·대응이 붕 뜬다. 그래서 아래 구조 사용.

```
① 왜 보안 중요(생체정보)
② [뼈대] 익숙한 아키텍처 경로를 '보안 렌즈'로 다시 걷기   ← 예방
③ [줌아웃] 그동안 전부 감시·기록되고 있다                ← 탐지/감사
④ [뚫리면] 대응 + 🔥실전 드리프트 사고 + 자가복구 데모    ← 대응
⑤ 안 한 것(Config/SecurityHub/NAT…)을 왜 안 했나         ← 판단력/트레이드오프
```

### 뼈대 = 음성 파일 한 개의 여정 (예방 통제)
```
사용자 음성 업로드
 → CloudFront + WAF        (경계: 봇·웹공격 차단, rate-limit)
 → ALB (CloudFront-only)    (오리진/ WAF 우회 차단)
 → ECS (사설 서브넷)         (외부 직접노출 0, NAT 대신 VPC엔드포인트)
 → KMS 암호화 → S3          (저장 데이터 암호화 = 생체정보 보호)
 + IAM 최소권한 / KMS 키정책 (신원·권한 통제)
```

---

## 2. 리전 분리 (꼭 알 것)
- **서울(ap-northeast-2, 기본)**: 대부분 리소스.
- **버지니아(us-east-1, `aws.us_east_1` alias, `waf.tf`에 정의)**: 글로벌 서비스 전용 — WAF(CloudFront용), GuardDuty 글로벌, Access Analyzer, 루트/IAM 이벤트.
- 이유: CloudFront·IAM 같은 글로벌 서비스의 로그·통제는 us-east-1에서만 동작(AWS 제약).

---

## 3. tf 파일 → 발표 단계 인덱스

| 단계(문서) | tf 파일 | 한 줄 역할 |
|---|---|---|
| **01 FOUNDATION** | provider, variables, locals, data_network/persistent/runtime, outputs | 배선: 리전·state·변수·다른 레이어 읽기 |
| **02 PREVENTION** | kms_security | 데이터 암호화 마스터 키(CMK)+키정책 |
| | s3_security | 버킷 암호화·퍼블릭차단·버킷키 |
| | security_groups | SG 체이닝(ECS→RDS, CloudFront→ALB, VPCE) |
| | worker_security_group | 워커 SG 통제 |
| | iam_hardening | IAM 최소권한/와일드카드 제거 |
| **03 PERIMETER** | waf | WAFv2 5룰 + rate-limit (+us-east-1 provider 정의) |
| **04 DETECTION** | monitoring_security | CloudTrail(멀티리전+무결성+데이터이벤트)+VPC Flow Logs→S3 |
| | guardduty_security | GuardDuty(서울+버지니아)+finding 알림 |
| | access_analyzer | 외부 노출 탐지(IAM Access Analyzer) |
| | athena_results | Athena 결과 버킷+워크그룹 분리 |
| **05 ALERTING** | monitoring_alerts | WAF 등 CloudWatch 경보→SNS |
| | security_event_alerts | 고위험 정책이벤트(root/IAM/SG/CloudTrail변조)→SNS |
| **06 RESPONSE** | lambda_auto_remediation | SG 0.0.0.0/0 자가회수 Lambda |
| | cloudtrail_auto_recovery | CloudTrail 정지/삭제 자가복구 Lambda |

---

## 4. 관련 문서
- `SECURITY_PROGRESS.md` — 작업 진행상황·결정 이력(드리프트 사고 조사 포함)
- `SECURITY_RUNBOOK.md` — 사고 유형별 대응 절차
- `ATHENA_SECURITY_QUERIES.md` — 보안 조사 쿼리(드리프트 추적에 사용)
- `SECURITY_ASSESSMENT.md` — 실무 평가·의도적 제외 근거
