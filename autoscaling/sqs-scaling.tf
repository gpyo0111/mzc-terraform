resource "aws_appautoscaling_policy" "free_worker_sqs_scale_out" {
  name               = "securevoice-free-worker-sqs-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.free_worker.service_namespace
  resource_id        = aws_appautoscaling_target.free_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.free_worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 180
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "paid_worker_sqs_scale_out" {
  name               = "securevoice-paid-worker-sqs-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.paid_worker.service_namespace
  resource_id        = aws_appautoscaling_target.paid_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.paid_worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 180
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 2
    }
  }
}

resource "aws_appautoscaling_policy" "free_worker_sqs_scale_in" {
  name               = "securevoice-free-worker-sqs-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.free_worker.service_namespace
  resource_id        = aws_appautoscaling_target.free_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.free_worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_appautoscaling_policy" "paid_worker_sqs_scale_in" {
  name               = "securevoice-paid-worker-sqs-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.paid_worker.service_namespace
  resource_id        = aws_appautoscaling_target.paid_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.paid_worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "free_queue_visible_high" {
  alarm_name          = "securevoice-free-queue-visible-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.free_queue_name
  }

  alarm_actions = [
    aws_appautoscaling_policy.free_worker_sqs_scale_out.arn
  ]
}

resource "aws_cloudwatch_metric_alarm" "paid_queue_visible_high" {
  alarm_name          = "securevoice-paid-queue-visible-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.paid_queue_name
  }

  alarm_actions = [
    aws_appautoscaling_policy.paid_worker_sqs_scale_out.arn
  ]
}

resource "aws_cloudwatch_metric_alarm" "paid_queue_oldest_age_high" {
  alarm_name          = "securevoice-paid-queue-oldest-age-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 60
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.paid_queue_name
  }

  alarm_actions = [
    aws_appautoscaling_policy.paid_worker_sqs_scale_out.arn
  ]
}

resource "aws_cloudwatch_metric_alarm" "free_queue_empty" {
  alarm_name          = "securevoice-free-queue-empty"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 10
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.free_queue_name
  }

  alarm_actions = [
    aws_appautoscaling_policy.free_worker_sqs_scale_in.arn
  ]
}

resource "aws_cloudwatch_metric_alarm" "paid_queue_empty" {
  alarm_name          = "securevoice-paid-queue-empty"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 10
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.paid_queue_name
  }

  alarm_actions = [
    aws_appautoscaling_policy.paid_worker_sqs_scale_in.arn
  ]
}
