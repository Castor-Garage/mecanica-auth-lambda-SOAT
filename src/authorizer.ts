// Lambda authorizer do API Gateway (tipo REQUEST, payload 2.0, resposta
// simples). Protege a rota ANY /{proxy+}, que repassa as requisições para a
// API principal no EKS: só deixa passar quem apresenta um JWT válido,
// emitido pela Lambda de CPF (role client) ou pelo /auth/login de admin da
// API (role admin).
//
// É defesa em profundidade (RFC 0003 em mecanica-pos-SOAT): a API continua
// verificando o token e o perfil exigido por cada rota
// (requireRole/assertOrderAccess). Aqui só se confere assinatura, validade e
// formato do payload.
import type {
  APIGatewayRequestAuthorizerEventV2,
  APIGatewaySimpleAuthorizerResult,
  APIGatewaySimpleAuthorizerWithContextResult,
} from 'aws-lambda'
import { verifyToken, type AuthTokenPayload } from './jwt.js'

type AuthorizerResult =
  | APIGatewaySimpleAuthorizerResult
  | APIGatewaySimpleAuthorizerWithContextResult<AuthTokenPayload>

export async function handler(
  event: APIGatewayRequestAuthorizerEventV2,
): Promise<AuthorizerResult> {
  // HTTP API entrega os nomes de header em minúsculas
  const token = /^Bearer\s+(\S+)$/i.exec(event.headers?.authorization ?? '')?.[1]
  const payload = token ? verifyToken(token) : null

  if (!payload) {
    return { isAuthorized: false }
  }

  // sub/role ficam disponíveis no log de acesso do Gateway ($context.authorizer.role)
  return { isAuthorized: true, context: payload }
}
