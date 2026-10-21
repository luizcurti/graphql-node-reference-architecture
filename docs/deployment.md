# Deployment (AWS)

Every push to `main` deploys the stack to AWS with GitHub Actions, once the CI
checks pass:

```
           HTTPS / WSS            HTTP (CloudFront ranges only)
client ──► CloudFront ──────────► ALB ──► ECS Fargate: app (Apollo Server, graphql-ws)
                                                │
                                                ├──► RDS MySQL 8.4          (Knex, TLS verified)
                                                ├──► ElastiCache Redis      (subscriptions PubSub,
                                                │                            login rate limiter,
                                                │                            JWT verification cache)
                                                └──► ECS Fargate: kafka     (comment.created,
                                                     kafka.graphql-ref.internal via Cloud Map)
```

| docker-compose service            | AWS                                                                                     |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| `app`                             | ECS Fargate service behind an ALB, HTTPS/WSS through CloudFront's default certificate   |
| `graphql_mysql`                   | RDS MySQL 8.4 (`db.t4g.micro`), `DATABASE_SSL=rds`                                      |
| `redis`                           | ElastiCache Redis 7 (`cache.t4g.micro`), AUTH token + TLS (`rediss://` in `REDIS_URL`)  |
| `kafka`                           | ECS Fargate service (`apache/kafka:3.9.0`, KRaft, one node), Cloud Map private DNS name |
| `npm run db:setup`                | One-off ECS task after every apply (same image, compiled knexfile)                      |
| `jaeger`, `prometheus`, `grafana` | Not deployed: no OTLP endpoint (no tracing overhead), logs in CloudWatch                |

Notes:

- **Seed data is reloaded on every deploy**: the deploy runs `migrate:latest`
  and then the seeds, which truncate and reload the demo rows, exactly like
  `npm run db:setup` in CI. The API collection run by the smoke tests depends
  on those fixed rows (`elisa.pereira`, post `645`, ...).
- **Secrets**: the MySQL password is managed by RDS in Secrets Manager;
  `JWT_SECRET`, `METRICS_TOKEN` and `REDIS_URL` are SSM SecureString
  parameters under `/graphql-ref/`. ECS injects them as environment variables.
- **MySQL 8.4**: docker-compose and CI use 8.0, whose standard support on RDS
  has ended (extended support is billed extra). `DATABASE_SSL=rds` verifies the
  server certificate against the RDS CA bundle bundled with `mysql2`.
- **Kafka** is a single container without persistence: topics and offsets are
  lost if its task restarts. Amazon MSK would be the managed alternative, at a
  much higher hourly cost and with IAM authentication in kafkajs.
- **CORS**: `ALLOWED_ORIGINS` is the API's own CloudFront URL. Add your
  front-end's origin there to call the API from a browser on another site
  (the login cookie is `SameSite=None; Secure`).
- **`/metrics`** requires `X-Metrics-Token` (SSM `/graphql-ref/METRICS_TOKEN`).
- **Network**: public subnets and no NAT gateway (tasks get a public IP to
  reach ECR, Docker Hub, SSM and Secrets Manager). Only the ALB accepts traffic
  from outside the VPC, and only from CloudFront; MySQL, Redis and Kafka only
  accept the app tasks.

## One-time setup

Requirements: Terraform >= 1.10, AWS CLI credentials (admin) of the target
account, and the GitHub CLI logged in with admin access to the repository.

```bash
scripts/bootstrap.sh
```

It applies [`bootstrap/`](../bootstrap) (an S3 bucket for the Terraform state
and an IAM role GitHub Actions assumes through OIDC, scoped to the
`graphql-ref-*` resources and the `production` environment), then creates the
`production` GitHub environment with the `AWS_DEPLOY_ROLE_ARN`,
`TF_STATE_BUCKET` and `AWS_REGION` variables. On an account where no other
project created the GitHub OIDC provider yet, run
`scripts/bootstrap.sh -var="create_oidc_provider=true"`.

## Deploy

Every push to `main` deploys; to deploy without a push:

```bash
gh workflow run ci.yml --repo luizcurti/graphql-node-reference-architecture --ref main
```

The **Deploy to AWS** job creates the ECR repository, builds and pushes the
image, applies [`infra/`](../infra) (the first run takes ~15 minutes, mostly
RDS and ElastiCache), runs the migration + seed task, waits for the ECS
services and runs [`scripts/smoke-test.sh`](../scripts/smoke-test.sh): `/ready`,
`/metrics` locked without the token, the Postman collection (cookie auth,
users, posts, comments, depth/complexity limits, the Redis-backed login rate
limiter), and the app's own `kafka_messages_produced_total` /
`kafka_messages_consumed_total` counters proving the collection's
`createComment` went through Kafka and back.

## Try it

```bash
API=https://xxxx.cloudfront.net   # from the run summary
curl -s $API/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ post(id: \"645\") { id title user { userName } } }"}'
curl -s -c cookies.txt $API/graphql -H 'Content-Type: application/json' \
  -d '{"query":"mutation { login(data: { userName: \"elisa.pereira\", password: \"Senha123\" }) { userId } }"}'
curl -s -b cookies.txt $API/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ users { id userName } }"}'
```

## Destroy

RDS, ElastiCache, the ALB and the Fargate tasks are billed by the hour. Tear
the stack down when you are done (the bootstrap resources are kept):

```bash
gh workflow run destroy.yml --repo luizcurti/graphql-node-reference-architecture --ref main -f confirm=destroy
```

Recreate it with the deploy command above.
