# Castor Garage - Auth Lambda (CPF) e API Gateway

Function Serverless de autenticação por CPF e API Gateway do Tech Challenge Fase 3 (SOAT). Repositório 1 dos 4 exigidos pela entrega ("Lambda (Function Serverless)"). O API Gateway fica aqui porque é a porta de entrada tanto da Lambda quanto da [API principal](https://github.com/Castor-Garage/mecanica-pos-SOAT) (ver ADR 0001 e RFC 0003 naquele repositório).

## Propósito

- **Autenticação por CPF** (`src/handler.ts`): substitui o login por e-mail/senha para clientes finais. O cliente informa apenas o CPF, a função valida o dígito verificador, consulta o cliente no banco gerenciado e — se ele existir e estiver com `status = ATIVO` — devolve um JWT que a API principal já sabe validar (`role: client`, ver `src/shared/types/jwt.d.ts` e `src/infrastructure/http/middlewares/auth.middleware.ts` naquele repositório).
- **Authorizer JWT** (`src/authorizer.ts`): confere o token (de cliente ou de admin) antes de o Gateway repassar a requisição para a API principal. É uma camada extra de defesa: a API continua verificando o token e o perfil exigido por cada rota.
- **API Gateway** (`infra/gateway.tf`): porta de entrada única do sistema, com as rotas abaixo, limite de requisições e log de acesso.

Fluxo completo:

```
Cliente → API Gateway → POST /auth/cpf → Lambda de CPF
                                           ├─ valida formato/dígitos do CPF
                                           ├─ consulta tabela `clients` no RDS
                                           └─ assina JWT (HS256, mesmo JWT_SECRET da API)
Cliente ← { token, client }

Cliente → API Gateway, com `Authorization: Bearer <token>`
            ├─ jwtAuthorizer confere o token
            └─ proxy HTTP → API principal (EKS)
```

## Tecnologias

- Node.js 20 + TypeScript
- `pg` (consulta direta à tabela `clients`, sem Prisma — evita empacotar o query engine nativo do Prisma na Lambda)
- `jsonwebtoken` (HS256, compatível com `@fastify/jwt` da API principal)
- `esbuild` (um bundle por Lambda, no mesmo pacote)
- `vitest` (testes)
- Terraform (`infra/`): `aws_lambda_function` + API Gateway HTTP API (`aws_apigatewayv2_*`)
- AWS Academy (Learner Lab): `LabRole` reaproveitado como execution role das Lambdas — a conta não permite criar roles IAM novas (mesmo padrão do repo de infraestrutura Kubernetes)

## Rotas do API Gateway

| Rota | Authorizer | Destino |
|---|---|---|
| `POST /auth/cpf` | — | Lambda de CPF |
| `POST /auth/login` | — | API principal (login do admin, que emite o token) |
| `GET /health`, `GET /docs`, `GET /docs/{proxy+}` | — | API principal (healthcheck e Swagger) |
| `POST /webhooks/email` | — | API principal (protegido pelo `WEBHOOK_SECRET` da própria API) |
| `OPTIONS /{proxy+}` | — | API principal (preflight CORS, que o navegador envia sem token) |
| `ANY /{proxy+}` | `jwtAuthorizer` | API principal (todas as outras rotas) |

Respostas do próprio Gateway, antes de a requisição chegar na API:

| Status | Quando |
|---|---|
| `401` | rota protegida chamada sem header `Authorization` |
| `403` | token inválido, expirado, de outro algoritmo ou sem perfil conhecido |
| `429` | limite de requisições excedido |

Controle e observabilidade:

- **Limite de requisições:** 100 req/s (pico de 200) no geral e 5 req/s (pico de 10) em `POST /auth/cpf` e `POST /auth/login`, para dificultar tentativa de CPFs e senhas em massa. Ajustável pelas variáveis `throttling_*` e `login_throttling_*` — aumente antes de rodar teste de carga passando pelo Gateway.
- **Log de acesso** em JSON no CloudWatch (`/aws/apigateway/castor-garage-api-gateway`): `requestId`, rota, status, latência total e da integração, erro do authorizer e perfil do token. O mesmo `requestId` segue para a API no header `x-request-id`, que ela usa como `requestId` nos próprios logs.
- **Métricas detalhadas por rota** no CloudWatch (latência, 4xx, 5xx).
- **CORS:** libera `Authorization`, `Content-Type`, `X-Request-Id` e todos os métodos usados pela API.

## Endpoint de autenticação

```
POST /auth/cpf
Content-Type: application/json

{ "cpf": "529.982.247-25" }
```

Respostas:

| Status | Quando |
|---|---|
| `200` | `{ "token": "...", "client": { "id": "...", "name": "..." } }` |
| `400` | CPF ausente, malformado ou com dígito verificador inválido |
| `404` | CPF não cadastrado **ou** cliente com status diferente de `ATIVO` (mesma resposta nos dois casos, para não revelar se o CPF existe) |

## Passos para execução local

```bash
npm install
cp .env.example .env    # preencha DATABASE_URL e JWT_SECRET
npm run typecheck
npm test
```

Não há servidor HTTP local incluso (são funções puras `handler(event)`); para testar ponta a ponta, use `sam local` / `aws lambda invoke` apontando pro pacote, ou os testes unitários em `tests/`, que exercitam os handlers diretamente.

## Deploy

**Ordem entre os repositórios:** o Gateway lê do SSM o hostname do Load Balancer da API (`/castor-garage/production/backend-url`), que o job `deploy-production` de `mecanica-pos-SOAT` publica. A API precisa ter sido publicada em produção ao menos uma vez antes do primeiro `apply` daqui. Se o Load Balancer mudar (Service recriado), rode o pipeline deste repositório de novo para o Gateway apontar para o endereço novo.

1. Gerar o pacote: `npm run package` → cria `function.zip` na raiz, com as duas Lambdas (`handler.mjs` e `authorizer.mjs`).
2. `cd infra && terraform init`
3. Definir as variáveis obrigatórias (não têm default, por serem sensíveis):

   ```bash
   export TF_VAR_lab_role_arn="arn:aws:iam::<account-id>:role/LabRole"
   export TF_VAR_database_url="postgresql://usuario:senha@<rds-endpoint>:5432/mecanica_db"
   export TF_VAR_jwt_secret="<o mesmo valor de k8s/secret.yaml na API principal>"
   ```

4. `terraform apply`
5. `terraform output api_endpoint` → é a URL base do sistema: `<endpoint>/auth/cpf` para autenticar e `<endpoint>/<rota>` para a API principal (ex.: `<endpoint>/service-orders/track/OS-2026-00001`).

O pipeline (`.github/workflows/pipeline.yml`) faz os passos 1–4 automaticamente a cada push em `main`, usando os secrets do repositório: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (sessão temporária do AWS Academy), `LAB_ROLE_ARN`, `DATABASE_URL`, `JWT_SECRET`.

**RDS em VPC privada:** se o banco gerenciado não aceitar acesso público, defina `vpc_id`/`subnet_ids` no Terraform para a Lambda de CPF rodar dentro da VPC, e libere o security group criado (`lambda_security_group_id` no output) como origem no security group do RDS. O authorizer não acessa banco e roda fora de VPC.

**Log de acesso no Academy:** se o `apply` falhar com permissão negada ao configurar o log de acesso do Gateway, rode com `-var="access_logs_enabled=false"`.

## Arquitetura deste repositório

```
API Gateway (HTTP API, stage $default, throttling + log de acesso)
   ├─ POST /auth/cpf ──────────AWS_PROXY──▶ Lambda auth_cpf ──pg──▶ RDS PostgreSQL (tabela clients)
   ├─ rotas públicas da API ───HTTP_PROXY─▶ Load Balancer da API principal (EKS)
   └─ ANY /{proxy+} ──▶ jwtAuthorizer ──HTTP_PROXY─▶ Load Balancer da API principal (EKS)
```

Repassa `x-request-id` do contexto do Gateway (`$context.requestId`) para a Lambda e para a API, mantendo a correlação de logs de ponta a ponta (ver `docs/observabilidade.md` na API principal).

## Testes

```bash
npm test
```

Cobre validação de CPF (dígitos verificadores, sequências repetidas, máscara), os caminhos do handler (CPF inválido, cliente inexistente, cliente inativo, sucesso) e do authorizer (token de cliente e de admin aceitos; token ausente, sem `Bearer`, com outro segredo, outro algoritmo, expirado ou sem perfil recusados).
