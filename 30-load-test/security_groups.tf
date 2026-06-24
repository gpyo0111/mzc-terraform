# ── Locust Master 포트 ──────────────────────────────────────────────────────
#   5557/5558 : Locust master ↔ worker 통신 (gRPC 스트림)
#   8089      : Locust Web UI (VPC 내부에서만 접근)

resource "aws_security_group" "locust_master" {
  name        = "${var.project_name}-${var.env}-locust-master-sg"
  description = "Locust master: allow worker connections and web UI"
  vpc_id      = data.aws_vpc.main.id

  # Locust 워커 → 마스터 gRPC
  ingress {
    description     = "Locust worker gRPC"
    from_port       = 5557
    to_port         = 5558
    protocol        = "tcp"
    security_groups = [aws_security_group.locust_worker.id]
  }

  # VPC 내부 → 마스터 Web UI (8089)
  ingress {
    description = "Locust Web UI from VPC"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-locust-master-sg"
  })
}

resource "aws_security_group" "locust_worker" {
  name        = "${var.project_name}-${var.env}-locust-worker-sg"
  description = "Locust worker: outbound to ALB target + master"
  vpc_id      = data.aws_vpc.main.id

  # 워커 → 마스터 gRPC 는 egress all로 커버됨

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-locust-worker-sg"
  })
}
