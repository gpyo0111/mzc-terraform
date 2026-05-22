# 팀원용 terraform.tfvars 설정 안내

보안 및 개인 환경값 보호를 위해 `terraform.tfvars` 파일은 Git에 포함하지 않았습니다.

아래 내용을 기준으로 각 디렉토리에 동일하게 생성해서 사용합니다.

--------------------------------------------------
[ 10-persistent/terraform.tfvars ]
--------------------------------------------------

db_password = "mzmt1234"


--------------------------------------------------
[ 20-runtime/terraform.tfvars ]
--------------------------------------------------

db_host = "securevoice-dev-mysql.clums8ywi9au.ap-northeast-2.rds.amazonaws.com"

db_password_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:455535733131:secret:securevoice/dev/db-password-oaem7x"

jwt_secret_key_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:455535733131:secret:securevoice/dev/jwt-secret-key-NUu01p"

api_image_tag    = "7886a43"
worker_image_tag = "187b6a9"


--------------------------------------------------
[ 참고 ]
--------------------------------------------------

- 위 값들은 현재 공통 개발 환경(dev) 기준입니다.
- image tag는 최신 배포 기준으로 필요 시 변경합니다.
- terraform.tfvars 파일은 Git에 업로드하지 않습니다.