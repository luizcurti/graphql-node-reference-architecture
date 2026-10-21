#!/usr/bin/env bash
# End-to-end check of the AWS deployment, run by the CI deploy job after every
# deploy (and runnable by hand):
#   1. /ready (MySQL reachable) and /metrics locked behind X-Metrics-Token;
#   2. the Postman collection CI runs locally (auth with the httpOnly cookie,
#      users, posts, comments, security limits, the Redis-backed login rate
#      limiter), against the seed data loaded by the deploy;
#   3. the Kafka event backbone: the collection's createComment must have been
#      produced to Kafka AND consumed back by the subscription consumer, read
#      from the app's own kafka_messages_*_total counters.
#
# Usage: API_URL=https://xxxx.cloudfront.net METRICS_TOKEN=... scripts/smoke-test.sh
set -euo pipefail

: "${API_URL:?set API_URL, e.g. https://xxxx.cloudfront.net}"
: "${METRICS_TOKEN:?set METRICS_TOKEN (SSM /graphql-ref/METRICS_TOKEN)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "::error title=Smoke test::$*"
  echo "FAIL: $*" >&2
  exit 1
}

# Sum of a Prometheus counter across all its label sets (0 when absent).
counter() {
  curl -sS "$API_URL/metrics" -H "X-Metrics-Token: $METRICS_TOKEN" |
    awk -v name="$1" '$1 == name || index($1, name "{") == 1 { sum += $2 } END { print sum + 0 }'
}

echo "== readiness"
for _ in $(seq 1 30); do
  curl -sf "$API_URL/ready" > /dev/null && break
  sleep 5
done
curl -sf "$API_URL/ready" || fail "/ready did not report MySQL ok"
echo

echo "== /metrics requires the token"
status=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/metrics")
[ "$status" = "401" ] || fail "GET /metrics without X-Metrics-Token returned $status, expected 401"

consumed_before=$(counter kafka_messages_consumed_total)

echo "== Postman collection"
npx --yes newman@6.2.2 run "$REPO_ROOT/graphql-node.postman_collection.json" \
  --env-var "baseUrl=$API_URL/graphql" \
  --reporters cli

echo "== Kafka: comment.created produced and consumed"
produced=0
consumed=0
for _ in $(seq 1 15); do
  produced=$(counter kafka_messages_produced_total)
  consumed=$(counter kafka_messages_consumed_total)
  [ "$produced" != "0" ] && [ "$consumed" != "$consumed_before" ] && break
  sleep 2
done
echo "kafka_messages_produced_total=$produced kafka_messages_consumed_total=$consumed"
[ "$produced" != "0" ] || fail "no message was produced to Kafka (KAFKA_BROKERS not wired?)"
[ "$consumed" != "$consumed_before" ] || fail "the comment consumer never received the comment.created event from Kafka"

echo "All smoke tests passed."
