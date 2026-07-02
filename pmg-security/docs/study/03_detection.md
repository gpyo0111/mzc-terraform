# 🔍 03. 탐지 (Detection) — 공부 카드 (방식②)

> 사용법: 카드 읽기 → ❓드릴 질문에 **말로 답** → **모범답안**과 대조 → 보강.
>
> 큰 그림: 예방(01)·경계(02)를 **뚫렸다고 가정**하고 "누가 무엇을 했는지 다 본다"는 단계.
> `CloudTrail(누가 무슨 API 호출)` + `Flow Logs(네트워크 통신)` + `GuardDuty(AI 위협판단)` + `Access Analyzer(외부 노출)` → 로그는 `Athena`로 조사.
> 한마디로 **"끄지 못하는 CCTV + 자동 순찰 경비원"**.

---

## 카드 1. CloudTrail (멀티리전 + 로그 무결성 검증 + 전용 S3 금고)

**흐름:** 계정에서 일어나는 **모든 API 호출**(누가·언제·무엇을·어디서) → CloudTrail이 기록 → **전용 S3 금고**(cloudtrail-logs 버킷)에 저장 → 30일 후 자동 삭제. 멀티리전이라 **어느 리전에서 한 짓도** 다 남고, 무결성 검증으로 **로그 위조도 탐지**.

**무엇:**
- `aws_cloudtrail.main` — 계정 활동 감사 로그(CCTV 녹화).
  - `is_multi_region_trail = true` — **전 리전** 활동 기록(해커가 안 쓰는 리전에 숨어 작업하는 것 차단).
  - `include_global_service_events = true` — IAM·STS 같은 **글로벌 서비스** 이벤트도 포함.
  - `enable_log_file_validation = true` — **로그 파일 무결성 검증**(해시 도장 → 나중에 로그가 변조됐는지 증명 가능).
- **전용 S3 금고** `cloudtrail-logs-{account_id}` + 퍼블릭 차단 4종 + **30일 수명주기**(비용).
- **버킷 정책**: `cloudtrail.amazonaws.com` 서비스에게만 `GetBucketAcl` + `PutObject`(자기 계정 경로 `AWSLogs/{account_id}/*`) 허용 + `bucket-owner-full-control` 조건.

**왜:**
- ① **모든 보안의 토대**: "누가 무엇을 했나"가 안 남으면 사고 조사·드리프트 추적·컴플라이언스가 불가능. CloudTrail이 EventBridge 알림·Athena 조사·GuardDuty의 **공통 데이터 원천**.
- ② **멀티리전**: 공격자가 평소 안 쓰는 리전(예: 남미)에서 작업하면 단일 리전 트레일은 못 봄 → 전 리전 켜야 사각지대 0.
- ③ **무결성 검증**: 공격자가 로그를 지우거나 고쳐 흔적을 없애도, 해시 도장이 깨져 **변조 사실 자체를 증명** → 부인방지(non-repudiation).

**어디:** 계정 전체. 로그는 cloudtrail-logs 버킷 → Athena로 조회(카드6).

**용어:**
- **CloudTrail** = 계정 내 모든 API 호출을 기록하는 감사 로그 서비스(누가·언제·무엇·어디서·성공여부).
- **로그 파일 무결성 검증** = 로그에 해시(digest)를 찍어, 사후에 누가 손댔는지 검증 가능하게 함.
- **부인방지** = "난 안 했다"고 발뺌 못 하게 행위를 증거로 남김.

**❓ 드릴 (보지 말고 말로):**
- Q1. `is_multi_region_trail = true`가 막는 공격 시나리오는?
- Q2. `enable_log_file_validation = true`는 무엇을 보장하나? 왜 생체정보 서비스에 중요?
- Q3. CloudTrail 로그를 담는 S3 버킷은 왜 **퍼블릭 차단 + 전용 버킷**이어야 하나?
- Q4. "CloudTrail은 왜 모든 보안의 토대"라고 하나?

