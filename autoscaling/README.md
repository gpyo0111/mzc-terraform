# autoscaling

이 디렉터리는 시스템 부하량 또는 특정 스케줄에 맞추어 ECS Fargate 컨테이너 서비스의 태스크(Task) 개수를 동적으로 자동 제어하는 Auto Scaling 규칙을 구성합니다.

## 1. 왜 필요한가? (Why)
클라우드 환경의 큰 장점은 인프라 자원을 유동적으로 사용하고 사용한 만큼만 비용을 지불하는 것입니다.
* **비용 최적화**: 분석 요청량이 적거나 새벽 시간대 등 시스템 부하가 낮은 상황에서는 컨테이너 개수를 최소화하여 불필요한 인프라 유지 비용을 줄여야 합니다.
* **가용성 및 성능 유지**: 갑작스럽게 대량의 음성 처리 요청이 유입되거나 트래픽이 몰리는 비즈니스 시간대에 컨테이너 개수를 자동으로 확장(Scale-out)하여 처리 지연을 방지해야 합니다.
* **비즈니스 특성에 따른 리소스 격리**: Free 요금제와 Paid 요금제 사용자의 컨테이너(Worker)를 격리 배포하고, Paid 요금제 사용자의 대기열을 더 빠르고 크게 확장할 수 있도록 차별화된 스케일링 규칙을 정의합니다.

## 2. 무슨 기능을 하는가? (What)
ECS 서비스의 태스크 개수를 대상으로 한 애플리케이션 오토스케일링(App Auto Scaling)을 정의합니다.
* **Auto Scaling Target 설정 (`main.tf`)**:
  * Free Worker 서비스(`free_worker_service_name`)는 1~2개 범위에서 오토스케일링이 적용되도록 제한합니다.
  * Paid Worker 서비스(`paid_worker_service_name`)는 1~10개 범위에서 유연하게 오토스케일링이 이루어지도록 설정합니다.
* **SQS 기반 동적 스케일링 (`sqs-scaling.tf`)**:
  * 비동기 처리를 담당하는 SQS 큐의 대기 중인 메시지 수(CloudWatch 지표 `ApproximateNumberOfMessagesVisible`)를 실시간 감시합니다.
  * 대기 메시지가 급증할 경우, 단계별 스케일링 정책(Step Scaling Policy)에 따라 ECS Worker 컨테이너 태스크를 즉각 확장(Scale-out)하여 빠른 처리를 보장합니다.
* **스케줄 기반 스케일링 (`scheduled-scaling.tf`)**:
  * 매일 오전(예: 업무 시작 시간인 09:00)에 컨테이너 최소 가동 대수를 보장하여 트래픽 유입에 대비(Scale-out)하고, 야간(예: 18:00)에는 최소 대수를 줄여 자원을 회수(Scale-in)하는 주기적 정책을 정의합니다.

## 3. 어떻게 사용하는가? (How)
`20-runtime` 단계 배포가 완료된 상태에서 사용합니다.

1. **디렉터리 이동**
   ```bash
   cd autoscaling
   ```

2. **초기화 및 배포**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **작동 확인**
   * 대량의 테스트 요청(부하 테스트 등)을 SQS 큐에 적재한 뒤 AWS ECS 콘솔에서 각 Worker 서비스의 Desired Count(원하는 개수)가 설정한 정책에 맞추어 점진적으로 늘어나는지 모니터링합니다.
