# DB Account Bootstrap Runbook

이 문서는 RDS master 계정과 ECS app 계정(`mzmt_app`)을 분리하기 위해 바뀐 Terraform 코드와, 팀원이 실제로 적용/운영할 절차를 정리한다.

## 0. 원래 흐름과 현재 흐름

### 원래 흐름

기존 구조는 대략 아래 흐름이었다.

```text
관리자/팀원
 -> 10-persistent/terraform.tfvars에 db_password 입력
 -> 10-persistent terraform apply
 -> RDS 생성 시 username/password를 Terraform이 전달
 -> 같은 비밀번호를 Secrets Manager secret version에도 저장
 -> 10-persistent output에서 RDS endpoint와 secret ARN 확인
 -> 20-runtime/terraform.tfvars에 endpoint/secret ARN/db_user를 복사
 -> 20-runtime terraform apply
 -> ECS task가 복사된 값으로 DB 접속
```

이 방식의 문제:

- DB password 값이 Terraform 입력값과 state에 남을 수 있다.
- 관리자 계정과 앱 계정의 역할 분리가 약하다.
- `10-persistent` output을 `20-runtime/terraform.tfvars`에 사람이 복사해야 한다.
- 오래된 endpoint/secret ARN을 잘못 넣을 수 있다.

### 현재 흐름

현재 구조는 아래처럼 바뀌었다.

```text
10-persistent terraform apply
 -> 00-network S3 remote state에서 VPC/subnet 정보를 읽음
 -> RDS 생성
 -> RDS master password는 RDS-managed Secrets Manager가 생성/관리
 -> app password용 Secrets Manager secret 껍데기만 생성
 -> DB admin EC2, IAM, SSM bootstrap document 생성
 -> Secrets Manager VPC endpoint 생성
 -> 10-persistent output을 S3 state에 저장

SSM bootstrap 1회 실행
 -> 사용자가 10-persistent output에서 ARN/endpoint/name만 읽음
 -> aws ssm send-command 실행
 -> SSM이 DB admin EC2에서 bootstrap script 실행
 -> script가 master secret을 Secrets Manager에서 읽음
 -> script가 app password를 생성해서 app secret에 저장
 -> script가 master 계정으로 RDS에 접속
 -> script가 MySQL 내부에 mzmt_app 생성
 -> script가 mzmt_db 권한 부여

20-runtime terraform apply
 -> 00-network S3 remote state에서 VPC/subnet 정보를 읽음
 -> 10-persistent S3 remote state에서 RDS endpoint, app username, secret ARN을 읽음
 -> ECS task definition에 DB_HOST/DB_USER/DB_NAME/DB_PASSWORD secret 연결
 -> ECS task execution role에 app/JWT secret 읽기 권한 부여
```

중요한 점:

- ECS 컨테이너가 S3 state를 읽는 것이 아니다.
- SSM bootstrap script가 S3 state를 읽는 것도 아니다.
- S3 state를 읽는 주체는 Terraform이다.
- `terraform output`으로 확인하는 값은 비밀번호가 아니라 ARN, endpoint, 이름이다.
- 실제 app password 값은 bootstrap script가 Secrets Manager에 저장하고, 사람에게 출력하지 않는다.

### 현재 접근 흐름을 한 줄씩 풀어쓰기