**💡 모범답안:**
- A1. 공격자가 **평소 안 쓰는 리전**에서 리소스를 만들거나 침투 작업을 하는 경우. 단일 리전 트레일이면 그 리전을 안 보면 놓침. 멀티리전은 **전 리전 활동을 한 트레일에 모아** 사각지대를 없앰.
- A2. 로그 파일에 **해시 도장**을 찍어, 누군가 로그를 **삭제·변조하면 그 사실을 탐지·증명**할 수 있게 함. 생체정보(음성) 접근 기록은 **법적·컴플라이언스 증거**라 "이 로그는 위조 안 됐다"는 무결성이 핵심(부인방지).
- A3. CloudTrail 로그 자체가 **"누가 무엇을 했나"의 민감 정보**라 외부 노출되면 공격자에게 정찰 정보 제공 + 변조 위험. 그래서 퍼블릭 차단 + **로그 원본 전용 버킷**으로 격리(다른 데이터와 안 섞고 위생 관리).
- A4. EventBridge 실시간 알림(04), Athena 사후 조사(카드6), GuardDuty 위협 판단이 모두 **CloudTrail이 남긴 활동 기록을 원천 데이터로** 쓰기 때문. 로그가 없으면 탐지·대응·조사 전부 불가 → 그래서 **자동복구 Lambda(05)로 항상 켜져있게** 보호.

---

## 카드 2. CloudTrail S3 Data Events (audio uploads/ 객체 감사)

**흐름:** 누군가 음성 원본(생체정보)을 audio 버킷 `uploads/`에 올리거나(Put) 내려받음(Get) → CloudTrail이 **그 객체 접근 1건까지** 기록 → "누가 어떤 음성에 언제 접근했나" 추적 가능.

**무엇:**
- `aws_cloudtrail.main`의 `event_selector` 블록:
  - `read_write_type = "All"` — 업로드(Put)·다운로드(Get) **둘 다** 기록.
  - `include_management_events = true` — **기존 관리 이벤트 기록을 보존**(이 블록 추가 시 기본값이 대체되므로 명시).
  - `data_resource` = `AWS::S3::Object`, 값 = `audio.arn/uploads/` — **uploads/ 하위 객체만** 감사.
- **범위 한정**: 생체정보 핵심인 `uploads/` 1개 prefix만. 인식 결과 `results/`는 **비용 절감 위해 제외**.

**왜:**
- ① **관리 이벤트 vs 데이터 이벤트**: 기본 CloudTrail은 "버킷을 만들었다/지웠다" 같은 **관리 이벤트**만 기록. **객체 1건의 Get/Put**(누가 이 음성 파일을 읽었나)은 **데이터 이벤트**라 따로 켜야 함.
- ② **생체정보 접근 감사**: 음성 원본은 민감 개인정보라 "누가 언제 어떤 음성에 접근했나"를 남겨야 유출 사고 시 추적·컴플라이언스 대응 가능.
- ③ **비용 통제**: S3 Data Events는 **10만 건당 $0.10** 과금 → 전체 버킷이 아니라 **생체정보 핵심 prefix(uploads/)만** 한정해 비용 차단.

**어디:** audio 버킷 `uploads/`. (results/ 제외 — 추후 prefix 한 줄로 확장 가능)

**용어:**
- **관리 이벤트(Management Event)** = 리소스의 생성·삭제·설정 변경(컨트롤 플레인). 기본 기록.
- **데이터 이벤트(Data Event)** = 객체 자체의 읽기/쓰기(데이터 플레인). 양이 많아 기본 비활성 → 선택적으로 켬.

**❓ 드릴 (보지 말고 말로):**
- Q1. 관리 이벤트와 데이터 이벤트의 차이는? 기본 CloudTrail은 어느 쪽만 기록하나?
- Q2. `uploads/`만 감사하고 `results/`는 제외한 이유는? (두 가지)
- Q3. `include_management_events = true`를 굳이 명시한 이유는?

**💡 모범답안:**
- A1. 관리 이벤트 = "버킷·리소스를 만들었다/지웠다/설정 바꿨다"(컨트롤 플레인), 기본으로 기록됨. 데이터 이벤트 = "이 객체(음성 파일)를 읽었다/올렸다"(데이터 플레인), 양이 많아 기본 비활성 → **별도로 켜야** 객체 접근이 남음. 기본 CloudTrail은 **관리 이벤트만** 기록.
- A2. ① **생체정보 보안**: 음성 원본이 담기는 `uploads/`만 접근 감사가 꼭 필요. `results/`(인식 결과)는 상대적으로 덜 민감. ② **비용**: Data Events는 10만 건당 $0.10이라 전체를 켜면 과금 폭증 → 핵심 prefix만 한정해 비용 통제.
- A3. `event_selector` 블록을 추가하면 **기본 동작(관리 이벤트 기록)이 대체**돼서, 명시하지 않으면 기존 관리 이벤트 로깅이 꺼질 수 있음. → `true`로 명시해 **기존 관리 이벤트 기록을 그대로 보존**하면서 데이터 이벤트만 추가.

