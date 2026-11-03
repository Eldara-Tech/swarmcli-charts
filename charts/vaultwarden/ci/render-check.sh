#!/usr/bin/env bash
#
# Render-time assertions for the vaultwarden chart, run by scripts/test-charts.sh after a
# fixture renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Scoped to single sign-on, which is what `docker compose config` cannot judge:
#   1. SSO_* appears only when sso.enabled (the `sso` fixture), with every value in place;
#   2. the client secret reaches Vaultwarden only as SSO_CLIENT_SECRET_FILE, a path to a
#      mounted secret that is declared external — never as a plaintext SSO_CLIENT_SECRET;
#   3. sso.enabled without sso.authority or sso.clientId is refused at render time, and an
#      empty sso.scopes leaves Vaultwarden's own default in charge.
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

if [ "$case" != "sso" ]; then
  # 1. SSO off: nothing of it renders.
  [ -z "$sso_keys" ] || note "$case: SSO variables rendered although sso.enabled is false: $(tr '\n' ' ' <<<"$sso_keys")"
  grep -Fx "$secret" <<<"$svc_secrets" >/dev/null && note "$case: mounts $secret although sso.enabled is false"
  exit "$fail"
fi

# 1. SSO on: every value the fixture and the defaults set.
for kv in "SSO_ENABLED=true" \
          "SSO_AUTHORITY=http://vw-e2e-idp:8080/realms/e2e" \
          "SSO_CLIENT_ID=vaultwarden-e2e" \
          "SSO_CLIENT_SECRET_FILE=/run/secrets/$secret" \
          "SSO_ONLY=false" \
          "SSO_SIGNUPS_ALLOWED=true" \
          "SSO_SIGNUPS_MATCH_EMAIL=true" \
          "SSO_PKCE=true" \
          "SSO_SCOPES=email profile offline_access"; do
  got="$(env_of "${kv%%=*}")"
  [ "$got" = "${kv#*=}" ] || note "sso: ${kv%%=*} is '$got', expected '${kv#*=}'"
done

# 2. The file SSO_CLIENT_SECRET_FILE names is a secret the service mounts, declared external.
grep -Fx "$secret" <<<"$svc_secrets" >/dev/null || note "sso: $secret is not mounted, so SSO_CLIENT_SECRET_FILE names nothing"
[ "$(yq -r ".secrets.\"$secret\".external // false" "$out")" = "true" ] \
  || note "sso: $secret is not declared external (a chart never creates a secret)"

# 3. The refusals, and the empty-scopes default, rendered from this chart with the
#    renderer test-charts.sh exports.
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
printf 'sso:\n  scopes: ""\n' >"$tmp/no-scopes.yaml"
if render -f "$tmp/no-scopes.yaml" >"$tmp/no-scopes.out" 2>"$tmp/err"; then
  [ "$(yq -r '.services.vaultwarden.environment | has("SSO_SCOPES")' "$tmp/no-scopes.out")" = "false" ] \
    || note "sso: an empty sso.scopes still rendered SSO_SCOPES, overriding Vaultwarden's default"
else
  note "sso: an empty sso.scopes was refused: $(cat "$tmp/err")"
fi

exit "$fail"
