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

## Routing a service

The swarm provider runs with `exposedByDefault=false` **and** a constraint on
`traefik.constraint-label`, so a routed service must opt in with **both**
`traefik.enable=true` and the constraint label — without the latter Traefik does
not discover it at all. `traefik.swarm.network` tells the swarm provider which
overlay to reach the service on (important when the service sits on several
networks). A minimal HTTPS service with HTTP→HTTPS redirect:

```
traefik.enable=true
traefik.constraint-label=traefik-public          # match traefik.constraintLabel
traefik.swarm.network=traefik-public             # match traefik.network
traefik.http.routers.myapp-http.rule=Host(`myapp.example.com`)
traefik.http.routers.myapp-http.entrypoints=http
traefik.http.routers.myapp-http.middlewares=https-redirect
traefik.http.routers.myapp-https.rule=Host(`myapp.example.com`)
traefik.http.routers.myapp-https.entrypoints=https
traefik.http.routers.myapp-https.tls=true
traefik.http.routers.myapp-https.tls.certresolver=le
traefik.http.services.myapp.loadbalancer.server.port=8080
```

The `https-redirect` middleware is always defined by this chart (independent of
the dashboard), so routed services can rely on it. The entrypoints are named
`http` and `https`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `traefik` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `logging.driver` | `json-file` | Docker logging driver for the Traefik service (empty ⇒ daemon default) |
| `logging.options` | `{max-size: 10m, max-file: 3}` | Logging driver options (e.g. Loki URL/labels) |
| `ports` | `[80, 443]` (host mode) | Published ports (long-form Swarm bindings) |
| `ports[].mode` | `host` | `host` preserves the client source IP; `ingress` uses the routing mesh |
| `configs` | `[]` | Optional Swarm configs exposed to Traefik's file provider at `/config` |
| `deploy.placement.constraints` | cert-volume label | Pins Traefik to the node holding the ACME cert volume (see Requirements) |
| `persistence.volumeName` | `traefik-public-certificates` | Named volume for the ACME store (used when `volumePath` is empty) |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount the ACME store from instead; when set it wins over `volumeName` (see Requirements) |
| `traefik.network` | `traefik-public` | External overlay network Traefik publishes routes on |
| `traefik.constraintLabel` | `traefik-public` | Swarm provider constraint label |
| `traefik.extraEntrypoints` | `[]` | Extra entrypoints (`{name, address}`) beyond http/https; pair each with a `ports` entry |
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

## Logging

The Traefik service logs via Docker's logging driver. It defaults to `json-file`
with rotation; point it at another driver (e.g. Loki) by overriding `logging`:

```yaml
logging:
  driver: loki:latest
  options:
    loki-url: http://loki:3100/loki/api/v1/push
    loki-external-labels: "app=traefik"
```

Set `logging:` empty to drop the block and inherit the daemon's default driver.
(This is the Docker *container* log driver — separate from Traefik's own access
and application logs under `traefik.log.*`.)

## Custom entrypoints

To route a non-HTTP service (e.g. GitLab SSH on a custom port), add an entrypoint
and publish its port — both are needed:

```yaml
ports:
  - target: 80
    published: 80
    protocol: tcp
    mode: host
  - target: 443
    published: 443
    protocol: tcp
    mode: host
  - target: 2222          # publish the custom port
    published: 2222
    protocol: tcp
    mode: host
traefik:
  extraEntrypoints:
    - name: gitlab-ssh    # --entrypoints.gitlab-ssh.address=:2222
      address: ":2222"
```

The routed service itself supplies the matching router. For raw SSH that's a TCP
router on its own deploy labels, e.g.:

```
traefik.tcp.routers.gitlab-ssh.entrypoints=gitlab-ssh
traefik.tcp.routers.gitlab-ssh.rule=HostSNI(`*`)
traefik.tcp.services.gitlab-ssh.loadbalancer.server.port=22
```

## Requirements

- **External `traefik-public` overlay network.** Declared in this chart's
  `requirements.yaml`; swarmcli auto-creates it as an attachable overlay on
  install if missing, and leaves it in place on uninstall (it is shared with the
  services Traefik routes to).
- **One labelled manager node for certificates.** Traefik's ACME account and
  issued certificates live in a single node-local volume
  (`persistence.volumeName`, default `traefik-public-certificates`). By default
  the chart pins Traefik with `node.labels.traefik-certs == true`, so that label
  must be set on **exactly one manager node**:

  ```bash
  docker node update --label-add traefik-certs=true <node>
  ```

  To keep the store under a directory you choose instead (e.g. to back up
  `acme.json` directly), set `persistence.volumePath` to an absolute path — it
  takes precedence over `volumeName` and `/certificates` is **bind-mounted** from
  that path on the pinned node. The directory must already exist there; keep it
  private (`acme.json` holds the ACME account key and certificate private keys,
  Traefik enforces `0600` on the file). A bind mount is direct host-filesystem
  access, acknowledged via the chart's `swarmcli-charts/allow` annotation. (A
  host path in `volumeName` is rejected at render time — that field is a Docker
  named-volume name and cannot contain `/`.)

- **Public DNS + reachable `:80`/`:443`.** ACME `tlschallenge` needs the
  dashboard host (and any routed host) to resolve to the node and ports 80/443 to
  be reachable from the internet.
- **Docker socket.** The chart mounts `/var/run/docker.sock` **read-only** so
  Traefik's swarm provider can discover routes (acknowledged in `Chart.yaml` via
  `swarmcli-charts/allow: "docker-socket"`).
