# 00-network

이 디렉터리는 전체 시스템 인프라의 뼈대가 되는 기본 가상 네트워크(VPC) 환경을 테라폼으로 구축합니다.

## 1. 왜 필요한가? (Why)
클라우드 인프라의 모든 리소스(컨테이너, 데이터베이스, 로드밸런서 등)는 안전하게 통신하고 외부 침입으로부터 보호받아야 합니다.
* **보안 영역 분리**: 외부 인터넷 접근이 필요한 리소스(ALB, Bastion)와 격리되어야 하는 리소스(ECS App 컨테이너, RDS 데이터베이스)의 영역을 나누어야 합니다.
* **네트워크 경로 제어**: 프라이빗 네트워크 내의 컨테이너가 패키지 업데이트 등을 위해 외부 인터넷과 통신할 때 NAT 게이트웨이를 경유하도록 제어합니다.
* **고가용성 보장**: 단일 IDC(가용영역) 장애에 대비하여 최소 2개 이상의 가용영역(AZ)에 걸쳐 서브넷 구조를 설계해야 합니다.

## 2. 무슨 기능을 하는가? (What)
AWS VPC 환경 및 라우팅 설정을 생성하여 후속 테라폼 단계에서 참조할 수 있게 정의합니다.
* **VPC (`aws_vpc.main`)**: 가상 네트워크 영역을 생성합니다. DNS Hostname 및 DNS Support를 활성화합니다.
* **인터넷 게이트웨이 (`aws_internet_gateway.main`)**: VPC 내부의 퍼블릭 서브넷 리소스들이 외부 인터넷과 양방향 통신할 수 있게 합니다.
* **서브넷 (Subnets)**: 고가용성 배치를 위해 가용영역 2개(AZ-a, AZ-c)에 다중 배치합니다.
  * **Public Subnets (`public_a`, `public_c`)**: 로드밸런서(ALB) 및 Bastion Host 등 인터넷 접근이 필요한 리소스가 위치합니다.
  * **Private App Subnets (`private_app_a`, `private_app_c`)**: ECS API/Worker 애플리케이션 컨테이너가 위치하며 외부에서 직접 접근할 수 없습니다.
  * **Private Data Subnets (`private_data_a`, `private_data_c`)**: RDS 데이터베이스가 위치하며, 외부 및 퍼블릭 영역과도 직접 연결되지 않고 오직 App 영역하고만 통신하도록 격리됩니다.
* **라우팅 테이블 및 연결 (Route Tables)**:
  * **Public RT**: 인터넷 게이트웨이(`0.0.0.0/0 -> IGW`)로 향하는 경로를 설정하여 Public 서브넷에 연결합니다.
  * **Private App RT & Private Data RT**: 프라이빗 서브넷들에 대해 외부 인터넷 통신 경로를 제어하고 격리 상태를 유지합니다.

## 3. 어떻게 사용하는가? (How)
`00-bootstrap-state` 배포가 끝난 후에 실행합니다.

1. **디렉터리 이동**
   ```bash
   cd 00-network
   ```

2. **초기화 및 배포**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **출력 변수 활용**
   * 배포 완료 후 VPC ID 및 각 서브넷 ID 목록이 출력(`outputs.tf`)됩니다.
   * `10-persistent` 및 `20-runtime` 단계에서 테라폼 리모트 스테이트(`terraform_remote_state`) 데이터 소스를 통해 이 네트워크 정보들을 가져와 참조하게 됩니다.
