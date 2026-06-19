terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Lambda 소스 코드를 zip으로 패키징하기 위한 프로바이더
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # 4번 보안 폴더 자체의 State 파일 저장소 정의
  backend "s3" {
    bucket = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key    = "securevoice/dev/pmg-security/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

provider "aws" {
  region = "ap-northeast-2"
}