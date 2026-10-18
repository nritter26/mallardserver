# Production deployment runbooks

One folder per stack. Each holds the variables that stack needs and a runbook for deploying it.

```text
prod/
├── README.md            # this file: shared setup, deploy order, port map, DNS
├── ai-stack/            # LibreChat, llama-swap, SearXNG, n8n
├── auth-stack/          # Keycloak
├── cloud-stack/         # MinIO, Filestash, Caddy
├── data-stack/          # PostgreSQL, MongoDB, Redis, RabbitMQ + admin UIs
├── devops-stack/        # Traefik, Gitea, act_runner
├── dns-stack/           # Pi-hole
├── monitoring-stack/    # Prometheus, Grafana, Loki, Promtail, Jaeger, OTel, cAdvisor
├── plane-stack/         # Plane project management
├── sftp-stack/          # SFTP
└── vpn-stack/           # Tailscale
```

Each folder contains exactly two files:

| File | Purpose |
|---|---|
| `README.md` | Prerequisites, numbered setup steps, verification, troubleshooting |
| `.env.example` | Every variable the stack's compose file reads, grouped and commented |

The compose files are **not** duplicated here. Each runbook points at the canonical file:

```text
../../docker-compose/<stack>/docker-compose.yaml
```

Fill in the real values locally (`cp .env.example .env`) or in Portainer under **Environment variables**. Never commit a real `.env`.

---

## Host

| Item | Value |
|---|---|
| Hostname | `mallardserver2` |
| LAN IP | `192.168.1.121` |
| OS | Ubuntu Server 26.04 LTS |
| Container manager | Docker Engine + Portainer CE |
| GPU | NVIDIA GeForce GTX 1060 3GB |
| Host paths in use | `/data`, `/srv/dev` |

Runbooks are written against the compose files as they stand on `2026-10-18`. Docker was not running on the machine they were authored on, so the verification steps have not been executed end to end.

---

## Before the first stack: shared networks

Six of the ten stacks attach to `proxy` and `data-net`, which are declared `external: true`. Compose does not create external networks, so they must exist first or **every** one of those stacks fails to deploy.

```sh
docker network create proxy
docker network create data-net
docker network ls | grep -E 'proxy|data-net'
```

Both names must be listed.

The other networks are created by their own stack and need no manual step:

| Network | Created by | Type |
|---|---|---|
| `proxy` | you, manually | external — shared by every stack that Traefik routes |
| `data-net` | you, manually | external — shared by stacks that talk to `postgres`/`mongodb` |
| `dev-net` | you, manually | external — only `test-stack` uses it |
| `monitoring` | `monitoring-stack` | internal |
| `ai-net` | `ai-stack` | internal |
| `cloud-net` | `cloud-stack` | internal |
| `plane-net` | `plane-stack` | internal |

To reach `monitoring` from another stack (for example to send OTLP to `otel-collector`), add it as an external network in that stack with the same name.

---

## Deploy order

Stacks are listed in dependency order. Deploying out of order fails in predictable ways: no `proxy` means no routing, no `data-stack` means no `postgres`.

| # | Stack | Depends on |
|---|---|---|
| 1 | `dns-stack` | `proxy` — every `*.mallard` name depends on it |
| 2 | `vpn-stack` | nothing |
| 3 | `devops-stack` | `proxy`; provides Traefik, which routes all the hostnames below |
| 4 | `data-stack` | `proxy`, `data-net` |
| 5 | `auth-stack` | `data-stack` (needs a `keycloak` database) |
| 6 | `monitoring-stack` | `proxy` |
| 7 | `ai-stack` | `data-stack`, `monitoring-stack` (host paths), `proxy` |
| 8 | `plane-stack` | nothing — it brings its own database |
| 9 | `cloud-stack` | `proxy` |
| 10 | `sftp-stack` | nothing |

`docker-compose/test-stack/` is not listed: it is the development stack, not part of this runbook set.

---

## Databases on the shared `postgres`

`data-stack` creates one PostgreSQL server and nothing else. Every other stack that references `postgres:5432` expects its own database to already exist. Create them once, as the superuser:

```sh
docker exec -it postgres psql -U <POSTGRES_USER>
```

```sql
CREATE DATABASE keycloak;   -- auth-stack
CREATE DATABASE gitea;      -- devops-stack
CREATE DATABASE n8n;        -- ai-stack
CREATE DATABASE hoppscotch; -- test-stack (not part of this set)
CREATE DATABASE app;        -- test-stack (not part of this set)
\q
```

| Stack | Database | Runbook step |
|---|---|---|
| `auth-stack` | `keycloak` | [auth-stack README](auth-stack/README.md) |
| `devops-stack` | `gitea` | [devops-stack README](devops-stack/README.md) |
| `ai-stack` | `n8n` | [ai-stack README](ai-stack/README.md) |

---

## `.mallard` DNS records

`dns-stack` sets a wildcard: every `*.mallard` name resolves to `HOST_IP`. Each row below is a Traefik router label inside the named stack — no manual DNS entry is needed, but the stack must be deployed and the Traefik router must exist.