1. `10-persistent`는 S3에 있는 `00-network` state를 읽어서 VPC/subnet 정보를 가져온다.
2. `10-persistent`는 RDS를 만들고, `manage_master_user_password = true`로 master password 관리를 RDS/Secrets Manager에 맡긴다.
3. RDS는 master password secret을 Secrets Manager에 만든다.
4. `10-persistent`는 app password용 Secrets Manager secret을 만들지만, secret 값은 넣지 않는다.
5. `10-persistent`는 DB admin EC2와 SSM bootstrap document를 만든다.
6. `10-persistent` apply 결과는 S3의 `securevoice/dev/10-persistent/terraform.tfstate`에 저장된다.
7. 사용자는 `terraform output`으로 `db_admin_instance_id`, `db_bootstrap_ssm_document_name`, `db_master_secret_arn`, `db_app_password_secret_arn`, `rds_endpoint`, `db_name`, `db_app_username`을 읽는다.
8. 사용자는 이 값을 `aws ssm send-command`의 파라미터로 넘긴다.
9. SSM은 DB admin EC2에서 bootstrap script를 실행한다.
10. bootstrap script는 `db_master_secret_arn`으로 Secrets Manager에서 master username/password를 읽는다.
11. bootstrap script는 `db_app_password_secret_arn`으로 app secret을 확인한다.
12. app secret 값이 없거나 `RotateAppPassword=true`이면 bootstrap script가 새 app password를 생성한다.
13. bootstrap script는 새 app password를 Secrets Manager app secret에 저장한다.
14. bootstrap script는 master 계정으로 RDS endpoint에 접속한다.
15. bootstrap script는 MySQL 안에 `mzmt_app` user를 만들고 `mzmt_db` 권한을 준다.
16. 이후 `20-runtime` apply 시 Terraform은 S3의 `10-persistent` state output을 읽는다.
17. `20-runtime`은 그 output으로 ECS task definition의 `DB_HOST`, `DB_USER`, `DB_NAME`, `DB_PASSWORD` secret 연결을 만든다.
18. ECS task가 시작될 때 ECS agent/task execution role이 Secrets Manager에서 app password를 읽어 컨테이너 환경변수 `DB_PASSWORD`로 주입한다.
19. API/worker 컨테이너는 환경변수만 보고 `mzmt_app`으로 DB에 접속한다.

### tfvars 파일이 repo에 없는 이유

`terraform.tfvars`는 원래 Git에 올리지 않는 로컬 입력 파일이다. 이 repo의 `.gitignore`에도 아래처럼 제외되어 있다.

```gitignore
*.tfvars
*.tfvars.json
```

따라서 repo에 `terraform.tfvars` 파일이 안 보이는 것이 정상이다.

문서의 `10-persistent/terraform.tfvars`, `20-runtime/terraform.tfvars` 예시는 “팀원이 로컬에서 필요하면 이렇게 만들라”는 안내다. 내가 코드에 반영한 것은 실제 tfvars 파일이 아니라 아래 Terraform 코드다.

```text
10-persistent:
  variables.tf
  main.tf
  outputs.tf
  db-admin-ec2.tf
  db-bootstrap.tf
  endpoints.tf

20-runtime:
  network_data.tf
  ecs.tf
  iam.tf
  variables.tf
  endpoints.tf
```

현재 기준으로 `20-runtime/terraform.tfvars`에 DB 관련 값은 넣지 않는다. `20-runtime`이 `10-persistent` remote state에서 자동으로 읽는다. `20-runtime/terraform.tfvars`는 이미지 태그처럼 runtime에서만 필요한 값만 담으면 된다.

### AWS 인증 방식

Terraform provider의 `aws_profile` 기본값은 `null`이다. 기본적으로 특정 profile을 강제하지 않고 현재 shell의 AWS credential을 사용한다.

AWS CLI의 `login` 방식 profile을 쓰는 경우에는 AWS CLI는 인증을 읽을 수 있지만 Terraform AWS provider가 그 profile을 직접 읽지 못할 수 있다. 이때는 같은 WSL/bash shell에서 credential을 환경변수로 export한 뒤 Terraform을 실행한다.

```bash
aws login --profile kjh
source <(aws configure export-credentials --profile kjh --format env)
aws sts get-caller-identity
```

그 다음 같은 shell에서 `terraform init`, `terraform plan`, `terraform apply`를 실행한다. shell을 새로 열었거나 세션이 만료되면 위 export를 다시 실행한다.

정적인 shared config profile을 쓰는 팀원은 필요할 때만 아래처럼 profile을 명시할 수 있다.

```bash
terraform plan -var='aws_profile=profile-name'
```

## 1. 변경 내역

### 목표

기존에는 RDS 생성 시 DB 비밀번호를 Terraform 변수로 받아 Secrets Manager에 저장하는 흐름이었다. 이 방식은 app 비밀번호가 Terraform state에 남을 수 있어서 운영 보안 관점에서 좋지 않다.

현재 구조는 아래처럼 바뀌었다.

