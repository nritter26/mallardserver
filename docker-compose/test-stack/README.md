# test-stack

Go API development stack for `mallardserver2`, deployed as one Portainer stack.

| Service | Purpose | URL |
|---|---|---|
| `hoppscotch` | API client (app) | http://192.168.1.121:3002 |
| `hoppscotch` | Admin dashboard | http://192.168.1.121:3101 |
| `hoppscotch-migrate` | One-shot DB migration (exits 0, then stays stopped) | none |
| `api` | Go API with hot reload (Air) | http://192.168.1.121:8080 |
| `mailpit` | Catches outgoing email (web UI + SMTP) | http://192.168.1.121:8025 (SMTP `:1025`) |
| `swagger-ui` | Renders `openapi.yaml` as API docs | http://192.168.1.121:8082 |
| `prism` | Mock server generated from `openapi.yaml` | http://192.168.1.121:4010 |
| `k6` | Load testing, live dashboard during a run | http://192.168.1.121:5665 |
| `artillery` | Scenario / load testing (CLI only) | none |
| `codegen` | Runs `oapi-codegen` (CLI only) | none |

Files: `docker-compose.yml`, `.env.example`, `README.md` (your real `.env` stays local and is never committed)

---

## Prerequisites

- Docker and Portainer running on the host
- The `data-net` Docker network (created by `data-stack`) with `postgres` and `otel-collector` attached
- Free host ports: `1025`, `3002`, `3101`, `3170`, `4010`, `5665`, `8025`, `8080`, `8082`

---

## Setup

### 1. Create the network

The stack attaches to `dev-net`, which Compose does not create for you.

```sh
docker network create dev-net
docker network ls | grep -E 'dev-net|data-net'
```

Both networks must be listed.

### 2. Create the project folders

```sh
sudo mkdir -p /srv/dev/api /srv/dev/loadtests/k6 /srv/dev/loadtests/artillery
sudo chown -R mallard:mallard /srv/dev
```

The `chown` matters: without it, writing into `/srv/dev` fails with "Permission denied", even with `sudo` on a redirect (`sudo cmd > file` still runs the redirect as your user).

### 3. Create the databases

Hoppscotch and the Go API each get their own user and database on the shared `postgres` container.

```sh
docker exec -it postgres psql -U <postgres-superuser>
```

```sql
CREATE USER hoppscotch WITH PASSWORD 'your-hoppscotch-password';
CREATE DATABASE hoppscotch OWNER hoppscotch;

CREATE USER app WITH PASSWORD 'your-app-password';
CREATE DATABASE app OWNER app;
\q
```

Use the same passwords for `HOPPSCOTCH_DB_PASSWORD` and `APP_DB_PASSWORD` in step 6. If you change `*_DB_USER` or `*_DB_NAME` in `.env`, use those names here instead.

### 4. Add the OpenAPI spec

Prism refuses to start with an empty spec, so it needs at least one endpoint.

```sh
cat > /srv/dev/api/openapi.yaml <<'EOF'
openapi: 3.0.3
info:
  title: Mallard API
  version: 0.1.0
paths:
  /health:
    get:
      summary: Health check
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                type: object
                properties:
                  status:
                    type: string
                    example: ok
EOF
```

`openapi.yaml` must exist as a file before the first deploy. If it doesn't, Docker creates a directory in its place and Swagger UI and Prism break.

### 5. Add a minimal Go project

Air restarts forever until the folder contains a Go program.

```sh
cd /srv/dev/api

cat > go.mod <<'EOF'
module mallard-api

go 1.23
EOF

cat > main.go <<'EOF'
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":"ok"}`)
	})
	http.ListenAndServe(":8080", nil)
}
EOF

cat > .air.toml <<'EOF'
root = "."
tmp_dir = "tmp"

[build]
  cmd = "go build -o ./tmp/main ."
  bin = "./tmp/main"
  include_ext = ["go", "yaml"]
  exclude_dir = ["tmp", "vendor"]
EOF
```

### 6. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `dev-stack`.
2. Paste the contents of `docker-compose.yml` into the Web editor.
3. Under **Environment variables**, load your `.env` (copy it from `.env.example` and fill in the values). Portainer's **Load variables from .env file** button imports the whole file.

   Required values (the stack refuses to deploy if one is empty): `APP_DB_PASSWORD`, `HOPPSCOTCH_DB_PASSWORD`, `JWT_SECRET`, `SESSION_SECRET`, `DATA_ENCRYPTION_KEY` (exactly 32 characters, `openssl rand -hex 16`). Everything else has a default in the compose file, so you only set it to override.

   Ports, network names, database names and users, and host paths are all configurable through `.env`.

4. Click **Deploy the stack**.

### 7. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'hoppscotch|api|mailpit|swagger|prism|k6|artillery|codegen'

curl http://localhost:8080/health     # Go API -> {"status":"ok"}
curl http://localhost:4010/health     # Prism  -> {"status":"ok"}
```

`hoppscotch-migrate` should show `Exited (0)`. That is normal.

### 8. First Hoppscotch login

1. Open http://192.168.1.121:3002 and sign in with your email.
2. Open Mailpit at http://192.168.1.121:8025 and click the magic link in the email.
3. The first user to sign in becomes the admin. The admin dashboard is at http://192.168.1.121:3101.
4. Import your spec: in Hoppscotch, **Collections → Import → OpenAPI**, and use `/srv/dev/api/openapi.yaml`.

---

## Daily workflow

The spec drives everything:

