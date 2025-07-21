variable "domain_name_sm" {
  type = string
}
variable "api_gateway_domain" {
  type = map(string)
}
variable "api_gateway_zone_id" {
  type = map(string)
}

variable "frontend_alb_domain" {
  type = string
}
variable "frontend_alb_zone_id" {
  type = string
}
variable "frontend_subdomains" {
  description = "Frontend subdomains (e.g. { client1 = true })"
  type        = map(bool)
  default     = {}
}

variable "api_gateway_deployments" {
  type = map(object({
    deployment_name       = string
    cognito_user_pool_arn = string
  }))
  default = {}
}
variable "api_gateway_custom_domain" {
  type = map(string)
}
