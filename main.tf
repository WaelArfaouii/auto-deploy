module "api_gateway" {
  source = "./modules/api_gateway"
  for_each             = var.api_gateway_deployments
  domain_name     = var.domain_name
  domain_name_sm     = var.domain_name_sm
  cognito_user_pool_arn = each.value.cognito_user_pool_arn
  deployment_name = each.value.deployment_name
  certificate_arn = var.certificate_arn
  vpc_link_id     = var.vpc_link_id
  env             = var.env
}
module "route53" {
  source                = "./modules/route53"
  domain_name_sm        = var.domain_name_sm
  frontend_alb_domain   = var.frontend_alb_domain
  frontend_alb_zone_id  = var.frontend_alb_zone_id
  frontend_subdomains   = var.frontend_subdomains
  api_gateway_custom_domain = { for k, m in module.api_gateway : k => m.custom_domain_name }
  api_gateway_domain = { for k, m in module.api_gateway : k => m.regional_domain_name }
  api_gateway_zone_id = { for k, m in module.api_gateway : k => m.regional_zone_id }


}