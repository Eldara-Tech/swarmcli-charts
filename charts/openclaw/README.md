# openclaw

[OpenClaw](https://openclaw.ai) — a self-hosted personal AI assistant — packaged as a
Docker Swarm stack. This chart runs the OpenClaw **gateway** (control plane + Control UI,
HTTP port `18789`): stateful (config, SQLite DB and workspace on a node-local named
volume; OAuth token encryption keys on a second one), single-node pinned, and fronted by
Traefik with TLS by default. The gateway API token comes from an external Swarm secret.
OpenClaw is backend-agnostic — wire any local model or API provider via `extraEnv` (and,
for a network-reachable backend such as a co-located Ollama, `backend.network`).

> **Never expose the gateway (`:18789`) to the internet without TLS and a token.** The
> defaults (Traefik + TLS at the edge + `auth.enabled`) satisfy this; keep them unless you
> front the gateway with your own TLS-terminating proxy.

## Prerequisites

1. Label the node that will hold the data volumes (Swarm volumes are node-local, so the
   service is pinned to exactly one node):

   ```bash
   docker node update --label-add openclaw-data=true <node>
   ```

2. Pre-create the gateway token secret. The chart **validates** this secret but never
   creates it (its content is operator-supplied):

   ```bash
   printf 'S3cr3t' | docker secret create openclaw_gateway_token -
   ```

3. An external ingress overlay named `traefik-public` (traefik & none modes), provisioned
   by the [traefik](../traefik) chart or your operator. It is `autoCreate:false` — swarmcli
   validates it exists and never creates it.

4. Provision **≥ 2 GB RAM** for the gateway (`--set resources.limits.memory=2G`); it can
   OOM (exit 137) at 1 GB.

**First boot:** the volumes start empty. Configure the assistant through the Control UI at
`https://<ingress.host>` after the stack converges. To seed `openclaw.json` (or the OAuth
keys) declaratively instead, write them into the `openclaw-data` / `openclaw-auth` volumes
on the pinned node before first start (e.g. `docker run --rm -v openclaw-data:/d busybox …`).

## Installing

```bash
swarmcli charts install openclaw swarmcli-charts/openclaw \
  --set ingress.host=openclaw.example.com \
  --set resources.limits.memory=2G
```

## Exposure modes

Set `exposure.mode`:

- `traefik` *(default)* — Traefik router labels on `exposure.network`; TLS at the edge via
  `traefik.certResolver`. Set `ingress.host` and `ingress.tls`.
- `published` — publish `publish.port` on the Swarm directly (plain HTTP). Front it with
  your own TLS; set `allowedOrigins` explicitly.
- `none` — no port and no labels; the gateway sits on `exposure.network` for a reverse
  proxy you manage.

## Wiring a model backend

OpenClaw talks to whatever backend you configure. For an API provider, pass its
credentials/URL via `extraEnv` (no extra network needed):

```bash
--set extraEnv.OPENAI_API_KEY=sk-…
```

For a network-reachable backend such as a co-located Ollama, join its overlay and point
the gateway at it:

```bash
--set backend.enabled=true \
--set backend.network=ai-internal \
--set extraEnv.OLLAMA_HOST=http://ollama:11434
```

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ghcr.io/openclaw/openclaw` | Image repository |
| `image.tag` | `""` | Tag — defaults to appVersion (`2026.6.11`) |
| `replicas` | `1` | Replica count (must stay 1 — node-local volumes) |
| `persistence.enabled` | `true` | Mount the named state volumes |
| `persistence.dataVolume` | `openclaw-data` | Named volume for `/home/node/.openclaw` (config, DB, workspace) |
| `persistence.authVolume` | `openclaw-auth` | Named volume for `/home/node/.config/openclaw` (OAuth keys) |
| `persistence.dataPath` | `""` | Host dir for `/home/node/.openclaw`; when set, bind-mounts it and takes precedence over `dataVolume` (needs the `host-mount` acknowledgment) |
| `persistence.authPath` | `""` | Host dir for `/home/node/.config/openclaw`; when set, bind-mounts it and takes precedence over `authVolume` |
| `auth.enabled` | `true` | Require a gateway API token |
| `auth.secretName` | `openclaw_gateway_token` | External Swarm secret holding the token |
| `exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `exposure.network` | `traefik-public` | External ingress overlay (traefik & none modes) |
| `ingress.host` | `openclaw.example.com` | Public hostname (Traefik rule + default allowed origin) |
| `ingress.tls` | `true` | Public endpoint is HTTPS (proxied modes) |
| `traefik.certResolver` | `le` | Traefik ACME cert resolver |
| `traefik.entrypoints.http` / `.https` | `web` / `websecure` | Traefik entrypoints |
| `publish.port` | `18789` | Published port (published mode) |
| `publish.mode` | `ingress` | `ingress` (routing mesh) or `host` (pinned node) |
| `service.port` | `18789` | Container HTTP port (Traefik LB / publish target) |
| `allowedOrigins` | `""` | CORS origins; empty ⇒ `<scheme>://<ingress.host>` |
| `gatewayBind` | `lan` | Gateway bind interface (`lan` so the proxy can reach it) |
| `backend.enabled` | `false` | Join `backend.network` for a network-reachable backend |
| `backend.network` | `openclaw-backend` | External overlay to join when `backend.enabled` |
| `extraEnv` | `{}` | Arbitrary extra environment (backend keys/URLs, etc.) |
| `placement.constraints` | `["node.labels.openclaw-data == true"]` | Node pin |
| `resources.limits.memory` | `""` | Swarm deploy memory limit (set `2G`) |
| `healthcheck.*` | see `values.yaml` | `node fetch()` `/healthz` healthcheck |
| `labels` | `{}` | Extra deploy labels |

## Requirements

External resources (declared in `requirements.yaml`, validated by swarmcli's pre-flight):

- **Network** `traefik-public` (traefik & none modes) — `autoCreate:false`, operator/traefik-provisioned.
- **Network** `backend.network` (only when `backend.enabled`) — `autoCreate:false`, provisioned by the backend's operator.
- **Secret** `openclaw_gateway_token` (when `auth.enabled`) — operator-created, never chart-created.

## Security note

OpenClaw reads the gateway token from its mounted secret file natively via
`OPENCLAW_GATEWAY_TOKEN_FILE=/run/secrets/openclaw_gateway_token`, so the token never
lands in the compose file or `docker inspect` — only the file path does. By default state
uses node-local named volumes (no host bind mounts), and the container runs as the image's
non-root `node` user; the chart adds no `docker.sock`, `privileged`, host network/PID or
`cap_add`. The only host-filesystem access is the **opt-in** `persistence.dataPath` /
`authPath` (bind-mounting operator-chosen host directories); it is off by default and
acknowledged via `annotations: { swarmcli-charts/allow: "host-mount" }` in `Chart.yaml`,
so the security scan flags it only when you configure a host path.
