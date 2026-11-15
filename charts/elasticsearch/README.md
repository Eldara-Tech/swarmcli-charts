# elasticsearch

Elasticsearch, with Kibana in front of it, for Docker Swarm. Security is always on: every request
authenticates, and every password comes from an external Swarm secret. It runs as one node by
default, or as a 3- or 5-node cluster with TLS between the nodes. Each node is a Swarm service of
its own (`elasticsearch-1` … `elasticsearch-N`) with its own volume and node pin. Kibana logs in as
the built-in `kibana_system` user and is routed through Traefik by default. Elasticsearch publishes
no port by default; applications reach it over a shared overlay.

## Prerequisites

1. **Kernel setting, on every node that runs Elasticsearch.** Elasticsearch needs
   `vm.max_map_count` of at least 262144. A cluster refuses to start below that, and a single
   node runs badly:

   ```bash
   sudo sysctl -w vm.max_map_count=262144
   echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
   ```

2. **Label the node(s) that hold the data.** Swarm volumes are node-local, so node N is pinned to
   the Swarm node labelled `elasticsearch-data-<N>`. In a cluster, label a **different** node for
   each one. Three nodes on one host share its fate, so they give you no availability:

   ```bash
   docker node update --label-add elasticsearch-data-1=true <node-a>
   # cluster.nodes: 3 only:
   docker node update --label-add elasticsearch-data-2=true <node-b>
   docker node update --label-add elasticsearch-data-3=true <node-c>
   ```

3. **Create the secrets.** The chart checks that these exist but never creates them. Each password
   needs at least 6 characters:

   ```bash
   openssl rand -base64 24 | docker secret create elasticsearch_elastic_password -
   openssl rand -base64 24 | docker secret create kibana_system_password -   # kibana.enabled
   openssl rand -hex 32    | docker secret create kibana_encryption_key -    # kibana.encryptionKey.enabled
   ```

   You choose the `kibana_system` password; the chart's `kibana-setup` job sets it in
   Elasticsearch for you. **Keep the encryption key.** Kibana uses it to encrypt saved objects
   (alerting connectors store credentials in them), so if you change it, Kibana can no longer read
   them.

