terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 4.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.deployment_name}-ecs"

  setting {
    name  = "containerInsights"
    value = var.ecs_insights_enabled
  }

  tags = {
    monitor_site24x7 = "true"
    support          = var.stage == "production" ? "gold" : "standard"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE"]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "${var.deployment_name}-ecs-log-group"
  retention_in_days = var.log_retention_in_days
}

resource "aws_ecs_service" "retool" {
  name                               = "${var.deployment_name}-main-service"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.retool.arn
  desired_count                      = var.min_instance_count - 1
  deployment_maximum_percent         = var.maximum_percent
  deployment_minimum_healthy_percent = var.minimum_healthy_percent
  launch_type                        = "FARGATE"

  # A new task runs the Retool migration stack on first boot. On big upgrade
  # hops that takes minutes; without a grace period the ALB health check
  # (~60s) kills the task mid-migration and the deploy never rolls forward.
  # Match DATABASE_MIGRATIONS_TIMEOUT_SECONDS so the migration can finish.
  health_check_grace_period_seconds = 1800

  # Surface a genuinely failed deploy instead of churning silently on the old
  # task def. rollback is intentionally false: Retool migrations apply on boot
  # and are not reversible in-place, so auto-reverting to the previous image
  # would run old code against a migrated Aurora schema — an outage. Recovery
  # is operator-driven via the runbook's snapshot-restore path.
  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  network_configuration {
    security_groups = [aws_security_group.ec2.id]
    subnets         = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "retool"
    container_port   = 3000
  }
}

resource "aws_ecs_service" "jobs_runner" {
  name            = "${var.deployment_name}-jobs-runner-service"
  cluster         = aws_ecs_cluster.this.id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_jobs_runner.arn
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ec2.id]
    subnets         = var.private_subnet_ids
  }
}

resource "aws_ecs_task_definition" "retool_jobs_runner" {
  family = "retool"
  # Both task defs share family "retool"; ECS rejects concurrent revision
  # creates on one family. Serialize so image bumps don't race.
  depends_on    = [aws_ecs_task_definition.retool]
  task_role_arn = aws_iam_role.task_role.arn


  network_mode = "awsvpc"
  cpu          = "512"
  # Retool 3.114+ base memory is ~20% higher; 1024 was too tight for the
  # jobs-runner. 512 CPU / 2048 MB is a valid Fargate combo.
  memory                   = "2048"
  requires_compatibilities = ["FARGATE"]

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode(
    [
      {
        name      = "retool-jobs-runner"
        essential = true
        image     = var.ecs_retool_image
        cpu       = 512
        memory    = 2048
        command = [
          "./docker_scripts/start_api.sh"
        ]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.this.id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL"
          }
        }

        portMappings = [
          {
            containerPort = 3000
            hostPort      = 3000
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              name  = "SERVICE_TYPE"
              value = "JOBS_RUNNER"
            }
          ]
        )

        secrets = [
          {
            "name" : "LICENSE_KEY",
            "valueFrom" : var.retool_license_key
          }
        ]
      }
    ]
  )
}
resource "aws_ecs_task_definition" "retool" {
  family             = "retool"
  task_role_arn      = aws_iam_role.task_role.arn
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  network_mode       = "awsvpc"
  cpu                = "2048"
  # Main backend (MAIN_BACKEND,DB_CONNECTOR) runs the migration stack on boot.
  # Retool 3.114+ base memory is ~20% higher; the old container hard limit of
  # 2048 MB OOM-killed (exit 137) mid-migration on this hop. Give the task 8 GB
  # and the container 6 GB (see ecs_task_memory) for the migration spike.
  memory                   = "8192"
  requires_compatibilities = ["FARGATE"]
  container_definitions = jsonencode(
    [
      {
        name      = "retool"
        essential = true
        image     = var.ecs_retool_image
        cpu       = var.ecs_task_cpu
        memory    = var.ecs_task_memory
        command = [
          "./docker_scripts/start_api.sh"
        ]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.this.id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL"
          }
        }

        portMappings = [
          {
            containerPort = 3000
            hostPort      = 3000
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              name  = "SERVICE_TYPE"
              value = "MAIN_BACKEND,DB_CONNECTOR"
            },
            {
              "name"  = "COOKIE_INSECURE",
              "value" = tostring(var.cookie_insecure)
            }
          ]
        )

        secrets = [
          {
            "name" : "LICENSE_KEY",
            "valueFrom" : var.retool_license_key
          },
          {
            "name" : "CUSTOM_OAUTH2_SSO_CLIENT_SECRET",
            "valueFrom" : data.aws_ssm_parameter.google_oauth2_sso_client_secret.arn
          },
          {
            "name" : "RETOOL_EXPOSED_MANAGEMENT_API_KEY",
            "valueFrom" : var.management_api_key
          },
        ]
      }
    ]
  )
}
