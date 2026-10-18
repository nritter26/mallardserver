# dns-stack

Pi-hole: ad-blocking DNS for the whole LAN, and the resolver for the `.mallard` zone that every other stack's hostname depends on.

Deploy this early. Every `http://<service>.mallard` URL in the other runbooks resolves through this stack, and so does Traefik's routing.

| Service | Purpose | URL |
|---|---|---|
| `pihole` | DNS filtering, and the `.mallard` wildcard | http://192.168.1.121:8088 · http://pihole.mallard |

Files: [`docker-compose.yaml`](../../docker-compose/dns-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

---

## Prerequisites

- Docker and Portainer running on the host
- The `proxy` Docker network. It is declared `external: true`, so Compose will not create it
- Free host ports: `53` (TCP **and** UDP), `8088`
- Permission to change the DNS settings of the LAN's DHCP server (usually the router)

```sh
docker network create proxy
```

---

## Setup

### 1. Write the environment file

```sh
cd docker-compose/dns-stack
cp .env.example .env
```

Three variables, and one of them is easy to get wrong:

| Variable | Why it matters |
|---|---|
| `HOST_IP` | The address every `*.mallard` name points to. This must be this host's **LAN** IP (`192.168.1.121`), not `127.0.0.1` and not the Docker bridge address |
| `PIHOLE_PASSWORD` | Password for the Pi-hole admin web interface |
| `TZ` | Timezone |

The compose file uses `HOST_IP` in exactly one place:

```text
FTLCONF_misc_dnsmasq_lines=address=/mallard/${HOST_IP}
```

Get the address from the host itself rather than guessing:

```sh
ip -4 addr show | grep inet
```

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `dns-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   Required values: `TZ`, `PIHOLE_PASSWORD`, `HOST_IP`.

4. Click **Deploy the stack**.

### 3. Verify

```sh
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep pihole

dig @192.168.1.121 pihole.mallard +short     # -> 192.168.1.121
dig @192.168.1.121 gitea.mallard +short      # -> 192.168.1.121 (even before Gitea runs)
```

The second command resolving is expected. Pi-hole answers the `.mallard` wildcard from the `address=` line regardless of whether anything is listening on the other end.

Blocking check:

```sh
dig @192.168.1.121 doubleclick.net +short   # -> 0.0.0.0 when blocked
```

### 4. Point the LAN at Pi-hole

This is the step people skip, and nothing changes on the devices until it is done.

1. In the router's DHCP settings, set the DNS server to `192.168.1.121` (LAN DNS / "DNS server" field).
2. On an existing client, either restart the client or flush its cache. On Windows: `ipconfig /flushdns`. On Linux and Android: reboot the Wi-Fi connection.
3. Confirm:

   ```sh
   nslookup pihole.mallard <some-client-ip>
   ```

   The server in the answer must be `192.168.1.121`.

### 5. First login

1. Open http://192.168.1.121:8088 or http://pihole.mallard.
2. Sign in with `PIHOLE_PASSWORD`.
3. In **Settings → System**, set the interface to listen on the LAN. The compose file already sets `FTLCONF_dns_listeningMode=all`, which covers this.
4. Leave the upstream resolvers at `1.1.1.1` / `1.0.0.1` unless you have a reason to change them.

---

## Operations

### DNS is down for the whole LAN

```sh
docker stop pihole
```

Clients fall back to their DHCP-provided resolver only if the router advertises a second one. If Pi-hole is the only DNS server the router hands out, stopping it takes DNS with it — configure a fallback before relying on it.

### Add a blocklist

Do it in the web interface under **Settings → DNS lists**, not in the compose file. Lists live in the `pihole_etc` volume, so they survive a redeploy.

### Allowlist a domain

**Settings → Lists → Allowlist**. Needed when something the stack depends on resolves through an ad-blocked domain.

### Change `HOST_IP`

`HOST_IP` is only read at container start, and the dnsmasq line is baked into the volume at first initialisation. To move the host to a new address:

1. Update `HOST_IP` in `.env`.
2. Update the router's DNS setting to the new address.
3. Update every `traefik.http.routers.*.rule` and the hardcoded addresses in `ai-stack` and `cloud-stack` that still point at `192.168.1.121`.

### Inspect queries

**Menu → Query log** in the web interface, or:

```sh
docker exec -it pihole tail -f /var/log/pihole/pihole.log
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `network proxy declared as external, but could not be found` | Network not created | `docker network create proxy`, then redeploy |
| `pihole` will not start, `Address already in use` | systemd-resolved or another resolver holds port 53 | See below |
| Devices resolve nothing, but `dig @192.168.1.121` works from the host | The router is not handing out `192.168.1.121` as DNS | Set the router's DHCP DNS option, then flush client caches |
| `pihole.mallard` does not resolve from a client | Client is still using the router's DNS, or the client has a cached NXDOMAIN | Flush the client cache; confirm with `nslookup` which server answered |
| `.mallard` names resolve to something odd | `HOST_IP` was set to a container or loopback address | Set it to the host's LAN IP and redeploy |
| `http://pihole.mallard` returns 502 but `:8088` works | Traefik is not running, or the container is not on `proxy` | Deploy `devops-stack`; check `docker network inspect proxy` |
| Web interface asks to create a password instead of accepting `PIHOLE_PASSWORD` | The volume was initialised before the variable was set | Set the password in the UI, then update `.env` so a fresh deploy matches |
| Ad-blocking works but a site is broken | Over-aggressive list or missing CNAME | Allowlist the domain, then re-test |
| `docker logs pihole` shows `dnsmasq` errors about `/etc/pihole/dnsmasq.d` | Volume was created by a different Pi-hole major version | Back up `/data`, remove the `pihole_etc` volume, redeploy |

### Port 53 already in use

Ubuntu 26.04 runs `systemd-resolved`, which binds `127.0.0.53:53`. That normally does not collide with a container publishing `0.0.0.0:53`, but it does on setups where resolved is configured to listen on all interfaces. Check what holds the port:

```sh
sudo ss -lupn 'sport = :53'
```

If `systemd-resolved` is the culprit, either disable it and point `/etc/resolv.conf` at `127.0.0.1` (Pi-hole takes over as the host resolver too, which is the recommended setup), or remap the host side of the compose `ports:` entry to `5353:53/tcp` and `5353:53/udp` and forward that port in the router.

---

## Ports

| Host port | Container port | Service |
|---|---|---|
| `53` | `53/tcp` | Pi-hole DNS |
| `53` | `53/udp` | Pi-hole DNS |
| `8088` | `80/tcp` | Pi-hole web interface |

---

## Notes

- The image is `pihole/pihole:latest`. Pi-hole v6 changed both the environment variable scheme and the admin password flow; if the UI behaves unexpectedly after an upgrade, compare against the version notes for that release.
- `FTLCONF_webserver_api_password` sets the password at first start only. Changing it later in `.env` and redeploying does not change the stored password — change it in the web interface.
- The container needs `cap_add: [NET_ADMIN]` to rewrite `iptables` for its blocking. Some hardened hosts or rootless Docker setups refuse this.
- `dns-stack` publishes port 53 on every interface. Nothing authenticates DNS queries. If the LAN is not fully trusted, restrict the `ports:` entries or firewall 53 at the router.
- The `.mallard` TLD is a real reserved TLD for private use, so it cannot leak to the internet even if `upstreams` is misconfigured.