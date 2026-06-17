# =========================================================================
# 1. 비동기 AI 워커(Worker) 전용 인바운드 제로(Zero-Inbound) 보안 그룹 선언
# =========================================================================
resource "aws_security_group" "worker_runtime_isolation" {
  name        = "${var.project_name}-${var.env}-worker-runtime-sg"
  description = "Strictly isolated Security Group for asynchronous AI Worker tasks with ZERO inbound rules"
  vpc_id      = var.vpc_id # 기존 데이터 소스로 스캔해 둔 핵심 VPC ID를 매핑합니다.

  # -----------------------------------------------------------------------
  # [하드닝 핵심] ingress 블록(인바운드 규칙)을 아예 작성하지 않습니다.
  # 이로써 외부 인터넷 및 내부 ALB 등 그 어떤 엔티티도 워커 컨테이너 포트로의 
  # 네트워크 접근 시도 자체가 프로토콜 레벨에서 원천 드롭(Drop)됩니다.
  # -----------------------------------------------------------------------

  # -----------------------------------------------------------------------
  # [아웃바운드 허용] SQS 큐 폴링 및 S3 멀티파트 업로드를 위한 외부 통로 개방
  # -----------------------------------------------------------------------
  egress {
    description = "Allow outbound traffic for SQS polling, S3 object management, and ECR image layers download"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # 모든 프로토콜 통신 개방
    cidr_blocks = ["0.0.0.0/0"] # NAT 게이트웨이 및 사설 VPCE 통신 경로 허용
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-worker-runtime-sg"
  })
}