```text
Terraform:
  RDS, Secrets Manager secret, IAM, SSM 문서, VPC endpoint 생성
  app 비밀번호 값은 만들지 않음

SSM bootstrap:
  app 비밀번호 생성
  app secret에 저장
  MySQL 내부에 mzmt_app 생성
  mzmt_db 권한 부여

ECS:
  DB_USER=mzmt_app
  DB_PASSWORD는 Secrets Manager에서 주입
  RDS/secret 값은 10-persistent remote state에서 자동 참조
```

### 10-persistent/main.tf

RDS master password를 Terraform 변수로 받지 않고, RDS-managed Secrets Manager로 관리하도록 변경했다.

```hcl
db_name                     = var.rds_snapshot_identifier == "" ? var.db_name : null
username                    = var.rds_snapshot_identifier == "" ? var.db_master_username : null
manage_master_user_password = true
```

기존의 `password = var.db_password` 방식은 제거되었다. 이제 master password는 RDS가 Secrets Manager secret으로 생성/관리한다.

app 계정 password secret은 "껍데기"만 만든다.

```hcl
resource "aws_secretsmanager_secret" "db_password" {
  name = "${var.project_name}/${var.env}/db-password"

  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}
```

중요한 변경점:

- `random_password "db_app"` 제거
- `aws_secretsmanager_secret_version "db_password"` 제거
- app password 값은 Terraform state에 저장하지 않음
- app password 값은 SSM bootstrap이 `put-secret-value`로 저장함

### 10-persistent/variables.tf

DB 계정을 master/app으로 분리했다.

```hcl
variable "db_master_username" {
  default = "mzmt"
}

variable "db_app_username" {
  default = "mzmt_app"
}
```

의미:

- `db_master_username`: 관리자/DBA용 RDS master 계정명
- `db_app_username`: ECS API/worker가 사용할 MySQL app 계정명

기존의 `db_username`, `db_password` 변수는 제거되었다.

### 10-persistent/db-admin-ec2.tf

DB admin EC2에 bootstrap 작업용 IAM 권한을 추가했다.

```hcl
Action = [
  "secretsmanager:GetSecretValue",
  "secretsmanager:DescribeSecret"
]
```

이 권한은 master secret과 app secret을 읽기 위해 필요하다.

```hcl
Action = [
  "secretsmanager:PutSecretValue"
]
```

이 권한은 bootstrap 스크립트가 새 app password를 app secret에 저장하기 위해 필요하다.

```hcl
Action = [
  "secretsmanager:GetRandomPassword"
]
```

이 권한은 app password를 AWS Secrets Manager API로 생성하기 위해 필요하다.

DB admin EC2는 여전히 SSM 전용이다.

```text
관리자 PC
 -> SSM Session Manager / SSM Run Command
 -> DB admin EC2
 -> RDS 접속
```

### 10-persistent/db-bootstrap.tf

SSM Run Command 문서를 새로 만들었다.

```hcl
resource "aws_ssm_document" "bootstrap_db_app_user" {
  name          = "${var.project_name}-${var.env}-bootstrap-db-app-user"
  document_type = "Command"
}
```

이 문서는 DB admin EC2에서 bootstrap shell script를 실행한다.

입력 파라미터:

- `MasterSecretArn`: RDS-managed master secret ARN
- `AppSecretArn`: app password secret ARN
- `DbEndpoint`: RDS endpoint
- `DbName`: 권한을 줄 DB 이름
- `AppUsername`: app 계정명
- `RotateAppPassword`: app password를 새로 만들지 여부

### 10-persistent/scripts/bootstrap-db-app-user.sh

실제 DB bootstrap 로직이다.

하는 일:

1. master secret을 Secrets Manager에서 읽는다.
2. app secret에 비밀번호가 없거나 `--rotate`가 있으면 새 비밀번호를 만든다.
3. 새 app password를 Secrets Manager에 저장한다.
4. master 계정으로 MySQL에 접속한다.
5. `mzmt_app` user를 생성한다.
6. `mzmt_db`에 DML 권한을 부여한다.

핵심 SQL:

```sql
CREATE USER IF NOT EXISTS 'mzmt_app'@'%' IDENTIFIED BY '<app-password>';
ALTER USER 'mzmt_app'@'%' IDENTIFIED BY '<app-password>';
GRANT SELECT, INSERT, UPDATE, DELETE ON mzmt_db.* TO 'mzmt_app'@'%';
FLUSH PRIVILEGES;
```

보안상 중요한 점:

