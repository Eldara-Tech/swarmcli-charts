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

Bump the `version:` field in the chart's `Chart.yaml` and merge to `main` — that's it.

```yaml
# charts/whoami/Chart.yaml
version: 0.2.0  # ← bump this
```

On merge, `auto-tag.yml` detects the change, creates the `whoami/v0.2.0` tag automatically, which triggers `release.yml` to package the chart and publish a GitHub Release. The `index.yaml` on GitHub Pages is updated as the final step.

If the same version is already tagged (e.g. you merged an unrelated change), the auto-tag step skips silently — no duplicate releases.

## Contributing

- Each chart lives under `charts/<name>/`
- Required files: `Chart.yaml`, `values.yaml`, `templates/stack.yaml.tmpl`, `README.md`
- Templates use Go `text/template` syntax with `.Values`, `.Chart`, and `.Release` context

## One-Time Repo Setup (for maintainers)

The release workflow publishes `index.yaml` to GitHub Pages, so Pages needs to be enabled once:

1. Repo **Settings → Pages → Source** → set to **"Deploy from a branch"**, branch: `gh-pages`, folder: `/ (root)`

That's it — `contents: write` is scoped only to the job that creates the GitHub Release (required by `softprops/action-gh-release`), and the index-publishing job only needs `pages: write` + `id-token: write`, which are job-level permissions the workflow requests itself and don't depend on the repo/org-wide "Workflow permissions" toggle. If that toggle is greyed out or locked by an org policy, this setup still works.

After the first successful release, the index will be live at:
   ```
   https://<org>.github.io/swarmcli-charts/index.yaml
   ```

### How the index is built

`scripts/generate-index.sh` rebuilds `index.yaml` from scratch on every chart release:
- Lists all GitHub Releases tagged `<chart>/v<version>`
- Reads each chart's `Chart.yaml` as it existed at that tag (via `git show <tag>:path`) for metadata
- Downloads each release's `.sha256` file to embed the digest
- Outputs a Helm-style `index.yaml` with download URLs pointing at the release assets

The generated `index.yaml` is published straight to GitHub Pages (not committed back to `main`), so no repo-write permission is needed beyond what release creation already requires.

Run it locally to debug:
```bash
gh auth login
./scripts/generate-index.sh eldara-tech/swarmcli-charts > index.yaml
```
