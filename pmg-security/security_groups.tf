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
  type                     = "ingress"
  from_port                = 5432 # 데이터베이스 포트 (PostgreSQL: 5432 / MySQL: 3306)
  to_port                  = 5432
  protocol                 = "tcp"
  
  # 규칙이 박힐 대상: 검색해 온 RDS 보안 그룹 ID
  security_group_id        = data.aws_security_group.rds.id
  
  # 허용할 신분증 소스: 검색해 온 ECS 보안 그룹 ID
  source_security_group_id = data.aws_security_group.ecs.id
  
  description              = "Allow database traffic strictly from ECS tasks"
}

# =========================================================================
# 2. [ALB 보안 하드닝] 최전방 정문에 HTTPS(443) 암호화 통로 개방
# =========================================================================
resource "aws_security_group_rule" "alb_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  
  # 규칙이 박힐 대상: 검색해 온 ALB 보안 그룹 ID
  security_group_id = data.aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
  
  description       = "Allow HTTPS encrypted traffic from internet"
}

# =========================================================================
# 3. [VPC 엔드포인트 통제] 사설 엔드포인트를 VPC 내부 대역(10.0.0.0/22)으로 제한
# =========================================================================
resource "aws_security_group_rule" "vpc_endpoint_private_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  
  # 규칙이 박힐 대상: 검색해 온 VPCE 보안 그룹 ID
  security_group_id = data.aws_security_group.vpce.id
  cidr_blocks       = ["10.0.0.0/22"] # 아키텍처 상의 전체 VPC 대역 할당
  
  description       = "Restrict VPC Endpoint access strictly to internal VPC CIDR block"
}