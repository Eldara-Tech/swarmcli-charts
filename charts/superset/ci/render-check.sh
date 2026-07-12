#!/usr/bin/env bash
#
# Render-time assertions for the superset chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Superset's real configuration is a generated superset_config.py, carried base64-encoded in the
# SUPERSET_CONFIG_B64 env var — so it is invisible to the repo's other checks (the security scan
# greps the rendered YAML, and a base64 blob hides everything inside it). This decodes the blob
# and asserts the properties that matter and that a refactor could silently break:
#
#   1. no plaintext credential ever lands in the config — every secret is read from
#      /run/secrets at import time;
#   2. the config is valid Python (a broken quote in a value would otherwise only surface as a
#      crash-looping container in e2e);
#   3. the Celery broker is not the SQLite default (which silently breaks workers);
#   4. rate limiting is backed by Redis, not flask-limiter's per-replica in-memory store;
#   5. proxied modes trust X-Forwarded-* (without it, OAuth/CSRF redirects are built as http://);
#   6. SSO never hands a new user the Admin role (the footgun this chart deliberately avoids).
set -euo pipefail

out="$1"
case="${2:-}"

fail=0
note() { echo "   FAIL: $1"; fail=1; }

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "   note: mikefarah yq v4 not found — skipping superset render checks"
  exit 0
fi

cfg="$(yq -r '.services.app.environment.SUPERSET_CONFIG_B64' "$out" | base64 -d)"

# 1. secrets are read from files, never inlined.
grep -q "def _secret(name):" <<<"$cfg" || note "generated config has no _secret() file reader"
grep -q 'SECRET_KEY = _secret(' <<<"$cfg" || note "SECRET_KEY is not read from a mounted secret"
grep -q '_DB_PW = quote(_secret(' <<<"$cfg" || note "the DB password is not read from a mounted secret"

# 2. it must actually be Python. python3 is on every runner that has yq.
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$cfg" | python3 -c 'import ast,sys; ast.parse(sys.stdin.read())' \
    || note "generated superset_config.py is not valid Python"
fi

# 3./4. celery + rate limiting must be on Redis.
grep -q "broker_url = _R" <<<"$cfg" || note "CELERY_CONFIG.broker_url is not the Redis URL (SQLite default left in place?)"
grep -q "RATELIMIT_STORAGE_URI = _R" <<<"$cfg" || note "RATELIMIT_STORAGE_URI is not backed by Redis"

# 5. proxied modes (traefik/none) must trust the edge's forwarded headers.
case "$case" in
  published)
    grep -q "ENABLE_PROXY_FIX" <<<"$cfg" && note "ENABLE_PROXY_FIX must not be set in published mode (no proxy in front)"
    ;;
  *)
    grep -q "ENABLE_PROXY_FIX = True" <<<"$cfg" || note "proxied mode without ENABLE_PROXY_FIX (OAuth/CSRF redirects would be built as http://)"
    ;;
esac

# 6. SSO must not auto-promote new users to Admin.
if [ "$case" = "oidc" ]; then
  grep -q "AUTH_TYPE = AUTH_OAUTH" <<<"$cfg" || note "oidc fixture did not render AUTH_OAUTH"
  grep -q 'AUTH_USER_REGISTRATION_ROLE = "Admin"' <<<"$cfg" \
    && note "AUTH_USER_REGISTRATION_ROLE is Admin — every SSO user would become a Superset admin"
  grep -q "'client_secret': _secret(" <<<"$cfg" || note "the OAuth client secret is not read from a mounted secret"
fi

# The pip step exists exactly when the chart is expected to install a driver.
pkgs="$(yq -r '.services.app.command[0]' "$out")"
if [ "$case" = "byo-image" ]; then
  grep -q "pip install" <<<"$pkgs" && note "byo-image renders a pip step (python.installDrivers is false)"
else
  grep -q "pip install" <<<"$pkgs" || note "no driver install rendered — the lean image cannot reach its metadata DB"
fi
if [ "$case" = "mysql" ]; then
  grep -q "PyMySQL" <<<"$pkgs" || note "mysql dialect did not install PyMySQL"
  grep -q "mysql+pymysql://" <<<"$cfg" || note "mysql dialect did not render the mysql+pymysql driver"
fi

exit "$fail"
