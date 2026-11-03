#!/usr/bin/env bash
#
# Optional e2e smoke check for the vaultwarden chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# It probes the running server rather than assuming an exposure mode: it locates the task
# container for service "<release>_vaultwarden" (a local e2e swarm is single-node) and runs
# the image's own /healthcheck.sh inside it, which curls /alive on ROCKET_PORT. Then, for
# the fixtures that assemble something at runtime, it asserts what actually reached PID 1.
#
# Reading /proc/1/environ is the point of the secret/database assertions, not an
# implementation detail: the chart exports DATABASE_URL/ADMIN_TOKEN/SMTP_PASSWORD from an
# `sh -c` wrapper that reads /run/secrets/* with a compose-escaped `$$(cat …)`. If that
# escape is ever eaten, the shell expands `$$` to its own pid and the app silently runs
# holding the literal value "1(cat /run/secrets/…)". `docker exec` gets the image+service
# environment, NOT the wrapper's exports, so PID 1's environ is the only place the real
# value is visible.
set -euo pipefail

release="$1"
case="${3:-}"
# Both must match ci/e2e-setup.sh. The admin token is an Argon2id PHC string on purpose:
# its five `$` are what turn "the wrapper exported something" into "the wrapper exported
# the credential byte-for-byte". Single-quoted so this shell does not expand it.
DBPW='test'
ADMIN_PHC='$argon2id$v=19$m=65540,t=3,p=4$MmeKRnGK5RW5mJS7h3TOv90eOu7wJ3Ry6xGRW0ycHco$kSJqYRV3Fu2AjjM/dvbFyoIUt74BsAoWXqYIVXaQ+/8'

vw_cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_vaultwarden" | sed -n 1p; }

# PID 1's environment, one NUL-separated entry per line.
pid1_env() { docker exec "$1" sh -c "tr '\\0' '\\n' < /proc/1/environ" 2>/dev/null; }

# Assert PID 1 carries exactly this VAR=value. Never echoes the value (dummy here, but the
# same check on a real deployment would leak a credential into the log).
assert_env() { # $1 cid  $2 VAR=value  $3 human description
  if pid1_env "$1" | grep -xF "$2" >/dev/null; then
    echo "  ${3}: exported to PID 1 as expected"
    return 0
  fi
  echo "  FAIL: ${3} is not what the chart's export wrapper should have produced"
  echo "        (present vars: $(pid1_env "$1" | cut -d= -f1 | sort | tr '\n' ' '))"
  return 1
}

# Wait for the app to actually serve. Task "Running" != serving, and an unhealthy task may
# be replaced under us, so re-resolve the container each attempt. Retry for up to ~2.5 min.
ok=0
for _ in $(seq 1 30); do
  cid="$(vw_cid)"
  if [ -n "$cid" ] && docker exec "$cid" /healthcheck.sh >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "  FAIL: ${release}_vaultwarden never became healthy (/healthcheck.sh)"
  docker service ps "${release}_vaultwarden" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
cid="$(vw_cid)"
echo "  ${release}_vaultwarden: serving (/healthcheck.sh OK)"

# --- external-database fixtures: the app converged, so it connected — assert it connected
# to the CONFIGURED backend via a well-formed URL, not to the SQLite fallback. ----------
if [ "$case" = "postgres" ]; then
  assert_env "$cid" \
    "DATABASE_URL=postgresql://vaultwarden:${DBPW}@vw-postgres:5432/vaultwarden?sslmode=disable" \
    "DATABASE_URL (postgres)" || exit 1
fi
if [ "$case" = "mysql" ]; then
  assert_env "$cid" \
    "DATABASE_URL=mysql://vaultwarden:${DBPW}@vw-mariadb:3306/vaultwarden" \
    "DATABASE_URL (mysql)" || exit 1
fi

# --- secrets fixture: both secret-backed exports carry their secret's real content. -----
if [ "$case" = "secrets" ]; then
  assert_env "$cid" "ADMIN_TOKEN=${ADMIN_PHC}" "ADMIN_TOKEN (Argon2id PHC)" || exit 1
  assert_env "$cid" "SMTP_PASSWORD=${DBPW}"    "SMTP_PASSWORD"               || exit 1
fi

# --- bind-mount fixture: confirm /data is a mount (persistence actually took effect),
# not the container's ephemeral layer. -------------------------------------------------
if [ "$case" = "bind-mount" ]; then
  if docker exec "$cid" sh -c 'grep -q " /data " /proc/mounts'; then
    echo "  bind-mount: /data is persisted (mounted)"
  else
    echo "  FAIL: /data is not mounted — persistence did not take effect"
    exit 1
  fi
fi

