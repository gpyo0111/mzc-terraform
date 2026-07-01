# 인프라 복구 및 안정성 검증 모듈 (09_recovery_stability)

이 모듈은 SecureVoice 서비스의 고가용성(High Availability) 및 장애 대응(Fault Tolerance) 능력을 검증하기 위해 다양한 장애 케이스(카오스 시나리오)를 인위적으로 주입하고, 시스템이 이를 자동으로 복구하거나 무중단 상태를 유지하는지 검증하는 모듈입니다.

---

## 1. 검증 대상 및 테스트 시나리오 요약

이 모듈은 총 9가지의 장애 복구 시나리오를 통합하여 검증합니다.

| ID | 테스트 케이스명 | 설명 | 복구 확인 기준 (Pass Criteria) |
|:---|:---|:---|:---|
| **TC-REC-01** | ECS Task 강제 중단 | API ECS Task를 임의로 중단시킵니다. | ECS가 새 Task를 자동 실행하여 Desired Count 복원 및 60s 내 API 헬스체크 정상화 |
| **TC-REC-02** | Worker 부분 장애 | Worker Task의 desiredCount를 0으로 다운시킵니다. | Worker 부재 상태에서도 API 서버는 무중단 정상 응답 (HTTP 200) |
| **TC-REC-03** | SQS 메시지 보존 | Worker가 정지된 동안 메시지를 발행합니다. | Worker 정지 중 메시지 유실이 없어야 하며, Worker 복구 후 60s 내 정상 소비 |
| **TC-REC-04** | RDS 재부팅 및 재연결 | RDS MySQL 인스턴스를 강제 재부팅합니다. | DB 재가동 완료 후 API가 커넥션 풀을 정상적으로 자동 복구 및 재연결 완료 |
| **TC-REC-05** | 네트워크 분리 (Partition) | RDS의 인바운드 3306 포트 규칙을 임시 제거합니다. | 격리 중 API Health가 실패하며, 보안그룹 복구 후 API와 DB가 자동으로 정상 복귀 |
| **TC-REC-06** | 데이터 손상 (Corruption) | S3 오디오 버킷에 깨진 임시 파일을 업로드합니다. | 잘못된 포맷 요청에 예외 처리가 발생해도 전체 가용성(API 헬스)은 안전하게 유지 |
| **TC-REC-07** | 지연 주입 (Latency Injection) | RDS DB에 `SELECT SLEEP` 지연 쿼리를 주입합니다. | 지연 쿼리 수행 상황에서도 API가 타임아웃을 안전하게 제어하고 가용성을 유지 |
| **TC-REC-08** | 자원 고갈 (Exhaustion) | ECS Task 내부에 강제로 CPU 부하 명령을 주입합니다. | CPU 100% 임시 부하 상태에서도 API 가용성(Health Check)이 차단되지 않고 유지 |
| **TC-REC-09** | 순차 재시작 (Rolling Deploy) | API 서비스의 강제 신규 배포(Rolling)를 유발합니다. | 롤링 배포가 진행되는 동안 API Health Check의 지속적인 호출 성공률이 98% 이상 유지 |

---

## 2. 사전 준비사항

테스트 스크립트 실행을 위해 다음의 준비사항이 필요합니다.

1. **Python 라이브러리 설치**:
   ```bash
   pip install pymysql requests boto3
   ```
2. **AWS 자격증명 설정**:
   테스트 대상 리소스(ECS, RDS, EC2, S3, Secrets Manager) 조회가 가능한 AWS profile 권한이 필요합니다.
   ```bash
   # 기본적으로 config.sh에 설정된 프로필(bya) 또는 AWS_PROFILE 환경변수를 참조합니다.
   export AWS_PROFILE="bya"
   aws sts get-caller-identity
   ```
3. **환경변수 확인**:
   `mzc-terraform/40-infra-quality-test/config.sh` 파일에 정의된 리소스 식별자(ECS 클러스터명, SQS URL, RDS 식별자 등)가 현재 배포된 리소스 정보와 일치하는지 확인합니다.

---

## 3. 사용법

### 1) 단독 실행
`09_recovery_stability` 모듈 내 개별 쉘 스크립트(`run.sh`)를 실행하여 복구 안정성 테스트만을 단독으로 수행할 수 있습니다.
```bash
# 모듈 디렉터리로 이동
cd mzc-terraform/40-infra-quality-test/09_recovery_stability

# 복구 안정성 검증 테스트 실행
bash run.sh
```

### 2) 통합 실행 (run_all.sh 연동)
상위 디렉터리(`40-infra-quality-test`)에서 인프라 품질 테스트 전체를 돌릴 때 연동하여 실행합니다.
```bash
# 상위 디렉터리로 이동
cd mzc-terraform/40-infra-quality-test

# 전체 인프라 테스트 진행 (09번 모듈 포함)
bash run_all.sh
```

---

## 💡 모듈 상세 가이드 (Why, What, How)

### 왜 필요한가? (Why)
* **예기치 못한 장애 복구력 검증**: 단순히 테라폼 설정이 잘 되었는지 정적으로 검사하는 것을 넘어, 하드웨어 크래시, 네트워크 장애, 데이터 손상, 리소스 고갈 등 실서비스에서 발생할 수 있는 주요 동적 예외 시나리오 상황에서 **시스템이 자동으로 복구되는지 검증**하기 위해 필요합니다.
* **커넥션 풀 및 재연결 안정성 보증**: RDS Proxy, Secrets Manager 연동 환경 하에서 RDS 재부팅이나 네트워크 일시 차단 후 애플리케이션의 커넥션 풀이 수동 개입 없이 자동으로 복구되는지 확인하여 가용성을 보장합니다.

### 무슨 기능을 하는가? (What)
* **AWS SDK(boto3) 기반 장애 시뮬레이션**: 외부 장애 전용 에이전트 설치 없이 AWS API를 사용해 태스크 중지, 보안그룹 편집, RDS 재부팅, ECS 명령어 전송(`execute-command`) 등으로 실제 인프라 장애를 안전하게 시뮬레이션합니다.
* **실시간 복구 모니터링**: 장애를 주입한 직후 2초 간격으로 API 헬스체크 및 SQS 대기열 상태 등을 추적 관찰하여 복구 속도와 가용성 성공률을 측정하고 PASS/FAIL 여부를 보고합니다.

### 어떻게 사용하는가? (How)
* **결과 분석**: 테스트가 완료되면 각 TC 번호별로 소요 시간 및 성공 여부가 CLI에 시각적으로 표시됩니다. 만약 `[FAIL]` 항목이 발생하는 경우, 애플리케이션의 DB 재연결 풀링 설정이나 ECS 타임아웃, SQS Visibility Timeout 파라미터 튜닝이 요구되는 신호입니다.
* **경고**: 해당 테스트는 리소스의 가용 용량 조정(desiredCount=0), RDS 재부팅, 보안그룹 임시 수정 등을 동반하므로 **운영(Production) 환경에서는 절대 실행해서는 안 되며**, 오직 개발(Dev) 및 검증(Staging) 환경에서만 테스트 용도로 사용해야 합니다.
