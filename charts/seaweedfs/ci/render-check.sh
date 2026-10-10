#!/usr/bin/env bash
#
# Render assertions for the seaweedfs chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is mostly what a deploy cannot see: every one of these mistakes still
# converges to a healthy task.
#
#   * SeaweedFS with no identity serves S3 to ANYONE. The credentials have to reach the
#     process from the secrets, and an empty secret has to stop the start, not open the
#     store.
#   * The master, volume and filer APIs are unauthenticated. If they bind the overlay,
#     every object is readable and writable without a key, while S3 itself still says 403.
#   * Without a filer signing key the S3 gateway's gRPC port accepts identity updates from
#     anyone on the overlay.
#   * A single `$` in the wrapper is interpolated by Docker at deploy time, so the secret
#     would be read on the deploying machine (or read as empty) instead of in the task.
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

svc='.services.seaweedfs'
q() { yq -r "$1" "$rendered"; }

script="$(q "$svc.command[0]")"
args="$(q "$svc.command[]" | sed 1d)"  # the script is one line; no slice syntax, older yq lacks it
[ -n "$script" ] && [ "$script" != "null" ] || bad "the service has no start-up script — every check below would pass vacuously"

# ── the wrapper and its exec target ───────────────────────────────────────────────────
[ "$(q "$svc.entrypoint | join(\" \")")" = "/bin/sh -c" ] \
  || bad "entrypoint is not [/bin/sh, -c]; the start-up script would not run"
grep -F 'exec /entrypoint.sh "$$@"' <<<"$script" >/dev/null \
  || bad "the wrapper does not exec the image entrypoint with its arguments — weed would not be PID 1, or would not start"
[ "$(sed -n 1p <<<"$args")" = "seaweedfs" ] \
  || bad "the first argument after the script is not the \$0 placeholder; 'server' would be swallowed as \$0"
[ "$(sed -n 2p <<<"$args")" = "server" ] || bad "the entrypoint is not asked for 'server'"
grep -Fx -- '-s3' <<<"$args" >/dev/null || bad "-s3 is missing: no S3 gateway would start"

# ── credentials ───────────────────────────────────────────────────────────────────────
access="$(q "$svc.secrets[0]")"
secret="$(q "$svc.secrets[1]")"
[ "$access" != "null" ] && [ "$secret" != "null" ] && [ "$access" != "$secret" ] \
  || bad "the service does not mount two distinct credential secrets (got '$access' / '$secret')"
for s in "$access" "$secret"; do
  [ "$(q ".secrets.\"$s\".external")" = "true" ] || bad "secret $s is not declared external: true"
done
grep -F "export AWS_ACCESS_KEY_ID=\"\$\$(cat /run/secrets/$access)\"" <<<"$script" >/dev/null \
  || bad "AWS_ACCESS_KEY_ID is not exported from /run/secrets/$access — SeaweedFS would know no identity and serve anonymously"
grep -F "export AWS_SECRET_ACCESS_KEY=\"\$\$(cat /run/secrets/$secret)\"" <<<"$script" >/dev/null \
  || bad "AWS_SECRET_ACCESS_KEY is not exported from /run/secrets/$secret"
grep -F "for s in $access $secret; do" <<<"$script" >/dev/null \
  && grep -F 'test -s "/run/secrets/$$s" ||' <<<"$script" >/dev/null \
  || bad "the wrapper does not refuse to start on a missing or empty secret — an empty one would turn authentication OFF"
# A single-$ expansion anywhere would be resolved by Docker at deploy time.
if grep -E '(^|[^$])\$[({A-Za-z@]' <<<"$script" >/dev/null; then
  bad "the start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
fi
if [ "$(q "$svc.environment.AWS_SECRET_ACCESS_KEY")" != "null" ] || [ "$(q "$svc.environment.AWS_ACCESS_KEY_ID")" != "null" ]; then
  bad "a credential is set in environment:, where it lands in the manifest and docker inspect"
fi

# ── only S3 leaves the container ──────────────────────────────────────────────────────
grep -Fx -- '-ip=127.0.0.1' <<<"$args" >/dev/null && grep -Fx -- '-ip.bind=127.0.0.1' <<<"$args" >/dev/null \
  || bad "master/volume/filer are not bound to 127.0.0.1 — their unauthenticated APIs would be reachable from the overlay"
grep -Fx -- '-s3.ip.bind=0.0.0.0' <<<"$args" >/dev/null \
  || bad "the S3 gateway is not bound to 0.0.0.0 — it would follow -ip.bind onto loopback and nothing outside could reach it"
grep -Fx -- '-s3.port.iceberg=0' <<<"$args" >/dev/null && grep -Fx -- '-s3.port.lance=0' <<<"$args" >/dev/null \
  || bad "the Iceberg/Lance catalog listeners are not disabled"
grep -F 'export WEED_JWT_FILER_SIGNING_KEY="$$(head -c 32 /dev/urandom | base64)"' <<<"$script" >/dev/null \
  || bad "no per-start filer signing key: the S3 gRPC port would accept identity updates from anyone on the overlay"

# ── port wiring: one value drives listener, probe, edge target and publish target ────
port="$(sed -n 's/^-s3.port=\([0-9]*\)$/\1/p' <<<"$args")"
[ -n "$port" ] || bad "-s3.port is not rendered"
hc="$(q "$svc.healthcheck.test | join(\" \")")"
[ "$hc" = "CMD curl -fsS -o /dev/null http://127.0.0.1:$port/healthz" ] \
  || bad "the healthcheck does not probe /healthz on the S3 port $port (got: $hc)"

# ── one process owns /data ────────────────────────────────────────────────────────────
[ "$(q "$svc.deploy.replicas")" = "1" ] || bad "replicas is not 1: two weed servers would share one /data"
[ "$(q "$svc.deploy.update_config.order")" = "stop-first" ] \
  || bad "update_config.order is not stop-first: old and new tasks would briefly share /data"
[ "$(q "$svc.stop_grace_period")" != "null" ] || bad "no stop_grace_period"

# ── networks ──────────────────────────────────────────────────────────────────────────
nets="$(q "$svc.networks[]")"
grep -Fx seaweedfs-net <<<"$nets" >/dev/null || bad "the service is not on network.name (seaweedfs-net): other stacks could not reach it"
[ "$(q '.networks."seaweedfs-net".external')" = "true" ] || bad "seaweedfs-net is not external — it would be stack-scoped and unreachable by name from other stacks"

# ── exposure ──────────────────────────────────────────────────────────────────────────
labels="$(q "$svc.deploy.labels[]")"
case "$case" in
  traefik|edge)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
             "traefik.http.services.ci.loadbalancer.server.port=$port"; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published in traefik mode"
    ;;
  published)
    [ "$(q "$svc.ports[0].target")" = "$port" ] && [ "$(q "$svc.ports[0].published")" = "18333" ] \
      || bad "case $case: the S3 port is not published as 18333 -> $port"
    ;;
  *)
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    [ "$nets" = "seaweedfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    ;;
esac
case "$case" in
  traefik)
    grep -Fx 'traefik.http.routers.ci-http.middlewares=https-redirect' <<<"$labels" >/dev/null \
      || bad "case $case: tls is on but HTTP does not redirect"
    grep -Fx 'traefik.http.routers.ci-https.rule=Host(`s3-cache.example.com`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTPS router for ingress.host"
    grep -Fx 'traefik.http.routers.ci-https.tls.certresolver=le' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router has no certresolver"
    ;;
  edge)
    if grep -F 'https' <<<"$labels" >/dev/null; then bad "case $case: tls is off but an https router or redirect is rendered"; fi
    grep -Fx 'traefik.http.routers.ci-http.rule=Host(`s3.e2e.test`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTP router for ingress.host"
    ;;
