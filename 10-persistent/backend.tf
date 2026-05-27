terraform {
  backend "s3" {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/10-persistent/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}