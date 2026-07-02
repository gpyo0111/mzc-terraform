# 🚨 04. 알림 (Alerting) — 공부 카드 (방식②)

> 사용법: 카드 읽기 → ❓드릴 질문에 **말로 답** → **모범답안**과 대조 → 보강.
>
> 큰 그림: 탐지(03)가 "위협을 본다"면, 알림(04)은 **"본 것을 사람에게 즉시 전달"** 하는 단계.
> `사건(CloudTrail/GuardDuty/Analyzer/WAF)` → `EventBridge(이벤트 필터·라우팅) 또는 CloudWatch Alarm(수치 임계)` → `SNS(방송국)` → `이메일`.
> 핵심: **"탐지만 하고 안 알리면 콘솔에 쌓여 아무도 안 본다."**

---

## 카드 1. SNS 보안 토픽 2개 (서울 + us-east-1) + 이메일 구독

**흐름:** 보안 사건 발생 → EventBridge/CloudWatch가 **SNS 토픽(방송국)** 에 발행 → 토픽에 구독된 **담당자 이메일**로 전달.

**무엇:**
- `aws_sns_topic.security_alerts` (**us-east-1**) — WAF·GuardDuty(us-east-1)·정책이벤트(글로벌) 알림 허브.
- `aws_sns_topic.security_alerts_seoul` (**서울**, guardduty_security.tf) — 서울 리전 GuardDuty·SG·CloudTrail 변조 알림 허브.
- 각 토픽에 `aws_sns_topic_subscription`(protocol=`email`, endpoint=`var.security_alert_email`) — 변수로 관리.
- **토픽 정책**: `events.amazonaws.com`(EventBridge)이 `sns:Publish` 하도록 허용.

**왜:**
- ① **왜 2개(리전 분리)**: AWS 이벤트는 **발생 리전의 EventBridge 버스**로 들어옴. 글로벌 서비스(IAM/STS/CloudFront/WAF)는 **us-east-1**, 리전 자원(서울 EC2 SG/CloudTrail)은 **서울**. EventBridge 규칙은 **같은 리전 SNS 토픽**에만 보낼 수 있어 → 리전별 토픽 필요.
- ② **이메일 변수화**: `var.security_alert_email`로 담당자 이메일을 한 곳에서 관리(하드코딩 X) → 변경 시 한 줄.
- ③ **토픽 정책**: EventBridge가 토픽에 발행하려면 명시적 허용 필요.

**🔥 정직 포인트:**
- 현재 알림 채널은 **이메일**. 실무에선 **Slack/PagerDuty**(protocol=https)로 확장하는 게 정석(코드 주석에도 "슬랙 연동 시 https" 언급). 발표 시 "이메일로 구현, 운영 시 Slack 웹훅 전환 가능"으로.
- us-east-1 토픽은 WAF 알람과 공유 → **토픽 정책 덮어쓰기 시 기본 statement 보존 필수**(03 카드4 참조).

**어디:** 모든 보안 알림의 종착지. 신규 이메일 구독은 **AWS 확인 메일에서 Confirm** 해야 수신 시작.

**용어:**
- **SNS(Simple Notification Service)** = 발행-구독(pub/sub) 메시지 방송국. 토픽에 발행하면 구독자(이메일/SMS/HTTPS/Lambda)에 일제 전달.
- **구독(Subscription)** = 토픽 메시지를 받을 수신처. 이메일은 첫 구독 시 Confirm 필요.

**❓ 드릴 (보지 말고 말로):**
- Q1. SNS 토픽을 왜 서울·us-east-1 **2개**로 나눴나?
- Q2. 이메일을 코드에 하드코딩 안 하고 변수로 뺀 이유는?
- Q3. 새 이메일 구독을 apply하면 바로 알림이 오나?

**💡 모범답안:**
- A1. AWS 이벤트는 **발생 리전의 EventBridge 버스**에 들어오고, EventBridge 규칙은 **같은 리전의 SNS 토픽**으로만 보낼 수 있음. 글로벌 서비스(IAM/WAF/CloudFront)는 us-east-1, 서울 리전 자원(EC2 SG/CloudTrail)은 서울에 이벤트가 잡히므로 **각 리전에 토픽이 하나씩** 있어야 둘 다 알림 가능.
- A2. 담당자가 바뀌거나 여러 곳에서 같은 이메일을 참조할 때 **한 곳(`var.security_alert_email`)만 고치면** 되도록. 하드코딩하면 여러 파일을 다 찾아 고쳐야 함(유지보수·실수 위험).
- A3. 아니. 이메일 구독은 AWS가 **확인 메일**을 보내고, 수신자가 **Confirm을 눌러야** 비로소 알림이 옴(원치 않는 구독 방지). apply 후 메일함에서 확인 필요.

