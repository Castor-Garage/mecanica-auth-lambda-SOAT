# Provisiona as Functions Serverless deste repositorio, seguindo o mesmo
# padrao AWS Academy usado em mecanica-k8s-infra-SOAT (LabRole reaproveitado
# como execution role, nada de IAM role nova, credenciais via variaveis de
# ambiente padrao AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN):
#
#   - auth_cpf: autenticacao por CPF (POST /auth/cpf)
#   - jwt_authorizer: authorizer do API Gateway nas rotas da API principal
#
# O API Gateway que expoe as duas fica em gateway.tf.
#
# Pre-requisito: `npm run package` na raiz do repo, que gera ../function.zip
# com src/handler.ts e src/authorizer.ts (ver package.json).

locals {
  use_vpc = var.vpc_id != ""
}

# Necessaria so quando a Lambda roda dentro da VPC (para alcancar um RDS
# privado). Libera todo trafego de saida; a entrada no RDS e controlada pelo
# security group do banco (adicionar esta SG como origem la).
resource "aws_security_group" "lambda" {
  count       = local.use_vpc ? 1 : 0
  name        = "${var.function_name}-sg"
  description = "Egress da Lambda de autenticacao por CPF"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lambda_function" "auth_cpf" {
  function_name = var.function_name
  role          = var.lab_role_arn
  handler       = "handler.handler"
  runtime       = "nodejs20.x"

  filename         = var.function_zip_path
  source_code_hash = filebase64sha256(var.function_zip_path)

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      DATABASE_URL   = var.database_url
      JWT_SECRET     = var.jwt_secret
      JWT_EXPIRES_IN = var.jwt_expires_in
      CORS_ORIGIN    = var.cors_origin
    }
  }

  dynamic "vpc_config" {
    for_each = local.use_vpc ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = [aws_security_group.lambda[0].id]
    }
  }
}

resource "aws_cloudwatch_log_group" "auth_cpf" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 14
}

# Confere o JWT (de cliente ou de admin) antes de o Gateway repassar a
# requisicao para a API principal. Nao acessa banco, entao roda fora de VPC.
resource "aws_lambda_function" "jwt_authorizer" {
  function_name = var.authorizer_function_name
  role          = var.lab_role_arn
  handler       = "authorizer.handler"
  runtime       = "nodejs20.x"

  # mesmo pacote da Lambda de CPF: o zip traz handler.mjs e authorizer.mjs
  filename         = var.function_zip_path
  source_code_hash = filebase64sha256(var.function_zip_path)

  timeout     = 5
  memory_size = 128

  environment {
    variables = {
      JWT_SECRET = var.jwt_secret
    }
  }
}

resource "aws_cloudwatch_log_group" "jwt_authorizer" {
  name              = "/aws/lambda/${var.authorizer_function_name}"
  retention_in_days = 14
}
