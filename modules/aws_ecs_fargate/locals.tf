locals {
  environment_variables = concat(
    var.additional_env_vars, # add additional environment variables
    [
      {
        name  = "NODE_ENV"
        value = var.node_env
      },
      {
        name  = "FORCE_DEPLOYMENT"
        value = tostring(var.force_deployment)
      },
      {
        name  = "POSTGRES_DB"
        value = "hammerhead_production"
      },
      {
        name  = "POSTGRES_HOST"
        value = module.rds_cluster.cluster_endpoint
      },
      {
        name  = "POSTGRES_SSL_ENABLED"
        value = "false"
      },
      {
        name  = "POSTGRES_SSL_REJECT_UNAUTHORIZED"
        value = "false"
      },
      {
        name  = "POSTGRES_PORT"
        value = "5432"
      },
      {
        "name"  = "POSTGRES_USER",
        "value" = var.rds_username
      },
      {
        "name"  = "POSTGRES_PASSWORD",
        "value" = random_string.rds_password.result
      },
      {
        "name" : "JWT_SECRET",
        "value" : random_string.jwt_secret.result
      },
      {
        "name" : "ENCRYPTION_KEY",
        "value" : random_string.encryption_key.result
      }
    ]
  )
}