---

## 카드 2. EventBridge — finding 라우팅 (GuardDuty / Access Analyzer)

**흐름:** GuardDuty·Access Analyzer가 finding 발생 → **EventBridge 규칙이 이벤트 패턴으로 필터링**(원하는 것만) → 매칭되면 **SNS 타깃**으로 라우팅 → 이메일.

**무엇:**
- `aws_cloudwatch_event_rule` + `aws_cloudwatch_event_target` 쌍 (EventBridge = 옛 CloudWatch Events).
- **GuardDuty 규칙**: `source=aws.guardduty`, `detail-type=GuardDuty Finding`, **`severity >= 4`**(Medium 이상) → SNS.
- **Access Analyzer 규칙**: `source=aws.access-analyzer`, `detail-type=Access Analyzer Finding`, **`status=ACTIVE`** → SNS.
- 서울·us-east-1 각각 규칙+타깃 쌍(2리전 커버).

**왜:**
- ① **이벤트 패턴 필터링**: EventBridge는 JSON 이벤트의 특정 필드(`severity`, `status`)를 **패턴 매칭**해 원하는 것만 통과 → 노이즈 차단(Low finding/RESOLVED는 안 보냄).
- ② **느슨한 결합**: 탐지(GuardDuty)와 알림(SNS)을 EventBridge가 중개 → 서로 직접 몰라도 됨(이벤트 기반 아키텍처).
- ③ **서버리스·저비용**: 규칙 매칭은 AWS가 관리, 트리거될 때만 동작.

**어디:** GuardDuty·Access Analyzer finding → 각 리전 SNS 토픽.

**용어:**
- **EventBridge** = 이벤트 버스. 서비스들이 내보내는 이벤트를 **패턴으로 필터링·라우팅**(과거 명칭 CloudWatch Events, 코드 리소스명이 `aws_cloudwatch_event_*`인 이유).
- **이벤트 패턴** = 어떤 이벤트를 잡을지 정하는 JSON 필터(source/detail-type/detail 필드).

**❓ 드릴 (보지 말고 말로):**
- Q1. EventBridge가 하는 일을 한 문장으로? 왜 GuardDuty를 SNS에 직접 안 붙이고 EventBridge를 끼나?
- Q2. `severity >= 4`, `status=ACTIVE` 같은 패턴 필터가 주는 이점은?
- Q3. 코드 리소스명이 `aws_cloudwatch_event_rule`인데 왜 EventBridge라고 부르나?

**💡 모범답안:**
- A1. 여러 서비스가 내보내는 **이벤트를 패턴으로 필터링해 원하는 타깃(SNS/Lambda)으로 라우팅**하는 이벤트 버스. GuardDuty finding은 그냥 두면 콘솔에만 쌓이는데, EventBridge가 **"Medium 이상만 골라" SNS로 보내** 실시간 이메일이 되게 함(필터링+중개 역할).
- A2. **노이즈 차단.** severity>=4는 Low finding을, status=ACTIVE는 이미 해소된 finding 재알림을 걸러냄 → 사람이 **의미 있는 신호만** 받아 알림 피로를 줄임.
- A3. EventBridge의 **이전 이름이 CloudWatch Events**라, Terraform 리소스명이 아직 `aws_cloudwatch_event_*`로 남아있음. 기능·콘솔은 EventBridge로 통합됨(같은 것).

---

## 카드 3. 고위험 정책 이벤트 알림 (root / IAM / SG / CloudTrail 변조)

**흐름:** CloudTrail 관리 이벤트가 **EventBridge 기본 버스로 자동 전달** → "발생 즉시 사람이 알아야 할" 4종 행위를 패턴 매칭 → SNS 이메일.

**무엇 (EventBridge 규칙 4개):**
| # | 규칙 | 잡는 이벤트 | 리전→토픽 |
|---|---|---|---|
| 1 | **루트 계정 사용** | Console Sign In / API Call + `userIdentity.type=Root` | us-east-1 |
| 2 | **IAM 민감 변경** | CreateUser, CreateAccessKey, AttachRolePolicy, DeactivateMFADevice 등 | us-east-1 |
| 3 | **SG 규칙 변경** | AuthorizeSecurityGroupIngress/Egress, **ModifySecurityGroupRules** | 서울 |
| 4 | **CloudTrail 변조** | StopLogging, DeleteTrail, UpdateTrail, PutEventSelectors | 서울 |

