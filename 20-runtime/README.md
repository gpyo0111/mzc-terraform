# 20-runtime

이 디렉터리는 ECS API 서비스, AI Worker 컨테이너, CI/CD 배포를 위한 Jenkins 인스턴스, 그리고 비동기 메시지 큐 등 애플리케이션 서비스를 구동하고 통신하기 위한 런타임 환경 인프라를 구성합니다.

## 1. 왜 필요한가? (Why)
구축된 가상 네트워크(VPC)와 데이터베이스 등의 지속성 인프라(Persistent) 상에서 실제 비즈니스 로직을 처리하는 컨테이너 및 부속 서비스를 배포하여 엔드포인트를 제공하기 위해 필요합니다.
* **마이크로서비스 인프라 구동**: 트래픽을 처리하는 API 서버와 CPU 연산 위주의 AI 분석 처리를 분리하고, ECS Fargate 컨테이너 기반으로 동작하도록 구성하여 유연성과 가동성을 확보합니다.
* **비동기 이벤트 기반 아키텍처**: 음성 처리 등 대용량 데이터 연산이 필요한 작업을 API 요청과 분리하여 SQS 메시지 큐를 통해 AI Worker로 비동기식 위임 처리합니다.
* **CI/CD 파이프라인 연동**: 리포지토리의 소스 코드를 자동으로 빌드하고 배포하기 위해 Jenkins 인스턴스를 구축합니다.

## 2. 무슨 기능을 하는가? (What)
서비스 런타임과 네트워크 부속 장치 및 IAM 보안 요소를 배포합니다.
* **ECS Cluster & Fargate Services (`ecs.tf`)**:
  * **ECS Cluster**: Fargate를 활용해 서버 관리 없이 컨테이너를 가동합니다.
  * **API Service (`voice-api-service`)**: 웹 클라이언트 및 API 요청을 처리하는 컨테이너 서비스입니다.
  * **Worker Service (`nes2net-ai-worker`)**: SQS 큐로부터 작업을 수신하여 AI 모델 추론을 수행하는 비동기 처리용 컨테이너 서비스입니다.
* **Application Load Balancer (`alb.tf`)**:
  * 외부(인터넷)에서 Public 서브넷의 ALB로 들어오는 HTTP 요청을 안전하게 라우팅하여 Private 서브넷의 API ECS 컨테이너 태스크로 균등하게 분산시킵니다.
* **SQS 및 DLQ (`sqs.tf`, `dlq_alarm.tf`)**:
  * API 서버와 Worker 컨테이너 간의 느슨한 결합(Decoupling)을 위한 대기열(Queue)을 생성합니다.
  * 처리 실패가 누적된 유해 메시지를 별도로 모으는 DLQ(Dead Letter Queue)를 두고, 실패 상태를 빠르게 감지하기 위한 CloudWatch Alarm 경보를 구성합니다.
* **Jenkins Server (`jenkins.tf`)**:
  * CI/CD 파이프라인 구동을 위한 전용 Jenkins EC2 인스턴스를 Public 영역에 구성하고 보안그룹을 통해 제한된 개발 주소에서만 접근할 수 있게 설정합니다.
* **VPC Endpoints (`endpoints.tf`)**:
  * 프라이빗 영역 내의 ECS Fargate 서비스가 인터넷 게이트웨이를 경유하지 않고 AWS VPC Endpoint를 통해 SQS, S3, Secrets Manager, ECR과 비공개 내부 망 통신을 수행할 수 있게 하여 보안 수준을 높입니다.
* **IAM Roles (`iam.tf`)**:
  * ECS 태스크 실행 역할(Task Execution Role) 및 태스크 역할(Task Role) 등, 리소스가 ECR 이미지 다운로드, CloudWatch 로그 기록, Secrets Manager 접근 등을 할 수 있는 최소 권한을 부여합니다.

## 3. 어떻게 사용하는가? (How)
`10-persistent` 인프라 배포가 완료되었고 ECR에 최신 API 및 Worker 도커 이미지가 푸시된 상태에서 사용합니다.

1. **디렉터리 이동**
   ```bash
   cd 20-runtime
   ```

2. **초기화 및 배포**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **엔드포인트 검증**
   * 배포 완료 후 ALB의 DNS 주소가 출력(`outputs.tf`)됩니다. 해당 DNS 주소를 이용해 API 동작을 점검하거나 클라이언트 환경 설정에 적용합니다.