# --- sso fixture: Vaultwarden discovers the provider at the first authorize request, so
# convergence proves only that the settings parsed and the secret file was readable (it
# refuses to start otherwise). Make that request — as the web vault would — and assert it
# is sent on to the stub's authorization endpoint for the chart's client, with the callback
# derived from DOMAIN and the configured scopes. Then prove the secret reached Vaultwarden
# only as a file. sso-ca runs the same checks against the https stub, whose certificate
# comes from a private CA: there the redirect also proves Vaultwarden trusts caBundle. ------
if [ "$case" = "sso" ] || [ "$case" = "sso-ca" ]; then
  idp_auth='http://vw-e2e-idp:8080/realms/e2e/protocol/openid-connect/auth?'
  [ "$case" = "sso-ca" ] && idp_auth='https://vw-e2e-idp-tls:8443/realms/e2e/protocol/openid-connect/auth?'
  cb='redirect_uri=https%3A%2F%2Fvaultwarden-sso.e2e.test%2Fidentity%2Fconnect%2Foidc-signin'
  q='client_id=web&redirect_uri=https%3A%2F%2Fvaultwarden-sso.e2e.test%2Fsso-connector.html&state=e2e-state'
  q="${q}&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
  got="$(docker exec "$cid" curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
    "http://127.0.0.1:80/identity/connect/authorize?${q}" 2>/dev/null || true)"
  code="${got%% *}"
  loc="${got#* }"
  case "$code" in
    3??) ;;
    *) echo "  FAIL: /identity/connect/authorize answered '$code', not a redirect — was the stub provider discovered? (docker service logs ${release}_vaultwarden)"; exit 1 ;;
  esac
  case "$loc" in
    "$idp_auth"*) ;;
    *) echo "  FAIL: the login redirected to '${loc:-<nothing>}', not to the stub's authorization endpoint"; exit 1 ;;
  esac
  for want in 'client_id=vaultwarden-e2e' "$cb" 'scope=[^&]*offline_access' 'code_challenge_method=S256'; do
    if ! grep -E "[?&]${want}(&|\$)" <<<"$loc" >/dev/null; then
      echo "  FAIL: the authorization request lacks ${want}: $loc"
      exit 1
    fi
  done
  echo "  sso: the login redirects to the stub with client_id vaultwarden-e2e, the oidc-signin callback on DOMAIN and the configured scopes"

  # /identity/connect/authorize answers whether or not SSO is on; prevalidate, which the
  # web vault calls first, hands out a token only when it is.
  pre="$(docker exec "$cid" curl -s --max-time 10 http://127.0.0.1:80/identity/sso/prevalidate 2>/dev/null || true)"
  if ! grep -F '"token":' <<<"$pre" >/dev/null; then
    echo "  FAIL: /identity/sso/prevalidate handed out no token, so SSO is not enabled in the running config: ${pre:-<empty>}"
    exit 1
  fi
  echo "  sso: enabled in the running config (/identity/sso/prevalidate hands out a token)"

  if ! pid1_env "$cid" | grep -xF "SSO_CLIENT_SECRET_FILE=/run/secrets/vaultwarden_sso_client_secret" >/dev/null; then
    echo "  FAIL: PID 1 does not carry SSO_CLIENT_SECRET_FILE=/run/secrets/vaultwarden_sso_client_secret"
    exit 1
  fi
  if pid1_env "$cid" | grep -E '^SSO_CLIENT_SECRET=' >/dev/null; then
    echo "  FAIL: SSO_CLIENT_SECRET is in PID 1's environment — the secret must only be read from its file"
    exit 1
  fi
  # Compared against the secret the task mounts, not a known value: setup keeps a secret left
  # over from an earlier run, which would make a check against the default pass vacuously.
  sso_secret="$(docker exec "$cid" cat /run/secrets/vaultwarden_sso_client_secret 2>/dev/null || true)"
  if [ -z "$sso_secret" ]; then
    echo "  FAIL: the task mounts no (or an empty) /run/secrets/vaultwarden_sso_client_secret"
    exit 1
  fi
  if { docker service inspect "${release}_vaultwarden"; docker inspect "$cid"; } | grep -F -- "$sso_secret" >/dev/null; then
    echo "  FAIL: the SSO client secret is visible in docker inspect"
    exit 1
  fi
  echo "  sso: the client secret is mounted, read through SSO_CLIENT_SECRET_FILE, and absent from docker inspect"
fi

# --- sso-ca fixture: discovery over https already proved the private CA is trusted (the
# redirect above). What it cannot show is that the public CAs still are — the push relay,
# HIBP, icons and a public SMTP relay depend on them — so count: the bundle PID 1 was handed
# must be the image's whole system bundle plus the mounted CA. -----------------------------
if [ "$case" = "sso-ca" ]; then
  if ! pid1_env "$cid" | grep -xF "SSL_CERT_FILE=/tmp/ca-bundle.crt" >/dev/null; then
    echo "  FAIL: PID 1 does not carry SSL_CERT_FILE=/tmp/ca-bundle.crt"
    exit 1
  fi
  # grep -c prints 0 itself on no match; empty means the file could not be read at all.
  certs() { local n; n="$(docker exec "$cid" grep -c 'BEGIN CERTIFICATE' "$1" 2>/dev/null || true)"; echo "${n:-0}"; }
  sys="$(certs /etc/ssl/certs/ca-certificates.crt)"
  ca="$(certs /run/configs/vaultwarden-ca.pem)"
  all="$(certs /tmp/ca-bundle.crt)"
  if [ "$ca" -lt 1 ] || [ "$sys" -lt 1 ] || [ "$all" -ne $((sys + ca)) ]; then
    echo "  FAIL: /tmp/ca-bundle.crt holds $all certificates, expected the system bundle's $sys plus the mounted CA's $ca"
    exit 1
  fi
  echo "  sso-ca: the private CA is trusted (discovery over https worked) and the bundle keeps all $sys public CAs beside it"
fi

# --- edge fixture: prove a request routes THROUGH the stood-up traefik edge. The probe
# above proved the app serves; now assert it is reachable via the edge with a matching
# Host header, and that an unknown host 404s. ------------------------------------------
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed vaultwarden.e2e.test /alive 200 || exit 1
  edge_assert_unrouted no-such-host.invalid || exit 1
fi

exit 0
