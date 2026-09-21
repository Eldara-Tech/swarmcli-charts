#!/usr/bin/env bash
#
# Optional e2e smoke check for the mongodb chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case name
# Exit 0 = healthy, non-zero = failure.
#
# It dials MongoDB the way an application does: from a throwaway client container on the release's
# overlay, by the stack-qualified service name, with the dummy passwords ci/e2e-setup.sh put in the
# secrets. Convergence alone proves little here — mongod listens happily with no users, the wrong
# users, or auth off — so every credential path the chart sets up is exercised from outside.
#
# PREREQUISITES (scripts/e2e-test.sh sets these up via ci/e2e-setup.sh):
#   docker node update --label-add mongodb-data=true <node>
#   printf 'test-root\n' | docker secret create mongodb_root_password -   (+ mongodb_password,
#   mongodb_keyfile)
set -euo pipefail

release="$1"
case="$3"
svc="${release}_mongodb"

cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${svc}" | sed -n 1p)"
[ -n "$cid" ] || { echo "  ${svc} container not found"; exit 1; }
fail() { echo "  ${svc}: $*"; exit 1; }

# The client uses the task's own image (already pulled) and joins the overlay the task joined:
# mongodb-net when external, <release>_mongodb-net when chart-managed. ingress, which a published
# port adds, is not attachable.
image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$cid")"
net="$(grep -vx ingress <<<"$nets" | sed -n 1p || true)"
[ -n "$net" ] || fail "no overlay attached (networks: $nets)"

# mongosh from the client container. $1 = connection string, $2 = script. A replica-set fixture
# connects WITH replicaSet discovery, so the driver re-dials the member address the server
# advertises — which is what proves that address resolves for clients, not just for the server.
params=""
[ "$case" = "replica-set" ] && params="?replicaSet=rs0"
client() {
  docker run --rm --network "$net" -e HOME=/tmp --entrypoint mongosh "$image" \
    --quiet --norc "mongodb://$1@${svc}:27017/$2${params}" --eval "$3"
}

# Auth is enforced: the entrypoint adds --auth only while the root credentials are set.
out="$(docker run --rm --network "$net" -e HOME=/tmp --entrypoint mongosh "$image" --quiet --norc \
  "mongodb://${svc}:27017/app${params}" \
  --eval 'try { db.e2e_anon.insertOne({ v: 1 }); print("WROTE") } catch (e) { print(e.codeName) }')"
[ "$out" = "Unauthorized" ] || fail "an anonymous write was not refused (got: $out)"

# Root authenticates with the secret's value, minus the trailing newline.
out="$(client root:test-root admin 'print(db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUserRoles.map(r => r.role + "@" + r.db).join())')"
[ "$out" = "root@admin" ] || fail "root did not authenticate as root@admin (got: $out)"

if [ "$case" = "no-appuser" ]; then
  if out="$(client app:test-app app 'print("AUTHENTICATED")' 2>&1)"; then
    fail "app user exists although auth.appUser.enabled is false ($out)"
  fi
else
  # readWrite on its own database, and nothing on any other.
  out="$(client app:test-app app '
    db.e2e_smoke.replaceOne({ _id: 1 }, { v: "ok" }, { upsert: true });
    let other;
    try { db.getSiblingDB("e2e_other").t.insertOne({ v: 1 }); other = "WROTE" } catch (e) { other = e.codeName }
    print(db.e2e_smoke.findOne({ _id: 1 }).v, other)')"
  [ "$out" = "ok Unauthorized" ] || fail "app user round-trip/least-privilege check failed (got: $out)"
fi

if [ "$case" = "replica-set" ]; then
  # A multi-document transaction is refused by a standalone, so committing one proves the replica
  # set is real; hello() shows the member address clients were handed.
  out="$(client app:test-app app '
    const s = db.getMongo().startSession();
    s.withTransaction(() => { s.getDatabase("app").e2e_tx.insertOne({ v: 1 }) });
    s.endSession();
    const h = db.hello();
    print(h.setName, h.hosts.join(), h.isWritablePrimary)')"
  [ "$out" = "rs0 ${svc}:27017 true" ] || fail "replica set check failed (got: $out)"
fi

# Mounts. /data/configdb must carry the chart's tmpfs lid, never a volume: the image declares
# VOLUME there, and without the lid Swarm attaches a stray anonymous volume per task. /data/db is
# asserted on TYPE and NAME, not presence — the image's VOLUME /data/db gives even the ephemeral
# fixture an anonymous volume there.
mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.Type}} {{.Name}}{{.Source}}{{"\n"}}{{end}}' "$cid")"
if grep '^/data/configdb volume ' <<<"$mounts" >/dev/null; then
  fail "a volume is mounted at /data/configdb instead of the tmpfs lid:
$mounts"
fi
data="$(awk '$1 == "/data/db" { print $2 ":" $3 }' <<<"$mounts")"

if [ "$case" = "ephemeral" ]; then
  case "$data" in
    *mongodb-data*) fail "ephemeral fixture mounted a persistent data volume ($data)" ;;
  esac
  echo "  ${svc}: auth + root + app user round-trip OK (ephemeral)"
  exit 0
fi

case "$data" in
  bind:/opt/mongodb-data|volume:*mongodb-data*) ;;
  *) fail "expected a named or bind data mount at /data/db, got '$data'" ;;
esac
echo "  ${svc}: auth + root + app user + persistent data mount OK${params:+ + replica set}"
