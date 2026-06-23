# 06. RESPONSE (자동대응 / Self-Healing) — lambda_auto_remediation / cloudtrail_auto_recovery

> 🎤 발표 위치: **클라이맥스 "뚫려도 스스로 치료한다"**. 탐지→알림에서 멈추지 않고 사람 없이 자동 회수/복구.
> 큰 그림: 위험행동 → (05와 같은)EventBridge 규칙 → **타깃 2개**(SNS 알림 + Lambda 자동조치). 룰/요금 중복 없음.

---

## lambda_auto_remediation.tf + lambda/sg_auto_remediate/index.py — SG 0.0.0.0/0 자동회수

**무엇을 만드나**
- archive_file(zip) + IAM role/policy(최소권한) + 로그그룹(30일) + Lambda(python3.12) + **기존 `sg_rule_changes` 규칙에 Lambda 타깃 추가** + lambda_permission.
- 토글 변수 `sg_auto_revoke_enabled`(기본 false=드라이런).

**동작(index.py)**
- 이벤트 `groupId`로 SG **현재 상태 재조회** → "지금 실제로 열린" 위험 규칙만 처리(이벤트 파싱 의존 최소화 = 견고).
- 대상: **RISKY_PORTS**(22/23/21/3389/3306/5432/1433/6379/11211/27017/9200) 또는 전체(-1)가 **`0.0.0.0/0`·`::/0`**로 열린 인바운드만.
- 회수 시 **문제 규칙의 열린 CIDR만** 골라 revoke(SG·다른 규칙 보존). 인바운드만, egress 이벤트는 skip.
- **사각지대 커버:** `ModifySecurityGroupRules`(콘솔 규칙 편집으로 0.0.0.0/0 변경)까지 `HANDLED_EVENTS`에 포함 → Authorize만으론 못 잡던 구멍 메움. `_extract_group_id()`가 Modify 이벤트 groupId(대소문자 변형까지) 추출.

**3중 안전장치**: ⓐ 위험포트+전세계개방만 ⓑ AUTO_REVOKE=false 드라이런(현재 알림만) ⓒ SG 태그 `AutoRemediate=false`면 skip(의도적 개방 예외).

**최소권한 IAM**: logs(전용 로그그룹), `ec2:DescribeSecurityGroups`(`*` — Describe는 리소스제한 미지원, AWS 제약), `ec2:RevokeSecurityGroupIngress`(이 계정/서울 SG로 한정), `sns:Publish`(서울 토픽 1개).

---

## cloudtrail_auto_recovery.tf + lambda/cloudtrail_auto_recover/index.py — CloudTrail 자동복구

**무엇을 만드나**
- 동일 패턴(zip+IAM+로그그룹+Lambda) + **기존 `cloudtrail_tampering` 규칙에 Lambda 타깃 추가** + lambda_permission.
- 토글 `cloudtrail_auto_recover_enabled`(기본 false=드라이런).
- 재생성용 원래 설정값을 **Terraform이 `aws_cloudtrail.main` 실제 속성에서 env로 주입**(TRAIL_NAME/S3_BUCKET/멀티리전/글로벌/무결성/DATA_RESOURCE_ARN) → 코드/실물 항상 일치.

**동작(index.py)**
- `StopLogging` → `start_logging` 즉시 재가동.
- `DeleteTrail` → **원설정대로 `create_trail` 재생성** + audio `uploads/` 데이터이벤트 `put_event_selectors` 재적용 + `start_logging`(CreateTrail은 정지상태로 생성되므로 별도 시작).
- `_is_our_trail()`로 우리 트레일(이름/ARN)만 처리.

**안전장치**: ⓐ StopLogging/DeleteTrail만 복구. **UpdateTrail/PutEventSelectors는 복구 안 함**(정상 Terraform 변경과 충돌 방지 → 알림만 유지). ⓑ AUTO_RECOVER=false 드라이런. ⓒ 우리 트레일만.

**최소권한 IAM**: logs, cloudtrail Start/Create/PutEventSelectors(우리 트레일 ARN 한정), sns:Publish(서울 토픽 1개).

---

## ⚠️ 현재 상태 (데모 핵심)
- 두 Lambda 모두 **드라이런(알림만)으로 apply 완료**(2026-06-22). 데모 시 `-var sg_auto_revoke_enabled=true` / `-var cloudtrail_auto_recover_enabled=true`로 켜서 **실제 자동회수·자동복구 시연** 예정.
- 신규 EventBridge 규칙/SNS 구독 없음(기존 재사용) → 추가 Confirm 불필요. archive 프로바이더 공유(추가 init 불필요).

## 🎤 / ❓ 예상 질문
- Q: "자동대응이 정상 변경을 막으면?" → 드라이런으로 오탐 0 확인 후 활성화 + 예외태그 + 위험조건 협소화(위험포트+전세계개방만).
- Q: "왜 알림과 Lambda가 한 규칙?" → 룰/요금 중복 제거, 탐지-알림-대응 일원화.
- Q: "왜 SG 재조회?" → 이벤트 페이로드 형식에 의존하지 않고 '지금 실제 열린' 규칙만 정확히 처리.
- Q: "DeleteTrail 후 데이터이벤트는?" → env로 ARN 주입받아 재생성 시 put_event_selectors로 원복.

---

## ✅ 06단계 한 줄 요약
> **SG 위험개방·CloudTrail 변조를 (알림과 같은 트리거로) Lambda가 자동 회수/복구. 드라이런 토글·예외태그·위험조건 협소화·최소권한·SG 재조회로 안전 설계. 현재 드라이런 배포 → 데모 시 활성화.**
