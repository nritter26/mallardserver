# ai-stack

Local AI and automation: llama-swap serving quantised models on the GPU, LibreChat as the chat UI, SearXNG for private web search, n8n for workflow automation.

| Service | Purpose | URL |
|---|---|---|
| `llama-swap` | OpenAI-compatible LLM server, swaps models on demand | `192.168.1.121:11435` |
| `librechat` | Chat UI wired to llama-swap | http://192.168.1.121:3080 · http://chat.mallard |
| `searxng` | Private metasearch, used by LibreChat | http://search.mallard (see troubleshooting) |
| `n8n` | Workflow automation | http://192.168.1.121:5678 · http://n8n.mallard |

Files: [`docker-compose.yaml`](../../docker-compose/ai-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` and `data-net` Docker networks. Both are declared `external: true`
- **`data-stack` deployed** — LibreChat needs MongoDB, n8n needs PostgreSQL
- Free host ports: `3080`, `5678`, `11435`
- **An NVIDIA GPU and the NVIDIA Container Toolkit.** `llama-swap` requests the CUDA device and refuses to start without it
- **GGUF model files in `/data/models`** on the host, and an existing `/data/searxng/settings.yml`

### Host paths

Both are bind mounts, which makes them easy to get wrong. If the source path does not exist, Docker **creates a directory** in its place, and the service then fails in a way that looks like a bug in the image.

```sh
ls -l /data/models/            # must be a directory holding .gguf files
ls -l /data/searxng/settings.yml   # must be a FILE, not a directory
nvidia-smi                     # must work on the host
```

The three models the embedded llama-swap config expects:

```text
/data/models/qwen2.5-3b-instruct-q4_k_m.gguf
/data/models/qwen2.5-coder-3b-instruct-q5_k_m.gguf
/data/models/Phi-3-mini-4k-instruct-q4.gguf
```

If `/data/searxng/settings.yml` does not exist, remove the stray directory and write a minimal file, or just delete the volume mount line for one deploy:

```sh
sudo rm -rf /data/searxng        # only if it is an empty directory
sudo install -d /data/searxng
```

### GPU fit

The card is a GTX 1060 with 3 GB of VRAM. The configured `-ngl` values put the whole model on the GPU, which works for 3B and 4B models quantised to Q4/Q5. Anything larger needs a lower `-ngl`, and llama-swap then runs partly on CPU.

---

## Setup

### 1. Create the n8n database

n8n points at `postgres:5432` with database `n8n` and does not create it.

```sh
docker exec -it postgres psql -U <POSTGRES_USER>
```

```sql
CREATE DATABASE n8n;
\q
```

### 2. Prepare the environment file

```sh
cd docker-compose/ai-stack
cp .env.example .env
```

The four LibreChat secrets have exact format requirements, and LibreChat refuses to start if they are wrong:

```sh
openssl rand -hex 32   # LIBRECHAT_CREDS_KEY           -> 64 hex characters (256-bit)
openssl rand -hex 16   # LIBRECHAT_CREDS_IV            -> 32 hex characters (128-bit)
openssl rand -hex 32   # LIBRECHAT_JWT_SECRET          -> 64 hex characters
openssl rand -hex 32   # LIBRECHAT_JWT_REFRESH_SECRET  -> 64 hex characters
```

### 3. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `ai-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.
4. Click **Deploy the stack**.

### 4. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'llama-swap|searxng|librechat|n8n'

curl -s http://192.168.1.121:11435/v1/models | head -40
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:3080
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.121:5678
```

`/v1/models` returning the three model names means llama-swap read its config. It does not mean a model is loaded: llama-swap starts a model on first request and unloads it after the 300-second TTL.

Check the GPU is actually in use:

```sh
nvidia-smi
```

### 5. First LibreChat login

1. Open http://192.168.1.121:3080.
2. Register the first account. The first user becomes the administrator and can promote others under **Admin → Users**.
3. The model list comes from the embedded `librechat.yaml`, which points at `http://llama-swap:8080/v1` with `apiKey: "none"`. Three models should appear: `qwen-3b`, `qwen-coder-3b`, `phi-3-mini`.
4. Send a message. The first one is slow — llama-swap loads the model, and it takes as long as the file is large.

### 6. First n8n login

1. Open http://192.168.1.121:5678.
2. Create the owner account on the first screen. That account is the instance owner.

---

## Operations

### Talk to llama-swap directly

It speaks the OpenAI API on port 11435, no key required:

```sh
curl http://192.168.1.121:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-3b","messages":[{"role":"user","content":"hello"}]}'
```

llama-swap is only on `ai-net`, not `proxy`, so it has no `.mallard` hostname and no Traefik router. Reach it from the host port, or from a container on `ai-net`.

### Adding a model

Add it to the `swap_cfg` block in the compose file and drop the `.gguf` into `/data/models`:

```yaml
configs:
  swap_cfg:
    content: |
      healthCheckTimeout: 180
      models:
        "qwen-3b":
          cmd: /app/llama-server --port $${PORT} -m /models/qwen2.5-3b-instruct-q4_k_m.gguf -ngl 99 -c 4096
          ttl: 300
        "new-model":
          cmd: /app/llama-server --port $${PORT} -m /models/new-model-q4.gguf -ngl 20 -c 4096
          ttl: 300
```

Then add its name to the `models.default` list in the `librechat_cfg` block, and redeploy. Config blocks are read at container start, so `docker restart` is not enough.

### Choosing GPU layers

| Flag | Meaning | When to lower it |
|---|---|---|
| `-ngl 99` | Whole model on the GPU | Default; best speed |
| `-ngl 30` | First 30 layers on the GPU | Balanced |
| `-ngl 0` | CPU only | When VRAM is too small |

Lower the value in the `swap_cfg` block, then redeploy.

### Web search

LibreChat has search enabled with `SEARCH_PROVIDER=searxng` and `SEARXNG_URL=http://searxng:8080`. Both containers are on `ai-net`, so the name resolves.

> SearXNG carries Traefik labels but is **only** on `ai-net`. Traefik discovers containers on `proxy` only, so `http://search.mallard` does not resolve to a working router as the stack stands. Use `docker exec` to reach it, or add `proxy` to the service's `networks:` list.

### Data volumes

| Volume | Holds |
|---|---|
| `librechat_images` | Uploaded images for conversations |
| `librechat_uploads` | Uploaded files |
| `librechat_logs` | LibreChat application logs |
| `n8n_data` | Workflows, credentials, execution history |

Conversations live in the MongoDB database `LibreChat` on `data-stack`, not in a volume.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| `network data-net declared as external, but could not be found` | Network not created | `docker network create data-net`, then redeploy |
| `llama-swap` exits with `could not select device driver "" with capabilities: [[gpu]]` | NVIDIA Container Toolkit missing | Install it, confirm `nvidia-smi` works, redeploy |
| `llama-swap` starts but `/v1/models` is empty or 500 | `/data/models` has no `.gguf` files, or the filenames in `swap_cfg` do not match | `ls -l /data/models`; names must match the config exactly |
| `librechat` restarts, log mentions `CREDS_KEY` length | Secret is not 64 hex characters | `openssl rand -hex 32` and redeploy |
| `librechat` restarts, log mentions `CREDS_IV` | Secret is not 32 hex characters | `openssl rand -hex 16` and redeploy |
| `librechat` log shows a MongoDB connection error | `data-stack` is down, or `MONGO_USER`/`MONGO_PASSWORD` differ | Check `mongodb` is healthy; copy the pair from `data-stack/.env` |
| `librechat` UI loads but the model list is empty | llama-swap unreachable, or the config block was edited without redeploying | `curl http://192.168.1.121:11435/v1/models` from the host |
| Replies are extremely slow on the first message | The model is loading into VRAM | Expected. Later messages reuse the model for 300 seconds |
| OOM kill on the first message | Model larger than 3 GB of VRAM | Lower `-ngl`, or use a smaller quantisation |
| `searxng` exits immediately | `/data/searxng/settings.yml` is a directory, not a file | `ls -ld /data/searxng/settings.yml`; remove the directory and create a real file |
| Web search inside LibreChat returns nothing | SearXNG has no upstream configured, or the settings file is empty | Add `use_default: true` under `search.safe_search` in `settings.yml` and a `default` engine |
| `http://search.mallard` does not resolve to a working page | SearXNG is on `ai-net` only; Traefik only discovers `proxy` | See the note above: add `proxy` to the service's networks |
| `n8n` restarts, log shows `database "n8n" does not exist` | Step 1 skipped | `CREATE DATABASE n8n;`, then `docker restart n8n` |
| `n8n` webhook URLs are wrong after a host IP change | `N8N_HOST` and `WEBHOOK_URL` are hardcoded in the compose file | Edit them, plus `DOMAIN_CLIENT` and `DOMAIN_SERVER` for LibreChat |
| LibreChat shows the wrong URL after a host IP change | Same — both are hardcoded, not driven by `.env` | Edit the compose file and redeploy |
| Port `3080` or `5678` already in use | Another service holds it | `sudo ss -lpn 'sport = :3080'` |

To see why any container fails:

```sh
docker logs --tail 50 <container>
```

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `3080` | `3080` | LibreChat |
| `5678` | `5678` | n8n editor and webhook listener |
| `11435` | `8080` | llama-swap OpenAI API |

---

## Notes

- Every image is on `latest`. LibreChat, n8n and SearXNG in particular change environment variable names and config formats between releases. Pin them before relying on this.
- `DOMAIN_CLIENT`, `DOMAIN_SERVER`, `N8N_HOST` and `WEBHOOK_URL` are **hardcoded** to `192.168.1.121` in the compose file. They are the one part of this stack that `.env` cannot reach.
- `llama-swap` needs the CUDA image variant. The plain image has no GPU support and will exit immediately.
- `n8n` runs without `N8N_ENCRYPTION_KEY`. It generates and stores one in `n8n_data`, which means the credentials in that volume cannot be decrypted anywhere else. Back the volume up together with the key, or set one explicitly.
- The three models are all under 4B parameters. They are adequate for scripting questions and small local tasks, not for the kind of work a 3 GB card is often hoped to do.
- `/data/models` is mounted read-only into the container, which is correct. Writing models from inside the container is not possible by design.