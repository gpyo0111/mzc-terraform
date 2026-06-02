#!/usr/bin/env bash
set -Eeuo pipefail
set +x

# DB admin EC2에서 실행하는 1회성 bootstrap 스크립트다.
# - master secret을 읽어 RDS에 관리자 계정으로 접속한다.
# - app password secret이 비어 있으면 새 비밀번호를 생성해 저장한다.
# - MySQL 내부에 app user를 만들고 애플리케이션용 DML 권한을 부여한다.
# - 비밀번호는 stdout에 출력하지 않는다.

usage() {
  echo "Usage: bootstrap-db-app-user <master-secret-arn> <app-secret-arn> <db-endpoint> <db-name> <app-username> [--rotate]" >&2
}

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  usage
  exit 2
fi

MASTER_SECRET_ARN="$1"
APP_SECRET_ARN="$2"
DB_ENDPOINT="$3"
DB_NAME="$4"
APP_USERNAME="$5"
ROTATE_APP_PASSWORD=""
if [ "$#" -eq 6 ]; then
  ROTATE_APP_PASSWORD="$6"
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
DB_PORT="${DB_PORT:-3306}"

command -v aws >/dev/null 2>&1 || { echo "aws CLI is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }
MYSQL_BIN="$(command -v mysql || command -v mariadb || true)"
if [ -z "$MYSQL_BIN" ]; then
  echo "mysql or mariadb client is required." >&2
  exit 1
fi

MASTER_JSON="$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$MASTER_SECRET_ARN" \
  --query SecretString \
  --output text)"

MASTER_USERNAME="$(MASTER_JSON="$MASTER_JSON" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["MASTER_JSON"])["username"])
PY
)"

MASTER_PASSWORD="$(MASTER_JSON="$MASTER_JSON" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["MASTER_JSON"])["password"])
PY
)"

set +e
APP_PASSWORD="$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$APP_SECRET_ARN" \
  --query SecretString \
  --output text 2>/dev/null)"
APP_SECRET_STATUS="$?"
set -e

if [ "$APP_SECRET_STATUS" -ne 0 ] || [ -z "$APP_PASSWORD" ] || [ "$APP_PASSWORD" = "None" ] || [ "$ROTATE_APP_PASSWORD" = "--rotate" ]; then
  APP_PASSWORD="$(aws secretsmanager get-random-password \
    --region "$AWS_REGION" \
    --password-length 32 \
    --exclude-punctuation \
    --require-each-included-type \
    --query RandomPassword \
    --output text)"

  aws secretsmanager put-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$APP_SECRET_ARN" \
    --secret-string "$APP_PASSWORD" >/dev/null

  echo "Stored a new app DB password in Secrets Manager."
else
  echo "Using existing app DB password from Secrets Manager."
fi

MYSQL_PWD="$MASTER_PASSWORD" "$MYSQL_BIN" \
  --host="$DB_ENDPOINT" \
  --port="$DB_PORT" \
  --user="$MASTER_USERNAME" \
  --protocol=TCP <<SQL
CREATE USER IF NOT EXISTS '$APP_USERNAME'@'%' IDENTIFIED BY '$APP_PASSWORD';
ALTER USER '$APP_USERNAME'@'%' IDENTIFIED BY '$APP_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE ON $DB_NAME.* TO '$APP_USERNAME'@'%';
FLUSH PRIVILEGES;
SQL

echo "Bootstrapped MySQL app user '$APP_USERNAME' for database '$DB_NAME'."
