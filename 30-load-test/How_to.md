# Locust 부하 테스트 가이드 (로컬 실행)

개발용 API 서버 및 SQS 워커의 성능과 오토스케일링을 모니터링하기 위해 로컬 PC에서 Locust를 실행하여 부하를 주는 방식입니다.
이 가이드는 **무료 플랜(Free Queue)** 검증 및 **유료 플랜(Paid Queue)** 검증을 별도로 다룰 수 있도록 구성되어 있습니다.

---

## 1. 사전 준비 (유료 플랜 테스트용 계정 생성 및 등업)

유료 플랜(`paid-worker-service`)을 테스트하려면 `paid` 역할을 가진 데이터베이스 계정이 필요합니다. 아래 파이썬 자동화 스크립트를 통해 API 회원가입 및 DB 등업 처리를 한 번에 완료할 수 있습니다.

```bash
# 30-load-test 디렉터리로 이동
cd c:/Users/ANN/mzc-final-project/mzc-terraform/30-load-test

# boto3, requests 등의 의존성이 설치되어 있어야 합니다.
pip install boto3 requests

# 유료 계정 생성 및 DB 등업 스크립트 실행
python promote_paid_user.py
```
* **결과**: `paid@bank-b.com` 계정이 생성되고 역할이 `paid`로 승격됩니다. 이 계정은 `locustfile_paid.py`에서 부하 요청을 전송할 때 사용됩니다.

---

## 2. 무료 플랜 부하 테스트 (free-worker-service 검증)

로그인하지 않은 GuestUser 및 일반 회원가입 유저를 모사하여 `free-queue`에 부하를 집중시킵니다.

1. **무료 전용 Locust 실행 (포트 8088 사용 및 호스트 지정)**:
   ```bash
   locust -f locustfile_free.py --web-port 8088 --host http://securevoice-dev-api-alb-537121418.ap-northeast-2.elb.amazonaws.com
   ```
2. **웹 브라우저 대시보드 접속**:
   * 👉 **`http://localhost:8088`**
3. **설정값 입력 후 시작**:
   * **Number of users**: `200`
   * **Spawn rate**: `5`
   * **[Start swarming]** 클릭

---

## 3. 유료 플랜 부하 테스트 (paid-worker-service 검증)

사전에 등업된 `paid@bank-b.com` 유료 계정 토큰을 활용하여 `paid-queue`와 `paid-worker-service` 인프라를 집중 검증합니다.

1. **유료 전용 Locust 실행 (포트 8090 사용 및 호스트 지정)**:
   ```bash
   locust -f locustfile_paid.py --web-port 8090 --host http://securevoice-dev-api-alb-537121418.ap-northeast-2.elb.amazonaws.com
   ```
2. **웹 브라우저 대시보드 접속**:
   * 👉 **`http://localhost:8090`**
3. **설정값 입력 후 시작**:
   * **Number of users**: `50` (또는 유료 워커 규모에 맞춘 임의의 수)
   * **Spawn rate**: `2`
   * **[Start swarming]** 클릭




