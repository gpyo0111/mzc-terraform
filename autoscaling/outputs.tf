output "free_worker_scalable_target" {
  value = aws_appautoscaling_target.free_worker.resource_id
}

output "paid_worker_scalable_target" {
  value = aws_appautoscaling_target.paid_worker.resource_id
}
