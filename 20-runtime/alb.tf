resource "aws_lb" "api" {
  name               = "${var.project_name}-${var.env}-api-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb.id]
  subnets         = var.public_subnet_ids

  tags = local.common_tags
}

resource "aws_lb_target_group" "api" {
  name        = "${var.project_name}-${var.env}-api-tg"
  port        = var.api_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"securevoice api alb\"}"
      status_code  = "200"
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}