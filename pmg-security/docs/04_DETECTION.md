# 04. DETECTION (탐지·감사) — monitoring_security / guardduty_security / access_analyzer / athena_results

> 🎤 발표 위치: **줌아웃 "다 감시 중"**. 예방(02)·경계(03)를 뚫어도 누가 뭘 했는지 전부 기록·탐지된다.
> 큰 그림: 🎥 CloudTrail(행동 녹화) · 🚗 Flow Logs(트래픽 장부) · 🤖 GuardDuty(AI 위협판단) · 🚨 Access Analyzer(외부노출 순찰) · 🔎 Athena(로그 수사).

---

## monitoring_security.tf — CloudTrail + VPC Flow Logs

**무엇을 만드나**
- **CloudTrail 로그 S3 버킷** (`cloudtrail_logs`) — 퍼블릭 차단 + 30일 수명주기 + CloudTrail 쓰기 허용 버킷정책(AclCheck + Write + `bucket-owner-full-control`).
- **CloudTrail 본체** (`main`): `is_multi_region_trail=true` + `enable_log_file_validation=true`(무결성) + `include_global_service_events=true`.
  - **S3 Data Events**: audio `uploads/` prefix만 (`read_write_type=All`, `include_management_events=true` 보존). 생체정보 객체 Get/Put 감사. results/ 제외(비용).
- **VPC Flow Logs S3 버킷** + 퍼블릭 차단 + 30일 수명주기 + delivery.logs 쓰기 정책.
- **Flow Log 본체** (`aws_flow_log.main`): `log_destination_type=s3`, `traffic_type=ALL`, **parquet + Hive 파티션 + per_hour_partition**(Athena 비용 최적화).

**왜**
- 멀티리전 = 타 리전 은닉 작업도 포착. 무결성검증 = 로그 변조 탐지(부인방지·감사).
- uploads/ Data Events = 관리이벤트만 찍는 기본 CloudTrail을 넘어 **객체 단위(누가 어떤 음성 접근)** 감사. prefix 1개 한정으로 비용 통제(10만건당 $0.10).
- Flow Logs S3 직행 = CloudWatch보다 저렴 + CloudTrail과 Athena 통합분석. GuardDuty는 flow log 자체 피드라 탐지 무관.

**어떻게 작동**: CloudTrail/flow log → S3 적재 → Athena가 parquet+파티션으로 저비용 조회(ATHENA_SECURITY_QUERIES.md).

**🎤 / ❓예상 질문**
- Q: "CloudTrail 끄면 탐지 무력화 아닌가?" → CloudTrail 자동복구 Lambda(06) + 무결성검증으로 방어.
- Q: "Flow Logs 왜 S3?" → 비용↓ + Athena 통합. GuardDuty 탐지엔 영향 없음.

---

## guardduty_security.tf — AI 위협 탐지 + 알림 배선

**무엇을 만드나**
- **GuardDuty 디텍터 2개**(서울 + us-east-1) + 각 **S3 보호**(`aws_guardduty_detector_feature` `S3_DATA_EVENTS` — 구 `datasources{s3_logs}` deprecated 대체).
- **알림 배선** finding → EventBridge → SNS:
  - 서울: 신규 토픽 `security_alerts_seoul` + 이메일 구독 + 토픽정책(events 발행 허용).
  - us-east-1: 기존 WAF 토픽 `security_alerts` **재사용** — **기본 statement(`__default_statement_ID`) 보존** + events 발행 추가.
- EventBridge 규칙: `severity >= 4`(Medium 이상)만 라우팅 → Low 노이즈 차단.

**왜**
- GuardDuty = 룰 직접 안 짜도 AI가 미지/광범위 위협(채굴·유출키·이상통신) 자동 탐지.
- 2리전 = IAM/CloudFront 등 글로벌 위협은 us-east-1 적재 → 서울만 보면 공백.
- 콘솔에만 쌓이면 무의미 → 이메일 실시간 통지.

**⚠️ 핵심 footgun 포인트 (면접)**
- **SNS 토픽에 명시적 정책을 쓰면 AWS 기본 정책을 덮어씀** → 기존 WAF 알람이 깨질 수 있음. 그래서 us-east-1 토픽정책에 `__default_statement_ID`(계정 소유자 권한)를 **일부러 함께 넣어 보존**. 알고 방어한 부분.

**비용**: GuardDuty 분석량 과금(평가판→유지 결정). S3 보호는 별도 리소스라 부담 시 DISABLE 가능.

**🎤 / ❓예상 질문**: GuardDuty(위협탐지) vs Config(구성준수) 구분 / 왜 2리전 / severity 필터 이유.

---

## access_analyzer.tf — 외부 노출 자동 순찰 (무료·무위험)

**무엇을 만드나**: IAM Access Analyzer 2개(서울 + us-east-1, `type=ACCOUNT`) + finding(`status=ACTIVE`만) → EventBridge → SNS(각 리전 토픽 재사용).

**왜**
- 모든 문(S3·IAM 역할·KMS 키 등)을 24h 순찰 → **외부 계정/퍼블릭 노출** 자동 발견. 사람이 정책 일일이 검사 불필요.
- 외부 분석기만 = **완전 무료**(미사용권한 $0.20/월, 내부 분석기 $9/리소스는 미사용).
- **위험 0**: 탐지 전용, 어떤 리소스도 변경/차단 안 함. 토픽정책은 GuardDuty 배선에서 이미 events 발행 허용.

**🎤 / ❓예상 질문**: "준수 축을 무료로 어떻게 보강?" → Access Analyzer 외부 분석기(무료) + IaC 예방고정.

---

## athena_results.tf — 로그 수사실(쿼리 결과 분리)

**무엇을 만드나**: Athena 결과 전용 S3 버킷(퍼블릭 차단 + 14일 수명주기 + force_destroy) + **워크그룹 2개**(`cloudtrail`→cloudtrail/, `flowlogs`→flowlogs/) + 결과 **SSE_S3 암호화** + `enforce_workgroup_configuration=true`.

**왜**
- 로그 원본 ≠ 조사 결과물(민감) → 분리(권한·수명주기·위생). 워크그룹별 출력위치 강제 = 폴더 자동 분리.
- 결과 암호화 **SSE_S3**(KMS 아님) = KMS 키정책 footgun 회피 의도적 선택.
- 스캔량 상한(`bytes_scanned_cutoff`)은 발표 중 큰 조회 막힐까봐 주석(옵션 비용 가드레일).

**🎤 / ❓예상 질문**: "왜 결과 버킷 분리?" → 민감 결과물 위생 + 권한 격리. "왜 워크그룹 2개?" → 결과 폴더 자동 분리 + 저장위치 강제.

---

## ✅ 04단계 한 줄 요약
> **행동(CloudTrail 멀티리전+무결성+생체정보 객체감사) · 트래픽(Flow Logs S3/parquet) · AI위협(GuardDuty 2리전) · 외부노출(Access Analyzer 무료) 4중 감시 + finding을 EventBridge→SNS로 실시간 통지, 로그는 Athena로 수사.**
> footgun 방어: SNS 기본 statement 보존 / Athena 결과 SSE_S3로 KMS 회피.
