resource "aws_appautoscaling_scheduled_action" "business_hours_warm_start" {
  name               = "securevoice-business-hours-warm-start"
  service_namespace  = aws_appautoscaling_target.free_worker.service_namespace
  resource_id        = aws_appautoscaling_target.free_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.free_worker.scalable_dimension

  # KST weekday 09:00 = UTC 00:00
  schedule = "cron(10 6 ? * MON-FRI *)"

  scalable_target_action {
    min_capacity = 2
    max_capacity = 2
  }
}

resource "aws_appautoscaling_scheduled_action" "business_hours_warm_start_paid" {
  name               = "securevoice-paid-business-hours-warm-start"
  service_namespace  = aws_appautoscaling_target.paid_worker.service_namespace
  resource_id        = aws_appautoscaling_target.paid_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.paid_worker.scalable_dimension

  # KST weekday 09:00 = UTC 00:00
  schedule = "cron(10 6 ? * MON-FRI *)"

  scalable_target_action {
    min_capacity = 5
    max_capacity = 10
  }
}

resource "aws_appautoscaling_scheduled_action" "business_hours_normal_free" {
  name               = "securevoice-free-business-hours-normal"
  service_namespace  = aws_appautoscaling_target.free_worker.service_namespace
  resource_id        = aws_appautoscaling_target.free_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.free_worker.scalable_dimension

  # KST weekday 18:00 = UTC 09:00
  schedule = "cron(0 9 ? * MON-FRI *)"

  scalable_target_action {
    min_capacity = 1
    max_capacity = 2
  }
}

resource "aws_appautoscaling_scheduled_action" "business_hours_normal_paid" {
  name               = "securevoice-paid-business-hours-normal"
  service_namespace  = aws_appautoscaling_target.paid_worker.service_namespace
  resource_id        = aws_appautoscaling_target.paid_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.paid_worker.scalable_dimension

  # KST weekday 18:00 = UTC 09:00
  schedule = "cron(0 9 ? * MON-FRI *)"

  scalable_target_action {
    min_capacity = 1
    max_capacity = 10
  }
}
