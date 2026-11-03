#!/usr/bin/env bash
#
# Renders the version-history page (index.html on GitHub Pages) from the published
# index.yaml: for every chart version, its release date, appVersion, the swarmcli it
# needs, and every image it pins (#177).
#
# The index is the input, not the releases, so the page lists exactly the versions
# `swarmcli charts install` can install. What only the tag knows is read with `git
# show <chart>/v<version>:...`, as generate-index.sh does, so this needs every tag.
#
# Images come from values.yaml the way Renovate's helm-values manager sees them:
# every map with a string `repository` (an empty `tag` falls back to appVersion, as
# the templates do) and every string key ending in "image" (ollama's
# `modelInitImage`). That lists the components a default install leaves off too
# (exporters, embedded databases), each with the values key that sets it. On the
# 197 tags released before this page existed it found every image a default render
# deploys.
#
# yq only converts YAML to JSON; jq does the rest, so @html escapes every value.
#
# Requires: git, jq, yq (mikefarah v4)
#
# Usage: ./scripts/generate-history.sh <owner/repo> <index.yaml> > index.html

set -euo pipefail

REPO="${1:?Usage: generate-history.sh <owner/repo> <index.yaml>}"
INDEX="${2:?Usage: generate-history.sh <owner/repo> <index.yaml>}"

for tool in git jq yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

PINS='def pins($app):
  [ paths as $p | getpath($p) as $v | ($p | map(tostring) | join(".")) as $key
    | if ($v | type) == "object" and ($v.repository | type) == "string" then
        {image: ($v.repository + ":" + (($v.tag // "") | tostring | if . == "" then $app else . end)), key: $key}
      elif ($v | type) == "string" and ($p[-1] | tostring | test("image$"; "i")) and ($v | test(":")) then
        {image: $v, key: $key}
      else empty end ];'

# Number-like scalars become strings before the JSON round-trip, so a `tag: 3.10`
# stays 3.10 rather than turning into the float 3.1.
to_json() { yq -o=json -I=0 '(.. | select(tag == "!!int" or tag == "!!float")) |= tostring'; }

ROWS=$(to_json <"$INDEX" | jq -c '.entries | to_entries[] | .key as $chart | .value[]
  | {chart: $chart, version, app: (.appVersion // ""), created: (.created // ""), description: (.description // "")}' |
  while IFS= read -r ENTRY; do
    TAG=$(jq -r '"\(.chart)/v\(.version)"' <<<"$ENTRY")
    CHART=${TAG%%/*}
    FLOOR=$(git show "${TAG}:charts/${CHART}/Chart.yaml" 2>/dev/null | yq -r '.swarmcliVersion // ""' || true)
    VALUES=$(git show "${TAG}:charts/${CHART}/values.yaml" 2>/dev/null | to_json || true)
    [ -n "$VALUES" ] || VALUES='{}'
    jq -c --arg floor "$FLOOR" --argjson values "$VALUES" "${PINS}"'
      .app as $app | . + {floor: $floor, images: ($values | pins($app))}' <<<"$ENTRY" || exit 1
  done)

GENERATED=$(to_json <"$INDEX" | jq -r '.generated // ""')

# The page itself. group_by is a stable sort, so each chart keeps the index's
# newest-first order, and its first row's description is the current one.
printf '%s\n' "$ROWS" | jq -s -r --arg repo "$REPO" --arg generated "$GENERATED" '
  def row: @html "<tr><td><a href=\"https://github.com/\($repo)/releases/tag/\(.chart)/v\(.version)\">\(.version)</a></td><td>\(.created[0:10])</td><td>\(.app)</td><td>\(if .floor == "" then "—" else .floor end)</td><td>"
    + ([.images[] | @html "<code>\(.image)</code> <span class=\"key\">\(.key)</span>"] | join("<br>"))
    + "</td></tr>";
  group_by(.chart) as $charts
  | "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>SwarmCLI Charts: version history</title>
<style>
body{font:15px/1.5 system-ui,sans-serif;max-width:76rem;margin:2rem auto;padding:0 1rem;color:#1f2328}
table{border-collapse:collapse;width:100%;margin-bottom:2.5rem}
th,td{border-bottom:1px solid #d0d7de;padding:.35rem .6rem;text-align:left;vertical-align:top}
code{font-size:13px}
.key{color:#59636e;font-size:13px}
</style>
</head>
<body>
<h1>SwarmCLI Charts: version history</h1>
<p>Every published version of every chart: the application version it deploys, the swarmcli it needs and every image it pins. Each image is listed with the values key that sets it, so components a default install leaves off (exporters, embedded databases) appear too.</p>
"
  + "<p>" + ([$charts[] | .[0].chart | @html "<a href=\"#\(.)\">\(.)</a>"] | join(" · ")) + "</p>\n"
  + ([$charts[] | .[0] as $head
      | (@html "<h2 id=\"\($head.chart)\">\($head.chart)</h2>\n<p>\($head.description)</p>\n")
        + "<table>\n<thead><tr><th>Version</th><th>Released</th><th>App version</th><th>swarmcli</th><th>Images</th></tr></thead>\n<tbody>\n"
        + (map(row) | join("\n"))
        + "\n</tbody>\n</table>\n"] | join(""))
  + (@html "<p>Generated from <a href=\"index.yaml\">index.yaml</a> (\($generated)).</p>\n")
  + "</body>\n</html>"'
