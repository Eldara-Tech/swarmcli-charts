# mariadb-galera

A MariaDB **Galera cluster** on Docker Swarm: synchronous multi-primary
replication, so every peer accepts reads *and* writes and a committed transaction
is on every peer before it returns. Losing a peer costs no data and no writes, as
long as a majority survives.

Each peer is its own Swarm service with one replica, its own data volume and its
own node label — a Swarm volume is node-local, which is the same reason the
single-node [`mariadb`](../mariadb) chart pins itself. Peers find each other over
the overlay by service name; Galera's own ports are never published.

Use [`mariadb`](../mariadb) instead if you want one database and can tolerate the
restart. Galera buys availability, not speed: a write costs a cluster-wide
round-trip, and the constraints below are real.

## Prerequisites

```bash
# The root password, shared by every peer, as an external Swarm secret:
printf 'S3cr3t' | docker secret create mariadb_galera_root_password -

# The app user's password (auth.appUser.enabled, on by default):
printf 'S3cr3t' | docker secret create mariadb_galera_password -

# One node per peer, each labelled for the peer whose volume lives there.
# The chart pins peer N to node.labels.mariadb-galera-<N>:
docker node update --label-add mariadb-galera-1=true <node-a>
docker node update --label-add mariadb-galera-2=true <node-b>
docker node update --label-add mariadb-galera-3=true <node-c>
```

Put each peer on a **different** node — three peers on one node share its fate and
give you no availability at all. On a single-node swarm (development) set
`persistence.nodeLabelPrefix: ""` to schedule every peer unpinned instead.

The `mariadb-galera-net` overlay is created for you at install. It carries
replication traffic, so on a multi-node swarm consider encrypting it — either
`network.external: false` with `network.encrypted: true`, or pre-create it
yourself:

```bash
docker network create --driver overlay --attachable --opt encrypted mariadb-galera-net
```

## Installing

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts install db swarmcli-charts/mariadb-galera
```

The cluster bootstraps itself on the first install — there is no second step and
no flag to unset afterwards. See *How bootstrapping decides* below for what that
means when a peer is later rebuilt.

## Connecting

Apps join the same overlay and connect to **`mariadb`**, a DNS alias every peer
shares, so connections spread across the peers:

```yaml
networks:
  mariadb-galera-net:
    external: true
```

```
mysql://app:<password>@mariadb:3306/app
```

Any peer accepts writes, so nothing needs to find a leader. But DNS round-robin is
**not health-aware**: a client handed a peer that is down or re-syncing must
reconnect, so use a driver/pool that retries. For a single health-checked endpoint,
put a proxy such as MaxScale or HAProxy in front of the alias — this chart does
not deploy one. Individual peers are addressable as `mariadb-galera-1`,
`mariadb-galera-2`, … if you want to pin reads to one.

`exposure.enabled` publishes the SQL port in **host** mode only: every peer
publishes the same port, and several services cannot each claim it on the ingress
routing mesh. Port 3306 on a node then reaches the peer running there.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `mariadb` | Image repository. |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml. |
| `cluster.name` | `mariadb-galera` | Galera cluster name; peers only join a cluster whose name matches. |
| `cluster.peers` | `3` | Number of peers. `3` or `5` — Galera needs a majority, so even counts add nothing. |
| `cluster.forceBootstrap` | `""` | Disaster recovery only: the peer that must form a new cluster. See below. |
| `auth.rootSecretName` | `mariadb_galera_root_password` | External secret holding the root password. |
| `auth.appUser.enabled` | `true` | Create a non-root user + database when the cluster first bootstraps. |
| `auth.appUser.username` | `app` | Application user name. |
| `auth.appUser.database` | `app` | Database created for that user. |
| `auth.appUser.secretName` | `mariadb_galera_password` | External secret holding the app user's password. |
| `persistence.enabled` | `true` | Named volume per peer. `false` = ephemeral (no volumes, no pins). |
| `persistence.volumePrefix` | `mariadb-galera-data` | Volume name prefix; peer N gets `<prefix>-<N>`. |
| `persistence.volumePaths` | `[]` | One absolute host path per peer, in peer order; takes precedence over the prefix. |
| `persistence.nodeLabelPrefix` | `mariadb-galera` | Node-label prefix; peer N pins to `node.labels.<prefix>-<N>`. `""` = unpinned. |
| `placement.constraints` | `[]` | Extra constraints applied to every peer, in all modes. |
| `network.name` | `mariadb-galera-net` | Overlay the cluster attaches to. |
| `network.external` | `true` | `false` = chart-managed internal overlay. |
| `network.encrypted` | `false` | IPsec on a chart-managed overlay; requires `external: false`. |
| `network.clientAlias` | `mariadb` | DNS alias shared by every peer. `""` = no shared alias. |
| `exposure.enabled` | `false` | Publish the SQL port on each peer's own node. |
| `exposure.port` | `3306` | Published port. |
| `exposure.protocol` | `tcp` | Published protocol. |
| `exposure.mode` | `host` | Only `host` is valid — see *Connecting*. |
| `resources.limits.memory` | `""` | Per-peer memory limit, e.g. `512M`. Rendered only when set. |
| `healthcheck.enabled` | `true` | Container healthcheck (`--connect --galera_online`). |
| `healthcheck.interval` | `10s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `6` | Failures before unhealthy. |
| `healthcheck.startPeriod` | `120s` | Grace period — **must exceed your worst-case state transfer**. |
| `healthcheck.monitor` | `180s` | Rollout failure window; see below. |
| `extraArgs` | `[]` | Extra `mariadbd` flags, appended verbatim. |
| `labels` | `{}` | Extra deploy labels on every peer. |

