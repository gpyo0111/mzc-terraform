data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "jenkins" {
  id = data.terraform_remote_state.network.outputs.private_app_subnet_ids[0]
}

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-${var.env}-jenkins-sg"
  description = "Jenkins EC2 security group"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "Jenkins webhook from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-jenkins-sg"
    Role = "cicd"
  })
}

resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-${var.env}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Role = "cicd"
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "jenkins_deploy" {
  name = "${var.project_name}-${var.env}-jenkins-deploy-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [
          data.aws_ecr_repository.api.arn,
          data.aws_ecr_repository.worker.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeClusters",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.api_task.arn,
          aws_iam_role.worker_task.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_deploy" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins_deploy.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-${var.env}-jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = data.aws_subnet.jenkins.id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = false

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    dnf update -y
    dnf install -y docker git python3 python3-pip awscli
    systemctl enable --now docker

    mkdir -p /var/jenkins_home
    for i in $(seq 1 30); do
      if [ -b /dev/xvdf ]; then
        break
      fi
      sleep 2
    done
    if ! blkid /dev/xvdf; then
      mkfs -t xfs /dev/xvdf
    fi
    echo "/dev/xvdf /var/jenkins_home xfs defaults,nofail 0 2" >> /etc/fstab
    mount -a
    chown -R 1000:1000 /var/jenkins_home

    mkdir -p /opt/jenkins
    cat > /opt/jenkins/Dockerfile <<'DOCKERFILE'
    FROM jenkins/jenkins:lts-jdk17

    USER root
    RUN apt-get update && \
        apt-get install -y --no-install-recommends \
          awscli \
          docker.io \
          git \
          python3 \
          python3-pip \
          python3-venv && \
        rm -rf /var/lib/apt/lists/*
    USER jenkins
    DOCKERFILE

    cat > /opt/jenkins/docker-compose.yml <<'COMPOSE'
    services:
      jenkins:
        build: .
        container_name: jenkins
        restart: unless-stopped
        ports:
          - "8080:8080"
          - "50000:50000"
        environment:
          - DOCKER_HOST=unix:///var/run/docker.sock
          - DOCKER_BUILDKIT=1
        volumes:
          - /var/jenkins_home:/var/jenkins_home
          - /var/run/docker.sock:/var/run/docker.sock
    COMPOSE

    docker compose -f /opt/jenkins/docker-compose.yml up -d
  EOF

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.jenkins_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.env}-jenkins-home"
      Role = "cicd"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-jenkins-ec2"
    Role = "cicd"
  })
}

resource "aws_lb_target_group" "jenkins" {
  name        = "${var.project_name}-${var.env}-jenkins-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/login"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Role = "cicd"
  })
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 8080
}

resource "aws_lb_listener_rule" "jenkins_webhook" {
  count        = var.enable_jenkins_webhook_alb_rule ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/github-webhook/*", "/github-webhook/"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}
