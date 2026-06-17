# 🚨 SecureVoice 보안 운영 런북 (Incident Response Runbook)

> 보안 침해 사고 발생 시 당황하지 않고 순서대로 조치하기 위한 비상 대응 매뉴얼.
> 대상 인프라: SecureVoice(음성 변조 탐지) — 계정 `455535733131`, 메인 리전 `ap-northeast-2`(서울), 글로벌 `us-east-1`.

---

## 0. 사고 대응 5단계 (공통 흐름)
1. **탐지(Detect)** — 알림 수신 / 이상 인지
2. **분류(Triage)** — 실제 사고인지, 심각도 판단
3. **격리(Contain)** — 피해 확산 차단 (자격증명 정지, 네트워크 차단 등)
4. **근절·복구(Eradicate & Recover)** — 원인 제거, 정상화
5. **사후(Post-incident)** — 타임라인 기록, 재발 방지, 런북 업데이트

> 원칙: **증거 보존 우선**(섣불리 리소스 삭제 금지) → 격리 → 복구. 모든 조치에 시각·담당자 기록.

---

## 1. 비상 연락 / 에스컬레이션
| 역할 | 담당 | 연락처 |
|------|------|--------|
| 보안 담당(1차) | (작성) | (작성) |
| 인프라/클라우드 | (작성) | (작성) |
| CI/CD 담당 | (작성) | (작성) |
| 의사결정자 | (작성) | (작성) |

- 보안 알림 수신 메일: `var.security_alert_email`(variables.tf)
- AWS 지원: Support 콘솔 (키 lockout 등 복구 불가 상황 시)

---

## 2. 우리가 구축한 탐지 체계 (알림이 오면 무슨 의미인지)
| 알림 출처 | 내용 | 전달 경로 |
|-----------|------|-----------|
| **GuardDuty** | 미지·행동 기반 위협(악성 IP, 크립토마이닝, 자격증명 이상 등), severity≥4 | EventBridge → SNS(서울/us-east-1) → 이메일 |
| **EventBridge: root-account-usage** | 루트 계정 로그인/API 사용 | SNS(us-east-1) → 이메일 |
| **EventBridge: iam-sensitive-changes** | IAM 유저/키/정책 생성·부착 | SNS(us-east-1) → 이메일 |
| **EventBridge: sg-rule-changes** | 보안그룹 규칙 추가(방화벽 개방) | SNS(서울) → 이메일 |
| **EventBridge: cloudtrail-tampering** | CloudTrail 중지/삭제/수정 | SNS(서울) → 이메일 |
| **WAF 알람** | WAF 5대 룰 차단 발생 | CloudWatch 알람 → SNS(us-east-1) → 이메일 |

조사용 로그 위치:
- **CloudTrail**(API 행동): S3 `securevoice-dev-cloudtrail-logs-455535733131` → Athena 조회
- **VPC Flow Logs**(네트워크): S3 `securevoice-dev-vpc-flow-logs-455535733131` (parquet) → Athena 조회
- **GuardDuty findings**: 콘솔 → GuardDuty → Findings

---

## 3. 사고 유형별 대응 절차 (Playbooks)

### A. 루트 계정 비정상 사용 / 자격증명(IAM) 유출
**탐지 신호:** `root-account-usage` 또는 `iam-sensitive-changes` 알림, GuardDuty `UnauthorizedAccess`/`CredentialAccess` finding.
1. **격리**
   - 의심 IAM 사용자 액세스 키 즉시 비활성화: `aws iam update-access-key --access-key-id <ID> --status Inactive --user-name <USER>`
   - 의심 역할 세션 무효화: 역할에 `AWSRevokeOlderSessions` 인라인 정책 부착(특정 시각 이전 세션 거부).
   - 루트 유출 의심 시: 루트 비밀번호 변경 + 루트 액세스 키 삭제 + MFA 재설정.
2. **조사** (Athena, 섹션 4): 해당 주체가 호출한 API 전체, 소스 IP, 시각.
3. **근절·복구**: 무단 생성된 IAM 사용자/키/정책 제거, 영향 리소스 점검.
4. **사후**: 키 로테이션 정책 점검, MFA 강제, 최소권한 재검토.

### B. GuardDuty 고위험(High) finding
**탐지 신호:** GuardDuty finding severity 7~8.9 알림.
1. 콘솔 → GuardDuty → Findings에서 유형/대상 리소스/소스 IP 확인.
2. **격리**: 침해 의심 EC2/ECS 태스크 격리(전용 격리 SG로 교체), 관련 자격증명 정지.
3. **조사**: 해당 리소스의 CloudTrail/Flow Logs 상관분석.
4. **복구**: 인스턴스/태스크 교체(재배포), 침해 자격증명 폐기.

### C. CloudTrail 변조 (감사 로그 끄기/삭제)
**탐지 신호:** `cloudtrail-tampering` 알림 (`StopLogging`/`DeleteTrail`/`UpdateTrail`).
> ⚠️ 공격자가 흔적을 지우려는 신호일 수 있음 — **최우선 대응**.
1. **즉시 로깅 재개**: `aws cloudtrail start-logging --name securevoice-dev-trail`
2. 누가 중지했는지 확인(Athena: `eventName='StopLogging'`), 해당 주체 격리(플레이북 A).
3. S3 버킷의 로그 무결성(log file validation) 검증.
4. **복구**: Terraform `terraform apply`로 트레일 설정 원복(코드가 정답).

