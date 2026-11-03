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

# The exporter user's password (metrics.enabled, off by default):
openssl rand -base64 32 | docker secret create mariadb_galera_exporter_password -

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

Across nodes, the overlay needs the usual Swarm ports open between them: 2377/tcp,
7946/tcp+udp and 4789/udp. Galera's own ports (4567, 4568 and 4444) and the
peers' election port (4566) travel inside the overlay. If the
overlay's MTU is above what the path between nodes carries (common on cloud
networks with an MTU of 1450 or less), small queries work but a state transfer
hangs. Create the network with a lower MTU then, alongside any other options:
`--opt com.docker.network.driver.mtu=1400`.

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
services:
  app:
    networks: [mariadb-galera-net]

networks:
  mariadb-galera-net:
    external: true
```

```
mysql://app:<password>@mariadb:3306/app
```

That is all an app in another stack needs. The overlay is attachable, and the SQL
port stays unpublished (`exposure.enabled: false`, the default).

Any peer accepts writes, so nothing needs to find a leader. The alias is also
health-aware, which is worth being precise about because it is easy to assume
otherwise: Swarm stops resolving the alias to a peer once that peer has no healthy
task, and resolves it again once a replacement passes its healthcheck. Since this
chart's healthcheck asserts the peer can actually serve, that covers a peer which
is down, one still receiving a state transfer, and one cut off from the cluster —
none of them keeps receiving client connections. A peer *donating* a transfer
stays in rotation on purpose: it remains writable throughout. So does a peer
taking part in an election while every peer is down, which reports healthy
without running `mariadbd`: there is no cluster to serve then, and its
connections are refused.

What it does not remove is the **detection lag**. A failing peer stays in the alias
for up to `healthcheck.interval × healthcheck.retries` (60s at the defaults) plus
propagation, so clients still need a pool that retries, and lowering `retries`
trades that window against false positives under load.

### The proxy endpoint (`proxy.enabled`)

Set `proxy.enabled: true` for the production endpoint MariaDB's own Galera guide
recommends: an HAProxy in front of the peers, which takes over the `mariadb` alias.

```bash
swarmcli charts install db swarmcli-charts/mariadb-galera --set proxy.enabled=true
```

It closes the lag — checks run every 2s rather than every 60s — and it routes by
Galera's *state*, not just by reachability. Each peer runs a small responder that
answers 200 only while it is `Synced`, so a peer **donating** a state transfer stops
receiving client traffic without being killed: the container healthcheck
deliberately still calls that peer healthy (see the healthcheck note below), and the
proxy simply declines to route to it. That split is the whole point — one layer
decides *alive*, the other decides *good to serve*.

The responder uses `socat`, `gosu` and the `mariadb` client already in the image, so
it adds no package and no sidecar, and it listens only inside the peer on
`proxy.checkPort` (never published). The proxy itself is stateless and runs
`proxy.replicas: 2` by default, because a single proxy in front of an HA cluster is
a single point of failure.

The proxy reaches each peer at its task address (`tasks.<release>_<peer>`, see
below), and looks it up through Docker's DNS while it runs rather than once at
start. So it starts before any peer is up, and follows a peer Swarm reschedules.

Connections are spread across all `Synced` peers by default. Galera is multi-primary,
so that is correct. But writing the same rows from several peers at once fails
certification, and the application sees deadlock errors (1213) it has to retry. An
application that does not retry them wants `proxy.routing: single-writer`, below.

Individual peers are addressable as `mariadb-galera-1`, `mariadb-galera-2`, … if
you want to pin reads to one. Those names bypass the proxy, so under single-writer
routing they are for diagnostics only, never for writes.

Peers address *each other* differently, and it is worth knowing why. They find one
another through `tasks.<release>_<peer>`, the name Swarm publishes for a service's
actual tasks, because a load-balanced service VIP is not a usable rendezvous for
group communication. But each peer *advertises* its own plain IP, read from
`/etc/hosts` at start-up — never a name. Galera has to bind its state-transfer
listener to the address a peer advertises, and a `tasks.` name does not resolve
inside the container, so advertising one makes every transfer to that peer fail
with `Host not found (authoritative)`. A peer that cannot establish its own address
refuses to start rather than join with one nothing can dial.

`exposure.enabled` publishes the SQL port in **host** mode only: every peer
publishes the same port, and several services cannot each claim it on the ingress
routing mesh. Port 3306 on a node then reaches the peer running there.

With `proxy.enabled` as well, the port is published on the proxy instead, through
the ingress mesh: port 3306 on any node reaches the proxy, which routes to a
`Synced` peer. The peers then publish nothing, so no external client can bypass
the proxy's health checks, and `exposure.mode` does not apply.

### Single-writer routing (`proxy.routing`)

`proxy.routing: single-writer` has the proxy send every connection to one peer, the
**writer**: the lowest-numbered `Synced` peer. Writes then queue on that peer's row
locks, as on a standalone MariaDB, instead of failing certification when two peers
change the same row.

```bash
swarmcli charts install db swarmcli-charts/mariadb-galera \
  --set proxy.enabled=true --set proxy.routing=single-writer
