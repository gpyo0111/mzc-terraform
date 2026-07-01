# 10-persistent

이 디렉터리는 시스템에서 지속적으로 유지되어야 하는 데이터 저장소, 관계형 데이터베이스(RDS), 그리고 이를 안전하게 연결하기 위한 Bastion EC2와 Secrets Manager 등의 영구 백엔드 인프라를 구성합니다.

## 1. 왜 필요한가? (Why)
애플리케이션은 무상태(Stateless)로 관리되어 컨테이너가 교체되더라도 유실되지 않고 안전하게 보존되어야 하는 영구 데이터가 존재합니다.
* **데이터 영속성 보장**: 사용자 정보, 음성 처리 결과 등의 관계형 데이터와 대용량 AI 음성 모델 파일은 서비스 수명 주기와 무관하게 안전하게 격리되어 보존되어야 합니다.
* **네트워크 보안 및 접근 제어**: 데이터베이스는 외부 위협으로부터 가장 철저히 격리되어야 하므로, 프라이빗 서브넷에 배치하고 Bastion EC2나 RDS Proxy 등을 통해서만 제한적으로 접근할 수 있도록 보안 터널을 확보해야 합니다.
* **비밀번호 관리 최적화**: DB 비밀번호나 JWT 서명 키 등을 테라폼 코드나 로컬 설정 파일에 평문으로 적지 않고, AWS Secrets Manager를 통해 암호화하여 저장하고 필요할 때 동적으로 읽어오도록 구성해야 합니다.

## 2. 무슨 기능을 하는가? (What)
보안과 고가용성이 보장된 영구 데이터 스토리지 환경을 구성합니다.
* **AI Model S3 Bucket (`aws_s3_bucket.model`)**:
  * 음성 합성/변환에 사용될 AI 모델 파일을 저장합니다.
  * KMS 마스터 키를 활용하여 저장 데이터를 강제 암호화하고 퍼블릭 접근을 완전히 차단합니다.
* **RDS MySQL Instance (`aws_db_instance.mysql`)**:
  * 관계형 데이터를 관리하기 위한 MySQL 데이터베이스 인스턴스입니다.
  * **Multi-AZ 활성화**: 주 가용영역 장애 시 예비 가용영역으로 자동 장애 조치(Failover)되어 서비스 가동성을 유지합니다.
  * **보안그룹 적용**: 오직 프라이빗 앱 서브넷 및 Bastion SG, RDS Proxy SG 대역에서의 3306 포트 통신만 수신합니다.
  * **비밀번호 자동 관리**: 최초 마스터 비밀번호는 테라폼 대신 AWS Secrets Manager에서 연동하여 관리합니다.
  * **삭제 방지 및 자동 백급**: 백업 기간 7일을 보존하며 실수로 데이터베이스가 지워지는 것을 원천 방지하기 위해 `deletion_protection = true` 및 `prevent_destroy` 생명 주기를 가집니다.
* **RDS Proxy (`rds-proxy.tf`)**:
  * 컨테이너 인프라(ECS)의 잦은 스케일 아웃/인으로 인해 급증할 수 있는 커넥션 개수를 풀링하여 데이터베이스 부하를 줄입니다.
* **Bastion DB Admin EC2 (`db-admin-ec2.tf`)**:
  * 프라이빗 서브넷에 격리된 RDS 데이터베이스에 관리자가 안전하게 SSH 터널링을 통해 쿼리를 실행하거나 유지보수 작업을 할 수 있도록 지원하는 퍼블릭 영역의 EC2 인스턴스입니다.
* **DB Bootstrap Script (`scripts/bootstrap-db-app-user.sh`)**:
  * RDS 생성이 완료된 후 애플리케이션 서비스가 사용할 DB 유저 및 권한 설정, 기본 스키마(DDL) 배포를 자동화하기 위해 Bastion 내부에서 동작하는 스크립트입니다.
* **AWS Secrets Manager**:
  * `db-password` 시크릿 및 `jwt-secret-key` 시크릿의 껍데기를 만들어 안전한 키 보관 환경을 갖춥니다.

## 3. 어떻게 사용하는가? (How)
`00-network` 단계 배포가 완료된 후에 사용합니다.

1. **디렉터리 이동**
   ```bash
   cd 10-persistent
   ```

2. **초기화 및 배포**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **데이터베이스 초기화 (Bootstrapping)**
   * RDS와 Bastion EC2 배포가 완료되면, Bastion EC2에 접속하여 `scripts/bootstrap-db-app-user.sh`를 구동합니다.
   * 이 작업으로 애플리케이션(ECS 서비스)이 사용할 전용 데이터베이스 사용자 및 패스워드를 Secrets Manager에 등록하고, 스키마 생성을 완료합니다.
