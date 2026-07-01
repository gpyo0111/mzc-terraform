# =============================================================================
# graceful-shutdown: AI Worker Graceful Shutdown Patch
#
# 이 모듈은 기존 배포된 free-worker와 paid-worker 서비스에
# Graceful Shutdown 기능을 주입합니다.
# original worker.py 코드를 직접 수정하는 대신, 컨테이너의 entrypoint를
# 오버라이드하여 S3에 저장된 랩퍼 스크립트를 다운로드하고 실행하도록 합니다.
# =============================================================================

# ── remote state 참조 ────────────────────────────────────────────────────────
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/10-persistent/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}

data "terraform_remote_state" "runtime" {
  backend = "s3"

  config = {
    bucket         = "securevoice-terraform-state-455535733131-ap-northeast-2"
    key            = "securevoice/dev/20-runtime/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "securevoice-terraform-lock"
    encrypt        = true
  }
}

# ── S3에 랩퍼 스크립트 업로드 ────────────────────────────────────────────────
resource "aws_s3_object" "graceful_worker" {
  bucket = data.terraform_remote_state.persistent.outputs.model_bucket_name
  key    = "scripts/graceful_worker.py"
  source = "${path.module}/graceful_worker.py"
  etag   = filemd5("${path.module}/graceful_worker.py")
}

# ── 기존 ECS Cluster & Service 조회 ──────────────────────────────────────────
data "aws_ecs_cluster" "main" {
  cluster_name = data.terraform_remote_state.runtime.outputs.ecs_cluster_name
}

# ── Free Worker 태스크 정의 및 서비스 패치 ──────────────────────────────────────
data "aws_ecs_service" "free_worker" {
  cluster_arn  = data.aws_ecs_cluster.main.arn
  service_name = data.terraform_remote_state.runtime.outputs.free_worker_service_name
}

data "aws_ecs_task_definition" "free_worker" {
  task_definition = data.aws_ecs_service.free_worker.task_definition
}

locals {
  free_containers = jsondecode(data.aws_ecs_task_definition.free_worker.container_definitions)
  
  # "free-worker" 컨테이너만 골라서 entryPoint를 수정하고, adot 등 다른 컨테이너는 유지
  # Terraform의 삼항 연산자 타입 일관성을 위해 merge 내부에서 conditional map으로 결합
  patched_free_containers = [
    for c in local.free_containers :
    merge(c, c.name == "free-worker" ? {
      entryPoint = [
        "sh",
        "-c",
        "python -c \"import boto3, os; boto3.client('s3').download_file(os.environ['MODEL_S3_BUCKET'], 'scripts/graceful_worker.py', 'graceful_worker.py')\" && exec python -u graceful_worker.py"
      ]
    } : {
      entryPoint = lookup(c, "entryPoint", null)
    })
  ]
}

resource "aws_ecs_task_definition" "free_worker" {
  family                   = data.aws_ecs_task_definition.free_worker.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = data.aws_ecs_task_definition.free_worker.cpu
  memory                   = data.aws_ecs_task_definition.free_worker.memory
  execution_role_arn       = data.aws_ecs_task_definition.free_worker.execution_role_arn
  task_role_arn            = data.aws_ecs_task_definition.free_worker.task_role_arn
  
  container_definitions = jsonencode(local.patched_free_containers)
  
  depends_on = [aws_s3_object.graceful_worker]
}

resource "terraform_data" "update_free_service" {
  triggers_replace = [
    aws_ecs_task_definition.free_worker.arn
  ]

  provisioner "local-exec" {
    command = "aws ecs update-service --cluster ${data.aws_ecs_cluster.main.cluster_name} --service ${data.terraform_remote_state.runtime.outputs.free_worker_service_name} --task-definition ${aws_ecs_task_definition.free_worker.arn}"
  }
}

# ── Paid Worker 태스크 정의 및 서비스 패치 ──────────────────────────────────────
data "aws_ecs_service" "paid_worker" {
  cluster_arn  = data.aws_ecs_cluster.main.arn
  service_name = data.terraform_remote_state.runtime.outputs.paid_worker_service_name
}

data "aws_ecs_task_definition" "paid_worker" {
  task_definition = data.aws_ecs_service.paid_worker.task_definition
}

locals {
  paid_containers = jsondecode(data.aws_ecs_task_definition.paid_worker.container_definitions)
  
  # "paid-worker" 컨테이너만 골라서 entryPoint를 수정하고, adot 등 다른 컨테이너는 유지
  # Terraform의 삼항 연산자 타입 일관성을 위해 merge 내부에서 conditional map으로 결합
  patched_paid_containers = [
    for c in local.paid_containers :
    merge(c, c.name == "paid-worker" ? {
      entryPoint = [
        "sh",
        "-c",
        "python -c \"import boto3, os; boto3.client('s3').download_file(os.environ['MODEL_S3_BUCKET'], 'scripts/graceful_worker.py', 'graceful_worker.py')\" && exec python -u graceful_worker.py"
      ]
    } : {
      entryPoint = lookup(c, "entryPoint", null)
    })
  ]
}

resource "aws_ecs_task_definition" "paid_worker" {
  family                   = data.aws_ecs_task_definition.paid_worker.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = data.aws_ecs_task_definition.paid_worker.cpu
  memory                   = data.aws_ecs_task_definition.paid_worker.memory
  execution_role_arn       = data.aws_ecs_task_definition.paid_worker.execution_role_arn
  task_role_arn            = data.aws_ecs_task_definition.paid_worker.task_role_arn
  
  container_definitions = jsonencode(local.patched_paid_containers)
  
  depends_on = [aws_s3_object.graceful_worker]
}

resource "terraform_data" "update_paid_service" {
  triggers_replace = [
    aws_ecs_task_definition.paid_worker.arn
  ]

  provisioner "local-exec" {
    command = "aws ecs update-service --cluster ${data.aws_ecs_cluster.main.cluster_name} --service ${data.terraform_remote_state.runtime.outputs.paid_worker_service_name} --task-definition ${aws_ecs_task_definition.paid_worker.arn}"
  }
}
