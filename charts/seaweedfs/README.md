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
  password-protected `weed admin`, opt-in (see [Web UI](#web-ui)), with OIDC login
  on the SeaweedFS Enterprise image.
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.
- **Optional OIDC sign-in to the S3 API** (`s3.oidc`): tokens from your identity
  provider, scoped by group to buckets and read or read/write access.

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

- **What the edge adds in front of `weed admin`.** In traefik mode the admin
  routers carry three protections that `published` mode and the overlays lack:
  - they refuse every method but GET and HEAD when the browser marks the request
    `Sec-Fetch-Site: same-site` or `cross-site` (current browsers send the
    header; a client that sends none, such as curl, passes);
  - the routes that return stored files or their metadata
    (`/api/files/download`, `/api/files/view`, `/api/files/metadata`) ride a
    router of their own, `<router>-admin-content-https`, whose responses carry
    `Content-Security-Policy: sandbox` and `X-Content-Type-Options: nosniff`
    (the `<router>-admin-sandbox` middleware). An inline PDF preview may not
    render under the sandbox; download the file instead;
  - every admin router refuses a path with an encoded slash (`%2F`). Traefik
    matches the path still encoded, and this keeps every request for those
    routes on their router. The UI passes file paths in the query string, never
    the path.

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
- **OIDC login for the UI needs the SeaweedFS Enterprise image**: see
  [Single sign-on](#single-sign-on-seaweedfs-enterprise). [`s3.oidc`](#oidc-for-the-s3-api)
  covers the S3 API alone.
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

### Single sign-on (SeaweedFS Enterprise)

`admin.oidc` adds a **Sign in with OIDC** button to the login page; the password login
keeps working beside it. OIDC login to `weed admin` is a SeaweedFS Enterprise feature: the
free image has no such option, and the chart refuses `admin.oidc` on it. Set
`image.repository` to `chrislusf/seaweedfs-enterprise`, or a mirror whose name ends in
`seaweedfs-enterprise`. Its terms are SeaweedFS's: [seaweedfs.com](https://seaweedfs.com/)
lists it as free for development and testing under 25 TB and priced per TB otherwise. The
4.48 image needs no key file: it starts with a built-in 25 TB licence, which its log dates
to expire 31 days after the start. The chart manages no licence. `image.tag` defaults to
the free image's `appVersion`; pin it if Enterprise has not published that tag yet.

With [Keycloak](../keycloak), in your realm:

1. Create an OpenID Connect client, e.g. `seaweedfs-admin`, with **Client authentication**
   on and **Standard flow** on; turn the other flows off. Leave **PKCE Method** empty:
   SeaweedFS sends no PKCE challenge.
2. Set **Valid redirect URIs** to the UI's public URL followed by `/login/oidc/callback`,
   e.g. `https://seaweedfs-admin.example.com/login/oidc/callback`.
3. In the client's dedicated scope, add a **Group Membership** mapper: token claim name
   `groups`, **Full group path** off (so the claim carries the bare names the lists use),
   **Add to ID token** on.
4. Create the groups `admin.oidc.adminGroups` and `admin.oidc.readonlyGroups` name, and
   add users to them.
5. Put the client secret (**Credentials** tab) in a Swarm secret:
   `printf '%s' '<client secret>' | docker secret create seaweedfs-admin-oidc-client-secret -`

```yaml
image:
  repository: chrislusf/seaweedfs-enterprise
admin:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: seaweedfs-admin.example.com
  oidc:
    enabled: true
    issuer: https://keycloak.example.com/realms/<realm>
    clientId: seaweedfs-admin
    adminGroups: [storage-admins]        # full control, as with the password
    readonlyGroups: [storage-auditors]   # can look, cannot change anything
```

- **Who gets in.** A member of an `adminGroups` group gets the same full control as the
  password; a member of a `readonlyGroups` group can look but not change anything. Anyone
  in neither is refused (`OIDC login failed`), whatever else the realm grants them: the
  chart sets no default role. SeaweedFS compares group names **ignoring case**, so a realm
  group `Storage-Admins` counts as `storage-admins`: leave creating groups to realm admins.
  It treats `*` as a wildcard, so the chart refuses it, and `?` and `,` with it.
- **A session ends when its ID token expires**, five minutes after login with Keycloak's
  defaults. To stay logged in longer, raise **Access Token Lifespan** (the realm's
  **Tokens** settings, or the client's **Advanced** tab); the ID token follows it.
- **Everything is https.** SeaweedFS refuses a plain-http issuer or callback (except on
  localhost), and the chart refuses to render one. `admin.oidc.browserUrl`, the base of the
  callback, defaults to `https://<admin.ingress.host>` while the UI is traefik-routed with
  `admin.ingress.tls`; set it to the UI's https URL otherwise, e.g. behind a proxy that
  terminates TLS. Use the provider's public URL as `issuer`: the browser is sent to the
  login page its discovery document names.
- **The provider must be up when weed admin starts.** It reads the discovery document
  once, from inside the container. If the provider is unreachable then, the login page has
  no OIDC button and the log says `disabling admin OIDC authentication`; the password login
  keeps working, and `docker service update --force <release>_seaweedfs` tries again.
- **The client secret** goes from the Swarm secret into weed admin's environment alone,
  like the password. The other `WEED_ADMIN_OIDC_*` settings are plain environment, in the
  manifest and `docker inspect`.
- **The Enterprise image listens differently.** Its `weed admin` binds the unauthenticated
  worker gRPC port (`admin.port + 10000`) wherever it binds the UI; the free one keeps that
  port on 127.0.0.1. So on the Enterprise image, with or without `admin.oidc`, the chart
  runs the UI on 127.0.0.1, on `admin.port + 1`, and busybox `nc` forwards `admin.port` to
  it. Neither port is reachable from the overlays.

### Single sign-on through oauth2-proxy

`admin.oauth2` puts [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in front
of the UI, on the free image as on Enterprise, as the [airbyte chart](../airbyte) does for
Airbyte: a user signs in at your identity provider, must be in one of
`admin.oauth2.allowedGroups`, and then logs in to the UI with its password as before. It
cannot be combined with `admin.oidc`, and the chart refuses both at once.

The password stays because the UI also answers on every overlay the store joins
(`network.name`, `monitoring` with metrics on), where nothing stands in front of it. The
proxy decides who reaches the login page from the edge; it does not replace the password.

It needs `admin.exposure.mode: traefik` with `admin.ingress.tls`: the proxy carries the
UI's routers and every edge rule above, and sets a secure cookie. seaweedfs then joins
`exposure.network` only when the S3 API is routed, and meets the proxy on `admin-oauth2`,
an overlay of the stack's own that nothing else can attach to.

With [Keycloak](../keycloak), in your realm:

1. Create an OpenID Connect client, e.g. `seaweedfs-admin`, with **Client authentication**
   and **Standard flow** on; turn the other flows off. oauth2-proxy sends a PKCE S256
   challenge, so **PKCE Method** may be `S256`.
2. Set **Valid redirect URIs** to `https://<admin.ingress.host>/oauth2/callback`.
3. Add the **Group Membership** mapper as above: claim `groups`, **Full group path** off,
   **Add to ID token** on.
4. Put the client secret in a Swarm secret, and a random cookie secret beside it:
   `printf '%s' '<client secret>' | docker secret create seaweedfs-admin-oauth2-client-secret -`
   and `head -c 32 /dev/urandom | docker secret create seaweedfs-admin-oauth2-cookie-secret -`

```yaml
admin:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: seaweedfs-admin.example.com
  oauth2:
    enabled: true
    issuer: https://keycloak.example.com/realms/<realm>
    clientId: seaweedfs-admin
    allowedGroups: [storage-admins]
```

- **Who gets in.** A user whose ID token's `groups` claim holds an `allowedGroups` value,
  matched exactly, reaches the login page; anyone else gets oauth2-proxy's `403`. Everyone
  admitted then needs the one UI password: the free UI has no per-user roles.
- **Other providers** work too: the proxy runs as a generic OIDC client, and needs only a
  `groups` claim in the ID token. Dex and Authentik send it only when asked, so add
  `groups` to `admin.oauth2.scope` there.
- **A private CA.** The proxy always verifies the provider's certificate. For a provider on
  a private CA, put the CA bundle in a Swarm secret and name it in `admin.oauth2.caSecret`.
- **The provider must be up when the proxy starts**: it reads the discovery document once
  and exits without it, and Swarm restarts it until it succeeds.
- **The session** lives in an encrypted cookie, Secure, SameSite=Lax and only for
  `admin.ingress.host`, for oauth2-proxy's default 7 days. Rotating the cookie secret signs
  everyone out. No identity header goes to the UI, and a bearer token does not skip the
  sign-in. `admin.oauth2.trustedProxyIp` must cover the edge proxy's address on
  `exposure.network`.
- **`labels`** still go on seaweedfs. In this mode the UI's routers are the proxy's, so a
  middleware for them cannot be added through `labels`.

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
- **No telemetry.** `weed server` reports anonymous cluster statistics to
  telemetry.seaweedfs.com by default; the chart passes `-master.telemetry=false`.
- Everything on `network.name`, and everything on `exposure.network` whenever
  the S3 API or the admin UI is traefik-routed, can reach the S3 port. That is
  the intent; the key pair is what protects the data.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a
background loop in the container, once the gateway answers. `409` (already
exists) counts as done, so restarts and upgrades are harmless; a bucket that
cannot be created after five minutes is logged (`docker service logs`) and the
server keeps running. Removing a name from `buckets` does not delete the bucket.

## OIDC for the S3 API

`s3.oidc.enabled` lets people and jobs use their identity provider's token instead of the
key pair, which keeps working unchanged. A client sends the token as a Bearer header, or
exchanges it for temporary S3 keys with STS on the same port:

```bash
curl -H "Authorization: Bearer $TOKEN" https://s3-cache.example.com/runner-cache/some/key
aws sts assume-role-with-web-identity --endpoint-url https://s3-cache.example.com \
  --role-arn arn:aws:iam::role/oidc --role-session-name "$USER" --web-identity-token "$TOKEN"
```

Access comes only from `s3.oidc.grants`:

```yaml
s3:
  oidc:
    enabled: true
    issuer: https://sso.example.com/realms/infra
    clientId: seaweedfs-s3
    grants:
      - { group: ci-cache, access: readwrite, buckets: [runner-cache] }
      - { group: auditors, access: readonly, buckets: [] }   # [] = every bucket
```

A token is accepted when its `iss` equals `s3.oidc.issuer`, its `aud` or `azp` equals
`s3.oidc.clientId`, and its `groups` claim names a granted group. It then gets every grant of
every granted group it is in. A token in no granted group is refused, and so is anything no
grant covers. Every grant must list its `buckets`; only an explicit `[]` means every bucket.
`readonly` is GetObject, ListBucket and GetBucketLocation; `readwrite` adds PutObject
(multipart uploads included) and DeleteObject. No grant can create or delete a bucket or
change its policy, ACL or settings: that stays with the key pair. SeaweedFS authorizes a
bucket's logging, website and replication settings as ListBucket, so `readonly` can read them.

Group names are compared in **exact case**, and may not contain `*`, `?` or `$`. SeaweedFS
fetches the signing keys itself, so the issuer (or `s3.oidc.jwksUri`, when set) must be
reachable from the container, over a certificate the image trusts. With `jwksUri: ""` they
are discovered from `<issuer>/.well-known/openid-configuration`.

### Keycloak

1. The issuer is the realm URL, `https://<keycloak-host>/realms/<realm>`, exactly as tokens
   carry it (older Keycloak versions put `/auth` before `/realms`).
2. Create an OpenID Connect client, e.g. `seaweedfs-s3`, and set `s3.oidc.clientId` to it.
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
  token is refused, decode it and compare `iss` with `s3.oidc.issuer`, `aud`/`azp` with
  `s3.oidc.clientId` and `groups` with the grants (exact case), then check that the container
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
| `image.repository` | `chrislusf/seaweedfs` | Container image; `chrislusf/seaweedfs-enterprise` for `admin.oidc` |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `s3.port` | `8333` | S3 listen port (max 55535: the gRPC port is this + 10000) |
| `s3.accessKeySecret` | `seaweedfs-s3-access-key` | External secret holding the access key id |
| `s3.secretKeySecret` | `seaweedfs-s3-secret-key` | External secret holding the secret key |
| `buckets` | `[]` | Buckets created at start if missing |
| `s3.oidc.enabled` | `false` | OIDC sign-in to the S3 API (Bearer tokens and STS) |
| `s3.oidc.issuer` | `""` | Issuer URL, exactly as the token's `iss` claim |
| `s3.oidc.clientId` | `""` | Client the tokens are for: their `aud` or `azp` |
| `s3.oidc.jwksUri` | `""` | Signing keys URL; `""` = discovered from the issuer |
| `s3.oidc.grants` | `[]` | `{group, access: readonly\|readwrite, buckets}`, all three required; `buckets: []` = every bucket |
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
| `admin.oidc.enabled` | `false` | OIDC login to the UI (Enterprise image only) |
| `admin.oidc.issuer` | `""` | The provider's https issuer URL |
| `admin.oidc.clientId` | `seaweedfs-admin` | Client ID |
| `admin.oidc.clientSecretSecret` | `seaweedfs-admin-oidc-client-secret` | External secret holding the client secret |
| `admin.oidc.browserUrl` | `""` | The UI's https base URL for the callback; `""` = from `admin.ingress` when routed with TLS |
| `admin.oidc.adminGroups` | `[]` | `groups` claim values that get full control |
| `admin.oidc.readonlyGroups` | `[]` | `groups` claim values that get read-only access; one of the two lists is required |
| `admin.oauth2.enabled` | `false` | oauth2-proxy sign-in in front of the UI; not with `admin.oidc` |
| `admin.oauth2.image.repository` / `admin.oauth2.image.tag` | `quay.io/oauth2-proxy/oauth2-proxy` / pinned in `values.yaml` | oauth2-proxy image |
| `admin.oauth2.issuer` | `""` | The provider's https issuer URL |
| `admin.oauth2.clientId` | `seaweedfs-admin` | Client ID |
| `admin.oauth2.clientSecretSecret` | `seaweedfs-admin-oauth2-client-secret` | External secret holding the client secret |
| `admin.oauth2.cookieSecretSecret` | `seaweedfs-admin-oauth2-cookie-secret` | External secret holding the cookie secret (16, 24 or 32 bytes) |
| `admin.oauth2.caSecret` | `""` | External secret holding the CA bundle for a provider on a private CA |
| `admin.oauth2.allowedGroups` | `[]` | `groups` claim values admitted; at least one is required |
| `admin.oauth2.scope` | `openid email profile` | Scopes requested at sign-in |
| `admin.oauth2.trustedProxyIp` | `10.0.0.0/8` | Addresses whose `X-Forwarded-*` headers the proxy believes |
| `extraArgs` | `[]` | Extra `weed server` flags |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/healthz` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