esac

# ── buckets ───────────────────────────────────────────────────────────────────────────
case "$case" in
  buckets) want='runner-cache e2e.second-bucket' ;;
  traefik|edge) want='runner-cache' ;;
  ephemeral) want='scratch' ;;
  oidc) want='idp runner-cache reports' ;;
  *) want='' ;;
esac
if [ -n "$want" ]; then
  grep -F "for b in $want; do" <<<"$script" >/dev/null || bad "case $case: the bootstrap loop does not iterate exactly '$want'"
  grep -F "\"http://127.0.0.1:$port/\$\$b\"" <<<"$script" >/dev/null \
    || bad "case $case: buckets are not created against the S3 port $port"
  grep -F -- '--aws-sigv4' <<<"$script" >/dev/null || bad "case $case: bucket creation is not signed — it would be refused"
  grep -F '[ "$$code" = 409 ]' <<<"$script" >/dev/null \
    || bad "case $case: 409 (bucket exists) is not treated as done — every restart would retry for five minutes"
  grep -F ') & exec /entrypoint.sh' <<<"$script" >/dev/null \
    || bad "case $case: the bootstrap loop does not run in the background — it would block the server it waits for"
else
  if grep -F 'for b in' <<<"$script" >/dev/null; then bad "case $case: a bucket loop is rendered with no buckets"; fi
