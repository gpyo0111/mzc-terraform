# 00-bootstrap-state

이 디렉터리는 테라폼의 상태 파일(State File)을 안전하고 영구적으로 보존하기 위해 원격 백엔드(Remote Backend)로 활용할 AWS 리소스를 구성합니다.

## 1. 왜 필요한가? (Why)
테라폼은 인프라의 상태 정보를 `terraform.tfstate`라는 상태 파일에 저장하여 관리합니다. 
기본적으로 이 파일은 로컬에 저장되지만, 협업 환경이나 CI/CD 환경에서는 다음과 같은 문제점이 발생합니다.
* **상태 파일 불일치**: 로컬에서 각자 배포할 경우 다른 사용자의 변경 내역을 덮어쓸 수 있습니다.
* **민감 정보 노출**: 상태 파일 내에 암호화 키, 패스워드 등 민감 정보가 일반 텍스트로 보관될 수 있어 공유에 취약합니다.
* **동시 수정 충돌**: 여러 사람이 동시에 테라폼 명령을 실행하면 상태 파일이 손상될 수 있습니다.

이를 해결하기 위해 AWS S3(상태 파일 영구 저장 및 암호화)와 DynamoDB(동시 실행 방지를 위한 Lock 관리)를 사용하여 안전한 협업 구조(원격 백엔드)를 우선 구축해야 합니다.

## 2. 무슨 기능을 하는가? (What)
이 단계는 테라폼을 적용할 AWS 계정에 초기 1회 실행되는 부트스트랩 리소스를 정의합니다.
* **Terraform State S3 Bucket (`aws_s3_bucket.terraform_state`)**:
  * 상태 파일을 원격으로 안전하게 저장하기 위한 버킷입니다.
  * **버전 관리(Versioning) 활성화**: 상태 파일이 업데이트될 때마다 이전 기록을 유지하여 실수로 덮어쓰거나 지워졌을 때 복구가 가능합니다.
  * **SSE 암호화(`AES256`) 적용**: 버킷에 저장되는 모든 상태 파일을 암호화하여 저장합니다.
  * **퍼블릭 액세스 전면 차단(Public Access Block)**: 상태 파일에 인터넷을 통한 비인가 접근을 원천적으로 차단합니다.
  * **삭제 방지(`prevent_destroy`)**: 인프라 삭제 명령(`terraform destroy`) 시 실수로 이 버킷이 삭제되는 것을 방지합니다.
* **DynamoDB Lock Table (`aws_dynamodb_table.terraform_lock`)**:
  * 테라폼 실행 중 동시 수정 충돌을 막기 위해 락킹(Locking)을 적용하기 위한 테이블입니다.
  * `LockID`라는 문자열 해시 키 속성을 사용합니다.
  * `prevent_destroy` 생명 주기를 지정하여 삭제 사고를 방지합니다.

## 3. 어떻게 사용하는가? (How)
해당 디렉터리는 리포지토리의 테라폼을 적용하기 위해 **가장 먼저 실행**되어야 합니다.

1. **디렉터리 이동**
   ```bash
   cd 00-bootstrap-state
   ```

2. **초기화 및 실행 계획 확인**
   ```bash
   terraform init
   terraform plan -var-file="terraform.tfvars"
   ```
   *(주의: 프로젝트 정보, Account ID, 리전 등의 변수가 포함된 `terraform.tfvars` 파일이 존재해야 합니다.)*

3. **배포 적용**
   ```bash
   terraform apply -var-file="terraform.tfvars"
   ```

4. **백엔드 구성 정보 적용**
   * 배포 완료 후 출력되는 S3 버킷명과 DynamoDB 테이블명을 복사합니다.
   * `00-network`, `10-persistent`, `20-runtime` 등 다른 모든 테라폼 하위 폴더의 `backend.tf` 파일 내에 해당하는 S3 버킷과 DynamoDB 테이블명을 기입하여 원격 백엔드를 연동합니다.
