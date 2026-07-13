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
  default     = ""
}

variable "client_id" {
  type        = string
  description = "Google SSO Client ID for the production workspace"
  default     = "495594039277-u8690qm5okuca05c4upfehie6mqrtcvv.apps.googleusercontent.com"
}

variable "staging_client_id" {
  type        = string
  description = "Google SSO Client ID for the staging workspace (separate OAuth app)"
  default     = "742137882758-kr09odn9r44clo368nugd6e4054l7dpk.apps.googleusercontent.com"
}
