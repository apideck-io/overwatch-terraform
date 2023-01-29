data "aws_ssm_parameter" "retool_license_key" {
  name = "/overwatch/${local.stage}/RETOOL_LICENSE_KEY"
}
data "aws_ssm_parameter" "magement_api_key" {
  name = "/unify/${terraform.workspace == "production" ? "prod" : "staging"}/API_GATEWAY_API_KEY"
}

module "retool" {
  source = "./modules/aws_ecs_fargate"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  deployment_name    = "overwatch"
  aws_region         = "eu-central-1"
  vpc_id             = module.platform_network.vpc_id
  private_subnet_ids = [for subnet in module.platform_network.main_private_subnets : subnet.id]
  public_subnet_ids  = [for subnet in module.platform_network.main_public_subnets : subnet.id]
  # ssh_key_pair = "<your-key-pair>"
  ecs_retool_image = "tryretool/backend:2.103.7"
  domain_name      = local.domain_name

  retool_license_key    = data.aws_ssm_parameter.retool_license_key.arn
  log_retention_in_days = 7

  management_api_key    = data.aws_ssm_parameter.magement_api_key.arn

  environment = local.environment
  stage       = local.stage
  # ecs_insights_enabled = true
  additional_env_vars = [{
    name  = "DOMAINS",
    value = "overwatch.${local.domain_name}"
    }, {
    name  = "BASE_DOMAIN",
    value = "https://overwatch.${local.domain_name}"
    }, {
    name  = "DISABLE_INTERCOM",
    value = "true"
    }, {
    name  = "DISABLE_USER_PASS_LOGIN",
    value = "true"
    }, {
    name  = "RESTRICTED_DOMAIN",
    value = "apideck.com"
    }, {
    name  = "HIDE_PROD_AND_STAGING_TOGGLES",
    value = "true"
    }, {
    name  = "DISABLE_GIT_SYNCING"
    value = "true"
    }, {
    name  = "TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY"
    value = "true"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_CLIENT_ID"
    value = var.client_id
    }, {
    name  = "CUSTOM_OAUTH2_SSO_SCOPES"
    value = "openid email profile https://www.googleapis.com/auth/userinfo.profile"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_AUTH_URL"
    value = "https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_TOKEN_URL"
    value = "https://oauth2.googleapis.com/token"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_JWT_EMAIL_KEY"
    value = "idToken.email"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_JWT_FIRST_NAME_KEY"
    value = "idToken.given_name"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_JWT_LAST_NAME_KEY"
    value = "idToken.family_name"
    }, {
    name  = "CUSTOM_OAUTH2_SSO_ACCESS_TOKEN_LIFESPAN_MINUTES"
    value = "45"
    }, {
    name  = "DATABASE_MIGRATIONS_TIMEOUT_SECONDS"
    value = "900"
    }
  ]

  alb_ingress_rules = [{

    description      = "Global HTTPS inbound"
    from_port        = "443"
    to_port          = "443"
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]

  }]
}

module "platform_network" {
  source = "./modules/platform_network"

  prefix      = local.prefix
  project     = local.project
  environment = local.environment
  stage       = local.stage
}
