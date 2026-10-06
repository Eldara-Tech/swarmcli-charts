#!/usr/bin/env bash
#
# Render assertions for the mariadb chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# It guards the metrics opt-in, where every mistake still deploys and scrapes:
#
#   * The exporter carries exactly the two discovery labels. Once a service opts in,
#     every deploy label it carries is readable through Prometheus's targets API.
#   * The database itself never changes: not on the metrics overlay (that would put
#     its SQL port in front of everything that can reach Prometheus), not mounting the
#     exporter secret, and so never restarted by turning metrics on.
#   * Passwords come from the mounted secrets. A single `$` in a wrapper is
#     interpolated by Docker at deploy time, on the deploying machine.
#   * Nothing of it renders while metrics are off.
#
# No check pipes into `grep -q` (scripts/lint.sh enforces it): match with `grep … >/dev/null`
# or a here-string.
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

svcs="$(q '.services | keys | .[]' | sort | tr '\n' ' ')"
db_nets="$(q '.services.mariadb.networks[]' | tr '\n' ' ')"
db_labels="$(q '.services.mariadb.deploy.labels // [] | .[]')"

if grep -F 'prometheus.io/' <<<"$db_labels" >/dev/null; then
  bad "the mariadb service carries discovery labels; only the exporter may opt in"
fi
if grep -Fx monitoring <<<"$(q '.services.mariadb.networks[]')" >/dev/null; then
  bad "the mariadb service joined the metrics overlay: its SQL port would be reachable from it"
fi

if [ "$case" != "metrics" ]; then
  [ "$svcs" = "mariadb " ] || bad "case $case: services are '$svcs'; metrics must be opt-in"
  [ "$(q '.networks.monitoring')" = "null" ] || bad "case $case: the metrics overlay is declared although metrics are off"
  exit "$fail"
fi

# ── metrics ───────────────────────────────────────────────────────────────────────────
[ "$svcs" = "mariadb mariadb-exporter mariadb-exporter-user " ] \
  || bad "services are '$svcs', expected mariadb, mariadb-exporter and mariadb-exporter-user"

# The database renders exactly as without metrics.
[ "$db_nets" = "mariadb-net " ] || bad "the mariadb service's networks changed: '$db_nets'"
[ "$(q '.services.mariadb.secrets | join(",")')" = "mariadb_root_password,mariadb_password" ] \
  || bad "the mariadb service's secrets changed: $(q '.services.mariadb.secrets | join(",")')"
grep -Fx 'team=db' <<<"$db_labels" >/dev/null || bad "the fixture's labels no longer reach the mariadb service"

e='.services.mariadb-exporter'
cmd="$(q "$e.command[0]")"
[ "$(q "$e.entrypoint | join(\" \")")" = "/bin/sh -c" ] || bad "exporter: entrypoint is not [/bin/sh, -c]"
grep -F 'export MYSQLD_EXPORTER_PASSWORD="$$(cat /run/secrets/mariadb_exporter_password)";' <<<"$cmd" >/dev/null \
  || bad "exporter: the password is not read from the mounted secret"
grep -F 'exec /bin/mysqld_exporter' <<<"$cmd" >/dev/null || bad "exporter: does not exec mysqld_exporter"
grep -E -- '--mysqld\.address=tasks\.ci_mariadb:3306( |$)' <<<"$cmd" >/dev/null \
  || bad "exporter: does not scrape this release's database at tasks.ci_mariadb:3306"
grep -F -- '--mysqld.username=exporter' <<<"$cmd" >/dev/null || bad "exporter: does not log in as the exporter user"
[ "$(q "$e.environment")" = "null" ] || bad "exporter: has an environment block; a credential there lands in docker inspect"
[ "$(q "$e.deploy.labels | sort | join(\",\")")" = "prometheus.io/port=9104,prometheus.io/scrape=true" ] \
  || bad "exporter: deploy labels are '$(q "$e.deploy.labels | sort | join(\",\")")', expected exactly the two discovery labels"
[ "$(q "$e.networks | sort | join(\" \")")" = "mariadb-net monitoring" ] \
  || bad "exporter: networks are '$(q "$e.networks | join(\" \")")', expected the database's overlay and the metrics overlay"
[ "$(q "$e.ports")" = "null" ] || bad "exporter: publishes a port; /metrics has no authentication"
e_secrets="$(q "$e.secrets | join(\",\")")"
[ "$e_secrets" = "mariadb_exporter_password" ] || bad "exporter: mounts '$e_secrets', expected only its own secret"
[ "$(yq -o=json -I=0 "$e.deploy.placement" "$rendered")" = "$(yq -o=json -I=0 '.services.mariadb.deploy.placement' "$rendered")" ] \
  || bad "exporter: placement differs from the database's; it belongs on the database's node"

u='.services.mariadb-exporter-user'
ucmd="$(q "$u.command[0]")"
[ "$(q "$u.deploy.restart_policy.condition")" = "on-failure" ] \
  || bad "user one-shot: restart condition is not on-failure; it must run to completion once, and retry while the database is not writable yet"
[ "$(q "$u.networks | join(\" \")")" = "mariadb-net" ] \
  || bad "user one-shot: networks are '$(q "$u.networks | join(\" \")")'; it holds the root password and stays off the metrics overlay"
grep -F 'mariadb -h tasks.ci_mariadb -uroot' <<<"$ucmd" >/dev/null || bad "user one-shot: does not reach this release's database"
grep -F 'export MYSQL_PWD="$$(cat /run/secrets/mariadb_root_password)"' <<<"$ucmd" >/dev/null \
  || bad "user one-shot: the root password is not read from the mounted secret"
grep -F "GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO" <<<"$ucmd" >/dev/null \
  || bad "user one-shot: the grant changed; anything wider reads data, anything narrower fails a default collector"
grep -F "user=\"'exporter'@'%'\"" <<<"$ucmd" >/dev/null || bad "user one-shot: does not create the exporter user"

# A single-$ expansion in either script would be resolved by Docker at deploy time.
for s in "$cmd" "$ucmd"; do
  if grep -E '(^|[^$])\$[({A-Za-z@'"'"']' <<<"$s" >/dev/null; then
    bad "an unescaped \$ in a wrapper ($(grep -oE '(^|[^$])\$[({A-Za-z@'"'"'][^ ]{0,20}' <<<"$s" | sed -n 1p)): Docker would interpolate it at deploy time"
  fi
done

[ "$(q '.secrets.mariadb_exporter_password.external')" = "true" ] || bad "the exporter secret is not declared external"
[ "$(q '.networks.monitoring.external')" = "true" ] || bad "the metrics overlay is not declared external"

exit "$fail"
