#!/usr/bin/env bash
#
# Scaffold a new chart that passes `make lint` and `make test` out of the box.
# Generates charts/<name>/ with Chart.yaml, values.yaml, values.schema.json,
# templates/stack.yaml.tmpl, requirements.yaml, README.md and a
# ci/default-values.yaml fixture.
#
# Usage: scripts/new-chart.sh <name>
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "usage: scripts/new-chart.sh <name>" >&2
  exit 2
fi
if ! printf '%s' "$NAME" | grep -Eq '^[a-z][a-z0-9-]*$'; then
  echo "ERROR: chart name must be lowercase alphanumeric with dashes (got: $NAME)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/charts/$NAME"
if [ -e "$DIR" ]; then
  echo "ERROR: charts/$NAME already exists" >&2
  exit 1
fi

mkdir -p "$DIR/templates" "$DIR/ci"

cat >"$DIR/Chart.yaml" <<EOF
name: $NAME
description: TODO one-line description of $NAME
version: 0.1.0
appVersion: "latest"
maintainers:
  - name: Eldara
    url: https://github.com/Eldara-Tech
keywords:
  - $NAME
home: https://github.com/Eldara-Tech/swarmcli-charts
sources:
  - https://github.com/Eldara-Tech/swarmcli-charts
EOF

cat >"$DIR/values.yaml" <<EOF
# $NAME chart default values

image:
  repository: nginx
  tag: ""  # defaults to appVersion from Chart.yaml

replicas: 1

# Extra deploy labels (key: value)
labels: {}
EOF

cat >"$DIR/values.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "image": {
      "type": "object",
      "properties": {
        "repository": { "type": "string" },
        "tag": { "type": "string" }
      },
      "required": ["repository"]
    },
    "replicas": { "type": "integer", "minimum": 1 },
    "labels": { "type": "object" }
  }
}
EOF

cat >"$DIR/templates/stack.yaml.tmpl" <<'EOF'
version: "3.9"

services:
  {{ .Chart.Name }}:
    image: {{ .Values.image.repository }}:{{ if .Values.image.tag }}{{ .Values.image.tag }}{{ else }}{{ .Chart.AppVersion }}{{ end }}
    networks:
      - default
    deploy:
      replicas: {{ .Values.replicas }}
      restart_policy:
        condition: on-failure
{{- if .Values.labels }}
      labels:
{{- range $key, $val := .Values.labels }}
        - "{{ $key }}={{ $val }}"
{{- end }}
{{- end }}

networks:
  default: {}
EOF

cat >"$DIR/requirements.yaml" <<'EOF'
# External resources this chart needs (optional but authoritative when present:
# every external network/secret/config the rendered stack references must be
# listed here). Delete this file if the chart uses no external resources.
#
# networks:
#   - name: traefik-public   # the external network's real name (required)
#     driver: overlay        # optional, default "overlay"
#     attachable: true       # optional, default true
#     autoCreate: true       # optional, default true (false => validate-only)
#     description: "Shared ingress overlay"
# secrets:                   # validated, never auto-created
#   - name: db-password
#     description: "Postgres password"
# configs: []
networks: []
secrets: []
configs: []
EOF

cat >"$DIR/README.md" <<EOF
# $NAME

TODO describe what this chart deploys.

## Installing

\`\`\`bash
swarmcli charts install $NAME swarmcli-charts/$NAME
\`\`\`

## Values

| Key | Default | Description |
|-----|---------|-------------|
| \`image.repository\` | \`nginx\` | Container image |
| \`image.tag\` | \`""\` | Image tag — defaults to \`appVersion\` |
| \`replicas\` | \`1\` | Number of replicas |
| \`labels\` | \`{}\` | Extra deploy labels |
EOF

cat >"$DIR/ci/default-values.yaml" <<EOF
# Default render case for CI. Add more ci/<case>-values.yaml files to exercise
# meaningful value permutations (e.g. ci/scaled-values.yaml).
EOF

echo "Created charts/$NAME"
echo "Next:"
echo "  1. edit charts/$NAME/{Chart.yaml,values.yaml,templates/stack.yaml.tmpl,README.md}"
echo "  2. add ci/<case>-values.yaml fixtures for meaningful value combinations"
echo "  3. make test CHART=$NAME"
