
# 직접 graceful shutdown의 동작 테스트

### 방법 1. 대기 상태(Idle)에서의 Graceful Shutdown 테스트 (가장 간단함)

워커가 SQS 메시지를 받기 위해 롱 폴링(20초 대기)을 하고 있을 때 시그널을 주어 즉시 안전하게 종료되는지 테스트합니다.

#### 1) 실행 중인 워커 태스크 ID 확인
터미널에서 아래 명령어를 실행하여 현재 실행 중인 free-worker 태스크 ID를 조회합니다.
```bash
aws ecs list-tasks --cluster securevoice-dev-cluster --service-name securevoice-dev-free-worker-service --query "taskArns[]" --output text
```
* 출력 예시: `arn:aws:ecs:ap-northeast-2:455535733131:task/securevoice-dev-cluster/711a345ad4484d178cdf017559a73e10`
* 마지막 슬래시 뒤의 문자열(`711a345ad4484d178cdf017559a73e10` 부분)이 **태스크 ID**입니다.

#### 2) 태스크 중지 (SIGTERM 시그널 전송)
위에서 조회한 태스크 ID를 넣고 중지 명령을 내립니다. (ECS가 태스크에 SIGTERM 시그널을 보냅니다)
```bash
aws ecs stop-task --cluster securevoice-dev-cluster --task <태스크_ID> --reason "User testing graceful shutdown"
```

#### 3) CloudWatch 로그 확인
태스크가 안전하게 종료되었는지 로그 그룹 `/ecs/securevoice-dev-free-worker`에서 해당 태스크 ID 이름의 로그 스트림을 확인하거나 아래 명령어로 로그를 조회합니다.
```bash
aws logs get-log-events --log-group-name /ecs/securevoice-dev-free-worker --log-stream-name free-worker/free-worker/<태스크_ID> --query "events[-2:].message"
```
* **성공 시 출력 로그:**
  ```json
  [
      "[GRACEFUL] Signal 15 received. Requesting graceful shutdown...",
      "[GRACEFUL] Shutdown requested and no messages received. Exiting worker gracefully."
  ]
  ```

---

### 방법 2. 작업 처리 중(Busy)에서의 Graceful Shutdown 테스트

워커가 실제 AI 추론 작업을 처리하고 있을 때 종료 시그널을 받더라도, **현재 진행 중인 작업을 끝까지 완수하고 SQS 메시지를 정상 삭제한 후 종료**되는지 검증합니다.

#### 1) 테스트용 부하 발생 준비 (Locust 또는 API 요청)
1. 회원가입/로그인 후 음성 분석 요청을 보냅니다 (또는 Locust 부하를 1개만 실행합니다).
2. 요청을 보내자마자 데이터베이스에서 해당 `request_id`의 상태가 `PROCESSING`으로 변경된 것을 확인합니다.

#### 2) 작업 도중 태스크 중지 명령 실행
워커 로그에 `[REQUEST][...] received...` 또는 `db status=PROCESSING`이 뜨는 순간, 즉시 중지 명령을 내립니다.
```bash
aws ecs stop-task --cluster securevoice-dev-cluster --task <현재_작업중인_태스크_ID>
```

#### 3) 최종 결과 검증
* **데이터베이스 확인**: 중지 명령을 내렸음에도 작업이 끝까지 수행되어 최종 상태가 `SUCCEEDED`로 정상 완료되었는지 확인합니다.
* **SQS 대기열 확인**: 메시지가 삭제되지 않고 남아있으면 중복 처리가 발생하는데, 정상적으로 처리 후 삭제되어 SQS 대기열(`free-queue`)에 메시지가 남아있지 않아야 합니다.
* **로그 확인**: 작업 완료 로그 뒤에 다음과 같이 출력되며 종료됩니다.
  ```plain
  [WORKER][...] db status=SUCCEEDED
  [WORKER][...] sqs message deleted
  [GRACEFUL] Shutdown requested before receive_messages. Exiting worker gracefully.
  ```

편하신 방법으로 한 번 실행해 보시기 바랍니다!