- **전제**: 멀티리전 CloudTrail이 켜져 있어 관리 이벤트가 각 리전 **EventBridge 기본 버스로 자동 전달** → CloudWatch Logs 적재 없이 동작(저비용).

**왜:**
- ① **명확한 고위험 행위**: GuardDuty(행동 기반)와 별개로, **"이건 무조건 사람이 봐야 함"** 인 정책성 행동을 CloudTrail에서 직접 매칭.
  - **루트 사용**: 루트는 평소 거의 안 써야 정상 → 사용 자체가 고신호.
  - **IAM 민감 변경**: 백도어 계정·키 생성, 권한 탈취 징후.
  - **SG 변경**: 방화벽 구멍 뚫기 징후(ModifySecurityGroupRules는 콘솔 편집 사각지대 커버).
  - **CloudTrail 변조**: 감사 로그 끄기/삭제 = 공격 은폐 첫 수순(T1562).
- ② **저비용**: CloudTrail→EventBridge 기본 버스 자동 전달을 활용 → CloudWatch Logs 수집비 없이 동작.
- ③ **순수 additive**: 규칙+타깃만 추가, 서비스 영향 0.

**🔥 정직 포인트 (알림 vs 자동대응 경계):**
- 이 4종은 **"알림만"** 이 기본인데, 그중 **SG 변경(#3)·CloudTrail 변조(#4)는 05단계 자동대응 Lambda가 같은 규칙을 재사용**해 자동 회수/복구까지 함.
- **루트 사용·IAM 변경(#1·#2)은 자동대응 안 함** → 자동으로 되돌리면 **정상 작업을 파괴**할 위험이 커서 **사람 판단(알림)에 맡김**. (대응 자동화의 적정선)

**어디:** 계정 전체. #1·#2 → us-east-1 토픽, #3·#4 → 서울 토픽.

**용어:**
- **EventBridge 기본 버스(default bus)** = 계정의 AWS 서비스 이벤트가 자동으로 흘러드는 기본 이벤트 버스(별도 적재 설정 불필요).
- **T1562 (Impair Defenses)** = 공격자가 방어/로깅을 무력화하는 MITRE ATT&CK 기법.

**❓ 드릴 (보지 말고 말로):**
- Q1. 이 4종 알림과 GuardDuty 알림(카드2)의 차이는? (왜 둘 다 필요)
- Q2. 루트 사용·CloudTrail 중지가 왜 "고위험 신호"인가?
- Q3. CloudWatch Logs 수집 없이 어떻게 CloudTrail 이벤트로 알림이 되나?
- Q4. (정직) 4종 중 SG·CloudTrail은 자동대응하는데 루트·IAM은 알림만인 이유는?

**💡 모범답안:**
- A1. GuardDuty는 **AI가 행동을 보고 "이상하다"** 를 판단(미지 위협). 이 4종은 **"무조건 위험한 명확한 행위"** 를 CloudTrail 이벤트에서 **규칙으로 확정 매칭**(정의가 명확). 행동 기반(GuardDuty) + 규칙 기반(EventBridge)을 **둘 다** 써서 빈틈을 메움.
- A2. **루트**는 최상위 권한이라 평소 거의 안 써야 정상 → 사용 자체가 침해/오용 신호. **CloudTrail 중지/삭제**는 공격자가 **흔적을 지우려는 첫 행동**(T1562)이라, 이게 뜨면 그 직후 다른 공격이 진행 중일 가능성이 높음.
- A3. 멀티리전 CloudTrail이 켜져 있으면 **관리 이벤트가 각 리전 EventBridge 기본 버스로 자동 전달**됨. EventBridge 규칙이 거기서 바로 패턴 매칭하므로, **CloudWatch Logs에 따로 적재(비용 발생)하지 않아도** 알림이 동작.
- A4. **SG·CloudTrail 변조는 "되돌리는 게 거의 항상 정답"**(위험 개방 회수, 로그 재가동)이라 자동대응이 안전. 반면 **루트 사용·IAM 변경은 정상 운영 작업일 수도** 있어, 자동으로 되돌리면 **정상 작업을 파괴**할 위험 → 사람이 판단하도록 알림만. (자동화는 "오작동해도 안전한 것"에만)

---

## 카드 4. WAF BlockedRequests 알람 (CloudWatch Alarm)

**흐름:** WAF 규칙 5(rate-limit)가 누군가를 차단 → `BlockedRequests` 메트릭 증가 → **CloudWatch Alarm이 5분 합계 > 0이면 발동** → SNS 이메일.

**무엇:**
- `aws_cloudwatch_metric_alarm.waf_any_blocked_alarm` (us-east-1):
  - metric `BlockedRequests`, namespace `AWS/WAFV2`, period 300s, statistic `Sum`, **threshold 0**(GreaterThan), evaluation 1회.
  - dimensions: `WebACL=securevoice-dev-waf`, `Region=us-east-1`.
  - alarm_actions → `security_alerts`(us-east-1 SNS).

**왜:**
- ① **수치 임계 = CloudWatch Alarm 영역**: "5분간 차단 합계가 0을 넘는가"는 **숫자 누적 비교**라 EventBridge(이산 사건)로는 불가 → CloudWatch Alarm 고유.
- ② **WebACL 전체 조준**: 특정 규칙이 아니라 Web ACL **전체 BlockedRequests 총합** → "5룰 중 뭐든 1건이라도 차단되면" 비상벨.
- ③ **연결고리**: 규칙 1~4는 Count라 BlockedRequests를 안 만듦 → **차단을 만드는 건 규칙 5(rate-limit)뿐** → 사실상 **"rate-limit 차단 시 즉시 알림"**.

**🔥 정직/비용 포인트:**
- 비싸서 피한 건 CloudWatch **로그 적재($0.50/GB)**. 이 알람은 **WAF 무료 메트릭 + 알람 $0.10/월**이라 그 비용과 무관.
- threshold=0이라 아주 민감 → 향후 규칙 1~4를 Block 전환하면 정상 트래픽 차단까지 다 알릴 수 있어, 그때는 임계치 튜닝 필요.

**어디:** us-east-1(CloudFront 글로벌 메트릭은 us-east-1 수집). → us-east-1 SNS 토픽.

**용어:**
- **CloudWatch Alarm** = 메트릭(숫자)이 임계치를 넘으면 액션(SNS 등)을 발동. (vs EventBridge = 이산 사건 패턴)
- **dimension** = 메트릭을 좁히는 키(여기선 WebACL·Region).

**❓ 드릴 (보지 말고 말로):**
- Q1. 이 알람은 왜 EventBridge가 아니라 CloudWatch Alarm으로 만들었나?
- Q2. threshold=0이 의미하는 바는? 실제로 무엇이 이 알람을 울리나?
- Q3. "CloudWatch는 비싸서 피한다며?" 반박에 답?

**💡 모범답안:**
- A1. "5분간 차단 합계 > 0"은 **숫자 누적 임계치 비교**라서 **CloudWatch Alarm의 고유 영역**. EventBridge는 "root 로그인" 같은 **이산 사건**만 패턴 매칭하지, "N건 넘으면"이라는 수치 비교는 못 함.
- A2. threshold=0 = **단 1건이라도 차단되면** 알림. WAF 규칙 1~4는 Count(차단 안 함)라 BlockedRequests를 안 만들고, **규칙 5(rate-limit)만 실제 Block** → 사실상 이 알람은 **"rate-limit이 누굴 차단하면 즉시 알림"** 으로 작동.
- A3. 비싸서 피한 건 CloudWatch **로그 적재**($0.50/GB, CloudTrail 풀스트리밍 같은 것). 이 알람은 **WAF가 무료로 내보내는 메트릭 + 알람 1개($0.10/월)** 라 로그 적재가 전혀 없음 → 그 비용 항목과 무관.

---

## ✅ 알림(Alerting) 카드 1~4 — 한 줄씩 복습

1. **SNS 토픽 2개** — 서울·us-east-1(이벤트는 발생 리전 버스 → 리전별 토픽 필요), 이메일 구독(Confirm 필요).
2. **EventBridge finding 라우팅** — GuardDuty(severity>=4)·Analyzer(ACTIVE)를 패턴 필터링해 SNS로. 노이즈 차단.
3. **고위험 정책 이벤트** — 루트/IAM/SG/CloudTrail 변조 4종, CloudTrail→기본버스 자동전달(저비용). SG·CloudTrail은 05 자동대응으로 승격, 루트·IAM은 알림만.
4. **WAF BlockedRequests 알람** — CloudWatch Alarm(수치 임계 0), 사실상 rate-limit 차단 알림. 로그적재 비용과 무관.

> 관통하는 한 문장: **"이산 사건(누가 root 썼다·SG 열었다)은 EventBridge로, 수치 폭증(WAF 차단 N건)은 CloudWatch Alarm으로 잡아 → SNS 방송국(리전별 2개)을 거쳐 담당자 이메일로 즉시 전달. 탐지를 행동으로 잇는 신경망."**
> 다음 단계: `05_response`(대응 — Lambda 자가복구) 카드로.
