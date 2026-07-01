# observability

이 디렉터리는 전체 시스템 인프라 및 애플리케이션 서비스의 동작 상태, 리소스 사용량, 성능 통계 등을 한눈에 통합 모니터링할 수 있는 AWS CloudWatch Dashboard를 구성합니다.

## 1. 왜 필요한가? (Why)
분산된 마이크로서비스 환경에서는 인프라의 장애나 특정 서비스의 지연 원인을 개별적으로 파악하기 매우 어렵습니다.
* **통합 가시성(Observability) 확보**: ECS CPU/메모리 부하, 로드밸런서 요청/응답 통계, SQS 대기량 등을 한 곳에 시각화하여 상태를 실시간 감시해야 합니다.
* **장애 선제 대응**: 서비스 성능 저하나 SQS 큐의 누적 정체 등을 사전에 모니터링하여 병목 현상에 신속하게 대처하고 문제의 원인을 다각도로 분석(AIOps)할 수 있습니다.

## 2. 무슨 기능을 하는가? (What)
주요 지표들을 한눈에 보기 위한 통합 CloudWatch 대시보드 리소스를 관리합니다.
* **CloudWatch Dashboard (`aws_cloudwatch_dashboard.aiops`)**:
  * `securevoice-aiops-observability`라는 이름의 커스텀 대시보드를 생성합니다.
* **대시보드 레이아웃 템플릿 (`dashboards/securevoice-aiops-dashboard.json`)**:
  * 위젯 배치 및 모니터링할 지표들의 상세 구성(메트릭 쿼리, 시각화 형태 등)이 JSON 형식으로 정의되어 있습니다. 이 설정을 로드하여 CloudWatch 콘솔에 렌더링합니다.

## 3. 어떻게 사용하는가? (How)
모든 주요 인프라가 배포된 후 사용합니다.

1. **디렉터리 이동**
   ```bash
   cd observability
   ```

2. **초기화 및 배포**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **모니터링 활용**
   * 배포가 완료되면 AWS Management Console에 로그인합니다.
   * **CloudWatch > Dashboards (대시보드)** 메뉴로 이동하여 `securevoice-aiops-observability` 대시보드를 엽니다.
   * 서비스 부하 상태, ECS 활성 태스크 수, SQS 메시지 추이 등을 실시간으로 관찰할 수 있습니다.
