# mongodb

Single-instance MongoDB for Docker Swarm: persistent (data on a node-local named volume),
authenticated via external Swarm secrets, pinned to one node, and reachable by other stacks over
a shared overlay. An application user with `readWrite` on its own database is created alongside
root, and an optional single-member replica set turns on transactions and change streams. Not
Traefik-routed (MongoDB is TCP); publishes no port by default.

## Prerequisites

1. Label the node that will hold the data volume (Swarm volumes are node-local, so the service is
   pinned to exactly one node):

   ```bash
   docker node update --label-add mongodb-data=true <node>
   ```

2. Pre-create the password secrets. The chart **validates** these secrets but never creates them
   (their content is operator-supplied):

   ```bash
   printf 'S3cr3t' | docker secret create mongodb_root_password -
   printf 'AppS3cr3t' | docker secret create mongodb_password -   # skip with auth.appUser.enabled: false
   ```

3. Only with `replicaSet.enabled: true`, the keyFile the member authenticates to itself with:

   ```bash
   openssl rand -base64 756 | docker secret create mongodb_keyfile -
   ```

4. (Optional) the `mongodb-net` overlay — swarmcli auto-creates it if missing.

For an ephemeral database, set `persistence.enabled: false` (skip step 1 — the node pin is dropped
together with the volume).

On x86-64 the node's CPU must support **AVX**, and on ARM it must be ARMv8.2-A or newer. MongoDB
has required both since 5.0; older CPUs and some virtual CPU models crash with `Illegal
instruction`, and the image only logs a warning about it.

## Installing

```bash
swarmcli charts install mongodb swarmcli-charts/mongodb
```

With a replica set:

```bash
swarmcli charts install mongodb swarmcli-charts/mongodb --set replicaSet.enabled=true
```

## Connecting

Attach an app service to the `mongodb-net` overlay and dial **`<release>_mongodb:27017`** — for the
install above, `mongodb_mongodb:27017`. (The unqualified service name `mongodb` is also registered
as a network alias, but it is ambiguous the moment two releases of this chart share the overlay,
so prefer the stack-qualified name.)

As the application user — the database in the path is also the one it authenticates against:

```
mongodb://app:<mongodb_password>@mongodb_mongodb:27017/app
mongodb://app:<mongodb_password>@mongodb_mongodb:27017/app?replicaSet=rs0    # replicaSet.enabled
```

As root, authenticate against `admin`:

```
mongodb://root:<mongodb_root_password>@mongodb_mongodb:27017/admin
```

Percent-encode reserved characters (`@ : / ? # [ ] %`) in a password inside a connection string.

