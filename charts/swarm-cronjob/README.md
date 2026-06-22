# swarm-cronjob

Runs [swarm-cronjob](https://crazymax.dev/swarm-cronjob/) on your Docker Swarm — a label-driven scheduler
that turns ordinary Swarm services into cron jobs without any external dependencies.

swarm-cronjob watches the Docker API and triggers service scale-up on schedule.
It must run on a **manager node** and needs access to the Docker socket.

## Installing

```bash
swarmcli chart install swarm-cronjob eldara/swarm-cronjob
```

Custom timezone or log level:

```bash
swarmcli chart install swarm-cronjob eldara/swarm-cronjob \
  --set timezone=Europe/Budapest \
  --set log.level=debug
```

## Scheduling jobs

Once swarm-cronjob is running, annotate any other Swarm service with labels to schedule it:

```yaml
services:
  my-job:
    image: my-image
    deploy:
      replicas: 0          # keep at 0 — swarm-cronjob scales it up on schedule
      labels:
        - "swarm.cronjob.enable=true"
        - "swarm.cronjob.schedule=0 * * * *"   # every hour
        - "swarm.cronjob.skip-running=true"     # skip if already running
```

## Labels reference

| Label | Required | Default | Description |
|-------|----------|---------|-------------|
| `swarm.cronjob.enable` | ✅ | | Set to `true` to enable scheduling |
| `swarm.cronjob.schedule` | ✅ | | Cron expression (standard 5-field or `@every Xs`) |
| `swarm.cronjob.skip-running` | | `false` | Skip run if service is already running |
| `swarm.cronjob.replicas` | | `1` | Replicas to use during a scheduled run |
| `swarm.cronjob.registry-auth` | | `false` | Send registry auth to Swarm agents |
| `swarm.cronjob.query-registry` | | | Whether update requires contacting a registry |

Full docs: https://crazymax.dev/swarm-cronjob/usage/docker-labels/

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `crazymax/swarm-cronjob` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `timezone` | `Europe/Zurich` | Scheduler timezone |
| `log.level` | `info` | Log level: trace, debug, info, warn, error |
| `log.json` | `false` | Output logs as JSON |
| `deploy.placement.constraints` | `[node.role == manager]` | Placement constraints — must include a manager constraint |
| `deploy.replicas` | `1` | Number of replicas (keep at 1) |
| `deploy.restartPolicy.condition` | `any` | Restart policy |

## Notes

- swarm-cronjob requires access to `/var/run/docker.sock` and **must run on a manager node**.
  Do not remove the manager placement constraint.
- The service itself uses the `default` overlay network (internal only). It does not need
  Traefik or any ingress — it has no HTTP interface.
- Only one replica should ever run. Multiple replicas would schedule jobs multiple times.
