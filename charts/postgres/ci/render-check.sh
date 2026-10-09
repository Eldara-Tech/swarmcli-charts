#!/usr/bin/env bash
#
# Render assertions for the postgres chart. scripts/test-charts.sh runs this after a successful
# render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is the metrics opt-in, whose mistakes all deploy and converge just fine:
#
#   * Metrics are off unless asked for. With them off, nothing but the database renders, and
#     nothing joins the metrics overlay.
#   * The database never joins the metrics overlay and never mounts the exporter's secret:
#     everything on that overlay could reach its SQL port, and turning metrics on would restart
#     it. Only the exporter is scraped, and it carries exactly the two discovery labels, because
#     every deploy label of an opted-in service is readable through Prometheus's targets API.
#   * The exporter logs in as its own role, with the password read from the mounted secret, never
#     as the superuser and never with a password in its environment.
#   * The one-shot holding the superuser password stays off the metrics overlay, grants
#     pg_monitor and nothing wider, and never puts the exporter's password on a command line.
#
# No check pipes into `grep -q` (scripts/lint.sh enforces it): match with `grep … >/dev/null` or
# a here-string.
set -euo pipefail

rendered="${1:?rendered stack file}"
case="${2:-}"

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -F mikefarah >/dev/null; then
  echo "    ERROR: mikefarah yq v4 is required by render-check.sh (a skipped check reads exactly like a passing one)" >&2
  exit 1
fi

fail=0
bad() { echo "    FAIL: $*" >&2; fail=1; }
q() { yq -r "$1" "$rendered"; }

services="$(q '.services | keys | .[]' | sort | tr '\n' ' ')"
db='.services.postgres'
dbnets="$(q "$db.networks | join(\" \")")"

# The database renders the same in every fixture: one overlay, no exporter secret, no discovery
# labels.
[ "$(q "$db.networks | length")" = "1" ] || bad "postgres is on more than its own overlay: $dbnets"
if q "$db.secrets[]" | grep -F exporter >/dev/null; then
  bad "postgres mounts an exporter secret; turning metrics on would restart it"
fi
if q "$db.deploy.labels // [] | .[]" | grep -F 'prometheus.io/' >/dev/null; then
  bad "postgres carries discovery labels; the exporter is what Prometheus scrapes"
fi

if [ "$case" != "metrics" ]; then
  [ "$services" = "postgres " ] || bad "case $case: services are '$services'; metrics must be opt-in"
  [ "$(q '.networks.monitoring')" = "null" ] || bad "case $case: the metrics overlay is declared although metrics are off"
  exit "$fail"
fi

# ── metrics ──────────────────────────────────────────────────────────────────────────────────
[ "$services" = "postgres postgres-exporter postgres-exporter-user " ] \
  || bad "services are '$services', expected postgres, postgres-exporter and postgres-exporter-user"

