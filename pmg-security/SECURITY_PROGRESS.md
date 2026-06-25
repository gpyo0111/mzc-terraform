# 🔐 SecureVoice 보안 작업 진행상황 (pmg-security)

> 이 파일은 Claude와 사용자가 보안 작업을 이어서 진행하기 위한 **진행상황 추적 문서**입니다.
> 새 대화를 시작하면 Claude가 이 파일을 먼저 읽고 마지막 지점부터 이어갑니다.

## 0. 기본 전제 (Ground Rules)

- **작업 범위:** `mzc-terraform/pmg-security` 폴더 **안에서만** 코드 작성/수정. 다른 레이어 리소스는 `data` / `terraform_remote_state`로 읽기만.
- **배포 상태:** pmg-security는 **이미 AWS에 apply 완료(운영 중)**. → 모든 변경은 **무중단**을 전제로, apply 시 기존 리소스 영향도를 반드시 확인.
- **설명 방식:** 초등학생 눈높이 비유 + 보안 이점 + 운영 오버헤드(비용/관리) + apply 위험 함께 설명.
- **추가 범위:** Trivy CI/CD(GitHub Actions)까지 포함. 보안 런북 .md 문서까지 포함.
- **계정/리전:** account `455535733131`, 메인 `ap-northeast-2`(서울), 글로벌(WAF/CloudFront/SNS) `us-east-1` alias.
- **작업 환경:** 사용자는 **WSL**에서 작업. `terraform` 명령은 WSL bash에서 실행(Windows PowerShell/Git Bash에는 terraform 미설치). terraform v1.14.9 확인됨(2026-06-19).
  - ⚠️ **작업 위치(드라이브)가 장소마다 다름:** 학원=`D:\aws-project`(=`/mnt/d/aws-project/...`), 집=`C:\...`(=`/mnt/c/...`). **사용자가 세션 시작 시 어디서 작업하는지 알려주면 그 경로에 맞춰 진행.** 경로 하드코딩 금지.
  - validate 예(D 기준): `wsl -e bash -lc "cd /mnt/d/aws-project/mzc-terraform/pmg-security && terraform validate"`.
  - ※ archive 프로바이더 추가됨 → 새 환경에선 `terraform init` 1회 필요.

---

## 1. 전체 상태 요약 (체크리스트 대조)

범례: ✅ 완료 · 🟡 부분/주의 · ❌ 미완료 · ⏸️ 보류(결정필요) · 👥 팀 폴더에서 완료(범위 밖)

### 섹션 1. 자격증명 / 감사 로그
| 항목 | 상태 | 비고 |
|------|------|------|
| S3 수명주기(Lifecycle) | ✅ | 등급별 guest 7d / free 90d(30d Glacier) / paid 365d(30d Glacier) |
| CloudWatch 로그 30일 만료 | 🟡 | VPC flow log만 30일. 다른 로그그룹은 팀 폴더(20-runtime 14일) |
| Secrets Manager 격리 | 👥 | 10-persistent |
| ECS valueFrom 주입 | 👥 | 20-runtime |
| CloudTrail 멀티리전+무결성 | ✅ | monitoring_security.tf |
| CloudTrail→CloudWatch 스트리밍 | ⏸️ | 비용/필요성 설명 후 결정 |
| VPC Flow Logs | ✅ | CloudWatch行. Athena 쓰려면 S3行 추가 필요 |

### 섹션 2. 암호화 / 네트워크 격리
| 항목 | 상태 | 비고 |
|------|------|------|
| KMS CMK + 키순환 | ✅ | kms_security.tf |
| **KMS Key Policy 최소권한** | ❌ | 키 정책 없음 = 기본(루트 전체허용). **운영중 변경 시 고위험** |
| S3 SSE-KMS 강제 | ✅ | audio/model |
| Gateway/Interface 엔드포인트 | 👥 | 10-persistent / 20-runtime |
| 엔드포인트 아웃바운드 통제 | ✅ | VPCE SG inbound 10.0.0.0/22:443 |
| S3 퍼블릭 차단 | ✅ | 5개 버킷 |
| 보안그룹 체이닝 | ✅ | ECS→RDS, CloudFront PrefixList→ALB |

### 섹션 3. 접근통제 / DevSecOps
| 항목 | 상태 | 비고 |
|------|------|------|
| Execution/Task Role 분리 | 👥 | 20-runtime |
| IAM 와일드카드 제거 | 🟡 | S3는 타이트. flow-logs 정책에 `Resource="*"` 남음 |
| Trivy 스캐너 (CI/CD) | ❌ | GitHub Actions, Terraform 밖 |
| Trivy 크리티컬 차단+Slack | ❌ | |

### 섹션 4. 경계 보안 / 모니터링
| 항목 | 상태 | 비고 |
|------|------|------|
| WAFv2 (5룰) | ✅ | waf.tf. CloudFront 연결은 콘솔/수동 (확인 필요) |
| Managed Prefix List ALB우회차단 | ✅ | |
| Rate-based Rule (디도스) | ✅ | 2000/5분 Block |
| WAF Count 모드 | ✅ | 룰1~4 Count, 룰5만 Block → 나중에 Block 전환 튜닝 |
| GuardDuty | ⏸️ | 코드 존재. 비용/필요성 설명 후 결정. Slack연동 미완 |
| CloudWatch Logs Insights 보안쿼리 | ❌ | aws_cloudwatch_query_definition 없음 |
| 보안 런북(.md) | ❌ | |

---

## 2. 남은 작업 백로그 (진행 순서)

> **의존성 + 위험도 + 확정된 결정**을 반영해 갱신(2026-06-16). 각 항목 진행 시 상세 설명 + apply 위험 안내.

| # | 작업 | 위험도 | 상태 |
|---|------|--------|------|
| 1 | 코드 정리: `output "test"` 제거, 알림 이메일 변수화 | 낮음 | ✅ 완료 |
| 2 | CloudTrail→CloudWatch 풀스트리밍 → **생략 확정** (검색=Athena, 알람=EventBridge로 대체) | — | ❌ 취소 |
| 3 | VPC Flow Logs → S3 전환(+Athena), 기존 CloudWatch log group/IAM role 제거 | 중 | ✅ 완료 |
| 4 | GuardDuty 유지(평가판 지속) + `datasources` 최신화 + EventBridge로 finding→SNS 알림 | 낮음~중 | ✅ 완료 |
| 5 | EventBridge 정책 이벤트 룰(root 로그인 / SG 0.0.0.0/0 개방 / CloudTrail 중지 등) → SNS | 낮음 | ✅ 완료 |
| 6 | WAF Count→Block 전환 튜닝 (로그 관찰 후) | 중 | ⏸️ 보류 (프로젝트 기간상 미실시, 발표 시 구두 설명) |
| 7 | KMS Key Policy 최소권한 적용 (옵션 A: 안전한 명시적 정책) | **높음** | ✅ 완료 |
| 8 | Trivy CI/CD (GitHub Actions) + 크리티컬 차단 + Slack | — | ❌ 범위 외 (프로젝트 CI/CD 담당자가 진행) |
| 9 | 보안 운영 런북 .md 작성 (최종 상태 문서화) | 없음 | ✅ 완료 (SECURITY_RUNBOOK.md) |

