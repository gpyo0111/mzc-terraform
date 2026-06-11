data "aws_iam_policy_document" "chatbot_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "chatbot_role" {
  name               = "${var.project_name}-${var.environment}-chatbot-role"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "chatbot_readonly" {
  role       = aws_iam_role.chatbot_role.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "chatbot_cloudwatch_readonly" {
  role       = aws_iam_role.chatbot_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}