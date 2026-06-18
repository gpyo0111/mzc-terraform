# 🎯 SecureVoice 보안 구현 — 실무 관점 자체 평가 & 로드맵

> 시니어 엔지니어/면접관 관점의 객관적 평가. 발표·면접 대비용.

---

## 1. 종합 평가
- **포트폴리오/데모 기준 상위권, 실무 주니어~미드 수준 역량.** 예방 통제(preventive)가 탄탄.
- 프로덕션/시니어 기준으론 **거버넌스·컴플라이언스 자동화**, **예방적 IAM 통제(MFA)**, **민감데이터 객체 수준 감사**가 공백.
- 한 줄: **"보안을 켜는 법"은 충분, 이제 "보안을 운영·증명하는 법"으로 가는 지점.**

## 2. 강점 (그대로 어필)
- 예방-탐지-대응 3축을 레이어별로 설계 (WAF→SG체이닝→암호화→IAM→로깅→탐지).
- **ALB를 CloudFront Prefix List로 제한**(origin bypass 차단) — 고급 통제.
- **SG 체이닝**(SG ID 참조) — 기본 이상.
- **GuardDuty finding을 알림까지 배선** + severity 필터로 alert fatigue 방지.
- **비용 의식적 결정**(EventBridge vs 풀스트리밍, S3+Athena vs CloudWatch).
- **CMK 키 정책 footgun 인지**(Enable IAM 보존, 엄격버전 테스트 후 연기).
- IaC + 원격상태 참조로 팀 코드 비침범 + 런북/문서화.

## 3. 시니어가 지적할 공백
| 공백 | 이유 |
|------|------|
| MFA 강제 / IAM 비밀번호 정책 없음 | root 사용 *알림*은 있으나 *예방* 부재 |
| AWS Config / Security Hub 없음 | 지속적 준수·드리프트 탐지·보안점수 부재 |
| audio 버킷 객체 수준 감사 없음 | 생체정보인데 "누가 어떤 음성 접근?" 추적 불가 |
| Secrets 자동 로테이션 미설정 | DB비번/JWT 고정 (팀 폴더 영역) |
| WAF Count 모드 | 사실상 모니터링. 전환 계획은 있음 |
| IR 런북 미검증 | 문서만, 모의훈련/자동화 전 |

## 4. 추가 추천 — 고가치·저비용 (10일 내 진행 대상)
우선순위 순:
1. **AWS Security Hub (FSBP 표준)** — GuardDuty/Config 결과 통합 + 보안점수. 소액. *Config 스코핑 필요.*
2. **IAM 비밀번호 정책 + MFA 강제** — 거의 무료, 예방 통제 공백 메움.
3. **audio 버킷에만 CloudTrail Data Events** — 생체정보 객체 감사. 버킷 1개 한정해 비용 통제.
4. **S3 Bucket Keys 활성화** — KMS 호출/비용 *절감*. 한 줄 설정.
5. (예정) WAF 로그 S3 + Count→Block 전환(튜닝 후).

## 5. 필살기 (면접 스토리 = "판단 근거")
- "GuardDuty는 켜는 것보다 finding을 알림·대응으로 연결하는 게 핵심. EventBridge 배선 + severity≥4 필터."
- "검색은 Athena(저렴), 실시간 알람은 EventBridge(거의 무료)로 분리해 CloudWatch 풀스트리밍을 의도적으로 제외."
- "KMS 키 정책 lockout footgun 때문에 운영 중엔 안전한 명시적 정책, 엄격버전은 비운영 테스트 후 단계화."
- "ALB를 CloudFront Prefix List로 묶어 WAF 우회 직접 침투 차단."
- "예방-탐지-대응으로 설계, 대응은 런북화 → 다음은 SSM Automation으로 자동화."