- master password를 화면에 출력하지 않는다.
- app password를 화면에 출력하지 않는다.
- password 값은 Terraform state에 저장하지 않는다.
- SSM output에는 성공 메시지만 남는다.

### 10-persistent/endpoints.tf

Secrets Manager VPC endpoint를 `10-persistent`로 이동했다.

```hcl
resource "aws_vpc_endpoint" "secretsmanager" {
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
}
```

이유:

- bootstrap은 `20-runtime`보다 먼저 실행된다.
- DB admin EC2가 private subnet 안에서 Secrets Manager에 접근해야 한다.
- ECS도 같은 VPC endpoint를 통해 Secrets Manager에 접근할 수 있다.

### 20-runtime/endpoints.tf

기존 `20-runtime`의 Secrets Manager VPC endpoint는 제거했다.

이유:

- 동일 VPC에 private DNS가 켜진 Secrets Manager interface endpoint를 중복 생성하면 충돌 가능성이 있다.
- Secrets Manager endpoint는 `10-persistent`에서 공통 인프라로 관리한다.

### 20-runtime/ecs.tf

API/free worker/paid worker가 app 계정으로 DB에 접속하도록 환경변수를 유지한다.

```hcl
{ name = "DB_HOST", value = data.terraform_remote_state.persistent.outputs.rds_endpoint }
{ name = "DB_USER", value = data.terraform_remote_state.persistent.outputs.db_app_username }
{ name = "DB_NAME", value = data.terraform_remote_state.persistent.outputs.db_name }
```

비밀번호는 Secrets Manager에서 주입한다.

```hcl
secrets = [
  {
    name      = "DB_PASSWORD"
    valueFrom = data.terraform_remote_state.persistent.outputs.db_app_password_secret_arn
  }
]
```

ECS task는 실제 비밀번호 값을 Terraform 코드나 tfvars에서 받지 않는다. `20-runtime`은 Terraform plan/apply 시점에 S3에 저장된 `10-persistent` state output을 읽어 ARN과 endpoint만 연결한다.

### 20-runtime/network_data.tf

`20-runtime`이 `10-persistent` state output을 직접 읽도록 remote state를 추가했다.

```hcl
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key    = "securevoice/dev/10-persistent/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
```

이것은 ECS 컨테이너가 S3를 읽는 구조가 아니다. Terraform이 배포 시점에 S3 state 파일의 output을 읽어서 task definition과 IAM policy를 만든다.

주의:

- `20-runtime`을 plan/apply하는 작업자는 S3에 있는 `10-persistent` state를 읽을 권한이 있어야 한다.
- `terraform_remote_state`는 output을 읽기 위한 기능이지만, 동작상 backend state snapshot에 접근한다. 따라서 state bucket 접근 권한은 운영자/배포 주체로 제한한다.
- DB 연결 정보의 자동 참조를 위해 `20-runtime`은 `10-persistent`가 먼저 apply된 상태를 전제로 한다.

### 20-runtime/variables.tf

`db_host`, `db_name`, `db_user`, `db_password_secret_arn`, `jwt_secret_key_secret_arn` 변수는 제거했다.

이유:

- 팀원이 `10-persistent` output을 `20-runtime/terraform.tfvars`에 복사하지 않아도 된다.
- 오래된 RDS endpoint나 secret ARN을 잘못 넣는 실수를 줄인다.
- DB 연결 정보의 source of truth를 `10-persistent` state output으로 통일한다.

### 10-persistent/outputs.tf

bootstrap과 runtime 연결에 필요한 output을 추가했다.

```hcl
output "db_master_secret_arn"
output "db_app_username"
output "db_app_password_secret_arn"
output "db_bootstrap_ssm_document_name"
output "db_admin_instance_id"
output "rds_endpoint"
output "db_name"
```

이 output들은 대부분 ARN, 이름, endpoint다. 비밀번호 값이 아니다.

## 2. 실행 Runbook

### 전체 실행 흐름

```text
1. 10-persistent apply
2. Terraform output으로 bootstrap 파라미터 확인
3. SSM Run Command로 DB bootstrap 1회 실행
4. 20-runtime apply
5. ECS API/worker가 mzmt_app으로 DB 접속
```

### 기존 환경 마이그레이션 주의사항

