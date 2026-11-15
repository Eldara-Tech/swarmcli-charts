#!/usr/bin/env bash
#
# e2e setup for the elasticsearch chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but never creates:
#   * the operator secrets: the elastic and kibana_system passwords, the Kibana encryption key and
#     a TLS CA + node certificate (generated here with openssl, into $E2E_ES_TLS_DIR so
#     ci/e2e-check.sh can verify the chain with the same CA);
#   * every node label a fixture pins to — elasticsearch-data-1..3 on the one CI node, so the
#     pinned cluster shape, the one operators run, schedules there;
#   * the traefik-public overlay (autoCreate:false), and for `edge` the traefik chart itself;
#   * for bind-mount, the host data dir, empty and owned by the image's uid 1000 / gid 0;
#   * vm.max_map_count >= 262144, which a cluster refuses to start without.
# ci/e2e-teardown.sh removes everything created here.
#
# The passwords end in a newline ON PURPOSE (`echo pw | docker secret create` is how many
# operators create secrets), and the kibana_system one carries a double quote and a backslash, the
# two characters a hand-built JSON body gets wrong. ci/e2e-check.sh authenticates with the bare
# values, so a lost strip or a broken body fails there.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"
tls_dir="${E2E_ES_TLS_DIR:-${TMPDIR:-/tmp}/e2e-elasticsearch-tls}"

secret() {
  docker secret inspect "$1" >/dev/null 2>&1 || printf '%s\n' "$2" | docker secret create "$1" - >/dev/null
}
secret elasticsearch_elastic_password 'e2e-elastic-pw'
secret kibana_system_password 'e2e-"kibana"\pw'
secret kibana_encryption_key 'e2e0123456789abcdef0123456789abcdef0123456789'

# One CA and one certificate for every node. Its only SAN is the chart's shared client alias:
# ci/e2e-check.sh dials that name (curl --connect-to) so it can verify the chain AND the name
# without the certificate listing each release-scoped service name.
mkdir -p "$tls_dir"
if [ ! -s "$tls_dir/node.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj /CN=e2e-elasticsearch-ca \
    -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj /CN=elasticsearch \
    -keyout "$tls_dir/node.key" -out "$tls_dir/node.csr" 2>/dev/null
  printf 'subjectAltName=DNS:elasticsearch,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n' \
    >"$tls_dir/ext.cnf"
  openssl x509 -req -in "$tls_dir/node.csr" -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" \
    -CAcreateserial -days 7 -extfile "$tls_dir/ext.cnf" -out "$tls_dir/node.crt" 2>/dev/null
fi
for f in ca:ca.crt cert:node.crt key:node.key; do
  name="elasticsearch_tls_${f%%:*}"
  docker secret inspect "$name" >/dev/null 2>&1 || docker secret create "$name" "$tls_dir/${f#*:}" >/dev/null
done

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update \
  --label-add elasticsearch-data-1=true --label-add elasticsearch-data-2=true \
  --label-add elasticsearch-data-3=true "$node" >/dev/null

# Kibana's default traefik mode and `none` validate this overlay but never create it.
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# Through a throwaway privileged container, so it works whether or not the runner has sudo.
if [ "$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)" -lt 262144 ]; then
  docker run --rm --privileged alpine sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
fi
if [ "$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)" -lt 262144 ]; then
  echo "   vm.max_map_count is $(cat /proc/sys/vm/max_map_count) and could not be raised to 262144" >&2
  exit 1
fi

if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt:/opt alpine sh -c \
    'rm -rf /opt/elasticsearch-data-1 && mkdir -p /opt/elasticsearch-data-1 && chown 1000:0 /opt/elasticsearch-data-1' >/dev/null
fi

if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
