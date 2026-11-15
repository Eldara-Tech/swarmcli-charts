# kafka

An [Apache Kafka](https://kafka.apache.org/) cluster in KRaft mode for Docker Swarm.
Every peer is a broker **and** a controller, so there is no ZooKeeper and nothing else
to run: 3 peers keep the metadata quorum through the loss of 1, and 5 through the loss
of 2. Topics default to 3 replicas with `min.insync.replicas` 2, so a producer with
`acks=all` keeps writing while one peer is down.

Each peer is its own Swarm service with one replica, its own data volume and its own
node label, because a Swarm volume lives on one node. The controller quorum is
**dynamic** ([KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes)):
a peer that comes back on an empty volume joins as a new voter and replaces its old
entry by itself (see *How the quorum forms*).

What it deploys:

- `kafka-1` … `kafka-<N>`: the peers, on the `kafka-net` overlay.
- `kafka-users` (with `auth.enabled`): a one-shot that creates the client users and
  their ACLs, then exits.
- `kafka-exporter` (with `metrics.enabled`): a Prometheus exporter on the `monitoring`
  overlay.

Combined broker+controller mode keeps the cluster to one kind of service, but Kafka's
documentation calls it unsuitable for "critical" deployments, where controllers run on
nodes of their own. This chart does not offer that split.

## Prerequisites

```bash
# The identity the peers use with each other (controller and replication traffic):
openssl rand -base64 32 | docker secret create kafka_internal_password -
# A client user, one secret per entry of auth.users (the default has one, "app"):
printf 'S3cr3t' | docker secret create kafka_app_password -
# The exporter's user (metrics.enabled, off by default):
openssl rand -base64 32 | docker secret create kafka_exporter_password -

# One node per peer, each labelled for the peer whose volume lives there.
# The chart pins peer N to node.labels.kafka-<N>:
docker node update --label-add kafka-1=true <node-a>
docker node update --label-add kafka-2=true <node-b>
docker node update --label-add kafka-3=true <node-c>
```

Put the peers on **different** nodes: three peers on one node share its fate and
provide no availability. On a single-node swarm, set `persistence.nodeLabelPrefix: ""`.
A password is read with its trailing newlines removed, and one with a newline inside it
is refused.

The image must be Kafka 4.2 or later: the quorum relies on
`controller.quorum.auto.join.enable`, which 4.2 introduced. The default image tag
defaults to `appVersion` in Chart.yaml.

## Installing

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts install kafka swarmcli-charts/kafka
```

The first install needs every peer: peer 1 creates the cluster only once every other
peer has reported an empty volume, so an install with a node down waits for it (see
*How the quorum forms*).

## Connecting

Inside the swarm, a client joins `kafka-net` and bootstraps from the shared alias
`network.clientAlias` (`kafka`), port 9092. From the metadata it then learns each
broker's own address, `<release>-kafka-<N>:9092` (the release name with `_` and `.`
replaced by `-`), and connects to the leader of every partition itself. The alias is
only the first connection, which is why it does not need to be health-aware: a client
tries every address it resolves to.

With `auth.enabled` (the default) a client authenticates with SASL/SCRAM-SHA-512:

```properties
bootstrap.servers=kafka:9092
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app" password="S3cr3t";
```

```yaml
# in your app's stack
services:
  app:
    networks: [kafka-net]
networks:
  kafka-net:
    external: true
```

Two releases on one overlay must not share `network.clientAlias`: the alias would
resolve to the brokers of both, and a client would bootstrap from whichever it reached.

### From outside the swarm (`exposure.mode`)

Nothing can load-balance a Kafka client's connections: it fetches the metadata from any
broker and then connects to the leader of each partition by the address that broker
advertises. So each broker needs an address of its own, and what sits "in front" of the
cluster routes per broker. Each broker gets a third listener (container port 9094) for
it, advertised under that address. Both modes need `auth.enabled`; the render refuses
them without it.

**`traefik`**: the [traefik](../traefik) edge terminates TLS and routes each broker's
host name to it by SNI, all on its `https` entrypoint (443):

```yaml
exposure:
  mode: traefik
traefik:
  hosts:            # one per peer, in peer order, each resolving to the edge
    - kafka-1.example.com
    - kafka-2.example.com
    - kafka-3.example.com
```

Clients use `security.protocol=SASL_SSL` with the hosts as bootstrap servers
(`kafka-1.example.com:443,kafka-2.example.com:443,…`). Traefik requests a Let's Encrypt
certificate for each host through `traefik.certResolver` (`le`, the traefik chart's), so
each name needs public DNS pointing at the edge; `""` serves Traefik's default
certificate instead. The brokers join the edge's overlay (`exposure.network`), where
anything else on it can reach their ports too, behind SASL.

**`published`**: broker N publishes `publish.basePort + N - 1` (19092, 19093, …) on the
ingress routing mesh, so every node of the swarm answers on every broker's port, and
advertises `<publish.host>:<port>`. Point `publish.host` at a TCP load balancer or a
DNS name in front of your nodes. The traffic is not encrypted; SCRAM keeps the password
itself off the wire, but use it on trusted networks only.

## Users and ACLs

With `auth.enabled`, every listener speaks SASL and Kafka's StandardAuthorizer refuses
whatever no ACL allows.

- The peers authenticate to each other as `auth.internal.username` over SASL/PLAIN, with
  the password from `auth.internal.secretName` (KRaft cannot use SCRAM between
  controllers). It is the only super user.
- Each entry of `auth.users` is a client user. The `kafka-users` one-shot creates it over
  the overlay, or resets its password, and grants it every operation on every topic,
  group and transactional id, and on the cluster. Adding a user changes only the
  one-shot, so no peer restarts.
- **Rotating a password**: create a secret under a new name and point `secretName` at
  it; the changed spec runs the one-shot again.
- **Removing a user** from the list does not delete it from Kafka. Remove it by hand:
  `kafka-configs.sh --alter --entity-type users --entity-name <u> --delete-config SCRAM-SHA-512`
  and `kafka-acls.sh --remove --allow-principal User:<u> …`, as any client user.
- **Narrower permissions**: create the user yourself with `kafka-configs.sh` and grant it
  only the ACLs it needs with `kafka-acls.sh`; leave it out of `auth.users`, whose users
  always get everything.

`auth.enabled: false` makes every listener PLAINTEXT with no authorizer: anything on the
overlay may read and write every topic.

## Metrics

Kafka serves no Prometheus metrics of its own, so `metrics.enabled` adds one
[kafka_exporter](https://github.com/danielqsj/kafka_exporter), a Kafka client that
reports brokers, partitions, replication and consumer-group lag. It carries the deploy
labels `prometheus.io/scrape=true` and `prometheus.io/port=9308` and joins the
`monitoring` overlay, where the prometheus-stack chart scrapes by default, so
Prometheus finds it by itself. The peers never join that overlay.

```bash
openssl rand -base64 32 | docker secret create kafka_exporter_password -
swarmcli charts upgrade kafka swarmcli-charts/kafka -f kafka-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

Turning it on adds a service and changes no peer, so nothing restarts. With `auth.enabled`
the exporter logs in as its own user, `metrics.username`, which the users one-shot creates
and allows to Describe topics, groups and the cluster, and nothing else. JVM, request and
controller metrics would need JMX, which this chart does not expose.

`metrics.network` must differ from `network.name`; the render fails otherwise. Turning
it off leaves the exporter running (swarmcli deploys without `--prune`): remove it with
`docker service rm <release>_kafka-exporter`.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. With the prometheus-stack chart they go in
through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/kafka/monitoring
curl -fsSL -O "$base/kafka-rules.yml" -O "$base/kafka-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.kafka=./kafka-rules.yml \
  --set-file grafana.dashboards.kafka=./kafka-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which
`--reuse-values` is safe (Eldara-Tech/swarmcli#687).

A release file and swarmcli-cd take values files only, not `--set-file`, so there both
files go in as values files: each file's content, as it is, indented under its key as a
block string. From the two files downloaded above:

```bash
mkdir -p monitoring/rules monitoring/dashboards
{ printf 'prometheus:\n  extraRules:\n    kafka: |\n'; sed 's/^./      &/' kafka-rules.yml; } > monitoring/rules/kafka.yaml
{ printf 'grafana:\n  dashboards:\n    kafka: |\n'; sed 's/^./      &/' kafka-dashboard.json; } > monitoring/dashboards/kafka.yaml
```

The dashboard stays JSON: converted to YAML it becomes a mapping, which the render
refuses (`got object, want string`). prometheus-stack's README, *Keeping your setup in
git*, shows where to list the two files.

- **Alerts** (`kafka-rules.yml`), each per release and grouped by `stack` and `job`:
  - critical: `KafkaUnreachable` (most scrapes of the exporter failing: with no broker
    answering it serves too late for the scrape timeout, so a whole-cluster outage shows
    as this one and silences the rest), `KafkaPartitionsOffline` (a partition no leader
    serves: its replicas are reported without an offset) and `KafkaPartitionsUnderMinISR`
    (fewer in-sync replicas than `min(2, replication factor)`, so `acks=all` writes are
    refused; the 2 is the chart's `min.insync.replicas`, edit it if you change that);
  - warning: `KafkaPartitionsUnderReplicated`, `KafkaBrokersMissing` (fewer brokers than
    the most seen in the last day, as the rules cannot know `cluster.peers`; it fires for a
    day after a deliberate shrink) and `KafkaConsumerGroupLagGrowing` (a group's lag rising
    across 30 minutes, judged by its trend rather than a fixed threshold; a group nobody
    consumes any more fires until its offsets expire).

  `KafkaPartitionsUnderReplicated` is derived from Strimzi's exporter rules (Apache-2.0)
  and `KafkaConsumerGroupLagGrowing` replaces their fixed-threshold lag alert; the rest are
  this chart's. An exporter that cannot reach any broker when it *starts* exits and is
  restarted by Swarm, and while it is down it is no target at all, so `KafkaUnreachable`
  covers a cluster that fails under a running exporter, not one that was down before it.
- **Dashboard** (`kafka-dashboard.json`, uid `kafka`): brokers, offline, below-min-ISR and
  under-replicated partitions, partitions off their preferred leader, messages in per
  second by topic, partitions per topic, and per consumer group its lag, lag trend,
  consumption rate and members. Pick a cluster by its `stack`, and narrow by topic or
  consumer group.

The dashboard picks a release by the `stack` label prometheus-stack's discovery puts on
every target, and the alerts carry it. Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `apache/kafka` | Image repository. Kafka 4.2 or later. |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml. |
| `cluster.peers` | `3` | Number of peers, `3` or `5`. Raising it later adds the new peers by themselves. |
| `auth.enabled` | `true` | SASL on every listener and the StandardAuthorizer. `false` = PLAINTEXT, open to the overlay. |
| `auth.internal.username` | `kafka-internal` | The peers' own identity (SASL/PLAIN), the only super user. |
| `auth.internal.secretName` | `kafka_internal_password` | External secret holding its password. |
| `auth.users` | `[{name: app, secretName: kafka_app_password}]` | Client users (SCRAM-SHA-512) with full ACLs, created by the users one-shot. |
| `persistence.enabled` | `true` | Named volume per peer. `false` = ephemeral (no volumes, no pins). |
| `persistence.volumePrefix` | `kafka-data` | Volume name prefix; peer N gets `<prefix>-<N>`. |
| `persistence.volumePaths` | `[]` | One absolute host path per peer, in peer order (writable by uid 1000); takes precedence over the prefix. |
| `persistence.nodeLabelPrefix` | `kafka` | Node-label prefix; peer N pins to `node.labels.<prefix>-<N>`. `""` = unpinned. |
| `placement.constraints` | `[]` | Extra constraints applied to every peer, in all modes. |
| `network.name` | `kafka-net` | Overlay the cluster attaches to. |
| `network.external` | `true` | Shared external overlay (auto-created). `false` = chart-managed. |
| `network.encrypted` | `false` | IPsec on a chart-managed overlay (`external: false` only). |
| `network.clientAlias` | `kafka` | DNS alias every peer shares, for bootstrapping. `""` = none. |
| `exposure.mode` | `none` | `none`, `traefik` or `published`; see *From outside the swarm*. |
| `exposure.network` | `traefik-public` | The edge's overlay (traefik mode), never created by this chart. |
| `traefik.hosts` | `[]` | One host name per peer, in peer order (traefik mode). |
| `traefik.entrypoint` | `https` | Traefik entrypoint of the TCP routers. |
| `traefik.port` | `443` | Port of that entrypoint, which the brokers advertise. |
| `traefik.certResolver` | `le` | Certificate resolver; `""` = Traefik's default certificate. |
| `traefik.constraintLabel` | `traefik-public` | Your Traefik's swarm-provider constraint label. |
| `publish.host` | `""` | Address clients outside the swarm reach the nodes by (published mode, required). |
| `publish.basePort` | `19092` | Broker N publishes `basePort + N - 1`. |
| `config` | `{}` | Extra `server.properties` entries; see *Broker settings*. |
| `heap` | `1g` | JVM heap of each peer (`-Xms` and `-Xmx`). |
| `metrics.enabled` | `false` | Add the kafka_exporter. |
| `metrics.image.repository` | `danielqsj/kafka-exporter` | Exporter image. |
| `metrics.image.tag` | pinned in `values.yaml` | Exporter image tag (a concrete pin; Renovate maintains it). |
| `metrics.username` | `exporter` | The exporter's Kafka user (Describe only). |
| `metrics.secretName` | `kafka_exporter_password` | External secret holding its password. |
| `metrics.network` | `monitoring` | Overlay shared with Prometheus. |
| `resources.limits.memory` | `""` | Per-peer memory limit, e.g. `2G`. Leave room above `heap` for the page cache. |
| `healthcheck.enabled` | `true` | Container healthcheck: the controller listener accepts connections. |
| `healthcheck.interval` | `10s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `3` | Failures before unhealthy. |
| `healthcheck.startPeriod` | `60s` | Grace period before failures count. |
| `healthcheck.monitor` | `120s` | How long an upgrade waits on each peer before the next; see *Upgrading*. |
| `stopGracePeriod` | `2m` | Time a peer gets for a controlled shutdown. |
| `labels` | `{}` | Extra deploy labels on the peers and the users one-shot. |

## Security note

- Passwords come only from external Swarm secrets and are read inside the containers at
  start, so they appear in neither the compose file, the environment nor `docker
  inspect`. A peer writes the internal one into its own `server.properties` inside the
  container; the users one-shot writes them to files only it reads, never to a command
  line.
- Traffic on `kafka-net` is not encrypted. On an overlay spanning untrusted networks,
  use a chart-managed one with `network.encrypted: true`, or create the external one
  with `--opt encrypted`.
- The internal user is a super user; the `auth.users` users can do everything an ACL can
  grant. Give applications that need less a user of their own (see *Users and ACLs*).

## Operating notes

### How the quorum forms

The image's own startup formats every volume with a static voter list, which cannot form
a dynamic quorum, so each peer runs a start script of the chart's instead. On a volume
that already holds data it simply starts the broker. On an **empty** volume it first
asks the other peers, on port 9095 of their alias, whether theirs is empty or formatted,
and waits, with no time limit, until it can decide:

- **Peer 1** formats with `--standalone`, creating the cluster as its only voter, but
  only once *every* other peer has reported an empty volume. That is a first install.
- **Any other empty peer**, and peer 1 as soon as any peer holds data, formats with
  `--no-initial-controllers` once some peer is serving, starts as an observer, and adds
  itself to the quorum (`controller.quorum.auto.join.enable`).

A peer that does not answer may be the one holding the data, so nobody guesses: a first
install with a node down waits for it, and so does a peer rebuilt while the others are
all down, until one of them is back. Each peer keeps answering on 9095 for as long as it
runs; the port is never published.

The healthcheck is the controller listener (9093), the only port Kafka opens before the
quorum has a leader. Swarm publishes a peer's alias in DNS only once its healthcheck
passes, so a check on the client port would hide every peer from every other on a first
install and the quorum would never form. A peer waiting on an empty volume passes as
well, so the others can ask it.

### A wiped or replaced peer

A peer that starts on an empty volume, because its disk was lost, the volume was
removed, or it runs ephemeral, formats with a **new directory id** and joins as an
observer. Once it has caught up, it removes its own old entry from the voter set and adds
itself under the new id, and then gets its partition replicas back from the others. It
never rejoins as the old voter with an empty log: with a static quorum such a peer can
help elect a leader that is missing data the quorum had committed, which is the problem
KIP-853 solves. Nothing needs doing by hand. While it catches up the quorum is one voter
short, so keep the other peers up.

### Losing a majority

With a majority of the peers' volumes gone, no quorum can form and the remaining peer
cannot decide anything on its own: the cluster does not start. There is no forced
bootstrap; restore the volumes from a backup, or rebuild the cluster from empty volumes
(uninstall with `--purge-volumes`, then install).

### Upgrading

Every peer carries `com.swarmcli.rollout=sequential`, so swarmcli >= 2.2.0 updates the
peers one at a time, each converged before the next, and never stops two together. A
peer counts as converged once its controller listener answers and
`healthcheck.monitor` has passed, not once it has caught up on its partitions: raise
`healthcheck.monitor` if a restarted broker needs longer to rejoin the ISR of every
partition, or producers with `acks=all` see `NotEnoughReplicas` while two peers are
behind. `stopGracePeriod` gives a peer time for a controlled shutdown, which moves its
partition leadership to the others first and spares it log recovery on the next start.

An upgrade that changes the peers together with the users one-shot or the exporter, as
an image bump does, can stop partway with `update out of sequence` on a swarmcli that
does not yet carry the fix for
[swarmcli#728](https://github.com/Eldara-Tech/swarmcli/issues/728): the rollout re-sent
a service whose own update was still settling. Run the same upgrade again; it rolls on
from where it stopped.

### Changing the peer count

Raising `cluster.peers` from 3 to 5 adds two peers on empty volumes, which join the
quorum by themselves; label their nodes first. They hold no partitions until you move
some to them with `kafka-reassign-partitions.sh`.

Lowering it does **not** take peers out of the cluster. Move their partitions away
first, then remove each from the quorum
(`kafka-metadata-quorum.sh remove-controller --controller-id <N> --controller-directory-id <id>`),
and only then lower the count and remove the services by hand (swarmcli deploys without
`--prune`).

### Broker settings

`config` adds entries to every peer's `server.properties`, after the chart's own, so it
can override the replication defaults (`default.replication.factor`, the internal topics'
factors) and anything else:

```yaml
config:
  log.retention.hours: 72
  num.partitions: 6
  log.retention.bytes: 107374182400
```

Changing it restarts every peer, one at a time. The keys the chart sets itself
(listeners, the quorum, the data directory, SASL and the authorizer, and every
`listener.name.*`) are refused, and so is anything that looks like a credential.
`min.insync.replicas` takes effect on a first install only: once the cluster exists,
Kafka keeps it at cluster level, so change it with `kafka-configs.sh --alter
--entity-type brokers --entity-default --add-config min.insync.replicas=<n>`.
