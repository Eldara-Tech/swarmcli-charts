# rustfs

[RustFS](https://github.com/rustfs/rustfs) as an **S3-compatible object store** for
Docker Swarm, in one of two modes, chosen with `mode` at install:

- **`standalone`** (the default): one service, one node, one drive, with all of its data
  on a node-local volume. A single drive has no erasure-coding redundancy.
- **`distributed`**: objects erasure-coded across several peers, one per node. Each peer
  is a Swarm service of its own (`rustfs-1` … `rustfs-<peers>`) with exactly one replica,
  its own volume and its own node label, because a Swarm volume is node-local. With the
  default 4 peers of one drive each, every object is split into 2 data and 2 parity
  shards, so reads survive 2 peers down and writes survive 1. It is RustFS's multi-node,
  multi-drive (MNMD) deployment, the mode its own Helm chart installs by default.

**Which mode.** Standalone fits a build cache (the GitLab Runner distributed cache), a
backup target or an application's blob store on a small swarm. Distributed is for data
that must survive losing a node: it needs a node per peer, at least 4 of them, and stores
half the drives' total at the default size ([Sizing](#sizing)). A release keeps the mode
it was installed with ([Installing](#installing)).

What the chart adds on top of the image, in either mode:

- **Credentials come from Swarm secrets**, which RustFS reads itself
  (`RUSTFS_ACCESS_KEY_FILE` / `RUSTFS_SECRET_KEY_FILE`). The container refuses to
  start if either is missing, empty, has whitespace inside it, or is RustFS's public
  default `rustfsadmin` — the image only warns about that one and starts anyway.
- **The web console is opt-in.** It is a second listener that serves the S3 and
  admin API as well as the UI, so it stays off unless you ask for it. It can log users
  in through an OpenID Connect provider such as Keycloak.
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.
- **Logs go to `docker service logs`.** The image writes them to a file inside the
  container by default.

Distributed mode adds:

- **One cluster, wired so that it can start on Swarm.** Every peer starts with the same
  volume list and names itself in it ([How the peers find each other](#how-the-peers-find-each-other)).
- **Upgrades roll one peer at a time.** Each peer carries `com.swarmcli.rollout=sequential`,
  so swarmcli updates the next peer only once the one before runs and has outlived its
  monitor window ([Upgrading](#upgrading)).
- **Shapes RustFS would refuse are refused at render**: a peer count and drive count with no
  valid erasure set, more than one drive per peer on named volumes, one host path named
  twice ([Sizing](#sizing)).

## Prerequisites

```bash
# The root credentials, as external Swarm secrets (never chart values), shared by every
# peer in distributed mode. Any key id works; make the secret key long and random, on one
# line with no whitespace inside it.
printf '%s' 'cache-access-key' | docker secret create rustfs-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key -

# Standalone: the node that holds the data. Skip on a single-node swarm and set
# persistence.nodeLabel="" instead.
docker node update --label-add rustfs-data=true <node>

# Distributed: one node per peer, each labelled for the peer whose drives live there. The
# chart pins peer N to node.labels.rustfs-<N>.
docker node update --label-add rustfs-1=true <node-a>
docker node update --label-add rustfs-2=true <node-b>
docker node update --label-add rustfs-3=true <node-c>
docker node update --label-add rustfs-4=true <node-d>
```

Peers belong on different nodes: peers sharing a node share its fate, and with the default
parity losing one node that holds two peers stops writes. On a single-node swarm (to
develop against, never for availability), either label that node with every peer's label
or set `persistence.nodeLabelPrefix=""`.

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.
swarmcli adds it on a first run, while there is no repository list yet; an existing list
is left as it is.

```bash
# Standalone, the default:
swarmcli charts install s3 swarmcli-charts/rustfs --set 'buckets={runner-cache}'

# Or distributed, with the default 4 peers:
swarmcli charts install s3 swarmcli-charts/rustfs --set mode=distributed --set 'buckets={backups}' --wait
```

The chart needs swarmcli 2.2.0 or later in both modes; an older swarmcli refuses to install
or upgrade it, or asks first when run interactively. 2.2.0 is the first to roll a
distributed cluster's peers one at a time, and the chart declares one floor for both modes,
because a template cannot see which swarmcli renders it.

In distributed mode all peers start together on install, find each other within seconds,
and `--wait` returns once each peer's task runs and has outlived its monitor window
(`healthcheck.monitor`, 2 minutes). The shape — `cluster.peers` and
`cluster.drivesPerPeer` — is fixed from then on: RustFS records it on every drive.

> **`mode` is chosen at install.** Changing it on an existing release does not convert the
> data: RustFS cannot expand a single-drive store in place, so the new mode's services start
> on empty drives. Nor does it replace the old ones: swarmcli deploys without `--prune` and
> never removes a service the render drops, so the old mode's services keep running beside
> the new mode's empty ones, all under the same `<release>-rustfs` alias, and clients reach
> both. To take a standalone store's data into a cluster, see
> [Moving from standalone](#moving-from-standalone).

### Connecting

By default (`exposure.mode: none`) the store is reachable only on the `rustfs-net`
overlay, which swarmcli creates if it is missing. Another stack joins that network as
`external: true` and uses the endpoint `http://<release>-rustfs:9000`
(`http://s3-rustfs:9000` above), an alias the chart adds on that network, with `_` and
`.` in the release name turned into `-`. The stack's own service name (`<release>_rustfs`,
or a peer's `<release>_rustfs-<n>`) resolves too, but Java clients (anything on the AWS
SDK for Java, such as Airbyte) reject a host name containing `_`. Releases whose names
differ only in those characters (`my_s3`, `my-s3`) get the same alias, so keep them off
one network.

In distributed mode every peer carries that alias, so it resolves to every peer, and any
peer serves every object.

- **The alias is not readiness-aware.** Swarm resolves it to every peer whose healthcheck
  passes, which is liveness: on a first install, or after every peer stopped, a peer can
  pass its healthcheck before the cluster serves, and answers 503 meanwhile, and a
  connection already on its way to a peer that stops fails. Clients must retry, as S3
  clients do by default.
- Each peer also answers on `http://<release>-rustfs-<n>:9000`, the name the other peers
  dial it by.

Clients use **path-style** addressing (`http://<endpoint>/<bucket>/<key>`), the
default for every non-AWS S3 client, and region `us-east-1`. For virtual-hosted-style
addressing, set `RUSTFS_SERVER_DOMAINS` in `extraEnv`.

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret and network the release references.
A default install needs:

```yaml
- name: s3                # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [rustfs-access-key, rustfs-secret-key]
    networks: [rustfs-net]
```

Add `traefik-public` to `networks` when the S3 API or the console is traefik-routed,
`monitoring` with `metrics.enabled`, `rustfs-oidc-client-secret` to `secrets` with
`console.oidc.enabled`, and the path to `hostPaths` when you set `persistence.volumePath`
(every path, when you set `persistence.volumePaths`). Each entry is the name itself, so
an override in values needs the same change here. swarmcli-cd rolls a distributed
cluster's peers one at a time from v1.5.0-rc4 on.

## Exposure

The S3 API and the web console are exposed independently. `network.name` is attached
in every mode. `exposure.mode`, `ingress.*` and `publish.*` describe the **S3 API
only**; the console has the same three under `console.*`, and a disabled console is
exposed nowhere:

| Mode | S3 API (`exposure.mode`) | Console (`console.exposure.mode`) |
|------|--------------------------|-----------------------------------|
| `none` (default) | nothing — overlay clients only (on `exposure.network` too while the console is routed) | nothing — overlay clients only (on `exposure.network` too while the S3 API is routed) |
| `traefik` | Traefik labels routing `ingress.host` to `s3.port`, with an HTTPS router and ACME certificate when `ingress.tls` | the same for `console.ingress.host` and `console.port`, TLS per `console.ingress.tls` |
| `published` | `s3.port` published on the Swarm as `publish.port` | `console.port` published as `console.publish.port` |

Either route joins `exposure.network`. The S3 API through Traefik:

```bash
swarmcli charts install s3 swarmcli-charts/rustfs \
  --set exposure.mode=traefik --set ingress.host=s3-cache.example.com \
  --set 'buckets={runner-cache}'
```

The console in a browser through Traefik, with no route or published port for the S3
API (port 9000):

```yaml
# values.yaml — swarmcli charts install s3 swarmcli-charts/rustfs -f values.yaml
exposure:
  mode: none                    # no route or published port for the S3 API
console:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: rustfs.example.com    # a host of its own, not ingress.host
```

That keeps port 9000 off the edge's routers, not off its network: a routed console
attaches the service to `exposure.network`, and every service on that overlay can
reach port 9000 (and 9001) directly. The console host itself serves the full signed
S3 API too (see [Web console](#web-console)).

In distributed mode:

- **traefik**: every peer declares the same routers and services, Traefik merges them into
  one service and balances requests over every healthy peer.
- **published**: host mode only. Every peer publishes the same port on its own node, which
  the routing mesh cannot give several services, so `<node>:<publish.port>` reaches the peer
  running there. `publish.mode` and `console.publish.mode` default to `ingress`, which the
  render refuses for a published listener in this mode, so set them to `host`. Put a load
  balancer over the nodes, or use Traefik.

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`,
redirect middleware `https-redirect`); override them for your own Traefik. The
whole bucket namespace is served at the root of `ingress.host`, which is what
path-style requires — do not put a path prefix in front of it.

While either listener is traefik-routed, the chart raises RustFS's idle-connection
timeout to `traefik.idleTimeoutSeconds` (120). RustFS closes an idle upstream
connection after 75 seconds by default, Traefik keeps them for 90, and a large `PUT`
sent on a connection RustFS has just closed fails with `socket hang up`. If you run
your own proxy, keep its upstream keep-alive below RustFS's timeout. Traefik's
entrypoints also time out slow requests (v3's default `readTimeout` is 60s); raise it
on the edge if multi-gigabyte uploads fail part-way.

## Web console

The console listens on `console.port` (9001) and serves its UI under
`/rustfs/console/`; you log in with the key pair from the secrets, or through
[single sign-on](#single-sign-on). On `rustfs-net` it is
`http://<release>-rustfs:9001`; `console.exposure.mode` routes it on
`console.ingress.host` or publishes it as `console.publish.port` (see
[Exposure](#exposure) for the console-only example). A browser that opens `/` is
redirected to `/rustfs/console/`. Routed, the console needs a host of its own, not
`ingress.host`: its UI calls the S3 and admin API at the root of the host it was
loaded from.

That listener is the whole server, not just the UI: **the console host also serves
the full signed S3 and admin API**, exactly as the S3 port does, so routing only the
console still puts that API on a public name. Exposing it adds no unauthenticated
surface, but it does add a public endpoint for your root credentials, and the console
keeps them in the browser's local storage. Leave it off where you do not use it.

In distributed mode `console.enabled` runs the console on every peer. Routed through
Traefik, it carries a **sticky cookie**, so a browser stays on one peer: each peer keeps a
single sign-on login's state in its own memory.

### GitLab Runner cache

The runner's job helper containers upload and download the cache archive
themselves, and they run on the node's own Docker engine — not on any overlay. So
the runner needs an endpoint reachable from a plain container on each runner
node: the Traefik host (or a published port), not `<release>-rustfs`. With the
[gitlab-runner chart](../gitlab-runner):

```yaml
cache:
  enabled: true
  s3:
    server: s3-cache.example.com     # ingress.host
    bucket: runner-cache             # listed in this chart's buckets
    addressing: path
    accessKeySecret: rustfs-access-key
    secretKeySecret: rustfs-secret-key
```

## Single sign-on

With `console.oidc.enabled` the console offers a login through an OpenID Connect
provider beside the key-pair login. Its button reads **Login with SSO**, and
`console.oidc.displayName` sets the label. RustFS's STS (`AssumeRoleWithWebIdentity`)
accepts that provider's tokens too. RustFS maps each value of one ID token claim to the
RustFS policy of the same name (`consoleAdmin`, `readwrite`, `readonly`, or your own)
and gives the session temporary credentials with those policies. The claim is `groups`
unless `extraEnv` names another; the Keycloak steps below give RustFS one of its own,
`rustfs_policies`. Each value must name an existing policy, or RustFS refuses the whole
login (see the last point below). Policies attached inside RustFS to a group named like
a claim value take the claim's place, and so does a `ROLE_POLICY` in `extraEnv`.

With [Keycloak](../keycloak), in your realm:

1. Create an OpenID Connect client, e.g. `rustfs`, with **Client authentication** on
   (a confidential client) and **Standard flow** on; turn the other flows off. Set
   **PKCE Method** to `S256`.
2. Set **Valid redirect URIs** to exactly the console's public URL followed by the
   callback path, `https://rustfs.example.com/rustfs/admin/v3/oidc/callback/default`,
   and **Web origins** to `https://rustfs.example.com`.
3. Put the client secret (**Credentials** tab) in a Swarm secret:
   `printf '%s' '<client secret>' | docker secret create rustfs-oidc-client-secret -`
4. Choose the RustFS policies to grant: log into the console with the root key pair,
   open **Policies** and copy each name exactly. Names are case-sensitive.
5. For each policy, create a client role named exactly like it: **Clients → rustfs →
   Roles → Create role**.
6. Add a mapper: **Clients → rustfs → Client scopes → rustfs-dedicated → Mappers →
   Configure a new mapper → User Client Role** (on older Keycloak, **Mappers** sits
   directly on the client), set as follows, and save:

   | Setting | Value |
   |---|---|
   | Name | `rustfs-policy-mapper` |
   | Client ID | `rustfs`; left empty, Keycloak adds every client's roles, `account`'s included |
   | Client Role prefix | empty |
   | Token Claim Name | `rustfs_policies` |
   | Claim JSON Type | `String` |
   | Multivalued | on |
   | Add to ID token | on — the login reads the ID token |
   | Add to access token | on |
   | Add to userinfo | on |

7. Assign the roles: **Users → the user → Role mapping → Assign role**, filter by
   client roles and pick the `rustfs` ones. Assigned to a Keycloak group instead
   (**Groups → the group → Role mapping**), they reach every member. Do not make them
   default roles unless every user of the realm should get that storage access.
8. Check the token: **Clients → rustfs → Client scopes → Evaluate**, pick the user,
   then **Generated ID token**. A user granted `readwrite` shows
   `"rustfs_policies": ["readwrite"]`.

```yaml
console:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: rustfs.example.com
  oidc:
    enabled: true
    configUrl: https://keycloak.example.com/realms/<realm>/.well-known/openid-configuration
    clientId: rustfs
    displayName: Keycloak        # the button reads "Login with Keycloak"; default SSO
extraEnv:
  # The claim of step 6. Set both: with GROUPS_CLAIM alone, RustFS still reads `groups`
  # through CLAIM_NAME's default and refuses the login.
  RUSTFS_IDENTITY_OPENID_GROUPS_CLAIM: rustfs_policies
  RUSTFS_IDENTITY_OPENID_CLAIM_NAME: rustfs_policies
```

A role change in Keycloak takes effect at the user's next login: sign out of the
console and log in again. RustFS needs no restart.

**Groups instead of client roles.** Where every Keycloak group a user is in is named
exactly like a RustFS policy, a **Group Membership** mapper can carry the policies
instead of steps 5–7: token claim name `groups`, **Full group path** off, **Add to ID
token** on, and no `extraEnv`. With the full path on, the claim reads `/readwrite`,
which names no policy, and a user in any group that is not a policy is refused.

- **The callback.** RustFS builds it from `console.oidc.browserUrl`, which the chart
  derives as `https://<console.ingress.host>` while the console is traefik-routed
  (`http://` with `console.ingress.tls: false`); set it yourself otherwise (e.g.
  `http://node1.example.com:9001` for a published console). It is passed as
  `RUSTFS_BROWSER_REDIRECT_URL`, and RustFS's dynamic redirect is off, so a request's
  `Host` header can never move the callback. `default` in its path is
  RustFS's id for the one provider, not the button's label.
- **Use the provider's public URL** for `configUrl`: the browser is sent to the
  authorization endpoint the discovery document names, and RustFS checks the
  document's issuer against `configUrl`. For the keycloak chart that is its
  `ingress.host`.
- **A provider on a private address** needs `console.oidc.allowPrivateIdp: true`. That
  is a provider whose name resolves to a private address from inside the task: one on
  an overlay such as `rustfs-net`, or on a LAN. RustFS refuses to contact it unless its
  origin is in `RUSTFS_OUTBOUND_ALLOW_ORIGINS`, and without that discovery fails at
  start and the console has no single sign-on. The flag adds the origin of `configUrl`
  to that list, which is process-wide: RustFS's event and audit webhooks and Object
  Lambda targets may then reach that origin as well. A provider on a public address
  needs no flag. If the discovery document names endpoints on another private origin,
  set `RUSTFS_OUTBOUND_ALLOW_ORIGINS` in `extraEnv` to the full comma-separated list;
  it replaces the chart's.
- **The provider must be up when RustFS starts.** RustFS reads the discovery
  document once, at start, and does not retry. If the provider is unreachable then,
  the console has no single sign-on and STS refuses the provider's tokens until RustFS
  restarts (`docker service update --force <release>_rustfs`); the key-pair login
  keeps working. In distributed mode each peer reads it at its own start, and a peer that
  could not reach it has no single sign-on until it restarts
  (`docker service update --force <release>_rustfs-<n>`).
- **The client secret** goes from the Swarm secret into the server's environment at
  start, by the start-up wrapper; it is never in the manifest or `docker inspect`.
  `extraEnv` refuses it in every spelling.
- **What `extraEnv` may tune**, as `RUSTFS_IDENTITY_OPENID_<name>` and only with
  `console.oidc.enabled`: `SCOPES`, `CLAIM_NAME`, `CLAIM_PREFIX`, `ROLE_POLICY`,
  `GROUPS_CLAIM`, `ROLES_CLAIM`, `EMAIL_CLAIM`, `USERNAME_CLAIM` and `HIDE_FROM_UI`.
  Every other OIDC setting is refused, since the provider, client, issuer, callback
  and label come from `console.oidc.*`, and so is a provider suffix: a second provider
  is not supported. The `MINIO_IDENTITY_OPENID_*` spelling is refused too, because
  RustFS reads only some of those names and ignores the rest.
- **`OIDC policy mapping did not resolve to current policies`** at the callback means
  the token's policy claim is missing or holds a value that names no RustFS policy:
  RustFS checks every value, and one miss refuses the whole login. Look at the ID token
  as in step 8. The usual causes: a mapper not added to the ID token, a client-role
  mapper with no **Client ID**, a role or group named differently from its policy, only
  one of the two `extraEnv` keys set, or, with the groups mapper, **Full group path** on
  or a user who is also in a group that is not a policy.

**In distributed mode** every peer is a client of the provider, with the same client id,
secret and callback. **Route the console through Traefik**, whose sticky cookie keeps a
browser on the peer that started its login: RustFS keeps the login's PKCE verifier and
nonce in that peer's memory, so a callback reaching another peer fails with an
invalid-state error. A published console keeps a browser on one node's peer by itself; the
`rustfs-net` alias does not.

## Security

- **Credentials.** RustFS reads both keys from `/run/secrets` itself; neither value
  appears in the manifest or in `docker inspect`. Anonymous requests are refused, and
  so is the default `rustfsadmin` pair. To rotate, create new secrets under new names,
  point `s3.accessKeySecret` / `s3.secretKeySecret` at them and upgrade; in distributed
  mode that takes a full stop (below). `extraEnv` refuses the credential variables in
  both spellings (`RUSTFS_*` and the `MINIO_*` ones RustFS also reads), so a key cannot
  slip into the manifest that way, and the bucket loop hands the key pair to `curl` on
  stdin, so it never appears in a process list.
- Everything on `network.name`, and while either listener is traefik-routed everything
  on `exposure.network`, can reach the S3 port (and the console port when enabled).
  That is the intent; the key pair is what protects the data. In distributed mode that
  port also carries the peers' internode RPC, which RustFS signs with a secret derived
  from the key pair.
- **Distributed mode: `extraEnv` also refuses the cluster wiring** the chart sets
  (`RUSTFS_VOLUMES`, `RUSTFS_LOCAL_ENDPOINT_HOST`, `RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE`), an
  erasure set width (`RUSTFS_ERASURE_SET_DRIVE_COUNT`, which would override the one the
  render checks), the internode secret (`RUSTFS_RPC_SECRET`, a credential), and RustFS's
  test-only switch off its one-drive-per-disk check (`RUSTFS_UNSAFE_BYPASS_DISK_CHECK`),
  each in its `MINIO_*` spelling too, and `MINIO_CI`.
- **Distributed mode: rotating the key pair takes a full stop.** Every peer derives the
  internode secret from the pair, so peers on the old pair and peers on the new one cannot
  reach each other: an upgrade rolling one peer at a time would split the cluster. Create
  the new secrets, stop every peer, then upgrade; swarmcli holds back only peers that are
  running, so all of them start together on the new pair:

  ```bash
  printf '%s' 'new-access-key' | docker secret create rustfs-access-key-2 -
  openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key-2 -
  for n in 1 2 3 4; do docker service scale --detach "s3_rustfs-$n=0"; done
  swarmcli charts upgrade s3 swarmcli-charts/rustfs -f s3-values.yaml --wait \
    --set s3.accessKeySecret=rustfs-access-key-2 --set s3.secretKeySecret=rustfs-secret-key-2
  ```

  The data and buckets survive; clients need the new pair.
- **No call home.** `RUSTFS_CHECK_UPDATE` is off: the image is pinned, and the pin is
  what moves.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a background
loop in the container, once the server answers. For a bucket that already exists
RustFS answers `200`, as S3 does in us-east-1, and the loop also accepts `409`, so
restarts and upgrades are harmless; a bucket that cannot be created after
five minutes is logged (`docker service logs`) and the server keeps running. Removing
a name from `buckets` does not delete the bucket. If you set `RUSTFS_REGION` in
`extraEnv`, the loop signs for that region.

In distributed mode peer 1 runs the loop, once the cluster accepts writes, and the other
peers see the buckets through the cluster. The five minutes start when peer 1 starts, which
on a cluster includes waiting for the others (a missing node label, a slow image pull): a
bucket not created by then is logged on `docker service logs <release>_rustfs-1`, and
`docker service update --force <release>_rustfs-1` runs the loop again.

## Persistence & node pinning

Everything lives under `/data` on the `rustfs-data` volume, pinned to the node
labelled `rustfs-data=true` while `persistence.enabled`. `persistence.volumePath`
bind-mounts a host directory instead. It must exist on that node and be owned by
uid/gid 10001, the user RustFS runs as, which cannot fix ownership itself:

```bash
install -d -o 10001 -g 10001 -m 0750 /srv/rustfs
```

`persistence.enabled: false` stores everything in the container — lost when the
task is replaced, for tests only. The service is always one replica and updates stop
the old task before starting the new one: two processes must never share `/data`.

In distributed mode each peer's drive lives on its own named volume, `<volumePrefix>-<n>`
(`rustfs-data-1` …), mounted at `/data`, with the drive at `/data/rustfs0` inside it, and
each peer is pinned to the node labelled `<nodeLabelPrefix>-<n>=true` (`rustfs-1=true` …)
while `persistence.enabled`.

`persistence.volumePaths` bind-mounts host directories instead: one entry per peer, in peer
order, each a list of `cluster.drivesPerPeer` absolute paths (a single path may be a
string), drive `k` mounted at `/data/rustfs<k>`. Each must exist on its peer's node, on a
disk no other drive of that peer uses, owned by uid/gid 10001:

```bash
install -d -o 10001 -g 10001 -m 0750 /mnt/disk1/rustfs /mnt/disk2/rustfs   # on every node
```

```yaml
mode: distributed
cluster:
  drivesPerPeer: 2
persistence:
  volumePaths:          # the same paths on every node: each peer is on a node of its own
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
```

With `persistence.nodeLabelPrefix: ""` nothing keeps the peers on different nodes, so then
the render refuses a path given to two peers. Each mode refuses the other's host-path key
rather than ignoring it: `persistence.volumePath` in distributed mode, and
`persistence.volumePaths` in standalone.

In distributed mode, with `persistence.enabled: false` a peer whose task is replaced
starts on an empty drive, which RustFS formats at start and heals from the others, but
losing more peers at once than the parity covers loses data. For tests only. Each peer,
like the standalone service, is always one replica, and its updates stop the old task
before starting the new one.

The chart raises the open-file limit to `nofile` (65536): below 16384 RustFS turns
off its per-disk file-descriptor cache, which costs performance. Set `nofile: 0` to
keep the daemon's default. swarmcli deploys through `docker stack deploy`, which
applies `ulimits` to a Swarm service from Docker 23 on; an older Docker CLI ignores
it with a warning.

## Distributed mode

### Sizing

RustFS groups the drives into erasure sets of 2 to 16 drives, and splits every object
across the drives of one set into data and parity shards.

- **The set width** is the largest size from 2 to 16 that divides `peers × drivesPerPeer`
  and also divides the peer count or is a multiple of it. 4 × 1 gives one set of 4, 4 × 2
  one set of 8, 6 × 2 one set of 12. With no such width (17 or 19 peers of one drive, say)
  the render fails, because every peer would refuse to start.
- **Parity** defaults to 2 for a set of 4 or 5 drives, 3 for 6 or 7, and 4 from 8 on.
  Reads need as many drives as there are data shards, writes one more when parity is half
  the set, and parity can be at most half the set. Set another with
  `extraEnv.RUSTFS_STORAGE_CLASS_STANDARD` at install (e.g. `EC:1` on a set of 4, `EC:3` on
  a set of 8).
- **Usable capacity** is the drives' total times data ÷ (data + parity): half of it with
  the default 4 peers.
- **More than one drive per peer** needs `persistence.volumePaths`, one host path per drive,
  each on a disk of its own. RustFS refuses two drives on one physical disk ("local erasure
  endpoints must use distinct physical disks"), and a peer's named volumes all share its
  node's Docker disk. The render refuses `drivesPerPeer > 1` without host paths.
- **The shape is fixed at install.** RustFS records the drive count and set width on every
  drive and refuses to start with others. RustFS grows by adding a server pool, which this
  chart does not support yet. The volume list is written in RustFS's ellipsis form
  (`http://s3-rustfs-{1...4}:9000/data/rustfs0`): a list written out without ellipses is a
  legacy layout that can never take a second pool.

### How the peers find each other

Swarm puts no name of a task in DNS — not its `tasks.<service>` name, not a network alias,
not the service name — and routes nothing to its VIP until the task's healthcheck passes.
RustFS, for its part, resolves every peer in its volume list, its own entry included, before
it opens a port. Left to itself, no peer would ever pass a healthcheck, and no peer would
ever start. So the chart:

- gives every peer `RUSTFS_LOCAL_ENDPOINT_HOST=<release>-rustfs-<n>`, which RustFS matches
  against the volume list by name, without DNS, and accepts only with
  `RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE=orchestrated`. That mode also waits for the other peers
  without a time limit, where the default outside Kubernetes exits after 180 seconds;
- checks `/health/live`, which a peer answers on its own, not `/health/ready`, which needs
  the other peers' lock quorum. A healthcheck on readiness would keep every peer out of DNS
  for good on a first install and after every peer stopped.

The peers dial each other at their aliases' VIPs, which survive a reschedule; each peer
keeps `endpoint_mode: vip`, because `dnsrr` drops network aliases. The cost of a liveness
healthcheck is that it says nothing about the cluster: whether the cluster serves is
`/minio/health/cluster` on any peer, which the [upgrade steps](#upgrading) check. Measured
on RustFS's pinned version, a peer restarted into a running cluster answers `/health/ready`
200 before its own healthcheck has passed.

### Upgrading

With the values you installed with, `mode: distributed` among them:

```bash
swarmcli charts upgrade s3 swarmcli-charts/rustfs -f s3-values.yaml --wait
```

swarmcli updates the peers one at a time, in lexical name order (`rustfs-10` before
`rustfs-2`): it stops a peer, starts its new task, waits until that task runs and has
outlived `healthcheck.monitor` (2 minutes), and only then moves to the next; `rollback` and
`apply` roll the same way. With the default 4 peers the cluster keeps serving reads and
writes throughout, one peer short. An upgrade whose peer fails to start stops there, with
the rest untouched. Pass the values you installed with (`-f`), not `--reuse-values`
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

Check the cluster before and after, from any container on `rustfs-net`:

```bash
docker run --rm --network rustfs-net curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  http://s3-rustfs:9000/minio/health/cluster     # 200: every erasure set has write quorum
```

Install is never sequential: all peers start together, which is what a first install
needs.

### Moving from standalone

There is no in-place conversion. RustFS refuses to start a single-drive store with more than
one drive ("an existing single-node single-drive (SNSD) deployment cannot be expanded in
place"), so a distributed cluster always starts empty, and changing `mode` on a release
does not move its data ([Installing](#installing)). Install the cluster as a second release
with `mode: distributed`, copy the buckets across through S3 (e.g. `rclone sync` or
`mc mirror` from one endpoint to the other), move clients to the new endpoint, then
uninstall the old release. Both modes default to `rustfs-net` and to
`http://<release>-rustfs:9000`, so a client needs only the new release name.

## Metrics

RustFS serves no Prometheus metrics of its own; it pushes them over OpenTelemetry (OTLP)
instead. So `metrics.enabled` adds an
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) service,
`<release>_rustfs-metrics` (`<release>_rustfs-distributed-metrics` in distributed mode),
which RustFS, every peer of it, pushes to over `rustfs-net` and which serves the
same metrics for Prometheus. It carries the deploy labels `prometheus.io/scrape=true` and
`prometheus.io/port=8889` and joins the `monitoring` overlay, which is where the
[prometheus-stack](../prometheus-stack) chart scrapes by default, so Prometheus finds it by
itself with no scrape config. Any Prometheus using Docker Swarm service discovery on those
labels works the same way. RustFS itself never joins `monitoring`.

```bash
swarmcli charts upgrade s3 swarmcli-charts/rustfs -f rustfs-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

- **Turning metrics on restarts RustFS once**, because its environment changes, and so does
  turning them off. The S3 API is unavailable while the new task starts. In distributed mode
  every peer restarts once, one at a time, and the cluster keeps serving, one peer short.
- You get the `rustfs_*` series RustFS pushes, some 500 of them: requests by method,
  status class and S3 operation, request latency, drive capacity and state, objects and
  bytes per bucket, and the process's memory, CPU and open files. RustFS's own `job` and
  `instance` labels (`RustFS` and the task's address) arrive as `exported_job` and
  `exported_instance`, beside the `job` and `stack` that discovery gives the collector.
  The collector drops a series 5 minutes after RustFS last pushed it.
- **In distributed mode** each peer's own series (process, requests, drives) carry its name
  in a `server` label, `<release>-rustfs-<n>:9000`. The cluster-wide series (capacity,
  erasure sets, drives offline) come from every peer, each with an `observer` label naming
  the peer that reports it. A peer that stops keeps its last series in the collector for 5
  minutes, showing the cluster as it last saw it, so read quorum as the worst view any peer
  reports, as the rules do.
- **RustFS pushes only its metrics.** The chart turns its trace and log export off and sets
  `RUSTFS_OBS_LOG_STDOUT_ENABLED`, without which RustFS stops writing its log to
  `docker service logs` as soon as any OTLP endpoint is set. While metrics are on,
  `extraEnv` refuses `RUSTFS_OBS_ENDPOINT`, the per-signal `RUSTFS_OBS_METRIC_ENDPOINT`,
  `_TRACE_ENDPOINT` and `_LOG_ENDPOINT`, the three settings the chart makes, and three
  that would break the push: `RUSTFS_OBS_USE_STDOUT` (a copy of every metric in the log),
  `RUSTFS_OBS_METRICS_EXPORT_ENABLED` (no push at all) and `RUSTFS_OBS_METER_INTERVAL`
  (past the collector's 5 minutes, every series disappears between pushes).
- **What `monitoring` and `rustfs-net` can reach.** The collector listens on two ports and
  authenticates neither: 8889 serves the metrics, and 4318 takes OTLP pushes. Everything on
  `monitoring` or `rustfs-net` reaches both. On 8889 that means every bucket's name, size
  and object count (`rustfs_cluster_usage_buckets_*{bucket="…"}`), with no credentials and
  past RustFS's IAM, which would refuse an unsigned ListBuckets. On 4318 it means pushing
  series the collector then serves as RustFS's. Its `memory_limiter` refuses pushes once it
  holds 150 MiB, below its 256M memory limit (`metrics.resources.limits.memory`), so a
  flood of them is refused rather than getting the collector killed. prometheus-stack
  already treats `monitoring` as a trust zone (its README, *Security*). The collector's own
  telemetry stays on loopback, neither port is published, and RustFS's S3 and console
  ports stay off `monitoring`.
- `metrics.network` names a different overlay. It must differ from `network.name` and
  `exposure.network`, and the render fails if it does not.
- **Turning it off** leaves the collector running, because swarmcli deploys without
  `--prune`, and with nothing left pushing to it, `RustFSNotReporting` fires at critical
  about 15 minutes later. So remove it in the same step (`s3_rustfs-distributed-metrics`
  in distributed mode):

  ```bash
  swarmcli charts upgrade s3 swarmcli-charts/rustfs -f rustfs-values.yaml --set metrics.enabled=false
  docker service rm s3_rustfs-metrics
  ```
- With swarmcli-cd, add `monitoring` to `allow.networks`.

**A collector of your own.** With `metrics.enabled` off, `extraEnv` may point RustFS
elsewhere: `RUSTFS_OBS_ENDPOINT` is the OTLP/HTTP base URL (RustFS appends `/v1/metrics`,
`/v1/traces` and `/v1/logs`), and RustFS then exports traces and logs as well, unless
`RUSTFS_OBS_TRACES_EXPORT_ENABLED` and `RUSTFS_OBS_LOGS_EXPORT_ENABLED` are `"false"`. Set
`RUSTFS_OBS_LOG_STDOUT_ENABLED: "true"` too, or the server log leaves
`docker service logs`.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. One rules file and one dashboard cover both modes.
With the prometheus-stack chart they go in through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/rustfs/monitoring
curl -fsSL -O "$base/rustfs-rules.yml" -O "$base/rustfs-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.rustfs=./rustfs-rules.yml \
  --set-file grafana.dashboards.rustfs=./rustfs-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which `--reuse-values`
is safe (Eldara-Tech/swarmcli#687).

A release file and swarmcli-cd take values files only, not `--set-file`, so there both
files go in as values files: each file's content, as it is, indented under its key as a
block string. From the two files downloaded above:

```bash
mkdir -p monitoring/rules monitoring/dashboards
{ printf 'prometheus:\n  extraRules:\n    rustfs: |\n'; sed 's/^./      &/' rustfs-rules.yml; } > monitoring/rules/rustfs.yaml
{ printf 'grafana:\n  dashboards:\n    rustfs: |\n'; sed 's/^./      &/' rustfs-dashboard.json; } > monitoring/dashboards/rustfs.yaml
```

The dashboard stays JSON: converted to YAML it becomes a mapping, which the render
refuses (`got object, want string`). prometheus-stack's README, *Keeping your setup in
git*, shows where to list the two files.

- **Alerts** (`rustfs-rules.yml`): RustFS ships no alert rules that fit these shapes, so
  these are the chart's, in two groups, `rustfs` for a standalone store and
  `rustfs-distributed` for a cluster. Each selects its own collector by `job`, so neither
  evaluates the other mode's releases. They share alert names where they mean the same
  thing, so a routing rule on `alertname` covers both modes, and every alert groups by
  `stack` and `job`.
  - **`rustfs`.** Critical: `RustFSNotReporting` once the collector has answered with
    nothing from RustFS for about 15 minutes (its series expire 5 minutes after the last
    push, then the alert waits 10), because the task is down or restarting, its export
    failed, or metrics were turned off without removing the collector; `RustFSDriveOffline`
    while the drive is offline, when RustFS answers every read and write with 503 although
    `/health/ready` still answers 200, so the healthcheck does not restart it; and
    `RustFSS3ServerErrors` while more than 5% of the requests either listener answers,
    health checks included, are 5xx. Warnings: `RustFSCapacityLow` below 10% free space,
    and `RustFSDriveIOErrors` for I/O errors and timeouts on the drive.
  - **`rustfs-distributed`**, the quorum alerts grouped also by `pool_id` and `set_id`.
    Critical: `RustFSNotReporting` once the collector has answered with nothing from any
    peer for about 15 minutes; `RustFSWriteQuorumLost` and `RustFSReadQuorumLost` while an
    erasure set has fewer drives online than its write or read quorum, so writes, or reads,
    to it fail; `RustFSWriteQuorumAtRisk` while a set has exactly its write quorum online,
    one failure from refusing writes — with the default 4 peers, one peer down; and
    `RustFSS3ServerErrors` while more than 5% of what the peers answer is 5xx. Warnings:
    `RustFSDriveOffline` while any drive or peer is offline (critical in the `rustfs` group,
    where the one drive is the store), `RustFSCapacityLow` below 10% free, and
    `RustFSDriveIOErrors` per peer. A single peer that stops shows up as
    `RustFSDriveOffline` and, at the default size, `RustFSWriteQuorumAtRisk`.

  A down collector is prometheus-stack's `TargetDown`.
- **Dashboard** (`rustfs-dashboard.json`, uid `rustfs`), trimmed from RustFS's
  [`.docker/observability/grafana/dashboards/rustfs.json`](https://github.com/rustfs/rustfs/blob/main/.docker/observability/grafana/dashboards/rustfs.json)
  (Apache-2.0), for either mode: peers reporting (1 for a standalone store), drives
  offline, free and used space, objects and buckets; requests by method, responses by
  status class, S3 operations and latency; capacity, drive errors, and size and objects per
  bucket; the process's memory, CPU and open files (each peer's), and traffic. Pick a
  release by its `stack`.

The dashboard picks a release by the `stack` label prometheus-stack's discovery puts on
every target, and the alerts carry it. Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`, and the rules
expect the collector's `job` to be its service name: `<release>_rustfs-metrics` for the
`rustfs` group, `<release>_rustfs-distributed-metrics` for `rustfs-distributed`.

## Values

(standalone) or (distributed) marks a key that applies to that mode only; the other mode
ignores it, except where its description says it is refused.

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `rustfs/rustfs` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `mode` | `standalone` | `standalone` or `distributed`; chosen at install, changing it does not convert the data ([Installing](#installing)) |
| `cluster.peers` | `4` | (distributed) Peers, one service each; at least 4; fixed at install |
| `cluster.drivesPerPeer` | `1` | (distributed) Drives per peer; more than 1 needs `persistence.volumePaths`; fixed at install |
| `s3.port` | `9000` | S3 listen port (and, distributed, the port the peers dial each other on) |
| `s3.accessKeySecret` | `rustfs-access-key` | External secret holding the root access key |
| `s3.secretKeySecret` | `rustfs-secret-key` | External secret holding the root secret key |
| `console.enabled` | `false` | Run the web console listener (on every peer) |
| `console.port` | `9001` | Console listen port (must differ from `s3.port`) |
| `console.exposure.mode` | `none` | Console: `none`, `traefik` or `published` |
| `console.ingress.host` / `.tls` | `""` / `true` | Console `Host()` rule (required in traefik mode, not `ingress.host`) and HTTPS routers |
| `console.publish.port` / `.mode` | `9001` / `ingress` | Console published port (published mode); distributed mode needs mode `host`, on each peer's node |
| `console.oidc.enabled` | `false` | Console single sign-on through an OpenID Connect provider (needs `console.enabled`) |
| `console.oidc.configUrl` | `""` | The provider's discovery document URL (required when enabled) |
| `console.oidc.allowPrivateIdp` | `false` | Allow-list the origin of `configUrl` for a provider on a private address (process-wide) |
| `console.oidc.clientId` | `rustfs` | Client ID |
| `console.oidc.clientSecretSecret` | `rustfs-oidc-client-secret` | External secret holding the client secret |
| `console.oidc.browserUrl` | `""` | Console public base URL for the callback; `""` = from `console.ingress` when routed, required otherwise |
| `console.oidc.displayName` | `SSO` | The login button's label, "Login with &lt;displayName&gt;" |
| `buckets` | `[]` | Buckets created at start if missing (by peer 1, distributed) |
| `persistence.enabled` | `true` | Persist `/data` (each peer's drives) |
| `persistence.volumeName` | `rustfs-data` | (standalone) Named volume |
| `persistence.volumePath` | `""` | (standalone) Host path bind-mounted at `/data` instead (precedence over `volumeName`; owned by 10001); refused in distributed mode |
| `persistence.nodeLabel` | `rustfs-data` | (standalone) Node label the service is pinned to; `""` = no pin |
| `persistence.volumePrefix` | `rustfs-data` | (distributed) Named volume prefix, one per peer (`-<n>`) |
| `persistence.volumePaths` | `[]` | (distributed) Host paths instead: one entry per peer, each `drivesPerPeer` paths (owned by 10001); refused in standalone mode |
| `persistence.nodeLabelPrefix` | `rustfs` | (distributed) Node label prefix pinning peer N (`-<N>`); `""` = no pins |
| `placement.constraints` | `[]` | Extra constraints, always applied (to every peer) |
| `network.name` | `rustfs-net` | Overlay S3 clients, and the peers, join (external, auto-created) |
| `exposure.mode` | `none` | S3 API: `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay (when either listener is traefik-routed) |
| `ingress.host` | `s3.example.com` | S3 API `Host()` rule |
| `ingress.tls` | `true` | S3 API HTTPS routers + redirects |
| `traefik.certResolver` | `le` | ACME resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.routerName` | `""` | Router/service name; `""` = release name |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware |
| `traefik.idleTimeoutSeconds` | `120` | RustFS's idle-connection timeout while either listener is routed; must outlast Traefik's 90s |
| `publish.port` / `publish.mode` | `9000` / `ingress` | S3 API published port (published mode); distributed mode needs mode `host`, on each peer's node |
| `nofile` | `65536` | Open-file limit; `0` = daemon default |
| `extraEnv` | `{}` | Extra `RUSTFS_*` environment (for every peer). Credentials, the listener addresses, every OIDC setting but the tuning ones ([Single sign-on](#single-sign-on)), while `metrics.enabled` the OTLP endpoints and export settings ([Metrics](#metrics)), and in distributed mode the cluster wiring, the erasure set width, the internode secret and the disk-check bypass ([Security](#security)) are refused; `RUSTFS_OBS_LOG_DIRECTORY`, `RUSTFS_CHECK_UPDATE`, `RUSTFS_HTTP1_HEADER_READ_TIMEOUT` and `RUSTFS_OUTBOUND_ALLOW_ORIGINS` override the chart's defaults |
| `metrics.enabled` | `false` | An OpenTelemetry Collector RustFS (every peer) pushes its metrics to, labelled for Prometheus service discovery. See *Metrics*. |
| `metrics.image.repository` | `otel/opentelemetry-collector` | Collector image |
| `metrics.image.tag` | pinned in `values.yaml` | Collector image tag (a concrete pin; Renovate maintains it) |
| `metrics.network` | `monitoring` | External overlay the collector shares with Prometheus (auto-created) |
| `metrics.resources.limits.memory` | `256M` | The collector's memory limit; keep it at 256M or more, above its `memory_limiter`'s 200 MiB |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/health/ready` (standalone) or `/health/live` (distributed) on the S3 port; in distributed mode `monitor` is also how long swarmcli waits on each peer before rolling the next, and applies with the healthcheck off too |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits (per peer) |
| `labels` | `{}` | Extra deploy labels (for every peer) |
