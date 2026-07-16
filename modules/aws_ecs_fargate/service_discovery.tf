# Cloud Map service discovery so the backend can reach the code-executor by
# hostname (code-executor.retoolsvc:3004) inside the VPC — no ALB, never public.
# Shape copied from the sibling modules/aws_ecs service-discovery pattern, minus
# the workflows_enabled count: here the executor is always provisioned.
resource "aws_service_discovery_private_dns_namespace" "retoolsvc" {
  name        = "retoolsvc"
  description = "Service Discovery namespace for Retool deployment"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "code_executor" {
  name = "code-executor"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.retoolsvc.id

    dns_records {
      ttl  = 60
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}