fi

# ── persistence and placement ─────────────────────────────────────────────────────────
mounts="$(q "$svc.volumes[]")"
constraints="$(q "$svc.deploy.placement.constraints[]")"
case "$case" in
  ephemeral)
    [ "$(q "$svc.volumes")" = "null" ] || bad "case $case: /data is mounted although persistence is off"
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a top-level volume is declared although persistence is off"
    [ "$(q "$svc.deploy.placement")" = "null" ] || bad "case $case: a placement block is rendered although persistence is off"
    ;;
  bind-mount)
    grep -Fx '/tmp/seaweedfs-e2e/data:/data' <<<"$mounts" >/dev/null || bad "case $case: the host path is not bind-mounted at /data"
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a named volume is declared although volumePath takes precedence"
    grep -Fx 'node.labels.seaweedfs-e2e-node == true' <<<"$constraints" >/dev/null || bad "case $case: the custom node pin is missing"
    ;;
  *)
    grep -Fx 'seaweedfs-data:/data' <<<"$mounts" >/dev/null || bad "case $case: the named volume is not mounted at /data"
    [ "$(q '.volumes."seaweedfs-data"')" != "null" ] || bad "case $case: the named volume is not declared at the top level"
    grep -Fx 'node.labels.seaweedfs-data == true' <<<"$constraints" >/dev/null || bad "case $case: the data node pin is missing"
    ;;
esac
if [ "$case" = "buckets" ]; then
  grep -Fx 'node.role == manager' <<<"$constraints" >/dev/null || bad "case $case: placement.constraints was not applied"
fi

# ── OIDC ──────────────────────────────────────────────────────────────────────────────
# SeaweedFS logs a broken IAM file and carries on without OIDC, and it trusts the file for
# every security property, so the generated JSON is checked here field by field: what each
# of these lines guards still converges to a healthy task.
iamarg='-s3.iam.config=/tmp/seaweedfs-iam.json'
iamwrite="printf '%s' \"\$\$SEAWEEDFS_IAM_CONFIG\" > /tmp/seaweedfs-iam.json;"
iamjson="$(q "$svc.environment.SEAWEEDFS_IAM_CONFIG")"
if [ "$case" != "oidc" ]; then
  if grep -F -- '-s3.iam.config' <<<"$args" >/dev/null; then bad "case $case: -s3.iam.config is passed although oidc is off"; fi
  if grep -F -- '-s3.iam=' <<<"$args" >/dev/null; then bad "case $case: -s3.iam is set although oidc is off"; fi
  [ "$iamjson" = "null" ] || bad "case $case: SEAWEEDFS_IAM_CONFIG is set although oidc is off"
  if grep -F 'SEAWEEDFS_IAM_CONFIG' <<<"$script" >/dev/null; then bad "case $case: the wrapper writes an IAM file although oidc is off"; fi
