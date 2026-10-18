# devops-stack

Edge and source control: Traefik reverse proxy, Gitea with its CI runner.

Deploy this third. Eight other stacks publish `.mallard` hostnames through Traefik, so if it is down, every one of those URLs fails even though the containers are healthy.

| Service | Purpose | URL |
|---|---|---|
| `traefik` | Reverse proxy and edge router for every stack | :80 (routing) · http://traefik.mallard (dashboard) |
| `gitea` | Git hosting, HTTP and SSH | http://gitea.mallard · http://192.168.1.121:3001 · SSH `gitea.mallard:2222` |
| `act_runner` | CI/CD runner for Gitea Actions | none (CLI only) |

Files: [`docker-compose.yaml`](../../docker-compose/devops-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` and `data-net` Docker networks. Both are declared `external: true`
- Free host ports: `80`, `2222`, `3001`, `8089`
- Port 80 must be free. Anything already listening there — Apache, nginx, a previous Traefik — blocks the deploy

```sh
docker network create proxy
docker network create data-net
```

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/devops-stack
cp .env.example .env
```

`GITEA_RUNNER_TOKEN` cannot be created ahead of time — it only exists once Gitea is running. Deploy in two passes: set everything except the token, deploy, then get the token from the Gitea UI and add it.

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `devops-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   | Variable | Required | Notes |
   |---|---|---|
   | `TZ` | yes | e.g. `Europe/Berlin` |
   | `POSTGRES_USER` | yes | Superuser on the shared `postgres` from `data-stack` |
   | `POSTGRES_PASSWORD` | yes | Must match `data-stack` exactly |
   | `GITEA_RUNNER_TOKEN` | no at first | Add it in step 5 |

4. Click **Deploy the stack**.

`gitea` will not start cleanly yet: it points at a `gitea` database that does not exist. That is what the next step fixes.

### 3. Create the Gitea database

Gitea connects to the shared PostgreSQL server over `data-net` and expects a database named `gitea`. The stack does not create it.

```sh
docker exec -it postgres psql -U <POSTGRES_USER>
```

```sql
CREATE DATABASE gitea;
\q
```

Then restart Gitea so it runs its migrations:

```sh
docker restart gitea
```

Gitea's `depends_on` is not set in this compose file, so it will not start automatically when the database appears. This is the expected sequence.

### 4. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'traefik|gitea|act_runner'

curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:3001   # -> 200
curl -s -o /dev/null -w '%{http_code}\n' http://traefik.mallard      # -> 200 or 302
```

`act_runner` will be restarting or logging "connection refused" until the token is set. That is normal.

### 5. Register the CI runner

1. Open http://gitea.mallard and create the first account. The first registered user is the administrator.
2. Go to **Settings → Actions → Runners → Add new runner**.
3. Gitea displays a registration token. Copy it.
4. Add it to the stack: **Stacks → devops-stack → Environment variables → `GITEA_RUNNER_TOKEN`**, then update the stack.

   ```sh
   # generate one yourself if you prefer
   docker run --rm gitea/act_runner:latest generate-jit
   ```

   The runner is also registered under the name `mallard-runner` (`GITEA_RUNNER_NAME`), which is fixed in the compose file.

5. Confirm it connected:

   ```sh
   docker logs --tail 20 act_runner
   ```

   A registered runner logs something like ` runner started, server: http://gitea:3000 ` and stops retrying.

### 6. Confirm routing works

Traefik reads container labels, so it needs to see the containers on the `proxy` network:

```sh
docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{end}}'
```

`gitea` and `traefik` should both be listed. Then:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: gitea.mallard' http://192.168.1.121/
```

The `Host` header test works even before `.mallard` DNS is configured, which separates routing problems from DNS problems.

---

## Operations

### How the proxy decides where to send traffic

Traefik is started with `--providers.docker=true` and `--providers.docker.network=proxy`, so it only discovers containers attached to `proxy`. It is also started with `--providers.docker.exposedbydefault=false`: a service is only routed if it carries `traefik.enable=true`.

A new service therefore needs three things: join `proxy`, carry the labels, and be restarted after the labels change.

```yaml
networks: [proxy]
labels:
  - traefik.enable=true
  - traefik.http.routers.<name>.rule=Host(`<name>.mallard`)
  - traefik.http.routers.<name>.entrypoints=web
  - traefik.http.services.<name>.loadbalancer.server.port=<container-port>
```

The container port, not the host port. Traefik reaches containers directly on `proxy`.

### Adding a service

1. Add the three lines above to the service in its own stack's compose file.
2. Redeploy that stack.
3. Check the router appeared: http://traefik.mallard → Routers.

Labels are read at container creation. Editing a compose file and running `docker restart` does not re-read them — the container has to be recreated.

### Dashboard

http://traefik.mallard, or directly on http://192.168.1.121:8089. The dashboard is exposed via the internal API (`api@internal`), which is only served on the `traefik` entrypoint, not on `:80`.

### Runner storage

`act_runner` mounts `/var/run/docker.sock` read-write, so workflows it runs can start sibling containers on the host. Jobs execute as Docker containers, not inside the runner.

### Back up Gitea

```sh
docker exec -it gitea sh -c 'git gc'                       # recommended inside the container
docker run --rm -v gitea_data:/src -v "$PWD":/dst alpine \
  tar czf /dst/gitea-data-$(date +%F).tar.gz -C /src .
```

Repositories, LFS objects and avatars live in the `gitea_data` volume. Settings changed through the web UI live in `gitea_config`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| `network data-net declared as external, but could not be found` | Network not created | `docker network create data-net`, then redeploy |
| `gitea` restarts in a loop, log shows `database "gitea" does not exist` | Step 3 not done | `CREATE DATABASE gitea;`, then `docker restart gitea` |
| `gitea` log shows `password authentication failed for user` | `POSTGRES_USER`/`POSTGRES_PASSWORD` differ from `data-stack` | Copy them exactly; check the superuser actually exists |
| `bind: address already in use` on port 80 | Another web server or an old Traefik holds :80 | `sudo ss -lpn 'sport = :80'`, stop it |
| `http://gitea.mallard` gives 404 but `:3001` works | Router label missing, wrong `Host` rule, or the container is not on `proxy` | Check `docker network inspect proxy` and the labels in the compose file |
| `http://traefik.mallard` gives 404 | The dashboard rule points at `api@internal`, which only answers on the `traefik` entrypoint | Use http://192.168.1.121:8089 |
| Traefik dashboard shows no routers | `exposedbydefault=false` and the labels were added without recreating the container | Redeploy the stack so the container is recreated |
| `act_runner` logs `connection refused` or restarts | Token missing or wrong | Set `GITEA_RUNNER_TOKEN`, update the stack |
| Runner registers but jobs stay queued | Runner is offline, or the workflow lacks `runs-on: mallard-runner` | Check **Settings → Actions → Runners** for the green dot; match the label |
| SSH clone fails, browser clone works | Port 2222 is the exposed SSH port, not 22 | `ssh://git@gitea.mallard:2222/<user>/<repo>.git` |
| Gitea cannot write to its volume | Rootless image needs the directory owned by uid 1000 | `docker exec -it gitea chown -R 1000:1000 /var/lib/gitea` (see below) |

### Rootless volume permissions

`gitea/gitea:1.21-rootless` runs as uid 1000. A `gitea_data` volume created by a non-rootless Gitea is owned by root, and Gitea then fails to write. Either recreate the volume or fix the ownership:

```sh
docker exec --user root -it gitea chown -R 1000:1000 /var/lib/gitea /etc/gitea
```

To see why any container fails:

```sh
docker logs --tail 30 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `80` | `80` | Traefik `web` entrypoint |
| `2222` | `2222` | Gitea SSH |
| `3001` | `3000` | Gitea web |
| `8089` | `8089` | Traefik `traefik` entrypoint (dashboard) |

Gitea's SSH port is remapped from 22 to 2222 to stay clear of the host's own `sshd`.

---

## Notes

- The `gitea` image is on `1.21-rootless`. Gitea 1.21 is well past its end of life; check the current release notes before exposing it to anything but the LAN.
- Traefik mounts `/var/run/docker.sock`. It needs read access to the daemon to discover containers, which on a single-host deployment effectively grants root-equivalent control of the host.
- `gitea` has no `depends_on: postgres`, so it does not wait for `data-stack`. On a cold boot it will crash-loop until the database exists.
- Gitea Actions runners execute untrusted workflow code with access to the Docker socket. Only enable them for repositories you control.
- The `act_runner_data` volume holds the runner's registration. Deleting it means re-registering with a new token.