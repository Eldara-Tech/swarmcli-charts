#!/usr/bin/env bash
#
# e2e setup for the vaultwarden chart. scripts/e2e-test.sh runs this BEFORE `swarmcli
# charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates:
#   * the five dummy secrets (created for EVERY fixture — a fixture that does not
#     reference one leaves it inert, and unconditional creation keeps this simple);
#   * the persistence node label the data pin needs;
#   * traefik-public (autoCreate:false in requirements.yaml — the operator/traefik
#     chart owns it; here we stand in for them);
#   * for the postgres/mysql fixtures, the DB overlay plus a throwaway backend named
#     to match that fixture's database.*.host, with the vaultwarden schema + user
#     bootstrapped from the image's own env, waited on until it accepts connections;
#   * for the sso fixture, a stub OpenID provider, waited on until it serves discovery;
#   * for the sso-ca fixture, the same stub over https with a certificate from a throwaway
#     private CA, and that CA as the vaultwarden_ca_bundle Swarm config.
# ci/e2e-teardown.sh removes everything created here (leaving shared overlays).
#
# INVARIANT: the backend's app-user password must equal the vaultwarden_*_password
# secret's content ($DBPW), and its schema/user must equal database.<type>.name /
# .username (vaultwarden) — otherwise the app cannot authenticate and never converges.
# This hook owns both sides, so it sets one $DBPW and uses it for both.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"
DBPW='test'

# --- dummy secrets ---------------------------------------------------------------
for s in vaultwarden_postgres_password vaultwarden_mysql_password vaultwarden_smtp_password; do
  docker secret inspect "$s" >/dev/null 2>&1 \
    || printf '%s' "$DBPW" | docker secret create "$s" - >/dev/null
done
# The admin token is an Argon2id PHC string, which is what the README tells operators to
# use — and the interesting case: it contains five `$`, so it also proves a credential full
# of shell metacharacters survives the secret -> `$$(cat …)` export path unmangled. Single
# quotes so this shell does not expand it. Must match ci/e2e-check.sh.
ADMIN_PHC='$argon2id$v=19$m=65540,t=3,p=4$MmeKRnGK5RW5mJS7h3TOv90eOu7wJ3Ry6xGRW0ycHco$kSJqYRV3Fu2AjjM/dvbFyoIUt74BsAoWXqYIVXaQ+/8'
docker secret inspect vaultwarden_admin_token >/dev/null 2>&1 \
  || printf '%s' "$ADMIN_PHC" | docker secret create vaultwarden_admin_token - >/dev/null
# Distinctive rather than "test": ci/e2e-check.sh asserts these bytes are absent from docker
# inspect, and a value that also occurs in a hostname or an env var would match itself.
docker secret inspect vaultwarden_sso_client_secret >/dev/null 2>&1 \
  || printf '%s' 'sw4rm-vw-sso-e2e-secret' | docker secret create vaultwarden_sso_client_secret - >/dev/null

# --- persistence pin -------------------------------------------------------------
# Label this (single-node) swarm's node so the persistence.nodeLabel constraint
# schedules. Harmless for the ephemeral/edge fixtures (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add vaultwarden-data=true "$node" >/dev/null

# Shared ingress overlay the traefik/none/edge exposure modes attach to.
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# --- bind-mount fixture only: pre-create the host dir (path matches
# ci/bind-mount-values.yaml). Done from a throwaway root container so it works whether
# or not the runner has sudo (dockerd always runs as root), the same way the postgres
# chart's hook provisions its own bind dir. Best-effort. --------------------------
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /srv/vaultwarden:/data alpine \
    sh -c 'chmod 0777 /data' >/dev/null 2>&1 || true
fi

