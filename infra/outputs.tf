output "api_endpoint" {
  description = "URL base do API Gateway: <valor>/auth/cpf para autenticar e <valor>/<rota> para a API principal"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.auth_cpf.function_name
}

output "authorizer_function_name" {
  value = aws_lambda_function.jwt_authorizer.function_name
}

output "backend_base_url" {
  description = "Destino do proxy do Gateway (Load Balancer da API principal, lido do SSM)"
  value       = local.backend_base_url
}

output "lambda_security_group_id" {
  description = "So existe quando vpc_id foi definido. Adicione como origem permitida no security group do RDS."
  value       = local.use_vpc ? aws_security_group.lambda[0].id : null
}
