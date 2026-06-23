# 02. PREVENTION (예방) — kms / s3 / security_groups / worker_sg / iam_hardening

> 🎤 발표 위치: **뼈대(아키텍처 경로를 보안 렌즈로 다시 걷기)**의 핵심. "각 길목에서 뭐가 지키나".
> 큰 그림: **암호화(KMS→S3→IAM 3박자)** + **접근통제(SG 체이닝·제로인바운드·최소권한 IAM)**.

---

## kms_security.tf — 마스터 자물쇠(CMK)

**무엇을 만드나**
- `aws_kms_key.securevoice_master` (고객관리형 키) + `aws_kms_alias`(별칭 `alias/securevoice-dev-master-key`).

**왜**
- `enable_key_rotation=true`: 연 1회 자동 키 교체 → 키 유출돼도 미래 데이터 보호(컴플라이언스).
- `deletion_window_in_days=30`: 삭제 명령 후 30일 복구 유예 → 실수/랜섬웨어 방지 타임록.
- **키 정책(옵션 A)**: ① 루트 `kms:*`(잠금사고 방지 + 기존 IAM 기반 접근 유지) + ② ECS api/worker 역할만 `Decrypt`/`GenerateDataKey`/`DescribeKey` → 관리자·사용자 분리, 감사성↑.

**어떻게 작동**
- S3가 이 키로 객체를 SSE-KMS 암호화. ECS 역할이 객체 읽을 때 이 키로 복호화.
- ② statement의 역할 ARN은 `iam_hardening.tf`의 `data.aws_iam_role`(팀 역할 읽기) 재사용.

**🎤 / ❓예상 질문**
- Q: "키 lockout 안 무섭나?" → 옵션 A는 루트 `kms:*` 보존이라 잠금 위험 거의 0. 엄격한 옵션 B(루트 제거+ViaService 제한)는 비운영 테스트 후 2회차로 보류.
- Q: "Bucket Key가 뭐?" → s3_security 참조(KMS 호출 캐싱·비용절감).

---

## s3_security.tf — 버킷 하드닝 (4개 버킷)

**무엇을 만드나**
- `data.aws_s3_bucket` 4개(audio/model/web_static/tf_state) 룩업.
- 4개 모두 **퍼블릭 액세스 차단**(`block_*`/`ignore_*`/`restrict_*` 4종 true).
- audio **등급별 수명주기**: guest 7일 파기 / free 30일→Glacier→90일 / paid(tenants) 30일→Glacier→365일. uploads/ + results/ 각각.
- audio·model **SSE-KMS 강제** + `bucket_key_enabled=true`.
- CloudFront **OAC** + audio/web_static **버킷 정책**(CloudFront만 접근).

**왜**
- 퍼블릭 차단 = 생체정보 버킷 실수 노출 원천 봉쇄.
- 수명주기 = 비용 절감 + **생체정보 보관 최소화**(오래 안 들고 있음 = 유출면 축소).
- SSE-KMS = 저장 데이터 암호화. Bucket Key = 객체마다 KMS 호출 안 하고 데이터키 캐싱 → KMS 비용 대폭↓, 보안 동일.
- OAC = S3를 직접 공개 안 하고 **CloudFront 경유(SigV4 서명)만** 허용 → 버킷 직접접근 차단.

**어떻게 작동**
- `kms_master_key_id = aws_kms_key.securevoice_master.arn` → KMS와 결합.
- OAC 정책 Condition `aws:SourceArn = 우리 CloudFront 배포 ARN`만 통과.

**⚠️ 알려진 이슈 (2회차 정리감, 면접 정직 포인트)**
- **`audio_oac_policy`는 사실상 죽은 설정**: audio는 SSE-KMS 암호화인데 **KMS 키 정책에 CloudFront 복호화 권한이 없음** → CloudFront가 audio 객체를 복호화 못 함 = 실제 서빙 불가. 음성은 API/프리사인드URL 경로라 CloudFront 직접 서빙 대상도 아님. → **제거 예정**(web_static OAC만 유효).

