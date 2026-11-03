#!/usr/bin/env bash
#
# Render-time assertions for the vaultwarden chart, run by scripts/test-charts.sh after a
# fixture renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Scoped to single sign-on and the CA bundle, which is what `docker compose config` cannot
# judge:
#   1. SSO_* appears only when sso.enabled (the sso fixtures), with every value in place;
#   2. the client secret reaches Vaultwarden only as SSO_CLIENT_SECRET_FILE, a path to a
#      mounted secret that is declared external — never as a plaintext SSO_CLIENT_SECRET;
#   3. sso.enabled without sso.authority or sso.clientId, or beside an
#      extraEnv.SSO_CLIENT_SECRET, is refused at render time, and an empty sso.scopes leaves
#      Vaultwarden's own default in charge;
#   4. caBundle mounts its external config only when enabled (the sso-ca fixture), and the
#      start command APPENDS it to the system bundle before Vaultwarden starts — never
#      substitutes it, which would drop every public CA.
set -euo pipefail

out="$1"
case="${2:-}"

fail=0
note() { echo "   FAIL: $1"; fail=1; }

# Hard failure, never a skip (a skipped check is indistinguishable from a passing one).
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -i mikefarah >/dev/null; then
  echo "   FAIL: mikefarah yq v4 is required by the vaultwarden render checks but was not found" >&2
  exit 1
fi

# No check below pipes into `grep -q`: under the `pipefail` above that makes a check
# that DID match report "no match". Match with `| grep … >/dev/null`; a here-string
# (`grep -q … <<<"$x"`) is fine — no pipe, no SIGPIPE. scripts/lint.sh has the why.

env_of() { yq -r ".services.vaultwarden.environment.\"$1\" // \"\"" "$out"; }
sso_keys="$(yq -r '.services.vaultwarden.environment // {} | keys | .[] | select(test("^SSO_"))' "$out")"
svc_secrets="$(yq -r '.services.vaultwarden.secrets // [] | .[]' "$out")"
secret=vaultwarden_sso_client_secret

# 2. In every render: the plaintext variable never exists.
[ "$(yq -r '.services.vaultwarden.environment | has("SSO_CLIENT_SECRET")' "$out")" = "false" ] \
  || note "SSO_CLIENT_SECRET is rendered — the client secret must only reach Vaultwarden as SSO_CLIENT_SECRET_FILE"

# 4. In every render: the CA bundle follows caBundle.enabled.
cmd="$(yq -r '.services.vaultwarden.command[0] // ""' "$out")"
bundle='cat /etc/ssl/certs/ca-certificates.crt /run/configs/vaultwarden-ca.pem > /tmp/ca-bundle.crt || exit 1; export SSL_CERT_FILE=/tmp/ca-bundle.crt; '
if [ "$case" = "sso-ca" ]; then
  if [ "$(yq -r '.services.vaultwarden.configs // [] | map(.source + " " + .target) | join(",")' "$out")" != "vaultwarden_ca_bundle /run/configs/vaultwarden-ca.pem" ]; then
    note "$case: vaultwarden_ca_bundle is not mounted (alone) at /run/configs/vaultwarden-ca.pem, where the start command reads it"
  fi
  [ "$(yq -r '.configs.vaultwarden_ca_bundle.external // false' "$out")" = "true" ] \
    || note "$case: vaultwarden_ca_bundle is not declared external (a chart never creates a config)"
  case "$cmd" in
    *"${bundle}exec /start.sh") ;;
    *) note "$case: the start command does not append the CA to the system bundle and point SSL_CERT_FILE at it right before exec: $cmd" ;;
  esac
else
  [ "$(yq -r '(.services.vaultwarden.configs // [] | length) + (.configs // {} | length)' "$out")" = "0" ] \
    || note "$case: a config is mounted or declared although caBundle.enabled is false"
  grep -F 'SSL_CERT_FILE' <<<"$cmd" >/dev/null && note "$case: SSL_CERT_FILE is set although caBundle.enabled is false"
fi