To reach MongoDB from outside the overlay, set `exposure.enabled: true`. The container always
listens on 27017 and `exposure.port` is the port published on the **host**, so a taken 27017 can be
republished (`exposure.port: 37017`). `mode: ingress` binds that port on **every** Swarm node, so
prefer `mode: host` (the pinned node only) and firewall it to trusted sources — MongoDB speaks
plain TCP here, with no TLS. With the replica set on, an outside client must add
`directConnection=true`: replica-set discovery hands it the member address
`<release>_mongodb:27017`, which only resolves on the overlay.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `mongo` | Image repository |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Replica count (must stay 1 — node-local volume; see `replicaSet` for a replica set) |
| `auth.rootUsername` | `root` | Root user created at first init (role `root` on `admin`) |
| `auth.rootSecretName` | `mongodb_root_password` | External Swarm secret holding the root password |
| `auth.appUser.enabled` | `true` | Create an application user at first init |
| `auth.appUser.username` | `app` | Application user name |
| `auth.appUser.database` | `app` | Database it gets `readWrite` on, and authenticates against |
| `auth.appUser.secretName` | `mongodb_password` | External Swarm secret holding its password |
| `replicaSet.enabled` | `false` | Run a single-member replica set (transactions, change streams) |
| `replicaSet.name` | `rs0` | Replica set name (`?replicaSet=<name>`) |
| `replicaSet.keyFileSecretName` | `mongodb_keyfile` | External Swarm secret holding the internal-auth keyFile |
| `persistence.enabled` | `true` | Mount a volume at `/data/db` (also controls the node pin) |
| `persistence.volumeName` | `mongodb-data` | Named volume (used when `volumePath` is empty) |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead; when set it wins over `volumeName` (see Operating notes) |
| `persistence.nodeLabel` | `mongodb-data` | Node label the data pin renders from (`node.labels.<nodeLabel> == true`); dropped when persistence is off, `""` skips the pin |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin comes from `persistence.nodeLabel`) |
| `network.name` | `mongodb-net` | Overlay network |
| `network.external` | `true` | Use a pre-existing/shared overlay vs chart-managed |
| `exposure.enabled` | `false` | Publish a port |
| `exposure.port` / `.protocol` / `.mode` | `27017` / `tcp` / `ingress` | Host port (mapped to the container's 27017), protocol, publish mode |
| `resources.limits.memory` | `""` | Swarm deploy memory limit; mongod sizes its cache from it |
| `healthcheck.*` | see `values.yaml` | `mongosh` against the container's hostname: healthy once `db.hello()` reports a writable primary |
| `healthcheck.monitor` | `2m` | Rollout watch window. Must cover `startPeriod + interval x retries` (110s) — see below |
| `extraArgs` | `[]` | Extra mongod flags, one argv element per entry (`["--slowms", "200"]`) |
| `labels` | `{}` | Extra deploy labels |

## Security note

Passwords are read from the mounted secret files, so the resolved values appear only inside the
container — never in the compose file or `docker inspect`, which show only `/run/secrets/...`
paths. The root password goes through the image's `MONGO_INITDB_ROOT_PASSWORD_FILE` convention.
The image has no such variable for any other user, so for the application user the chart wraps the
entrypoint: it writes a first-init script in which `mongosh` reads the password from the secret
file itself, then hands over to the image's entrypoint unchanged. Trailing newlines in a secret
are stripped, the way the image strips them for root.

Setting the root credentials also makes the entrypoint start mongod with `--auth` on every boot,
so there is no unauthenticated access even to an already-initialised volume. The healthcheck
needs no password: `db.hello()` is one of the few commands MongoDB answers unauthenticated. With
the replica set on, the probe authenticates as root only for the one-time `rs.initiate`.

**Hand applications the app user, not root.** `root` can read, drop and reconfigure everything.
The app user holds `readWrite` on `auth.appUser.database` alone — enough to create collections and
indexes and to read and write documents, and refused everywhere else. If an application also
needs `collMod`, validators or profiling on its database, grant `dbAdmin` there rather than
switching it to root:

```bash
docker exec -it $(docker ps -q -f label=com.docker.swarm.service.name=mongodb_mongodb) \
  mongosh -u root -p --authenticationDatabase admin \
  --eval 'db.getSiblingDB("admin").grantRolesToUser("app", [{ role: "dbAdmin", db: "app" }])'
```

That also shows the pattern for adding a second application's user (`db.getSiblingDB("<db>")
.createUser(...)`) when several apps share one instance.

## Operating notes

- **Users are created on first boot only.** The root user and the app user are created while
  `/data/db` is empty; once the volume holds data, the entrypoint skips its init entirely. Editing a
  secret and redeploying does **not** change a stored password — rotate inside the database
  (`db.getSiblingDB("admin").changeUserPassword("app", "…")`), then update the secret to match.
  Likewise, enabling `auth.appUser` or renaming a user on an existing volume creates or renames
  nothing. (Persistence off — an ephemeral database — re-initialises on every new task.)
- **Replica set.** `replicaSet.enabled: true` restarts mongod with `--replSet` and a keyFile, and
  the healthcheck runs `rs.initiate` once, advertising `<release>_mongodb:27017` as the only member.
  The task reports healthy once it has elected itself primary — on the probe after the one that
  initiates the set. This works on a fresh volume and on one that already holds standalone data,
  which is converted in place with its data kept. Because the member address contains the release
  name, reusing a data directory (`persistence.volumePath`) under a **different** release name
  leaves a member that no longer finds itself in its own configuration, and the task never turns
  healthy — keep the release name, or `rs.reconfig(…, { force: true })` as root. The healthcheck
  runs the initiate, so `healthcheck.enabled: false` is rejected at render time while the replica
  set is on. The oplog defaults to 5% of the volume's free disk (at least 990 MB); cap it with
  `extraArgs: ["--oplogSize", "<MB>"]` on a small disk.
- **Upgrades follow MongoDB's featureCompatibilityVersion.** Changing the image series — via
  `image.tag`, or by upgrading to a chart whose `appVersion` moved — is a database upgrade, not a
  redeploy: mongod starts only on data whose `featureCompatibilityVersion` it supports, and a
  newly-upgraded server keeps the old FCV until you raise it. Follow MongoDB's upgrade notes for
  the target release. To stay on the long-term-support series instead of the chart default, pin
  `image.tag: "8.0"`.
- **Memory.** mongod sizes the WiredTiger cache from the container's memory limit
  (`resources.limits.memory`) when one is set, otherwise from the node's RAM — on a node shared
  with other services, set a limit. Leave headroom above the cache for connections and for the
  healthcheck's `mongosh`.
- **Host-path persistence.** By default data lives on the node-local named volume `mongodb-data`
  (durable across restarts/redeploys, under Docker's own volume storage). To store it under a
  directory you choose instead, set `persistence.volumePath` to an absolute path — it takes
  precedence over `volumeName` and `/data/db` is **bind-mounted** from that path on the pinned
  node. The directory must already exist on that node; the image entrypoint chowns it to the
  container's `mongodb` uid (`999`) on start. A bind mount is direct host-filesystem access,
  acknowledged by this chart's `swarmcli-charts/allow: "host-mount"` annotation. (A host path in
  `volumeName` is rejected at render time — that field is a Docker named-volume name and cannot
  contain `/`.)
- **Ephemeral mode still gets a volume — an anonymous one.** The image declares `VOLUME /data/db`,
  so with `persistence.enabled: false` Swarm attaches an anonymous volume there. It is discarded
  with the task (a recreated task gets a fresh, empty one), so the database is ephemeral as
  advertised — but the anonymous volumes are not stack-labelled, so `uninstall --purge-volumes`
  cannot see them; `docker volume prune` on the node clears them. The image's other declared
  volume, `/data/configdb`, is only used by a sharded cluster's config server; the chart covers it
  with an empty tmpfs so no task leaves a stray volume behind.
- **Backups / availability.** Data lives only on the pinned node's local volume and the service runs
  a single replica, so there is no built-in HA — a single-member replica set adds replica-set
  *features*, not redundancy. If that node is lost the database is unavailable until it returns or
  you restore a backup. Back up out-of-band (`mongodump`, or a filesystem snapshot of the volume).

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. `swarmcli charts lint` warns when `monitor` is shorter
than `start_period + interval x retries`.

**Raise it if you raise the healthcheck values above**, or the lint will tell you.
