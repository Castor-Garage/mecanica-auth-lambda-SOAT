// Assina e confere tokens compatíveis com o que a API principal espera de
// @fastify/jwt: HS256, mesmo JWT_SECRET, payload { sub, role, email? }
// (ver mecanica-pos-SOAT/src/shared/types/jwt.d.ts). A API não sabe (nem
// precisa saber) que esse token veio de uma Lambda — só verifica assinatura
// e formato do payload.
import jwt, { type SignOptions } from 'jsonwebtoken'

export type ClientTokenPayload = {
  sub: string
  role: 'client'
}

// Tokens aceitos pelo authorizer do Gateway: de cliente (emitidos por esta
// Lambda) ou de admin (emitidos pelo /auth/login da API principal)
export type AuthTokenPayload = {
  sub: string
  role: 'admin' | 'client'
}

export function signClientToken(clientId: string): string {
  const secret = process.env.JWT_SECRET
  if (!secret) {
    throw new Error('JWT_SECRET não configurado na Lambda')
  }

  const payload: ClientTokenPayload = { sub: clientId, role: 'client' }

  const options: SignOptions = {
    algorithm: 'HS256',
    expiresIn: (process.env.JWT_EXPIRES_IN ?? '8h') as SignOptions['expiresIn'],
  }

  return jwt.sign(payload, secret, options)
}

// null para token inválido, expirado, assinado com outro algoritmo ou sem
// sub/role conhecidos. JWT_SECRET ausente é erro de configuração e sobe como
// exceção, igual em signClientToken.
export function verifyToken(token: string): AuthTokenPayload | null {
  const secret = process.env.JWT_SECRET
  if (!secret) {
    throw new Error('JWT_SECRET não configurado na Lambda')
  }

  try {
    const decoded = jwt.verify(token, secret, { algorithms: ['HS256'] })
    if (typeof decoded === 'string' || typeof decoded.sub !== 'string') {
      return null
    }
    const role: unknown = decoded.role
    if (role === 'admin' || role === 'client') {
      return { sub: decoded.sub, role }
    }
    return null
  } catch {
    return null
  }
}