기존에 `20-runtime`을 이미 apply한 환경에서는 Secrets Manager VPC endpoint가 `20-runtime` state에 있을 수 있다.

확인:

```powershell
cd 20-runtime
terraform state list | Select-String secretsmanager
```

아래 리소스가 나오면:

```text
aws_vpc_endpoint.secretsmanager
```

같은 VPC에 `private_dns_enabled = true`인 Secrets Manager endpoint를 중복 생성할 수 없으므로, 바로 `10-persistent apply`를 실행하면 충돌할 수 있다.

처리 방식은 둘 중 하나다.

```text
권장:
  기존 endpoint를 10-persistent state로 import하고,
  20-runtime state에서는 제거한다.

대안:
  20-runtime에서 기존 endpoint를 destroy한 뒤,
  10-persistent에서 새 endpoint를 생성한다.
```

운영 중인 환경이면 endpoint를 destroy하는 동안 ECS secret 조회 경로가 흔들릴 수 있으므로 import 방식이 더 안전하다.

현재 환경처럼 기존 리소스를 새 Terraform 코드 구조로 옮기는 경우에는 아래 순서로 state만 정리한다. 이 명령들은 실제 AWS 리소스를 삭제하지 않고 Terraform state의 소유권만 정리한다.

기존 app password secret version은 더 이상 Terraform이 관리하지 않게 state에서만 제거한다. 이렇게 해야 apply 때 기존 secret value를 지우려고 하지 않는다.

```bash
cd 10-persistent
terraform state list | grep aws_secretsmanager_secret_version.db_password
terraform state rm aws_secretsmanager_secret_version.db_password
```

기존 Secrets Manager VPC endpoint가 `20-runtime` state에 있으면 먼저 `20-runtime` state에서만 제거한다.

```bash
cd ../20-runtime
terraform state list | grep aws_vpc_endpoint.secretsmanager
terraform state rm aws_vpc_endpoint.secretsmanager
```

그 다음 같은 endpoint를 `10-persistent` state로 import한다.

```bash
cd ../10-persistent
terraform import aws_vpc_endpoint.secretsmanager <secretsmanager-vpc-endpoint-id>
```

endpoint ID는 아래처럼 확인할 수 있다.

```bash
aws ec2 describe-vpc-endpoints \
  --region ap-northeast-2 \
  --filters Name=service-name,Values=com.amazonaws.ap-northeast-2.secretsmanager \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text
```

### 1단계: 10-persistent 적용

```powershell
cd 10-persistent
terraform apply
```

이 단계에서 생성되는 것:

- RDS MySQL
- RDS master managed secret
- app password secret 껍데기
- DB admin EC2
- DB admin EC2 IAM role/policy
- SSM bootstrap document
- Secrets Manager VPC endpoint

이 단계에서 아직 하지 않는 것:

- app password 값 생성
- MySQL 내부 `mzmt_app` user 생성
- `mzmt_db` 권한 부여

### 2단계: bootstrap 파라미터 확인

```powershell
$instanceId       = terraform output -raw db_admin_instance_id
$documentName     = terraform output -raw db_bootstrap_ssm_document_name
$masterSecretArn  = terraform output -raw db_master_secret_arn
$appSecretArn     = terraform output -raw db_app_password_secret_arn
$dbEndpoint       = terraform output -raw rds_endpoint
$dbName           = terraform output -raw db_name
$appUsername      = terraform output -raw db_app_username
```

주의:

- 위 값들은 비밀번호가 아니다.
- `masterSecretArn`, `appSecretArn`은 secret의 주소다.
- 실제 password 값은 사람이 출력해서 볼 필요가 없다.

### 3단계: DB bootstrap 실행

첫 실행은 `RotateAppPassword=true`를 권장한다.

```powershell
aws ssm send-command `
  --instance-ids $instanceId `
  --document-name $documentName `
  --parameters "MasterSecretArn=$masterSecretArn,AppSecretArn=$appSecretArn,DbEndpoint=$dbEndpoint,DbName=$dbName,AppUsername=$appUsername,RotateAppPassword=true"
```

이 명령이 하는 일:

- DB admin EC2에서 bootstrap 스크립트 실행
- master secret 조회
- app password 생성
- app password를 app secret에 저장
- master 계정으로 RDS 접속
- `mzmt_app` 생성
- `mzmt_db` 권한 부여

명령 실행 결과 확인:

```powershell
$commandId = "<send-command 결과의 CommandId>"

