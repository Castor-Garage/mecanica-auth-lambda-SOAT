variable "aws_region" {
  description = "Regiao AWS do Learner Lab (confira no painel 'AWS Details' do Academy)"
  type        = string
  default     = "us-east-1"
}

variable "function_name" {
  description = "Nome da funcao Lambda"
  type        = string
  default     = "castor-garage-auth-cpf"
}

variable "authorizer_function_name" {
  description = "Nome da Lambda authorizer que confere o JWT nas rotas da API principal"
  type        = string
  default     = "castor-garage-jwt-authorizer"
}

variable "api_name" {
  description = "Nome do HTTP API (API Gateway), porta de entrada unica: autenticacao por CPF e proxy para a API principal"
  type        = string
  default     = "castor-garage-api-gateway"
}

variable "lab_role_arn" {
  description = "ARN do LabRole fornecido pela AWS Academy (arn:aws:iam::<account-id>:role/LabRole). Reaproveitado como execution role da Lambda, ja que o Academy nao permite criar IAM roles novas — mesmo padrao usado em mecanica-pos-SOAT/infra/aws."
  type        = string
}

variable "database_url" {
  description = "Connection string do banco gerenciado (RDS) — mesma base da API principal. Ex.: postgresql://usuario:senha@host:5432/mecanica_db"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "Mesmo JWT_SECRET configurado na API principal (k8s/secret.yaml) — o token so e aceito pela API se o segredo bater dos dois lados."
  type        = string
  sensitive   = true
}

variable "jwt_expires_in" {
  description = "Validade do token emitido"
  type        = string
  default     = "8h"
}

variable "cors_origin" {
  description = "Origem liberada no header CORS da resposta"
  type        = string
  default     = "*"
}

variable "function_zip_path" {
  description = "Caminho do pacote da Lambda gerado por `npm run package` (../function.zip)"
  type        = string
  default     = "../function.zip"
}

variable "vpc_id" {
  description = "VPC onde a Lambda deve rodar para alcancar o RDS (VPC default do Academy, normalmente). Deixe em branco para rodar a Lambda fora de VPC (so funciona se o RDS aceitar acesso publico)."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Subnets para a Lambda, quando vpc_id for definido."
  type        = list(string)
  default     = []
}

variable "backend_url_ssm_parameter" {
  description = "Parametro SSM com o hostname do Load Balancer da API principal em producao, publicado pelo job deploy-production do pipeline de mecanica-pos-SOAT"
  type        = string
  default     = "/castor-garage/production/backend-url"
}

variable "backend_port" {
  description = "Porta do Service LoadBalancer da API principal (k8s/api/base/service.yaml em mecanica-pos-SOAT)"
  type        = number
  default     = 3000
}

variable "authorizer_cache_ttl" {
  description = "Segundos que o Gateway guarda a decisao do authorizer para o mesmo token (0 desliga o cache). A API verifica o token de novo em toda requisicao, entao um token que expira dentro dessa janela continua sendo barrado por ela."
  type        = number
  default     = 300
}

variable "throttling_rate_limit" {
  description = "Requisicoes por segundo aceitas pelo Gateway em regime, em todas as rotas exceto as de login. Aumente antes de rodar teste de carga passando pelo Gateway."
  type        = number
  default     = 100
}

variable "throttling_burst_limit" {
  description = "Pico de requisicoes aceito pelo Gateway, em todas as rotas exceto as de login"
  type        = number
  default     = 200
}

variable "login_throttling_rate_limit" {
  description = "Requisicoes por segundo em POST /auth/cpf e POST /auth/login: limite menor para dificultar tentativa de CPFs e senhas em massa"
  type        = number
  default     = 5
}

variable "login_throttling_burst_limit" {
  description = "Pico de requisicoes em POST /auth/cpf e POST /auth/login"
  type        = number
  default     = 10
}

variable "access_logs_enabled" {
  description = "Grava o log de acesso do Gateway no CloudWatch (requestId, rota, status, latencia). Desligue se a conta do Academy negar a criacao da entrega de logs."
  type        = bool
  default     = true
}
