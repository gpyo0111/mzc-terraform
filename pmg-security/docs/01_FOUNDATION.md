# 01. FOUNDATION (기초 배선) — provider / variables / locals / data_* / outputs

> 이 단계는 "보안 기능"이 아니라, **이 레이어가 어떻게 굴러가고 다른 레이어를 어떻게 읽나**를 다룬다.
> 🎤 발표 위치: 본론 전 **"코드 구조 한 장"** 슬라이드. (깊게 안 가고 30초)

---

## provider.tf — 엔진 설정

**무엇을 만드나**
- `required_version >= 1.6.0`, 프로바이더 2개: `aws ~> 5.0` + `archive ~> 2.0`(Lambda zip 패키징용).
- `backend "s3"`: 이 레이어의 state 저장소 = `securevoice/dev/pmg-security/terraform.tfstate`.
- `provider "aws"` 기본 리전 = 서울(ap-northeast-2).

**왜**
- **state를 S3에 원격 저장** → 팀 공유 + 유실 방지. (드리프트 사고 때 "코드 vs 실제" 비교 기준이 됨)
- `archive` 프로바이더 = 자가복구 Lambda 추가하면서 필요해짐(파이썬 폴더→zip).

**어떻게 작동**
- `terraform init`이 backend(S3)에 연결하고 프로바이더를 내려받음.
- ⚠️ archive 추가 후 새 환경에선 `terraform init` 1회 필요.

**🎤 발표 / ❓예상 질문**
- Q: "state 왜 S3에 두나?" → 팀 공유·동시작업 안전·유실방지. (+ 잠금 필요 시 DynamoDB lock 언급 가능)

---

## (리전 2개) 서울 + 버지니아
- 서울(기본) = 대부분. 버지니아(`aws.us_east_1`, **waf.tf에 정의**) = 글로벌 서비스(WAF/GuardDuty글로벌/Access Analyzer/root·IAM 이벤트).
- ❓"왜 버지니아도?" → CloudFront·IAM 글로벌 서비스 로그/통제는 us-east-1에서만 동작(AWS 제약).

---

## variables.tf — 바꿀 값은 한 곳에 (SSOT)

**무엇을 만드나**
- `aws_region`, `account_id`, `project_name`, `env`, `vpc_id` 등 공통값.
- 버킷 이름들(`audio_bucket_name`=생체정보 음성, `model_bucket_name`, `web_static_bucket_name`, `tf_state_bucket_name`).
- `kms_key_alias`, `security_alert_email`(보안 경보 수신).

**왜**
- 하드코딩 제거 → **단일 진실 공급원**. 담당자 이메일 바뀌면 `security_alert_email` 한 줄만 수정.
- `audio_bucket_name` 설명에 "고위험 생체정보" 명시 → 왜 이 버킷에 보안을 집중하는지 코드가 스스로 설명.

**🎤 발표 / ❓예상 질문**
- Q: "이메일 같은 게 코드에 박혀 있는데?" → 변수화돼 한 곳에서 관리. 민감값(시크릿)은 변수가 아니라 Secrets Manager로 분리(10-persistent).

---

## locals.tf — 반복 줄이기

**무엇을 만드나**: `waf_name`, `common_tags`(Project/Environment/ManagedBy=terraform).

**왜**: 모든 리소스에 **태그 통일** → 비용추적·리소스검색·소유 파악. `ManagedBy=terraform` = "콘솔로 손대지 말 것" 신호.

---

## data_network.tf / data_persistent.tf / data_runtime.tf — 다른 레이어 "읽기 전용" 창구 ★

**무엇을 만드나**
- `terraform_remote_state`로 `00-network`(VPC), `10-persistent`(RDS·S3·Secrets), `20-runtime`(ECS)의 state를 읽어옴.

**왜 (이 레이어의 핵심 원칙)**
- 작업 범위 = **pmg-security 안에서만 작성**. 다른 레이어 리소스는 **읽기만** 한다는 원칙이 코드로 구현된 부분.
- 비유: 옆 팀 공책을 눈으로만 보고(VPC ID·서브넷·SG ID 참조), 절대 거기에 쓰지 않음.

**어떻게 작동**
- 다른 레이어가 `output`으로 내보낸 값을 `data.terraform_remote_state.<name>.outputs.<key>`로 참조.
- ※ 읽는 방식 2가지: (1) remote_state(레이어 output), (2) `data.aws_s3_bucket`/`data.aws_security_group`처럼 **이름으로 직접 조회**(s3_security.tf·security_groups.tf에서 사용). 둘 다 읽기 전용.

**🎤 발표 / ❓예상 질문**
- Q: "레이어를 왜 나눴나?" → 생애주기 분리(네트워크·영속데이터·런타임·보안). 보안 레이어가 다른 걸 망가뜨리지 않게 읽기전용 참조.
- Q: "remote_state vs data 소스 차이?" → remote_state는 그 레이어가 *내보낸 것만*, data 소스는 *이름으로 실시간 조회*.

---

## outputs.tf — 내 결과물 중 남이 쓸 것

**무엇을 만드나**: `verified_kms_master_key_arn` (내가 만든 KMS 마스터 키 ARN) 하나만 export.

**왜**: 다른 레이어/컴포넌트가 이 키로 암호화하도록 ARN 제공. (과거 디버깅용 `output "test"`는 #1에서 제거 — 깔끔하게 유지)

---

## ✅ 01단계 한 줄 요약
> **서울+버지니아 2리전, state는 S3, 다른 레이어는 읽기 전용으로 참조하며, 내 보안 리소스만 코드로 관리하는 레이어.**
