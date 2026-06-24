# ── CloudWatch Log Groups ────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "locust_master" {
  name              = "/ecs/${var.project_name}-${var.env}-locust-master"
  retention_in_days = 7

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "locust_worker" {
  name              = "/ecs/${var.project_name}-${var.env}-locust-worker"
  retention_in_days = 7

  tags = local.common_tags
}

# ── Locust Master Task Definition ────────────────────────────────────────────
#
#  --master                  : 마스터 모드로 실행
#  --master-bind-host 0.0.0.0: 워커의 접속을 모든 인터페이스에서 수신
#  --headless --autostart    : Web UI 없이 자동 시작 (ECS 환경)
#  --run-time                : 지정 시간 경과 후 자동 종료
#  --users / --spawn-rate    : 목표 동시 유저 및 램프업 속도

resource "aws_ecs_task_definition" "locust_master" {
  family                   = "${var.project_name}-${var.env}-locust-master"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = var.locust_master_cpu
  memory = var.locust_master_memory

  execution_role_arn = aws_iam_role.locust_task_execution.arn
  task_role_arn      = aws_iam_role.locust_task.arn

  container_definitions = jsonencode([
    {
      name      = "locust-master"
      image     = local.locust_image
      essential = true

      command = [
        "--master",
        "--master-bind-host", "0.0.0.0",
        "--headless",
        "--autostart",
        "--run-time", var.locust_run_time,
        "--users", tostring(var.locust_users),
        "--spawn-rate", tostring(var.locust_spawn_rate),
        "--host", var.target_host,
        "--expect-workers", tostring(var.locust_worker_count),
      ]

      environment = [
        { name = "TARGET_HOST", value = var.target_host },
        { name = "AUDIO_S3_BUCKET", value = var.audio_s3_bucket },
        { name = "AUDIO_S3_PREFIX", value = var.audio_s3_prefix },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      portMappings = [
        # Locust master ↔ worker gRPC
        { containerPort = 5557, hostPort = 5557, protocol = "tcp" },
        { containerPort = 5558, hostPort = 5558, protocol = "tcp" },
        # Web UI (NLB 또는 포트포워딩으로 접근)
        { containerPort = 8089, hostPort = 8089, protocol = "tcp" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.locust_master.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "master"
        }
      }
    }
  ])

  tags = local.common_tags
}

# ── Locust Worker Task Definition ────────────────────────────────────────────
#
#  워커는 마스터의 private IP를 알아야 한다.
#  ECS Service Connect 대신, 마스터 서비스에 고정 DNS 이름을 부여하는
#  aws_service_discovery_service (Cloud Map)를 사용한다.
#  마스터 DNS: locust-master.load-test.local

resource "aws_ecs_task_definition" "locust_worker" {
  family                   = "${var.project_name}-${var.env}-locust-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = var.locust_worker_cpu
  memory = var.locust_worker_memory

  execution_role_arn = aws_iam_role.locust_task_execution.arn
  task_role_arn      = aws_iam_role.locust_task.arn

  container_definitions = jsonencode([
    {
      name      = "locust-worker"
      image     = local.locust_image
      essential = true

      command = [
        "--worker",
        "--master-host", "locust-master.load-test.local",
      ]

      environment = [
        { name = "TARGET_HOST", value = var.target_host },
        { name = "AUDIO_S3_BUCKET", value = var.audio_s3_bucket },
        { name = "AUDIO_S3_PREFIX", value = var.audio_s3_prefix },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.locust_worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "worker"
        }
      }
    }
  ])

  tags = local.common_tags
}

# ── Cloud Map (Service Discovery) ────────────────────────────────────────────

resource "aws_service_discovery_private_dns_namespace" "load_test" {
  name        = "load-test.local"
  description = "Private DNS for Locust master-worker discovery"
  vpc         = data.aws_vpc.main.id

  tags = local.common_tags
}

resource "aws_service_discovery_service" "locust_master" {
  name = "locust-master"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.load_test.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}

# ── ECS Services ─────────────────────────────────────────────────────────────

resource "aws_ecs_service" "locust_master" {
  name            = "${var.project_name}-${var.env}-locust-master"
  cluster         = data.terraform_remote_state.runtime.outputs.ecs_cluster_name
  task_definition = aws_ecs_task_definition.locust_master.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    # private_app_subnet에 배치 → 기존 서비스와 동일 VPC 내 직접 통신
    subnets          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
    security_groups  = [aws_security_group.locust_master.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.locust_master.arn
  }

  tags = local.common_tags
}

resource "aws_ecs_service" "locust_worker" {
  name            = "${var.project_name}-${var.env}-locust-worker"
  cluster         = data.terraform_remote_state.runtime.outputs.ecs_cluster_name
  task_definition = aws_ecs_task_definition.locust_worker.arn
  desired_count   = var.locust_worker_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
    security_groups  = [aws_security_group.locust_worker.id]
    assign_public_ip = false
  }

  # 마스터가 먼저 올라온 후 워커 시작
  depends_on = [aws_ecs_service.locust_master]

  tags = local.common_tags
}
