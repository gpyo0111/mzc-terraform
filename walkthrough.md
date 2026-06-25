# Walkthrough - AWS Backup & S3 Versioning IaC Migration

We have successfully migrated the manually created AWS Backup configuration and S3 Bucket Versioning settings into a new Terraform module [backup-ops](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops) without modifying the numbered team skeleton folders.

---

## Changes Implemented

### 1. Created Terraform Configuration in [backup-ops](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops)
- **[provider.tf](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops/provider.tf)**: Integrated standard AWS provider (omitting profiles to use environment-configured credentials).
- **[backend.tf](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops/backend.tf)**: Set up S3 state backend at `securevoice/dev/backup-ops/terraform.tfstate` matching the project standard.
- **[variables.tf](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops/variables.tf)**: Defined standard configuration variables (region, project name, environment, and target audio bucket name).
- **[main.tf](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops/main.tf)**:
  - Fetched RDS database and S3 audio bucket details using `data` sources.
  - Declared `aws_backup_vault`, `aws_backup_plan` (daily schedule, 1 day retention), and `aws_backup_selection` resources.
  - targeted the RDS DB instance **both by direct ARN and by tag** (`Backup = "Daily"`) to protect against tags being deleted if `10-persistent` is reapplied.
  - Declared the default IAM role `AWSBackupDefaultServiceRole` and attached standard policies (`AWSBackupServiceRolePolicyForBackup`, `AWSBackupServiceRolePolicyForRestores`).
  - Enabled versioning for the S3 audio bucket via `aws_s3_bucket_versioning`.
- **[README.md](file:///c:/Users/ANN/mzc-final-project/mzc-terraform/backup-ops/README.md)**: Added resource mapping, operation guide, and manual import instructions.

### 2. State Integration & Import
To prevent Terraform from attempting to recreate existing AWS resources and causing conflict errors, the manual resources were successfully imported into state:
1. `aws_iam_role.backup_role` (Imported ID: `AWSBackupDefaultServiceRole`)
2. `aws_backup_vault.securevoice_vault` (Imported ID: `securevoice-vault`)
3. `aws_backup_plan.securevoice_plan` (Imported ID: `346e90c3-bf15-4539-a62a-7b90425af012`)
4. `aws_s3_bucket_versioning.audio` (Imported ID: `mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an`)

---

## Verification Results

### 1. Terraform Apply Completion
The execution plan was applied without destroying any existing resources:
```plain
Apply complete! Resources: 3 added, 2 changed, 0 destroyed.
```

### 2. AWS CLI Verification

#### AWS Backup Plan
Successfully registers and maintains the backup plan:
```bash
$ aws backup list-backup-plans --query "BackupPlansList[*].{Name:BackupPlanName,Id:BackupPlanId}" --output table
-------------------------------------------------------------------
|                         ListBackupPlans                         |
+---------------------------------------+-------------------------+
|                  Id                   |          Name           |
+---------------------------------------+-------------------------+
|  346e90c3-bf15-4539-a62a-7b90425af012 |  securevoice-test-plan  |
+---------------------------------------+-------------------------+
```

#### AWS Backup Selection
The backup selection has targeted the RDS instance by ARN directly, alongside tag-based selection:
```json
{
    "SelectionName": "securevoice-backup-selection",
    "IamRoleArn": "arn:aws:iam::455535733131:role/AWSBackupDefaultServiceRole",
    "Resources": [
        "arn:aws:rds:ap-northeast-2:455535733131:db:securevoice-dev-mysql"
    ],
    "ListOfTags": [
        {
            "ConditionType": "STRINGEQUALS",
            "ConditionKey": "Backup",
            "ConditionValue": "Daily"
        }
    ]
}
```

#### S3 Bucket Versioning Status
Confirming the S3 versioning configuration for the audio bucket is successfully managed and remains enabled:
```json
{
    "Status": "Enabled"
}
```
