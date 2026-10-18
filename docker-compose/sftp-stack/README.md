# sftp-stack

A single SFTP server backed by `/data/ftp` on the host, for file transfer to the server from outside.

| Service | Purpose | URL |
|---|---|---|
| `sftp` | SFTP server, one user | `sftp://192.168.1.121:2224` |

Files: [`docker-compose.yaml`](../../docker-compose/sftp-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- Free host port `2224`
- The directory `/data/ftp` on the host, owned by the UID and GID you are about to configure
- No networks block: the service runs on Docker's default `bridge` network and takes no part in `proxy` or `data-net`

---

## Setup

### 1. Create the host directory

The container maps `/data/ftp` to `/home/<user>/upload`, so the host directory must exist and must belong to the same UID and GID the container runs as. If they do not match, the login succeeds and every upload fails.

```sh
sudo mkdir -p /data/ftp
sudo chown 1000:1000 /data/ftp
sudo chmod 755 /data/ftp
```

Pick a UID and GID that exist on the host and are not already in use by a system account — 1000 is the first user account, usually `mallard`. Confirm:

```sh
id mallard
getent passwd 1000
```

Using the host user's own UID means files transferred over SFTP are owned by that user on the host and can be moved or served without a second `chown`.

### 2. Prepare the environment file

```sh
cd docker-compose/sftp-stack
cp .env.example .env
```

```sh
openssl rand -base64 18      # SFTP_PASSWORD
```

### 3. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `sftp-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   | Variable | Notes |
   |---|---|
   | `SFTP_USER` | Login name. Also the home directory path in the volume mount |
   | `SFTP_PASSWORD` | Login password |
   | `SFTP_UID` | Must match the owner of `/data/ftp` on the host |
   | `SFTP_GID` | Must match the group of `/data/ftp` on the host |

4. Click **Deploy the stack**.

### 4. Verify

```sh
docker ps --format '{{.Names}}\t{{.Status}}' | grep sftp

# from the host, as the same user
sftp -P 2224 change-me@192.168.1.121
```

In the `sftp>` prompt:

```text
pwd                 # -> /upload
ls -l
put /etc/hostname .
ls
```

If `put` reports `Permission denied`, the UID/GID do not match the host directory. That is the most common failure in this stack.

### 5. Connect a client

FileZilla:

| Field | Value |
|---|---|
| Host | `192.168.1.121` |
| Port | `2224` |
| Protocol | **SFTP** |
| Logon type | Normal |
| Username | `SFTP_USER` |
| Password | `SFTP_PASSWORD` |

Also works from Windows Explorer over `sftp://192.168.1.121:2224/`, and from VS Code's Remote-SSH extension if you prefer an editor workflow.

The host key appears on first connection. Accept it after checking the fingerprint on the server:

```sh
docker exec -it sftp ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

---

## Operations

### Change the password

```sh
docker exec -it sftp passwd <SFTP_USER>
```

Updating `.env` and redeploying does not change the stored password. The `atmoz/sftp` entrypoint runs `chpasswd` only at container start, and only if the user is being created; on an existing user the password in `.env` is ignored.

### Change the user name

The name is baked into the volume path:

```yaml
volumes:
  - /data/ftp:/home/${SFTP_USER}/upload
```

Renaming means a new home directory and a new user. Create the new user, move the files, then update `.env`:

```sh
docker exec -it sftp useradd -m -u 1000 -s /bin/bash <new-user>
```

### Add a second user

The image supports one user per container. A second account means a second service in this compose file, with its own `command:` and its own host directory:

```yaml
  sftp-2:
    image: atmoz/sftp:latest
    container_name: sftp-2
    restart: unless-stopped
    command: ${SFTP2_USER}:${SFTP2_PASSWORD}:1000:1000
    ports:
      - "2225:22"
    volumes:
      - /data/ftp2:/home/${SFTP2_USER}/upload
```

Bind it to host port `2225` so the two do not collide.

### What the user can do

`atmoz/sftp` creates a restricted account: no shell, no port forwarding, no agent forwarding. `SFTP_USER` can read and write `/data/ftp` and nothing else on the host.

It is still an SSH server. A determined user with valid credentials can reach anything readable by the mapped UID inside the container's view of the filesystem. Do not map `SFTP_UID` to 0.

### Check what is on disk

```sh
ls -l /data/ftp
du -sh /data/ftp
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bind: address already in use` on 2224 | Another SFTP server, or a stale container | `sudo ss -lpn 'sport = :2224'` |
| Login rejected | Wrong `SFTP_USER` or `SFTP_PASSWORD` | The password in `.env` is only applied at user creation; reset with `docker exec -it sftp passwd <user>` |
| Login succeeds, `ls` fails with `Permission denied` | UID/GID do not match the host directory | `sudo chown <SFTP_UID>:<SFTP_GID> /data/ftp` |
| Uploads land in a Docker volume, not on the host | `/data/ftp` did not exist, so Docker created it as root | `ls -ld /data/ftp`; fix ownership, move the data out of the anonymous volume, redeploy |
| `422 Invalid port` or `220` in FileZilla | Protocol set to FTP | Switch to **SFTP** |
| Slow transfers over Tailscale | Cipher negotiation | Modern SFTP clients default to strong ciphers; if a legacy client is slow, enable compression or move large transfers over the LAN |
| Container restart loses the user | The account lives in the container filesystem, and the compose file has no volume for it | Redeploying recreates the user from `command:`. That is why changing `.env` does not change an existing password |
| `sftp` command hangs on `put` | Path does not exist | `ls -l /data/ftp` on the host; the mount must exist before first deploy |

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `2224` | `22` | SFTP |

Remapped from 22 to stay clear of the host's own `sshd`.

---

## Notes

- The compose file has no `networks:` block at all, so the service is on Docker's default `bridge`. It is reachable from the LAN on the published port and from nowhere else.
- No host path is configurable: `/data/ftp` is hardcoded, as is port `2224`.
- Credentials live in the container's own filesystem, not a volume, so they are lost on recreate and restored from `.env`. That is convenient and also means `.env` is the only place the password exists — protect it.
- All transfers are encrypted, but the service is reachable from every address that can route to `192.168.1.121`. If it should be reachable only over Tailscale, remove the `ports:` entry and reach it through the subnet route.