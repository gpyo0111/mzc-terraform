# 🌐 02. 경계 (Perimeter) — 공부 카드 (방식②)

> 사용법: 카드 읽기 → ❓드릴 질문에 **말로 답** → **모범답안**과 대조 → 보강.
> (Notion: 모범답안 줄들을 선택해 토글로 감싸면 가리고 풀기 좋음)
>
> 큰 그림: `사용자 → CloudFront(엣지) → 🛡️WAF(검문소) → ALB → ECS`.
> 예방(01)이 "데이터·접근을 잠그는 안쪽"이라면, 경계(02 WAF)는 **앱에 트래픽이 닿기 전 엣지(성문)에서 거르는 바깥쪽 방어선**이다.

---

## 카드 1. WAF 검문소 전체 구조 (CloudFront 엣지 / us-east-1 / scope·default_action)

**흐름:** 사용자 요청 → CloudFront 엣지 도착 → **WAF Web ACL이 패킷을 먼저 검사** → 5대 규칙 통과한 정상 트래픽만 `default_action allow`로 통과 → ALB → ECS. 공격 패킷은 앱(ECS)에 **닿기 전에** 엣지에서 걸러진다.

**무엇:**
- `aws_wafv2_web_acl.main` — CloudFront 엣지에 붙는 웹 방화벽(검문소).
- `scope = "CLOUDFRONT"` — CloudFront(글로벌)용. (ALB·API GW용이면 `REGIONAL`)
- `provider = aws.us_east_1` — **이 파일이 us-east-1 프로바이더 alias의 출발점.** CloudFront용 WAF는 **us-east-1에만** 생성 가능 → 별도 리전 통로 정의(`provider "aws" { alias = "us_east_1" }`). GuardDuty·SNS 등 다른 글로벌 리소스도 이 alias 공유.
- `default_action { allow {} }` — 5대 규칙에 안 걸린 트래픽은 **기본 통과**. (화이트리스트가 아니라 블랙리스트 방식 — 정상 통과 + 나쁜 것만 거름)
- 전역 `visibility_config` — Web ACL 전체 트래픽 통계를 CloudWatch로 전송 + 샘플 요청 저장.

**왜:**
- ① **앱 도달 전 차단**: 엣지(CloudFront)에서 거르면 공격 패킷이 **ALB·ECS에 닿기 전에** 차단 → 백엔드 부하·장애·비용 방어. (몸에 칼 닿기 전 성문에서 잡기)
- ② **관리형 위주라 운영 부담↓**: AWS가 시그니처를 자동 업데이트(뒤 카드2) → 우리가 룰을 직접 관리 안 함.

**어디:** CloudFront 배포 앞단(엣지). 단, **연결(attach)은 콘솔 수동** → 카드 4 정직 포인트 참조.

**용어:**
- **Web ACL** = WAF의 규칙 묶음(Access Control List). 여기에 규칙들을 priority 순으로 담는다.
- **scope CLOUDFRONT vs REGIONAL** = 글로벌(CloudFront)이냐 특정 리전 리소스(ALB 등)냐. CLOUDFRONT는 us-east-1 고정.
- **default_action** = 어떤 규칙에도 안 걸린 트래픽의 처리(여기선 allow).

**❓ 드릴 (보지 말고 말로):**
- Q1. WAF를 왜 서울이 아니라 **us-east-1(미국)** 에 만들었나?
- Q2. `default_action`이 `allow`인 게 무슨 의미? 이게 화이트리스트인가 블랙리스트인가?
- Q3. WAF를 엣지(CloudFront)에 두는 이점은? ALB 앞에 두는 것과 뭐가 다른가?

