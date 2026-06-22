# SwarmCLI Charts

Community charts for [SwarmCLI](https://github.com/Eldara-Tech/swarmcli) — a k9s-inspired TUI for Docker Swarm.

## Available Charts

| Chart | Version | App Version | Description |
|-------|---------|-------------|-------------|
| [whoami](charts/whoami) | 0.1.5 | 1.10.3 | HTTP echo service for testing |

## Adding the Repository

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts repo update
```

You can add multiple repos and reference charts by repo prefix. `install` takes a
release name and a `<repo>/<chart>` reference:

```bash
swarmcli charts install whoami swarmcli-charts/whoami
```

## Usage

```bash
# Install a chart
swarmcli charts install whoami swarmcli-charts/whoami --set ingress.host=whoami.yourdomain.com

# Install with custom values
swarmcli charts install whoami swarmcli-charts/whoami -f my-values.yaml

# List available charts
swarmcli charts search
```

## Releasing a New Chart Version

The **git tag is the source of truth** for the version. To release, push a tag of
the form `<chart>/v<version>`:

```bash
git tag whoami/v0.2.0
git push origin whoami/v0.2.0
```

`release.yml` stamps that version into the chart's `Chart.yaml` at package time,
publishes a GitHub Release with the `.tgz`, and rebuilds the `index.yaml` on
GitHub Pages as the final step. The `version:` field committed in `Chart.yaml` is
only a placeholder — the tag wins.

The published chart version is plain SemVer (`0.2.0`); install it with
`--version 0.2.0` (the leading `v` belongs to the git tag, not the chart version).

## Contributing

- Each chart lives under `charts/<name>/`
- Required files: `Chart.yaml`, `values.yaml`, `templates/stack.yaml.tmpl`, `README.md`
- Templates use Go `text/template` syntax with `.Values`, `.Chart`, and `.Release` context

## One-Time Repo Setup (for maintainers)

The release workflow publishes `index.yaml` to GitHub Pages, so Pages needs to be enabled once:

1. Repo **Settings → Pages → Source** → set to **"GitHub Actions"** — the release workflow publishes the generated index via `actions/upload-pages-artifact` + `actions/deploy-pages`

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
