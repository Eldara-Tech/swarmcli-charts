# mariadb

Single-instance MariaDB 11.8 for Docker Swarm: persistent (data on a node-local
named volume), authenticated via external Swarm secrets (root, plus an optional
non-root app user), pinned to one node, and reachable by other stacks over a shared
overlay. Not Traefik-routed (MariaDB is TCP); publishes no port by default.

## Prerequisites

1. Label the node that will hold the data volume (Swarm volumes are node-local, so
   the service is pinned to exactly one node):

   ```bash
   docker node update --label-add mariadb-data=true <node>
   ```

2. Pre-create the password secrets. The chart **validates** these secrets but never
   creates them (their content is operator-supplied). The root password is always
   required; the app-user password is needed only when `auth.appUser.enabled` (the
   default):

   ```bash
   printf 'S3cr3t' | docker secret create mariadb_root_password -
   printf 'app-pw' | docker secret create mariadb_password -
   ```

3. (Optional) the `mariadb-net` overlay — swarmcli auto-creates it if missing.

For a root-only database, set `auth.appUser.enabled: false` (skip the
`mariadb_password` secret). For an ephemeral database, set
`persistence.enabled: false` (skip step 1 — the node pin is dropped together with
the volume).

## Installing

```bash
swarmcli charts install mariadb swarmcli-charts/mariadb
```

## Connecting

Attach an app service to the `mariadb-net` overlay and dial `mariadb:3306`,
authenticating as the app user (`auth.appUser.username` / database
`auth.appUser.database`) with the `mariadb_password` secret, or as `root` with the
`mariadb_root_password` secret. To reach MariaDB from outside the overlay, set
`exposure.enabled: true` (publishes a port; choose `mode: ingress` for the
cluster-wide routing mesh or `mode: host` for the pinned node only). `ingress`
binds 3306 on **every** Swarm node, so prefer `mode: host` and firewall the port
to trusted sources — or keep exposure disabled and stay on the overlay.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `mariadb` | Image repository |
| `image.tag` | `""` | Tag — defaults to appVersion (`11.8`) |
| `replicas` | `1` | Replica count (must stay 1 — node-local volume) |
| `auth.rootSecretName` | `mariadb_root_password` | External Swarm secret holding the root password |
| `auth.appUser.enabled` | `true` | Create a non-root app user + database |
| `auth.appUser.username` | `app` | App user name |
| `auth.appUser.database` | `app` | Database created and granted to the app user |
| `auth.appUser.secretName` | `mariadb_password` | External Swarm secret holding the app-user password |
| `persistence.enabled` | `true` | Mount a volume at `/var/lib/mysql` (also controls the node pin) |
| `persistence.volumeName` | `mariadb-data` | Named volume (used when `volumePath` is empty) |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead; when set it wins over `volumeName` (see Operating notes) |
| `persistence.nodeLabel` | `mariadb-data` | Node label the data pin renders from (`node.labels.<nodeLabel> == true`); dropped when persistence is off, `""` skips the pin |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin comes from `persistence.nodeLabel`) |
| `network.name` | `mariadb-net` | Overlay network |
| `network.external` | `true` | Use a pre-existing/shared overlay vs chart-managed |
| `exposure.enabled` | `false` | Publish a port |
| `exposure.port` / `.protocol` / `.mode` | `3306` / `tcp` / `ingress` | Port binding |
| `resources.limits.memory` | `""` | Swarm deploy memory limit |
| `healthcheck.*` | see `values.yaml` | `healthcheck.sh --connect --innodb_initialized` |
| `extraArgs` | `[]` | Extra `mariadbd` flags appended verbatim |
| `labels` | `{}` | Extra deploy labels |

## Security note

Passwords are read from the mounted secret files via the image's `MARIADB_*_FILE`
convention (`MARIADB_ROOT_PASSWORD_FILE`, `MARIADB_PASSWORD_FILE`), so the resolved
values appear only inside the container — never in the compose file or
`docker inspect`, which show only the `/run/secrets/...` path. The healthcheck uses
the image's auto-created `healthcheck@localhost` user (via `.my-healthcheck.cnf`),
so no password ever appears on a command line either.

## Operating notes

- **The node pin travels with persistence.** The
  `node.labels.mariadb-data == true` constraint is rendered from
  `persistence.nodeLabel` while `persistence.enabled` is on and dropped with it,
  so an ephemeral database never sits `Pending` on a missing node label.
  `placement.constraints` holds *extra* constraints and is applied in all modes.
  (Before this coupling the pin lived in `placement.constraints` — a values file
  that still lists it there just applies it twice, which is harmless; to move the
  pin to a different label, set `persistence.nodeLabel` instead.)
- **Password rotation is not automatic.** `MARIADB_ROOT_PASSWORD_FILE` /
  `MARIADB_PASSWORD_FILE` are applied only during first-boot initialization (an
  empty data volume). Once the volume holds a database, editing the Swarm secret
  and re-deploying does **not** change the stored password — new app tasks then
  fail to authenticate. Rotate inside the database
  (`ALTER USER 'app'@'%' IDENTIFIED BY '…'`, and likewise for `root`), then update
  the secret to match. (Persistence off — an ephemeral DB — re-reads the secret on
  every boot, since each boot re-initializes.)
- **Host-path persistence.** By default data lives on the node-local named volume
  `mariadb-data` (durable across restarts/redeploys, under Docker's own volume
  storage). To store it under a directory you choose instead, set
  `persistence.volumePath` to an absolute path — it takes precedence over
  `volumeName` and the data dir is **bind-mounted** from that path on the pinned
  node. The directory must already exist on that node and be writable by the
  container's `mysql` uid (`999`); the entrypoint chowns it on first init, but
  pre-creating it with the right owner (`install -d -o 999 -g 999 <path>`) is
  safest. A bind mount is direct host-filesystem access, acknowledged by this
  chart's `swarmcli-charts/allow: "host-mount"` annotation. (A host path in
  `volumeName` is rejected at render time — that field is a Docker named-volume
  name and cannot contain `/`.)
- **Backups / availability.** Data lives only on the pinned node's local volume and
  the service runs a single replica, so there is no built-in HA: if that node is
  lost the database is unavailable until it returns or you restore a backup. Back
  the volume up out-of-band.
- **Healthcheck on a reused volume.** The credential-free healthcheck relies on the
  `healthcheck@localhost` user, created only by first-boot init on MariaDB images
  since mid-2023. A data volume first initialized by an older image lacks that user
  and the healthcheck fails permanently; create it once (or re-initialize on a
  current image) to recover.