### 확정된 결정 / 변경 (2026-06-16)
- ✅ **GuardDuty 유지**: 현재 평가판(무료) 사용 중, 종료 후에도 이어서 사용하기로 결정. (광범위·미지 위협 탐지의 핵심)
- ✅ **Shield**: Shield Standard(무료·자동)만 사용 — 추가 비용 없음. 별도 작업 불필요.
- ❌ **CloudTrail→CloudWatch 풀스트리밍 생략**: 이미 Athena(S3)로 CloudTrail 검색 중이라 풀스트리밍은 비용 낭비. 실시간 알람은 EventBridge로 대체.
- 🔄 **VPC Flow Logs → S3 전환**: 비용 절감 + Athena 통일. GuardDuty는 flow log를 자체적으로 읽으므로 CloudWatch 제거해도 탐지 영향 없음.
- ⛔ **구 항목 자동 해소**: IAM 와일드카드 제거(구 항목)는 flow-logs용 IAM role을 삭제하면서 자동 해결됨. Logs Insights(구 항목)는 로그가 S3로 이동하므로 Athena로 대체(별도 작업 불필요).

---

## 3. 작업 로그 (완료 기록)

> 작업을 끝낼 때마다 여기에 "무엇을/왜/어떻게" 한 줄씩 추가.

