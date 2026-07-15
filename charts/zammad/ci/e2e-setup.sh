#!/usr/bin/env bash
#
# e2e setup for the zammad chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts install`,
# once per fixture:  $1 = release name   $2 = chart directory   $3 = fixture case name
#
# The e2e job runs the `embedded-backing` fixture, which is SELF-CONTAINED: the chart runs its own
# PostgreSQL, Redis, memcached and Elasticsearch on a chart-managed overlay, so nothing external
# needs provisioning — no overlays, no throwaway database. The one thing swarmcli's pre-flight
# still requires is the operator secrets (it never creates them), so this hook creates them with
# dummy values.
#
# INVARIANT: the same secret value backs both sides — the embedded PostgreSQL reads
# zammad_db_password via POSTGRES_PASSWORD_FILE and Zammad reads it via POSTGRESQL_PASS; likewise
# the embedded Redis (--requirepass) and Zammad (REDIS_PASSWORD) share zammad_redis_password. This
# hook owns both, so one $PW is used everywhere.
#
# Idempotent: safe to re-run after a crashed run. ci/e2e-teardown.sh removes what it creates.
set -euo pipefail

PW='test'

# zammad_elasticsearch_password is created too although the embedded fixture does not use it
# (embedded ES runs with security disabled): harmless, and it keeps this hook correct if the e2e
# case is ever switched to an external-ES fixture.
for s in zammad_db_password zammad_redis_password zammad_elasticsearch_password; do
  docker secret inspect "$s" >/dev/null 2>&1 || printf '%s' "$PW" | docker secret create "$s" - >/dev/null
done
