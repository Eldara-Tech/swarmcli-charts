# openclaw

[OpenClaw](https://openclaw.ai) — a self-hosted personal AI assistant — packaged as a
Docker Swarm stack. This chart runs the OpenClaw **gateway** (control plane + Control UI,
HTTP port `18789`): stateful (config, SQLite DB and workspace on a node-local named
volume; OAuth token encryption keys on a second one), single-node pinned, and fronted by
Traefik with TLS by default. The gateway API token comes from an external Swarm secret.
The model backend is configured inside OpenClaw (`openclaw.json` / Control UI), not by this
chart — for a network-reachable backend such as a co-located Ollama, `backend.network` joins
the gateway to the backend's overlay so it can reach it (see [Wiring a model
backend](#wiring-a-model-backend)).

> **Never expose the gateway (`:18789`) to the internet without TLS and a token.** The
> gateway token is always required (OpenClaw is fail-closed without auth); the defaults
> (Traefik + TLS at the edge) satisfy the TLS half — keep them unless you front the gateway
> with your own TLS-terminating proxy.

## Prerequisites

1. Label the node that will hold the data volumes (Swarm volumes are node-local, so the
   service is pinned to exactly one node while `persistence.enabled`; the pin is dropped
   together with persistence, and `persistence.nodeLabel: ""` skips it, e.g. on a
   single-node swarm):

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

**First boot:** the volumes start empty. The gateway launches with `--allow-unconfigured`
(see `allowUnconfigured`) so it boots without a pre-seeded `gateway.mode=local` — OpenClaw's
config guard would otherwise abort startup; auth stays enforced. Configure the assistant
through the Control UI at `https://<ingress.host>` after the stack converges. To seed
`openclaw.json` (or the OAuth keys) declaratively instead, write them into the
`openclaw-data` / `openclaw-auth` volumes on the pinned node before first start (e.g.
`docker run --rm -v openclaw-data:/d busybox …`) and you may then set `allowUnconfigured=false`.

**Approving your browser (first login):** a non-loopback browser reaching the Control UI is
shown "pairing required" with the exact device request ID (loopback `127.0.0.1` connections
are auto-approved, which is why the container health check needs no pairing). Approve it from
inside the running gateway container:

```bash
cid=$(docker ps -q -f "label=com.docker.swarm.service.name=<release>_gateway")   # on the pinned node
docker exec -it "$cid" sh -c \
  'export OPENCLAW_GATEWAY_TOKEN="$(cat /run/secrets/openclaw_gateway_token)"; openclaw devices approve <requestId>'
```

If the CLI returns `unknown requestId` (a known OpenClaw bug), approve the device from the
Control UI dashboard instead. For the gateway to see your real browser IP (not Traefik's) in
proxied modes, set `trustedProxies` to your ingress overlay's subnet.

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

**The backend is configured inside OpenClaw, not through this chart's environment.** OpenClaw
does not select or point at a backend from env vars — provider selection and endpoints live in
its config (`openclaw.json`, editable via the Control UI or `openclaw config set`). Env vars
such as `OLLAMA_HOST` / `*_BASE_URL` are **not** honored; see the authoritative list of what
OpenClaw does read from the environment: <https://docs.openclaw.ai/help/environment>.

**API provider (OpenAI, Anthropic, …).** OpenClaw reads provider API *keys* from its process
environment, so pass the key via `extraEnv` and configure the provider in OpenClaw:

```bash
--set extraEnv.OPENAI_API_KEY=sk-…
```

Then, in the Control UI (or `openclaw config set`), select the provider/model.

**Network-reachable backend (e.g. a co-located Ollama).** Two steps: (1) join the backend's
overlay so the gateway can reach it by service name, and (2) point OpenClaw at that address in
its **config** — the `baseUrl` cannot come from env:

```bash
# 1. give the gateway network reachability to the backend
--set backend.enabled=true \
--set backend.network=ai-internal
```

```bash
# 2. inside OpenClaw (Control UI, or exec into the gateway container), set the endpoint:
openclaw config set --batch-json \
  '{"models":{"providers":{"ollama":{"baseUrl":"http://ollama:11434","api":"ollama"}}}}'
```

(Setting only `OLLAMA_API_KEY` via `extraEnv` makes OpenClaw auto-discover from
`http://127.0.0.1:11434` — localhost *inside* the gateway container — which is not your
co-located Ollama; use the config `baseUrl` above.)

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ghcr.io/openclaw/openclaw` | Image repository |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Replica count (must stay 1 — node-local volumes) |
| `persistence.enabled` | `true` | Mount the named state volumes |
| `persistence.dataVolume` | `openclaw-data` | Named volume for `/home/node/.openclaw` (config, DB, workspace) |
| `persistence.authVolume` | `openclaw-auth` | Named volume for `/home/node/.config/openclaw` (OAuth keys) |
| `persistence.dataPath` | `""` | Host dir for `/home/node/.openclaw`; when set, bind-mounts it and takes precedence over `dataVolume` (needs the `host-mount` acknowledgment) |
| `persistence.authPath` | `""` | Host dir for `/home/node/.config/openclaw`; when set, bind-mounts it and takes precedence over `authVolume` |
| `persistence.nodeLabel` | `openclaw-data` | Node label the data pin renders from (`node.labels.<nodeLabel> == true`); dropped when persistence is off, `""` skips the pin |
| `auth.secretName` | `openclaw_gateway_token` | External Swarm secret holding the (always-required) gateway API token |
| `exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `exposure.network` | `traefik-public` | External ingress overlay (traefik & none modes) |
| `ingress.host` | `openclaw.example.com` | Public hostname (Traefik rule + default allowed origin) |
| `ingress.tls` | `true` | Public endpoint is HTTPS (proxied modes) |
| `traefik.certResolver` | `le` | Traefik ACME cert resolver |
| `traefik.routerName` | `""` | Base name for the Traefik router/service objects (`<name>-http`/`-https`); empty ⇒ release name |
| `traefik.constraintLabel` | `traefik-public` | Value of the `traefik.constraint-label` the swarm provider filters on (match your Traefik) |
| `traefik.redirectMiddleware` | `https-redirect` | Middleware on the HTTP router redirecting to HTTPS; the default is always defined by the [traefik chart](../traefik) |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names (the traefik chart's) |
| `publish.port` | `18789` | Published port (published mode) |
| `publish.mode` | `ingress` | `ingress` (routing mesh) or `host` (pinned node) |
| `service.port` | `18789` | Container HTTP port (Traefik LB / publish target) |
| `allowedOrigins` | `[]` | Control-UI allowed origins (`gateway.controlUi.allowedOrigins`, list) — required for non-loopback; empty ⇒ `["<scheme>://<host>"]` |
| `trustedProxies` | `[]` | Proxy IPs/CIDRs to trust for `X-Forwarded-*` (`gateway.trustedProxies`, proxied modes); e.g. `["10.0.1.0/24"]` |
| `gatewayBind` | `lan` | Gateway bind interface, passed as `--bind` (`lan` so the proxy can reach it) |
| `allowUnconfigured` | `true` | Launch with `--allow-unconfigured` so the gateway boots from empty state (auth still enforced); set `false` only if you pre-seed `openclaw.json` |
| `backend.enabled` | `false` | Join `backend.network` for a network-reachable backend |
| `backend.network` | `openclaw-backend` | External overlay to join when `backend.enabled` |
| `extraEnv` | `{}` | Extra env vars OpenClaw reads from its process environment (e.g. a provider API key); not a way to select/point at a backend — see [Wiring a model backend](#wiring-a-model-backend) |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin comes from `persistence.nodeLabel`) |
| `resources.limits.memory` | `""` | Swarm deploy memory limit (set `2G`) |
| `healthcheck.*` | see `values.yaml` | `node fetch()` `/healthz` healthcheck |
| `healthcheck.monitor` | `4m` | Rollout watch window. Must cover `startPeriod + interval x retries` (210s) — see below |
| `labels` | `{}` | Extra deploy labels |

## Requirements

External resources (declared in `requirements.yaml`, validated by swarmcli's pre-flight):

- **Network** `traefik-public` (traefik & none modes) — `autoCreate:false`, operator/traefik-provisioned.
- **Network** `backend.network` (only when `backend.enabled`) — `autoCreate:false`, provisioned by the backend's operator.
- **Secret** `openclaw_gateway_token` (always required) — operator-created, never chart-created.

## Security note

The gateway's launch wrapper reads the token from its mounted secret file into the
`OPENCLAW_GATEWAY_TOKEN` env at runtime (`export OPENCLAW_GATEWAY_TOKEN="$(cat
/run/secrets/openclaw_gateway_token)"`), so the token value never lands in the compose file
or `docker inspect` — only the `cat` of the secret path does. By default state
uses node-local named volumes (no host bind mounts), and the container runs as the image's
non-root `node` user; the chart adds no `docker.sock`, `privileged`, host network/PID or
`cap_add`. The only host-filesystem access is the **opt-in** `persistence.dataPath` /
`authPath` (bind-mounting operator-chosen host directories); it is off by default and
acknowledged via `annotations: { swarmcli-charts/allow: "host-mount" }` in `Chart.yaml`,
so the security scan flags it only when you configure a host path.

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. `swarmcli charts lint` warns when `monitor` is shorter
than `start_period + interval x retries`.

**Raise it if you raise the healthcheck values above**, or the lint will tell you.