## 6. 일부러 제외 (판단력 어필) — 각 서비스 설명
- **AWS Config + Security Hub(FSBP)**: 지속적 준수 모니터링·보안 점수 통합. **핵심 가치는 멀티계정·다팀 드리프트 탐지**인데 단일 dev 서비스엔 과함. 상시 비용 **월 $10~30** 대비 신규 가치는 "점수 대시보드" 정도. → **예방은 IaC 코드 고정+`plan`으로 드리프트 탐지, 탐지는 GuardDuty**로 대체. *단, `plan`은 수동·주기적이고 Config는 24h 자동 감시 — 단일 서비스라 수동 점검으로 충분하다 판단, 멀티계정·상시 자동화 필요 시 도입.* 멀티계정(Organizations)·컴플라이언스 인증 요구 시 위임관리자 계정에 도입이 정석. (2026-06-18 결정, 기술 검증 후 제외)
- **Shield Advanced**: DDoS 상위 등급. L7 고급방어+24/7 대응팀+비용환급. **월 $3,000+**. → 대형 표적 서비스용, 우리는 Standard+WAF Rate-limit로 충분.
- **Macie**: S3 민감정보(PII) 자동 스캔. **텍스트 PII 위주라 음성 바이너리엔 효과 제한 + 스캔 비용 큼.** → 프로덕션 확장 시 재검토.
- **GuardDuty 선택 플랜**: EKS(우리 ECS라 무관)/Malware(EBS 스캔)/RDS/Lambda 보호 — 각 추가 과금. → 기본+S3로 충분.
- **SIEM(Splunk/Datadog 등)**: 로그 통합·상관분석 플랫폼, 전담 SOC용, 고비용. → Security Hub로 대체.
- **Config 전체 기록**: 항목당 $0.003, 전체 켜면 비쌈. → 끄는 게 아니라 **핵심 리소스만 스코핑**해서 켬.

---

## 결론
현재도 경쟁력 있는 포트폴리오. **Security Hub + MFA강제 + audio data event + Bucket Keys** 4개(전부 저비용)를 더하면 **예방-탐지-대응-준수**가 완성돼 한 단계 상승.

---

## 7. 멘토 보고용 — 현황 & 로드맵 (그대로 설명 가능)

핵심 한 줄: **"보안을 예방-탐지-대응-준수 4축으로 설계하고, 비용 대비 효과로 취사선택했습니다."**

| 축 | 구현 내용 | 상태 |
|----|----------|------|
| **예방(Preventive)** | WAF 5룰, SG 체이닝, ALB→CloudFront Prefix List(origin bypass 차단), S3 퍼블릭차단, KMS(CMK) 암호화 + 키정책 | ✅ 완료 |
| **탐지(Detective)** | GuardDuty(서울+버지니아), VPC Flow Logs(S3+Athena), CloudTrail(멀티리전+무결성) | ✅ 완료 |
| **대응(Responsive)** | EventBridge 고위험 이벤트 알림(root/IAM/SG/CloudTrail), GuardDuty finding→SNS, 운영 런북 | ✅ 완료 |
| **준수(Compliance)** | S3 Bucket Keys ✅ · audio `uploads/` 객체감사(CloudTrail Data Events) ✅ / Security Hub·Config는 의도적 제외(§6) / IAM Access Analyzer·MFA강제 | 🔄 진행 중 |
| **자동화(Auto-Remediation)** | EventBridge→Lambda 자동 격리(필살기) | 📋 계획 |

### 남은 작업 (순서)
- ~~**B**: audio 버킷 CloudTrail Data Events (생체정보 객체 감사)~~ ✅ 완료 (uploads/ 한정)
- ~~**C**: AWS Security Hub(FSBP) + Config(스코핑)~~ ❌ 의도적 제외 (§6 — 비용 대비 효과 + IaC/GuardDuty로 대체)
- **D**: IAM 비밀번호 정책 + MFA 강제 (팀 IAM 사용자 MFA 설정 완료 → 적용 가능, CLI 액세스키 주의)
- **필살기 A**: 자동 대응 — SG 0.0.0.0/0 개방 시 Lambda가 자동 회수+알림(self-healing)
- **필살기 B**: IAM Access Analyzer(무료) — 외부 노출 자동 탐지 + 최소권한 정책 생성

### 의도적으로 제외 (판단력)
Shield Advanced(월 $3,000) / Macie(음성엔 효과 제한+고비용) / SIEM(SOC용 고비용) / GuardDuty EKS·Malware 플랜(불필요·과금) — **비용 대비 효과 낮아 제외, 프로덕션 확장 시 재검토.**

### 이미 갖춘 차별점(필살기)
- 비용 의식적 설계(EventBridge vs 풀스트리밍, S3+Athena vs CloudWatch) — 근거를 설명할 수 있음
- ALB origin bypass 차단 / GuardDuty 알림 배선+severity 필터 / KMS lockout footgun 회피 단계적 적용