# gitlab

[GitLab CE](https://about.gitlab.com) — self-hosted Git hosting and CI/CD — packaged as a
Docker Swarm stack. This chart runs the **omnibus all-in-one image**: PostgreSQL, Redis,
Gitaly, Puma, Sidekiq, nginx and sshd all in one container, on three node-local volumes,
pinned to a single node, fronted by Traefik with TLS at the edge. Git over SSH is routed
through a Traefik **TCP** entrypoint by default.

> **GitLab is big.** Its documented baseline is **8 vCPU / 16 GB RAM**; the image is several
> gigabytes and a cold boot takes many minutes. This is a single-replica, single-node
> deployment by design — every piece of GitLab's state lives on one volume set, so it cannot
> be scaled horizontally by raising `replicas` (the schema caps it at 1).

## Prerequisites

1. Label the node that will hold the volumes (Swarm volumes are node-local, so the service
   is pinned to exactly one node while `persistence.enabled`; the pin is dropped together
   with persistence, and `persistence.nodeLabel: ""` skips it, e.g. on a single-node swarm):

   ```bash
   docker node update --label-add gitlab-data=true <node>
   ```

2. An external ingress overlay named `traefik-public` (traefik & none modes, and any mode
   with `ssh.mode: traefik`), provisioned by the [traefik](../traefik) chart or your
   operator. It is `autoCreate:false` — swarmcli validates it exists and never creates it.

3. **For `ssh.mode: traefik` (the default): the Traefik release must define the SSH
   entrypoint and publish its port.** Traefik silently drops a router bound to an entrypoint
   it does not define, so without this git-over-SSH just never connects. Note `ports` is a
   *replacing* list — re-list 80 and 443:

   ```yaml
   ports:
     - { target: 80, published: 80, protocol: tcp, mode: host }
     - { target: 443, published: 443, protocol: tcp, mode: host }
     - { target: 2222, published: 2222, protocol: tcp, mode: host }
   traefik:
     extraEntrypoints:
       - name: gitlab-ssh
         address: ":2222"
   ```

   The entrypoint must be **dedicated** to GitLab: raw SSH carries no SNI, so the TCP router
   matches any SNI and the entrypoint alone selects it. See
   [traefik/README.md](../traefik/README.md#custom-entrypoints).

4. Optional secrets, pre-created by you (the chart validates them, never creates them):

   ```bash
   printf 'S3cr3tPassw0rd' | docker secret create gitlab_root_password -   # auth.rootPassword.enabled
   printf 'hunter2'        | docker secret create gitlab_smtp_password -   # smtp.enabled
   ```

## Installing

```bash
swarmcli charts install gitlab swarmcli-charts/gitlab \
  --set ingress.host=gitlab.example.com
```

**First boot takes a long time.** GitLab runs `gitlab-ctl reconfigure` on every container
start, and the first one initialises the database. The chart sets a 10-minute healthcheck
`start_period` for exactly this reason: the image's own healthcheck has none, so Swarm would
declare a cold-booting GitLab unhealthy after ~5 minutes and restart it forever.

With `auth.rootPassword.enabled: false` (the default), GitLab generates a root password into
`/etc/gitlab/initial_root_password` on the pinned node.

## How GitLab is configured

GitLab has no per-setting environment variables. The image's `/assets/gitlab.rb` ends with
`eval ENV["GITLAB_OMNIBUS_CONFIG"]`, so the chart renders the whole `gitlab.rb` into that one
variable, built from the values below plus `config.extraRb` appended last.

A chart **cannot** ship a `gitlab.rb` file: swarmcli refuses any `configs.<x>.file` path
outside the chart, and Swarm config data is immutable anyway. This is not a limitation to
work around — `GITLAB_OMNIBUS_CONFIG` is GitLab's own documented mechanism for it.

> **Do not put overrides in `/etc/gitlab/gitlab.rb`.** That file lives on the persisted
> `/etc/gitlab` volume and is read *after* `GITLAB_OMNIBUS_CONFIG`, so anything you uncomment
> there silently wins over the chart — including settings the chart needs for GitLab to boot
> behind a proxy at all. The image writes a fully-commented template there on first boot, so
> out of the box there is no conflict. Use chart values or `config.extraRb`.

What the chart always sets, and why:

| Setting | Why |
|---|---|
| `external_url` | From `ingress.host` + the exposure mode's scheme and port. Every clone URL, e-mail link and OAuth redirect is built from it. Without one the image derives it from the container hostname — a Swarm task ID. |
| `nginx['listen_port']`, `nginx['listen_https'] = false` | TLS terminates at the edge (or nowhere); GitLab's bundled nginx serves plain HTTP. The `https://` scheme in `external_url` is what makes GitLab set `X-Forwarded-Proto`/`-Ssl` and generate https links. |
| `letsencrypt['enable'] = false` | It defaults **on** whenever `external_url` is https with no certificate configured, and its ACME challenge cannot work behind a proxy that owns port 80. A failed challenge fails `gitlab-ctl reconfigure`, so the container never finishes starting. |
| `prometheus_monitoring['enable'] = false` | The bundled Prometheus and its exporters cost roughly a gigabyte of RAM. Re-enable from `config.extraRb`. |
| `gitlab_rails['gitlab_shell_ssh_port']` | The port GitLab *advertises* in clone URLs. It does not move sshd — that is pinned to 22 inside the image — so it is set to `ssh.port`, the port users actually type. |

### Extra configuration

`config.extraRb` is appended verbatim after everything above and can therefore override any
of it:

```yaml
config:
  extraRb: |
    gitlab_rails['time_zone'] = 'Europe/Zurich'
    gitlab_rails['gitlab_default_theme'] = 2
    nginx['real_ip_trusted_addresses'] = ['10.0.0.0/8']
```

**A literal `$` must be written `$$`.** This is rendered into the compose manifest, which
docker interpolates before deploying, so a single `$` would be eaten (or expanded into
something else). This matters for nginx variables:

```yaml
config:
  extraRb: |
    nginx['proxy_set_headers'] = { "X-Forwarded-For" => "$$proxy_add_x_forwarded_for" }
```

### Secrets

Passwords are never values in `values.yaml` and never reach the compose file: the chart
renders a `File.read('/run/secrets/…')` call into the Ruby config, and GitLab reads the
mounted secret itself at reconfigure time. `docker inspect` shows only the call. If a secret
is missing the read raises and reconfigure fails loudly rather than booting GitLab with an
empty password.

## Exposure

`exposure.mode` controls the HTTP interface and `ssh.mode` controls git-over-SSH; they are
independent, so a directly-published GitLab can still route SSH through Traefik, or the other
way round.

- **`traefik`** (default) — deploy labels only, discovered by the traefik chart's swarm
  provider. Requires `traefik.enable`, `traefik.constraint-label` and
  `traefik.swarm.network`, all of which the chart renders; the provider runs
  `exposedByDefault=false` plus a constraint on the label, so a service without them is
  never discovered (404 at the edge).
- **`published`** — a node port, no proxy. The port becomes part of `external_url`.
- **`none`** — no port and no labels, but still on `exposure.network` so some other proxy
  there can reach it.

For SSH the same three names mean: a Traefik TCP router on `ssh.entrypoint`, a published
node port, or not exposed at all (HTTP(S) clone still works either way). Note that the
Traefik TCP path hides the client's source IP from sshd — there is no PROXY-protocol support
on that side — so SSH audit logs show the ingress address.

The defaults target the in-repo [traefik](../traefik) chart: entrypoints `http`/`https` (not
Traefik's conventional `web`/`websecure`), `certResolver: le`, `constraintLabel:
traefik-public`, `redirectMiddleware: https-redirect`. Override them if you run your own
Traefik.

## Persistence and backups

| Volume | Mount | Holds |
|---|---|---|
| `persistence.configVolume` | `/etc/gitlab` | `gitlab-secrets.json`, the SSH **host keys**, `gitlab.rb` |
| `persistence.dataVolume` | `/var/opt/gitlab` | PostgreSQL, repositories, uploads, LFS, artifacts, backups |
| `persistence.logsVolume` | `/var/log/gitlab` | logs only — the one that is safe to lose |

**`/etc/gitlab` is the one you cannot lose.** `gitlab-secrets.json` holds the database
encryption key: without it, encrypted columns are unrecoverable even from a good backup, and
new SSH host keys are minted on every redeploy so every git client warns. Back it up
separately from the application backup.

Set `persistence.configPath` / `dataPath` / `logsPath` to bind-mount host directories
instead (they must already exist on the pinned node). This is host-filesystem access,
acknowledged via `swarmcli-charts/allow: "host-mount"` in `Chart.yaml`; the default
named-volume render is clean.

`persistence.enabled: false` drops the volumes *and* the node pin together — everything is
lost on every reschedule. Test only.

## `/dev/shm`

Puma and Sidekiq write Prometheus metrics files to `/dev/shm`; Docker's 64 MiB default is
too small and GitLab fails with `unmapped file`. The usual fix, `shm_size`, **cannot be used
in Swarm**: docker/cli lists it as unsupported and `docker stack deploy` drops it silently
(GitLab's own Swarm example has this bug). The chart mounts a sized tmpfs instead, in the one
form the swarm converter honours — long syntax with the size in bytes.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `gitlab/gitlab-ce` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Capped at 1: one volume set, one PostgreSQL |
| `exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `exposure.network` | `traefik-public` | External ingress overlay |
| `ingress.host` | `gitlab.example.com` | Public hostname; becomes `external_url`. Required. No underscores |
| `ingress.tls` | `true` | TLS at the edge (traefik/none modes) |
| `traefik.routerName` | `""` | Traefik object name prefix; defaults to the release name |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Entrypoints on the Traefik instance |
| `traefik.certResolver` | `le` | ACME resolver name |
| `traefik.constraintLabel` | `traefik-public` | Must match the Traefik provider constraint |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware, used only when `ingress.tls` |
| `publish.port` | `8080` | `exposure.mode: published` — node port; also part of `external_url` |
| `publish.mode` | `ingress` | `ingress` (routing mesh) or `host` (preserves client IP) |
| `service.port` | `80` | Container port GitLab's nginx listens on |
| `ssh.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `ssh.port` | `2222` | The port users type; advertised in clone URLs |
| `ssh.entrypoint` | `gitlab-ssh` | `ssh.mode: traefik` — dedicated Traefik entrypoint |
| `ssh.publishMode` | `ingress` | `ssh.mode: published` — `ingress` or `host` |
| `persistence.enabled` | `true` | Mount the three state volumes and pin the node |
| `persistence.configVolume` / `dataVolume` / `logsVolume` | `gitlab-config` / `-data` / `-logs` | Named volumes |
| `persistence.configPath` / `dataPath` / `logsPath` | `""` | Host paths; take precedence over the named volumes |
| `persistence.nodeLabel` | `gitlab-data` | Node label for the data pin; `""` to skip |
| `shm.enabled` | `true` | Mount a sized tmpfs at `/dev/shm` |
| `shm.sizeMb` | `256` | Its size; GitLab needs at least 256 |
| `auth.rootPassword.enabled` | `false` | Seed the initial root password from a secret |
| `auth.rootPassword.secretName` | `gitlab_root_password` | External Swarm secret holding it |
| `smtp.enabled` | `false` | Send mail over SMTP instead of the image's sendmail |
| `smtp.address` / `.port` | `""` / `587` | Relay host and port |
| `smtp.username` | `""` | SMTP user |
| `smtp.passwordSecretName` | `gitlab_smtp_password` | External secret; used unless `authentication: none` |
| `smtp.domain` | `""` | HELO domain |
| `smtp.authentication` | `login` | `login` \| `plain` \| `cram_md5` \| `none` |
| `smtp.tls` | `false` | Implicit TLS (usually port 465) |
| `smtp.starttlsAuto` | `true` | STARTTLS when the server offers it |
| `smtp.opensslVerifyMode` | `peer` | Certificate verification mode |
| `smtp.from` / `.displayName` / `.replyTo` | `""` | E-mail identity |
| `config.extraRb` | `""` | Extra omnibus Ruby, appended last (escape `$` as `$$`) |
| `extraEnv` | `{}` | Extra container environment variables |
| `placement.constraints` | `[]` | EXTRA constraints; the data pin is added automatically |
| `resources.limits.memory` / `.reservations.memory` | `""` | Unset by default — a limit below what GitLab needs OOM-kills it mid-reconfigure |
| `healthcheck.enabled` | `true` | Run the image's probe with a usable `start_period` |
| `healthcheck.interval` / `.timeout` / `.retries` | `60s` / `30s` / `5` | Probe timings |
| `healthcheck.startPeriod` | `10m` | Grace for a cold boot |
| `healthcheck.monitor` | `20m` | Swarm rollout watch window; keep ≥ `startPeriod + interval × retries` |
| `stopGracePeriod` | `5m` | GitLab runs `gitlab-ctl stop` on SIGTERM; 10s would SIGKILL PostgreSQL |
| `labels` | `{}` | Extra deploy labels |

## Not covered by this chart

The container registry, GitLab Pages, Mattermost, an external PostgreSQL/Redis, and
object-storage backups. Some are reachable through `config.extraRb`; the registry also needs
a second Traefik router and hostname, so it is a chart change rather than a values change —
open an issue if you need it.