| Hostname | Service | Defined in |
|---|---|---|
| `traefik.mallard` | Traefik dashboard | `devops-stack` |
| `gitea.mallard` | Gitea web | `devops-stack` |
| `pihole.mallard` | Pi-hole admin | `dns-stack` |
| `pgadmin.mallard` | pgAdmin | `data-stack` |
| `mongo-express.mallard` | mongo-express | `data-stack` |
| `redisinsight.mallard` | RedisInsight | `data-stack` |
| `rabbitmq.mallard` | RabbitMQ management | `data-stack` |
| `auth.mallard` | Keycloak | `auth-stack` |
| `prometheus.mallard` | Prometheus | `monitoring-stack` |
| `grafana.mallard` | Grafana | `monitoring-stack` |
| `jaeger.mallard` | Jaeger UI | `monitoring-stack` |
| `search.mallard` | SearXNG | `ai-stack` |
| `chat.mallard` | LibreChat | `ai-stack` |
| `n8n.mallard` | n8n | `ai-stack` |
| `minio.mallard` | MinIO console | `cloud-stack` |
| `filestash.mallard` | Filestash | `cloud-stack` |
| `caddy.mallard` | cloud Caddy | `cloud-stack` |

`plane-stack` is the exception: it does not join `proxy`, so it has no hostname and is reached only at `http://192.168.1.121:8092`.

---

## Host port map

Every host port the ten stacks bind. Check it before adding anything new.

| Port | Service | Stack |
|---|---|---|
| `53` (TCP+UDP) | Pi-hole DNS | `dns-stack` |
| `80` | Traefik | `devops-stack` |
| `2222` | Gitea SSH | `devops-stack` |
| `2224` | SFTP | `sftp-stack` |
| `3000` | Grafana | `monitoring-stack` |
| `3001` | Gitea web | `devops-stack` |
| `3080` | LibreChat | `ai-stack` |
| `5050` | pgAdmin | `data-stack` |
| `5433` | PostgreSQL | `data-stack` |
| `5540` | RedisInsight | `data-stack` |
| `5672` / `15672` | RabbitMQ / management | `data-stack` |
| `5678` | n8n | `ai-stack` |
| `6379` | Redis | `data-stack` |
| `8080` / `8443` | Keycloak HTTP / HTTPS | `auth-stack` |
| `8081` | mongo-express | `data-stack` |
| `8088` | Pi-hole web | `dns-stack` |
| `8089` | Traefik dashboard | `devops-stack` |
| `8092` | Plane proxy | `plane-stack` |
| `8334` | Filestash | `cloud-stack` |
| `8444` / `8480` | cloud Caddy HTTPS / HTTP | `cloud-stack` |
| `9000` / `9001` | MinIO API / console | `cloud-stack` |
| `9090` | Prometheus | `monitoring-stack` |
| `11435` | llama-swap | `ai-stack` |
| `16686` | Jaeger UI | `monitoring-stack` |
| `27017` | MongoDB | `data-stack` |
| `4317` / `4318` | OTel collector gRPC / HTTP | `monitoring-stack` |

Two collisions to keep in mind:

- `auth-stack` binds `8080`. The development Go API in `test-stack` also binds `8080`. They cannot run at the same time.
- `cloud-stack` publishes `8444` for HTTPS, but its Caddyfile only defines a `:80` site block, so nothing answers on `8444`.

---

## Conventions

| Rule | Detail |
|---|---|
| One folder per stack | Each folder has `README.md` + `.env.example` and nothing else |
| Compose file is canonical | Lives in `docker-compose/<stack>/`, never copied into `prod/` |
| No secrets in git | Commit `.env.example`; real `.env` files stay local and are git-ignored |
| Comments on their own lines | Some env loaders do not strip inline comments and would fold them into the value |
| Shared networks are external | `proxy` and `data-net` are created once and never by Compose |
| Pin image versions | Several images are on `latest`; pin them before relying on this long term |

---

## Known issues in this repository

Found while writing these runbooks. They are not fixed by the documentation.

| Issue | Effect |
|---|---|
| Compose files are named `docker-compose.yaml`, but `scripts/up-all.sh` and `scripts/down-all.sh` check for `docker-compose.yml` | Every stack reports `[missing]` and is skipped |
| `scripts/create-networks.sh` contains the *stop all stacks* script | Calling it to create networks stops stacks instead. Create the networks by hand, as shown above |
| `scripts/up-all.sh` does not exist; the start script is `scripts/up-add.sh` | The name in the top-level README points at nothing |
| `docker-compose/test-stack/README.md` says `docker-compose.yml` and `.env.example`, the folder has `docker-compose.yaml` and `env.example` | Portainer setup steps copy a file that is not there |
| `scripts/` is not present inside `docs/room1/` | The commands in the top-level README must be run from the repository root, not from this folder |

---

## Runbooks

| Stack | Runbook |
|---|---|
| ai | [ai-stack/README.md](ai-stack/README.md) |
| auth | [auth-stack/README.md](auth-stack/README.md) |
| cloud | [cloud-stack/README.md](cloud-stack/README.md) |
| data | [data-stack/README.md](data-stack/README.md) |
| devops | [devops-stack/README.md](devops-stack/README.md) |
| dns | [dns-stack/README.md](dns-stack/README.md) |
| monitoring | [monitoring-stack/README.md](monitoring-stack/README.md) |
| plane | [plane-stack/README.md](plane-stack/README.md) |
| sftp | [sftp-stack/README.md](sftp-stack/README.md) |
| vpn | [vpn-stack/README.md](vpn-stack/README.md) |