```

Every proxy replica applies the same rule, so they all pick the same writer without
sharing any state. It moves like this:

- **Failover.** A writer that stops answering, or stops being `Synced` (as when it
  donates a state transfer), is marked down after three failed checks 2s apart. Its
  connections are closed then, and new ones go to the next peer.
- **Failback.** Once a lower-numbered peer is `Synced` again and has passed two
  checks 2s apart, new connections go to it, and those still open to the peer that
  stood in are closed within the next second: about 5s in all. That second
  interruption is what keeps every replica on the same writer.
- **Existing connections** therefore never stay on a peer that is no longer the
  writer. The application sees the connection close, reconnects, and lands on the
  writer. A transaction open on a closed connection is rolled back, and only the
  application knows whether to run it again.

Each replica checks the peers on its own, so for a few seconds around a change (up
to the 6s a mark-down takes) two replicas can route to different peers.

The writer is picked by HAProxy's `balance first`. On its own that would leave
connections open to the old writer at failback, and HAProxy's `on-marked-up
shutdown-backup-sessions` covers only the return of the first server, not a peer
further down. So a small Lua task in the proxy closes them for whichever peer
returns, and logs each time it does: `single-writer: closing <n> connection(s) to
<peer>; the writer is <peer>`.

Apps must connect through `mariadb` (or `mariadb-galera-proxy` when
`network.clientAlias` is `""`). A peer's own name bypasses all of this.

## Metrics

MariaDB serves no Prometheus metrics of its own, so `metrics.enabled` adds one
[mysqld_exporter](https://github.com/prometheus/mysqld_exporter) per peer. Each
carries the deploy labels `prometheus.io/scrape=true` and `prometheus.io/port=9104`
and joins the `monitoring` overlay, which is where the prometheus-stack chart
scrapes by default — so Prometheus finds every peer by itself, with no scrape
config. Any Prometheus using Docker Swarm service discovery on those labels works
the same way.

```bash
openssl rand -base64 32 | docker secret create mariadb_galera_exporter_password -
swarmcli charts upgrade db swarmcli-charts/mariadb-galera -f db-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

Turning it on adds services and changes no peer, so it is safe on a running cluster:
nothing restarts. The exporters log in as a database user of their own, `exporter`,
which a one-shot service (`mariadb-galera-exporter-user`) creates as root over the
overlay and then exits; Galera replicates it to every peer. The user holds `PROCESS,
REPLICATION CLIENT, SLAVE MONITOR` — what the default collectors need, and no
`SELECT` on your data.

You get `mysql_up` and every numeric `SHOW GLOBAL STATUS` and `SHOW GLOBAL VARIABLES`
value, Galera's `mysql_global_status_wsrep_*` included (`wsrep_cluster_size`,
`wsrep_local_state`, `wsrep_flow_control_paused`, …), so dashboards and alert rules
written for mysqld_exporter apply as they are. Each exporter is its own service, so
the `job` label names the peer it watches (`<release>_mariadb-galera-exporter-<N>`),
and it shares that peer's node pin, so while the peers are pinned `node` is the
peer's node.

That pin also decides what a lost node looks like. Swarm cannot move the exporter
elsewhere, so its target stays and reads down (`up 0`, not `mysql_up 0`), while the
surviving peers report `mysql_global_status_wsrep_cluster_size` below
`cluster.peers`. That drop is the signal to alert on, and the rules below do:
`GaleraQuorumAtRisk` and `GaleraClusterShrunk`.

