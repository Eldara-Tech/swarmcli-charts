#!/usr/bin/env bash
#
# e2e setup for the airbyte chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# Only the mock fixture deploys (the rest are ci/e2e-render-only). It needs everything the
# chart treats as external, so this hook provides, with dummy values:
#   * the six operator secrets and the airbyte-db-net / traefik-public overlays;
#   * the airbyte-data node label the session Redis is pinned to;
#   * PostgreSQL (airbyte-e2e-postgres) on airbyte-db-net. Its user is a superuser, so
#     Temporal's auto-setup can create its temporal and temporal_visibility databases;
#   * MinIO (airbyte-e2e-minio) as the S3 endpoint. Airbyte creates its bucket itself;
#   * an OIDC discovery mock (airbyte-e2e-oidc, ci/mock-oidc.js) on traefik-public, without
#     which oauth2-proxy exits at startup.
# ci/e2e-teardown.sh removes everything created here except the shared traefik-public.
#
# INVARIANT: the Postgres user/password and the MinIO root user/password equal the values of
# the airbyte_db_* and airbyte_s3_* secrets; the hook owns both sides.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

chart_dir="$2"
DB_USER=airbyte
DB_PW=test
S3_KEY=airbyte-e2e
S3_SECRET=airbyte-e2e-secret
ISSUER=http://airbyte-e2e-oidc:8080/realms/airbyte   # == ci/mock-values.yaml oauth2.issuerUrl

secret() {
  docker secret inspect "$1" >/dev/null 2>&1 \
    || printf '%s' "$2" | docker secret create "$1" - >/dev/null
}
secret airbyte_db_user "$DB_USER"
secret airbyte_db_password "$DB_PW"
secret airbyte_s3_access_key "$S3_KEY"
secret airbyte_s3_secret_key "$S3_SECRET"
secret airbyte_oauth_client_secret test
docker secret inspect airbyte_oauth_cookie_secret >/dev/null 2>&1 \
  || dd if=/dev/urandom bs=32 count=1 2>/dev/null | docker secret create airbyte_oauth_cookie_secret - >/dev/null

docker network create --driver overlay --attachable airbyte-db-net >/dev/null 2>&1 || true
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add airbyte-data=true "$node" >/dev/null

docker service rm airbyte-e2e-postgres airbyte-e2e-minio airbyte-e2e-oidc >/dev/null 2>&1 || true
docker config rm airbyte-e2e-mock-oidc >/dev/null 2>&1 || true
docker config create airbyte-e2e-mock-oidc "$chart_dir/ci/mock-oidc.js" >/dev/null

docker service create --name airbyte-e2e-postgres --network airbyte-db-net \
  --env POSTGRES_DB=airbyte --env POSTGRES_USER="$DB_USER" --env POSTGRES_PASSWORD="$DB_PW" \
  postgres:17-alpine >/dev/null
docker service create --name airbyte-e2e-minio --network airbyte-db-net \
  --env MINIO_ROOT_USER="$S3_KEY" --env MINIO_ROOT_PASSWORD="$S3_SECRET" \
  quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z server /data >/dev/null
docker service create --name airbyte-e2e-oidc --network traefik-public \
  --config source=airbyte-e2e-mock-oidc,target=/mock.js --env ISSUER="$ISSUER" \
  node:22-alpine node /mock.js >/dev/null

# Wait for all three to run (image pulls), then until Postgres accepts TCP connections: during
# first init the entrypoint's temporary server listens on the socket only, so a socket probe
# would report ready while initdb is still running.
for svc in airbyte-e2e-postgres airbyte-e2e-minio airbyte-e2e-oidc; do
  for _ in $(seq 1 60); do
    state="$(docker service ps "$svc" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done
done
for _ in $(seq 1 40); do
  cid="$(docker ps -q -f label=com.docker.swarm.service.name=airbyte-e2e-postgres | sed -n 1p)"
  if [ -n "$cid" ] && docker exec "$cid" pg_isready -h 127.0.0.1 -U "$DB_USER" -d airbyte >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