## Security note

Passwords are read from mounted secret files via the image's `MARIADB_*_FILE`
convention, so the plaintext never lands in the compose file, the environment or
`docker inspect` — only the `/run/secrets/...` path does. Secrets are always
external and operator-created; the chart never creates one.

State transfer between peers needs a database account of its own, and the usual
recipe puts `wsrep_sst_auth=user:password` in the config — where it also ends up in
the error log. This chart instead creates the account authenticating **VIA
`unix_socket`**, matching it against the OS user `mysqld` already runs as, so there
is no third secret and no password to leak.

Replication carries every row written. On a multi-node swarm it crosses the
overlay between nodes, so encrypt that overlay unless the network between nodes is
already trusted — see *Prerequisites*.

## Operating notes

### How bootstrapping decides

Exactly one peer must form the cluster, once, and never again — bootstrapping a
second time beside a live cluster is a split brain. **Peer 1 is the designated
seed**: it is the only peer that can ever form a cluster, and the others only ever
join. Before `mariadbd` starts:

- **Peer 1, data dir empty, no peer answering on port 4567** → form the cluster.
  This is the first install.
- **Peer 1, data dir exists** → join. This is every restart, so a restart can
  never bootstrap.
- **Peer 1, data dir empty but some peer answers** → join and pull a state
  transfer. This is the seed rebuilt on a new node, and it is why a lost volume
  re-syncs instead of starting a rival cluster.
- **Any other peer** → always join. It waits up to two minutes for a peer to start
  listening first, because a Galera node that finds no cluster exits, and without
  the wait a first install would be a burst of crash-restarts.

A single designated seed is what removes the race. Letting every peer bootstrap
when it sees no peers is the tempting version and it is wrong: on a first install
all peers start at once with empty data dirs and none is listening yet, so each
forms its own cluster of one and they never merge — while all of them report
healthy.

The consequence to know: **a first install needs peer 1 to be schedulable.** If
its node is unavailable the other peers wait rather than forming a cluster without
it. Once the cluster exists, peer 1 is no more special than any other peer, and
losing it costs nothing extra.

When `cluster.forceBootstrap` names a peer, that peer becomes the only
bootstrapper and peer 1 is demoted to joining — so the count never rises above
one, whatever you set.

### Recovering a fully stopped cluster

If every peer stopped **gracefully**, Galera recovers the cluster by itself on
restart. If they all died at once (power loss, a node reboot storm), no peer will
consider itself safe to bootstrap and they will wait rather than risk losing
committed transactions. Recover deliberately:

1. Find the furthest-ahead peer. On each, read `seqno` from
   `/var/lib/mysql/grastate.dat`, or if it says `-1`, start with
   `--wsrep-recover` and read the recovered position from the log.
2. Set `cluster.forceBootstrap` to **that peer's number** and
   `swarmcli charts upgrade` — it forms a new cluster from the best data.
3. Once the others have rejoined and the cluster is `Synced`, set
   `cluster.forceBootstrap: ""` and upgrade again. Leaving it set means that peer
   would form yet another cluster on its next restart.

Never force-bootstrap more than one peer, and never force-bootstrap while the
cluster is still up.

### Upgrading the image

Galera requires every peer on the same server version, and `swarmcli charts
upgrade` updates all peer services at once — so the whole cluster restarts
together. That is usually fine (a graceful full stop recovers automatically), but
it is a full outage, and it is the one time you may need the recovery procedure
above. To roll peers one at a time instead, update each service in place
(`docker service update --image mariadb:<tag> <release>_mariadb-galera-1`), waiting
for `Synced` between peers, then bump the chart to match.

Note also that a MariaDB tag change is a **series** change, not a patch: check the
release notes for on-disk format changes before upgrading a cluster you care about.

### Galera constraints

These are Galera's, not this chart's, and they break applications that assume a
standalone MariaDB:

- **InnoDB only.** MyISAM/Aria tables are not replicated.
- **Every table needs a primary key.** Rows are located by primary key when
  applying a write set; a table without one behaves unpredictably.
- Writes are certified cluster-wide, so a transaction can be rolled back on commit
  as a deadlock even when nothing local conflicted. Applications must retry.
- `LOCK TABLES`, `GET_LOCK()` and other explicit locking are not cluster-aware.

### Scaling the cluster

Change `cluster.peers` between `3` and `5` and upgrade. **Shrinking needs a manual
step**: swarmcli deploys without `--prune`, so the services for the removed peers
keep running and stay cluster members. Remove them yourself afterwards:

```bash
docker service rm <release>_mariadb-galera-4 <release>_mariadb-galera-5
```

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. Keep `monitor` at or above
`startPeriod + interval × retries`; `swarmcli charts lint` warns when it is
shorter.

`startPeriod` matters more here than in a single-node chart. A joining peer is not
`Synced` until its state transfer finishes, and if the grace period expires first,
Swarm kills it mid-transfer and restarts it into the same transfer — forever. Raise
`startPeriod` (and `monitor` with it) well past the time a full restore of your
dataset takes.
