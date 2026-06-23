# 03. PERIMETER (경계) — waf.tf

> 🎤 발표 위치: **뼈대(아키텍처 경로를 보안 렌즈로 다시 걷기)**의 "성문 검문소". 예방(02)을 통과한 트래픽이 앱에 닿기 **전** 엣지에서 거른다.
> 큰 그림: `사용자 → CloudFront(엣지) → 🛡️WAF(검문소) → ALB → ECS`. 칼이 몸에 닿기 전에 성문에서 잡는다.

---

## waf.tf — CloudFront 엣지 WAFv2 (검문소)

**무엇을 만드나**
- **us-east-1 프로바이더 alias** (`provider "aws" { alias = "us_east_1" }`) — 이 파일이 출발점. CloudFront용 WAF는 us-east-1 고정이라 별도 리전 통로 필요. GuardDuty·SNS 등 다른 글로벌 리소스도 이 alias 공유.
- `aws_wafv2_web_acl.main` (`scope = CLOUDFRONT`, `default_action = allow`) + 규칙 5개 + 전역 `visibility_config`(CloudWatch 통계).

**5대 규칙 (priority 순)**

| 순위 | 규칙 | 막는 것 | 모드 |
|---|---|---|---|
| 1 | AWS Managed **IP Reputation List** | AWS가 아는 악성 IP "전과자" 즉시 필터 | 👀 Count |
| 2 | AWS Managed **Common Rule Set** | OWASP Top10(XSS 등) 흔한 웹 공격 | 👀 Count |
| 3 | AWS Managed **Known Bad Inputs** | Log4j 등 알려진 RCE(원격코드실행) 패턴 | 👀 Count |
| 4 | AWS Managed **SQLi Rule Set** | DB 탈취 SQL 인젝션 | 👀 Count |
| 5 | **Custom Rate-based** (디도스) | 한 IP 5분 2000건 초과 = 매크로/디도스 | 🚫 **Block** |

**왜**
- 엣지(CloudFront)에서 거르면 **앱(ECS)이 받기 전에** 차단 → 백엔드 부하·장애·비용 방어.
- 관리형 룰 = AWS가 시그니처 자동 업데이트(우리가 관리 안 함). Rate-limit = 디도스/무차별 호출 완화.

**어떻게 작동**
- `default_action allow` + 각 규칙이 매칭 트래픽 처리. Count는 기록만/통과, Block은 차단.
- Rate-based: `aggregate_key_type=IP`로 IP별 카운트, `limit=2000`/5분.

**⚠️ 핵심 정직 포인트 (발표 차별화)**
- **규칙 1~4는 Count(감시만), 실제 Block은 규칙 5(디도스)뿐.** `override_action { count {} }` = 잡아도 통과시키고 기록만.
- 사유: **오탐 방지.** 개발 단계에서 무지성 Block 켜면 정상 음성 업로드까지 막혀 서비스 장애. 정석은 **로그로 정상 트래픽 무피해 확인 후 단계적 Block 전환**.
- 이 전환(#6)은 **프로젝트 기간상 보류 → 발표 시 구두 설명**. ("WAF 튜닝의 정석대로 Count로 관찰 단계를 뒀다" = 운영 감각 어필. 차단 안 해도 탐지·기록은 되어 공격 가시성은 확보)

**⚠️ 확인 필요 (열린 항목)**
- **WAF ↔ CloudFront 연결이 코드에 없음** — 이 파일은 WAF를 만들기만 하고 CloudFront 배포 attach는 **콘솔/수동**(CloudFront가 팀 공용·콘솔 생성). → 발표 전 **콘솔에서 WAF가 CloudFront에 실제 연결돼 있는지 확인 필수.** 안 붙어있으면 검문소를 성문에 안 세운 셈.
- 맨 아래 `output "cloudfront_waf_acl_arn"`은 주석처리(콘솔 연결용 ARN 복사 편의, 비활성).
- `tags`가 `common_tags` 아닌 하드코딩(`{Environment, ManagedBy}`) — 사소한 일관성 흠(심화 정리감).

**비용/오버헤드**
- Web ACL 월 ~$5 + 관리형 룰그룹당 월비용 + 요청 100만건당 소액. 디도스 대량유입 시 오히려 백엔드 비용/장애 방어로 상쇄.

**🎤 / ❓예상 질문**
- Q: "WAF 왜 서울 아닌 미국?" → CloudFront(글로벌)용 WAF는 us-east-1 고정. ALB용이면 서울 `REGIONAL`.
- Q: "다 Count면 방어 되나?" → 디도스(규칙5)는 실제 Block. 나머지는 관찰 후 전환 예정 + 탐지·기록은 됨.
- Q: "Shield는?" → Shield Standard(무료·자동) 사용 중. Advanced는 비용 대비 효과로 의도적 제외(SECURITY_ASSESSMENT).
- Q: "Managed Prefix List로 ALB 우회 차단은?" → 그건 `security_groups.tf`(02 문서). WAF(엣지 검사) + Prefix List(ALB를 CloudFront에서만 443) = 우회 이중 차단.

---

## ✅ 03단계 한 줄 요약
> **CloudFront 엣지에 WAFv2 5룰(관리형 4 + 커스텀 rate-limit) 검문소를 세워 앱 도달 전 차단. 디도스만 Block, 관리형 4룰은 오탐 관찰 위해 Count(정석 튜닝 절차) → 발표 시 구두 설명.**
> 확인감: WAF↔CloudFront 콘솔 연결 검증, tags 일관성.
