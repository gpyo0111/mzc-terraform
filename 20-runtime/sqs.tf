resource "aws_sqs_queue" "free_dlq" {
  name                      = "free-dlq"
  message_retention_seconds = 1209600

  tags = local.common_tags
}

resource "aws_sqs_queue" "paid_dlq" {
  name                      = "paid-dlq"
  message_retention_seconds = 1209600

  tags = local.common_tags
}

resource "aws_sqs_queue" "free" {
  name                       = "free-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.free_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "paid" {
  name                       = "paid-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.paid_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}