provider "aws" {
  region  = "eu-central-1"
  profile = var.aws_profile
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
  default_tags {
    tags = local.tags
  }
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    dynamodb_table = "terraform-lock"
    bucket         = "apideck-terraform-s3"
    key            = "terraform/overwatch"
    region         = "eu-central-1"
    encrypt        = true

    profile        = "apideck-staging"
    assume_role = {
      role_arn     = "arn:aws:iam::708245472192:role/tf-state-role"
      session_name = "Terraform"
      external_id  = "terraform-state"
    }
  }
  required_version = ">= 0.13"
}