- **Rotating the password**: create a secret under a new name and point
  `metrics.secretName` at it. The changed spec runs the one-shot again, which resets
  the password; a scrape or two may read `mysql_up 0` until it has.
- **A cluster rebuilt from empty data** loses the user with everything else. Run the
  one-shot again: `docker service update --force <release>_mariadb-galera-exporter-user`.
- `metrics.network` names a different overlay. It must differ from `network.name`,
  and the render fails if it does not: the peers never join it.
- **Turning it off** leaves the services running, for the same reason as shrinking
  the cluster (swarmcli deploys without `--prune`). Remove them yourself:
  `docker service rm <release>_mariadb-galera-exporter-1 … <release>_mariadb-galera-exporter-user`.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. With the prometheus-stack chart they go in
through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/mariadb-galera/monitoring
curl -fsSL -O "$base/galera-rules.yml" -O "$base/galera-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.galera=./galera-rules.yml \
  --set-file grafana.dashboards.galera=./galera-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which `--reuse-values`
is safe (Eldara-Tech/swarmcli#687).

A release file and swarmcli-cd take values files only, not `--set-file`, so there both
files go in as values files: each file's content, as it is, indented under its key as a
block string. From the two files downloaded above:

```bash
mkdir -p monitoring/rules monitoring/dashboards
{ printf 'prometheus:\n  extraRules:\n    galera: |\n'; sed 's/^./      &/' galera-rules.yml; } > monitoring/rules/galera.yaml
{ printf 'grafana:\n  dashboards:\n    galera: |\n'; sed 's/^./      &/' galera-dashboard.json; } > monitoring/dashboards/galera.yaml
```

The dashboard stays JSON: converted to YAML it becomes a mapping, which the render
refuses (`got object, want string`). prometheus-stack's README, *Keeping your setup in
git*, shows where to list the two files.

- **Alerts** (`galera-rules.yml`): `MySQLDown`, `MySQLGaleraNotReady`,
  `MySQLGaleraOutOfSync` and `MySQLGaleraDonorFallingBehind`, derived from the
  [mysqld-mixin](https://github.com/prometheus/mysqld_exporter/tree/main/mysqld-mixin)
  (Apache-2.0); OutOfSync leaves out a donor, which keeps serving during a state
  transfer. Then one alert per cluster: `GaleraQuorumAtRisk` while fewer than 3
  members remain, so the next failure loses quorum, and `GaleraClusterShrunk` while a
  cluster has fewer members than it had in the last day. With `events.failover`
  on, four more from its controller: `GaleraEventsMisplaced`,
  `GaleraEventTakeoverFailing`, `GaleraEventRunMissed` and `GaleraEventSchedulerOff`
  (see *Event failover*).
- **Dashboard** (`galera-dashboard.json`, uid `galera`): members, Synced peers,
  primary component, peer state, flow control, write-set queues and traffic,
  certification conflicts, plus connections, queries and buffer-pool hits. Pick a
  cluster by its `stack`.

The dashboard picks a release by the `stack` label prometheus-stack's discovery puts on
every target, and the alerts carry it. Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`.

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
| `network.clientAlias` | `mariadb` | Health-aware DNS alias shared by every peer. `""` = no shared alias. |
| `proxy.enabled` | `false` | HAProxy client endpoint in front of the peers; takes over `network.clientAlias`. |
| `proxy.image.repository` | `haproxy` | Proxy image. |
| `proxy.image.tag` | `3.4` | Proxy image tag (a concrete pin; Renovate maintains it). |
| `proxy.replicas` | `2` | Proxy replicas — stateless, so more than one is safe and recommended. |
| `proxy.checkPort` | `9200` | Port the Synced responder listens on inside each peer; never published. |
| `proxy.routing` | `multi-primary` | `single-writer` = every connection to the lowest-numbered `Synced` peer. See *Single-writer routing*. |
| `proxy.resources.limits.memory` | `""` | Proxy memory limit. Rendered only when set. |
| `metrics.enabled` | `false` | One mysqld_exporter per peer, labelled for Prometheus service discovery. See *Metrics*. |
| `metrics.image.repository` | `prom/mysqld-exporter` | Exporter image. |
| `metrics.image.tag` | pinned in `values.yaml` | Exporter image tag (a concrete pin; Renovate maintains it). |
| `metrics.username` | `exporter` | Database user the exporters log in as; the chart creates it. |
| `metrics.secretName` | `mariadb_galera_exporter_password` | External secret holding that user's password. |
| `metrics.network` | `monitoring` | External overlay the exporters share with Prometheus; no peer joins it. |
| `exposure.enabled` | `false` | Publish the SQL port on each peer's own node, or on the proxy when `proxy.enabled`. |
| `exposure.port` | `3306` | Published port. |
| `exposure.protocol` | `tcp` | Published protocol. |
| `exposure.mode` | `host` | Only `host` is valid — see *Connecting*. Unused when `proxy.enabled`. |
| `events.failover.enabled` | `false` | Keep each listed event running on the writer alone. See *Event failover*. |
| `events.failover.events` | `[]` | `<schema>.<event>` per recurring event to keep on the writer. |
| `resources.limits.memory` | `""` | Per-peer memory limit, e.g. `512M`. Rendered only when set. |
| `healthcheck.enabled` | `true` | Container healthcheck — `healthcheck.sh --su-mysql --connect --galera_ready`. |
| `healthcheck.interval` | `10s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `6` | Failures before unhealthy. |
| `healthcheck.startPeriod` | `300s` | Grace period — **must exceed your worst-case state transfer**. |
| `healthcheck.monitor` | `360s` | Rollout failure window; see below. |
| `stopGracePeriod` | `5m` | How long Swarm waits for a peer to stop cleanly before killing it. |
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

With `metrics.enabled`, the exporters are the one thing on both the Galera overlay
and `metrics.network`, so what can reach Prometheus can reach port 9104 and never a
peer. `/metrics` has no authentication, and mysqld_exporter's `/probe?target=`
endpoint will log in to any address it is handed with the exporter's credentials, so
a rogue server on that overlay can capture a login attempt: give the user a long
random password, as above. The one-shot that creates it holds the root password and
stays off `metrics.network`.

`events.failover` adds a controller that logs in as root over the Galera overlay:
moving an event while keeping its definer takes `ALTER DEFINER`, which needs the
SET USER privilege. It too stays off `metrics.network`. With `metrics.enabled` a relay
that holds no secret forwards its metrics there.

## Operating notes

### How bootstrapping decides

Exactly one peer must form the cluster, once, and never again: bootstrapping a
second time beside a live cluster is a split brain. Every peer makes the same
decision before `mariadbd` starts:

- **A member answers on port 4567**, a peer running inside a cluster → join it,
  pulling a state transfer if it needs one. This is every restart into a running
  cluster, and a peer rebuilt from an empty volume.
- **No member, and this peer's `grastate.dat` says `safe_to_bootstrap: 1`** → form
  the cluster again. Galera sets that flag on the last peer to leave a cluster that
  stopped one peer at a time, so its data is the newest and at most one peer has it.
- **No member otherwise** → the peers elect one. Each serves its position on port
  4566, inside the overlay and never published: its `seqno` from `grastate.dat`, or
  from `--wsrep-recover` after a crash, or `-2` when its data dir is empty. Once
  every peer has reported, the highest `seqno` wins and ties go to the lowest peer
  number, so every peer computes the same winner. The winner forms the cluster and
  the others join it.

That last rule covers three cases:

- **First install:** every peer is empty, so peer 1 forms the cluster.
- **A peer with an empty volume during a full stop:** it reports `-2` and loses to
  every peer with data. It never seeds a cluster that the others then copy.
- **A peer missing:** no election happens until every peer has reported, because
  the missing one may hold the newest data. See *Recovering a fully stopped
  cluster*.

The wait is not optional. Swarm publishes a peer in DNS (`tasks.<release>_<peer>`)
only once its healthcheck passes. A peer passes it inside a cluster, or while it
takes part in an election, so that the others can reach it. A `mariadbd` started
with no member to reach fails with `No address to connect`, and rewrites
`grastate.dat` to `seqno: -1` on every attempt.

Letting every peer bootstrap when it sees no other is the tempting version, and it
is wrong. On a first install all peers start at once with empty data dirs, so each
forms its own cluster of one, they never merge, and all of them report healthy.
The election removes that race.

Things to know:

- **A first install needs every peer to be schedulable.** No peer forms the cluster
  until all of them have reported.
- **A peer takes part in an election, then restarts.** The winner restarts to
  bootstrap and the others restart to join, so each has a fresh healthcheck start
  period for its state transfer. Expect one completed task per peer after a first
  install or a full stop. Without persistence the winner cannot carry its win
  across a restart, so it bootstraps in place; with an empty data dir that fits in
  the healthcheck's retries.
- **While it elects, a peer reports healthy without running `mariadbd`.** Its
  exporter shows `mysql_up 0` meanwhile, and the client alias resolves to it while
  refusing connections; there is no cluster to serve then anyway.
- **`cluster.forceBootstrap` overrides the election.** The peer it names bootstraps
  unconditionally, and the others join it.

### Recovering a fully stopped cluster

If the peers stopped **one at a time**, the cluster comes back by itself: the last
peer to leave holds `safe_to_bootstrap: 1` and forms it again, and the others join.

If they stopped **together**, as after a power loss, a crash, or an upgrade forced
through a swarmcli older than this chart needs (see *Upgrading the image*), no peer
holds the flag. The peers then elect the furthest-ahead one and form the cluster
by themselves. They log `no peer is up, so the peers elect one`, and the winner
logs `the peers elected this one at seqno <N>`. After a crash `grastate.dat` shows
`seqno: -1`, so each peer first recovers its position with `--wsrep-recover`.

You step in only when the election cannot complete:

- a peer is gone for good, for example its node is lost; or
- a crashed peer's position cannot be recovered.

The peers that are left then wait, logging `waiting for a peer to come up`, rather
than risk losing committed transactions. Recover deliberately:

1. Find the furthest-ahead of the peers you have. On each peer's node, read its
   `grastate.dat`:
   `docker run --rm -v <release>_mariadb-galera-data-<N>:/d:ro busybox cat /d/grastate.dat`.
   The highest `seqno` wins. A peer that crashed shows `-1`; with that peer
   stopped, recover its position from the volume itself, using the image the
   cluster runs. The number after the last `:` is its seqno. MariaDB 12.3.3 and
   later refuse to start without a cluster address, even only to recover, so the
   command passes an empty one; `--network none` keeps it from reaching anyone:

   ```bash
   docker run --rm --network none -v <release>_mariadb-galera-data-<N>:/var/lib/mysql mariadb:<tag> \
     mariadbd --user=mysql --wsrep-on=ON --wsrep-provider=/usr/lib/galera/libgalera_smm.so \
     --wsrep-cluster-address=gcomm:// --wsrep-recover 2>&1 | grep 'Recovered position'
   ```
2. Set `cluster.forceBootstrap` to **that peer's number** and run
   `swarmcli charts upgrade`. Leave out `--wait` while a peer cannot run: the release
   cannot converge without it, but the upgrade still waits for the forced peer. The
   chart marks that peer `safe_to_bootstrap: 1`, which Galera insists on, and it
   forms a new cluster from the best data you have; the others join it.
3. Once the cluster is `Synced`, set `cluster.forceBootstrap: ""` and upgrade
   again. That restarts only the forced peer, and it rejoins the running cluster.
   Leaving it set means that peer would form yet another cluster on its next
   restart.

4. Before you bring the lost peer back, remove its data volume on its node
   (`docker volume rm <release>_mariadb-galera-data-<N>`, with its task gone). It
   then rejoins empty and takes a full state transfer. Its old data carries a
   history the forced cluster has diverged from, under the same numbering. Back in
   a running cluster it would be replaced by a state transfer too, but if it
   returns during a later full stop, its higher `seqno` wins the election and
   overwrites everything written since you forced.

Anything the lost peer held beyond the forced peer is gone either way. That is the
price of forcing, and the reason the election waits for every peer.

Never force-bootstrap more than one peer, never force-bootstrap while the cluster
is still up, and never force one while some peer still shows
`safe_to_bootstrap: 1`: that peer restarts the cluster by itself.

Upgrade only once the cluster is up. An upgrade while every peer is down still
lets them elect and form the cluster, but each peer it updates exits after the
election, inside its `healthcheck.monitor` window. Swarm counts that as a failed
update and pauses it, and `swarmcli charts upgrade` reports the rollout as stuck.
Run the upgrade again once the cluster is `Synced`.

### Upgrading the image

Galera upgrades one peer at a time: MariaDB supports a cluster running two versions
while that happens. Each peer carries the `com.swarmcli.rollout: sequential` deploy
label, so `swarmcli charts upgrade`, `rollback` and `apply` replace the peers one
at a time, in order, each healthy and past `healthcheck.monitor` before the next,
and the cluster keeps quorum throughout. An upgrade that changes every peer
therefore takes about three peer restarts plus three monitor windows. A peer that
is down is not waited for, so the recovery above still reaches every peer at once.

That needs swarmcli 2.2.0 or later, which this chart declares. An older swarmcli
refuses the chart; forced through with `--skip-compat-check`, it updates every peer
together, a full stop with no peer holding `safe_to_bootstrap: 1`.

Every peer can also restart without you changing the image. By default Swarm resolves
the series tag (`mariadb:<appVersion>`) to a digest at every deploy, so once upstream
re-tags it with a patch release, the next upgrade of any value changes every peer. Upgrade with
`--resolve-image changed`: it keeps the digest the cluster already runs while the
image is unchanged, and resolves a fresh one when you change it on purpose.

```bash
swarmcli charts upgrade db swarmcli-charts/mariadb-galera -f db-values.yaml --resolve-image changed …
```

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

### Scheduled events

Events run only where `event_scheduler` is on, so set `--event-scheduler=ON` in
`extraArgs`. Each event then runs on one peer: the one whose copy is `ENABLED`,
which is the peer it was created or last altered on. Every other peer holds it as
`SLAVESIDE_DISABLED`, and the `ORIGINATOR` column in `information_schema.EVENTS`
names the peer that runs it.

Peer N runs with `server_id` N, which keeps it that way through a state
transfer. At start-up a peer disables every event whose originator is not its own
`server_id`. A peer rebuilt from a donor therefore does not also run the donor's
events, as it would if every peer shared one `server_id`. (MariaDB's guide to
replicating *out* of a Galera cluster suggests one `server_id` on every node. This
chart sets up no such replication, and under `wsrep_gtid_mode` the GTIDs take the
bootstrap peer's `server_id` anyway.)

MariaDB never runs a missed occurrence later, and an event stops when the peer
running it stops: no other peer takes it over unless you turn on *Event failover*
below.

**Upgrading from a chart where every peer ran `server_id` 1** (mariadb-galera 0.2.5
and earlier):
an event created through peer 2 or higher is disabled when that peer restarts with
its own `server_id`, and then runs nowhere. Before upgrading, note what each peer
runs:

```sql
SELECT EVENT_SCHEMA, EVENT_NAME, DEFINER FROM information_schema.EVENTS WHERE STATUS = 'ENABLED';
```

An event that peer 1 lists as well was a copy, and running it twice is what the
new `server_id`s stop. After the upgrade, re-enable each of the others on the peer
that should run it, naming its definer: without `DEFINER=`, `ALTER EVENT` makes
the user who runs it the definer.

```sql
ALTER DEFINER = '<user>'@'<host>' EVENT <schema>.<event> ENABLE;
```

### Event failover

`events.failover` keeps each event you list running on exactly one peer, the
**writer**: the lowest-numbered `Synced` peer. That is the peer
`proxy.routing: single-writer` sends every connection to, so the events follow the
application's writes. It works without the proxy too.

```yaml
events:
  failover:
    enabled: true
    events: [app.weekly_closing, app.process_pv]
extraArgs:
  - "--event-scheduler=ON"
```

One controller replica checks every 5s. When the writer changes, it does two things
for each listed event, in this order:

1. It turns the event off on every other peer it can reach. This change is local to
   each peer, so it also reaches a peer outside the primary component, and a donor,
   which is not `Synced` but still runs its events.
2. It turns the event on on the writer. Galera replicates that, and every other peer
   then holds the event `SLAVESIDE_DISABLED`.

Both steps name the event's own definer and character set, because a bare
`ALTER EVENT` would make root the definer. Each step is logged, e.g.
`app.weekly_closing: now runs on peer 2`.

What each case comes to:

- **Writer fails.** The event moves to the next peer within about 5s. A peer cut off
  from the cluster cannot commit, so it cannot run the event twice. When it rejoins,
  it picks up the move from the others before it serves again.
- **Writer recovers** and is `Synced` again. The event moves back, turned off on the
  peer that stood in before it is turned on again.
- **Peer restart or full state transfer.** A rebuilt peer starts with the event
  disabled (see *Scheduled events*). If that peer is the writer, the controller turns
  the event on again.
- **Missed runs.** A run that fell due while the writer changed is skipped, and
  MariaDB never makes one up. The controller logs it, e.g. `app.weekly_closing was
  due at 2026-11-08 02:00:00 (Europe/Budapest) while the writer changed from peer 1
  to peer 2, and may not have run, or not to the end`. Check, and run the job by hand
  if it is needed. Write such jobs so that running them again is harmless. The
  controller measures from the last run it saw on a writer, so it cannot tell after
  it restarted itself; after an outage that took it down too, check by hand.
- **A run in progress** on the old writer is not stopped. It finishes there, and the
  new writer's first run is the next scheduled one. The two overlap only if a run
  lasts longer than its own interval, which MariaDB allows even without failover.

**Which events to list.** Every recurring event the cluster runs today. Ask the peer
that runs them, before you take a dump:

```sql
SELECT CONCAT(EVENT_SCHEMA, '.', EVENT_NAME) FROM information_schema.EVENTS
WHERE STATUS = 'ENABLED' AND EVENT_TYPE = 'RECURRING';
```

On any other peer, an enabled event and one disabled on purpose look the same
(`SLAVESIDE_DISABLED`), and so does a dump taken there. Listed events are turned on
on the writer whatever the dump said.

Only listed events are ever touched. That is how an event disabled on purpose stays
disabled: a peer holds it `SLAVESIDE_DISABLED`, exactly as it holds one that another
peer runs, so nothing can tell the two apart. List recurring (`EVERY`) events only.
The controller leaves a one-time (`AT`) event alone and logs why, because turned on
on another peer it would run a second time. To stop a listed event for good, remove
it from the list first.

With `metrics.enabled`, the controller's state reaches Prometheus through a relay on
`metrics.network`, alongside the exporters: `mariadb_galera_events_writer_peer`,
`_misplaced`, `_scheduler_off`, and the counters `_takeovers_total`, `_errors_total`
and `_missed_runs_total`. `monitoring/galera-rules.yml` alerts on them:

- `GaleraEventsMisplaced`: a listed event is missing, one-time, or not running on
  the writer alone.
- `GaleraEventTakeoverFailing`: turning an event on on the writer keeps failing.
  A turn-off that fails, as on a peer shutting down, is only logged: a peer that
  keeps the event on shows up as misplaced.
- `GaleraEventRunMissed`: a run may have been missed.
- `GaleraEventSchedulerOff`: `event_scheduler` is off on the writer.

Without metrics, the same conditions are in the controller's log
(`docker service logs <release>_mariadb-galera-events`).

**Manual takeover**, e.g. while the controller is down. On the peer that should run
the event, using the definer and character set that `information_schema.EVENTS`
shows for it:

```sql
SET SESSION character_set_client = <CHARACTER_SET_CLIENT>, collation_connection = <COLLATION_CONNECTION>;
ALTER DEFINER = '<user>'@'<host>' EVENT <schema>.<event> ENABLE;
```

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

The check asserts `--galera_ready` (able to serve), **not** `--galera_online`
(fully `Synced`). The stricter check is a trap: a peer donating a state transfer is
`Donor/Desynced` for the whole transfer while staying writable, so Swarm would kill
it once the transfer outran `interval × retries` — breaking the transfer during
exactly the recovery the cluster exists for. The trade-off is that a donor's apply
queue lags, so it can serve slightly stale reads mid-transfer; a client needing a
causal read sets `wsrep_sync_wait`.

The check runs as the `mysql` unix user (`--su-mysql`) so it authenticates through
the same `unix_socket` account used for state transfers. That is not a stylistic
choice: the default path reads credentials from a file inside the data dir, and a
state transfer replaces the data dir, so a freshly synced peer would fail its own
healthcheck forever — reporting `Access denied for user 'root'@'localhost'` while
being perfectly healthy — until Swarm killed it.

`startPeriod` matters more here than in a single-node chart. A joining peer cannot
serve until its state transfer finishes, so it fails the check for the whole
transfer; if the grace period expires first, Swarm kills it mid-transfer and
restarts it into the same transfer — forever. Raise `startPeriod` (and `monitor`
with it) well past the time a full restore of your dataset takes.

That applies to the peer *receiving* a transfer. The peer sending one is covered by
the choice of `--galera_ready` above, which is why a large donation does not put
the donor on the same clock.