---

## 카드 3. VPC Flow Logs → S3 (CloudWatch 대신 S3 + Athena 최적화)

**흐름:** VPC를 드나드는 **모든 네트워크 통신**(누가→누구, 허용/거부) → Flow Log가 기록 → **S3 버킷**(parquet + 시간 파티션)에 저장 → Athena로 비용 효율적 조회.

**무엇:**
- `aws_flow_log.main` — `traffic_type = "ALL"`(허용+거부 모두), `vpc_id` 전체, **`log_destination_type = "s3"`**.
- `destination_options`: `file_format = "parquet"` + `hive_compatible_partitions = true` + `per_hour_partition = true` — **Athena 쿼리 비용·성능 최적화**.
- 전용 S3 버킷 + 퍼블릭 차단 + **30일 수명주기**.
- 버킷 정책: `delivery.logs.amazonaws.com`에게만 쓰기 허용 + `aws:SourceAccount`/`SourceArn` 조건으로 **내 계정 것만**.

**왜 (설계 결정 — CloudWatch → S3 전환):**
- ① **비용 절감**: 예전엔 CloudWatch Logs로 적재했는데 **로그 적재($0.50/GB)가 비쌈** → S3는 훨씬 싸고 Athena로 통일.
- ② **GuardDuty 영향 없음**: GuardDuty는 Flow Log를 **자체 피드로 직접 읽음** → CloudWatch 제거해도 위협 탐지에 영향 0.
- ③ **부수효과**: 이 전환으로 옛 flow-logs용 IAM role의 `Resource="*"` 와일드카드도 자동 제거(IAM 하드닝 덤).
- ④ **parquet + Hive 파티션**: Athena는 **스캔한 데이터량($5/TB)** 으로 과금 → 컬럼형(parquet) + 시간 파티션으로 **스캔 범위를 줄여 비용↓**.

**어디:** VPC 전체 네트워크. flow-logs 버킷 → Athena(flowlogs 워크그룹, 카드6).

**용어:**
- **VPC Flow Logs** = VPC 내 네트워크 트래픽의 "출발지→목적지, 포트, 허용/거부"를 기록(네트워크 번호판 장부).
- **parquet** = 컬럼 기반 압축 포맷. 필요한 컬럼만 읽어 스캔량↓ → Athena 비용↓.
- **파티션 프로젝션/Hive 파티션** = 시간 등으로 폴더를 나눠, 쿼리 시 필요한 구간만 스캔.

**❓ 드릴 (보지 말고 말로):**
- Q1. Flow Logs를 CloudWatch Logs가 아니라 **S3로** 보낸 이유는? (비용 + 탐지영향)
- Q2. parquet + 시간 파티션이 **Athena 비용**에 어떻게 도움 되나?
- Q3. CloudWatch flow log를 없애면 GuardDuty 위협 탐지가 약해지지 않나?

**💡 모범답안:**
- A1. **비용**: CloudWatch Logs는 로그 적재가 $0.50/GB로 비쌈 → S3는 훨씬 싸고 Athena 조회로 통일 가능. **탐지영향 없음**: GuardDuty가 Flow Log를 자체 피드로 직접 읽기 때문에 CloudWatch 경유를 없애도 위협 탐지엔 영향이 없음.
- A2. Athena는 **쿼리가 스캔한 데이터량으로 과금**($5/TB). parquet(컬럼형)는 필요한 컬럼만 읽어 스캔량을 줄이고, 시간 파티션은 "특정 날짜/시간만" 스캔하게 해 **전체를 안 훑음** → 비용·속도 둘 다 개선.
- A3. 안 약해짐. GuardDuty는 **VPC Flow Log를 AWS 내부 피드로 직접 구독**해서 분석하는 거지, 우리가 CloudWatch에 적재한 사본을 읽는 게 아님. 그래서 CloudWatch 적재를 없애도 GuardDuty는 그대로 작동. (CloudWatch는 우리가 보려고 쌓던 것 → S3+Athena로 대체)

---

## 카드 4. GuardDuty (2리전 AI 위협 탐지 + finding 알림 배선)

