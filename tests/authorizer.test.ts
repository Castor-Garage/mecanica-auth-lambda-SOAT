import type { APIGatewayRequestAuthorizerEventV2 } from 'aws-lambda'
import jwt, { type Algorithm } from 'jsonwebtoken'
import { describe, expect, it } from 'vitest'
import { handler } from '../src/authorizer.js'

const SECRET = 'segredo-de-teste'
process.env.JWT_SECRET = SECRET

function eventWith(authorization?: string): APIGatewayRequestAuthorizerEventV2 {
  return {
    headers: authorization === undefined ? {} : { authorization },
  } as unknown as APIGatewayRequestAuthorizerEventV2
}

function sign(payload: object, secret = SECRET, algorithm: Algorithm = 'HS256'): string {
  return jwt.sign(payload, secret, { algorithm, expiresIn: '1h' })
}

describe('authorizer', () => {
  it('autoriza token de cliente e repassa sub/role no contexto', async () => {
    const result = await handler(eventWith(`Bearer ${sign({ sub: 'c1', role: 'client' })}`))
    expect(result).toEqual({ isAuthorized: true, context: { sub: 'c1', role: 'client' } })
  })

  it('autoriza token de admin emitido pelo /auth/login da API', async () => {
    const token = sign({ sub: 'a1', role: 'admin', email: 'admin@oficina.com' })
    const result = await handler(eventWith(`Bearer ${token}`))
    expect(result).toEqual({ isAuthorized: true, context: { sub: 'a1', role: 'admin' } })
  })

  it('nega requisição sem header Authorization', async () => {
    expect(await handler(eventWith())).toEqual({ isAuthorized: false })
  })

  it('nega header sem o prefixo Bearer', async () => {
    const token = sign({ sub: 'c1', role: 'client' })
    expect(await handler(eventWith(`Token ${token}`))).toEqual({ isAuthorized: false })
  })

  it('nega token assinado com outro segredo', async () => {
    const token = sign({ sub: 'c1', role: 'client' }, 'outro-segredo')
    expect(await handler(eventWith(`Bearer ${token}`))).toEqual({ isAuthorized: false })
  })

  it('nega token assinado com algoritmo diferente de HS256', async () => {
    const token = sign({ sub: 'c1', role: 'client' }, SECRET, 'HS512')
    expect(await handler(eventWith(`Bearer ${token}`))).toEqual({ isAuthorized: false })
  })

  it('nega token expirado', async () => {
    const expired = jwt.sign(
      { sub: 'c1', role: 'client', exp: Math.floor(Date.now() / 1000) - 60 },
      SECRET,
      { algorithm: 'HS256' },
    )
    expect(await handler(eventWith(`Bearer ${expired}`))).toEqual({ isAuthorized: false })
  })

  it('nega token sem perfil conhecido', async () => {
    const semRole = sign({ sub: 'c1' })
    const roleDesconhecido = sign({ sub: 'c1', role: 'superuser' })
    expect(await handler(eventWith(`Bearer ${semRole}`))).toEqual({ isAuthorized: false })
    expect(await handler(eventWith(`Bearer ${roleDesconhecido}`))).toEqual({ isAuthorized: false })
  })
})
