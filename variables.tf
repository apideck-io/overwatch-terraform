locals {
  prefix      = "overwatch"
  project     = "Overwatch"
  environment = terraform.workspace
  stage       = terraform.workspace == "production" ? "production" : "staging" //  production or staging
  domain_name = terraform.workspace == "production" ? "apideck.com" : "stagingapideck.com"
  tags = {
    Application = local.project
    Environment = terraform.workspace
  }
}

variable "aws_profile" {
  type        = string
  description = "AWS Profile to use for deployment"
}

variable "client_id" {
  type        = string
  description = "Google SSO Client ID"
}
