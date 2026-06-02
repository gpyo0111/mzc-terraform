# SSM Run Command 문서다.
# 관리자는 이 문서를 DB admin EC2에 실행해서 app secret 값 생성, MySQL app user 생성, 권한 부여를 한 번에 처리한다.
# 실제 비밀번호는 SSM output에 출력하지 않고, Terraform state에도 저장하지 않는다.
resource "aws_ssm_document" "bootstrap_db_app_user" {
  name            = "${var.project_name}-${var.env}-bootstrap-db-app-user"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Bootstrap MySQL application user using Secrets Manager values."

    parameters = {
      MasterSecretArn = {
        type        = "String"
        description = "RDS-managed master user secret ARN."
      }
      AppSecretArn = {
        type        = "String"
        description = "Application DB password secret ARN."
      }
      DbEndpoint = {
        type        = "String"
        description = "RDS endpoint address."
      }
      DbName = {
        type        = "String"
        description = "Database name to grant permissions on."
      }
      AppUsername = {
        type        = "String"
        description = "Application DB username."
      }
      AwsRegion = {
        type        = "String"
        description = "AWS region."
        default     = var.aws_region
      }
      RotateAppPassword = {
        type          = "String"
        description   = "Set true to generate a new app password even if the secret already has a value."
        default       = "false"
        allowedValues = ["true", "false"]
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapDbAppUser"
        inputs = {
          runCommand = [
            "set -Eeuo pipefail",
            "dnf install -y python3 >/dev/null",
            "dnf install -y awscli >/dev/null || dnf install -y awscli-2 >/dev/null || true",
            "dnf install -y mysql >/dev/null || dnf install -y mariadb105 >/dev/null || dnf install -y mariadb >/dev/null",
            "cat > /tmp/bootstrap-db-app-user.sh <<'SCRIPT'",
            file("${path.module}/scripts/bootstrap-db-app-user.sh"),
            "SCRIPT",
            "chmod 700 /tmp/bootstrap-db-app-user.sh",
            "ROTATE_ARG=''",
            "if [ '{{ RotateAppPassword }}' = 'true' ]; then ROTATE_ARG='--rotate'; fi",
            "AWS_REGION='{{ AwsRegion }}' /tmp/bootstrap-db-app-user.sh '{{ MasterSecretArn }}' '{{ AppSecretArn }}' '{{ DbEndpoint }}' '{{ DbName }}' '{{ AppUsername }}' $ROTATE_ARG"
          ]
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.env
  }
}