### D. 보안그룹 무단 개방 (0.0.0.0/0)
**탐지 신호:** `sg-rule-changes` 알림.
1. 변경된 SG/규칙 확인 → 무단이면 **즉시 해당 인바운드 규칙 삭제**: `aws ec2 revoke-security-group-ingress ...`
2. 누가 변경했는지 조사(플레이북 A) → 자격증명 점검.
3. **복구**: Terraform로 SG 원복. ALB는 CloudFront Prefix List만 허용해야 함(security_groups.tf 기준).

### E. DDoS / 비정상 트래픽 폭증
**탐지 신호:** WAF 알람(BlockedRequests 급증), ALB 5xx 증가.
1. WAF(us-east-1) → Web ACL `securevoice-dev-waf` → Sampled requests로 공격 패턴/IP 확인.
2. Rate-based 룰(현재 2000/5분, Block)이 동작 중인지 확인. 필요 시 임계치 하향.
3. 특정 IP/국가 집중 시 WAF에 IP set / geo 차단 룰 추가.
4. Shield Standard가 L3/L4 자동 방어. (Advanced는 미사용)
5. **복구**: 트래픽 정상화 확인, 룰 튜닝 내역 기록.

### F. S3 데이터 노출 의심 (음성=생체정보)
**탐지 신호:** 퍼블릭 액세스 경고, 비정상 대량 GetObject, GuardDuty S3 finding.
1. 해당 버킷 퍼블릭 액세스 차단 상태 확인(4개 옵션 ON이어야 함, s3_security.tf).
2. 버킷 정책/ACL 점검 — 무단 허용 즉시 제거.
3. Athena로 GetObject 호출자/IP/객체 조사.
4. 유출 확정 시: 영향 객체 식별, 관련 자격증명 폐기, (생체정보이므로) **개인정보 침해 신고 절차** 검토.

### G. KMS 마스터 키 오용/손상 의심
**탐지 신호:** 비정상 `Decrypt`/`GenerateDataKey` 급증, 키 정책/상태 변경 알림.
1. CloudTrail에서 키 사용 주체 조사(Athena: `eventSource='kms.amazonaws.com'`).
2. 무단 주체면 해당 자격증명 격리. **키 비활성화는 신중히**(S3/ECS 복호화 중단 → 서비스 영향).
3. 키 정책 무단 변경 시 Terraform로 원복(kms_security.tf, 옵션 A 정책).
4. > ⚠️ 키 삭제/비활성화는 데이터 복호화 불가로 이어짐. 30일 삭제 대기(deletion_window) 내 복구 가능.

---

## 4. 유용한 조사 쿼리 / 명령어

### Athena — CloudTrail (특정 IP의 행동 추적)
```sql
SELECT eventtime, eventsource, eventname, sourceipaddress,
       useridentity.username AS user_name, errorcode
FROM cloudtrail_logs
WHERE sourceipaddress = '<의심 IP>'
ORDER BY eventtime DESC
LIMIT 50;
```

### Athena — 권한 거부(AccessDenied) 다발 주체 (침투 시도 징후)
```sql
SELECT useridentity.arn, sourceipaddress, eventname, count(*) AS cnt
FROM cloudtrail_logs
WHERE errorcode = 'AccessDenied'
GROUP BY 1,2,3 ORDER BY cnt DESC LIMIT 50;
```

### Athena — 리소스 삭제 추적
```sql
SELECT eventtime, useridentity.arn, eventname, sourceipaddress
FROM cloudtrail_logs
WHERE eventname LIKE 'Delete%'
ORDER BY eventtime DESC LIMIT 50;
```

### 긴급 격리 명령어 (CLI)
```bash
# 액세스 키 비활성화
aws iam update-access-key --access-key-id <ID> --status Inactive --user-name <USER>
# CloudTrail 로깅 재개
aws cloudtrail start-logging --name securevoice-dev-trail
# 보안그룹 무단 인바운드 제거
aws ec2 revoke-security-group-ingress --group-id <SG_ID> --protocol tcp --port <P> --cidr 0.0.0.0/0
```

---

## 5. 핵심 리소스 인벤토리 (빠른 참조)
| 항목 | 식별자 |
|------|--------|
| KMS 마스터 키 | `alias/securevoice-dev-master-key` (`...key/5b711458-...`) |
| CloudTrail | `securevoice-dev-trail` (멀티리전, 로그검증 ON) |
| CloudTrail 로그 버킷 | `securevoice-dev-cloudtrail-logs-455535733131` |
| Flow Logs 버킷 | `securevoice-dev-vpc-flow-logs-455535733131` |
| WAF Web ACL | `securevoice-dev-waf` (us-east-1, CLOUDFRONT) |
| GuardDuty | 서울 + us-east-1 디텍터 (S3 보호 ON) |
| SNS(서울) | `securevoice-dev-security-alerts-seoul` |
| SNS(us-east-1) | `securevoice-dev-security-alerts-topic` |
| 민감 데이터 버킷 | audio(음성/생체), model(AI 모델) — SSE-KMS |

---

## 6. 정기 점검 체크리스트 (월간 권장)
- [ ] GuardDuty findings 리뷰 (미처리 건 없는지)
- [ ] CloudTrail 로깅 정상 여부 (`is_logging = true`)
- [ ] S3 4개 버킷 퍼블릭 액세스 차단 유지
- [ ] IAM 미사용 자격증명/오래된 액세스 키 정리, MFA 점검
- [ ] WAF 차단 로그 추세 확인, Count→Block 전환 검토
- [ ] KMS 키 정책/로테이션 상태 확인
- [ ] SNS 구독 이메일 유효성(담당자 변경 반영)
- [ ] 보안 알림 실제 수신 테스트 (테스트 SG 변경 등)

---

> 본 런북은 인프라 변경 시 함께 갱신한다. 진행상황은 `SECURITY_PROGRESS.md`, 개념 정리는 `SECURITY_QNA.md` 참조.