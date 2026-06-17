# 🎤 SecureVoice 보안 Q&A 정리 (발표/면접 대비)

> 작업하며 직접 물어본 개념 질문들을 발표·면접용으로 정리한 학습 노트.
> 새 질문이 생기면 계속 추가한다.

---

## 📂 로깅 / 모니터링

### Q. CloudTrail, CloudWatch, VPC Flow Logs 차이가 뭐야?
- **CloudTrail**: 계정의 **API 행동**(누가 무슨 명령을 했나 — 생성/삭제/로그인) 기록. "감시카메라(사람 행동)".
- **VPC Flow Logs**: **네트워크 통신** 기록(어느 IP→어디, 허용/거부). "차량 통행기록(번호판)".
- **CloudWatch**: 메트릭·알람·로그를 다루는 **모니터링 종합 서비스**. CloudWatch Logs는 그 안의 로그 저장소.
- 핵심 교정: 기록 주체는 CloudTrail/Flow Logs이고, 그걸 **어디에 저장할지**(S3 / CloudWatch Logs)를 고르는 것.

### Q. CloudWatch Logs는 비용이 드는데 왜 굳이? 더 싼 S3를 쓰면 안 되나?
- CloudWatch Logs: **수집(ingestion) 약 $0.50~0.76/GB** + 보관. 비쌈.
- S3: 저장 $0.023/GB·월. 쌈. Athena로 검색($5/TB 스캔).
- 트레이드오프: **CloudWatch = 실시간 알림/검색 가능**, **S3+Athena = 저렴, 사후 분석**.
- 결론: 양 많고 사후분석 위주(VPC Flow 등)는 **S3+Athena**가 정석. 실시간 알림 필요한 것만 CloudWatch.
- → 우리 프로젝트: VPC Flow Logs를 CloudWatch에서 **S3로 전환**(비용↓, Athena 통일). GuardDuty는 Flow Log를 자체적으로 읽으므로 탐지 영향 없음.

### Q. Athena 주기검사(+Lambda) vs CloudWatch Logs Insights, 실무는?
- 둘을 "탐지 백본"으로 양자택일하지 않음.
- **실시간 탐지** = GuardDuty/Security Hub/EventBridge/SIEM. **사후 포렌식** = Athena on S3. **인터랙티브 조회** = (CloudWatch에 있을 때) Logs Insights.
- 실시간 탐지를 Athena 크론으로 직접 만드는 건 **안티패턴**.

---

## 🛡️ 위협 탐지 / 알림

### Q. 왜 CloudWatch 풀스트리밍 대신 EventBridge를 썼나? (핵심)
한 줄: **검색은 Athena(저렴), 실시간 알람은 EventBridge(거의 무료)로 나눠서 비싼 풀스트리밍을 통째로 생략.**
1. 검색은 이미 Athena(S3)로 하고 있어 풀스트리밍은 중복=낭비.
2. 풀스트리밍은 모든 로그를 수집비 내고 빨아들여 비쌈.
3. CloudTrail 관리 이벤트는 **EventBridge 기본 버스로 자동 전달** → 전체를 비싸게 수집하지 않고도 특정 고위험 이벤트만 실시간 알람 가능.

### Q. GuardDuty와 EventBridge는 같은 실시간 탐지 도구야?
아니다, 카테고리가 다름.
- **GuardDuty** = 관리형 **위협 탐지 엔진**(ML+위협인텔, 미지·행동 위협 탐지). finding 생성.
- **EventBridge** = **이벤트 라우터/규칙 엔진**(내가 적은 패턴만 매칭). 탐지 지능 없음.
- 보완 관계: `GuardDuty(탐지) → EventBridge(배관) → SNS(알림)`.

### Q. GuardDuty엔 알림 기능이 없어?
맞다. GuardDuty는 finding을 콘솔에 쌓기만 함. 이메일 알림은 **EventBridge → SNS**로 따로 배선해야 함(AWS 공식 방식). GuardDuty는 finding을 EventBridge로 자동 발행.

### Q. EventBridge는 내가 직접 지정해야 → 모르는 위협은 못 잡지?
맞다. EventBridge는 사전 정의한 패턴만 잡음(미지/행동 위협 못 잡음). 그래서 **GuardDuty(미지 위협) + EventBridge(특정 정책 이벤트)** 를 함께 쓰는 게 방어 심도(defense in depth).

### Q. "severity Medium 이상만 알림"의 기준은?
- GuardDuty severity는 1.0~8.9 숫자: **Low 1.0~3.9 / Medium 4.0~6.9 / High 7.0~8.9**.
- 규칙 조건 `severity >= 4` → Medium+High만 알림, Low(노이즈) 차단.
- severity 값은 **GuardDuty가 finding 유형별로 자동 부여**(우리는 필터 기준으로만 사용). 컷오프는 숫자만 바꾸면 조정 가능.

### Q. Shield는 뭘 쓰고 있나?
- **Shield Standard**: 모든 AWS 계정에 **무료·자동**(L3/L4 DDoS). 우리가 쓰는 것.
- **Shield Advanced**: 월 $3,000+ 유료. 계약 안 했으면 아님.
- L7 DDoS는 WAF Rate-based 룰이 보완.

---

## 🔐 암호화 / KMS

### Q. KMS 키 종류는?
- **AWS owned**: AWS가 관리(안 보임), 무료.
- **AWS managed**(`aws/s3`, `aws/rds`): 서비스별 자동, 정책 편집 불가, 키 월정액 없음. (우리 RDS = `aws/rds`)
- **Customer managed (CMK)**: 내가 생성·통제, 정책 편집·로테이션 가능, **키당 월 $1**. (우리 `securevoice_master`)

