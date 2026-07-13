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

# Re-added: this us-east-1 wildcard cert is still in use (CloudFront requires
# us-east-1 certs), so deleting it fails with ResourceInUseException and hangs
# every apply. Keep it managed until the consumer is decommissioned.
module "apideck_acm_certificate_east" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 3.0"

  providers = {
    aws = aws.us_east_1
  }

  domain_name = "*.${var.domain_name}"
  zone_id     = data.aws_route53_zone.apideck_com.zone_id

  wait_for_validation = true
}