**💡 모범답안:**
- A1. **CloudFront(글로벌 서비스)용 WAF는 `scope=CLOUDFRONT`라 us-east-1 리전에만 생성 가능**(AWS 제약). 그래서 이 파일에 us-east-1 프로바이더 alias를 정의했고, 다른 글로벌 리소스(GuardDuty us-east-1·WAF용 SNS 등)도 이 통로를 공유. (ALB용 WAF였다면 서울 `REGIONAL`)
- A2. `default_action allow` = **규칙에 안 걸린 트래픽은 기본 통과** → **블랙리스트 방식**(정상은 다 통과시키고, 나쁜 패턴만 골라 막음). 웹 서비스는 불특정 다수가 와야 하므로 "기본 차단(화이트리스트)"이 아니라 "기본 통과 + 악성만 거름"이 맞다.
- A3. 엣지에 두면 공격이 **백엔드(ALB·ECS)에 도달하기 전** 글로벌 엣지에서 걸러져 ⓐ 백엔드 부하·비용·장애를 사전 방어하고 ⓑ 전 세계 엣지에서 분산 처리. ALB(REGIONAL) WAF는 서울 리전 도달 후 검사라 그만큼 안쪽. 우리는 CloudFront가 정문이라 엣지 WAF가 맞다.

---

## 카드 2. 관리형 규칙 4종 + Count 모드 (오탐 방지 정석)

**흐름:** 통과한 패킷을 priority 1→4 순서로 검사 → 각 규칙이 매칭되는 공격 패턴을 탐지 → **현재는 `override_action count`라 "잡아도 통과시키고 기록만"** → CloudWatch에 탐지 지표·샘플 적재.

**무엇 (AWS 관리형 규칙 4개, priority 순):**

| 순위 | 규칙 | 막는 것 | 출처 |
|---|---|---|---|
| 1 | **IP Reputation List** | AWS가 수집한 전 세계 악성 IP "전과자" 즉시 필터 | AWS 기본 권장 |
| 2 | **Common Rule Set** | OWASP Top 10(XSS 등) 흔한 웹 공격 | AWS 공통 코어 |
| 3 | **Known Bad Inputs** | Log4j 등 알려진 RCE(원격코드실행) 패턴 | AWS 기본 권장 |
| 4 | **SQLi Rule Set** | DB 탈취 SQL 인젝션 | 커스텀 추가 |

- 전부 `managed_rule_group_statement`(vendor_name=`AWS`) — **AWS가 시그니처를 자동 업데이트**하는 관리형 룰 그룹.
- ⚠️ 4개 모두 `override_action { count {} }` — **Count(감시) 모드**. 매칭돼도 차단 안 하고 **기록만** 하고 통과.
- 각 규칙 `visibility_config` — CloudWatch 메트릭 + 샘플 요청 수집 ON.

**왜 (priority 순서가 곧 효율):**
- 1순위 **IP 평판**: 악성 IP는 **패킷 내용을 볼 필요도 없이** 출처로 즉시 거름(가장 싸고 빠른 필터).
- 2~4순위: IP를 통과한 패킷의 **내용(payload)** 을 정밀 검사 — 흔한 웹 공격(2) → 치명적 RCE(3) → DB 인젝션(4).
- 관리형인 이유: XSS·SQLi·Log4j 같은 공격 시그니처는 계속 진화 → **AWS가 자동 갱신**해주는 룰을 쓰면 우리가 패턴을 직접 유지보수할 필요가 없다(운영 부담↓).

