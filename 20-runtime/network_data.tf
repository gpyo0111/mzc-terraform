data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/00-network/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}

# 10-persistent에서 만든 RDS endpoint, DB app 계정명, Secrets Manager ARN을 읽는다.
# Terraform plan/apply 시점에 S3 backend의 state output을 읽는 것이며, ECS 런타임이 S3를 읽는 것은 아니다.
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/10-persistent/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}