**흐름:** GuardDuty가 CloudTrail·Flow Log·DNS 로그를 **AI로 상시 분석** → 알려지지 않은/행동 기반 위협(이상 API, 코인 채굴, 침해된 자격증명 등) 탐지 → finding 발생 → **EventBridge가 Medium 이상만 걸러 SNS 이메일**로 전달.

**무엇:**
- `aws_guardduty_detector` **2개**: 서울(`seoul_detector`) + us-east-1(`us_east_1_detector`).
- `aws_guardduty_detector_feature`(S3_DATA_EVENTS, ENABLED) — S3 보호 기능(구 `datasources{s3_logs}` deprecated → 신문법).
- **알림 배선(서울)**: 신규 SNS 토픽 `security_alerts_seoul` + 이메일 구독 + 토픽 정책(EventBridge 발행 허용) + EventBridge 규칙(`source=aws.guardduty`, `severity >= 4`) → SNS.
- **알림 배선(us-east-1)**: 기존 WAF용 토픽 `security_alerts` 재사용 + 토픽 정책(**기본 statement 보존** + EventBridge 발행 추가) + EventBridge 규칙 → SNS.
- **severity 필터**: `>= 4`(Medium/High)만 알림 → Low(1.0~3.9) 노이즈 차단.

**왜:**
- ① **미지·행동 기반 위협**: 예방/경계는 "알려진 규칙"을 막지만, GuardDuty는 **평소와 다른 행동**(이상 패턴)을 AI로 잡아 **새로운/은밀한 위협**을 탐지. 광범위 탐지의 핵심.
- ② **2리전 이유**: 글로벌 서비스(IAM/STS/CloudFront/WAF) 위협 이벤트는 **us-east-1에 적재**됨 → 서울만 켜면 글로벌 위협을 놓침. 두 리전 다 켜야 탐지 공백 0.
- ③ **알림 배선**: GuardDuty가 finding을 콘솔에만 쌓으면 아무도 안 봄 → **EventBridge로 받아 이메일** 실시간 전달해야 의미.
- ④ **severity 필터**: Low까지 다 알리면 노이즈로 피로 → Medium 이상만(>=4) 사람에게.

**🔥 정직 포인트:**
- **토픽 정책 덮어쓰기 함정**: SNS에 명시적 정책을 쓰면 **AWS 기본 정책이 덮어써짐** → us-east-1 토픽은 기존 WAF 알람 발행이 깨지지 않도록 **기본 statement(`__default_statement_ID`)를 반드시 함께 보존**하고 EventBridge 발행 statement를 추가.
- GuardDuty S3 Protection은 **비용 요인** → 부담되면 `status`를 DISABLED로 끌 수 있음.

**어디:** 계정 전체(서울+us-east-1). finding → 각 리전 SNS 토픽 → 이메일.

**용어:**
- **GuardDuty** = AWS 관리형 위협 탐지 서비스. 로그를 AI/위협 인텔로 분석해 finding 생성(우리가 룰 안 짬).
- **finding** = GuardDuty가 탐지한 위협 항목(severity 점수 포함).
- **severity** = Low(1.0~3.9) / Medium(4.0~6.9) / High(7.0~8.9).

**❓ 드릴 (보지 말고 말로):**
- Q1. GuardDuty가 예방(WAF·SG)이나 CloudTrail과 다른 점은? (무엇을 잡나)
- Q2. GuardDuty를 서울 + us-east-1 **2리전**에 둔 이유는?
- Q3. severity `>= 4`로 거른 이유는?
- Q4. (정직) us-east-1 토픽 정책에서 기본 statement를 왜 꼭 보존했나?

**💡 모범답안:**
- A1. WAF/SG는 **알려진 규칙·패턴**을 막고, CloudTrail은 **활동을 기록**만 함. GuardDuty는 그 로그들을 **AI로 분석해 "평소와 다른 행동"(이상 API 호출, 침해된 키, 코인 채굴 통신 등)** 을 탐지 → **미지의/행동 기반 위협**을 잡음. 규칙으로 못 거르는 영역.
- A2. **글로벌 서비스(IAM·STS·CloudFront·WAF) 관련 위협 이벤트가 us-east-1에 적재**되기 때문. 서울만 켜면 그 글로벌 위협을 놓침 → 두 리전 다 켜야 사각지대가 없음.
- A3. Low(1.0~3.9)까지 다 알리면 **노이즈·알림 피로**로 정작 중요한 걸 놓침 → Medium 이상(>=4)만 사람에게 보내 신호 대 잡음비를 높임.
- A4. SNS에 **명시적 정책을 쓰면 AWS 기본 정책이 통째로 덮어써짐**. us-east-1 토픽은 원래 WAF 알람(CloudWatch)이 발행하던 토픽이라, 기본 statement를 안 남기면 **WAF 알람 발행이 깨짐** → 기본 statement 보존 + EventBridge 발행 statement 추가로 둘 다 살림.

