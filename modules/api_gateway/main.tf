resource "aws_api_gateway_rest_api" "main" {
  name = "${var.domain_name}-${var.deployment_name}-${var.env}-api"
}

# -------------------- Protected Routes --------------------
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "root_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito_auth.id
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito_auth.id

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "root_integration" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_rest_api.main.root_resource_id
  http_method             = aws_api_gateway_method.root_any.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_method" "proxy_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "proxy_options_integration" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_options.http_method
  type                    = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "proxy_options_response_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "proxy_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_options.http_method
  status_code = aws_api_gateway_method_response.proxy_options_response_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'DELETE,GET,HEAD,OPTIONS,PATCH,POST,PUT'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.proxy_options_integration]
}

resource "aws_api_gateway_method_response" "proxy_response_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "proxy_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy.http_method
  status_code = aws_api_gateway_method_response.proxy_response_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  depends_on = [aws_api_gateway_integration.proxy]
}

# -------------------- Swagger UI (Public) --------------------
resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "swagger_ui" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "swagger-ui"
}

resource "aws_api_gateway_resource" "swagger_ui_index" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.swagger_ui.id
  path_part   = "index.html"
}

resource "aws_api_gateway_method" "swagger_ui_index_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.swagger_ui_index.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "swagger_ui_index_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.swagger_ui_index.id
  http_method             = aws_api_gateway_method.swagger_ui_index_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/api/v1/swagger-ui/index.html"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
}

resource "aws_api_gateway_resource" "swagger_ui_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.swagger_ui.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "swagger_ui_proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.swagger_ui_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "swagger_ui_proxy_any" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.swagger_ui_proxy.id
  http_method             = aws_api_gateway_method.swagger_ui_proxy_any.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/api/v1/swagger-ui/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# -------------------- Deployment and Authorizer --------------------
resource "aws_api_gateway_authorizer" "cognito_auth" {
  name            = "cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  identity_source = "method.request.header.Authorization"
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
}

resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.root_integration,
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.proxy_options_integration,
    aws_api_gateway_integration.swagger_ui_index_get,
    aws_api_gateway_integration.swagger_ui_proxy_any,
    aws_api_gateway_integration.swagger_json_get,
    aws_api_gateway_integration.api_docs_proxy_any,
    aws_api_gateway_integration.api_docs_get,
  ]

  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode({
      resources = [
        aws_api_gateway_resource.proxy.id,
        aws_api_gateway_resource.swagger_ui_index.id,
        aws_api_gateway_resource.swagger_ui_proxy.id,
        aws_api_gateway_resource.swagger_json.id,
        aws_api_gateway_resource.api_docs.id,
        aws_api_gateway_resource.api_docs_proxy.id,
      ],
      methods = [
        aws_api_gateway_method.root_any.http_method,
        aws_api_gateway_method.proxy.http_method,
        aws_api_gateway_method.proxy_options.http_method,
        aws_api_gateway_method.swagger_ui_index_get.http_method,
        aws_api_gateway_method.swagger_ui_proxy_any.http_method,
        aws_api_gateway_method.swagger_json_get.http_method,
        aws_api_gateway_method.api_docs_proxy_any.http_method,
        aws_api_gateway_method.api_docs_get.http_method,
      ],
      integrations = [
        aws_api_gateway_integration.root_integration.id,
        aws_api_gateway_integration.proxy.id,
        aws_api_gateway_integration.proxy_options_integration.id,
        aws_api_gateway_integration.swagger_ui_index_get.id,
        aws_api_gateway_integration.swagger_ui_proxy_any.id,
        aws_api_gateway_integration.swagger_json_get.id,
        aws_api_gateway_integration.api_docs_proxy_any.id,
        aws_api_gateway_integration.api_docs_get.id,
      ]
    }))
  }
}

resource "aws_api_gateway_stage" "main" {
  stage_name    = var.env
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_domain_name" "main" {
  domain_name              = "${var.deployment_name}-api.${var.domain_name_sm}.com"
  regional_certificate_arn = var.certificate_arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "main" {
  api_id      = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  domain_name = aws_api_gateway_domain_name.main.domain_name
}

resource "aws_api_gateway_resource" "swagger_json" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.v1.id  # under /api/v1
  path_part   = "swagger.json"
}

resource "aws_api_gateway_method" "swagger_json_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.swagger_json.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "swagger_json_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.swagger_json.id
  http_method             = aws_api_gateway_method.swagger_json_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/api/v1/swagger.json"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
}

resource "aws_api_gateway_resource" "api_docs" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "api-docs"
}

resource "aws_api_gateway_resource" "api_docs_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api_docs.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "api_docs_proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.api_docs_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "api_docs_proxy_any" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.api_docs_proxy.id
  http_method             = aws_api_gateway_method.api_docs_proxy_any.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/api/v1/api-docs/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_method" "api_docs_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.api_docs.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "api_docs_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.api_docs.id
  http_method             = aws_api_gateway_method.api_docs_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://scheme-management-qa-back-nlb-7b0c87d3b157aa32.elb.eu-west-2.amazonaws.com/api/v1/api-docs"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
}


