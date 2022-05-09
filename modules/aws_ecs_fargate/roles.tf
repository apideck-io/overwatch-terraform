data "aws_caller_identity" "current" {}

data "aws_iam_policy" "ecs_task_execution_role_policy" {
  name = "AmazonECSTaskExecutionRolePolicy"
}

# ECS Task roles
data "aws_iam_policy_document" "assume_role_ecs_task" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ssm_paramstore_access" {
  statement {
    actions = [
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:eu-central-1:${data.aws_caller_identity.current.account_id}:parameter/*"
    ]
  }
}

resource "aws_iam_policy" "ssm_paramstore_access" {
  name        = "${var.deployment_name}-ecs-to-ssm-${var.environment}"
  description = "ecs task access to SSM"
  policy      = data.aws_iam_policy_document.ssm_paramstore_access.json
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.deployment_name}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_ecs_task.json
  managed_policy_arns = [
    aws_iam_policy.ssm_paramstore_access.arn,
    data.aws_iam_policy.ecs_task_execution_role_policy.arn
  ]
}

data "aws_iam_policy_document" "task_role_assume_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_role" {
  name               = "${var.deployment_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_role_assume_policy.json
  path               = "/"
}

data "aws_iam_policy_document" "service_role_assume_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "service_role_policy" {
  statement {
    actions = [
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:RegisterTargets",
      "ec2:Describe*",
      "ec2:AuthorizeSecurityGroupIngress"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "service_role" {
  name               = "${var.deployment_name}-service-role"
  assume_role_policy = data.aws_iam_policy_document.service_role_assume_policy.json
  path               = "/"

  inline_policy {
    name   = "${var.deployment_name}-service-policy"
    policy = data.aws_iam_policy_document.service_role_policy.json
  }
}
