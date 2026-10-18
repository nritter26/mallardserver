# cloud-stack

Object storage and file management: MinIO as an S3-compatible store, Filestash as a web client for it, and Caddy as a second entry point.

| Service | Purpose | URL |
|---|---|---|
| `cloud-minio` | S3-compatible object storage | API `192.168.1.121:9000` · console http://192.168.1.121:9001 · http://minio.mallard |
| `cloud-filestash` | Web file manager that connects to MinIO | http://192.168.1.121:8334 · http://filestash.mallard |
| `cloud-caddy` | Reverse proxy in front of Filestash | http://192.168.1.121:8480 · http://caddy.mallard |

Files: [`docker-compose.yaml`](../../docker-compose/cloud-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

This stack has no dependency on `data-stack`. Its only external requirement is the `proxy` network, which Traefik also uses.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` Docker network. It is declared `external: true`
- Free host ports: `8334`, `8444`, `8480`, `9000`, `9001`

```sh
docker network create proxy
```

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/cloud-stack
cp .env.example .env
```

Two variables, both for MinIO.

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `cloud-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   Required values: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`.

4. Click **Deploy the stack**.

### 3. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'cloud-minio|cloud-filestash|cloud-caddy'

curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:9000/minio/health/live   # -> 200
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:9001                    # -> 200
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:8480                    # -> 200
```

MinIO's health endpoint returning `200` is the meaningful check. The other two only confirm the ports are bound.

### 4. First login to MinIO

1. Open http://minio.mallard or http://192.168.1.121:9001.
2. Sign in with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.

   These are the *root* credentials, equivalent to full administrative control of the store. In a larger deployment you would create a service account for applications and keep the root pair for administration only.

3. Create a bucket, for example `uploads`.

The root user and password are applied at first start. Changing them in `.env` afterwards and redeploying **does not** change the stored credentials — MinIO keeps the original values in its configuration inside the `minio_data` volume. To change them, set them through the console: **Configuration → Identity & Access → Root Credentials**.

### 5. Connect Filestash to MinIO

1. Open http://filestash.mallard or http://192.168.1.121:8334.
2. Create the Filestash admin account on first use.
3. Add a backend: **Backend → Add a backend → S3**.

   | Field | Value |
   |---|---|
   | Endpoint | `http://cloud-minio:9000` |
   | Bucket | the bucket you created |
   | Access key | `MINIO_ROOT_USER` |
   | Secret key | `MINIO_ROOT_PASSWORD` |
   | Region | leave empty |

   Use the container name `cloud-minio:9000` from inside Docker. From a browser or an external tool, use `http://192.168.1.121:9000` — Filestash reaches the backend itself, so the endpoint has to be one it can resolve.

4. Filestash stores its backends and configuration in the `filestash_data` volume, so this survives a redeploy.

### 6. Caddy as an alternative entry point

`cloud-caddy` reverse-proxies Filestash on port 80 and is published on host port `8480`, so http://192.168.1.121:8480 is a second address for the same application, and http://caddy.mallard routes to it through Traefik.

---

## Operations

### Using the MinIO client

```sh
mc alias set mallard http://192.168.1.121:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc mb mallard/uploads
mc ls mallard/
mc cp ./file.txt mallard/uploads/
```

Run it in a throwaway container so nothing is installed on the host:

```sh
docker run --rm --network cloud-net --entrypoint sh minio/mc -c \
  "mc alias set m http://cloud-minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' && mc ls m/"
```

### Presigned URLs

```sh
mc share download --expire 24h mallard/uploads/file.pdf
```

### Buckets

| Command | Effect |
|---|---|
| `mc mb mallard/<name>` | Create |
| `mc rb --force mallard/<name>` | Delete, with contents |
| `mc ilm rule add --expire-days 30 mallard/<name>` | Expire objects after 30 days |

Set a lifecycle rule for anything that accumulates logs or uploads; `minio_data` has no automatic pruning.

### Where the Caddy configuration lives

The Caddyfile is an inline `configs:` block, not a file on the host:

```text
:80 {
  reverse_proxy cloud-filestash:8334
}
```

That defines an HTTP listener only. See the troubleshooting entry for `:8444`.

### Backup

```sh
docker run --rm -v cloud-minio_data:/data -v "$PWD":/dst minio/mc \
  mirror --overwrite /data /dst/minio-$(date +%F)
```

Or mirror between two MinIO instances with `mc mirror`. Volume snapshots taken while MinIO is running are not consistent; stop the container first for a plain `tar`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| MinIO console shows an old or wrong login | Root credentials are read from the volume at first start | Change them in the console under **Configuration → Identity & Access → Root Credentials** |
| `Access Denied` from Filestash after adding the backend | Endpoint, key or region mismatch | Endpoint must be `http://cloud-minio:9000`, region empty |
| Filestash cannot reach the backend | It was given a host address it cannot resolve, or `cloud-net` membership is missing | Use the container name from inside the stack |
| `http://minio.mallard` 502 | Traefik is not running, or the container is not on `proxy` | Deploy `devops-stack`; `docker network inspect proxy` |
| Nothing answers on `https://192.168.1.121:8444` | The Caddyfile only defines a `:80` site block, so Caddy listens on 80 inside the container and 443 is never bound | Use `8480`, or add an `https://` site block with a certificate to the `caddyfile` config |
| `bind: address already in use` on 9000 or 9001 | Another MinIO, or a leftover container from `plane-stack` | `docker ps --format '{{.Names}}\t{{.Ports}}'` |
| MinIO restarts repeatedly | `minio_data` corrupted, often by a hard power cut | `docker logs cloud-minio`; restore from a mirror, or remove the volume and start over |
| Filestash loses its backends | `filestash_data` removed | Re-add the backend; keep the volume |
| `caddy.mallard` 404 | The Traefik router for Caddy targets port 80, and Caddy answers on 80 only for the Filestash site | `curl -H 'Host: caddy.mallard' http://192.168.1.121/` to test routing separately from the app |

To see why any container fails:

```sh
docker logs --tail 30 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `8334` | `8334` | Filestash |
| `8444` | `443` | cloud-caddy HTTPS — **not listening**, see troubleshooting |
| `8480` | `80` | cloud-caddy HTTP |
| `9000` | `9000` | MinIO S3 API |
| `9001` | `9001` | MinIO console |

---

## Notes

- All three images are on `latest`, and `machines/filestash` in particular is a small project with infrequent releases. Check the changelog before upgrading.
- `APPLICATION_URL=http://192.168.1.121:8334` is hardcoded in the compose file for Filestash. It drives the links Filestash generates and OAuth callbacks; if the address is wrong, share links point nowhere. It is not driven by `.env`.
- MinIO runs with only a root user. There is no separate service account, so every client of this store holds full administrative credentials. Create a restricted service account for Filestash and keep the root pair private.
- `minio_data` has no retention policy and no automatic cleanup. It will fill the disk eventually.
- The MinIO image is `pgsty/minio`, a repackaged build. It behaves like upstream MinIO but is not the official image, so version numbers and support channels differ.
- `cloud-stack` does not join `data-net`, so it cannot reach the shared databases by container name. That is deliberate; nothing here needs them.