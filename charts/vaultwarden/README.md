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
	 printf '%s' '<client secret>' | docker secret create vaultwarden_sso_client_secret -   # sso.enabled
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

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret, config, volume and network the release
references, whatever its name. A default install needs:

```yaml
- name: vaultwarden       # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    networks: [traefik-public]
```

`database.type: postgres` adds `vaultwarden_postgres_password` and `postgres-net`,
`database.type: mysql` adds `vaultwarden_mysql_password` and `mariadb-net`,
`auth.adminToken.enabled` adds `vaultwarden_admin_token`, `smtp.password.enabled` adds
`vaultwarden_smtp_password`, and `sso.enabled` adds `vaultwarden_sso_client_secret`. Each
entry is the name itself, so an override in values needs the same change here. See
[`allow`](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md#allow-optional) in the swarmcli-cd docs.

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

## Single sign-on

`sso.enabled` lets users log in through an OpenID Connect provider such as Keycloak or
Authentik:

```bash
swarmcli charts install vaultwarden swarmcli-charts/vaultwarden \
	--set ingress.host=vault.example.com \
	--set sso.enabled=true \
	--set sso.authority=https://keycloak.example.com/realms/main \
	--set sso.clientId=vaultwarden
```

- Register a **confidential** client with the provider, whose redirect URI is
	`<DOMAIN>/identity/connect/oidc-signin` — `https://vault.example.com/identity/connect/oidc-signin`
	above. Vaultwarden refuses to start with SSO on and no client secret, so a public client
	cannot be used.
- `sso.authority` is the issuer URL without `/.well-known/openid-configuration`, and must equal
	the `issuer` of the provider's discovery document exactly, trailing slash included.
	Vaultwarden contacts the provider at the first login, not at start, so an unreachable or
	mismatched one shows up as a failed login rather than a task that does not converge; only
	a value that is not a URL at all stops it from starting.
- The client secret is read by Vaultwarden itself from the mounted secret, through
	`SSO_CLIENT_SECRET_FILE`, so it never reaches the compose file or `docker inspect`. An
	`SSO_CLIENT_SECRET` in `extraEnv` is refused beside `sso.enabled`, since Vaultwarden
	refuses to start with both.
- SSO replaces the login step only. Every user still sets and enters a **master password**,
	which is what decrypts the vault; the provider never sees it.
- `sso.only: true` refuses email + master password logins entirely.
- Accounts created by a first SSO login follow `sso.signupsAllowed`, **not**
	`app.signupsAllowed`, which governs only the sign-up form. A `SIGNUPS_DOMAINS_WHITELIST` in
	`extraEnv` overrides both. With the default `sso.signupsAllowed: true`, anyone the provider
	authenticates gets an account, so restrict the client at the provider, or turn it off and
	invite users — which Vaultwarden itself advises with a public provider such as Google or
	gitlab.com. `sso.signupsMatchEmail` attaches a first SSO login to an existing account with
	the same email.
- Settings saved in the admin panel are written to `/data/config.json` and **override** the
	environment the chart sets, the SSO settings included — and the panel stores the client
	secret there in plaintext, and shows it to anyone holding the admin token. Leave the SSO
	settings to the chart.
- Keycloak: raise the client's access token lifespan to at least 10 minutes (the 5-minute
	default collides with the web vault's own expiry check), and add `offline_access` to
	`sso.scopes` (`"email profile offline_access"`) so it issues refresh tokens; without them a
	session lasts only as long as the access token.
- Vaultwarden's further SSO settings (`SSO_AUDIENCE_TRUSTED`, `SSO_MASTER_PASSWORD_POLICY`,
	`SSO_AUTH_ONLY_NOT_SESSION`, …) go in `extraEnv`. See the
	[Vaultwarden SSO wiki](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-SSO-support-using-OpenId-Connect).

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
| `sso.enabled` | `false` | OpenID Connect single sign-on. See *Single sign-on* |
| `sso.authority` | `""` | Provider issuer URL; required with `sso.enabled` |
| `sso.clientId` | `""` | Client ID; required with `sso.enabled` |
| `sso.clientSecretSecretName` | `vaultwarden_sso_client_secret` | External secret holding the client secret (`SSO_CLIENT_SECRET_FILE`) |
| `sso.only` | `false` | `SSO_ONLY` — refuse email + master password logins |
| `sso.signupsAllowed` | `true` | `SSO_SIGNUPS_ALLOWED` — a first SSO login may create an account |
| `sso.signupsMatchEmail` | `true` | `SSO_SIGNUPS_MATCH_EMAIL` — associate it with an existing account of the same email |
| `sso.scopes` | `""` | `SSO_SCOPES`, besides the implicit `openid`; empty keeps Vaultwarden's default |
| `sso.pkce` | `true` | `SSO_PKCE` |
| `app.websocketsEnabled` | `true` | `ENABLE_WEBSOCKET` |
| `app.signupsAllowed` | `false` | `SIGNUPS_ALLOWED` |
| `app.rocketWorkers` | `10` | `ROCKET_WORKERS` |
| `app.logLevel` | `info` | `LOG_LEVEL` |
| `extraEnv` | `{}` | Extra environment variables; merged last, overrides the above |
| `placement.constraints` | `[]` | Extra scheduler constraints |
| `resources.limits.memory` | `""` | Optional memory limit |
| `healthcheck.*` | see `values.yaml` | Runs the image's `/healthcheck.sh`; `monitor` is Swarm's rollout window |
| `labels` | `{}` | Extra deploy labels |
