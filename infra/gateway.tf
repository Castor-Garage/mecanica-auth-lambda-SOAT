# API Gateway (HTTP API): porta de entrada unica do sistema.
#
#   POST /auth/cpf         -> Lambda de autenticacao por CPF (sem authorizer)
#   rotas publicas da API  -> API principal no EKS (sem authorizer)
#   ANY /{proxy+}          -> API principal no EKS, depois do jwtAuthorizer
#
# O authorizer e defesa em profundidade (RFC 0003 em mecanica-pos-SOAT): a API
# continua verificando token e perfil em cada rota (requireRole/assertOrderAccess).

# Hostname do Load Balancer da API em producao, publicado no SSM pelo job
# deploy-production do pipeline de mecanica-pos-SOAT. A API precisa ter sido
# publicada ao menos uma vez antes do primeiro apply deste modulo.
data "aws_ssm_parameter" "backend_url" {
  name = var.backend_url_ssm_parameter
}

locals {
  backend_base_url = "http://${data.aws_ssm_parameter.backend_url.insecure_value}:${var.backend_port}"

  # Rotas da API principal que nao exigem token: login do admin (e ele que
  # emite o token), healthcheck, Swagger, webhook de e-mail (autenticado pelo
  # WEBHOOK_SECRET da propria API) e o preflight CORS, que o navegador envia
  # sem Authorization.
  public_backend_routes = toset([
    "POST /auth/login",
    "GET /health",
    "GET /docs",
    "GET /docs/{proxy+}",
    "POST /webhooks/email",
    "OPTIONS /{proxy+}",
  ])

  # Alvo de tentativa em massa (CPFs, senhas de admin): limite menor que o resto
  login_routes = toset(["POST /auth/cpf", "POST /auth/login"])
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.api_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = [var.cors_origin]
    allow_methods  = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers  = ["content-type", "authorization", "x-request-id"]
    expose_headers = ["x-request-id"]
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  count             = var.access_logs_enabled ? 1 : 0
  name              = "/aws/apigateway/${var.api_name}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
    detailed_metrics_enabled = true
  }

  dynamic "route_settings" {
    for_each = local.login_routes
    content {
      route_key                = route_settings.value
      throttling_burst_limit   = var.login_throttling_burst_limit
      throttling_rate_limit    = var.login_throttling_rate_limit
      detailed_metrics_enabled = true
    }
  }

  dynamic "access_log_settings" {
    for_each = var.access_logs_enabled ? [1] : []
    content {
      destination_arn = aws_cloudwatch_log_group.api_gateway[0].arn
      # requestId e o mesmo que a API principal grava nos logs dela (x-request-id)
      format = jsonencode({
        requestId          = "$context.requestId"
        requestTime        = "$context.requestTime"
        ip                 = "$context.identity.sourceIp"
        routeKey           = "$context.routeKey"
        status             = "$context.status"
        responseLatency    = "$context.responseLatency"
        integrationLatency = "$context.integrationLatency"
        integrationError   = "$context.integrationErrorMessage"
        authorizerError    = "$context.authorizer.error"
        role               = "$context.authorizer.role"
      })
    }
  }

  # route_settings referencia as rotas so pelo route_key, sem dependencia implicita
  depends_on = [aws_apigatewayv2_route.auth_cpf, aws_apigatewayv2_route.backend_public]
}

# Repassa o request id do Gateway para a Lambda no header x-request-id, para
# a mesma correlacao de logs (requestId) usada na API principal — ver
# mecanica-pos-SOAT/docs/observabilidade.md.
resource "aws_apigatewayv2_integration" "auth_cpf" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.auth_cpf.invoke_arn
  payload_format_version = "2.0"

  request_parameters = {
    "overwrite:header.x-request-id" = "$context.requestId"
  }
}

resource "aws_apigatewayv2_route" "auth_cpf" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth/cpf"
  target    = "integrations/${aws_apigatewayv2_integration.auth_cpf.id}"
}

# Proxy HTTP para a API principal. Mantem o caminho da requisicao original
# (overwrite:path) e manda o mesmo x-request-id, que a API usa como requestId.
resource "aws_apigatewayv2_integration" "backend" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = local.backend_base_url

  request_parameters = {
    "overwrite:path"                = "$request.path"
    "overwrite:header.x-request-id" = "$context.requestId"
  }
}

resource "aws_apigatewayv2_route" "backend_public" {
  for_each  = local.public_backend_routes
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.backend.id}"
}

resource "aws_apigatewayv2_route" "backend_protected" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.backend.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "jwt-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.jwt_authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.Authorization"]
  # guarda a decisao por token, para nao invocar a Lambda a cada requisicao
  authorizer_result_ttl_in_seconds = var.authorizer_cache_ttl
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_cpf.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jwt_authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt.id}"
}