```text
openapi.yaml -> Swagger UI (docs)
             -> Prism (mock for frontend work)
             -> oapi-codegen -> Go types/server -> Air rebuilds -> api :8080
             -> Hoppscotch (import spec) -> test endpoints
             -> k6 / Artillery -> load test http://api:8080
```

### Edit the spec

After changing `openapi.yaml`, restart the containers that read it:

```sh
docker restart <prism-container> <swagger-ui-container>
```

Use the actual names from `docker ps` (Portainer prefixes them with the stack name).

Writing to the file in place (`cat >`, or an editor that overwrites) is enough. If your editor replaces the file with a new one, the containers keep the old mount, and you need to recreate them: **Portainer → Stack → Update the stack** with **Re-pull image and redeploy** ticked.

### Generate Go code

```sh
docker exec -it <codegen-container> sh -c \
  "go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest \
   -generate types,chi-server -package api openapi.yaml > api/gen.go"
```

Air rebuilds the API on save.

### Test requests from Hoppscotch

Hoppscotch sends requests from your browser, not from inside Docker. Use LAN addresses in requests, not container names:

| Target | URL in Hoppscotch |
|---|---|
| Go API | `http://192.168.1.121:8080` |
| Prism mock | `http://192.168.1.121:4010` |

Because the browser makes the call, your Go API needs CORS headers for the Hoppscotch origin (`http://192.168.1.121:3002`), or use Hoppscotch's browser extension or proxy setting to bypass CORS.

### Load testing

```sh
docker exec -it <k6-container> k6 run /scripts/smoke.js
docker exec -it <artillery-container> artillery run /scripts/test.yml
```

Scripts live on the host in `/srv/dev/loadtests/k6` and `/srv/dev/loadtests/artillery`. k6 and Artillery run inside Docker, so there they use container names: target the API at `http://api:8080`.

The k6 dashboard at http://192.168.1.121:5665 only exists while a test is running. To keep a report, add `K6_WEB_DASHBOARD_EXPORT: /scripts/report.html` to the `k6` environment.

### Email testing

The Go API sends mail to `mailpit:1025` (`SMTP_ADDR` is already set). Sent messages, including Hoppscotch login emails, appear in Mailpit at `:8025`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network devnet declared as external, but could not be found` | Old compose file, or network not created | Use the current compose file; run `docker network create dev-net` |
| `service "api" refers to undefined network dev-net` | Service network keys don't match the bottom `networks:` block | Services use keys `dev` / `data`; paste the compose file again unmodified |
| `Permission denied` writing to `/srv/dev/...` | Folder owned by root | `sudo chown -R mallard:mallard /srv/dev` |
| Deploy refused: `set JWT_SECRET` (or similar) | Required variable missing | Add it under Environment variables |
| `hoppscotch-migrate` exits non-zero | Database or user missing, wrong password, or Postgres version issue | Check `docker logs <hoppscotch-migrate>`; redo step 3; confirm the password matches |
| `hoppscotch` never starts | Migration did not finish | Fix the migrate error first; it must exit 0 |
| Hoppscotch login loop, or CORS errors | `HOST` does not match the address you open in the browser | Set `HOST` to the exact address you use, then redeploy |
| No login email arrives | Mail goes to Mailpit, not your inbox | Open http://192.168.1.121:8025 |
| Requests to the API fail in Hoppscotch with CORS errors | Browser blocks cross-origin calls | Add CORS to the Go API, or use the Hoppscotch extension or proxy |
| Prism restarts: `No operations found in the current file` | `openapi.yaml` has `paths: {}` | Add an endpoint (step 4), then restart Prism |
| Prism crashes with `reading 'isPrimary'` | Multiprocess mode on a newer Node | The compose file already disables it (`--no-multiprocess`) and runs on `node:20-alpine` |
| Swagger UI / Prism show nothing, or stay on the old spec | `openapi.yaml` was a directory, or the file was replaced after the container started | Make sure it's a real file (`ls -l`), then recreate the containers |
| `api` restarts in a loop | No Go project in `/srv/dev/api` | Add `go.mod`, `main.go` and `.air.toml` (step 5) |
| `api` log: `go.mod requires go >= 1.xx` | Go in the Air image is too old | Use `image: golang:1.23` and `command: sh -c "go install github.com/air-verse/air@latest && air"` |
| k6 dashboard won't load | No test is running | Start a test; the dashboard only exists during a run |

To see why any container fails:

```sh
docker logs --tail 30 <container>
```

---

## Ports

| Host port | Service |
|---|---|
| `1025` | Mailpit SMTP |
| `3002` | Hoppscotch app (`3000` is Grafana) |
| `3101` | Hoppscotch admin |
| `3170` | Hoppscotch backend |
| `4010` | Prism mock |
| `5665` | k6 web dashboard |
| `8025` | Mailpit web UI |
| `8080` | Go API |
| `8082` | Swagger UI (`8081` is mongo-express) |

---

## Notes

- Pin image versions (`latest` is used for several images) before relying on this long term.
- Prism downloads its CLI with `npx` on every start, so the first few seconds after a restart are slow and it needs internet access.
- Prism only reads the spec at startup, so restart it after every spec change.
- Hoppscotch's variable names come from its AIO setup and can change between releases. If the app misbehaves after an upgrade, compare against the `.env.example` in the Hoppscotch repo. Back up the `hoppscotch` database before upgrading.
- Personal Hoppscotch collections may live in browser storage. Use team workspaces and periodic exports.
- Hoppscotch's migrations on `postgres:18-alpine` are untested here. If they fail, use a small dedicated Postgres for Hoppscotch.
