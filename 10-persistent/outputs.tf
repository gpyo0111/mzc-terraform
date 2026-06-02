output "model_bucket_name" {
  value = aws_s3_bucket.model.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

output "db_name" {
  value = var.db_name
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

# 관리자가 DB에 접속할 때 사용할 RDS master 계정명이다.
output "db_master_username" {
  value = var.db_master_username
}

# RDS가 자동으로 생성/관리하는 master password secret ARN이다.
# 관리자 작업이나 app 계정 생성 시 DB admin EC2에서 조회한다.
output "db_master_secret_arn" {
  value     = try(aws_db_instance.mysql.master_user_secret[0].secret_arn, null)
  sensitive = true
}

# ECS API/worker가 사용할 app DB 계정명이다.
output "db_app_username" {
  value = var.db_app_username
}

# 기존 runtime 변수명과 호환하기 위한 app DB password secret ARN이다.
output "db_password_secret_arn" {
  value     = aws_secretsmanager_secret.db_password.arn
  sensitive = true
}

# ECS task가 DB_PASSWORD로 읽을 app DB password secret ARN이다.
output "db_app_password_secret_arn" {
  value     = aws_secretsmanager_secret.db_password.arn
  sensitive = true
}

output "jwt_secret_key_secret_arn" {
  value     = aws_secretsmanager_secret.jwt_secret_key.arn
  sensitive = true
}

output "db_admin_instance_id" {
  value = aws_instance.db_admin.id
}

output "db_bootstrap_ssm_document_name" {
  value = aws_ssm_document.bootstrap_db_app_user.name
}
