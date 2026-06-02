resource "aws_appautoscaling_target" "free_worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.free_worker_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = 1
  max_capacity = 2
}

resource "aws_appautoscaling_target" "paid_worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.paid_worker_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = 1
  max_capacity = 10
}