4. **TLS certificates** (`tls.enabled`, which a cluster requires). See
   [TLS](#tls) for how to generate them.

5. Kibana in `traefik` or `none` mode needs the `traefik-public` overlay. The traefik chart creates
   it (this chart only checks for it). swarmcli creates the `elasticsearch-net` overlay if it is
   missing.

For an ephemeral instance, set `persistence.enabled: false` and skip step 2. The node pins are
dropped along with the volumes.

## Installing

One node, with Kibana at `https://kibana.example.com` through the traefik chart:

```bash
swarmcli charts install elasticsearch swarmcli-charts/elasticsearch \
  --set kibana.ingress.host=kibana.example.com
```

A three-node cluster, once the TLS secrets exist:

```bash
swarmcli charts install elasticsearch swarmcli-charts/elasticsearch \
  --set cluster.nodes=3 --set tls.enabled=true \
  --set kibana.ingress.host=kibana.example.com
```

Log in to Kibana as `elastic` with the password from `elasticsearch_elastic_password`. After that,
create named users for people in **Stack Management → Users** instead of sharing the superuser.

The first start takes a minute or two. A cluster node waits up to 30 seconds for the others before
it opens its REST API, and Kibana then sets up its indices. `swarmcli charts status elasticsearch`
shows the services as they converge. `kibana-setup` shows as complete once it has done its job.

Without the traefik chart, set `kibana.exposure.mode=published` to serve Kibana on port 5601 of
every node (plain HTTP), or `none` to reach it from your own proxy on `traefik-public` at
`<release>_kibana:5601`.

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` lists every `external:` secret and network the release references. A default
install needs:

```yaml
- name: elasticsearch     # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [elasticsearch_elastic_password, kibana_system_password, kibana_encryption_key]
    networks: [elasticsearch-net, traefik-public]
```

`tls.enabled` adds `elasticsearch_tls_ca`, `elasticsearch_tls_cert` and `elasticsearch_tls_key`.
Each entry must match the actual name, so if you override a name in values, change it here too.

## Connecting

Attach your application to the `elasticsearch-net` overlay. Each node is reachable at
**`http://<release>_elasticsearch-<N>:9200`** (https with `tls.http`). For the install above, that
is `http://elasticsearch_elasticsearch-1:9200`. Every node also answers to the shared alias
`elasticsearch` (`network.clientAlias`). That alias is convenient for a single node, but it
resolves to every node without checking their health. In a cluster, give your client the list of
nodes, which most Elasticsearch clients accept, so it can fail over on its own. If two releases of
this chart share the overlay, the alias is ambiguous: give them different aliases, or set it to
`""`.

Authenticate as a user you created for the application. Do not use `elastic` for this. A role with
only the indices the application needs is enough:

```bash
curl -u elastic:$PW http://elasticsearch_elasticsearch-1:9200/_security/user/myapp \
  -H 'Content-Type: application/json' \
  -d '{"password":"…","roles":["myapp_writer"]}'
```

To reach the REST API from outside the overlay, set `exposure.enabled: true`. `mode: ingress`
binds the port on every Swarm node. A cluster needs `mode: host`, because every node publishes the
same port. Restrict that port with a firewall, and turn on `tls.http`, or the passwords cross the
network in plain text.

## TLS

`tls.enabled` turns on TLS between the nodes (transport, port 9300). `tls.http` (on by default
once TLS is enabled) also serves the REST API over HTTPS. Kibana and the setup job get the CA
automatically; your applications need it too. A **cluster requires** `tls.enabled`, because
Elasticsearch will not form a multi-node cluster with security on and the transport layer
unencrypted. A single node works without it.

All nodes can share one certificate. With the default `tls.verificationMode: certificate`, each
side checks that the certificate chains to your CA and ignores the host name, so the certificate
does not need to name any node. To generate a CA and a certificate:

```bash
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj /CN=elasticsearch-ca \
  -keyout ca.key -out ca.crt
openssl req -newkey rsa:2048 -nodes -subj /CN=elasticsearch -keyout node.key -out node.csr
printf 'subjectAltName=DNS:elasticsearch,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n' > ext.cnf
openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 \
  -extfile ext.cnf -out node.crt

docker secret create elasticsearch_tls_ca   ca.crt
docker secret create elasticsearch_tls_cert node.crt
docker secret create elasticsearch_tls_key  node.key
```

The certificate needs both `serverAuth` and `clientAuth`, because each node is a client of the
others. Keep `ca.key` off the swarm. If you would rather use Elastic's own tool,
`elasticsearch-certutil ca --pem` and `elasticsearch-certutil cert --pem` (run inside the
Elasticsearch image) produce the same files.

`tls.verificationMode: full` also checks host names. Kibana connects to
`<release>_elasticsearch-<N>`, so with `full` the certificate must list those names as DNS SANs.

To rotate a certificate, create the new files as secrets under **new names** (Swarm secrets cannot
be changed) and point `tls.*SecretName` at them. The next upgrade then restarts each node in turn.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `docker.elastic.co/elasticsearch/elasticsearch` | Elasticsearch image |
| `image.tag` | `""` | Defaults to `appVersion` in Chart.yaml |
| `cluster.name` | `""` | `cluster.name`; `""` uses the release name |
| `cluster.nodes` | `1` | `1`, `3` or `5`. Fixed at install (see [Scaling](#scaling)) |
| `auth.elasticPasswordSecretName` | `elasticsearch_elastic_password` | External secret: the `elastic` superuser's password |
| `tls.enabled` | `false` | TLS between the nodes; required with `cluster.nodes > 1` |
| `tls.http` | `true` | Also serve the REST API over HTTPS (with `tls.enabled`) |
| `tls.verificationMode` | `certificate` | `certificate`, `full` or `none` (see [TLS](#tls)) |
| `tls.caSecretName` / `certSecretName` / `keySecretName` | `elasticsearch_tls_ca` / `_cert` / `_key` | External secrets: PEM CA, node certificate, unencrypted key |
| `heapSize` | `""` | JVM heap, e.g. `2g`; `""` lets Elasticsearch size it (half the memory limit, or half the host) |
| `persistence.enabled` | `true` | One volume per node at `/usr/share/elasticsearch/data`; `false` = ephemeral, no pins |
| `persistence.volumePrefix` | `elasticsearch-data` | Node N's named volume is `<prefix>-<N>` |
| `persistence.volumePaths` | `[]` | One absolute host path per node (bind mount, `chown 1000:0`); overrides `volumePrefix` |
| `persistence.nodeLabelPrefix` | `elasticsearch-data` | Node N is pinned to `node.labels.<prefix>-<N> == true`; `""` = unpinned |
| `placement.constraints` | `[]` | Extra constraints on every node, always applied |
| `network.name` | `elasticsearch-net` | Overlay that the nodes, Kibana and your applications share |
| `network.external` | `true` | `false` = a chart-managed overlay, reachable only inside this stack |
| `network.clientAlias` | `elasticsearch` | Shared alias every node answers to; `""` = none |
| `exposure.enabled` | `false` | Publish the REST API (9200) |
| `exposure.port` | `9200` | Published port |
| `exposure.mode` | `ingress` | `ingress` or `host`; a cluster needs `host` |
| `resources.limits.memory` | `""` | Memory limit per node, e.g. `4G` |
| `stopGracePeriod` | `2m` | Time a node is given for a clean shutdown |
| `healthcheck.*` | on, 10s/5s/6, 120s start, `monitor: 3m` | The REST API answers; see [Healthchecks](#healthchecks) |
| `settings` | `{}` | Extra Elasticsearch settings (`key: value`, use `-f`); settings the chart manages are refused |
| `labels` | `{}` | Extra deploy labels on every node |
| `kibana.enabled` | `true` | Deploy Kibana and the `kibana-setup` job |
| `kibana.image.repository` | `docker.elastic.co/kibana/kibana` | Kibana image |
| `kibana.image.tag` | `""` | Defaults to `appVersion` in Chart.yaml (it must match Elasticsearch's version) |
| `kibana.replicas` | `1` | More than one needs `kibana.encryptionKey.enabled` |
| `kibana.passwordSecretName` | `kibana_system_password` | External secret: the `kibana_system` password, set by `kibana-setup` |
| `kibana.encryptionKey.enabled` | `true` | Use a fixed encryption key for sessions, saved objects and reporting |
| `kibana.encryptionKey.secretName` | `kibana_encryption_key` | External secret: at least 32 characters |
| `kibana.exposure.mode` | `traefik` | `traefik`, `published` or `none` |
| `kibana.exposure.network` | `traefik-public` | Edge overlay (traefik and none modes); never created by this chart |
| `kibana.ingress.host` | `kibana.example.com` | Public host: Traefik rule and `server.publicBaseUrl` |
| `kibana.ingress.tls` | `true` | Public endpoint is HTTPS: TLS router, redirect, Secure cookie |
| `kibana.traefik.*` | in-repo traefik chart | `certResolver: le`, entrypoints `http`/`https`, `constraintLabel: traefik-public`, `redirectMiddleware: https-redirect` |
| `kibana.publish.port` / `mode` | `5601` / `ingress` | Published port (published mode, plain HTTP) |
| `kibana.healthcheck.*` | on, 15s/5s/5, 120s start, `monitor: 4m` | Kibana's HTTP server answers |
| `kibana.resources.limits.memory` | `""` | Memory limit, e.g. `2G` |
| `kibana.settings` | `{}` | Extra Kibana settings passed as `--key=value`; settings the chart manages are refused |
| `kibana.placement.constraints` | `[]` | Constraints on Kibana and `kibana-setup` |
| `kibana.labels` | `{}` | Extra deploy labels on Kibana |

Traefik defaults: they match the traefik chart in this repository. If you run your own Traefik,
override `kibana.traefik.*`. A router bound to an entrypoint your Traefik does not define is
silently dropped.

## Security notes

- **Passwords are kept out of the stack.** `docker inspect` shows only secret paths. In
  Elasticsearch, the image reads the `elastic` password from its file
  (`ELASTIC_PASSWORD_FILE`). Kibana puts its password and key into its keystore at start, so they
  appear in neither its process list nor its environment. (The image would otherwise turn
  environment variables into command-line flags.) `kibana-setup` reads both passwords from files
  and sends them only in the HTTP request.
- **The `elastic` password comes from the secret on every start**, until someone changes it
  through the API (Kibana's user management, `_security/user/elastic/_password`). From then on,
  Elasticsearch keeps the password it stored and ignores the secret. To rotate it with the chart,
  create a secret under a new name and point `auth.elasticPasswordSecretName` at it.
- **`elasticsearch-net` is shared.** Anything attached to it can reach every node's port 9200,
  and port 9300 too. Every request still needs a password, and in a cluster 9300 also requires a
  certificate from your CA. Without `tls.http`, though, passwords cross the overlay in plain text.
  Set `network.external: false` if only Kibana should reach Elasticsearch.
- **Do not put Kibana's encryption key in values** or labels. It belongs in its secret only.

## Operating notes

### How a cluster forms

Each node finds the others at `tasks.<release>_elasticsearch-<N>`, Swarm's DNS name for that
node's container. It advertises the address Docker wrote for it in `/etc/hosts`, never a name.
On the very first start, the nodes run with `cluster.initial_master_nodes` listing every node, and
Elasticsearch forms the cluster once a majority of them agree. Because this takes a majority, a
node that comes back with an empty volume cannot form a new cluster by itself. It joins the one
that is running.

When a node first sees an elected master, it writes `.swarmcli-joined` to its data directory.
Later starts leave `cluster.initial_master_nodes` out, as Elastic recommends. Without that step,
Elasticsearch warns on every start that the setting risks data loss. If a node loses its data, the
marker goes with it, and the node starts again as an empty one.

One case Elasticsearch cannot protect against: if a **majority** of nodes lose their data at the
same moment, they form a new, empty cluster. The node that still has the data refuses to join it
(`locked into cluster UUID`). Its data is intact, so recover it from a snapshot or with Elastic's
[`elasticsearch-node`](https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/node-tool)
tool rather than wiping it.

### Healthchecks

A node is healthy once its REST API answers at all, a `401` included. The check does not wait for
the cluster to be green or a master to be elected. Swarm publishes a node in DNS only once it is
healthy, and the nodes find each other through DNS, so a check that required the cluster could
never pass on a first start. Kibana is healthy once its HTTP server answers, including the `503`
"not ready yet" it serves while it migrates saved objects after an upgrade. A check that killed
Kibana during a long migration would restart that migration forever. To find out whether the
cluster is actually usable, query `_cluster/health`.

`healthcheck.monitor` must cover `startPeriod + interval × retries`. Swarm only counts a failure
within that window against a rollout, so a shorter window lets a broken deploy report success.

### Upgrading

Kibana and Elasticsearch both follow the chart's `appVersion`. Renovate keeps that current, and the
two images are released together. With swarmcli ≥ 2.2.2, the nodes of a cluster carry
`com.swarmcli.rollout=sequential`, so `swarmcli charts upgrade` restarts them **one at a time**,
waiting for each to become healthy before the next. An upgrade therefore never stops every node at
once. "Healthy" means only that the REST API answers. If you have many shards and want the cluster
green before the next node restarts, roll the upgrade yourself, node by node, and check
`_cluster/health` in between. For a single node, an upgrade restarts it, with a short outage.

Elasticsearch upgrades one major version at a time and only from the last minor of the previous
major. Read Elastic's upgrade notes before you change `image.tag` across a major.

### Scaling

`cluster.nodes` is fixed at install:

- **1 → 3 is not supported in place.** Nodes 2 and 3 start empty and make up a majority of the new
  master list, so they can form a cluster of their own next to node 1. Install a new release and
  restore a snapshot into it instead.
- **3 → 5** is safe. Two empty nodes are not a majority of five, so they join the existing cluster.
  The old nodes get the new seed list as the upgrade restarts them one at a time.
- **Shrinking is never safe** until you have moved the data off the nodes you are removing
  (`cluster.routing.allocation.exclude._name`) and removed them from the voting configuration.

### Snapshots

The chart sets up no snapshot repository. Elasticsearch has built-in support for S3, GCS and Azure
repositories. Add the client settings through `settings` and the credentials to the keystore, or
register a shared-filesystem repository with `path.repo` and a volume of your own. Then configure
snapshots in Kibana under **Stack Management → Snapshot and Restore**.

### Metrics

Elasticsearch does not serve Prometheus metrics itself, and this chart does not ship an exporter
yet. Until it does, `_cluster/health` and `_nodes/stats` (or Kibana's Dev Tools) show cluster
health and node statistics.
