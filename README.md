10-persistent (terraform destroy 해당 X)
- terraform.tfvars
  db_password = "mzmt1234"

20-runtime (terraform destroy 해당)
- terraform.tfvars
  db_host = "securevoice-dev-mysql.clums8ywi9au.ap-northeast-2.rds.amazonaws.com"

  db_password_secret_arn  = "arn:aws:secretsmanager:ap-northeast-2:455535733131:secret:securevoice/dev/db-password-oaem7x"
  jwt_secret_key_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:455535733131:secret:securevoice/dev/jwt-secret-key-NUu01p"
  
  api_image_tag    = "7886a43"
  worker_image_tag = "187b6a9"