**🔥 핵심 정직 포인트 (발표 차별화 — Count 모드):**
- **규칙 1~4는 Block이 아니라 Count(감시만).** `override_action { count {} }` = 공격 패턴을 잡아도 **차단하지 않고 기록만** 하고 통과시킴.
- **사유 = 오탐(false positive) 방지.** 개발 단계에서 곧장 Block을 켜면 **정상 음성 업로드(오디오 바이너리 등)** 까지 룰에 걸려 차단될 수 있어 서비스 장애 위험.
- **정석 튜닝 절차**: 먼저 Count로 돌려 **CloudWatch 로그·샘플로 정상 트래픽이 안 걸리는지 관찰** → 오탐 0 확인 후 **단계적으로 Block 전환**.
- 이 전환(백로그 #6)은 **프로젝트 기간상 보류 → 발표 시 구두 설명**. "WAF 튜닝의 정석대로 Count 관찰 단계를 뒀다"는 **운영 감각** 어필 포인트. (Count여도 **탐지·기록·알림은 정상 작동**하므로 공격 가시성은 확보됨)

**어디:** CloudFront 엣지(Web ACL 안). 탐지 지표는 CloudWatch.

**용어:**
- **관리형 룰 그룹(Managed Rule Group)** = AWS(또는 벤더)가 미리 만들고 **자동 업데이트**하는 규칙 묶음.
- **override_action count** = 룰 그룹의 원래 동작을 덮어써 **전부 Count(기록만)** 로 바꿈. (vs `none {}` = 룰 그룹 원래 동작대로 Block)
- **OWASP Top 10** = 가장 흔한 웹 취약점 10선(XSS, 인젝션 등) — Common Rule Set이 이걸 커버.

**❓ 드릴 (보지 말고 말로):**
- Q1. 규칙 priority가 IP평판(1)→Common(2)→BadInputs(3)→SQLi(4) 순인 **이유**는?
- Q2. `override_action { count {} }`가 정확히 무슨 동작인가? Block과 뭐가 다른가?
- Q3. 규칙 1~4를 다 Count로 둔 **이유**와, 그래도 의미가 있는 이유는?
- Q4. "왜 직접 룰을 안 짜고 **AWS 관리형**을 쓰나?" 반박에 답?

**💡 모범답안:**
- A1. **싸고 빠른 필터를 앞에** 두는 효율 설계. 1순위 IP 평판은 **패킷 내용을 볼 필요 없이 출처(악성 IP)** 만으로 즉시 거름 → 뒤 단계 부하를 줄임. 그 다음 통과한 패킷의 **내용**을 점점 정밀하게 검사(흔한 웹공격→RCE→SQLi).
- A2. `count`는 룰 그룹이 공격을 **매칭해도 차단하지 않고 CloudWatch에 기록만** 하고 통과시킴. `block`(또는 룰 원래 동작 `none`)은 매칭 즉시 **차단**. 즉 Count = "감시·기록", Block = "실제 차단".
- A3. **오탐 방지.** 개발 중 곧장 Block을 켜면 정상 음성 업로드 같은 트래픽이 룰에 걸려 막힐 수 있음 → 먼저 Count로 **정상 트래픽이 안 걸리는지 로그로 관찰**한 뒤 단계적 Block 전환이 정석. 그래도 의미 있는 이유: Count여도 **탐지·기록·메트릭·알림은 작동**해 공격 가시성은 확보됨(차단만 보류).
- A4. XSS·SQLi·Log4j 등 공격 시그니처는 **끊임없이 진화**함. 직접 룰을 짜면 우리가 계속 따라가며 유지보수해야 함. **AWS 관리형 룰은 AWS 보안팀이 시그니처를 자동 업데이트** → 항상 최신 방어 + 운영 부담 최소. (단일 dev 팀엔 직접 작성이 과함)

---

## 카드 3. 커스텀 Rate-based 규칙 (디도스 — 유일한 Block)

**흐름:** 정상 패턴 검사(1~4)를 다 통과한 패킷 → **마지막 5순위에서 "이 IP가 5분간 몇 번 때렸나" 호출량 검사** → 한 IP가 **5분에 2000건 초과**면 매크로/디도스로 판단 → **즉시 Block(차단)**.

**무엇:**
- `rule "DDoS-Rate-Limit-Rule"` (priority 5) — 유일하게 **`action { block {} }`** (Count 아님, 실제 차단).
- `rate_based_statement` — `limit = 2000`(5분=300초 동안 동일 IP 최대 요청), `aggregate_key_type = "IP"`(카운팅 기준 = 클라이언트 접속 IP).
- `visibility_config` — 차단된 공격 IP 샘플 수집.

**왜:**
- ① **디도스/무차별 호출 완화**: 한 IP가 비정상적으로 대량 호출(매크로·크리덴셜 스터핑·디도스)하면 백엔드(ECS·RDS)가 과부하 → 5분 2000건 상한으로 **자동 차단**.
- ② **이건 왜 Block인가**: 1~4(관리형)는 오탐 위험이 있어 Count지만, **"한 IP가 5분에 2000번"은 정상 사용자가 거의 도달 불가능한 명백한 임계치** → 오탐 위험이 낮아 처음부터 Block해도 안전. (그래서 5룰 중 유일하게 즉시 차단)
- ③ 디도스 **L7(애플리케이션 계층)** 완화를 WAF에서 담당(L3/4 볼류매트릭은 Shield Standard가 자동 — 카드4).

**어디:** CloudFront 엣지(Web ACL 5순위).

**🔔 알람 연결 (monitoring_alerts.tf — 중요):**
- `aws_cloudwatch_metric_alarm.waf_any_blocked_alarm`: 메트릭 `BlockedRequests`(namespace `AWS/WAFV2`), **threshold=0**(1건이라도 차단 시), 5분 Sum → us-east-1 SNS(`security_alerts`) → 이메일.
- **핵심 연결고리**: 규칙 1~4는 Count라 `BlockedRequests`를 안 만듦 → **차단을 만드는 건 규칙 5(rate-limit)뿐** → 이 알람은 사실상 **"rate-limit이 누굴 차단하면 즉시 알림"** 으로 작동.
- **CloudWatch인 이유**: "5분 차단 합계 > 0"은 **숫자 임계치 비교**라 CloudWatch Alarm 고유 영역(EventBridge는 이산 사건만 매칭, 숫자 누적 못 봄). 비싸서 피한 건 CloudWatch **로그 적재**($0.50/GB)이고, 이 알람은 **무료 메트릭 + 알람 $0.10/월**이라 그 비용과 무관.

**용어:**
- **Rate-based rule** = 시간창(5분 고정) 동안 IP별 요청 수를 세서 임계치 초과 시 동작.
- **aggregate_key_type = IP** = "무엇 단위로 셀 것인가"를 IP로 지정(IP별 카운트). 다른 옵션엔 헤더·쿠키 등도 있음.
- **L7 디도스** = HTTP 요청 폭주(애플리케이션 계층). vs L3/4 = 네트워크/전송 계층 볼류매트릭 공격(SYN flood 등).

**🔥 정직 포인트 (limit 값 튜닝의 트레이드오프):**
- limit=2000은 **2001번째부터** 차단 → 한 IP가 5분에 1500건(=초당 5건)이면 **통과**. 단, 초당 5건은 백엔드에 실질 부하가 아님(rate-limit은 모든 부하 차단이 아니라 **명백한 폭주만** 끊는 용도).
- **낮추면(예 500)**: 회사·학교·카페의 **NAT 공유 IP**에서 정상 사용자 합산이 임계치를 넘겨 **단체 오탐** 위험↑. → 정석은 감이 아니라 **실제 트래픽의 IP별 p99 관찰 후** 여유 두고 설정.
- **단일 IP 한계**: 수천 IP가 각각 1500건씩 나눠 때리는 **분산 디도스는 IP별 카운트로 못 막음** → 그건 **Shield(L3/4 자동) + 오토스케일링** 영역. 방어는 계층적.

**❓ 드릴 (보지 말고 말로):**
- Q1. 5대 규칙 중 **이것만 Block**이고 1~4는 Count인 이유는?
- Q2. `limit=2000`/`aggregate_key_type=IP`가 정확히 무슨 뜻인가? 5분에 2001번째 요청은?
- Q3. Rate-limit이 막는 공격을 구체적으로? 디도스를 이걸로 다 막나?

**💡 모범답안:**
- A1. 1~4(관리형)는 패턴 매칭이라 **정상 트래픽 오탐 위험**이 있어 관찰(Count) 단계가 필요. 반면 "**한 IP가 5분에 2000건 초과**"는 정상 사용자가 거의 도달 못 하는 **명백한 비정상 임계치**라 오탐 위험이 낮음 → 처음부터 Block해도 안전. 그래서 5룰 중 유일하게 즉시 차단.
- A2. `aggregate_key_type=IP` = **클라이언트 IP별로** 요청을 카운트. `limit=2000` = 직전 **5분(300초) 동안 한 IP의 누적 요청이 2000을 넘으면** 그 IP를 Block. 2001번째부터 차단되고, 5분 창에서 요청이 줄어 임계 아래로 내려가면 다시 통과.
- A3. **L7 디도스·무차별 매크로·크리덴셜 스터핑**(한 IP가 API를 대량 난타하는 패턴)을 완화. 단, 이걸로 **모든 디도스를 막진 못함** — 수많은 IP로 분산하는 대규모 디도스나 L3/4 볼류매트릭 공격은 **Shield(엣지·AWS 자동)** 영역. WAF rate-limit은 그중 **단일 IP 폭주**를 잡는 층. (방어는 계층적)

---

## 카드 4. 운영 정직 포인트 (WAF↔CloudFront 연결 / Shield / tags)

**흐름:** WAF는 만들어 놨지만(코드) → **실제로 CloudFront 배포에 붙어 있어야** 검문소가 성문에 선 것 → 이 연결은 **코드에 없고 콘솔 수동** → 발표 전 콘솔에서 연결 여부 검증 필요.

**무엇 (열린 항목·정직 포인트):**
- **WAF ↔ CloudFront 연결이 코드에 없음.** 이 파일은 WAF Web ACL을 **만들기만** 하고, CloudFront 배포에 attach하는 설정은 **콘솔/수동**. (CloudFront 배포가 팀 공용·콘솔 생성이라 우리 레이어에서 직접 연결 안 함)
- 맨 아래 `output "cloudfront_waf_acl_arn"`은 **주석처리** — 콘솔 연결 시 ARN 복사 편의용(비활성).
- `tags`가 `common_tags`(다른 파일 패턴) 아닌 **하드코딩**(`{Environment="dev", ManagedBy="terraform"}`) — 사소한 일관성 흠(심화 정리감).
- **Shield Standard**(무료·자동) 사용 중. Shield Advanced(월 $3000)는 비용 대비 효과로 **의도적 제외**(SECURITY_ASSESSMENT).

**왜 (이걸 솔직히 말하는 게 중요):**
- ① **만든 것 ≠ 적용된 것**: WAF를 코드로 정의해도 CloudFront에 attach 안 됐으면 **트래픽이 검사를 안 거침** = 검문소를 성문에 안 세운 셈. → "발표/운영 전 콘솔 연결 검증"이 반드시 필요한 항목.
- ② **공용 리소스 경계**: CloudFront가 팀 공용·콘솔 생성이라 우리 레이어 코드로 연결을 강제하면 충돌 위험 → 연결만 콘솔에 일임. (단점: IaC 밖이라 드리프트·누락 위험 → 그래서 검증이 필요)
- ③ Shield는 **계층 분담**: 볼류매트릭(L3/4) 디도스는 Shield Standard가 엣지에서 자동, L7은 WAF rate-limit. Advanced는 24/7 대응팀·비용보호를 주지만 단일 dev엔 과함.

**🛡️ Shield Standard 상세 (알아둘 것):**
- **모든 AWS 계정에 자동·무료·상시.** 설정·코드 없음(우리가 켠 게 아니라 기본 탑재). 우리가 할 일 = **없음**.
- **막는 것**: L3/L4 볼류매트릭(SYN flood·UDP reflection 등 네트워크 폭주)을 엣지(CloudFront·Route53·ALB)에서 자동 흡수. CloudFront 쓰면 자동으로 더 강하게 보호.
- **한계(솔직)**: 공격 **알림·대시보드·리포트 없음**("너 공격받았어"를 안 알려줌). 그건 Advanced 영역.
- **Advanced 제외 사유**: 월 $3000+ — 24/7 DDoS 대응팀·공격 중 비용 환급·L7 보호를 주지만 단일 dev엔 과함(Macie·Config 제외와 동일 "비용 대비 효과" 논리). 프로덕션·고가치 시 재검토.
- **포지션**: "기본 베이스라인 = Shield Standard(L3/4 자동), 그 위에 WAF로 L7 보강." 셋이 다른 층(L3/4 Shield · L7패턴 관리형4룰 · L7빈도 rate-limit)을 분담.

**어디:** CloudFront 배포(콘솔에서 Web ACL 연결 확인). Shield는 엣지 자동.

**❓ 드릴 (보지 말고 말로):**
- Q1. WAF를 코드로 다 만들었는데 왜 "콘솔에서 연결을 확인해야 한다"고 하나? (만든 것 vs 적용된 것)
- Q2. WAF↔CloudFront 연결을 **코드에 안 넣은** 이유와, 그 단점은?
- Q3. "디도스는 Shield 쓰면 되는데 WAF rate-limit이 왜 필요?" / "왜 Shield Advanced 안 쓰나?"

**💡 모범답안:**
- A1. WAF Web ACL을 **만드는 것**과 그게 **CloudFront에 붙어 트래픽을 실제 검사하는 것**은 별개. attach가 안 됐으면 트래픽이 WAF를 안 거치고 그냥 통과 = 검문소가 일을 안 함. 우리 코드는 생성만 하고 연결은 콘솔이라, **콘솔에서 CloudFront 배포에 이 Web ACL이 연결돼 있는지 반드시 확인**해야 함.
- A2. CloudFront 배포가 **팀 공용이고 콘솔로 생성**돼서, 우리 보안 레이어 코드로 연결을 강제하면 소유권 충돌·드리프트 위험이 있어 연결만 콘솔에 일임. **단점**: 연결이 IaC 밖이라 **사람이 빠뜨리거나 드리프트** 나도 코드로는 안 잡힘 → 그래서 "콘솔 검증"이 필수 절차로 남음. (정석은 CloudFront까지 같은 IaC로 묶어 attach까지 코드화)
- A3. **계층 분담**: Shield Standard(무료·자동)는 **L3/4 볼류매트릭 디도스**(네트워크 폭주)를 엣지에서 자동 완화하고, WAF rate-limit은 **L7(HTTP 요청) 단일 IP 폭주**를 잡음 → 막는 계층이 다름. **Shield Advanced**(월 $3000+)는 24/7 DDoS 대응팀·비용 보호를 주지만 **단일 dev 서비스엔 비용 대비 과함** → 의도적 제외(Macie·Config 제외와 같은 "비용 대비 효과" 논리). 프로덕션·고가치 서비스로 가면 그때 재검토.

---

## ✅ 경계(Perimeter) 카드 1~4 — 한 줄씩 복습

1. **WAF 검문소 구조** — CloudFront 엣지(us-east-1 고정) Web ACL, default_action allow(블랙리스트). 앱 도달 전 차단.
2. **관리형 4룰 + Count** — IP평판→Common→BadInputs→SQLi, AWS 자동갱신. 오탐 방지로 Count(관찰), Block 전환은 정석 절차상 보류.
3. **Rate-based 디도스** — 5분 2000건/IP 초과 시 유일하게 Block. 임계치 명확해 오탐 낮음.
4. **운영 정직 포인트** — WAF↔CloudFront 연결은 콘솔 수동(검증 필수), Shield Standard로 L3/4 분담, tags 하드코딩.

> 관통하는 한 문장: **"성문(엣지)에 검문소(WAF)를 세워, 알려진 악성은 자동갱신 룰로 거르고(관리형4) · 명백한 디도스는 즉시 막고(rate-limit) · 정상 오탐은 관찰 후 단계적 차단(Count 정석) — 단, 검문소가 성문에 실제로 섰는지는 콘솔로 확인해야 한다."**
> 다음 단계: `03_detection`(탐지 — CloudTrail·Flow Logs·GuardDuty·Analyzer·Athena) 카드로.