# --- external-database fixtures: overlay + a co-located backend --------------------
# Named vw-* rather than postgres/mariadb so this never collides with the keycloak or
# superset hooks, which stand up services under those plain names.
if [ "$case" = "postgres" ] || [ "$case" = "mysql" ]; then
  if [ "$case" = "postgres" ]; then
    dbnet=postgres-net
    db_name=vw-postgres
  else
    dbnet=mariadb-net
    db_name=vw-mariadb
  fi
  docker network create --driver overlay --attachable "$dbnet" >/dev/null 2>&1 || true

  docker service rm "$db_name" >/dev/null 2>&1 || true
  if [ "$case" = "postgres" ]; then
    docker service create --name "$db_name" --network "$dbnet" \
      --env POSTGRES_DB=vaultwarden \
      --env POSTGRES_USER=vaultwarden \
      --env POSTGRES_PASSWORD="$DBPW" \
      postgres:18 >/dev/null
    # pg_isready against 127.0.0.1 (TCP), not the unix socket: during first init the
    # entrypoint runs a temporary server that listens on the socket ONLY, so a socket
    # probe would report ready while initdb is still running.
    db_probe() { docker exec "$1" pg_isready -h 127.0.0.1 -U vaultwarden -d vaultwarden >/dev/null 2>&1; }
  else
    docker service create --name "$db_name" --network "$dbnet" \
      --env MARIADB_ROOT_PASSWORD="$DBPW" \
      --env MARIADB_DATABASE=vaultwarden \
      --env MARIADB_USER=vaultwarden \
      --env MARIADB_PASSWORD="$DBPW" \
      mariadb:11.8 >/dev/null
    # The image's healthcheck.sh --connect uses its own localhost socket — no creds needed.
    db_probe() { docker exec "$1" healthcheck.sh --connect >/dev/null 2>&1; }
  fi

  # Wait for the task to run (image pull), then until it actually accepts connections,
  # so Vaultwarden does not race the DB during its own boot/migration.
  for _ in $(seq 1 40); do
    state="$(docker service ps "$db_name" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done
  for _ in $(seq 1 40); do
    cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${db_name}" | sed -n 1p)"
    if [ -n "$cid" ] && db_probe "$cid"; then
      break
    fi
    sleep 3
  done
fi

# --- sso fixture only: a stub OpenID provider on traefik-public, the overlay the default
# traefik exposure joins. busybox httpd serves a discovery document and an empty key set,
# which discovery fetches and needs as a 200 JSON answer. Nobody logs in, so the token and
# userinfo endpoints never have to answer — but Vaultwarden refuses a discovery document
# that does not NAME them (sso_client.rs), so both are listed. Its issuer must equal
# ci/sso-values.yaml's sso.authority byte for byte. The two content types are what discovery checks for. ----
if [ "$case" = "sso" ]; then
  iss=http://vw-e2e-idp:8080/realms/e2e
  discovery="{\"issuer\":\"$iss\",\"authorization_endpoint\":\"$iss/protocol/openid-connect/auth\",\"token_endpoint\":\"$iss/protocol/openid-connect/token\",\"userinfo_endpoint\":\"$iss/protocol/openid-connect/userinfo\",\"jwks_uri\":\"$iss/protocol/openid-connect/certs.json\",\"response_types_supported\":[\"code\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"RS256\"]}"
  docker service rm vw-e2e-idp >/dev/null 2>&1 || true
  docker service create --detach --name vw-e2e-idp --network traefik-public --env DISCOVERY="$discovery" \
    busybox:1.37 sh -c 'd=/www/realms/e2e && mkdir -p "$d/.well-known" "$d/protocol/openid-connect" &&
      printf "%s" "$DISCOVERY" > "$d/.well-known/openid-configuration" &&
      printf "{\"keys\":[]}" > "$d/protocol/openid-connect/certs.json" &&
      printf ".well-known/openid-configuration:application/json\n.json:application/json\n" > /etc/httpd.conf &&
      exec httpd -f -v -p 8080 -h /www -c /etc/httpd.conf' >/dev/null
  got=""
  for _ in $(seq 1 40); do
    got="$(docker run --rm --network traefik-public curlimages/curl:latest -s -o /dev/null -w '%{http_code} %{content_type}' \
      --max-time 5 "$iss/.well-known/openid-configuration" 2>/dev/null || true)"
    [ "$got" = "200 application/json" ] && break
    sleep 3
  done
  [ "$got" = "200 application/json" ] || { echo "  FAIL: the stub OpenID provider never served its discovery document (last: '$got')"; exit 1; }
fi

