#!/usr/bin/env bash
#
# Render-time assertions for the renovate chart, run by scripts/test-charts.sh after a
# fixture renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Renovate chooses its config parser from the config file's EXTENSION
# (lib/workers/global/config/parse/util.ts — `switch (upath.extname(file))`) and its caller
# turns the default branch into `logger.fatal('Unsupported file type'); process.exit(1)`.
# v0.1.0 mounted the config at /run/configs/renovate-config, with no extension at all, so
# configName was broken for every possible value and every possible config content (#110) —
# a bug that renders, compose-validates and deploys perfectly, and only shows up in the
# container's log. Assert the mount target and RENOVATE_CONFIG_FILE agree and carry an
# extension Renovate really parses.
set -euo pipefail

out="$1"

env_path=$(sed -n 's/^[[:space:]]*RENOVATE_CONFIG_FILE:[[:space:]]*"\?\([^"]*\)"\?[[:space:]]*$/\1/p' "$out")
tgt_path=$(sed -n 's|^[[:space:]]*target:[[:space:]]*"\?\(/run/configs/[^"]*\)"\?[[:space:]]*$|\1|p' "$out")

# A fixture that leaves configName empty renders neither — nothing to assert.
if [ -z "$env_path" ] && [ -z "$tgt_path" ]; then
  exit 0
fi

if [ -z "$env_path" ] || [ -z "$tgt_path" ]; then
  echo "  FAIL: config mount is half-rendered (RENOVATE_CONFIG_FILE='$env_path', target='$tgt_path')"
  exit 1
fi

if [ "$env_path" != "$tgt_path" ]; then
  echo "  FAIL: RENOVATE_CONFIG_FILE ($env_path) does not point at the mount target ($tgt_path)"
  exit 1
fi

case "$env_path" in
  *.json | *.json5 | *.jsonc | *.yaml | *.yml | *.js | *.cjs | *.mjs) ;;
  *)
    echo "  FAIL: $env_path has no extension Renovate parses — it would exit 'FATAL: Unsupported file type' (#110)"
    exit 1
    ;;
esac

echo "  config: mounted at $env_path — an extension Renovate parses"
