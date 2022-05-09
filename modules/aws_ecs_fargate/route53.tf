resource "aws_route53_record" "apideck_com" {
  name    = "overwatch.${var.domain_name}"
  type    = "A"
  zone_id = data.aws_route53_zone.apideck_com.id

  alias {
    evaluate_target_health = true
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
  }
}
