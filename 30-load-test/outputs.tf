output "locust_ecr_repository_url" {
  description = "Locust 이미지를 푸시할 ECR URL"
  value       = aws_ecr_repository.locust.repository_url
}

output "locust_master_service_name" {
  value = aws_ecs_service.locust_master.name
}

output "locust_worker_service_name" {
  value = aws_ecs_service.locust_worker.name
}

output "cloud_map_namespace" {
  description = "Locust master DNS: locust-master.load-test.local"
  value       = aws_service_discovery_private_dns_namespace.load_test.name
}

output "cloudwatch_log_group_master" {
  value = aws_cloudwatch_log_group.locust_master.name
}

output "cloudwatch_log_group_worker" {
  value = aws_cloudwatch_log_group.locust_worker.name
}
