# ollama

[Ollama](https://ollama.com) self-hosted LLM server for Docker Swarm. Runs models
**offline** on your own node — prompts and data never leave the box. Serves the Ollama HTTP
API on port **11434** and stores pulled models under `/root/.ollama` on a node-local Swarm
volume, so it is a **single-replica, node-pinned** service. GPU acceleration is opt-in.

## Installing

```bash
# Default: publish the API on the swarm at :11434 (plain HTTP — see Exposure).
swarmcli charts install ollama swarmcli-charts/ollama
```

Pull a model once it is running (data persists in the volume):

```bash
# by service task, on any swarm node:
docker exec $(docker ps -q -f name=ollama_ollama) ollama pull llama3
```

## Persistence & node pinning

Models live on the node-local named volume `ollama-data` at `/root/.ollama`. Because a Swarm
volume is node-local, the service is pinned to the node holding the data via a label —
label exactly **one** node before installing:

```bash
docker node update --label-add ollama-data=true <node>
```

Set `persistence.nodeLabel: ""` to skip the pin (e.g. a single-node swarm), or
`persistence.enabled: false` for an ephemeral instance (models re-pull on restart). To store
models under a host directory instead of a Docker volume, set an absolute
`persistence.volumePath` (bind mount; acknowledged as `host-mount` in `Chart.yaml`).

## Exposure

Ollama has **no built-in authentication**. Choose how it is reached with `exposure.mode`:

- **`published`** (default) — publishes `publish.port` (11434) directly on the swarm. Reach it
  at `http://<node>:11434`. Only do this on a trusted network.
- **`traefik`** — Traefik deploy labels on `exposure.network`, TLS at the edge, routed for
  `ingress.host`. The `traefik.*` defaults match the [traefik](../traefik) chart in this repo
  (entrypoints `http`/`https`, cert resolver `le`, constraint label `traefik-public`, redirect
  middleware `https-redirect`); override them for your own Traefik. Add a Traefik auth
  middleware if it faces anything untrusted.
- **`none`** — no port, no labels; the service sits on `exposure.network` so your own reverse
  proxy or other stacks reach it as `ollama:11434` (e.g. an [openclaw](../openclaw) gateway
  pointed at `http://ollama:11434`).

`traefik` and `none` attach the service to the external overlay `exposure.network`
(`traefik-public` by default), declared in `requirements.yaml` with `autoCreate: false` —
provision it with the traefik chart / your operator. `published` mode needs no external
network.

## GPU (NVIDIA)

Set `gpu.enabled: true` to request a GPU. In Docker **Swarm** a GPU is scheduled as a
**generic resource**, not via `--gpus` / `deploy.resources.reservations.devices` — that
Compose form validates but is a **silent no-op under `docker stack deploy`** (Ollama would
quietly fall back to CPU). This chart renders the Swarm-native form:

```yaml
resources:
  reservations:
    generic_resources:
      - discrete_resource_spec:
          kind: NVIDIA-GPU     # gpu.kind — must match the node advertisement below
          value: 1             # gpu.count
```

The swarm node must **advertise** the GPU first, or the task stays `Pending`:

1. Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
   and make `nvidia` the default runtime.
2. Advertise the GPU to the daemon in `/etc/docker/daemon.json`, then restart Docker:
   ```json
   { "node-generic-resources": ["NVIDIA-GPU=GPU-<uuid>"] }
   ```
   (`<uuid>` from `nvidia-smi -a | grep UUID`.) The `kind` before `=` must equal `gpu.kind`.
3. Pin the service to that node (`persistence.nodeLabel`) so it schedules where the GPU is.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ollama/ollama` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` (`0.30.11`) |
| `replicas` | `1` | Pinned to 1 (stateful, node-local volume) |
| `persistence.enabled` | `true` | Persist models to a named volume |
| `persistence.volumeName` | `ollama-data` | Named volume mounted at `/root/.ollama` |
| `persistence.volumePath` | `""` | Absolute host path — bind-mount instead of the named volume |
| `persistence.nodeLabel` | `ollama-data` | Node label the service is pinned to (`""` = no pin) |
| `exposure.mode` | `published` | `published` \| `traefik` \| `none` |
| `exposure.network` | `traefik-public` | External ingress overlay (traefik & none modes) |
| `ingress.host` | `ollama.example.com` | Host for the Traefik router (proxied modes) |
| `ingress.tls` | `true` | Terminate TLS at the edge (traefik mode) |
| `traefik.certResolver` | `le` | Traefik cert resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider discovery constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware (when `ingress.tls`) |
| `traefik.routerName` | `""` | Router/service object base name (`""` = release name) |
| `publish.port` | `11434` | Host port in `published` mode |
| `publish.mode` | `ingress` | `ingress` (routing mesh) or `host` (pinned node) |
| `service.port` | `11434` | Container API port (LB / publish / dial target) |
| `placement.constraints` | `[]` | Extra scheduling constraints |
| `resources.limits.memory` | `""` | Optional memory limit, e.g. `"8G"` |
| `gpu.enabled` | `false` | Reserve a GPU via Swarm generic resources |
| `gpu.kind` | `NVIDIA-GPU` | Generic-resource kind (matches the node advertisement) |
| `gpu.count` | `1` | Number of GPUs to reserve |
| `extraEnv` | `{}` | Extra env vars, e.g. `OLLAMA_KEEP_ALIVE` (`OLLAMA_HOST` is bound to `0.0.0.0:<service.port>` automatically; override here) |
| `healthcheck.enabled` | `true` | `ollama list` liveness probe |
| `labels` | `{}` | Extra deploy labels |
