# seaweedfs

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) as an **S3-compatible object
store** for Docker Swarm. One service runs `weed server -s3` — master, volume
server, filer and S3 gateway in a single process — with all of its data on one
node-local volume. It fits a build cache (the GitLab Runner distributed cache),
a backup target or an application's blob store on a small swarm; it is not a
distributed SeaweedFS cluster.

What the chart adds on top of the image:

- **Authentication is always on.** The S3 key pair comes from two external Swarm
  secrets, and the container refuses to start if either is missing or empty —
  SeaweedFS serves every request anonymously when it knows no identity.
- **Only S3 leaves the container.** The master, volume and filer APIs have no
  authentication, so they listen on 127.0.0.1 only. The web UI is the
  password-protected `weed admin`, opt-in (see [Web UI](#web-ui)).
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.
- **Optional OIDC sign-in** (`oidc`): tokens from your identity provider, scoped by
  group to buckets and read or read/write access.

## Prerequisites

```bash
# The S3 credentials, as external Swarm secrets (never chart values). Any key id works;
# make the secret key long and random.
printf '%s' 'cache-access-key' | docker secret create seaweedfs-s3-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create seaweedfs-s3-secret-key -

# The node that holds the data. Skip on a single-node swarm and set
# persistence.nodeLabel="" instead.
docker node update --label-add seaweedfs-data=true <node>
```

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.
swarmcli v2.2.0-rc2 and later add it on a first run, while there is no repository
list yet; v2.1.1, and an existing list, are left as they are.

```bash
swarmcli charts install s3 swarmcli-charts/seaweedfs --set 'buckets={runner-cache}'
```

By default (`exposure.mode: none`) the store is reachable only on the
`seaweedfs-net` overlay, which swarmcli creates if it is missing. Another stack
joins that network as `external: true` and uses the endpoint
`http://<release>_seaweedfs:8333` (`http://s3_seaweedfs:8333` above).

Clients use **path-style** addressing (`http://<endpoint>/<bucket>/<key>`), the
default for every non-AWS S3 client. The region is not checked; send any, e.g.
`us-east-1`.

## Exposure

`exposure`, `ingress` and `publish` expose the **S3 API**; the web UI has its own
`admin.exposure` (see [Web UI](#web-ui)). `network.name` is attached in every
mode. `exposure.mode` adds:

| Mode | What it adds |
|------|--------------|
| `none` (default) | no route or port of its own — overlay clients only; on `exposure.network` too while the admin UI is traefik-routed, as the service then joins it |
| `traefik` | Traefik labels on `exposure.network`, routing `ingress.host` to the S3 port, with an HTTPS router and ACME certificate when `ingress.tls` |
| `published` | `s3.port` published on the Swarm as `publish.port` |

```bash
swarmcli charts install s3 swarmcli-charts/seaweedfs \
  --set exposure.mode=traefik --set ingress.host=s3-cache.example.com \
  --set 'buckets={runner-cache}'
```

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`,
redirect middleware `https-redirect`); override them for your own Traefik. The
whole bucket namespace is served at the root of `ingress.host`, which is what
path-style requires — do not put a path prefix in front of it.

Traefik's entrypoints time out slow requests (v3's default `readTimeout` is 60s).
A multi-gigabyte cache archive over a slow link can exceed that; raise it on the
edge if uploads fail part-way.

### GitLab Runner cache

The runner's job helper containers upload and download the cache archive
themselves, and they run on the node's own Docker engine — not on any overlay. So
the runner needs an endpoint reachable from a plain container on each runner
node: the Traefik host (or a published port), not `<release>_seaweedfs`. With the
[gitlab-runner chart](../gitlab-runner):

```yaml
cache:
  enabled: true
  s3:
    server: s3-cache.example.com     # ingress.host
    bucket: runner-cache             # listed in this chart's buckets
    addressing: path
    accessKeySecret: seaweedfs-s3-access-key
    secretKeySecret: seaweedfs-s3-secret-key
```

## Web UI

The UI is SeaweedFS's `weed admin`, off by default. With `admin.enabled` the
container starts it beside the server once the master answers, and restarts it
if it exits; S3 and its healthcheck never depend on it. Its settings live in
`/data/admin`; its session key there is deleted at every container start, so a
redeploy logs everyone out. The password, read from the secret, is kept out of
weed server's environment, every argv, the manifest and `docker inspect`. That
is no boundary inside the container: Swarm mounts the secret world-readable
(0444), and any process running as `seaweed` — weed server included — can read
it, or weed admin's environment.

```bash
# The password, as an external Swarm secret. Swarm never shows a secret again, so
# keep the password you put in.
printf '%s' '<password>' | docker secret create seaweedfs-admin-password -

swarmcli charts install s3 swarmcli-charts/seaweedfs \
  --set admin.enabled=true --set admin.exposure.mode=traefik \
  --set admin.ingress.host=seaweedfs-admin.example.com
```

Log in as `admin.user` (`admin`) with that password. `admin.exposure.mode` is
`none` (only `network.name`), `traefik` (routes `admin.ingress.host`, which must
differ from `ingress.host`) or `published` (`admin.port` as `admin.publish.port`,
plain HTTP). The S3 API keeps its own `exposure.mode`.

**Why not port 9333?** The master's status page shares one unauthenticated
listener with the master's admin endpoints: in testing, an anonymous
`GET /col/delete` deleted a bucket's data, and the page cannot be split off that
listener. The master, volume server (8080) and filer (8888) also share one bind
address, so opening 9333 opens the filer too — where an anonymous read of
`/etc/iam/identities/*.json` returned the S3 secret keys — and every gRPC port.
They stay on 127.0.0.1.

**One password is full control.** The admin user manages S3 users and their
keys, buckets, every file in them, and maintenance — treat the password like the
S3 secret key.

- **No login rate limit.** `weed admin` does not throttle password guesses. Put
  a Traefik middleware in front of the `<router>-admin-https` router
  (`<router>-admin-http` with `admin.ingress.tls: false`; `<router>` is
  `traefik.routerName`, or the release name) through `labels` — an
  `ipallowlist`, or forward-auth such as oauth2-proxy for single sign-on:

  ```yaml
  labels:
    traefik.http.middlewares.s3-admin-allow.ipallowlist.sourcerange: "192.0.2.0/24"
    traefik.http.routers.s3-admin-https.middlewares: s3-admin-allow
    # The stored-file routes ride a router of their own (below); keep its sandbox last.
    traefik.http.routers.s3-admin-content-https.middlewares: s3-admin-allow,s3-admin-sandbox
  ```

- **Cross-site requests: upstream gaps the edge only narrows.** `weed admin`
  checks a CSRF token on only a few of its writes, reads JSON whatever its
  `Content-Type`, and serves some uploaded files inline in its own origin; its
  session cookie is `SameSite=Lax`, which a browser still sends from another host
  of the same site (`s3.example.com` → `admin.example.com`). These are SeaweedFS
  bugs the chart cannot fix. In traefik mode it narrows them at the edge:
  - the admin routers refuse every method but GET and HEAD when the browser
    marks the request `Sec-Fetch-Site: same-site` or `cross-site` (current
    browsers send the header; a client that sends none, such as curl, passes);
  - the routes that return stored files or their metadata
    (`/api/files/download`, `/api/files/view`, `/api/files/metadata`) ride a
    router of their own, `<router>-admin-content-https`, whose responses carry
    `Content-Security-Policy: sandbox` and `X-Content-Type-Options: nosniff`
    (the `<router>-admin-sandbox` middleware), so a stored file opened in the
    browser runs no script in the UI's origin. An inline PDF preview may not
    render under the sandbox; download the file instead;
  - every admin router refuses a path with an encoded slash (`%2F`): Traefik
    matches the path still encoded and `weed admin` decodes it, so
    `/api%2Ffiles%2Fdownload` would otherwise reach the download handler without
    the sandbox. The UI passes file paths in the query string, never the path.

  **`published` mode has neither guard: any S3 user who can get an admin to open
  a link can take over the UI.** Publish it only on a trusted network.
- **The session cookie is not marked `Secure`** (`weed admin` sets that only when
  it terminates TLS itself), so a browser sends it in cleartext with any
  `http://` request to the host — the HTTP→HTTPS redirect answers that request,
  it does not stop it. HSTS does, from the browser's first HTTPS visit on: the
  [traefik chart](../traefik) sends it by default (`traefik.hsts`); a Traefik of
  your own may not. Keep `published` mode
  to trusted networks.
- **`/metrics` needs no login**, so the router excludes it
  (``!PathPrefix(`/metrics`)``); it still answers on the overlays.
- **OIDC login for the UI is SeaweedFS Enterprise only.** [`oidc`](#oidc) covers
  the S3 API alone. For SSO use the forward-auth middleware above.
- **The overlays bypass the router.** Anything on `network.name` — and on
  `exposure.network` whenever either API is traefik-routed, even with the UI's
  own mode `none` — reaches the UI directly on `admin.port`: past the routers'
  middlewares, their `/metrics`, cross-site and sandbox rules, and with no rate
  limit. The
  UI's worker gRPC port (`admin.port + 10000`) has no authentication and stays
  on 127.0.0.1.

To change the password, create a new secret under a new name, point
`admin.passwordSecret` at it and upgrade. The new task deletes the session key,
so every session ends with the redeploy, those opened with the old password
included; `docker service update --force <release>_seaweedfs` does the same. A
crash of the UI alone keeps its sessions.

## Security

- **Credentials.** The wrapper reads both secrets from `/run/secrets` and exports
  them as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, which SeaweedFS turns into
  its single admin identity; from then on every request must carry a valid SigV4
  signature. Neither value appears in the manifest or in `docker inspect`. To rotate,
  create new secrets under new names, point `s3.accessKeySecret` /
  `s3.secretKeySecret` at them and upgrade.
- **Internal APIs.** The master (9333), volume (8080) and filer (8888) HTTP and
  gRPC APIs bypass S3 authentication entirely, so they are bound to 127.0.0.1.
  `extraArgs` must not rebind `-ip` or `-ip.bind`.
- **The S3 gRPC port** (`s3.port + 10000`, 18333 by default) shares the S3
  gateway's address and accepts identity updates. The chart sets a fresh random
  filer signing key at every start, which makes that port refuse unsigned updates
  — without it, anything on the same overlay could add itself as an admin.
- Everything on `network.name`, and everything on `exposure.network` whenever
  the S3 API or the admin UI is traefik-routed, can reach the S3 port. That is
  the intent; the key pair is what protects the data.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a
background loop in the container, once the gateway answers. `409` (already
exists) counts as done, so restarts and upgrades are harmless; a bucket that
cannot be created after five minutes is logged (`docker service logs`) and the
server keeps running. Removing a name from `buckets` does not delete the bucket.

## OIDC

`oidc.enabled` lets people and jobs use their identity provider's token instead of the
key pair, which keeps working unchanged. A client sends the token as a Bearer header, or
exchanges it for temporary S3 keys with STS on the same port:

```bash
curl -H "Authorization: Bearer $TOKEN" https://s3-cache.example.com/runner-cache/some/key
aws sts assume-role-with-web-identity --endpoint-url https://s3-cache.example.com \
  --role-arn arn:aws:iam::role/oidc --role-session-name "$USER" --web-identity-token "$TOKEN"
```

Access comes only from `oidc.grants`:

```yaml
oidc:
  enabled: true
  issuer: https://sso.example.com/realms/infra
  clientId: seaweedfs-s3
  grants:
    - { group: ci-cache, access: readwrite, buckets: [runner-cache] }
    - { group: auditors, access: readonly, buckets: [] }   # [] = every bucket
```

A token is accepted when its `iss` equals `oidc.issuer`, its `aud` or `azp` equals
`oidc.clientId`, and its `groups` claim names a granted group. It then gets every grant of
every granted group it is in. A token in no granted group is refused, and so is anything no
grant covers. Every grant must list its `buckets`; only an explicit `[]` means every bucket.
`readonly` is GetObject, ListBucket and GetBucketLocation; `readwrite` adds PutObject
(multipart uploads included) and DeleteObject. No grant can create or delete a bucket or
change its policy, ACL or settings: that stays with the key pair. SeaweedFS authorizes a
bucket's logging, website and replication settings as ListBucket, so `readonly` can read them.

Group names are compared in **exact case**, and may not contain `*`, `?` or `$`. SeaweedFS
fetches the signing keys itself, so the issuer (or `oidc.jwksUri`, when set) must be
reachable from the container, over a certificate the image trusts. With `jwksUri: ""` they
are discovered from `<issuer>/.well-known/openid-configuration`.

### Keycloak

1. The issuer is the realm URL, `https://<keycloak-host>/realms/<realm>`, exactly as tokens
   carry it (older Keycloak versions put `/auth` before `/realms`).
2. Create an OpenID Connect client, e.g. `seaweedfs-s3`, and set `oidc.clientId` to it.
   Keycloak's access tokens name it in `azp`, which is accepted. The chart needs no client
   secret.
3. In the client's dedicated scope, add a **Group Membership** mapper: token claim name
   `groups`, **Full group path off** (otherwise the claim carries `/ci-cache`, which matches
   no grant), added to the access token.
4. Create the groups the grants name and add users to them. Decode one token and check
   its `iss`, `azp` and `groups` before blaming the store.

### What to know

- **A restart ends every STS credential.** They are signed with a key the container makes
  at each start, so after an upgrade or a node reboot clients must assume the role again.
  SDKs cache STS credentials until shortly before they expire (one hour by default), so a
  long-running client fails until then unless it is restarted. Bearer tokens are unaffected.
- **STS credentials outlive a group removal.** A Bearer token's groups are checked on every
  request, but STS credentials keep the grants of the token they came from for their
  lifetime: one hour by default, up to 12 hours if the client asks.
- **The embedded IAM API is off.** With OIDC on, the chart starts SeaweedFS with
  `-s3.iam=false`: that API answers ListAccessKeys with every identity's access key id, the
  admin's included, to any token holder. The key pair keeps working for S3, but loses the
  read-only IAM calls (ListUsers and the like), and signed STS calls sent as an SDK sends
  them, a form-encoded POST, fail their signature check: `aws sts get-caller-identity`
  does not work while OIDC is on. AssumeRoleWithWebIdentity is unsigned and unaffected.
- **Unknown key ids reach your provider.** A token whose `kid` is not among the cached keys
  makes SeaweedFS fetch the JWKS again, on every such request, so in traefik or published
  mode anyone can make the store call your identity provider with made-up tokens.
- **A refused token leaves no log line.** At SeaweedFS's default log level nothing is logged
  for a wrong `iss` or `aud`, a missing group, an unreachable provider or a trust-policy
  denial. Only a provider configuration it cannot use is logged, once at start, as `Failed
  to create provider`; OIDC is then off while the key pair still works. To find out why a
  token is refused, decode it and compare `iss` with `oidc.issuer`, `aud`/`azp` with
  `oidc.clientId` and `groups` with the grants (exact case), then check that the container
  reaches the issuer.
- The generated IAM configuration is in the manifest and `docker inspect` as
  `SEAWEEDFS_IAM_CONFIG`. It holds no secret.

## Persistence & node pinning

Everything lives under `/data` on the `seaweedfs-data` volume, pinned to the node
labelled `seaweedfs-data=true` while `persistence.enabled`. `persistence.volumePath`
bind-mounts a host directory instead (it must exist on that node; the image fixes
its ownership at start). `persistence.enabled: false` stores everything in the
container — lost when the task is replaced, for tests only. The service is always
one replica and updates stop the old task before starting the new one: two
processes must never share `/data`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `chrislusf/seaweedfs` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `s3.port` | `8333` | S3 listen port (max 55535: the gRPC port is this + 10000) |
| `s3.accessKeySecret` | `seaweedfs-s3-access-key` | External secret holding the access key id |
| `s3.secretKeySecret` | `seaweedfs-s3-secret-key` | External secret holding the secret key |
| `buckets` | `[]` | Buckets created at start if missing |
| `oidc.enabled` | `false` | OIDC sign-in to the S3 API (Bearer tokens and STS) |
| `oidc.issuer` | `""` | Issuer URL, exactly as the token's `iss` claim |
| `oidc.clientId` | `""` | Client the tokens are for: their `aud` or `azp` |
| `oidc.jwksUri` | `""` | Signing keys URL; `""` = discovered from the issuer |
| `oidc.grants` | `[]` | `{group, access: readonly\|readwrite, buckets}`, all three required; `buckets: []` = every bucket |
| `persistence.enabled` | `true` | Persist `/data` |
| `persistence.volumeName` | `seaweedfs-data` | Named volume |
| `persistence.volumePath` | `""` | Host path bind-mounted at `/data` instead (precedence over `volumeName`) |
| `persistence.nodeLabel` | `seaweedfs-data` | Node label the service is pinned to; `""` = no pin |
| `placement.constraints` | `[]` | Extra constraints, always applied |
| `network.name` | `seaweedfs-net` | Overlay S3 clients join (external, auto-created) |
| `exposure.mode` | `none` | S3 API: `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay, joined when the S3 API or the admin UI is routed |
| `ingress.host` | `s3.example.com` | S3 API Traefik `Host()` rule |
| `ingress.tls` | `true` | S3 API HTTPS router + redirect (traefik mode) |
| `traefik.certResolver` | `le` | ACME resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.routerName` | `""` | Router/service base name (`<name>`, `<name>-admin`, `<name>-admin-content`, middleware `<name>-admin-sandbox`); `""` = release name |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware |
| `publish.port` / `publish.mode` | `8333` / `ingress` | S3 API published port (published mode) |
| `admin.enabled` | `false` | Run the web UI (`weed admin`) |
| `admin.port` | `23646` | UI port in the container (max 55535: its worker gRPC is this + 10000) |
| `admin.user` | `admin` | UI login name |
| `admin.passwordSecret` | `seaweedfs-admin-password` | External secret holding the UI password |
| `admin.exposure.mode` | `none` | UI: `none`, `traefik` or `published` |
| `admin.ingress.host` | `""` | UI Traefik `Host()` rule; required in traefik mode, ≠ `ingress.host` |
| `admin.ingress.tls` | `true` | UI HTTPS router + redirect (traefik mode) |
| `admin.publish.port` / `admin.publish.mode` | `23646` / `ingress` | UI published port (published mode), ≠ `publish.port` |
| `extraArgs` | `[]` | Extra `weed server` flags |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/healthz` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
