# 🏛️ 공부노트 A — 아키텍처 전체 흐름 (실제 다이어그램 기준)

> 목표: "이 서비스 구조 설명해보세요" 에 **막힘없이 흐름으로** 답하기.
> 사용법: 1번(한 문장) → 2번(흐름) → 3번(3단 서브넷)을 외우고, 마지막 예상질문으로 셀프 점검.

---

## 1. 한 문장 요약 (제일 먼저)
> "사용자 음성(생체정보)을 AI로 텍스트 변환하는 서비스입니다. Route53→CloudFront→WAF로 받아서, 서울 VPC를 **2개 AZ × 3단 서브넷(Public→App→Data)** 으로 쌓아 DB를 가장 깊이 숨겼고, ECS가 요청을 처리하며 무거운 변환은 SQS로 워커에 넘깁니다. 이 구조 위에 길목마다 보안 통제를 박았습니다."

---

## 2. 데이터 흐름 (바깥 → 안)

```
[사용자]
   │
[Route 53]            DNS — 도메인을 CloudFront로 안내
   │
[CloudFront] + [WAF]  전세계 엣지 / Origin = S3(정적 React) + ALB(동적 API)
   │                  엣지에서 WAF가 L7 공격·디도스 검사
   ▼  ── Seoul Region, VPC 10.0.0.0/22 ──
[Internet Gateway]
   │
[ALB]                 Public Subnet, 2개 AZ에 걸침 (443만, CloudFront 엣지에서만)
   │
[ECS Fargate]         Private App Subnet (외부 직접접근 ❌)
   │   ├─ API Service          요청 받음
   │   ├─ Free user AI Worker  ┐ SQS 큐에서 가져가 AI 변환
   │   └─ Paid user AI Worker  ┘ (제로 인바운드)
   │
[RDS]                 Private Data Subnet (가장 깊숙이), Multi-AZ 복제
```

### 말로 읊는 7단계
1. 사용자가 **Route53**(DNS)을 거쳐 **CloudFront**로 들어온다.
2. CloudFront 엣지에서 **WAF**가 요청 내용을 검사한다 (SQLi·XSS·디도스 거름).
3. 동적 요청은 **ALB**로 가는데, 443만 + **CloudFront 엣지(Prefix List)에서 온 것만** 받는다.
4. ALB가 **ECS API**로 라우팅. API가 요청 처리.
5. 음성 원본은 **S3(audio)** 에 SSE-KMS 암호화 저장, 무거운 변환은 **SQS 큐**에 적재.
6. **AI 워커**가 큐에서 가져가 변환 (받는 게 아니라 가져감 = 제로 인바운드 근거).
7. 사용자/메타데이터는 **RDS**(Multi-AZ 이중화), 모델·결과는 **S3(model)**.

---

## 3. 3단 서브넷 구조 (설명의 뼈대) ⭐

VPC(10.0.0.0/22)를 **2개 AZ(A·C)** 로 나누고 각 AZ를 **3겹**으로:

| 계층 | 들어있는 것 | 외부 접근 |
|---|---|---|
| **Public** (10.0.0.0/25, .64/25) | ALB, NAT Gateway | 인터넷 ↔ (입구) |
| **Private App** (10.0.1.0/25 등) | ECS(API/워커), Admin(Jenkins·DB Access) | ❌ 직접 불가 |
| **Private Data** (10.0.1.192/26 등) | RDS | ❌ 가장 깊숙이 |

> 핵심: **"중요한 건 안쪽 깊이 숨긴다."** RDS는 Private Data에 있어 인터넷에서 직접 못 닿음. ALB만 Public에 노출되고 그것도 WAF/CloudFront 뒤.

---

## 4. Admin Services — "ECS 말고 누가 RDS에 붙나?" 의 답
- **Jenkins Server** = CI/CD 빌드
- **DB Access Server** = DBA/관리자가 RDS 접속하는 **베스천 서버**
→ RDS SG에 ECS 외 규칙(3306)이 있는 이유 = **DB Access Server / Jenkins** 가 붙어야 해서.

---

## 5. NAT Gateway + VPC 엔드포인트 (비용·보안)
- **NAT Gateway** (각 Public Subnet): Private의 ECS가 **밖으로 나갈 때만** 쓰는 통로(아웃바운드 전용, 인바운드 ❌).
- **VPC 엔드포인트** (Interface + Gateway) → S3·Lambda 등: AWS 서비스 트래픽을 인터넷 안 거치고 **VPC 내부 사설 경로**로. 특히 **S3 Gateway 엔드포인트는 무료** → NAT 데이터처리 비용 절감 + 보안↑.

---

## 6. 우측 서비스 아이콘 = 용도
| 서비스 | 용도 |
|---|---|
| SQS | API→워커 작업 큐 (제로 인바운드 근거) |
| ECR | 컨테이너 이미지 저장소 |
| Secrets Manager | DB 비번 등 비밀 (팀 10-persistent) |
| KMS | 암호화 마스터키 (내 작업) |
| SNS | 보안 알림 (내 작업) |
| IAM | 권한 최소화 (내 작업) |
| CloudTrail | 감사 로그 (내 작업) |
| SSM | DB Access Server 등 SSH 없이 안전 접속(Session Manager) |
| CloudWatch / Lambda | 메트릭·경보 / 자동대응 |

---

## 7. 리전 구조 (꼭 알 함정)
```
서울(ap-northeast-2)        버지니아(us-east-1)
메인 인프라 전부            CloudFront / WAF (글로벌 필수)
RDS·ECS·S3·GuardDuty        글로벌 이벤트(루트/IAM)·GuardDuty
SNS(서울)·EventBridge 4규칙  SNS(버지니아)·EventBridge 4규칙
```
- **왜 둘?** CloudFront/WAF는 us-east-1 고정 + 루트·IAM 같은 글로벌 활동이 us-east-1에 기록 → 탐지 공백 막으려 알림·GuardDuty를 양쪽에 배치.

---

## 8. 보안 전 주기 (발표 뼈대)
```
① 예방   암호화·격리·최소권한으로 애초에 차단
② 경계   WAF로 엣지에서 거름
③ 탐지   CloudTrail·Flow Logs·GuardDuty·Analyzer로 감시
④ 알림   위험하면 EventBridge→SNS→이메일
⑤ 대응   Lambda가 자동 회수/복구 (self-healing)
```

---

## 9. ❓ 예상 질문 (셀프 점검)
- "전체 구조 설명?" → 2번 7단계.
- "음성 업로드 경로?" → 사용자→Route53→CloudFront→WAF→ALB→ECS API→S3(audio) + SQS→워커.
- "worker 인바운드 0인 이유?" → 큐에서 가져가 처리하므로 받을 필요 없음.
- "ECS 말고 RDS 접속 주체?" → DB Access Server(베스천)/Jenkins (Admin Services).
- "리전이 왜 둘?" → CloudFront/WAF us-east-1 고정 + 글로벌 활동 기록 → 탐지 공백 방지.
- "NAT랑 VPC 엔드포인트 차이?" → NAT는 인터넷 아웃바운드, 엔드포인트는 AWS 서비스로 가는 사설경로(S3 Gateway는 무료).
- "RDS 고가용성?" → Multi-AZ 복제(AZ-A↔C).

---

## ✅ 외울 핵심 3개
1. **흐름:** 사용자→Route53→CloudFront→WAF→ALB→ECS(API/워커)→RDS/S3
2. **3단 서브넷:** Public(ALB·NAT) → Private App(ECS) → Private Data(RDS), 2 AZ
3. **전 주기:** 예방→경계→탐지→알림→대응
