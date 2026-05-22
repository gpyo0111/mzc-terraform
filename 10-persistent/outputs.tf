output "model_bucket_name" {
  value = aws_s3_bucket.model.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "db_password_secret_arn" {
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