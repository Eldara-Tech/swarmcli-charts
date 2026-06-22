# SwarmCLI Charts

Community charts for [SwarmCLI](https://github.com/Eldara-Tech/swarmcli) — a k9s-inspired TUI for Docker Swarm.

## Available Charts

| Chart | Version | App Version | Description |
|-------|---------|-------------|-------------|
| [whoami](charts/whoami) | 0.1.0 | 1.10.3 | HTTP echo service for testing |

## Adding the Repository

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts repo update
```

You can add multiple repos and reference charts by repo prefix:

```bash
swarmcli charts install swarmcli-charts/whoami
```

## Usage

```bash
# Install a chart
swarmcli charts install whoami --set ingress.host=whoami.yourdomain.com

# Install with custom values
swarmcli charts install whoami -f my-values.yaml

# List available charts
swarmcli charts search
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

## One-Time Repo Setup (for maintainers)

The release workflow publishes `index.yaml` to GitHub Pages, so Pages needs to be enabled once:

1. Repo **Settings → Pages → Source** → set to **"GitHub Actions"**
2. Repo **Settings → Actions → General → Workflow permissions** → set to **"Read and write permissions"**
   (needed so the workflow can commit the `index.yaml` backup and push)
3. After the first successful release, the index will be live at:
   ```
   https://<org>.github.io/swarmcli-charts/index.yaml
   ```

### How the index is built

`scripts/generate-index.sh` rebuilds `index.yaml` from scratch on every chart release:
- Lists all GitHub Releases tagged `<chart>/v<version>`
- Reads each chart's `Chart.yaml` as it existed at that tag (via `git show <tag>:path`) for metadata
- Downloads each release's `.sha256` file to embed the digest
- Outputs a Helm-style `index.yaml` with download URLs pointing at the release assets

Run it locally to debug:
```bash
gh auth login
./scripts/generate-index.sh eldara-tech/swarmcli-charts > index.yaml
```