e='.services."postgres-exporter"'
[ "$(q "$e.networks | join(\" \")")" = "$dbnets monitoring" ] \
  || bad "the exporter's networks are '$(q "$e.networks | join(\" \")")', expected the database's overlay and monitoring"
[ "$(q '.networks.monitoring.external')" = "true" ] || bad "monitoring is not declared external: Prometheus would not share it"
lbls="$(q "$e.deploy.labels // [] | sort | join(\",\")")"
[ "$lbls" = "prometheus.io/port=9187,prometheus.io/scrape=true" ] \
  || bad "the exporter's deploy labels are '$lbls', expected exactly the two discovery labels"
[ "$(q "$e.ports // [] | length")" = "0" ] || bad "the exporter publishes a port; /metrics has no authentication"
[ "$(q "$e.secrets | join(\" \")")" = "postgres_exporter_password" ] \
  || bad "the exporter mounts '$(q "$e.secrets | join(\" \")")', expected only its own secret"
[ "$(q '.secrets.postgres_exporter_password.external')" = "true" ] || bad "postgres_exporter_password is not declared external"
[ "$(q "$e.environment.DATA_SOURCE_PASS_FILE")" = "/run/secrets/postgres_exporter_password" ] \
  || bad "the exporter does not read its password from the mounted secret"
[ "$(q "$e.environment.DATA_SOURCE_USER")" = "exporter" ] || bad "the exporter does not log in as the exporter role"
for k in DATA_SOURCE_PASS DATA_SOURCE_NAME; do
  [ "$(q "$e.environment.$k")" = "null" ] || bad "the exporter sets $k, which puts a password in the service spec"
done
grep -Ex 'tasks\.[A-Za-z0-9_.-]+_postgres:5432/postgres\?sslmode=disable' <<<"$(q "$e.environment.DATA_SOURCE_URI")" >/dev/null \
  || bad "the exporter does not scrape tasks.<release>_postgres:5432/postgres (got '$(q "$e.environment.DATA_SOURCE_URI")')"
[ "$(yq -o=json -I=0 "$e.deploy.placement" "$rendered")" = "$(yq -o=json -I=0 "$db.deploy.placement" "$rendered")" ] \
  || bad "the exporter's placement differs from the database's; Prometheus would label it with another node"

u='.services."postgres-exporter-user"'
[ "$(q "$u.deploy.restart_policy.condition")" = "on-failure" ] \
  || bad "the one-shot's restart condition is not on-failure; it must run to completion once, and retry while the database is not up"
[ "$(q "$u.networks | join(\" \")")" = "$dbnets" ] \
  || bad "the one-shot is on '$(q "$u.networks | join(\" \")")'; holding the superuser password, it belongs on the database's overlay alone"
script="$(q "$u.command[0]")"
grep -F 'export PGPASSWORD="$$(cat /run/secrets/postgres_password)"' <<<"$script" >/dev/null \
  || bad "the one-shot does not read the superuser password from its mounted secret"
# The SQL, exactly: any edit to it is a privilege or logging decision, so it is a reviewed one.
# Logging off before the password is set; a role adopted only if this chart created it; its
# attributes reset to least privilege on every run; pg_monitor and nothing else.
want_sql="$(cat <<'EOF'
\set pw `printf '%s' "$$EXPORTER_PASSWORD"`
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
SET pg_stat_statements.track_utility = off;
SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'exporter') AS fresh
\gset
\if :fresh
CREATE ROLE :"exporter";
COMMENT ON ROLE :"exporter" IS 'swarmcli-charts postgres: metrics exporter role';
\endif
SELECT coalesce(shobj_description(oid, 'pg_authid'), '') = 'swarmcli-charts postgres: metrics exporter role' AS ours FROM pg_roles WHERE rolname = :'exporter'
\gset
\if :ours
ALTER ROLE :"exporter" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT CONNECTION LIMIT 3 PASSWORD :'pw';
GRANT pg_monitor TO :"exporter";
\else
DO $$$$BEGIN RAISE EXCEPTION 'refusing: role exporter exists but was not created by this chart, and its password would go to the exporter. Drop it or set another metrics.username.'; END$$$$;
\endif
EOF
)"
got_sql="$(sed -n "/^sql=\"\$\$(cat <<'SQL'\$/,/^SQL\$/p" <<<"$script" | sed '1d;$d')"
[ "$got_sql" = "$want_sql" ] \
  || bad "the one-shot's SQL changed; review it and update this check. Got:
$got_sql"
grep -F 'case "$$err" in *refusing:*) echo "postgres: $$err" >&2; exit 1 ;; esac' <<<"$script" >/dev/null \
  || bad "the one-shot retries a refused role for five minutes instead of stopping at once"
if grep -E -- '-v +pw=|PASSWORD +.\$\$' <<<"$script" >/dev/null; then
  bad "the exporter password is put on a command line or spliced into SQL"
fi
grep -E -- "-h tasks\.[A-Za-z0-9_.-]+_postgres -U \"postgres\" -d \"postgres\"" <<<"$script" >/dev/null \
  || bad "the one-shot does not log in as auth.username on tasks.<release>_postgres"
grep -F '*[[:space:]]*)' <<<"$script" >/dev/null \
  || bad "the one-shot does not refuse an exporter password with whitespace inside, which the exporter cannot log in with"
if grep -E '(^|[^$])\$[({A-Za-z_]' <<<"$script" >/dev/null; then
  bad "the one-shot has an unescaped \$: Docker would interpolate it at deploy time"
fi

# ── the refusals ─────────────────────────────────────────────────────────────────────────────
# Rendered from this fixture's chart with SWARMCLI, which test-charts.sh sets: each one must FAIL,
# with its own message.
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
refused() {
  local want="$1"; shift
  if "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" \
      -f "$chart/ci/metrics-values.yaml" "$@" >/dev/null 2>"$tmp/err"; then
    bad "rendered with $* — it must be refused"
  elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
    bad "$* failed, but not with \"$want\": $(cat "$tmp/err")"
  fi
}
refused 'metrics.network must differ from network.name' --set metrics.network=postgres-net
refused 'metrics.username must differ from auth.username' --set metrics.username=postgres
refused 'metrics.secretName must differ from auth.secretName' --set metrics.secretName=postgres_password
refused "at '/metrics/username': 'not' failed" --set metrics.username=pg_exporter
refused "at '/metrics/username'" --set metrics.username=Exporter

exit "$fail"