aws ssm get-command-invocation `
  --command-id $commandId `
  --instance-id $instanceId
```

성공 시 기대 메시지:

```text
Stored a new app DB password in Secrets Manager.
Bootstrapped MySQL app user 'mzmt_app' for database 'mzmt_db'.
```

비밀번호는 출력되지 않는다.

### 4단계: 20-runtime tfvars 설정

`20-runtime/terraform.tfvars`에는 이미지 태그 등 runtime 고유 값만 넣는다. DB 관련 값은 넣지 않는다.

```hcl
api_image_tag    = "<배포할 API 이미지 태그>"
worker_image_tag = "<배포할 worker 이미지 태그>"
```

`20-runtime`이 자동으로 읽는 값:

- `rds_endpoint`
- `db_name`
- `db_app_username`
- `db_app_password_secret_arn`
- `jwt_secret_key_secret_arn`

### 5단계: 20-runtime 적용

```powershell
cd ../20-runtime
terraform apply
```

이 단계에서 ECS task definition은 아래 값을 갖는다.

```text
DB_HOST     = RDS endpoint
DB_PORT     = 3306
DB_USER     = mzmt_app
DB_NAME     = mzmt_db
DB_PASSWORD = Secrets Manager app password
```

API 서버 코드가 `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` 환경변수를 읽는 구조라면 애플리케이션 코드는 바꿀 필요가 없다.

## 운영 Runbook

### 관리자가 DB를 관리할 때

일반적인 관리 흐름:

```text
관리자
 -> SSM Session Manager 또는 SSM Run Command
 -> DB admin EC2
 -> Secrets Manager에서 master secret 조회
 -> RDS 접속
 -> 필요한 DBA 작업 수행
```

운영 원칙:

- master 계정은 관리자/DBA 작업에만 사용한다.
- API/worker는 master 계정을 사용하지 않는다.
- 일반 애플리케이션 트래픽은 `mzmt_app` 계정만 사용한다.
- master password를 로컬 터미널에 출력하거나 복사해서 쓰는 방식은 최소화한다.

### app password를 다시 만들고 싶을 때

아래처럼 bootstrap을 다시 실행한다.

```powershell
aws ssm send-command `
  --instance-ids $instanceId `
  --document-name $documentName `
  --parameters "MasterSecretArn=$masterSecretArn,AppSecretArn=$appSecretArn,DbEndpoint=$dbEndpoint,DbName=$dbName,AppUsername=$appUsername,RotateAppPassword=true"
```

이렇게 하면:

- 새 app password 생성
- Secrets Manager app secret 새 버전 저장
- MySQL `mzmt_app` password 변경

그 다음 ECS task를 새로 배포하거나 재시작해야 한다. 이미 떠 있는 컨테이너는 기존 환경변수 값을 계속 들고 있을 수 있기 때문이다.

### app user 권한만 다시 맞추고 싶을 때

기존 password를 유지하면서 권한만 다시 적용하려면 `RotateAppPassword=false`로 실행한다.

```powershell
aws ssm send-command `
  --instance-ids $instanceId `
  --document-name $documentName `
  --parameters "MasterSecretArn=$masterSecretArn,AppSecretArn=$appSecretArn,DbEndpoint=$dbEndpoint,DbName=$dbName,AppUsername=$appUsername,RotateAppPassword=false"
```

이렇게 하면:

- 기존 app secret password 사용
- MySQL user가 없으면 생성
- password 동기화
- 권한 재부여

### rotation 상태

현재 자동 rotation은 아직 적용하지 않았다.

```text
master 계정:
  RDS-managed Secrets Manager 사용
  자동 rotation은 별도 설정 필요

app 계정:
  Secrets Manager에 저장
  자동 rotation은 미적용
  필요 시 bootstrap RotateAppPassword=true로 수동 회전
