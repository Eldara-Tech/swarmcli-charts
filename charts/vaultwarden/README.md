# vaultwarden

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) password manager on Docker Swarm.

This chart defaults to a **stateful SQLite deployment** (single replica, persisted at `/data`) and
can switch to **external PostgreSQL or MySQL/MariaDB** without exposing database passwords in
`values.yaml`.

## Prerequisites

1. Label the data node (for persisted mode):

	 ```bash
	 docker node update --label-add vaultwarden-data=true <node>
	 ```

	 On a single-node swarm, set `persistence.nodeLabel=""`.

2. If using external DB or optional auth features, pre-create the relevant secrets:

	 ```bash
	 printf 'S3cr3t' | docker secret create vaultwarden_postgres_password -
	 printf 'S3cr3t' | docker secret create vaultwarden_mysql_password -
	 # ADMIN_TOKEN should be an Argon2id PHC string, not plaintext. Generate one with the
	 # image this chart deploys — its tag is `appVersion` in Chart.yaml. Run interactively
	 # (it prompts for the password), then copy the resulting PHC string.
	 docker run --rm -it vaultwarden/server:<appVersion> /vaultwarden hash
	 # Single-quote it: a PHC string contains five `$` your shell would otherwise expand.
	 printf '%s' '<paste-argon2-phc-here>' | docker secret create vaultwarden_admin_token -
	 printf 'S3cr3t' | docker secret create vaultwarden_smtp_password -
	 ```

3. For `exposure.mode=traefik` (default), ensure your Traefik ingress overlay exists
	 (default `traefik-public`).

## Installing

Default (SQLite + Traefik):

```bash
swarmcli charts install vaultwarden swarmcli-charts/vaultwarden \
	--set ingress.host=vault.example.com
```

External PostgreSQL:

```bash
swarmcli charts install vaultwarden swarmcli-charts/vaultwarden \
	--set ingress.host=vault.example.com \
	--set database.type=postgres \
	--set database.postgres.host=postgres_postgres
```

Direct publish (no Traefik labels):

```bash
swarmcli charts install vaultwarden swarmcli-charts/vaultwarden \
	--set exposure.mode=published \
	--set publish.port=8080 \
	--set ingress.host=vault.example.com \
	--set ingress.tls=false
```

## Notes

- `database.type=sqlite` is the simplest path and keeps everything in `/data`.
- For `database.type=postgres` or `database.type=mysql`, `DATABASE_URL` is assembled at runtime from
	values plus password secret content.
- `auth.adminToken.enabled=true` reads `ADMIN_TOKEN` from an external secret.
- The `auth.adminToken.secretName` secret should hold an Argon2id PHC string. A plaintext
	token still works, but Vaultwarden logs `You are using a plain text ADMIN_TOKEN which is
	insecure` on every start. The chart reads the secret file at runtime, so the `$` in a PHC
	string never reaches the compose file — no `$$` escaping needed, unlike a hand-written stack.
- SMTP password can be secret-backed with `smtp.password.enabled=true`.
- `service.port` drives `ROCKET_PORT`, the Traefik loadbalancer port, the published target
	and the healthcheck together, so changing it moves all four.
- `DOMAIN` is what Vaultwarden uses for its WebAuthn/2FA origin and admin redirects. It is
	derived from `ingress.host` and `ingress.tls` (and, in `exposure.mode=published`, from a
	non-default `publish.port`); set `domain` explicitly to override.
- Vaultwarden has far more settings than this chart surfaces. `extraEnv` is merged **last**,
	so it can override any variable the chart sets — including `DOMAIN` or `SIGNUPS_ALLOWED`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `vaultwarden/server` | Container image |
| `image.tag` | `""` | Image tag, defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Vaultwarden replicas (stateful single replica) |
| `persistence.enabled` | `true` | Persist `/data` and enable node pin logic; `false` sets `I_REALLY_WANT_VOLATILE_STORAGE` and loses the vault on every task replacement |
| `persistence.volumeName` | `vaultwarden-data` | Named volume for `/data` |
| `persistence.volumePath` | `""` | Absolute host path for `/data` (takes precedence) |
| `persistence.nodeLabel` | `vaultwarden-data` | Node label used for persistent data pin |
| `exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `exposure.network` | `traefik-public` | External ingress overlay (traefik/none modes) |
| `ingress.host` | `vault.example.com` | Public hostname |
| `ingress.tls` | `true` | Public scheme used when deriving `DOMAIN` |
| `domain` | `""` | Explicit Vaultwarden `DOMAIN`; empty derives from ingress |
| `traefik.*` | see `values.yaml` | Traefik router/entrypoint/cert settings |
| `publish.port` / `.mode` | `8080` / `ingress` | Published host port and publish mode |
| `service.port` | `80` | Vaultwarden container port (also sets `ROCKET_PORT`) |
| `database.type` | `sqlite` | `sqlite` \| `postgres` \| `mysql` |
| `database.postgres.*` | see `values.yaml` | External PostgreSQL connection + secret + network |
| `database.mysql.*` | see `values.yaml` | External MySQL/MariaDB connection + secret + network |
| `auth.adminToken.enabled` | `false` | Read `ADMIN_TOKEN` from secret |
| `auth.adminToken.secretName` | `vaultwarden_admin_token` | External secret containing Argon2id PHC for `ADMIN_TOKEN` |
| `smtp.enabled` | `false` | Enable SMTP env configuration |
| `smtp.password.enabled` | `false` | Read SMTP password from secret |
| `smtp.password.secretName` | `vaultwarden_smtp_password` | External SMTP password secret |
| `app.websocketsEnabled` | `true` | `ENABLE_WEBSOCKET` |
| `app.signupsAllowed` | `false` | `SIGNUPS_ALLOWED` |
| `app.rocketWorkers` | `10` | `ROCKET_WORKERS` |
| `app.logLevel` | `info` | `LOG_LEVEL` |
| `extraEnv` | `{}` | Extra environment variables; merged last, overrides the above |
| `placement.constraints` | `[]` | Extra scheduler constraints |
| `resources.limits.memory` | `""` | Optional memory limit |
| `healthcheck.*` | see `values.yaml` | Runs the image's `/healthcheck.sh`; `monitor` is Swarm's rollout window |
| `labels` | `{}` | Extra deploy labels |