# --- sso-ca fixture only: the same stub, served over https by nginx with a certificate from
# a private CA generated here, which reaches Vaultwarden as the vaultwarden_ca_bundle config —
# so discovery, and with it the login redirect, works only if Vaultwarden trusts that CA. The
# config is recreated every run: it is immutable, and one left over from an earlier run would
# name a CA the new certificate does not come from. Host openssl, as charts/harbor's hook
# uses, in forms OpenSSL 3 and LibreSSL (macOS) both accept; the PEMs travel base64-encoded
# in the stub's environment because a value spanning lines is awkward to pass. --------------
if [ "$case" = "sso-ca" ]; then
  iss=https://vw-e2e-idp-tls:8443/realms/e2e
  discovery="{\"issuer\":\"$iss\",\"authorization_endpoint\":\"$iss/protocol/openid-connect/auth\",\"token_endpoint\":\"$iss/protocol/openid-connect/token\",\"userinfo_endpoint\":\"$iss/protocol/openid-connect/userinfo\",\"jwks_uri\":\"$iss/protocol/openid-connect/certs.json\",\"response_types_supported\":[\"code\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"RS256\"]}"
  tls="$(mktemp -d)"
  trap 'rm -rf "$tls"' EXIT
  printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=vaultwarden e2e CA\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' >"$tls/ca.cnf"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:vw-e2e-idp-tls\n' >"$tls/idp.ext"
  openssl req -x509 -config "$tls/ca.cnf" -newkey rsa:2048 -nodes -sha256 -days 2 \
    -keyout "$tls/ca.key" -out "$tls/ca.pem" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -sha256 -subj /CN=vw-e2e-idp-tls \
    -keyout "$tls/idp.key" -out "$tls/idp.csr" 2>/dev/null
  openssl x509 -req -sha256 -days 2 -in "$tls/idp.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" \
    -CAcreateserial -extfile "$tls/idp.ext" -out "$tls/idp.pem" 2>/dev/null
  openssl verify -CAfile "$tls/ca.pem" "$tls/idp.pem" >/dev/null \
    || { echo "  FAIL: the stub's certificate does not verify against the CA generated for it"; exit 1; }
  docker config rm vaultwarden_ca_bundle >/dev/null 2>&1 || true
  docker config create vaultwarden_ca_bundle "$tls/ca.pem" >/dev/null
  docker service rm vw-e2e-idp-tls >/dev/null 2>&1 || true
  docker service create --detach --name vw-e2e-idp-tls --network traefik-public --env DISCOVERY="$discovery" \
    --env CERT_B64="$(base64 <"$tls/idp.pem" | tr -d '\n')" --env KEY_B64="$(base64 <"$tls/idp.key" | tr -d '\n')" \
    nginx:alpine sh -c 'd=/www/realms/e2e && mkdir -p "$d/.well-known" "$d/protocol/openid-connect" &&
      printf "%s" "$DISCOVERY" > "$d/.well-known/openid-configuration" &&
      printf "{\"keys\":[]}" > "$d/protocol/openid-connect/certs.json" &&
      printf "%s" "$CERT_B64" | base64 -d > /etc/nginx/idp.pem && printf "%s" "$KEY_B64" | base64 -d > /etc/nginx/idp.key &&
      printf "events {}\nhttp { server { listen 8443 ssl; ssl_certificate /etc/nginx/idp.pem; ssl_certificate_key /etc/nginx/idp.key; root /www; default_type application/json; } }\n" > /etc/nginx/nginx.conf &&
      exec nginx -g "daemon off;"' >/dev/null
  # -k: this only waits for it to serve. Whether the CA is trusted is Vaultwarden's to prove.
  got=""
  for _ in $(seq 1 40); do
    got="$(docker run --rm --network traefik-public curlimages/curl:latest -sk -o /dev/null -w '%{http_code} %{content_type}' \
      --max-time 5 "$iss/.well-known/openid-configuration" 2>/dev/null || true)"
    [ "$got" = "200 application/json" ] && break
    sleep 3
  done
  [ "$got" = "200 application/json" ] || { echo "  FAIL: the https stub OpenID provider never served its discovery document (last: '$got')"; exit 1; }
fi

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public,
# so ci/e2e-check.sh can prove a request routes THROUGH it (shared helper). -----------
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
