# traefik

Deploys [Traefik](https://traefik.io) v3 as the Docker Swarm edge proxy. Traefik
watches the Swarm API for routing labels on your services, terminates TLS with
Let's Encrypt (ACME), and serves a basic-auth-protected dashboard over HTTPS.
Other stacks expose themselves by attaching to the shared `traefik-public`
overlay and adding `traefik.*` deploy labels.

## Installing

The dashboard host and the ACME email are required:

```bash
swarmcli charts install traefik swarmcli-charts/traefik \
  --set traefik.dashboard.host=traefik.yourdomain.com \
  --set traefik.acme.email=admin@yourdomain.com \
  --set traefik.dashboard.basicAuthUsers='admin:$$apr1$$....'
```

Or with a values file:

```bash
swarmcli charts install traefik swarmcli-charts/traefik -f my-values.yaml
```

Generate the `basicAuthUsers` hash (note the `$$` escaping for compose labels):

```bash
export PASSWORD=changethis
echo $(openssl passwd -apr1 $PASSWORD) | sed 's/\$/\$\$/g'
```

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `traefik` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `ports` | `[80, 443]` (host mode) | Published ports (long-form Swarm bindings) |
| `ports[].mode` | `host` | `host` preserves the client source IP; `ingress` uses the routing mesh |
| `configs` | `[]` | Optional Swarm configs exposed to Traefik's file provider at `/config` |
| `deploy.placement.constraints` | cert-volume label | Pins Traefik to the node holding the ACME cert volume (see Requirements) |
| `traefik.network` | `traefik-public` | External overlay network Traefik publishes routes on |
| `traefik.constraintLabel` | `traefik-public` | Swarm provider constraint label |
| `traefik.certResolver` | `le` | Let's Encrypt (ACME) cert resolver name |
| `traefik.trustedIPs` | RFC1918 + loopback | Trusted proxy / LB CIDRs for forwarded-headers and proxy-protocol |
| `traefik.acme.email` | `""` | **Required** — Let's Encrypt account email |
| `traefik.hsts.enabled` | `true` | Define the HSTS middleware and apply it on the https entrypoint |
| `traefik.hsts.stsSeconds` | `31536000` | HSTS `max-age` |
| `traefik.hsts.includeSubdomains` | `true` | HSTS `includeSubDomains` |
| `traefik.hsts.preload` | `true` | HSTS `preload` |
| `traefik.hsts.forceSTSHeader` | `false` | Always send the STS header |
| `traefik.dashboard.enabled` | `true` | Serve the Traefik dashboard over HTTPS |
| `traefik.dashboard.host` | `""` | **Required when enabled** — dashboard FQDN |
| `traefik.dashboard.insecure` | `false` | Expose the insecure `:8080` API — keep `false` in production |
| `traefik.dashboard.basicAuthUsers` | `""` | htpasswd users; empty ⇒ no basic-auth middleware is attached |
| `traefik.apiPort` | `8080` | Internal Traefik API port the dashboard load-balances to |
| `traefik.bufferingMaxRequestBodyBytes` | `2000000` | Max buffered request body in bytes (0 disables) |
| `traefik.log.enabled` | `true` | Traefik log |
| `traefik.log.access` | `true` | Access log |
| `traefik.log.level` | `INFO` | Log level |
| `extraLabels` | `{}` | Extra deploy labels appended verbatim |
| `extraCommands` | `[]` | Extra Traefik CLI flags appended to the command block |

## Requirements

- **External `traefik-public` overlay network.** Declared in this chart's
  `requirements.yaml`; swarmcli auto-creates it as an attachable overlay on
  install if missing, and leaves it in place on uninstall (it is shared with the
  services Traefik routes to).
- **One labelled manager node for certificates.** Traefik's ACME account and
  issued certificates live in a single node-local volume
  (`traefik-public-certificates`). By default the chart pins Traefik with
  `node.labels.traefik-certs == true`, so that label must be set on **exactly one
  manager node**:

  ```bash
  docker node update --label-add traefik-certs=true <node>
  ```

- **Public DNS + reachable `:80`/`:443`.** ACME `tlschallenge` needs the
  dashboard host (and any routed host) to resolve to the node and ports 80/443 to
  be reachable from the internet.
- **Docker socket.** The chart mounts `/var/run/docker.sock` **read-only** so
  Traefik's swarm provider can discover routes (acknowledged in `Chart.yaml` via
  `swarmcli-charts/allow: "docker-socket"`).
