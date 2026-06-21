# whoami

A minimal HTTP echo service used to test and validate SwarmCLI chart delivery.
Responds to every request with the container's hostname, IP, and request headers.

## Installing

```bash
swarmcli chart install whoami --set ingress.host=whoami.yourdomain.com
```

Or with a custom values file:

```bash
swarmcli chart install whoami -f my-values.yaml
```

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `traefik/whoami` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `2` | Number of replicas |
| `service.port` | `80` | Container port |
| `ingress.enabled` | `true` | Enable Traefik ingress |
| `ingress.host` | `whoami.example.com` | Public hostname |
| `ingress.tls` | `true` | Enable TLS via Traefik |
| `ingress.certResolver` | `letsencrypt` | Traefik cert resolver name |
| `traefik.network` | `traefik-public` | Overlay network shared with Traefik |
| `traefik.entrypoints.http` | `web` | HTTP entrypoint name |
| `traefik.entrypoints.https` | `websecure` | HTTPS entrypoint name |
| `labels` | `{}` | Extra deploy labels |

## Requirements

- Docker Swarm with an overlay network named `traefik-public`
- Traefik v2/v3 running on the same network
- A cert resolver named `letsencrypt` configured in Traefik (or override via `ingress.certResolver`)
