# 00-network remote state: VPC, subnet, route table IDs 참조
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

# 20-runtime remote state: ECS 클러스터, ECR URL 참조
data "terraform_remote_state" "runtime" {
  backend = "s3"

  config = {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/20-runtime/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}

data "aws_vpc" "main" {
  id = data.terraform_remote_state.network.outputs.vpc_id
}