- **[#1 완료]** 코드 정리 (저위험, terraform validate 통과)
  - `output "test"` 제거 + 고아 `data.aws_lb.target_alb` 제거 (outputs.tf, variables.tf) — 디버깅 잔재 + 매 plan마다 불필요 API 호출 제거
  - 보안 경보 이메일 하드코딩 → `var.security_alert_email` 변수화 (variables.tf, monitoring_alerts.tf), 기본값은 기존 이메일 유지 → apply 시 변화 없음
  - ※ GuardDuty `datasources` deprecated 정리는 #4(유지/제거 결정)와 묶여서 그때 처리하기로 이동
- **[#3 완료]** VPC Flow Logs CloudWatch → S3 전환 (monitoring_security.tf, terraform validate 통과)
  - flow log 전용 버킷 `securevoice-dev-vpc-flow-logs-455535733131` 신설(+퍼블릭 차단, +30일 수명주기, +delivery.logs.amazonaws.com 쓰기 정책)
  - `aws_flow_log.main`을 S3 대상으로 변경 + parquet/Hive/시간파티션(Athena 비용 최적화)
  - CloudWatch `aws_cloudwatch_log_group.vpc_flow_logs`, `aws_iam_role.vpc_flow_logs`, `aws_iam_role_policy.vpc_flow_logs` 삭제 → 이 과정에서 flow-logs IAM 정책의 `Resource="*"` 와일드카드도 자동 제거됨
  - CloudTrail 버킷에도 30일 수명주기 추가(요청사항: flow/cloudtrail 모두 30일)
  - **apply 시 주의:** `aws_flow_log`는 교체(destroy→create)되어 flow log 수집이 수십 초~1분 끊김(서비스 트래픽 영향 없음). 기존 CloudWatch flow log 데이터는 삭제됨.
  - **[apply 확인됨]** 사용자가 정상 apply 확인 완료.
- **[#4 완료]** GuardDuty 최신화 + finding 알림 배선 (guardduty_security.tf, terraform validate 통과)
  - `datasources { s3_logs }`(deprecated) → `aws_guardduty_detector_feature`(S3_DATA_EVENTS) 분리 (서울+us-east-1 둘 다), 태그 `common_tags`로 정리
  - **서울**: 신규 SNS 토픽 `security-alerts-seoul` + 이메일 구독 + EventBridge 규칙(GuardDuty Finding, severity>=4) → SNS
  - **us-east-1**: 기존 WAF용 SNS 토픽 재사용 + 토픽 정책(기본 statement 보존 + EventBridge 발행 허용) + EventBridge 규칙 → SNS
  - 두 리전 모두 Medium 이상 finding을 이메일 알림. WAF 알람은 기본 statement 보존으로 정상 유지.
  - **apply 시 주의:** ① 서울 SNS 신규 구독 → AWS 확인 메일에서 **Confirm 눌러야 알림 수신**. ② GuardDuty 디텍터는 in-place 업데이트(S3 보호는 ENABLED 유지). ③ GuardDuty S3 Protection은 비용 요인이므로 부담되면 `aws_guardduty_detector_feature` status를 DISABLED로 끌 수 있음.
  - **[apply 확인됨]** 사용자가 apply + 이메일 인증 완료.
- **[#5 완료]** EventBridge 고위험 정책 이벤트 알림 (security_event_alerts.tf, terraform validate 통과)
  - us-east-1: 루트 계정 사용 / IAM 민감 변경 → 기존 us-east-1 토픽
  - 서울: 보안그룹 규칙 변경 / CloudTrail 변조 → 서울 토픽
  - CloudTrail 관리 이벤트가 EventBridge 기본 버스로 자동 전달되는 점 활용(CloudWatch 수집비 없이 동작, 저비용)
  - apply 위험: 순수 additive(규칙4+타깃4), 서비스 영향 없음. 토픽 정책은 #4에서 이미 events 발행 허용 상태.
- **[#B 완료]** audio 버킷 `uploads/` CloudTrail Data Events (monitoring_security.tf, terraform validate 통과)
  - `aws_cloudtrail.main`에 `event_selector` 1개 추가: `include_management_events=true`(기존 관리이벤트 동작 보존) + `data_resource`(AWS::S3::Object, `audio.arn/uploads/`), `read_write_type="All"`.
  - **범위 결정(사용자):** 음성 원본(생체정보)이 담기는 `uploads/`에만 한정. 인식 결과 `results/`는 비용 절감 위해 제외(추후 prefix 한 줄로 확장 가능).
  - **apply 예상:** CloudTrail **in-place 수정 1건**(event_selector 추가), 트레일 재생성 아님. 관리이벤트는 그대로 유지되어 기존 로깅 손실 없음.
  - **apply 위험:** 순수 additive, 서비스 영향 없음. 유일한 변화는 `uploads/` 객체 Get/Put 1건당 Data Event 1건 적재(10만건당 $0.10) — prefix 한정으로 비용 통제.
  - **콘솔 확인:** CloudTrail → 추적(Trails) → securevoice-dev-trail → 데이터 이벤트 섹션에 S3 / `.../uploads/` 항목 표시. 음성 1건 업로드/다운로드 후 cloudtrail-logs 버킷에 객체 이벤트가 남는지 확인.
  - **[apply 확인됨]** 사용자가 정상 apply 확인 완료.

## 5. 앞으로의 작업 방식 메모
- apply는 사용자가 직접 수행. 각 작업마다 Claude가 **plan 예상 / apply 위험 / 콘솔 확인 방법**을 함께 제공한다.
- 진행 전략: **남은 작업 먼저 완주 → 2회차에서 전체를 다시 돌며 깊게 검토**.

## 6. ⏯️ 현재 중단 지점 (다음 세션 여기서 이어서)

> **🧊 [범위 동결 SCOPE FREEZE — 2026-06-22]** 신규 기능 추가 중단. 실무 평가상 범위는 충분(오히려 넘침). 이제부터는 **① 다듬기 ② 검증(Lambda true 데모) ③ 발표/포트폴리오 서사**에 집중. **새 Lambda/서비스 추가 금지** — 추가하고 싶으면 "이게 깊이/서사에 기여하나, 단일 dev에 과한가" 먼저 자문.
> **남은 실작업은 ALB 80 정리(팀 작업 종료 후)뿐.** ALB는 팀원이 작업용으로 80 열어둔 것 → pmg-security 코드는 CloudFront prefix(443) 규칙만 관리하면 됨. 80은 팀 종료 후 닫기/조이기(prod 전 필수).

#### 📚 [진행 중] tf 파일 학습·발표정리 (docs/ 폴더) — 내일 여기서 이어서
> **방식:** tf를 발표 흐름 5단계로 묶어, 단계별로 [같이 읽기 → 설명 → `docs/NN_*.md` 저장] 반복. 각 파일은 **무엇/왜/어떻게 작동/🎤발표위치/❓예상질문** 템플릿.
> **발표 구조(docs/00_OVERVIEW.md):** ①왜보안(생체정보) → ②익숙한 아키텍처 경로를 보안렌즈로 다시걷기(예방) → ③줌아웃: 다 감시중(탐지) → ④뚫리면 대응+🔥드리프트 실전사고+자가복구 데모 → ⑤안 한 것의 이유(판단력).

**✅ 완료한 docs:**
- `docs/00_OVERVIEW.md` — 발표 구조 + 리전분리 + tf→단계 인덱스표 + 관련문서 링크
- `docs/01_FOUNDATION.md` — provider/variables/locals/data_*/outputs (배선: 2리전, S3 state, 읽기전용 참조)
- `docs/02_PREVENTION.md` — kms/s3/security_groups/worker_sg/iam_hardening (암호화 3박자 + 접근통제). ⚠️기록해둔 정직포인트: `audio_oac_policy` 죽은설정(KMS 복호화권한 없어 CloudFront audio 서빙 불가→✅제거완료 2026-06-23), ALB 80-from-0.0.0.0/0, 워커 egress 0.0.0.0/0 넓음.
- `docs/03_PERIMETER.md` — waf.tf (CloudFront 엣지 WAFv2 5룰 + us-east-1 provider alias 출발점). ⚠️정직포인트: 규칙1~4 Count(감시만)·규칙5(디도스)만 Block→#6 전환 보류·발표 구두설명, WAF↔CloudFront 콘솔연결 검증 필요, tags 하드코딩.

**▶ 시작점 — ⓪ `audio_oac_policy` 죽은설정 제거 ✅ → 현재 `docs/03_PERIMETER.md` 진행 중:**
0. **[정리/다듬기 ✅ apply 완료 2026-06-23] `s3_security.tf`의 `aws_s3_bucket_policy.audio_oac_policy` 제거.** 사유: audio는 SSE-KMS인데 KMS 키정책에 CloudFront 복호화 권한 없음 → CloudFront audio 서빙 불가 = 죽은 설정. 음성은 API/프리사인드URL 경로라 CloudFront 직접 대상도 아님. (web_static OAC는 유효하니 유지). validate 통과 → 사용자 apply 완료(destroy 1건). 코드엔 제거 사유 주석으로 보존.
1. **03 PERIMETER**: `waf.tf` (WAFv2 5룰+rate-limit, +us-east-1 provider 정의가 여기 있음). ✅ 완료(docs/03_PERIMETER.md)
2. **04 DETECTION**: `monitoring_security.tf`(CloudTrail+Flow Logs), `guardduty_security.tf`, `access_analyzer.tf`, `athena_results.tf`. ✅ 완료(docs/04_DETECTION.md)
3. **05 ALERTING**: `monitoring_alerts.tf`, `security_event_alerts.tf`. ✅ 완료(docs/05_ALERTING.md)
4. **06 RESPONSE**: `lambda_auto_remediation.tf`, `cloudtrail_auto_recovery.tf` (+lambda python 2개). ✅ 완료(docs/06_RESPONSE.md)
> 진행 방법: 해당 단계 tf 읽고 → 채팅으로 설명 → 이해확인 → `docs/0N_*.md` 저장 → 다음 단계.

#### 🏁 docs 학습·발표정리 1바퀴 완료 (2026-06-23) — 00~06 전부 작성됨
> 다음 단계: **콘솔/코드 돌며 발표자료용 캡쳐(스크린샷) 작업.** 캡쳐 체크리스트는 `docs/CAPTURE_CHECKLIST.md` 참조.

---

### ⏯️ [2026-06-25 세션 종료] 다음 세션 여기서 이어서 ◀◀◀ 최신 중단지점

**오늘(06-25) 한 일:**
- **Athena 조사 실전 1건:** 정체불명 버킷 `amazon-sagemaker-455535733131-us-east-1-c07sezmrr3gu1z`(버지니아)를 누가 만들었나 추적.
  - CloudTrail `CreateBucket`(us-east-1) → 만든 주체 = `AmazonDataZoneEnvironmentDeployer` 서비스역할, `invokedby=datazone.amazonaws.com`.
  - 사람 추적(`datazone` `Create%` + `invokedby IS NULL`) → **본인(`user/mzc-pmg`)이 06-18 06:06 UTC 콘솔에서 `CreateDomain`**(SageMaker Unified Studio/DataZone 도메인) 클릭 → 33초 뒤 DataZone이 버킷 자동생성.
  - **우리 Terraform과 무관 확정**(`mzc-terraform` 전체 grep `sagemaker|datazone` = 0건). 콘솔 클릭으로 IaC 밖 "그림자 리소스" 생성된 실제 사례 → **사용자가 DataZone 도메인 삭제 완료**. (※ 며칠 뒤 Athena로 `DeleteBucket` 확인하면 마무리 깔끔 — 발표/면접 소재: 콘솔 드리프트를 CloudTrail+Athena로 30초 추적.)
- **공부 카드 진행 (`docs/study/01_prevention.md`):**
  - 카드 1 드릴 = 사용자가 건너뜀(말하기 미실시).
  - 카드 2(수명주기) 드릴 = 사용자 말로 답 → 채점. Q1⭕/Q2⭕(보관=보안)/Q3🔺(Glacier 인과: "못 지우니까 싼 데로→기간끝 삭제"로 교정). Glacier 단점(restore 시간/비용) 꼬리질문 남김.
  - **카드 3(KMS CMK) 신규 작성 완료** — 실제 `kms_security.tf` 반영(자동회전/30일 타임록/옵션A 키정책 2 statement/alias). 드릴4문항+모범답안 포함.
  - 카드 3 드릴 채점: Q1⭕/Q2🔺(루트 남긴 진짜 이유=lockout)/Q3⭕/Q4❌→교정(봉투암호화: `GenerateDataKey`가 곧 암호화라 `Encrypt` 불필요).
  - **심화 보강 2건 설명 완료:** ⓐ KMS lockout이 복구불가인 이유(`PutKeyPolicy`도 키정책이 통제 → 루트 제거+누락 시 닭-달걀 영구잠금. 옵션A 루트=비상 열쇠). ⓑ statement2 액션별 역할표(GenerateDataKey=쓰기/Decrypt=읽기/DescribeKey=메타조회) + 안 준 권한 비교.

**▶ 내일 시작점 (순서):**
1. **`docs/study/01_prevention.md` 카드 4 작성부터** — SSE-KMS 암호화 강제 + S3 Bucket Key. 실제 `s3_security.tf` 읽고 → 카드 작성 → 드릴 → 채점.
2. 이어서 카드 5(OAC) → 6(SG체이닝) → 7(워커 제로인바운드) → 8(IAM 하드닝). 같은 형식(카드→드릴→채점).
3. 예방 끝나면 `02_perimeter`~`05_response` 진행.
4. (공부 충분히 된 뒤) 캡쳐 = `docs/CAPTURE_CHECKLIST.md`.
> ※ 카드 1·2는 이미 작성됨. 드릴 말하기는 사용자가 원할 때. 카드 작성 = 방식②(카드→멘토질문→답→보강).

---

### ⏯️ [2026-06-24 세션 종료] (히스토리)

**📌 상황 전환:** 멘토 방문 후 피드백 = **"작업 내용을 말로 설명 못 함."** → 캡쳐보다 **"말로 설명하는 공부"가 우선**으로 결정. (캡쳐는 이해 후 자동으로 따라옴)

**오늘(06-24) 한 일:**
- `audio_oac_policy` 죽은설정 제거 → 사용자 apply 완료.
- docs 발표정리 1바퀴 마무리 + 발표/정리 자료 다수 생성:
  - `docs/CAPTURE_CHECKLIST.md` — 캡쳐 체크리스트(리전 함정 포함)
  - `MENTOR_SUMMARY.md` — 멘토용 서술 요약(아키텍처 다이어그램 포함)
  - `docs/WORK_AT_A_GLANCE.md` — 표 한눈에 보기
  - `docs/STUDY_A_ARCHITECTURE.md` — **아키텍처 공부노트(실제 다이어그램 기준)**. ※ 사용자 실제 아키텍처 확인: Route53→CloudFront→WAF, 서울 VPC 10.0.0.0/22, 2 AZ(A·C) × 3단 서브넷(Public:ALB·NAT / Private App:ECS·Admin(Jenkins·DB Access Server=베스천) / Private Data:RDS Multi-AZ), VPC 엔드포인트(S3 Gateway 무료), SQS 큐로 워커 분리.
  - **`docs/study/` 폴더 신설** — 공부노트 전용. `README.md`(방식·진행현황) + `01_prevention.md`(예방 카드 1·2 작성, 방식② 드릴+모범답안 분리). 카드 3~8은 stub. ※ 옛 `STUDY_B_SERVICES.md`는 이 폴더로 이전·삭제됨.
- 공부 방식 결정: **방식②(카드 + 말하기 드릴), 잘게 쪼개서, 한 단계씩(예방→경계→탐지→알림→대응).** 앞으로 카드는 `docs/study/` 폴더에서 진행. Notion에 사용자가 복붙 정리(=마크다운 제공). ※ Notion MCP 연결 시도했으나 `claude` CLI 미설치(VSCode 확장)로 실패 → 파일 제공 후 사용자가 옮김.
- ⚠️ **카드 1(S3 퍼블릭차단)은 방식①(읽기만)로만 했음** → 내일 카드 1 드릴(말하기)부터 다시.

**▶ 내일 시작점 (순서):**
1. **`docs/study/01_prevention.md` 카드 1 드릴부터** — 카드1·2 드릴 질문에 사용자가 **말로 답** → Claude가 피드백·보강.
2. 이어서 **카드 3~8(KMS/SSE-KMS/OAC/SG체이닝/제로인바운드/IAM)** 작성 → 방식②(카드 → 멘토 질문 → 답 → 보강).
3. 예방 끝나면 `02_perimeter`~`05_response`(경계→탐지→알림→대응) 같은 형식 진행.
4. (공부 충분히 된 뒤) 캡쳐 작업 = `docs/CAPTURE_CHECKLIST.md`.

> **업데이트(2026-06-18):** 아래 KMS #7 조사 내용은 **이미 완료(옵션 A 적용)** 되어 히스토리로 보존. 현재 실제 중단 지점은 맨 위 ★ 블록 참조.

### ⚠️ [2026-06-22 발견] SG 드리프트 (팀원 apply로 코드↔실제 어긋남) — apply 전 처리 필요
> #② Lambda apply 하려고 `terraform plan` 돌렸더니, 우리 작업과 무관한 SG 규칙 2개가 `+ create`로 잡힘(`security_groups.tf`의 SG 체이닝 규칙). 콘솔 확인 결과 **실제 AWS의 SG 내용이 코드와 달라진 진짜 드리프트**. 사용자 추정: 팀원이 잘못 apply.

**🔴 ALB SG (`sg-06de5768b9fcb7c2e`, securevoice-dev-alb-sg) — 보안 회귀(중요):**
- 코드(`aws_security_group_rule.alb_https_ingress`): 443 ← CloudFront PrefixList `pl-22a6434b` 에서만 (오리진 우회 차단 설계).
- 실제 AWS: 인바운드 1개 = `sgr-0a8a4cefd676e17a7` **HTTP 80 ← `0.0.0.0/0` (전 세계 개방)**. 443-from-CloudFront 규칙은 사라짐.
- 영향: **누구나 ALB 80번 직접 접근 가능 → CloudFront/WAF 우회.** 프로젝트 핵심 통제(WAF) 무력화.
- ※ 오늘 만든 SG Lambda는 이걸 자동회수 안 함(80은 RISKY_PORTS 제외 — 공개웹 정상케이스라). 설계 리뷰로 잡아야 하는 영역.

**🟡 VPCE SG (`sg-015b9f79b8989b38f`, securevoice-dev-runtime-vpce-sg) — 위험 아님(오히려 타이트):**
- 코드(`aws_security_group_rule.vpc_endpoint_private_ingress`): 443 ← `10.0.0.0/22`.
- 실제 AWS: 443 ← `10.0.1.0/25`(`sgr-0e074b11f1a47f51e`) + `10.0.0.128/25`(`sgr-0f0e6d2924f5bba33`) — 실제 서브넷만, 더 좁음.
- 둘 다 /22의 부분집합 → 현재가 최소권한상 더 나음. apply하면 /22가 추가돼 **다시 넓어짐**(되돌리는 셈).

**🔎 [조사 완료 2026-06-22] CloudTrail/Athena 추적 결과:**
- **ALB**: `mzc-pmg`(나)가 443←CloudFront PL 추가 → **`mzc-kjh`가 2026-06-19 09:01:48 UTC 회수(Revoke)**. 80←`0.0.0.0/0`은 원래 베이스라인. → kjh가 보안 강화 규칙을 지운 것.
- **VPCE**: `/22`는 `mzc-pmg`(나)가 2026-06-09 추가 → `mzc-kjh`가 2026-06-19 09:01:15 회수. `/25` 2개 Authorize 기록은 CloudTrail 보존창(30일) 이전 = **타 레이어가 만든 원본 베이스라인**으로 확정.
- **결론(사용자 판단):** kjh의 회수는 **실수**로 파악. ALB는 복원, VPCE는 /25에 일임.

**▶ 결정·조치 (2026-06-22, 사용자 확정):**
1. **ALB 443-from-CloudFront → apply로 복원** ✅ (코드 `alb_https_ingress` 유지 → plan에 `will be created`로 잡힘). ※ 80-from-world는 코드 밖 규칙이라 apply로 안 지워짐 → 별도 정리 대상(미해결, 출처 추적 필요).
2. **VPCE `/22` 규칙 코드에서 제거** ✅ (`security_groups.tf`의 `aws_security_group_rule.vpc_endpoint_private_ingress` 삭제, 주석으로 사유 보존). 인입 통제는 소유 레이어의 `/25`에 일임. → plan에서 /22 완전히 사라짐(refresh 시 state 자동 정리, create/destroy 0).
3. kjh 회수 = 실수로 확인 완료.
- **갱신된 plan: `13 to add, 1 to change, 0 to destroy`** (Lambda 12 + ALB 443 복원 1 = add 13 / sg_rule_changes에 ModifySecurityGroupRules = change 1). validate 통과.
- **✅ apply 완료 (2026-06-22):** ALB 443-from-CloudFront 복원됨. VPCE /22 제거됨(팀 /25 유지). Lambda 2개 드라이런 배포.
- **🟠 남은(미해결):** ALB **80-from-`0.0.0.0/0`** 출처 파악·정리. 코드 밖 규칙이라 apply로 안 지워짐. WAF 우회 위험 → 별도 정리 필요(팀에 80 의도 확인 후).

**[교훈/면접 소재]** 이번 건은 "보안 통제를 코드에 박아둬도, 공용계정에서 팀원의 apply/콘솔 변경으로 드리프트가 생긴다"는 산 증거. → ⓐ `terraform plan` 정기 점검의 가치(자동 Config 없이도 드리프트 포착), ⓑ SG 같은 공용 리소스는 단일 레이어가 소유권 갖고 변경창구 일원화 필요, ⓒ 자동화(Lambda)가 못 잡는 "설계상 위반"(80은 정상포트지만 CloudFront-only여야 함)은 코드리뷰/탐지로 보완.

### ★ 다음 세션 할 일 — ~~① IAM Access Analyzer~~ ✅ → ~~② Lambda 자동대응~~ ✅ 코드완료(apply 대기) → ③ 전체 코드리뷰
> 사용자 결정: 남은 작업을 **① IAM Access Analyzer → ② Lambda 자동화** 순서로 진행. **① 완료·apply 확인됨(2026-06-18)**.
> **▶ ② Lambda 자동대응: 코드 작성·validate 통과 완료(2026-06-19). 사용자 apply 대기 중.** 아래 [#② 완료] 로그 참조.

#### ⏯️ 현재 중단 지점 (2026-06-19 세션 종료 시점) — 다음 세션 여기서 이어서
**지금 상태:** SG 자동대응 Lambda 코드 작성·validate 통과. **아직 apply 안 함.** 코드는 D 또는 C 드라이브에 있으나 git push/apply 모두 미실시.

**▶ 다음 세션 시작 시 먼저 할 일 (순서):**
1. **사용자가 작업 위치(드라이브) 먼저 알려주기** → 그 경로로 `terraform init`(archive provider) → `plan` → `apply`. (SG Lambda는 드라이런 기본값이라 첫 apply 안전.)
2. apply 후 콘솔 확인(테스트 SG에 22번 `0.0.0.0/0` 추가 → 서울 보안 이메일 수신, 드라이런이면 회수 안 됨).
3. 오탐 0 확인되면 `var.sg_auto_revoke_enabled=true`로 회수 활성화 여부 결정.

**🟡 SG Lambda 관련 열린 결정 2개 (apply 전/후 정하면 됨):**
- (a) **첫 apply를 드라이런으로 갈지 / 처음부터 회수 켤지** — 현재 기본값=드라이런(권장). 사용자 답변 대기.
- (b) **`ModifySecurityGroupRules` 트리거 추가 여부** — 현재 코드는 규칙 *추가*(`AuthorizeSecurityGroupIngress`)만 잡고 콘솔에서 기존 규칙을 *편집*해 `0.0.0.0/0`으로 바꾸는 건 못 잡음(실제 사각지대). 추가하려면 핸들러 groupId 추출 보강 필요. 사용자 결정 대기.

**🟢 다음 자동대응 후보 — 이번 세션 논의 완료, 코드 미착수:**
- **A) CloudTrail 자동 재가동 Lambda (1순위 추천)** — 누가 `StopLogging`/`DeleteTrail` 하면 `cloudtrail_tampering` 규칙(security_event_alerts.tf, 이미 존재) 재사용해 Lambda가 즉시 재가동+알림. 위험 낮음($0). **항상 켜져야 하는 이유는 사용자에게 설명 완료**(CloudTrail이 EventBridge알림·Athena·GuardDuty·생체정보감사의 토대 / 공격자 first move=로그끄기 T1562 / 로그공백 소급복구불가 / 생체정보 컴플라이언스 / 무결성·부인방지 / 공용계정 책임추적). → **사용자가 진행하라 하면 SG와 같은 패턴(드라이런 토글+최소권한)으로 작성.**
- **B) 계정 레벨 S3 Block Public Access** (`aws_s3_account_public_access_block`) — Lambda보다 간단·강력한 예방. 저위험·$0.
- **C) EBS 기본 암호화** (`aws_ebs_encryption_by_default`) — 예방 설정 한 줄, 위험 없음·$0.
- **알림만 유지(자동대응 부적합):** IAM 민감 변경, 루트 사용 — 자동 되돌리면 정상 작업 파괴 위험.

**① IAM Access Analyzer (외부 접근 분석기) — ✅ 완료 (2026-06-18, `access_analyzer.tf`, validate 통과)**
- 목적: S3 버킷/IAM 역할/KMS 키 등이 **외부 계정·퍼블릭에 실수로 노출**됐는지 자동·상시 탐지. (준수 축 보강)
- 비용: **무료** (외부 분석기만 사용. 미사용권한 분석 $0.20/ID·월, 내부 분석기 $9/리소스·월 → 둘 다 **안 씀**).
- 작성 내용: `aws_accessanalyzer_analyzer` (type=`ACCOUNT`) **서울 1개 + us-east-1 1개**(글로벌 자원 노출 커버, 둘 다 무료) + EventBridge 규칙/타깃 2개(`source=aws.access-analyzer`, `detail-type=Access Analyzer Finding`, `detail.status=ACTIVE`만) → 서울은 `security_alerts_seoul`, us-east-1은 기존 `security_alerts` 토픽 재사용.
- **apply 예상:** 순수 additive — 분석기 2개 + EventBridge 규칙 2개 + 타깃 2개 = 6 added, 0 changed, 0 destroyed. 서비스/리소스 변경 없음(탐지 전용).
- **apply 위험:** **없음.** 기존 SNS 토픽 재사용(토픽 정책은 이미 events 발행 허용 — GuardDuty 배선에서 설정됨). 신규 이메일 구독 없음 → 추가 Confirm 불필요.
- **콘솔 확인:** IAM → 액세스 분석기(Access Analyzer)에 `securevoice-dev-account-analyzer` 활성 + (있다면) 외부 노출 finding 표시. 서울/버지니아 각각.
- **[apply 확인됨]** 사용자가 정상 apply 완료 (2026-06-18).

**② Lambda 자동대응(self-healing) — SG 0.0.0.0/0 개방 시 자동 회수 + 알림**
- 목적: 보안그룹에 `0.0.0.0/0` 인바운드가 열리면 **Lambda가 자동으로 해당 규칙을 회수(revoke)하고 SNS로 알림**. (대응 축 → 자동화로 승격, 필살기)
- 트리거: 이미 `security_event_alerts.tf`에 SG 변경 EventBridge 규칙 존재 → **재사용/확장**해서 Lambda 타깃 추가 검토(중복 룰 주의).
- 필요 리소스: Lambda 함수(python, boto3로 `revoke_security_group_ingress`) + Lambda 실행 IAM 역할(ec2 describe/revoke + logs + sns publish, **최소권한**) + EventBridge→Lambda 권한(`aws_lambda_permission`) + (기존)SNS 알림.
- 비용: 실질 **$0** (Lambda 무료한도 내, 드문 트리거).
- ⚠️ **위험: 중.** 잘못 짜면 **정상적인 SG 변경까지 자동 회수**해 서비스 영향 가능. → ⓐ 회수 대상을 `0.0.0.0/0` + 위험 포트(22/3306 등)로 **좁히고**, ⓑ 처음엔 **회수 없이 알림만**(dry-run) 돌려 오탐 확인 후 회수 활성화 권장. ⓒ 예외 태그(예: `AutoRemediate=false`) 설계 고려.
- 착수 전 확인: `security_event_alerts.tf`의 기존 SG 룰과 패턴 충돌/중복 여부 점검.

**[#② 완료 — 코드/validate, apply 대기]** SG 0.0.0.0/0 자동대응 Lambda (lambda_auto_remediation.tf + lambda/sg_auto_remediate/index.py, terraform validate 통과)
- **재사용:** 새 EventBridge 규칙을 만들지 않고 기존 `aws_cloudwatch_event_rule.sg_rule_changes`(security_event_alerts.tf, AuthorizeSecurityGroupIngress/Egress 탐지)에 **Lambda 타깃만 추가** → 룰 중복 없음. 알림(SNS)과 자동대응(Lambda)이 같은 트리거 공유.
- **안전 설계:** ⓐ 위험포트(22/23/21/3389/3306/5432/1433/6379/11211/27017/9200)+전체포트(-1) 에 `0.0.0.0/0`·`::/0` 인 인바운드만 대상. ⓑ `var.sg_auto_revoke_enabled` 기본 **false=드라이런(알림만)** → 오탐 관찰 후 true 로 회수 활성화. ⓒ SG 태그 `AutoRemediate=false` 면 건너뜀(의도적 개방 예외).
- **동작:** Lambda가 이벤트의 groupId로 SG 현재 상태를 재조회 → 실제로 열려있는 위험 규칙만 처리(이벤트 파싱 의존 최소화). 인바운드(AuthorizeSecurityGroupIngress)만 처리, egress 이벤트는 즉시 skip.
- **최소권한 IAM:** logs(전용 로그그룹만), ec2:DescribeSecurityGroups(`*` — Describe는 리소스제한 미지원, AWS 제약), ec2:RevokeSecurityGroupIngress(이 계정/서울 리전 SG ARN으로 한정), sns:Publish(서울 토픽 1개만).
- **신규 의존성:** `hashicorp/archive` 프로바이더 추가(provider.tf) — 파이썬 zip 패키징용. `terraform init` 1회 필요.
- **apply 예상:** additive — archive(zip) + IAM role/policy + log group + lambda + event target + lambda permission ≈ 6 added, 0 changed, 0 destroyed. 기존 SG/서비스 변경 없음.
- **apply 위험:** **낮음(드라이런 기본값 덕).** 첫 apply는 회수 안 함=알림만이라 정상 SG 변경을 잘못 막을 위험 없음. 회수 켜기 전(`sg_auto_revoke_enabled=true`) 알림 로그로 오탐 0 확인 권장.
- **콘솔 확인:** ① Lambda 콘솔에 `securevoice-dev-sg-auto-remediate` 존재. ② 테스트 SG에 22번 포트 `0.0.0.0/0` 인바운드 추가 → 서울 보안 이메일로 "[보안경보] SG 위험 개방 탐지" 수신(드라이런이면 회수 안 됨). ③ CloudWatch Logs `/aws/lambda/...-sg-auto-remediate`에 실행 로그.
- **사용자 할 일:** WSL에서 `terraform init`(archive provider) → `terraform plan` 확인 → `terraform apply`. (회수 활성화는 이후 `-var sg_auto_revoke_enabled=true` 또는 변수 기본값 변경)

**[#② 보강 완료 — ✅ apply 완료 (2026-06-22)] (드라이런 상태로 배포됨)** SG 사각지대 보강 + CloudTrail 자동복구 추가
> ✅ apply 완료. 두 Lambda 모두 **드라이런(알림만)** 상태로 가동 중. **데모/발표 자료 만들 때 `sg_auto_revoke_enabled=true` / `cloudtrail_auto_recover_enabled=true`로 변경해 실제 자동회수·자동복구 작동 확인 예정.**
- **SG: `ModifySecurityGroupRules` 커버** (sg_auto_remediate/index.py + security_event_alerts.tf)
  - 기존 규칙을 콘솔에서 *편집*해 `0.0.0.0/0` 으로 바꾸는 경로(=`AuthorizeSecurityGroupIngress` 로 안 잡히던 사각지대)를 EventBridge 규칙 eventName 에 `ModifySecurityGroupRules` 추가 + 핸들러 `HANDLED_EVENTS` 확장 + `_extract_group_id()`(Modify 이벤트의 `ModifySecurityGroupRulesRequest.groupId` 추출)로 커버.
  - 회수=문제 규칙 한 줄만 revoke(SG/다른 규칙 보존). 새 SG를 규칙 포함 생성해도 Authorize 단계에서 위험 규칙만 제거됨(SG 삭제 아님).
- **CloudTrail 자동복구 Lambda 신설** (cloudtrail_auto_recovery.tf + lambda/cloudtrail_auto_recover/index.py)
  - 기존 `aws_cloudwatch_event_rule.cloudtrail_tampering`(security_event_alerts.tf) **재사용**, Lambda 타깃만 추가(룰 중복 없음).
  - StopLogging→`start_logging` 재가동 / DeleteTrail→트레일 원설정대로 `create_trail`+데이터이벤트(`uploads/`) 재적용+`start_logging`. 재생성 설정값은 `aws_cloudtrail.main` 실제 속성에서 env 주입(코드/실물 일치).
  - **UpdateTrail/PutEventSelectors 는 자동복구 안 함**(정상 Terraform 변경과 충돌 방지) → 알림만 유지.
  - 토글 `var.cloudtrail_auto_recover_enabled` 기본 **false=드라이런**(SG와 동일 철학). 최소권한 IAM: cloudtrail Start/Create/PutEventSelectors는 우리 트레일 ARN 한정, sns:Publish 서울 토픽 1개.
  - **신규 EventBridge 규칙/SNS 구독 없음** → 추가 Confirm 불필요. archive 프로바이더는 SG Lambda와 공유(추가 init 불필요).
  - **apply 예상:** additive ≈ archive(zip)+IAM role/policy+log group+lambda+event target+lambda permission. SG Lambda 변경분(타깃/핸들러)은 in-place. 기존 트레일/SG/서비스 변경 없음.
  - **콘솔 확인:** ① Lambda `securevoice-dev-cloudtrail-auto-recover` 존재. ② 테스트로 트레일 StopLogging → 서울 보안 이메일 "[보안경보] CloudTrail 변조 탐지: StopLogging" 수신(드라이런이면 재가동 안 함). ③ SG 규칙 편집(0.0.0.0/0)으로 ModifySecurityGroupRules 경보 확인.
  - **사용자 할 일:** (이미 init된 D 환경) `terraform plan` 확인 → 팀원 상의 후 `terraform apply`. 회수/복구 켜기는 `-var sg_auto_revoke_enabled=true` / `-var cloudtrail_auto_recover_enabled=true`.

**③ (전체 작업 종료 후) 전체 코드 리뷰** — 사용자 요청으로 **맨 마지막**에 수행 (후보3 `audio_oac_policy` 죽은코드 제거 포함).

---

#### (히스토리) 작업 #7 KMS 조사 — 완료됨, 참고용
**작업 #7 (KMS Key Policy 최소권한) 조사 중 — 가장 고위험 작업.**

조사된 사실:
- `aws_kms_key.securevoice_master`(kms_security.tf)에는 **현재 key policy가 없음** → 기본값(루트 계정 전체 허용) → IAM 정책으로 접근 통제 중.
- 이 키 사용처(consumer)로 확인된 것:
  - **S3 SSE-KMS**: audio/model 버킷 (s3_security.tf) — S3 서비스 + 객체 Get/Put 하는 주체.
  - **ECS api_task / worker_task 역할**: 20-runtime/iam.tf:179 에서 하드코딩 ARN에 kms:Decrypt + GenerateDataKey 부여. **[확인됨] 이 ARN(`5b711458...`)은 securevoice_master와 동일 키.**
  - **RDS**: 10-persistent main.tf:88 `storage_encrypted = true`이나 `kms_key_id` 미지정 → **[확인됨] aws/rds 기본키 사용, 이 키의 consumer 아님.**
  - **CloudFront OAC**: 현재 키 정책이 없어 암호화 객체 복호화 불가 상태 → 지금은 CloudFront로 SSE-KMS audio를 서빙하지 않음(추정). 키 정책에 추가하지 않으면 현 동작 유지.

다음 세션 할 일 (순서):
1. ~~키 ARN 대조~~ ✅ 완료 — 동일 키 확인.
2. ~~RDS 키 확인~~ ✅ 완료 — aws/rds 기본키.
3. 그 뒤 방향 선택:
   - **(안전) 옵션 A**: 루트 'Enable IAM' statement 유지 + key admin/서비스 사용 명시 → 잠금사고 위험 거의 없음, 단 엄격한 제한은 아님.
   - **(엄격·위험) 옵션 B**: 루트 enable 제거하고 사용 주체 전부 열거 → **누락 시 서비스 중단 / 키 lockout(복구 불가)** 위험. 비운영 환경 테스트 필수 → 2회차 권장.

> ⚠️ KMS key policy는 잘못 쓰면 키에서 스스로 잠겨 AWS 지원 없이 복구 불가. 반드시 'Enable IAM' 또는 key admin 접근을 보존할 것.

**[#7 완료]** 옵션 A 적용 (kms_security.tf, terraform validate 통과)
- securevoice_master에 키 정책 추가: statement1 `EnableIAMUserPermissions`(루트 kms:*, 잠금/기존동작 보존) + statement2 `AllowECSTaskRolesUseOfKey`(api/worker 역할만 Decrypt/GenerateDataKey/DescribeKey, iam_hardening.tf의 data 소스 ARN 재사용).
- apply 예상: kms key **in-place 수정 1건**(정책 추가), 키 재생성 아님. statement1이 현재 기본동작과 동일해 기능 변화 없음 → 서비스 영향 없음.
- 콘솔 확인: KMS → 고객관리형 키 → securevoice-dev-master-key → 키 정책 탭에서 두 statement 확인.
- 2회차 강화 후보: statement1 제거 + `kms:ViaService=s3` 제한 (비운영 테스트 후).

**[#9 완료]** 보안 운영 런북 작성 → `SECURITY_RUNBOOK.md` (사고 유형별 대응 절차, 조사 쿼리, 리소스 인벤토리, 정기 점검 체크리스트).

---

## 🏁 1회차 완료 (2026-06-17)
완료: #1 코드정리 · #3 Flow Logs→S3 · #4 GuardDuty+알림 · #5 EventBridge 알림 · #7 KMS 키정책(옵션A) · #9 런북
취소/보류/범위외: #2 풀스트리밍(취소) · #6 WAF Count→Block(보류, 발표 구두) · #8 Trivy(CI/CD 담당)

### 2회차(심화) 후보
1. #7 KMS 옵션 B (Enable IAM 제거 + ViaService 제한) — 비운영 테스트 후
2. #6 WAF Count→Block 전환 (로그 관찰 후 오탐 점검)
3. audio_oac_policy(죽은 설정) 제거 (s3_security.tf)
4. ✅ flow log + CloudTrail Athena 테이블 DDL 작성(발표용) → `ATHENA_SECURITY_QUERIES.md` 완료 (2026-06-18). CloudTrail 버킷 무결성/접근 추가 점검은 미실시.
5. 전체 코드 리뷰 + GitHub push 정리(.gitignore로 .terraform/state/*.bak 제외)

**[#2회차-4 완료]** Athena 보안 조사 쿼리 문서 작성 → `ATHENA_SECURITY_QUERIES.md`
- 실제 S3 경로 구조 확인 후 작성: Flow Logs(parquet+Hive 파티션), CloudTrail(표준 JSON/CloudTrailSerde).
- **파티션 프로젝션** 적용 → `MSCK REPAIR`/수동 파티션 추가 불필요(자동 인식). 비용 주의: 항상 파티션 조건으로 스캔 범위 축소($5/TB).
- 보안 쿼리 8종: REJECT 상위 출발지 / 민감포트(22,3306) / 아웃바운드 대량전송(유출) / **audio uploads/ 객체 접근(작업 B 연계)** / 루트 사용 / SG 변경 / ConsoleLogin+MFA / 사용자·IP 행동추적.
- 위험: **없음**(Terraform/리소스 변경 아님, 순수 문서). 적용 시 Athena 콘솔에서 DDL 실행 + 워크그룹 선택만 하면 됨.
- **[추가]** Athena 결과 전용 버킷 + 워크그룹 2개 신설 (`athena_results.tf`, terraform validate 통과)
  - 버킷 `securevoice-dev-athena-results-455535733131`: 퍼블릭 차단 + 14일 수명주기 + force_destroy.
  - 워크그룹 분리: `securevoice-dev-cloudtrail`→`cloudtrail/`, `securevoice-dev-flowlogs`→`flowlogs/` (결과 폴더 자동 분리). 각 워크그룹 `enforce_workgroup_configuration=true` + 결과 SSE_S3 암호화. 스캔량 상한은 옵션(주석).
  - **이유:** 로그 원본 버킷에 조사 결과(민감)가 섞이는 문제 해소 + 결과물 위생/암호화.
  - **apply 위험:** 순수 additive(버킷1+워크그룹2), 서비스 영향 없음.
  - **[apply 확인됨]** 사용자가 정상 apply 완료 (5 added, 0 changed, 0 destroyed).

## 8. 추가 보강 작업 (확정, 잔여 ~10일) — 실무 평가 기반
> 상세 평가/근거: `SECURITY_ASSESSMENT.md`. 전부 저비용·고가치만 선별.

| # | 작업 | 위험도 | 상태 |
|---|------|--------|------|
| A | S3 Bucket Keys 활성화 (SSE-KMS 버킷) — KMS 호출/비용 절감 | 낮음(additive) | ✅ 완료 |
| B | audio 버킷 `uploads/`에만 CloudTrail Data Events — 생체정보 객체 감사 | 낮음~중 | ✅ 완료 |
| C | AWS Security Hub(FSBP) + Config(스코핑) — 준수 점수·통합 | 중 | ❌ 의도적 제외 (아래 결정 참조) |
| D | IAM 비밀번호 정책 + MFA 강제 | 낮음(단 MFA 강제는 팀원 영향 주의) | ⏸️ 미진행 (팀 조율 필요 — 아래 결정 참조) |

> ⚠️ D의 MFA 강제: IAM 사용자가 MFA 미설정 시 잠길 수 있음 → 팀 IAM 사용자 존재 여부/조율 확인 후 진행.

### 작업 D 결정 (2026-06-18): 미진행
- **D-1 비밀번호 정책**(`aws_iam_account_password_policy`): 위험 낮음. 콘솔 비밀번호 규칙만 강제, 기존 사용자 즉시 잠금 없음. → 추후 단독 추가 가능한 안전 항목.
- **D-2 MFA 강제**: **고위험.** MFA 미등록 사용자는 등록조차 막혀 lockout 가능. CLI 액세스 키 사용자(예: 현재 `mzc-pmg`로 Terraform 실행 중)는 정책 설계에 따라 자동화/배포까지 막힐 수 있음. 팀 공용 계정이라 단독 결정 불가.
- **결론:** 팀 전원 MFA 등록 현황 + CLI 키 사용자 예외 처리 합의가 선행돼야 안전. 현 시점 미진행. (필요 시 D-1만 분리 적용 검토)

### 작업 C 결정 (2026-06-18): 의도적 제외 + 대안 확보
- **사전 확인:** 계정 455535733131 서울 리전에 Config 레코더 없음 / Security Hub 미구독 → 충돌 없이 켤 수는 있었음(기술적 가능). 그러나 **켜지 않기로 결정.**
- **제외 근거:** Config/Security Hub의 핵심 가치는 **멀티계정 · 다팀의 지속적 드리프트 탐지**인데, 단일 dev 서비스에선 비용 대비 효과가 낮음. 예상 상시 비용 **월 $10~30** 대비 신규 가치는 사실상 "보안 점수 대시보드"라는 시각 자료 하나에 그침.
- **대안(이미 확보):** ① 예방 통제는 **IaC(Terraform) 코드에 고정**(예: S3 퍼블릭 차단 `public_access_block`, SSE-KMS 암호화 강제, SG 체이닝 등 위험 설정을 코드 규칙으로 사전 차단) + 드리프트(코드와 실제의 어긋남)는 `terraform plan`으로 차이 탐지 후 `apply`로 원상복구. ② 위협 탐지는 **GuardDuty(서울+버지니아)** 가 담당. ③ 로깅/감사는 CloudTrail(멀티리전+무결성)+Flow Logs(S3/Athena).
- **⚠️ 솔직한 한계(면접 대비):** `terraform plan`은 **사람이 직접 돌려야** 드리프트가 보임(수동·주기적). 반면 Config/Security Hub는 **24시간 자동 감시**로 어긋나는 즉시 탐지. → 정확한 포지션: "단일 서비스라 **plan 기반 수동 드리프트 점검으로 충분**하다 판단. 멀티계정·상시 자동 감시가 필요해지면 그때 Config를 도입하는 게 비용 대비 합리적." (이렇게 답하면 "plan은 자동이 아니지 않냐"는 반박을 선제 차단)
- **일관성:** Shield Advanced·Macie·SIEM과 **동일한 "비용 대비 효과로 취사선택" 논리** → SECURITY_ASSESSMENT.md "의도적 제외" 목록에 합류.
- **발표/면접 멘트:** "Config/Security Hub는 멀티계정 지속 준수 모니터링이 본질인데 단일 dev 서비스엔 과합니다. 예방은 IaC에 고정해 plan으로 드리프트를 잡고, 탐지는 GuardDuty로 커버했습니다. 프로덕션·멀티계정 확장 시 Security Hub를 컨트롤 타워로 도입하는 게 정석입니다."
- **재검토 트리거:** 멀티계정(AWS Organizations) 전환 / 컴플라이언스 인증(ISMS-P, SOC2 등) 요구 발생 시 → 그때 Security Hub를 위임관리자 계정에 도입.

---

## 4. 결정 대기 / 질문 (Open Questions)

- GuardDuty: 유지할지 제거할지 (비용 vs 위협탐지 가치) — #4에서 다룸
- CloudTrail→CloudWatch 스트리밍: 전 워크로드에 필요한지 — #5에서 다룸
- WAF CloudFront 연결이 실제로 콘솔에서 돼 있는지 확인 필요