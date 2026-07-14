<!-- Thanks for contributing a SwarmCLI chart! See CONTRIBUTING.md. -->

## What does this PR do?

<!-- Brief summary. New chart? Update to an existing one? -->

## Checklist

- [ ] `make test` passes locally (lints, renders + validates all affected charts)
- [ ] Chart has the required files (`Chart.yaml`, `values.yaml`,
      `templates/stack.yaml.tmpl`, `README.md`) and at least one
      `ci/*-values.yaml` fixture
- [ ] The README values table matches `values.yaml`
- [ ] `Chart.yaml` has a `# renovate: image=<repo>` comment directly above
      `appVersion`, naming the same image as `values.yaml` `image.repository`
- [ ] No `:latest` image, and the appVersion is **not** repeated in a `values.yaml`
      comment or in the README values table (Renovate edits `Chart.yaml` only, so
      those numbers drift)
- [ ] If the stack uses a risky primitive (Docker socket, host mount,
      `privileged`, host network/PID, `cap_add`), it is acknowledged via
      `annotations: swarmcli-charts/allow:` in `Chart.yaml`
- [ ] No `<no value>` in the rendered output (missing-key typos)
