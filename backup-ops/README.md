# Backup Operations Module (backup-ops)

이 모듈은 SecureVoice의 재해 복구(Disaster Recovery) 및 데이터 보호를 위해 AWS Backup과 S3 Bucket Versioning 설정을 관리합니다.

팀의 공통 뼈대 폴더(예: `10-persistent`, `20-runtime` 등)를 직접 수정하지 않기 위해 독립된 모듈로 분리하여 구성되었습니다.

---

## 제공 리소스

1. **AWS Backup Vault (`securevoice-vault`)**
   - 백업 본이 암호화되어 보관될 금고이며, 특정 KMS 키(`3229b4c8-2a82-49a6-8dbc-5b4fc5e8d73b`)를 사용합니다.
2. **AWS Backup Plan (`securevoice-test-plan`)**
   - 매일 UTC 05:00(KST 14:00)에 백업을 수행하며, 수명 주기(Lifecycle) 정책에 따라 1일 후 자동으로 삭제됩니다.
3. **AWS Backup Selection (`securevoice-backup-selection`)**
   - 백업 대상 리소스를 지정합니다.
   - **ARN 기반 직접 지정**: `10-persistent` 폴더를 건드리지 않아 RDS의 `Backup = "Daily"` 태그가 유실되더라도 백업이 중단되지 않도록 RDS 인스턴스의 ARN을 직접 타겟팅합니다.
   - **태그 기반 지정**: `Backup = "Daily"` 태그가 매핑된 다른 AWS 리소스도 자동으로 백업에 포함되도록 호환성을 유지합니다.
4. **AWS Backup IAM Role (`AWSBackupDefaultServiceRole`)**
   - AWS Backup 서비스가 백업 및 복원 작업을 정상 수행하는 데 필요한 AWS 관리형 권한(`AWSBackupServiceRolePolicyForBackup`, `AWSBackupServiceRolePolicyForRestores`)이 연결됩니다.
5. **S3 Bucket Versioning (`aws_s3_bucket_versioning.audio`)**
   - 오디오 버킷의 Versioning 상태를 `Enabled`로 고정하여 실수로 객체가 삭제되더라도 버전 관리를 통해 즉시 복구할 수 있도록 보장합니다.

---

## 실행 및 관리 방법

### 1. 초기화 및 실행
본 모듈은 S3 원격 백엔드(`securevoice/dev/backup-ops/terraform.tfstate`)를 활용합니다.
```bash
cd mzc-terraform/backup-ops
terraform init
terraform plan
terraform apply
```

### 2. 신규 환경 배포 시 리소스 매핑 참고 (Import)
기존에 CLI 또는 콘솔을 통해 수동으로 생성한 백업 자원이 있는 환경에서 본 코드를 처음 적용할 때는, Terraform이 리소스를 중복 생성하지 않고 기존 자원을 가져가도록 아래 명령어로 가져온(Import) 뒤 실행해야 합니다.
```bash
# IAM Role 가져오기
terraform import aws_iam_role.backup_role AWSBackupDefaultServiceRole

# Backup Vault 가져오기
terraform import aws_backup_vault.securevoice_vault securevoice-vault

# Backup Plan 가져오기 (Plan ID 입력 필요)
terraform import aws_backup_plan.securevoice_plan <BACKUP_PLAN_ID>

# S3 Versioning 설정 가져오기 (오디오 버킷명 입력 필요)
terraform import aws_s3_bucket_versioning.audio <AUDIO_BUCKET_NAME>
```

---

## 💡 모듈 상세 가이드 (Why, What, How)

### 왜 필요한가? (Why)
* **데이터 복구력 및 재해 복구(DR) 확보**: 예기치 못한 시스템 오류, 랜섬웨어 공격, 또는 작업자의 실수로 데이터베이스나 저장소가 유실 및 손상되는 시나리오에 대응하여 백업을 자동화하고 안전하게 데이터를 복구하기 위해 필요합니다.
* **결합도 분리**: 메인 데이터베이스와 런타임 환경 코드(`10-persistent`, `20-runtime`)의 구성을 방해하거나 훼손하지 않도록, 독립적으로 작동하는 백업 제어 모듈을 두어 유지보수의 유연성을 높입니다.

### 무슨 기능을 하는가? (What)
* **자동화된 일일 백업 정책**: AWS Backup Vault 및 Plan을 정의하여 매일 정해진 시간(KST 14:00)에 데이터베이스 백업을 자동화하고, 1일의 보존 수명 주기 후에 자동으로 파기되도록 일정을 관리합니다.
* **안정적인 타겟팅**: RDS 인스턴스의 ARN을 직접 타겟팅하여 인프라 태그의 누락이 발생하더라도 백업 정합성을 보장합니다.
* **객체 버전 관리(S3 Versioning)**: 오디오 데이터 버킷의 버전 관리를 강제 활성화(`Enabled`)하여 덮어쓰기나 의도치 않은 삭제 상황에서 특정 과거 시점의 데이터로 즉각 롤백할 수 있게 돕습니다.

### 어떻게 사용하는가? (How)
1. `backup-ops` 디렉터리로 이동합니다.
2. `terraform init` 및 `terraform apply`를 실행하여 AWS Backup 및 S3 Versioning 정책을 배포합니다.
3. (선택 사항) 이미 수동으로 생성한 백업 인프라가 존재한다면 중복 생성을 막기 위해 제공되는 `terraform import` 명령어들을 활용하여 기존 자원 상태를 가져옵니다.
