resource "aws_lb" "this" {
  name         = "${var.deployment_name}-alb"
  idle_timeout = var.alb_idle_timeout

  security_groups = [aws_security_group.alb.id]
  subnets         = var.public_subnet_ids
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = module.apideck_acm_certificate.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = aws_lb_listener.this.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.deployment_name}-target"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  port                 = 3000
  target_type          = "ip"
  protocol             = "HTTP"

  health_check {
    interval            = 30
    path                = "/api/checkHealth"
    protocol            = "HTTP"
    timeout             = 20
    healthy_threshold   = 3
    unhealthy_threshold = 2
    port                = 3000
  }

  # lifecycle {
  #   create_before_destroy = true
  # }
}

# resource "aws_lb_target_group" "this" {
#   name                 = "${var.deployment_name}-target"
#   vpc_id               = var.vpc_id
#   deregistration_delay = 30
#   port                 = 8080
#   target_type          = "ip"
#   protocol             = "HTTP"

#   health_check {
#     interval            = 10
#     path                = "/api/checkHealth"
#     protocol            = "HTTP"
#     timeout             = 5
#     healthy_threshold   = 3
#     unhealthy_threshold = 2
#     port                = "traffic-port"
#   }

#   protocol_version = "HTTP1"

#   # NOTE: TF is unable to destroy a target group while a listener is attached,
#   # therefor we have to create a new one before destroying the old. This also means
#   # we have to let it have a random name, and then tag it with the desired name.
#   lifecycle {
#     create_before_destroy = true
#   }
# }