case "$case" in
  sso)    authority=http://vw-e2e-idp:8080/realms/e2e ;;
  sso-ca) authority=https://vw-e2e-idp-tls:8443/realms/e2e ;;
  *)
    # 1. SSO off: nothing of it renders.
    [ -z "$sso_keys" ] || note "$case: SSO variables rendered although sso.enabled is false: $(tr '\n' ' ' <<<"$sso_keys")"
    grep -Fx "$secret" <<<"$svc_secrets" >/dev/null && note "$case: mounts $secret although sso.enabled is false"
    exit "$fail"
    ;;
esac

# 1. SSO on: every value the fixture and the defaults set.
for kv in "SSO_ENABLED=true" \
          "SSO_AUTHORITY=$authority" \
          "SSO_CLIENT_ID=vaultwarden-e2e" \
          "SSO_CLIENT_SECRET_FILE=/run/secrets/$secret" \
          "SSO_ONLY=false" \
          "SSO_SIGNUPS_ALLOWED=true" \
          "SSO_SIGNUPS_MATCH_EMAIL=true" \
          "SSO_PKCE=true" \
          "SSO_SCOPES=email profile offline_access"; do
  got="$(env_of "${kv%%=*}")"
  [ "$got" = "${kv#*=}" ] || note "$case: ${kv%%=*} is '$got', expected '${kv#*=}'"
done

# 2. The file SSO_CLIENT_SECRET_FILE names is a secret the service mounts, declared external.
grep -Fx "$secret" <<<"$svc_secrets" >/dev/null || note "$case: $secret is not mounted, so SSO_CLIENT_SECRET_FILE names nothing"
[ "$(yq -r ".secrets.\"$secret\".external // false" "$out")" = "true" ] \
  || note "$case: $secret is not declared external (a chart never creates a secret)"

# 3. The refusals, and the empty-scopes default, rendered from this chart with the
#    renderer test-charts.sh exports — once, from the sso fixture.
[ "$case" = "sso" ] || exit "$fail"
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() { "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" -f "$chart/ci/sso-values.yaml" "$@"; }
refused() {
  local want="$1"; shift
  if render "$@" >/dev/null 2>"$tmp/err"; then
    note "sso: rendered with $* — it must be refused"
  elif ! grep -F "$want" "$tmp/err" >/dev/null; then
    note "sso: $* failed, but not with \"$want\": $(cat "$tmp/err")"
  fi
}
printf 'sso:\n  authority: ""\n' >"$tmp/no-authority.yaml"
refused "sso.authority is required when sso.enabled=true" -f "$tmp/no-authority.yaml"
printf 'sso:\n  clientId: ""\n' >"$tmp/no-client.yaml"
refused "sso.clientId is required when sso.enabled=true" -f "$tmp/no-client.yaml"
# Vaultwarden panics with both SSO_CLIENT_SECRET and its _FILE set; SSO configured wholly
# through extraEnv, with sso.enabled off, must keep rendering.
printf 'extraEnv:\n  SSO_CLIENT_SECRET: x\n' >"$tmp/plain.yaml"
refused "extraEnv.SSO_CLIENT_SECRET cannot be combined" -f "$tmp/plain.yaml"
printf 'sso:\n  enabled: false\nextraEnv:\n  SSO_ENABLED: "true"\n  SSO_CLIENT_SECRET: x\n' >"$tmp/plain-off.yaml"
render -f "$tmp/plain-off.yaml" >/dev/null 2>"$tmp/err" \
  || note "sso: extraEnv.SSO_CLIENT_SECRET was refused with sso.enabled off: $(cat "$tmp/err")"
printf 'sso:\n  scopes: ""\n' >"$tmp/no-scopes.yaml"
if render -f "$tmp/no-scopes.yaml" >"$tmp/no-scopes.out" 2>"$tmp/err"; then
  [ "$(yq -r '.services.vaultwarden.environment | has("SSO_SCOPES")' "$tmp/no-scopes.out")" = "false" ] \
    || note "sso: an empty sso.scopes still rendered SSO_SCOPES, overriding Vaultwarden's default"
else
  note "sso: an empty sso.scopes was refused: $(cat "$tmp/err")"
fi

exit "$fail"
