# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public GitHub issue.

Email **hello@eldara.io** with:

- a description of the issue and its impact,
- steps to reproduce (the affected chart, values, and rendered output if
  relevant),
- any suggested remediation.

We aim to acknowledge reports within a few business days and will keep you
updated on remediation progress.

## Scope

This repository ships chart *templates* that swarmcli renders into Docker Swarm
stacks. Relevant concerns include charts that introduce dangerous primitives
(Docker socket mounts, host bind-mounts, `privileged` containers, host
network/PID, added capabilities). Such primitives must be explicitly
acknowledged in a chart's `Chart.yaml` (`annotations: swarmcli-charts/allow:`)
and are surfaced by CI — see [CONTRIBUTING.md](CONTRIBUTING.md).

For vulnerabilities in the swarmcli renderer itself, report against the
[swarmcli](https://github.com/Eldara-Tech/swarmcli) repository.
