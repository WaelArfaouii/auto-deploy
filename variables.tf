variable "domain_name" {
  type = string
}
variable "domain_name_sm" {
  type = string
}
variable "env" {
  type = string
}
variable "cognito_user_pool_arn" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "vpc_link_id" {
  type = string
}
variable "frontend_alb_domain" {
  type = string
}

variable "frontend_alb_zone_id" {
  type = string
}
variable "hosted_zone_count" {
  type = number
}
variable "frontend_subdomains" {
  description = "Frontend subdomains (e.g. { client1 = true })"
  type        = map(bool)
  default     = {}
}
variable "api_gateway_deployments" {
  type = map(object({
    deployment_name           = string
    cognito_user_pool_arn = string
  }))
  default = {}
}
