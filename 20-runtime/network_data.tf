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