data "aws_route53_zone" "apideck_com" {
  name         = var.domain_name
  private_zone = false
}

module "apideck_acm_certificate" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 3.0"

  domain_name = "*.${var.domain_name}"
  zone_id     = data.aws_route53_zone.apideck_com.zone_id

  wait_for_validation = true
}
