# data-stack

Shared data services for `mallardserver2`: PostgreSQL, MongoDB, Redis, RabbitMQ, plus a web client for each.

Deploy this **first**. `auth-stack`, `devops-stack` and `ai-stack` all connect to the `postgres` container over `data-net`, and none of them creates its own database.

| Service | Purpose | URL |
|---|---|---|
| `postgres` | Primary database, shared by every other stack | `192.168.1.121:5433` |
| `pgadmin` | PostgreSQL web client | http://192.168.1.121:5050 · http://pgadmin.mallard |
| `mongodb` | Document database | `192.168.1.121:27017` |
| `mongo-express` | MongoDB web client | http://192.168.1.121:8081 · http://mongo-express.mallard |
| `redis` | Cache and message broker | `192.168.1.121:6379` |
| `redisinsight` | Redis web client | http://192.168.1.121:5540 · http://redisinsight.mallard |
| `rabbitmq` | Message broker, AMQP + management UI | http://192.168.1.121:15672 · http://rabbitmq.mallard |

Files: [`docker-compose.yaml`](../../docker-compose/data-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` and `data-net` Docker networks. Both are declared `external: true`, so Compose will not create them and the stack refuses to deploy without them
- Free host ports: `5050`, `5433`, `5540`, `5672`, `6379`, `8081`, `15672`, `27017`

`proxy` and `data-net` must exist before you deploy:

```sh
docker network create proxy
docker network create data-net
docker network ls | grep -E 'proxy|data-net'
```

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/data-stack
cp .env.example .env
```

Fill in every value. Unlike most stacks there are no defaults in the compose file — a missing variable is substituted with an empty string, and the services start with blank or broken credentials. `redis` is the worst case: it starts with `--requirepass ""`, which leaves it open with no password at all.

Generate the secrets first:

```sh
openssl rand -hex 32   # POSTGRES_PASSWORD, REDIS_PASSWORD, and the rest
```

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `data-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   Required values (all of them):

   | Variable | Notes |
   |---|---|
   | `POSTGRES_USER` | Superuser name. Every other stack that reaches `postgres` uses this pair |
   | `POSTGRES_PASSWORD` | Superuser password |
   | `TZ` | e.g. `Europe/Berlin` |
   | `MONGO_USER` | MongoDB root user |
   | `MONGO_PASSWORD` | MongoDB root password |
   | `MONGO_EXPRESS_USER` | Login for the `mongo-express` UI, independent of MongoDB |
   | `MONGO_EXPRESS_PASSWORD` | |
   | `REDIS_PASSWORD` | Must match the password you give RedisInsight |
   | `RABBITMQ_USER` | |
   | `RABBITMQ_PASSWORD` | |
   | `PGADMIN_EMAIL` | pgAdmin login |
   | `PGADMIN_PASSWORD` | pgAdmin login |

4. Click **Deploy the stack**.

### 3. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'postgres|pgadmin|mongodb|mongo-express|redis|rabbitmq'

docker exec -it postgres psql -U <POSTGRES_USER> -c 'SELECT version();'
```

`postgres` should report `(healthy)` — it has a `pg_isready` healthcheck and everything that joins `data-net` waits on it. `mongodb` has a `mongosh` ping healthcheck and should also be healthy.

The four UI-backed services are reachable through Traefik, which must be running (`devops-stack`) and `.mallard` must resolve (`dns-stack`). Without those, use the IP and port.

### 4. Connect the admin UIs

Each client stores its own configuration, so this is a one-time step per stack.

**pgAdmin** — http://192.168.1.121:5050 — sign in with `PGADMIN_EMAIL` / `PGADMIN_PASSWORD`, then **Add New Server → General**:

| Field | Value |
|---|---|
| Name | `mallard-postgres` |
| Host | `postgres` |
| Port | `5432` |
| Maintenance database | your `POSTGRES_USER` |
| Username | your `POSTGRES_USER` |
| Password | your `POSTGRES_PASSWORD` |

`postgres` and `5432` are the *container* values, not the host values. From inside the Docker network it is `postgres:5432`; the host publishes it on `5433` because `5432` is commonly taken.

Use the host IP and `5433` when connecting from a machine outside Docker.

**mongo-express** — http://192.168.1.121:8081 — sign in with `MONGO_EXPRESS_USER` / `MONGO_EXPRESS_PASSWORD`. The connection is preconfigured in the compose file from `MONGO_USER` and `MONGO_PASSWORD`.

**RedisInsight** — http://192.168.1.121:5540 — the connection is *not* preconfigured. Add one manually:

| Field | Value |
|---|---|
| Name | `mallard-redis` |
| Host | `redis` |
| Port | `6379` |
| Username | *(leave empty)* |
| Password | your `REDIS_PASSWORD` |
| TLS | off |

**RabbitMQ** — http://192.168.1.121:15672 — sign in with `RABBITMQ_USER` / `RABBITMQ_PASSWORD`.

### 5. Create the databases other stacks need

The server is up but empty. Each downstream stack expects its own database to already exist, and none of them creates it.

```sh
docker exec -it postgres psql -U <POSTGRES_USER>
```

```sql
CREATE DATABASE keycloak;   -- auth-stack
CREATE DATABASE gitea;      -- devops-stack
CREATE DATABASE n8n;        -- ai-stack
\q
```

They all reuse the `POSTGRES_USER` superuser, so no extra roles are needed. `test-stack` additionally wants `hoppscotch` and `app` with their own users — see `docker-compose/test-stack/README.md`.

---

## Operations

### Connect from a container

Containers that join `data-net` reach the services by name on their internal ports:

```text
postgres   postgres:5432
mongodb    mongodb:27017
redis      redis:6379
rabbitmq   rabbitmq:5672
```

```sh
docker exec -it <some-container-on-data-net> sh -c 'nc -zv postgres 5432'
```

### Connect from the host

Use the published ports and the real credentials:

```sh
psql -h 192.168.1.121 -p 5433 -U <POSTGRES_USER> -d postgres
redis-cli -h 192.168.1.121 -p 6379 -a <REDIS_PASSWORD>
```

### Back up PostgreSQL

```sh
docker exec -it postgres pg_dumpall -U <POSTGRES_USER> > /data/backups/postgres-$(date +%F).sql
```

Every stack in this set stores its data in a named Docker volume, not a bind mount, so the data lives under `/var/lib/docker/volumes`. Copying `/data` does not back up any of it.

### Data volumes

| Volume | Holds | Losing it means |
|---|---|---|
| `postgres_data` | Every database in the set | Re-initialising from the image; all data gone |
| `mongodb_data` | LibreChat conversations | LibreChat starts empty |
| `redis_data` | Cache, with AOF enabled | Cache rebuilt; no real loss |
| `rabbitmq_data` | Queues, including Plane's | Undelivered messages gone |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created yet | `docker network create proxy`, then redeploy |
| `network data-net declared as external, but could not be found` | Same, for the data network | `docker network create data-net`, then redeploy |
| Deploy succeeds, `redis-cli` reports `NOAUTH Authentication required` | Normal — Redis requires a password | `redis-cli -a <REDIS_PASSWORD>`; check RedisInsight uses the same password |
| Redis reachable with no password | `REDIS_PASSWORD` was left blank, so `--requirepass` got an empty argument | Set it in `.env` and redeploy |
| `postgres` restarts in a loop | Volume `postgres_data` holds an initdb from a different major version, or a bad `POSTGRES_PASSWORD` was set at first start | Check `docker logs postgres`. If the password was changed after initdb, `POSTGRES_PASSWORD` alone will not change it — use `ALTER USER` |
| `pgadmin` connects, then "server not found" on reload | The server entry was never saved | Servers live in the `pgadmin_data` volume; add it again and check for a config error toast |
| pgAdmin refuses to connect to `postgres:5432` | pgAdmin is on `data-net` and `proxy`, so it can resolve the name | If it still fails, the stack is probably not on `data-net`; check `docker network inspect data-net` |
| `mongo-express` login rejected | `MONGO_EXPRESS_*` and `MONGO_*` are different credentials | Sign in with `MONGO_EXPRESS_USER` / `MONGO_EXPRESS_PASSWORD`, not the MongoDB root |
| `http://pgadmin.mallard` does not resolve | Pi-hole is not deployed, or the router is not using it as DNS | Deploy `dns-stack`, or use `http://192.168.1.121:5050` |
| `http://pgadmin.mallard` returns 502 | Traefik is not running, or the container is not on `proxy` | Deploy `devops-stack`; confirm with `docker network inspect proxy` |
| `mongodb` never becomes healthy | Healthcheck has a 20s start period and 10 retries | Give it a minute; if it still fails, check `docker logs mongodb` |
| `rabbitmq` management UI refuses the default `guest` login | `guest` only works from localhost | Use `RABBITMQ_USER` / `RABBITMQ_PASSWORD` |
| Port `5433` already in use | Something else bound the host port | Stop it, or change the left-hand side of `5433:5432` in the compose file |

To see why any container fails:

```sh
docker logs --tail 30 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `5050` | `80` | pgAdmin |
| `5433` | `5432` | PostgreSQL |
| `5540` | `5540` | RedisInsight |
| `5672` | `5672` | RabbitMQ AMQP |
| `6379` | `6379` | Redis |
| `8081` | `8081` | mongo-express |
| `15672` | `15672` | RabbitMQ management |
| `27017` | `27017` | MongoDB |

---

## Notes

- `mongo-express` and `redisinsight` are on `latest`. Pin them before relying on this long term; both have shipped breaking UI changes.
- `redis` runs with `--appendonly yes`, so its volume holds a real on-disk dataset rather than a pure cache. It is still treated as a cache here.
- The compose file names every volume explicitly (`postgres_data: {name: postgres_data}`), so volume names do not carry a stack-name prefix. Renaming them would orphan existing data.
- `postgres:18-alpine` is recent. Anything that runs its own migrations against it — Hoppscotch's Prisma migrations, for instance — is untested on this version.
- MongoDB publishes `27017` and Redis `6379` on all interfaces with credentials, not authentication-free, but they are still reachable from the whole LAN. Remove the `ports:` entries if nothing outside the host needs them.
- `data-net` is shared, so any container attached to it can resolve and reach all four databases. Treat membership in that network as equivalent to database access.