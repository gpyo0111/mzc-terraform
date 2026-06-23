# 05. ALERTING (알림) — monitoring_alerts / security_event_alerts

> 🎤 발표 위치: 탐지(04)와 대응(06) 사이의 "통지". 위험 행동을 사람에게 즉시 알린다.
> 큰 그림: 위험행동 → EventBridge(특정 행동 포착) → SNS → 이메일. **알림 규칙은 대응(06) Lambda와 트리거를 공유**(타깃만 추가).

---

## monitoring_alerts.tf — SNS 방송국 + WAF 통합경보

**무엇을 만드나**
- **SNS 토픽 `security_alerts`** (us-east-1) + 이메일 구독(`var.security_alert_email`) — 모든 us-east-1 알림의 허브. (서울 토픽 `security_alerts_seoul`은 guardduty_security.tf).
- **WAF 통합 경보** `waf_any_blocked_alarm`: `AWS/WAFV2 BlockedRequests` 합계 > 0(5분)이면 → SNS. WebACL=`securevoice-dev-waf`, Region=us-east-1(CloudFront 글로벌 메트릭).

**왜**
- 규칙별로 경보를 따로 안 만들고 **Web ACL 전체 차단합계 1개 메트릭**으로 통합 → 규칙 추가돼도 경보 수정 불필요(리팩토링).
- CloudFront WAF 메트릭은 us-east-1 고정 수집.

**🎤 / ❓**: "WAF가 다 Count인데 경보 의미 있나?" → rate-limit(규칙5)은 Block이라 디도스 차단 시 발화. Count→Block 전환하면 나머지도 자동 포착.

---

## security_event_alerts.tf — 고위험 정책 이벤트 4종 → SNS

**무엇을 만드나** (EventBridge 규칙 4 + 타깃 4)

| # | 이벤트 | 리전 | 토픽 | 왜 위험 |
|---|---|---|---|---|
| 1 | 루트 계정 사용(Console SignIn/API, `userIdentity.type=Root`) | us-east-1 | security_alerts | 루트는 평소 미사용이 정상 → 사용=고신호 |
| 2 | IAM 민감변경(CreateUser/AccessKey/LoginProfile/Attach*Policy/Put*Policy/DeactivateMFA) | us-east-1 | security_alerts | 권한탈취·백도어 징후 |
| 3 | SG 규칙변경(Authorize Ingress/Egress, **ModifySecurityGroupRules**) | 서울 | security_alerts_seoul | 방화벽 구멍 |
| 4 | CloudTrail 변조(StopLogging/DeleteTrail/UpdateTrail/PutEventSelectors) | 서울 | security_alerts_seoul | 감사로그 끄기=은폐 |

**왜**
- GuardDuty(미지/행동 기반)와 **별개로**, "발생 즉시 사람이 알아야 할 명백한 정책 행동"을 CloudTrail 이벤트에서 직접 매칭.
- **저비용:** CloudTrail 관리이벤트가 EventBridge 기본 버스로 자동 전달 → CloudWatch Logs 수집비 0.
- 배치: 글로벌(루트/IAM)은 us-east-1, 리전자원(SG/CloudTrail)은 서울.

**어떻게 작동**: SNS 토픽은 guardduty 파일에서 만든 것 재사용(두 토픽 모두 events 발행 허용 정책 보유). 규칙 3·4는 06 Lambda의 트리거로도 재사용됨.

**🎤 / ❓**: SG 0.0.0.0/0 값까지 패턴 정밀매칭은 까다로워 "SG 변경 행위 자체"를 알림 → 사람 검토(현업 안전 기본값). 정밀 회수는 06 Lambda가 SG 재조회로 처리.

---

## ✅ 05단계 한 줄 요약
> **WAF 통합경보 + 고위험 정책이벤트 4종(루트/IAM/SG/CloudTrail)을 EventBridge→SNS 이메일로 즉시 통지. 관리이벤트 기본버스 자동전달로 저비용, 규칙 3·4는 대응 Lambda와 트리거 공유.**
