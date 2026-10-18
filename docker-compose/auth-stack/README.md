# auth-stack

Keycloak 26: single sign-on and identity, backed by the shared PostgreSQL server from `data-stack`.

| Service | Purpose | URL |
|---|---|---|
| `keycloak` | Identity and access management | http://auth.mallard · http://192.168.1.121:8080 · https://192.168.1.121:8443 |

Files: [`docker-compose.yaml`](../../docker-compose/auth-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

**Status:** the infrastructure overview lists Keycloak as documented but not currently running on this host. Treat this runbook as a fresh deployment.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` and `data-net` Docker networks. Both are declared `external: true`
- **`data-stack` already deployed and healthy.** Keycloak has no database of its own; it uses the shared `postgres` container
- Free host ports: `8080`, `8443`
- **Port 8080 must be free.** It is also claimed by the development Go API in `test-stack` — the two cannot run at the same time

---

## Setup

### 1. Create the Keycloak database

Keycloak points at `jdbc:postgresql://postgres:5432/keycloak` and will not create the database itself.

```sh
docker exec -it postgres psql -U <POSTGRES_USER>
```

```sql
CREATE DATABASE keycloak;
\q
```

The stack connects as the `data-stack` superuser, so no dedicated role is needed.

### 2. Prepare the environment file

```sh
cd docker-compose/auth-stack
cp .env.example .env
```

### 3. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `auth-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   | Variable | Notes |
   |---|---|
   | `KEYCLOAK_ADMIN` | Username for the bootstrap admin, created on an empty database |
   | `KEYCLOAK_ADMIN_PASSWORD` | Its password. `openssl rand -base64 16` |
   | `POSTGRES_USER` | Must match `data-stack` |
   | `POSTGRES_PASSWORD` | Must match `data-stack` |

4. Click **Deploy the stack**.

First boot is slow: Keycloak applies roughly 80 schema migrations before the admin console is reachable. Wait a minute.

### 4. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep keycloak

curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:8080/    # -> 200
curl -s -o /dev/null -w '%{http_code}\n' http://auth.mallard/         # -> 200 or 302

docker exec -it keycloak sh -c 'curl -sf http://localhost:9000/health/ready' || \
docker logs --tail 30 keycloak
```

Health and metrics endpoints are enabled (`KC_HEALTH_ENABLED=true`) but only on Keycloak's **management** port, 9000 by default. The compose file publishes `8080` and `8443`, not `9000`, so check from inside the container as shown.

### 5. First login

1. Open http://auth.mallard.
2. Sign in with `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`.
3. Change that password immediately. **The bootstrap admin variables only apply when the database is empty** — once a master realm exists they are ignored, and resetting them in `.env` has no effect.
4. Create a realm for real users. Do not build in the `master` realm.

```
Admin console -> Create realm  ->  e.g. "mallard"
```

### 6. Create a client for the Go API

For each application that should use single sign-on:

1. **Clients → Create client → Client authentication: On**, **Standard flow: On**.
2. **Settings → Valid redirect URIs**: `http://api.mallard/*` or whatever the app's public address is.
3. **Web origins**: the app's origin, so CORS preflights succeed.
4. Copy the client secret from **Credentials** into the application's own `.env`.

The `test-stack` Go API has no Keycloak configuration yet. That integration is not part of this stack.

---

## Operations

### Hostname behaviour

The compose file sets two options that matter behind a reverse proxy:

| Option | Effect |
|---|---|
| `KC_HOSTNAME_STRICT=false` | Keycloak accepts any hostname and derives its public URL from the request |
| `KC_PROXY_HEADERS=xforwarded` | Trusts `X-Forwarded-For` and `X-Forwarded-Host` from Traefik |

The consequence: the issuer in tokens is whatever address the browser used. Open http://auth.mallard and tokens say `http://auth.mallard/`; open http://192.168.1.121:8080 and they say that instead. Both are internally consistent, but a client configured with one will reject tokens from the other. Pick one address and configure every client with it.

Behind Traefik the connection is plain HTTP, so `X-Forwarded-Proto` is `http` and the issuer stays `http://`. Enabling HTTPS means adding an `https` entrypoint in `devops-stack` and a TLS router, not only changing a Keycloak setting.

### Backup

Everything lives in the `keycloak` database:

```sh
docker exec -it postgres pg_dump -U <POSTGRES_USER> keycloak > /data/backups/keycloak-$(date +%F).sql
```

The `keycloak_data` volume holds only local key material — the truststore, and the master key blob in the `hashed_password` sense that lets Keycloak decrypt exported credentials. Losing it invalidates stored secrets and, depending on version, forces a re-rotation.

### Upgrade procedure

1. Back up the database and the volume.
2. Note the current image tag: `quay.io/keycloak/keycloak:26.0` is pinned, not `latest`.
3. Bump one major at a time. Keycloak runs `start-dev`-less production mode here (`command: start`), which expects a properly configured hostname and TLS. Behind Traefik over plain HTTP that works only because `KC_HOSTNAME_STRICT=false`.
4. Redeploy and watch `docker logs keycloak` through the migration.

### Add Keycloak to Traefik

The router label is already in the compose file:

```yaml
traefik.http.routers.keycloak.rule=Host(`auth.mallard`)
traefik.http.routers.keycloak.entrypoints=web
traefik.http.services.keycloak.loadbalancer.server.port=8080
```

Port `8080` there is the *container* port. Traefik reaches Keycloak directly on `proxy`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| `network data-net declared as external, but could not be found` | Network not created | `docker network create data-net`, then redeploy |
| Keycloak restarts, log shows `FATAL Failed to obtain JDBC connection` | `data-stack` is not up | Deploy `data-stack` first, then `docker restart keycloak` |
| Keycloak log shows `database "keycloak" does not exist` | Step 1 skipped | `CREATE DATABASE keycloak;`, then `docker restart keycloak` |
| Keycloak log shows `password authentication failed for user` | `POSTGRES_USER`/`POSTGRES_PASSWORD` do not match `data-stack` | Copy them exactly from `data-stack/.env` |
| `bind: address already in use` on 8080 | `test-stack`'s Go API holds it | Stop that container, or remap the left-hand side in this compose file |
| Console loads but login redirects in a loop | The issuer does not match the URL in the browser | Use one address consistently; check **Realm settings → Frontend URL** |
| Issuer mismatch errors in a client | Same request from two different hostnames | Fix the client to use the address the browser uses |
| `https://192.168.1.121:8443` refuses the connection | Keycloak's HTTPS interface has no certificate configured | The stack is HTTP-only; use `:8080` or `auth.mallard` |
| `/health/ready` returns nothing from the host | The management port is not published | `docker exec` into the container and curl `localhost:9000` |
| `data-stack` redeployed with a different superuser password | Keycloak is still using the old one | Update both `.env` files, then restart Keycloak |
| Login works at `:8080` but not at `auth.mallard` | Traefik is down, or the container is not on `proxy` | Deploy `devops-stack`; check `docker network inspect proxy` |

To see why any container fails:

```sh
docker logs --tail 50 keycloak
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `8080` | `8080` | Keycloak HTTP |
| `8443` | `8443` | Keycloak HTTPS, no certificate configured |

Neither the management port (`9000`) nor the metrics port (`9000` in the default distribution) is published.

---

## Notes

- Keycloak 26 runs in production mode (`command: start`), which normally demands a valid public hostname and TLS termination. `KC_HOSTNAME_STRICT=false` is what lets it run behind Traefik over plain HTTP. Treat that as a lab convenience, not a production posture.
- The image tag is pinned at `26.0`, which is good practice, but it will stop receiving fixes. Schedule upgrades; Keycloak migrations are not always reversible.
- Both database credentials are the shared superuser from `data-stack`. Keycloak can therefore read and write every other database on that server. Creating a dedicated `keycloak` role with rights only on the `keycloak` database would be a small, worthwhile change.
- Nothing else in this set is wired to Keycloak yet. It is an identity provider waiting for clients, and the first consumer should get the dedicated role above before it goes live.