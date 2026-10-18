# plane-stack

Plane project management, with its own dedicated PostgreSQL, Valkey, RabbitMQ and MinIO. Fourteen containers in one stack.

| Service | Purpose | URL |
|---|---|---|
| `plane-proxy` | Caddy entry point for the whole application | http://192.168.1.121:8092 |
| `web` | Frontend | via the proxy |
| `space` | Public space pages | via the proxy |
| `admin` | Administration panel | http://192.168.1.121:8092/admin/ |
| `api` | Django API | internal `:8000` |
| `worker` | Background jobs | none |
| `beat-worker` | Scheduled jobs, Celery beat | none |
| `live` | Realtime collaboration | via the proxy |
| `migrator` | One-shot database migration (exits 0) | none |
| `plane-db` | PostgreSQL 15 for Plane only | internal `:5432` |
| `plane-redis` | Valkey cache and queue broker | internal `:6379` |
| `plane-mq` | RabbitMQ for the task queue | internal `:5672` |
| `plane-minio` | Object storage for attachments | internal `:9000` |

Files: [`docker-compose.yaml`](../../docker-compose/plane-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- Free host port `8092`
- Nothing else. Unlike most stacks here, `plane-stack` creates its own `plane-net` and brings its own databases

### It has no hostname

`plane-stack` is the only stack that does **not** join `proxy`. There are no Traefik labels on any of its services, so it has no `.mallard` entry and is reachable only at `http://192.168.1.121:8092`. The dashboard UIs in the other runbooks will not list it.

### A busy stack on a small host

Fourteen containers, plus four of them are data stores with their own volumes. On a 16 GB host this is the single largest consumer in the set, and it competes with `ai-stack` for the GPU-adjacent CPU cycles. Deploy it after `data-stack` and `monitoring-stack`, not instead of them.

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/plane-stack
cp .env.example .env
```

`PLANE_APP_DOMAIN` is the one that causes friction. It is used in four places at once:

```yaml
APP_DOMAIN
WEB_URL: http://${PLANE_APP_DOMAIN}
CORS_ALLOWED_ORIGINS: http://${PLANE_APP_DOMAIN}
```

It must match the address you actually type into the browser, including the port. The default is `192.168.1.121:8092` with no scheme, which is correct for `http://192.168.1.121:8092` and wrong for anything else.

The rest are secrets. Generate each one:

```sh
openssl rand -hex 32   # PLANE_SECRET_KEY
openssl rand -hex 32   # PLANE_LIVE_SERVER_SECRET_KEY
openssl rand -hex 32   # PLANE_DB_PASSWORD
openssl rand -hex 32   # PLANE_RABBITMQ_PASSWORD
openssl rand -hex 32   # PLANE_MINIO_SECRET_KEY
```

MinIO requires its secret to be **at least 8 characters**. Longer is better, but do not exceed the length the release supports — very long values have caused startup failures in some versions.

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `plane-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.
4. Click **Deploy the stack**.

The deploy order is handled by the compose file:

```text
plane-db (healthy) ─┬─> migrator  (one-shot, exits 0)
                     └─> api ─┬─> worker ──> beat-worker
                               ├─> web ─┬─> space
                               │        └─> admin
                               └─> live
                                        plane-proxy (waits for web/api/space/admin/live)
```

### 3. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep plane

docker ps -a --format '{{.Names}}\t{{.Status}}' | grep migrator     # -> Exited (0)

curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:8092
```

`migrator` showing `Exited (0)` is correct and expected. It is a job, not a service. It will not restart on success (`restart: on-failure`), so it stays stopped permanently.

Check the migrations actually ran:

```sh
docker exec -it plane-stack-plane-db-1 psql -U plane -d plane -c '\dt' | head -20
```

A populated list of tables means the schema is in place.

### 4. Create the first account

1. Open http://192.168.1.121:8092.
2. Register. The **first account created becomes the workspace administrator**.
3. The administration panel is at http://192.168.1.121:8092/admin/.

If the first account cannot sign in, the `migrator` almost certainly failed:

```sh
docker logs plane-stack-migrator-1
```

### 5. Sanity-check a workspace

1. Create a project, then an issue in it.
2. Attach a file. That exercises the whole chain: browser → proxy → api → `plane-minio` over S3.
3. Check that the issue appears without a reload. That exercises `live`.

If attachments fail and live updates do not, the problem is in the backing services, not the proxy.

---

## Operations

### Container names

Only `plane-proxy` sets `container_name`. Everything else uses the Compose default, which is `<stack>-<service>-<index>`:

```text
plane-proxy
plane-stack-api-1
plane-stack-web-1
plane-stack-plane-db-1
plane-stack-migrator-1
```

If Portainer deploys the stack under a different name, the prefix changes. Confirm with `docker ps` rather than assuming.

### Scaling workers

```sh
docker compose up -d --scale worker=3
```

`worker` is stateless as long as the queue is RabbitMQ, which it is. `beat-worker` must stay at exactly one instance, because duplicate Celery beat schedules run the same jobs more than once.

### Pinning a release

```yaml
image: makeplane/plane-backend:${PLANE_APP_RELEASE:-stable}
```

Every Plane image reads the same variable, so setting `PLANE_APP_RELEASE` in `.env` pins all of them together:

```sh
PLANE_APP_RELEASE=v1.0.0
```

Leaving it at `stable` means an upgrade applies to the whole stack the next time you redeploy, with no changelog you have read. Pin it before a version you depend on.

### Backups

Four volumes and four data stores, but three of them are reconstructible. Back up the database and `uploads`:

```sh
docker exec -it plane-stack-plane-db-1 pg_dump -U plane plane | gzip > /data/backups/plane-$(date +%F).sql.gz
docker run --rm -v plane_uploads:/src -v "$PWD":/dst alpine \
  tar czf /dst/plane-uploads-$(date +%F).tar.gz -C /src .
```

| Volume | Contents | Backup needed |
|---|---|---|
| `plane_pgdata` | All application data | yes |
| `plane_uploads` | Attachments | yes |
| `plane_redisdata` | Cache, ephemeral | no |
| `plane_rabbitmq_data` | Queues, in-flight jobs | no |
| `plane_logs_*` | Service logs | no |
| `plane_proxy_config`, `plane_proxy_data` | Caddy certificates | only if using HTTPS |

### Rotating secrets

`PLANE_SECRET_KEY` signs sessions, `PLANE_LIVE_SERVER_SECRET_KEY` signs realtime tokens. Changing either invalidates existing sessions and disconnects live clients, which is acceptable at any time. Changing `PLANE_DB_PASSWORD` is **not** possible by editing `.env` alone — the password is stored inside the database:

```sql
ALTER USER plane WITH PASSWORD 'new-password';
```

Only after that should the compose file be updated.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `migrator` exits non-zero | `plane-db` not healthy yet, or `PLANE_DB_PASSWORD` too weak for the release | `docker logs plane-stack-migrator-1`; `restart: on-failure` retries it automatically |
| `migrator` stuck restarting | `plane-db` cannot start at all | `docker logs plane-stack-plane-db-1`; check `plane_pgdata` for a version mismatch |
| `api` exits, log shows `OperationalError: connection refused` | Backing services not ready | The stack restarts on `unless-stopped`; check `docker logs plane-stack-api-1` for the real cause |
| Login page loads, sign-in fails, console shows a CORS error | `PLANE_APP_DOMAIN` does not match the browser URL | Set it to `192.168.1.121:8092` or whatever you actually use, then redeploy |
| Redirects go to `localhost` or a bare hostname | Same | `PLANE_APP_DOMAIN` again; `WEB_URL` is built from it |
| Page loads but attachments fail | `plane-minio` unreachable, or `PLANE_MINIO_SECRET_KEY` too long or too short | Check the length constraint in step 1; `docker logs plane-stack-plane-minio-1` |
| Issues do not update in real time | `live` cannot reach Redis, or websockets are blocked | `docker logs plane-stack-live-1`; check the browser proxy in between |
| Background jobs never run | `worker` or `beat-worker` is down | `docker ps` and `docker logs plane-stack-worker-1` |
| Scheduled jobs run more than once | `beat-worker` scaled above 1 | Scale it back to a single instance |
| Empty workspace, no tables | `migrator` never succeeded | `docker logs plane-stack-migrator-1`, fix, then `docker compose up -d` |
| `bind: address already in use` on 8092 | Another service holds it | `sudo ss -lpn 'sport = :8092'` |
| Nothing at `plane.mallard` | Expected | This stack has no Traefik router and does not join `proxy`. Use `http://192.168.1.121:8092` |
| Portainer redeploy re-runs migrations | Expected behaviour | `migrator` is idempotent; it runs each time the stack is updated |

To see why any container fails:

```sh
docker logs --tail 50 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `8092` | `80` | plane-proxy |

Everything else is internal to `plane-net`. `plane-db` publishes nothing, which is deliberate: the database is not reachable from the LAN.

---

## Notes

- `WEBHOOK_ALLOWED_IPS` and `WEBHOOK_ALLOWED_HOSTS` are both set to empty strings, which means Plane accepts webhook deliveries from **any** source. Any host on the LAN that can reach `:8092` can trigger workflows. Set both to specific values if that matters.
- `CORS_ALLOWED_ORIGINS` is a single origin derived from `PLANE_APP_DOMAIN`. There is no way to allow a second origin without editing the compose file.
- `makeplane/*:stable` is a moving tag. The four log volumes, `plane_logs_api` and friends, accumulate indefinitely and are a common cause of surprise disk use.
- The `x-*-env` YAML anchors at the top of the compose file merge environment blocks with the `<<:` key. If you edit one block and it appears not to apply, check whether a later merge is overriding it.
- This stack's PostgreSQL is 15.7 while `data-stack` runs 18. They are separate servers with separate volumes and no upgrade path between them.