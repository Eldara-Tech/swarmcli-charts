# SwarmCLI Charts

Community charts for [SwarmCLI](https://github.com/eldara/swarmcli) — a k9s-inspired TUI for Docker Swarm.

## Available Charts

| Chart | Version | App Version | Description |
|-------|---------|-------------|-------------|
| [whoami](charts/whoami) | 0.1.0 | 1.10.3 | HTTP echo service for testing |

## Adding the Repository

```bash
swarmcli chart repo add swarmcli-charts https://eldara.github.io/swarmcli-charts
swarmcli chart repo update
```

You can add multiple repos and reference charts by repo prefix:

```bash
swarmcli chart install swarmcli-charts/whoami
```

## Usage

```bash
# Install a chart
swarmcli chart install whoami --set ingress.host=whoami.yourdomain.com

# Install with custom values
swarmcli chart install whoami -f my-values.yaml

# List available charts
swarmcli chart search
```

## Releasing a New Chart Version

1. Update `version:` in the chart's `Chart.yaml`
2. Commit and push to `main`
3. Tag the release:
   ```bash
   git tag whoami/v0.2.0
   git push origin whoami/v0.2.0
   ```
4. GitHub Actions packages the chart and creates a release automatically.

## Contributing

- Each chart lives under `charts/<name>/`
- Required files: `Chart.yaml`, `values.yaml`, `templates/stack.yaml.tmpl`, `README.md`
- Templates use Go `text/template` syntax with `.Values`, `.Chart`, and `.Release` context