```

자동 rotation은 다음 고도화 단계에서 검토한다. 지금은 계정 분리, secret 보관, bootstrap 자동화를 먼저 안정화한다.

### 장애/실패 시 확인할 것

SSM command 실패 시 확인 순서:

1. DB admin EC2가 `running` 상태인지 확인
2. SSM managed instance로 잡혀 있는지 확인
3. `10-persistent`의 Secrets Manager VPC endpoint가 생성됐는지 확인
4. DB admin EC2 role에 `GetSecretValue`, `PutSecretValue`, `GetRandomPassword` 권한이 있는지 확인
5. RDS security group이 DB admin EC2 security group에서 3306을 허용하는지 확인
6. RDS endpoint와 DB name output이 올바른지 확인

## 권한 모델

앱이 RDS에 접근할 때는 IAM 권한만으로 접근하는 것이 아니다. 아래 세 가지가 모두 맞아야 한다.

```text
ECS task execution role
 -> Secrets Manager에서 app password 조회
 -> 컨테이너 환경변수 DB_PASSWORD로 주입
API/worker 컨테이너
 -> DB_HOST/DB_USER/DB_NAME/DB_PASSWORD 사용
 -> RDS security group 3306 허용 범위 안에서 접속
MySQL
 -> mzmt_app 계정 권한으로 mzmt_db 접근
```

### IAM 권한

`20-runtime/iam.tf`의 ECS task execution role은 아래 secret만 읽을 수 있다.

- DB app password secret
- JWT secret

이 권한은 ECS agent가 task 시작 시 Secrets Manager 값을 읽어 컨테이너 환경변수로 넣기 위한 권한이다. 이 IAM 권한이 MySQL 테이블 권한을 의미하지는 않는다.

API task role은 S3 audio bucket 읽기/쓰기와 SQS send 권한만 가진다. Worker task role은 S3 audio/model bucket 읽기/쓰기와 SQS consume 권한만 가진다. 현재 구조에서는 DB IAM authentication을 사용하지 않으므로 API/worker task role에 RDS 접속 IAM 권한을 따로 주지 않는다.

DB admin EC2 role은 bootstrap을 위해 master/app secret 읽기, app secret 쓰기, random password 생성 권한을 가진다. 이 role은 일반 애플리케이션 트래픽용이 아니라 SSM bootstrap/관리 작업용이다.

### 네트워크 권한

`10-persistent/main.tf`의 RDS security group은 `00-network` remote state에서 읽은 private app subnet CIDR만 MySQL 3306 ingress로 허용한다.

DB admin EC2는 별도 security group rule로 RDS 3306 접근을 허용한다. ECS task security group은 outbound가 열려 있으므로, RDS security group ingress 범위와 맞으면 RDS에 도달할 수 있다.

### MySQL 내부 권한

SSM bootstrap script는 `mzmt_app` 계정을 만들고 아래 권한만 부여한다.

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON mzmt_db.* TO 'mzmt_app'@'%';
```

따라서 `mzmt_app`은 일반 CRUD 트래픽용 계정이다. `CREATE`, `ALTER`, `DROP`, `GRANT`, `SUPER` 같은 스키마 변경/관리 권한은 없다.

앱 배포 중 DB migration이 테이블 생성/변경을 해야 한다면 `mzmt_app`으로 실행하면 실패할 수 있다. 이 경우에는 master 계정을 직접 앱에 주는 방식이 아니라, 별도 migration 계정 또는 SSM/CI migration 절차를 만들어 제한된 시간에만 스키마 변경 권한을 쓰는 방식이 실무적으로 더 안전하다.

## 보안 기준

- Terraform state에는 app password 값을 저장하지 않는다.
- `terraform output`으로 확인하는 값은 ARN/endpoint/name만 사용한다.
- `aws secretsmanager get-secret-value`로 비밀번호를 화면에 출력하는 방식은 일반 운영 절차로 사용하지 않는다.
- app password 생성과 MySQL 반영은 SSM bootstrap 스크립트가 처리한다.
- SSM/CloudTrail로 누가 bootstrap을 실행했는지 추적할 수 있다.

## 팀원에게 전달할 핵심 요약

```text
10-persistent는 DB와 secret 껍데기, bootstrap 실행 환경을 만든다.
bootstrap은 app 비밀번호와 MySQL mzmt_app 계정/권한을 만든다.
20-runtime은 10-persistent remote state output을 읽어 ECS가 mzmt_app과 app secret으로 DB에 접속하게 만든다.
비밀번호는 사람이 직접 출력해서 보지 않는다.
```
