variable "domain_name" {
  type = string
}
variable "domain_name_sm" {
  type = string
}
variable "certificate_arn" {
  type = string
}
variable "cognito_user_pool_arn" {
  type = string
}
variable "env" {
  type = string
}

variable "vpc_link_id" {
  description = "VPC Link ID to use in API Gateway integrations"
  type        = string
}

variable "deployment_name" {
  type = string
}