#!/usr/bin/env bash
#
# e2e setup for the mariadb chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the two
# operator-supplied secrets and the persistence node-label pin. For the bind-mount
# fixture it also pre-creates the host data dir owned by the container's mysql uid (999).
# The shared mariadb-net overlay is autoCreate:true, so swarmcli creates it at install —
# not this hook. ci/e2e-teardown.sh removes everything created here. (See
# charts/redis/ci/e2e-setup.sh for the shared shape.)
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"

docker secret inspect mariadb_root_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_root_password - >/dev/null
docker secret inspect mariadb_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_password - >/dev/null

# Pin: label this (single-node) swarm's node so node.labels.mariadb-data == true schedules.
# Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add mariadb-data=true "$node" >/dev/null

# bind-mount fixture only (ci/bind-mount-values.yaml mounts /opt/mariadb-data at
# /var/lib/mysql). Two host-path facts bite here, both absent for a named volume:
#   * it must be writable by the mysql user (uid 999) the server runs as — mariadb:11.8
#     does not chown a bind-mounted datadir the way a fresh named volume inherits the
#     image's mysql ownership; and
#   * `uninstall --purge-volumes` does NOT remove a host path, so on a reused CI runner a
#     stale datadir from a prior run makes the entrypoint SKIP first-time init — which is
#     what sets up the healthcheck's local credentials, so the healthcheck then fails
#     "Access denied for root" and the task crash-loops.
# Provision via a throwaway root container (dockerd always runs as root, so this works
# whether or not the runner has sudo): empty the dir for a clean first-init, then chown it
# to the mysql uid/gid (999) so it matches exactly what a fresh named volume gives mariadb
# (pre-populated mysql-owned). The echo confirms the resulting owner/mode in the CI log.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/mariadb-data:/data alpine sh -c '
    rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null
    chown 999:999 /data && chmod 0755 /data
    echo "   [e2e-setup] /opt/mariadb-data -> $(stat -c "%u:%g %a" /data)"' || true
fi
