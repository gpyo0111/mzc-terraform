# =========================================================================
# 0. AWS 데이터 소스(Data Source) 정의: 이름 기반 실시간 자원 검색
# =========================================================================

# 1) RDS 보안 그룹 검색 (securevoice-dev-rds-sg)
data "aws_security_group" "rds" {
  name = "${var.project_name}-${var.env}-rds-sg"
}

# 2) ECS 보안 그룹 검색 (securevoice-dev-ecs-sg)
data "aws_security_group" "ecs" {
  name = "${var.project_name}-${var.env}-ecs-sg"
}

# 3) ALB 보안 그룹 검색 (securevoice-dev-alb-sg)
data "aws_security_group" "alb" {
  name = "${var.project_name}-${var.env}-alb-sg"
}

# 4) VPC 엔드포인트 보안 그룹 검색 (securevoice-dev-runtime-vpce-sg)
data "aws_security_group" "vpce" {
  name = "${var.project_name}-${var.env}-runtime-vpce-sg"
}


# =========================================================================
# 1. [ECS -> RDS 체이닝] RDS 보안 그룹에 ECS 서브넷 인입만 허용
# =========================================================================
resource "aws_security_group_rule" "ecs_to_rds_ingress" {
  type      = "ingress"
  from_port = 3306 # 데이터베이스 포트 (PostgreSQL: 5432 / MySQL: 3306)
  to_port   = 3306
  protocol  = "tcp"

  # 규칙이 박힐 대상: 검색해 온 RDS 보안 그룹 ID
  security_group_id = data.aws_security_group.rds.id

  # 허용할 신분증 소스: 검색해 온 ECS 보안 그룹 ID
  source_security_group_id = data.aws_security_group.ecs.id

  description = "Allow database traffic strictly from ECS tasks"
}

# =========================================================================
# [Tuning] 1. AWS 글로벌 인프라에서 관리하는 CloudFront 오리진 직면 Prefix List 룩업
# =========================================================================
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# =========================================================================
# [Tuning] 2. [ALB 보안 하드닝] 외부 전체 개방(0.0.0.0/0)을 차단하고 
#              오직 CloudFront 에지 서버만 HTTPS 진입이 가능하도록 방화벽 락(Lock) 주입
# =========================================================================
resource "aws_security_group_rule" "alb_https_ingress" {
  type      = "ingress"
  from_port = 443
  to_port   = 443
  protocol  = "tcp"

  # 규칙이 박힐 대상: 검색해 온 ALB 보안 그룹 ID 
  security_group_id = data.aws_security_group.alb.id

  # [리팩토링 핵심]: 기존 무차별 cidr_blocks = ["0.0.0.0/0"] 구문을 완전히 폐기하고
  # 위에서 레이더로 추적한 AWS 공식 CloudFront IP 프리픽스 리스트 ID로 대체 바인딩합니다.
  prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]

  description = "Enforce inbound HTTPS traffic strictly from verified CloudFront Edge servers to prevent Origin Bypass"
}

# =========================================================================
# 3. [VPC 엔드포인트 통제] — 제거됨 (2026-06-22)
#   기존: 443 ← 10.0.0.0/22 (VPC 전체 대역) 인입 허용 규칙을 여기서 관리했음.
#   제거 사유: VPCE SG(securevoice-dev-runtime-vpce-sg)에는 인프라 원본 레이어가 만든
#     실제 프라이빗 서브넷 규칙(443 ← 10.0.1.0/25, 10.0.0.128/25)이 이미 존재.
#     /22 는 그 /25 들을 모두 덮는 '더 넓은' 중복 규칙이라, 유지하면 최소권한을 오히려 약화.
#   조사 근거: CloudTrail/Athena 로 /22 는 mzc-pmg(2026-06-09 추가)→mzc-kjh(2026-06-19 회수)
#     확인. /25 는 CloudTrail 보존창(30일) 이전부터 존재 = 타 레이어 소유 베이스라인.
#   결론: VPCE 인입 통제는 소유 레이어의 /25 규칙에 일임하고, pmg-security 는 손대지 않음.
# =========================================================================