---

## 카드 5. IAM Access Analyzer (외부 노출 자동 탐지 — 무료)

**흐름:** Access Analyzer가 계정의 모든 리소스(S3·IAM 역할·KMS 키·SQS·Lambda 등)를 **상시 자동 점검** → "외부 계정·퍼블릭 인터넷에서 접근 가능한 게 있나?" 발견 → 신규 ACTIVE finding → EventBridge → SNS 이메일.

**무엇:**
- `aws_accessanalyzer_analyzer` **2개**(type=`ACCOUNT`): 서울 + us-east-1.
- 알림: EventBridge 규칙(`source=aws.access-analyzer`, `detail.status=ACTIVE`만) → 서울/us-east-1 각 토픽.
- **status=ACTIVE만** 매칭 → 해소(RESOLVED)된 finding 재알림 노이즈 차단.

**왜:**
- ① **외부 노출 자동 감시**: 사람이 모든 정책을 눈으로 검사하는 대신, **실수로 외부·퍼블릭에 열린 리소스를 24시간 자동 발견**(준수 축 보강).
- ② **무료**: 외부 접근 분석기(type=ACCOUNT)만 사용 → **완전 무료**. (미사용 권한 분석 $0.20/ID·월, 내부 분석기 $9/리소스·월은 **안 씀**)
- ③ **2리전**: IAM(글로벌)·CloudFront 등 글로벌 자원 노출은 us-east-1에 잡힘 → 둘 다 둬서 공백 0(둘 다 무료).
- ④ **순수 탐지 전용**: 어떤 리소스도 변경·차단 안 함 → apply 위험 0.

**어디:** 계정 전체(서울+us-east-1). finding → SNS 이메일.

**용어:**
- **IAM Access Analyzer** = 리소스 정책을 분석해 "외부에서 접근 가능한가"를 자동 탐지하는 무료 서비스.
- **외부 접근 분석기(ACCOUNT type)** = 단일 계정 기준 외부 노출 탐지(조직 단위 아님).

**❓ 드릴 (보지 말고 말로):**
- Q1. Access Analyzer가 하는 일을 한 문장으로? GuardDuty와 뭐가 다른가?
- Q2. 비용이 왜 무료인가? (어떤 기능을 안 썼나)
- Q3. `status=ACTIVE`만 알림으로 거른 이유는?

**💡 모범답안:**
- A1. 계정의 리소스(S3·IAM 역할·KMS 키 등)가 **외부 계정·퍼블릭에 실수로 노출됐는지 자동·상시 탐지**. GuardDuty가 "행동/위협"을 본다면, Access Analyzer는 "**정책상 외부에 열려있나(노출 상태)**"를 봄 → 둘은 보는 대상이 다름(위협 vs 노출).
- A2. **외부 접근 분석기(type=ACCOUNT)만** 사용해서 무료. 유료인 **미사용 권한 분석($0.20/ID·월)** 과 **내부 접근 분석기($9/리소스·월)** 는 안 씀.
- A3. finding이 해소(RESOLVED)된 뒤에도 알림이 오면 노이즈 → **새로 발생한 활성(ACTIVE) 노출만** 알려 의미 있는 신호만 받음.

---

## 카드 6. Athena 결과 버킷 + 워크그룹 분리 (조사 위생)

**흐름:** CloudTrail·Flow Log 원본은 각 S3 버킷에 → Athena로 SQL 조회 → **쿼리 결과(CSV)는 별도 athena-results 버킷**의 워크그룹별 폴더(cloudtrail/ vs flowlogs/)에 저장 → 14일 후 자동 삭제.

**무엇:**
- 전용 버킷 `athena-results-{account_id}` + 퍼블릭 차단 + **14일 수명주기**.
- 워크그룹 2개: `cloudtrail`(결과→`cloudtrail/`) + `flowlogs`(결과→`flowlogs/`).
  - `enforce_workgroup_configuration = true` — 사용자가 임의 위치 저장 못 하게 강제.
  - `encryption_configuration = SSE_S3` — 결과물도 자동 암호화.
  - (옵션) `bytes_scanned_cutoff_per_query` — 쿼리 스캔량 상한(비용 폭주 방지), 발표 중 막힘 방지 위해 기본 주석.

