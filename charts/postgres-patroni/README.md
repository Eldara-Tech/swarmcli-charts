# postgres-patroni

A highly available **PostgreSQL cluster** on Docker Swarm: one primary and streaming
replicas, with automatic failover by [Patroni](https://github.com/patroni/patroni).
When the primary stops or crashes, a replica takes over, and clients keep using the
same endpoint.

Patroni keeps the cluster's state in a small [etcd](https://etcd.io) cluster that the
chart deploys beside it, and etcd's majority is what decides the primary. That is why
two PostgreSQL peers are already enough for failover, and why there are always three
(or five) etcd members.

Each peer and each etcd member is its own Swarm service with one replica, its own data
volume and its own node label: a Swarm volume is node-local, which is the same reason
the single-node [`postgres`](../postgres) chart pins itself. Clients connect to an
HAProxy in front of the peers that asks each peer's Patroni which role it has, so port
5432 always reaches the primary and port 5433 the replicas.

The image is Percona's
[`percona-distribution-postgresql`](https://hub.docker.com/r/percona/percona-distribution-postgresql),
which ships Patroni and its etcd support beside the server. Use [`postgres`](../postgres)
instead if one database and the occasional restart are fine. Replication here is
asynchronous by default, so read *Failover and what it costs* before relying on it.

## Prerequisites

```bash
# Three passwords, as external Swarm secrets:
printf 'S3cr3t' | docker secret create postgres_patroni_superuser_password -
openssl rand -base64 32 | docker secret create postgres_patroni_replication_password -
openssl rand -base64 32 | docker secret create postgres_patroni_restapi_password -

# One node per peer, each labelled for the peer whose volume lives there.
# The chart pins peer N, and etcd member N, to node.labels.postgres-patroni-<N>:
docker node update --label-add postgres-patroni-1=true <node-a>
docker node update --label-add postgres-patroni-2=true <node-b>
docker node update --label-add postgres-patroni-3=true <node-c>
```

Put each label on a **different** node: three peers on one node share its fate and give
you no availability. With `cluster.peers: 2` you still need label 3, for etcd member 3.
On a single-node swarm (development) set `persistence.nodeLabelPrefix: ""` to schedule
everything unpinned instead.

The `postgres-patroni-net` overlay, which app stacks join to reach the proxy, is created
for you at install. etcd, the peers and their replication travel on a second,
stack-internal overlay (see *Security note*). Across nodes, Swarm needs its usual ports
open between them: 2377/tcp, 7946/tcp+udp and 4789/udp, and IP protocol 50 (ESP) as well
for `network.encrypted`.

## Installing

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts install db swarmcli-charts/postgres-patroni
```

The cluster initialises itself on the first install. etcd forms its quorum, one peer wins
Patroni's race to initialise the database, and the others copy it with `pg_basebackup`
and start streaming. There is no second step and no flag to unset afterwards. While etcd
is still forming, the peers log `waiting on etcd` and a few `Failed to get list of
machines` errors; those stop once it has a quorum.

## Connecting

Apps join the overlay and connect to **`postgres`**, the proxy's alias on it:

```yaml
networks:
  postgres-patroni-net:
    external: true
```

```
postgresql://postgres:<password>@postgres:5432/postgres   # the primary: reads and writes
postgresql://postgres:<password>@postgres:5433/postgres   # a replica: reads only
```

Port 5432 routes to whichever peer is the primary, and port 5433 spreads connections over
the running replicas. The proxy decides by asking each peer's Patroni REST API
(`/primary`, `/replica`) every 3 seconds. After a failover it closes the connections it
still holds to the old primary, so clients see an error and reconnect, landing on the new
one. Use a pool that retries.

The superuser is the only role the chart creates. For an app that should hold less than
superuser rights, create a least-privilege role once. It has to go to the primary, so send
it through the proxy, from any peer (the proxy's service name resolves on the
stack-internal overlay too):

```bash
docker exec -i $(docker ps -q -f label=com.docker.swarm.service.name=db_postgres-patroni-1) \
  sh -c 'PGPASSWORD="$(cat /run/secrets/postgres_patroni_superuser_password)" \
    psql -h db_postgres-patroni-proxy -U postgres' <<'SQL'
CREATE ROLE app LOGIN PASSWORD 'app-pw';
CREATE DATABASE app OWNER app;
SQL
```

Two releases on one shared overlay need different `network.clientAlias` values, or the
alias resolves to both proxies and clients are spread over two unrelated databases.

`exposure.enabled` publishes both ports on every node through the ingress routing mesh, on
`exposure.port` (default 5432) and `exposure.replicaPort` (default 5433).

## Failover and what it costs

- **The primary stops** (an upgrade, a drain, `docker service scale … =0`): Patroni shuts
  PostgreSQL down cleanly, streams the last WAL to the replicas, and hands the leader key
  over. Writes through the proxy resume on a replica within about 10 seconds, and nothing
  that was committed is lost. The old primary rejoins as a replica when it comes back.
- **The primary crashes** or its node disappears: the leader key expires after `ttl` (30
  s), the most up-to-date replica takes over, and the old primary rejoins with `pg_rewind`.
  Replication is **asynchronous**, so the last transactions the old primary committed but
  had not yet sent are lost. Patroni will not promote a replica more than 1 MB of WAL
  behind (`maximum_lag_on_failover`); if no replica qualifies, the cluster waits for the
  old primary rather than lose more. For zero-loss failover, turn on Patroni's
  synchronous mode (see *Changing Patroni and PostgreSQL settings*), at the cost of a
  round-trip per commit.
- **etcd loses its quorum** (two of three members down): `failsafe_mode` keeps the
  primary writable as long as it can still reach every other peer's REST API, rather than
  demoting it. A peer that is down as well ends that, and the primary turns read-only
  until etcd is back.
- **A replica is lost**: nothing for clients but one replica fewer on 5433. One that comes
  back with an empty volume copies the primary again by itself.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `percona/percona-distribution-postgresql` | Image repository; it must ship Patroni with etcd support. |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml. |
| `cluster.name` | `postgres-patroni` | Patroni's cluster name (its scope), under which it keeps its keys in etcd. |
| `cluster.peers` | `3` | Number of PostgreSQL peers, 2 to 5. |
| `etcd.members` | `3` | Number of etcd members, `3` or `5`. Fixed at install. |
| `etcd.image.repository` | `gcr.io/etcd-development/etcd` | etcd image. |
| `etcd.image.tag` | pinned in `values.yaml` | etcd image tag (a concrete pin; Renovate maintains it). |
| `etcd.generation` | `1` | Disaster recovery only: bumped when etcd is rebuilt from empty volumes. See below. |
| `etcd.rejoinMembers` | `[]` | Disaster recovery only: members that join the running etcd cluster. See below. |
| `etcd.resources.limits.memory` | `""` | Per-member memory limit. Rendered only when set. |
| `auth.superuser.username` | `postgres` | The superuser Patroni creates when it initialises the cluster. |
| `auth.superuser.secretName` | `postgres_patroni_superuser_password` | External secret holding its password. |
| `auth.replication.username` | `replicator` | The role replicas stream with. |
| `auth.replication.secretName` | `postgres_patroni_replication_password` | External secret holding its password. |
| `auth.restApi.username` | `patroni` | Basic-auth user of the Patroni REST API's write endpoints. Not a database role. |
| `auth.restApi.secretName` | `postgres_patroni_restapi_password` | External secret holding its password. |
| `persistence.enabled` | `true` | Named volumes. `false` = ephemeral (no volumes, no pins); CI and demos only. |
| `persistence.volumePrefix` | `postgres-patroni-data` | Peer volume name prefix; peer N gets `<prefix>-<N>`. |
| `persistence.etcdVolumePrefix` | `postgres-patroni-etcd` | etcd volume name prefix; member N gets `<prefix>-<N>`. |
| `persistence.volumePaths` | `[]` | One absolute host path per peer, in order; takes precedence over the prefix. Owned by uid 26. |
| `persistence.etcdVolumePaths` | `[]` | One absolute host path per etcd member, in order; takes precedence over the prefix. |
| `persistence.nodeLabelPrefix` | `postgres-patroni` | Peer N and member N pin to `node.labels.<prefix>-<N>`. `""` = unpinned. |
| `placement.constraints` | `[]` | Extra constraints applied to every service, in all modes. |
| `network.name` | `postgres-patroni-net` | Overlay clients reach the proxy on. |
| `network.external` | `true` | `false` = chart-managed overlay, reachable only inside this stack. |
| `network.encrypted` | `false` | IPsec on the overlays the chart creates: the internal one, and `network.name` when `external: false`. |
| `network.clientAlias` | `postgres` | The proxy's DNS alias on `network.name`. `""` = none. |
| `exposure.enabled` | `false` | Publish the proxy's ports on every node through the ingress mesh. |
| `exposure.port` | `5432` | Host port reaching the primary. |
| `exposure.replicaPort` | `5433` | Host port reaching the replicas. |
| `proxy.image.repository` | `haproxy` | Proxy image. |
| `proxy.image.tag` | pinned in `values.yaml` | Proxy image tag (a concrete pin; Renovate maintains it). |
| `proxy.replicas` | `2` | Proxy replicas — stateless, so more than one is safe and recommended. |
| `proxy.resources.limits.memory` | `""` | Proxy memory limit. Rendered only when set. |
| `postgresql.parameters` | `{}` | PostgreSQL settings, `key: value`. See *Changing Patroni and PostgreSQL settings*. |
| `resources.limits.memory` | `""` | Per-peer memory limit, e.g. `1G`. Rendered only when set. |
| `healthcheck.enabled` | `true` | Container healthcheck — Patroni's `/liveness`. |
| `healthcheck.interval` | `10s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `3` | Failures before unhealthy. |
| `healthcheck.startPeriod` | `60s` | Grace period before failures count. |
| `healthcheck.monitor` | `2m` | Rollout failure window; see below. |
| `stopGracePeriod` | `2m` | How long Swarm waits for a peer to stop cleanly before killing it. |
| `labels` | `{}` | Extra deploy labels on every service. |

## Security note

Passwords are read from the mounted secret files when each peer starts, so the plaintext
never lands in the compose file or `docker inspect`, only in the Patroni process's
environment. Secrets are always external and operator-created; the chart never creates
one.

etcd has no authentication, and neither have the Patroni REST API's read endpoints, so
anything that can write to etcd can choose the primary. Both are reachable only on the
stack-internal overlay `<release>_cluster`. App stacks on the client overlay reach the
proxy and nothing behind it. The internal overlay is not attachable, so no `docker run`
container can join it; a Swarm service still can, by declaring it, which takes the same
manager access that could read the secrets anyway. The REST API's write endpoints
(switchover, restart, reinitialise, configuration) need `auth.restApi`'s password even
from there.

Inside the cluster, every role authenticates with SCRAM over the network. Local
connections inside a peer's container are trusted, since anything that can run a process
there can read the secrets anyway.

Replication carries every row written, and on a multi-node swarm it crosses the
stack-internal overlay between nodes. Set `network.encrypted: true` unless the network
between nodes is already trusted. Client connections are not TLS-encrypted by the chart.

## Operating the cluster

The `patronictl` commands below run inside a peer, and any running peer will do:

```bash
peer() { docker ps -q -f label=com.docker.swarm.service.name=db_postgres-patroni-$1 | head -1; }
```

### Inspecting

```bash
docker exec $(peer 1) patronictl list
```

shows each peer's role (`Leader` or `Replica`), state (`running`, `streaming`) and lag.
etcd's own view:

```bash
docker exec $(docker ps -q -f label=com.docker.swarm.service.name=db_postgres-patroni-etcd-1) \
  etcdctl endpoint status --cluster -w table
```

### Commands that need the REST API password

`switchover`, `restart`, `reinit` and the others that change a peer go through the REST
API, so they need its credentials. The chart keeps them out of Patroni's configuration
file on purpose, so pass both:

```bash
patroni_ctl() {
  docker exec -i $(peer 1) sh -c 'PATRONI_RESTAPI_USERNAME=patroni \
    PATRONI_RESTAPI_PASSWORD="$(cat /run/secrets/postgres_patroni_restapi_password)" \
    patronictl "$@"' patronictl "$@"
}
patroni_ctl switchover --candidate postgres-patroni-2 --force   # move the primary
patroni_ctl reinit postgres-patroni postgres-patroni-3 --force  # re-copy one replica
```

Without them the command fails with `401, no auth header received`.

### Changing Patroni and PostgreSQL settings

`postgresql.parameters` is written into each peer's own configuration, and applied as the
peers roll one at a time on the next upgrade. It is also the cluster's starting
configuration on a first install.

A few settings must be equal on every peer, so once the cluster exists Patroni takes them
only from etcd: `max_connections`, `max_wal_senders`, `max_replication_slots`,
`max_worker_processes`, `max_prepared_transactions`, `max_locks_per_transaction`,
`wal_level`, `wal_keep_size`, `wal_log_hints`, `track_commit_timestamp` and
`hot_standby`. The same goes for Patroni's own cluster-wide settings, synchronous mode
among them. Change those in etcd, then restart the peers that report a pending restart:

```bash
docker exec $(peer 1) patronictl edit-config --force -s 'postgresql.parameters.max_connections=200'
docker exec $(peer 1) patronictl edit-config --force -s 'synchronous_mode=true'
patroni_ctl restart postgres-patroni --pending --force
```

### Upgrading the image

Every peer and etcd member carries `com.swarmcli.rollout=sequential`, so `swarmcli charts
upgrade` replaces them one at a time, each healthy for `healthcheck.monitor` before the
next starts. Replicas restart without clients noticing; each restart of the current
primary is a switchover of about 10 seconds, and as the primary moves between peers during
the rollout it can happen more than once. Run `patronictl list` afterwards.

That needs swarmcli 2.2.0 or newer, which `swarmcliVersion` enforces; a plain `docker
stack deploy` restarts everything at once.

Only minor versions upgrade in place. `appVersion` in Chart.yaml is the major series, and
Renovate holds a new series for approval because a newer server refuses the old data
directory: every peer would then fail to start until the data is migrated (`pg_dump` and a
restore into a fresh release). Treat a major upgrade as planned maintenance.

### A peer rebuilt from an empty volume

Nothing to do: a peer whose data directory is empty copies the primary with
`pg_basebackup` and starts streaming. Its healthcheck, Patroni's `/liveness`, passes for
the whole copy on purpose, so Swarm does not kill a long one partway. To re-copy a replica
that still has data, use `reinit` (above).

### A fully stopped cluster

Start the peers again (`swarmcli charts upgrade`, or `docker service scale` each back to 1).
Patroni elects the most up-to-date peer as the primary and the others follow it. There is
no bootstrap flag to set.

### Replacing an etcd member

An etcd member whose data is gone for good (its volume deleted, its node replaced) cannot
start again on its own: started empty beside the running members, it fails rather than
join them. With the other members still a majority, replace it. For member 3 of release
`db`:

```bash
e1=$(docker ps -q -f label=com.docker.swarm.service.name=db_postgres-patroni-etcd-1 | head -1)
docker service scale db_postgres-patroni-etcd-3=0
# On member 3's node, if it still exists. Swarm keeps the stopped task's container,
# which holds the volume, so remove that first:
docker rm -f $(docker ps -aq -f label=com.docker.swarm.service.name=db_postgres-patroni-etcd-3)
docker volume rm db_postgres-patroni-etcd-3
docker exec $e1 etcdctl member list                     # note member 3's ID
docker exec $e1 etcdctl member remove <id>
docker exec $e1 etcdctl member add postgres-patroni-etcd-3 --peer-urls=http://db-etcd-3:2380
swarmcli charts upgrade db swarmcli-charts/postgres-patroni --reuse-values \
  --version <installed version> --set 'etcd.rejoinMembers={3}'
```

The peer URL is `http://<release>-etcd-<N>:2380`, with any `_` or `.` in the release name
turned into `-`. `etcd.rejoinMembers` makes member 3 join the running cluster instead of
forming a new one. etcd reads it only while the member's data directory is empty, so it
can stay set afterwards, until etcd is rebuilt from nothing (below).

This is also why `persistence.enabled: false` is for demos only: there, an etcd member
that loses its task loses its data.

### etcd lost its majority for good

With two of three members' data gone, the runbook above cannot work, because `member add`
needs a majority. Rebuild etcd from nothing instead, **while the primary is still
running**. `failsafe_mode` keeps it writable as long as every peer is up:

```bash
for m in 1 2 3; do docker service scale db_postgres-patroni-etcd-$m=0; done
# On each member's node: its stopped container first, which holds the volume.
docker rm -f $(docker ps -aq -f label=com.docker.swarm.service.name=db_postgres-patroni-etcd-<N>)
docker volume rm db_postgres-patroni-etcd-<N>
# Then, with the next etcd.generation (1 unless you have done this before):
swarmcli charts upgrade db swarmcli-charts/postgres-patroni --reuse-values \
  --version <installed version> --set etcd.generation=2 --set 'etcd.rejoinMembers={}'
```

The members form a new, empty etcd cluster. The new `etcd.generation` gives it a new
cluster ID, and that is not optional: Patroni remembers the old cluster's raft term and
refuses a cluster with the same ID and a lower term as one that fell behind, so without
it the peers never use the new etcd. `etcd.rejoinMembers` is cleared because every
member must start as new. The running primary then takes the leader key again and writes
back the rest of Patroni's state, `edit-config` changes included, and the replicas follow
it. Do it before any peer restarts: a peer cannot start while etcd is
down, and a missing peer makes the primary give up `failsafe_mode` and turn read-only.
This chart has no tested procedure for the case where no peer is still running.

### Scaling

Change `cluster.peers` and upgrade. A new peer copies the primary and starts streaming;
the other peers are not restarted, and the proxy adds it.
**Shrinking needs a manual step**: swarmcli deploys without `--prune`, so the services for
the removed peers keep running and stay Patroni members, while the proxy no longer lists
them. One of them could then become the primary that no client can reach. Remove them
right after the upgrade:

```bash
docker service rm db_postgres-patroni-4 db_postgres-patroni-5
```

`etcd.members` is fixed at install.

### Why `healthcheck.monitor` exists

Swarm only counts a task failure against a rollout during `update_config.monitor`, measured
from task creation, and its default is 5 seconds. A peer that starts, passes nothing for
`startPeriod` and only then fails would otherwise count as a successful update. `monitor`
must therefore cover `startPeriod + interval × retries` (90 s at the defaults), and swarmcli
waits it out on each peer before it rolls the next one.

## Not included

Backups (the image ships pgBackRest, but nothing configures it) and metrics are not part of
this chart yet.
