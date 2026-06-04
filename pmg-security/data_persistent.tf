# 테라폼아, 이미지 속 S3 경로에 있는 공책을 찾아가서 'persistent'이라는 별명으로 기억해줘!
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    # 1. 이미지 속 가장 앞에 있던 S3 버킷 이름
    bucket = "securevoice-terraform-state-455535733131-ap-northeast-2"

    # 2. 버킷 클릭하고 들어갔을 때 나오는 상세 폴더 경로와 파일 이름 (Key)
    key = "securevoice/dev/10-persistent/terraform.tfstate"

    # 3. AWS 서비스 지역 (서울 리전)
    region = "ap-northeast-2"
  }
}