else
  grep -Fx -- "$iamarg" <<<"$args" >/dev/null || bad "case $case: $iamarg is not passed — OIDC would be off"
  grep -Fx -- '-s3.iam=false' <<<"$args" >/dev/null \
    || bad "case $case: -s3.iam=false is not passed — the embedded IAM API would list the admin's access key id to any granted token"
  [[ "${script%%exec /entrypoint.sh*}" == *"$iamwrite"* ]] \
    || bad "case $case: the wrapper does not write SEAWEEDFS_IAM_CONFIG to the -s3.iam.config path before exec"
  j() { yq -p json -r "$1" <<<"$iamjson"; }
  iss='http://127.0.0.1:8888/buckets/idp'
  role='arn:aws:iam::role/oidc'
  groups='ci-cache auditors'
  [ "$(j '.policy.defaultEffect')" = "Deny" ] \
    || bad "case $case: policy.defaultEffect is not Deny — a trust policy that matches nothing would ALLOW, so any token could assume the role"
  keys="$(j '[.. | select(tag == "!!map") | keys | .[]] | unique | .[]')"
  for k in sts signingKey policyClaim clientSecret defaultRole oidc:aud; do
    if grep -Fx "$k" <<<"$keys" >/dev/null; then bad "case $case: the IAM file carries '$k'"; fi
  done
  # The provider: one, with the issuer and client from the fixture and a role mapping that
  # sends every granted group, and nothing else, to the one role.
  [ "$(j '.providers | length')" = "1" ] && [ "$(j '.providers[0].type')" = "oidc" ] || bad "case $case: not exactly one oidc provider"
  [ "$(j '.providers[0].config.issuer')" = "$iss" ] || bad "case $case: the provider issuer is not oidc.issuer"
  [ "$(j '.providers[0].config.clientId')" = "seaweedfs-s3" ] || bad "case $case: the provider clientId is not oidc.clientId"
  [ "$(j '.providers[0].config.jwksUri')" = "" ] || bad "case $case: the provider jwksUri is not oidc.jwksUri (\"\": discovery)"
  [ "$(j '[.providers[0].config.roleMapping.rules[] | .claim + " " + .role] | unique | join(",")')" = "groups $role" ] \
    || bad "case $case: a role-mapping rule does not map the groups claim to $role (without roleMapping SeaweedFS maps hard-coded group names)"
  [ "$(j '[.providers[0].config.roleMapping.rules[].value] | join(" ")')" = "$groups" ] \
    || bad "case $case: the role-mapping rules do not cover exactly the granted groups"
  # The role: one, attached to the one policy, assumable only with the issuer AND a granted
  # group. STS lets the caller name the role, so this trust policy is the whole gate.
  [ "$(j '.roles | length')" = "1" ] && [ "$(j '.roles[0].roleArn')" = "$role" ] && [ "$(j '.roles[0].attachedPolicies | join(",")')" = "oidc" ] \
    || bad "case $case: not exactly one role $role attached to the oidc policy"
  [ "$(j '.roles[0].trustPolicy.Statement | length')" = "1" ] || bad "case $case: the trust policy does not have exactly one statement"
  tp='.roles[0].trustPolicy.Statement[0]'
  [ "$(j "$tp.Effect + \" \" + ($tp.Action | join(\",\"))")" = "Allow sts:AssumeRoleWithWebIdentity" ] \
    || bad "case $case: the trust statement does not allow exactly sts:AssumeRoleWithWebIdentity"
  [ "$(j "$tp.Condition | keys | join(\",\")")" = "ForAnyValue:StringEquals,StringEquals" ] \
    || bad "case $case: the trust condition is not exactly the issuer and the groups"
  [ "$(j "$tp.Condition.StringEquals | to_entries | map(.key + \"=\" + .value) | join(\",\")")" = "oidc:iss=$iss" ] \
    || bad "case $case: the trust policy does not pin oidc:iss to oidc.issuer"
  [ "$(j "$tp.Condition.\"ForAnyValue:StringEquals\".\"oidc:groups\" | join(\" \")")" = "$groups" ] \
    || bad "case $case: the trust policy does not require one of the granted groups — any token of the realm could assume the role"
  # The grants: one statement each, conditioned on exactly its group, with explicit actions.
  [ "$(j '.policies | length')" = "1" ] && [ "$(j '.policies[0].name')" = "oidc" ] || bad "case $case: not exactly one policy named oidc"
  st='.policies[0].document.Statement'
  [ "$(j "$st | length")" = "2" ] || bad "case $case: not one policy statement per grant"
  [ "$(j "[${st}[] | .Condition | keys | join(\",\")] | unique | join(\" \")")" = "ForAnyValue:StringEquals" ] \
    && [ "$(j "[${st}[] | .Condition.\"ForAnyValue:StringEquals\".\"jwt:groups\" | join(\",\")] | join(\" \")")" = "$groups" ] \
    || bad "case $case: a grant is not conditioned on exactly its own group — it would apply to every group"
  [ "$(j "[${st}[].Action[]] | sort | unique | join(\" \")")" = "s3:DeleteObject s3:GetBucketLocation s3:GetObject s3:ListBucket s3:PutObject" ] \
    || bad "case $case: the grants use other actions than the five explicit ones (s3:Put* or s3:* would include s3:PutBucketPolicy)"
  [ "$(j "${st}[0].Action | join(\" \")")" = "s3:GetObject s3:ListBucket s3:GetBucketLocation s3:PutObject s3:DeleteObject" ] \
    && [ "$(j "${st}[0].Resource | join(\" \")")" = "arn:aws:s3:::runner-cache arn:aws:s3:::runner-cache/*" ] \
    || bad "case $case: the readwrite grant is not read+write on runner-cache and its objects only"
  [ "$(j "${st}[1].Action | join(\" \")")" = "s3:GetObject s3:ListBucket s3:GetBucketLocation" ] \
    && [ "$(j "${st}[1].Resource | join(\" \")")" = "arn:aws:s3:::*" ] \
    || bad "case $case: the readonly grant with buckets [] is not read-only on every bucket"

  # ── the refusals: the schema's, then the template's own with the schema removed ─────
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$chart" "$tmp/noschema"
  rm "$tmp/noschema/values.schema.json"
  render() { local dir="$1"; shift; "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$dir" -f "$chart/ci/oidc-values.yaml" "$@"; }
  refused() {
    local dir="$1" want="$2"; shift 2
    if render "$dir" "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* ($dir) — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* ($dir) failed, but not with \"$want\": $(tail -1 "$tmp/err")"
    fi
  }
  for dir in "$chart" "$tmp/noschema"; do
    render "$dir" >/dev/null 2>"$tmp/err" || bad "the oidc fixture itself does not render ($dir): $(tail -1 "$tmp/err")"
  done
  refused "$chart" "at '/oidc/issuer'" --set oidc.issuer=sso.example.com/realms/infra
  refused "$chart" "at '/oidc/issuer'" --set oidc.issuer=
  refused "$chart" "at '/oidc/clientId'" --set oidc.clientId=
  refused "$chart" "at '/oidc/grants'" --set 'oidc.grants={}'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=ci*'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=ci?'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=${ci}'
  refused "$chart" "at '/oidc/grants/0/access'" --set 'oidc.grants[0].access=admin'
  refused "$chart" "at '/oidc/grants/0/buckets/0'" --set 'oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$chart" "additional properties 'bucket' not allowed" --set 'oidc.grants[0].bucket[0]=runner-cache'
  refused "$chart" "at '/oidc/jwksUri'" --set oidc.jwksUri=sso.example.com/certs
  printf 'oidc:\n  grants:\n    - { group: ci-cache, access: readwrite }\n' >"$tmp/nobuckets.yaml"
  refused "$chart" "missing property 'buckets'" -f "$tmp/nobuckets.yaml"
  ns="$tmp/noschema"
  refused "$ns" "oidc.issuer must be the identity provider's issuer URL" --set oidc.issuer=sso.example.com/realms/infra
  refused "$ns" "oidc.issuer must be the identity provider's issuer URL" --set oidc.issuer=
  refused "$ns" "oidc.clientId is required" --set oidc.clientId=
  refused "$ns" "oidc.grants needs at least one grant" --set 'oidc.grants={}'
  refused "$ns" "group \"ci*\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=ci*'
  refused "$ns" "group \"ci?\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=ci?'
  refused "$ns" "group \"\${ci}\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=${ci}'
  refused "$ns" "group \"\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group='
  refused "$ns" "has access \"admin\"; it must be readonly or readwrite" --set 'oidc.grants[0].access=admin'
  refused "$ns" "\"Runner_Cache\" is not a valid S3 bucket name" --set 'oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$ns" "group \"ci-cache\" has no buckets list" -f "$tmp/nobuckets.yaml"
  # The fixture discovers its keys; an explicit jwksUri must reach the provider as given.
  render "$chart" --set oidc.jwksUri=https://sso.example.com/certs >"$tmp/jwks.yaml" 2>"$tmp/err" \
    && [ "$(yq -r "$svc.environment.SEAWEEDFS_IAM_CONFIG" "$tmp/jwks.yaml" | yq -p json -r '.providers[0].config.jwksUri')" = "https://sso.example.com/certs" ] \
    || bad "an explicit oidc.jwksUri does not reach the provider config"
  # A `$` in a value must reach the container as `$`, not be interpolated by Docker.
  render "$chart" --set 'oidc.clientId=seaweedfs$s3' >"$tmp/dollar.yaml" 2>"$tmp/err" \
    && grep -F 'seaweedfs$$s3' "$tmp/dollar.yaml" >/dev/null \
    || bad "a \$ in oidc.clientId is not escaped as \$\$ in SEAWEEDFS_IAM_CONFIG — Docker would interpolate it"
fi

exit "$fail"