### Q. 봉투 암호화(Envelope Encryption)란? 마스터키 하나로 어떻게 다 암호화하나?
- 마스터키(CMK)는 큰 데이터를 직접 암호화하지 않음(4KB 이하만).
- 파일마다 **데이터키**를 생성(`GenerateDataKey`) → 그 데이터키로 파일 암호화 → 데이터키 자체를 마스터키로 봉인.
- 읽을 땐 마스터키로 데이터키를 풀고(`Decrypt`) → 데이터키로 파일 복호화.
- 그래서 마스터키 하나로 무한한 데이터 보호 가능(작은 데이터키만 봉인/해제).

### Q. 큰 파일이면 암호화가 오래 걸리지 않나?
- 파일 암호화는 AES(대칭키)로 S3가 로컬 처리 → 매우 빠름. **KMS 호출은 파일당 1번**(크기 무관).
- 병목은 네트워크 업로드지 암호화 아님. (소형 파일 대량이면 S3 Bucket Keys로 KMS 호출 절감)

### Q. 마스터키 하나로 전부 해결하나?
- 기술적으론 가능하지만 실무는 **분리** 권장(폭발 반경 축소, 도메인별 접근통제/로테이션/감사).
- 우리 현황: 가장 민감한 **S3 audio(생체 음성)/model**에만 전용 CMK, RDS는 `aws/rds`, Secrets는 `aws/secretsmanager` 기본키. → 민감 데이터에 통제력 집중(합리적).

### Q. CloudFront는 잘 되는데 "암호화 audio를 복호화 못 한다"는 게 뭐야?
- 버킷이 둘이고 암호화가 다름:
  - **web_static**(정적 웹): CMK 암호화 안 함 → CloudFront 정상 서빙(그래서 웹 잘 됨).
  - **audio**: CMK(SSE-KMS) 암호화 → CloudFront에 키 권한 없어 직접 복호화 불가.
- 즉 음성 파일은 CloudFront로 직접 안 내려주는 구조(API/ECS 경유). 정적 웹은 영향 없음.

### Q. KMS Key Policy의 `Enable IAM` statement란? 옵션 A vs B 차이?
- **`Enable IAM`**: "이 계정의 IAM 정책으로 키 접근 허용 가능"이라는 기본 문장. 빼면 IAM 권한이 전부 무효가 되고 키 정책에 직접 적힌 주체만 키 사용 가능.
- **옵션 A**(Enable IAM 유지 + 관리자/사용자 명시): 기존 동작 보존, 안전, 문서화·감사 위주(엄격하진 않음).
- **옵션 B**(Enable IAM 제거 + 사용 주체 전부 열거): 진짜 최소권한이지만, 하나 누락 시 서비스 중단 / 관리자 누락 시 **키 영구 잠금(lockout)**. 비운영 테스트 필수.
- 비유: A=문 열어두고 명단 게시 / B=문 잠그고 명단에 적힌 자만 입장.

### Q. IAM 정책과 KMS 키 정책의 정확한 차이는?
- **IAM 정책**: 사람/역할에 붙음. "이 역할이 **무엇을** 할 수 있나"(identity 기반).
- **KMS 키 정책**: 키 자체에 붙음. "이 키를 **누가** 쓸 수 있나"(resource 기반).
- KMS만의 특수성: 대부분 서비스는 IAM만으로 접근되지만, **KMS는 키 정책이 `Enable IAM`으로 IAM을 인정해야만 IAM 정책이 작동**한다. 둘 다 통과해야 키 사용 가능(키 정책이 최종 게이트키퍼).
- 비유: IAM 정책=사원증 권한 / 키 정책=금고에 붙은 출입규칙. 금고(KMS)는 규칙에 "사원증 시스템 인정(Enable IAM)"이 적혀 있어야 사원증이 통함.

### Q. 민감한 audio 파일을 CloudFront 대신 API/ECS로 처리하는 게 문제없나?
- 문제없고 **오히려 권장 패턴**. CloudFront 직접 서빙은 엣지에 전 세계 캐시되고 요청별 인증이 어려워 민감 생체정보엔 부적합.
- API/ECS 경유 = 요청별 인증·인가, 접근 로깅, 엣지 캐시 없음, KMS 복호화가 통제된 ECS 안에서만 발생.
- 정적 웹=CloudFront(빠른 배포) / 민감 음성=API 경유(엄격 통제)로 용도 분리한 좋은 설계.
- 정리거리: s3_security.tf의 `audio_oac_policy`는 실제 안 쓰이는 죽은 설정 → 2회차 제거 후보(당장 무해).

---

## 🧱 네트워크 / S3 (요약)
- **보안그룹 체이닝**: IP가 아니라 "앞단 리소스의 SG ID"를 신분증처럼 검사(ALB SG→ECS SG→RDS SG).
- **S3 퍼블릭 차단**: 4개 옵션 모두 켜서 실수로 인터넷 공개되는 사고 원천 차단.
- **VPC 엔드포인트**: 프라이빗 서브넷이 공용 인터넷 안 타고 AWS 서비스(S3/ECR/SQS 등)와 사설 통신.
- **Managed Prefix List(CloudFront)**: ALB 인바운드를 CloudFront 에지 IP로만 제한 → WAF 우회 직접 침투 차단.