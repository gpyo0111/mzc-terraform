output "free_queue_url" {
  value = aws_sqs_queue.free.url
}

output "paid_queue_url" {
  value = aws_sqs_queue.paid.url
}

output "free_dlq_url" {
  value = aws_sqs_queue.free_dlq.url
}

output "paid_dlq_url" {
  value = aws_sqs_queue.paid_dlq.url
}

output "alb_dns_name" {
  value = aws_lb.api.dns_name
}

output "api_target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "api_ecr_repository_url" {
  value = data.aws_ecr_repository.api.repository_url
}

output "worker_ecr_repository_url" {
  value = data.aws_ecr_repository.worker.repository_url
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "free_worker_service_name" {
  value = aws_ecs_service.free_worker.name
}

output "paid_worker_service_name" {
  value = aws_ecs_service.paid_worker.name
}

output "jenkins_instance_id" {
  value = aws_instance.jenkins.id
}

output "jenkins_target_group_arn" {
  value = aws_lb_target_group.jenkins.arn
}
