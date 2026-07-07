# whoami

A minimal HTTP echo service used to test and validate SwarmCLI chart delivery.
Responds to every request with the container's hostname, IP, and request headers.

## Installing

```bash
swarmcli charts install whoami swarmcli-charts/whoami --set ingress.host=whoami.yourdomain.com
```

Or with a custom values file:

```bash
swarmcli charts install whoami swarmcli-charts/whoami -f my-values.yaml
```

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ghcr.io/traefik/whoami` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `2` | Number of replicas |
| `service.port` | `80` | Container port |
| `ingress.enabled` | `true` | Enable Traefik ingress |
| `ingress.host` | `whoami.example.com` | Public hostname |
| `ingress.tls` | `true` | Enable TLS via Traefik (adds the HTTP→HTTPS redirect) |
| `ingress.certResolver` | `le` | Traefik cert resolver name |
| `traefik.network` | `traefik-public` | Overlay network shared with Traefik |
| `traefik.constraintLabel` | `traefik-public` | `traefik.constraint-label` value — required for discovery by a swarm provider running with constraints (the traefik chart does) |
| `traefik.redirectMiddleware` | `https-redirect` | Middleware on the HTTP router redirecting to HTTPS; the default is always defined by the traefik chart |
| `traefik.entrypoints.http` | `http` | HTTP entrypoint name |
| `traefik.entrypoints.https` | `https` | HTTPS entrypoint name |
| `labels` | `{}` | Extra deploy labels |

## Requirements

- Docker Swarm with an overlay network named `traefik-public` — swarmcli
  auto-creates it as an attachable overlay on install if it does not yet exist
  (declared in this chart's `requirements.yaml`), and reports it on uninstall
  rather than removing it (it is typically shared with Traefik and other stacks)
- Traefik v3 (swarm provider) running on the same network — the routing defaults
  (entrypoints `http`/`https`, constraint label `traefik-public`, cert resolver
  `le`, `https-redirect` middleware) match the [traefik chart](../traefik)
- With your own Traefik instead, override `traefik.*` and `ingress.certResolver`
  to match its configuration
