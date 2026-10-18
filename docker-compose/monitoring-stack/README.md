# monitoring-stack

Observability: Prometheus for metrics, Grafana for dashboards, Loki and Promtail for logs, Jaeger and the OpenTelemetry collector for traces, plus cAdvisor and an NVIDIA GPU exporter as sources.

| Service | Purpose | URL |
|---|---|---|
| `grafana` | Dashboards for metrics, logs and traces | http://192.168.1.121:3000 · http://grafana.mallard |
| `prometheus` | Metrics store, scrapes cAdvisor and the GPU exporter | http://192.168.1.121:9090 · http://prometheus.mallard |
| `loki` | Log store | internal `:3100` (no UI of its own) |
| `promtail` | Shipper: reads container logs, pushes to Loki | none |
| `jaeger` | Trace UI | http://192.168.1.121:16686 · http://jaeger.mallard |
| `otel-collector` | OTLP receiver, forwards traces to Jaeger | OTLP gRPC `:4317`, HTTP `:4318` |
| `cadvisor` | Container and host metrics source | internal `:8080` |
| `nvidia-gpu-exporter` | GPU telemetry | internal `:9835` |

Files: [`docker-compose.yaml`](../../docker-compose/monitoring-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

All four configuration files — Prometheus, Grafana datasources, Loki and Promtail, and the OTel collector — are embedded as `configs:` blocks inside the compose file. There are no separate files to mount or edit.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` Docker network. It is declared `external: true`
- Free host ports: `3000`, `4317`, `4318`, `9090`, `16686`
- An NVIDIA GPU and the NVIDIA Container Toolkit, for `nvidia-gpu-exporter`. This host has a GTX 1060 3GB
- Roughly 5 GB of disk for Prometheus's retention budget

```sh
docker network create proxy
```

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/monitoring-stack
cp .env.example .env
```

Two variables, both for the Grafana login.

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `monitoring-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   Required values: `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`.

4. Click **Deploy the stack**.

### 3. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'prometheus|grafana|loki|promtail|cadvisor|otel|jaeger|nvidia'

curl -s http://192.168.1.121:9090/-/healthy          # -> Prometheus is Healthy.
curl -s http://192.168.1.121:9090/api/v1/targets      # -> "health":"up" for the 3 jobs
curl -s http://192.168.1.121:3000/api/health          # -> {"database":"ok",...}
curl -s http://192.168.1.121:16686/                   # -> Jaeger UI
```

`nvidia-gpu-exporter` fails to start if the Container Toolkit is missing. That is the one service in this stack that can be absent without breaking the rest.

### 4. First login to Grafana

1. Open http://grafana.mallard or http://192.168.1.121:3000.
2. Sign in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`.
3. The datasources are already provisioned, so no manual setup:

   | Datasource | URL | Default |
   |---|---|---|
   | Prometheus | `http://prometheus:9090` | yes |
   | Loki | `http://loki:3100` | no |
   | Jaeger | `http://jaeger:16686` | no |

   Check **Connections → Data sources** — all three should be green.

4. There are no dashboards yet. Import one from the Grafana gallery, or build panels against the Prometheus datasource.

### 5. Confirm logs are flowing

Promtail discovers every container through the Docker socket, so logs should appear without configuration:

1. In Grafana, choose the Loki datasource and run `{container="grafana"}` in Explore.
2. Results appear once Promtail's 15-second refresh has caught the container.

### 6. Send a trace

The collector accepts OTLP and forwards to Jaeger:

```sh
# from a container that can reach otel-collector (see the network note below)
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
```

Then generate a trace and look for it under **Jaeger → Traces → Service**.

---

## Operations

### Network reachability — the important caveat

`otel-collector` is attached to `monitoring` and `proxy`. It is **not** on `data-net`, `ai-net` or `dev-net`.

An application container on those networks cannot resolve the name `otel-collector`. To send traces or metrics from another stack, attach it to a network that overlaps:

```yaml
networks: [data-net, monitoring]     # then otel-collector:4317 resolves
```

or add `monitoring` as an external network in that stack's compose file, since another stack already created it:

```yaml
networks:
  monitoring: {external: true, name: monitoring}
```

### Prometheus scrape configuration

The embedded config has three jobs and nothing else:

| Job | Target | Interval |
|---|---|---|
| `prometheus` | `localhost:9090` | 60s |
| `cadvisor` | `cadvisor:8080` | 120s |
| `nvidia-gpu` | `nvidia-gpu-exporter:9835` | 60s |

No application is scraped. To add one, append a job to the `prometheus_cfg` block in the compose file:

```yaml
- job_name: my-api
  scrape_interval: 30s
  static_configs:
    - targets: ["my-api:8080"]
```

The application also needs a `/metrics` endpoint and has to be on the `monitoring` network. Prometheus only scrapes its own targets by container name, never by host IP.

### Retention

| Store | Setting | Effect |
|---|---|---|
| Prometheus | `--storage.tsdb.retention.time=15d`, `--storage.tsdb.retention.size=5GB` | Whichever limit is hit first. Expect roughly 15 days on a quiet host, fewer on a busy one |
| Loki | `retention_period: 168h` in `limits_config` | 7 days, enforced by the compactor |

Both are in the compose file. To change them, edit and redeploy — the values are command-line and config flags, so a `docker restart` is not enough.

### Querying logs in Grafana

The Promtail relabelling keeps the container name, so `{container="traefik"}` and `{namespace="traefik"}` both work. Combine with a label filter for one service's logs.

### Storage

| Volume | Holds |
|---|---|
| `prometheus_data` | Metric samples |
| `grafana_data` | Dashboards, users, datasource state |
| `loki_data` | Log chunks and indexes |

Loki's `path_prefix` is `/loki`, which is where `loki_data` is mounted. Point it at a host path instead if these volumes need to live on a larger disk.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| `nvidia-gpu-exporter` exits, log says `could not select device driver` | NVIDIA Container Toolkit not installed | Install it on the host, then `nvidia-smi` and redeploy |
| Grafana datasource shows "Unable to connect" | The UI is not on the `monitoring` network | It is on `monitoring` and `proxy`; check the container is running |
| Grafana login rejected | Wrong credentials, or the value changed after first start | Grafana stores the initial password in `grafana_data`; reset it in the UI or `grafana cli admin reset-admin-password` |
| Loki datasource red, `connection refused` | `loki` not ready, or not on `monitoring` | `docker logs loki`; Grafana reaches it as `http://loki:3100` |
| Promtail restarts in a loop | `/var/run/docker.sock` missing or unreadable | Confirm the socket exists and the host allows the mount |
| No logs in Loki | Promtail has not caught the container yet | Wait one refresh (15s), then query `{container="<name>"}` |
| Prometheus "no targets" | Target container is not on `monitoring` | Attach it, or scrape by host IP instead of container name |
| Prometheus reports `down` for `cadvisor` | cAdvisor needs privileged mode and host paths | It is configured as such; check `docker logs cadvisor` |
| Jaeger empty, collector healthy | Traces never arrived | Confirm the application can resolve `otel-collector` — see the network note above |
| OTLP export fails with `connection refused` from another stack | Name does not resolve across networks | Join `monitoring` or `proxy` in that stack |
| Jaeger loses traces after a restart | `SPAN_STORAGE_TYPE=memory` | Expected. Traces are not persisted; use the collector's own storage for anything that must survive |
| Disk fills up | Prometheus hits 5 GB, Loki keeps 7 days of logs | Lower the retention values in the compose file, or prune `loki_data` |
| cAdvisor shows stale host metrics | `housekeeping_interval=30s`, `--docker_only=true` | By design it reports Docker-level metrics only |

To see why any container fails:

```sh
docker logs --tail 30 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `3000` | `3000` | Grafana |
| `4317` | `4317` | OTel collector, OTLP gRPC |
| `4318` | `4318` | OTel collector, OTLP HTTP |
| `9090` | `9090` | Prometheus |
| `16686` | `16686` | Jaeger UI |

Loki (`3100`), Promtail (`9080`), cAdvisor (`8080`) and the GPU exporter (`9835`) are internal to the `monitoring` network. Reach them through Grafana or by running a throwaway container on that network:

```sh
docker run --rm -it --network monitoring curlimages/curl http://loki:3100/ready
```

---

## Notes

- Seven of the eight images are on `latest`, including Prometheus, Grafana, Loki and Promtail. These projects change configuration schemas between versions; pin the versions before treating this stack as reproducible.
- The collector config exports **only** traces, and only to Jaeger. There is no metrics or log pipeline from OTLP, and no persistent trace store. Adding a span exporter means editing the `otel_cfg` block and pointing it at Prometheus or Tempo.
- Jaeger stores traces in memory with a 10 000-trace cap. It is a debugging tool here, not a system of record.
- `cadvisor` mounts `/`, `/var/run`, `/sys` and `/var/lib/docker` read-only and runs privileged. That is a broad grant of host visibility for a metrics collector.
- `promtail` has been deprecated by Grafana in favour of Grafana Alloy. Migrating is straightforward — Alloy reads the same Docker socket and speaks the same push API.
- Prometheus scrapes itself at `localhost:9090`, which is the Prometheus container's own loopback. That is correct for a single-container Prometheus.