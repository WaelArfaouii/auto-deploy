data "aws_route53_zone" "primary" {
  name         = "${var.domain_name_sm}.com"
  private_zone = false
}

resource "aws_route53_record" "api_gateway_domains" {
  for_each = var.api_gateway_custom_domain
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "${each.key}-api.${var.domain_name_sm}.com"
  type    = "A"
  alias {
    name                   = var.api_gateway_domain[each.key]
    zone_id                = var.api_gateway_zone_id[each.key]
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "frontend_custom" {
  for_each = var.frontend_subdomains
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "${each.key}.${var.domain_name_sm}.com"
  type    = "A"

  alias {
    name                   = var.frontend_alb_domain
    zone_id                = var.frontend_alb_zone_id
    evaluate_target_health = true
  }
}