**왜:**
- ① **원본 ≠ 결과 분리**: 로그 원본 버킷에 조사 결과가 섞이면 권한·수명주기·관리가 꼬임 → 결과 전용 버킷으로 분리.
- ② **결과물 위생**: 쿼리 결과 CSV엔 "누가 어떤 음성에 접근했나" 같은 **민감 조사 내용**이 그대로 남음 → 퍼블릭 차단 + 짧은 수명주기(14일) + 암호화.
- ③ **워크그룹 분리**: Athena는 워크그룹 단위로 결과 위치를 정함 → 안 나누면 CloudTrail/Flow 결과가 한 폴더에 섞임 → 워크그룹별로 폴더 자동 분리.
- ④ **KMS 대신 SSE_S3**: 결과 암호화에 KMS 키정책 footgun(잠금사고)을 피하려 **S3 관리키(SSE_S3)** 사용.

**어디:** Athena 콘솔에서 쿼리 실행 전 워크그룹 선택. (쿼리 모음 = `ATHENA_SECURITY_QUERIES.md`)

**용어:**
- **Athena** = S3의 데이터를 **SQL로 조회**하는 서버리스 쿼리 서비스. 스캔량($5/TB)으로 과금.
- **워크그룹(Workgroup)** = Athena 쿼리의 결과 저장 위치·암호화·비용 상한을 묶어 통제하는 단위.

**❓ 드릴 (보지 말고 말로):**
- Q1. 로그 원본 버킷에 조사 결과를 안 쌓고 **별도 버킷**으로 분리한 이유는?
- Q2. 워크그룹을 cloudtrail/flowlogs **2개로 나눈** 이유는?
- Q3. 조사 결과 버킷에 퍼블릭 차단·짧은 수명주기·암호화를 다 건 이유는?

**💡 모범답안:**
- A1. 로그 **원본**과 조사 **결과물**이 한 버킷에 섞이면 권한·수명주기·관리가 꼬임. 결과 전용 버킷으로 분리하면 위생적으로 관리되고, 결과물에만 짧은 수명주기·암호화를 따로 적용 가능.
- A2. Athena는 **워크그룹 단위로 결과 저장 위치**를 정함. 안 나누면 CloudTrail 조사 결과와 Flow Log 조사 결과가 **한 폴더에 섞임** → 워크그룹을 나눠 출력 위치를 cloudtrail/·flowlogs/로 박아두면 자동 분리.
- A3. 쿼리 결과 CSV엔 "누가 어떤 음성에 접근했나" 같은 **민감 조사 내용**이 그대로 남음 → 외부 노출 절대 금지(퍼블릭 차단) + 불필요한 잔존 방지(14일 삭제) + 유출 대비(SSE 암호화). 조사물도 데이터만큼 민감하다는 위생 관점.

---

## ✅ 탐지(Detection) 카드 1~6 — 한 줄씩 복습

1. **CloudTrail** — 멀티리전 + 무결성 검증으로 "누가 무엇을" 다 기록. 모든 탐지·조사의 토대.
2. **S3 Data Events** — audio uploads/ 객체 Get/Put까지 감사(생체정보 접근 추적), prefix 한정으로 비용 통제.
3. **VPC Flow Logs → S3** — 네트워크 통신 기록, CloudWatch 대신 S3+Athena(비용↓, GuardDuty 영향 0).
4. **GuardDuty** — 2리전 AI 위협 탐지, Medium 이상 finding → 이메일. 미지·행동 기반 위협 담당.
5. **Access Analyzer** — 외부 노출 자동 탐지(무료), ACTIVE finding만 알림.
6. **Athena 결과 버킷/워크그룹** — 원본↔결과 분리 + 폴더 분리 + 결과물 위생(차단·14일·암호화).

> 관통하는 한 문장: **"끄지 못하고 위조 못 하는 CCTV(CloudTrail)로 다 녹화하고 · 네트워크 장부(Flow Logs)를 남기고 · AI 경비원(GuardDuty)이 행동을 순찰하고 · 외부에 열린 문(Access Analyzer)을 자동 점검하고 · 사고 나면 Athena로 30초 만에 추적한다."**
> 다음 단계: `04_alerting`(알림 — EventBridge·SNS) 카드로.
