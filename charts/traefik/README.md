# traefik

TODO describe what this chart deploys.

## Installing

```bash
swarmcli charts install traefik swarmcli-charts/traefik
```

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `traefik` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` |
| `replicas` | `1` | Number of replicas |
| `labels` | `{}` | Extra deploy labels |
