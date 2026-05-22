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