**🎤 / ❓예상 질문**
- Q: "암호화 키 누가 관리?" → 우리 CMK(KMS), 회전 자동. Q: "수명주기 왜 등급별?" → 비용+생체정보 최소보관. Q: "OAC vs OAI?" → OAC가 최신(SigV4, KMS 지원).

---

## security_groups.tf — SG 체이닝(방화벽 연결)

**무엇을 만드나**
- `data.aws_security_group` 4개(rds/ecs/alb/vpce) 룩업.
- **ECS→RDS**: RDS SG 3306 인바운드를 ECS SG에서만(`source_security_group_id`).
- **CloudFront→ALB**: ALB 443 인바운드를 CloudFront Managed Prefix List에서만(`prefix_list_ids`).
- VPCE /22 규칙은 **제거됨**(팀의 /25에 일임 — 드리프트 사건 참조).

**왜**
- SG 체이닝 = IP가 아니라 **"어느 SG에서 왔나"로 허용** → IP 바뀌어도 안전, 횡적 이동 차단.
- CloudFront Prefix List = **오리진/WAF 우회 차단**(ALB를 인터넷에 직접 안 염).

**어떻게 작동**
- `source_security_group_id`로 SG↔SG 신뢰. `prefix_list_ids`로 CloudFront 엣지 IP 집합만 허용.

**⚠️ 현재 상태**: ALB에 팀원이 작업용으로 연 **80-from-`0.0.0.0/0`**이 남아있음(코드 밖). prod 전 닫기/조이기 필요.

**🎤 / ❓예상 질문**
- Q: "IP 대신 SG로 여는 이유?" → IP 변동 무관 + 최소권한. Q: "CloudFront 우회 어떻게 막나?" → ALB를 CloudFront prefix list로만 443 개방.

---

## worker_security_group.tf — 제로 인바운드 격리 ⭐

**무엇을 만드나**: 비동기 AI 워커용 SG. **ingress 블록 없음** + egress 전체 허용.

**왜**
- 워커는 *요청 받는* 서비스가 아니라 *큐에서 가져가 일하는* 구조 → **인바운드가 필요 없음.**
- 인바운드 0 = 외부·ALB·그 무엇도 워커 포트 접근 불가(프로토콜 레벨 드롭) = 제로 트러스트.

**어떻게 작동**: egress로 SQS 폴링·S3 업로드·ECR 이미지 다운로드(아웃바운드만).

**⚠️ 심화감**: egress가 `0.0.0.0/0` 전체라 다소 넓음 → VPCE 대상으로 좁힐 수 있음(위험 낮음, 나가는 쪽).

**🎤 / ❓예상 질문**
- Q: "워커는 어떻게 통신?" → 인바운드 0, 아웃바운드로 큐를 폴링. "받지 않고 가져간다"가 핵심.

---

## iam_hardening.tf — 팀 코드 안 건드리고 최소권한 보강 ⭐

**무엇을 만드나**
- 팀의 ECS 역할(api/worker) **읽기 룩업**.
- `s3:ListBucket`을 **audio/model 버킷에만**(`*` 아님) 주는 정책 생성 → 두 역할에 **attach만** 추가.

**왜**
- 403 오탐 방지(버킷 존재 조회엔 ListBucket 필요)하되 **리소스를 특정 버킷으로 한정**(최소권한).
- 팀 폴더(20-runtime) 코드 수정 없이, **내 레이어에서 정책을 덧붙임** → 공용 환경 협업 원칙.

**어떻게 작동**: `aws_iam_role_policy_attachment`로 우리가 만든 정책을 팀 역할에 연결.

**🎤 / ❓예상 질문**
- Q: "공용 계정에서 팀 권한 어떻게 안 깨고 보강했나?" → 역할은 읽기만, 정책은 내 레이어에서 attach. Q: "왜 ListBucket을 `*` 안 줬나?" → 최소권한, 필요한 버킷 2개로 한정.

---

## ✅ 02단계 한 줄 요약
> **암호화는 KMS(키)-S3(적용)-IAM(사용권한) 3박자, 접근통제는 SG 체이닝·워커 제로인바운드·버킷 한정 최소권한.**
> 정리감: `audio_oac_policy` 죽은설정 제거, ALB 80 닫기.
