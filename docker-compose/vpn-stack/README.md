# vpn-stack

Tailscale: mesh VPN and subnet router, so Tailscale clients can reach the LAN.

| Service | Purpose | URL |
|---|---|---|
| `tailscale` | Mesh VPN node, advertising `192.168.1.0/24` as a subnet route | none (a Tailscale IP, usually `100.x.y.z`) |

Files: [`docker-compose.yaml`](../../docker-compose/vpn-stack/docker-compose.yaml), `.env.example`, this README. Your real `.env` stays local and is never committed.

This is the smallest stack in the set — one service, one variable — but it has the most host-level requirements, because it does not use an isolated network namespace.

---

## Prerequisites

- Docker and Portainer running on the host
- A Tailscale account and an **auth key** from the admin console
- The `/dev/net/tun` device on the host
- The Tailscale kernel module loaded, because this stack sets `TS_USERSPACE=false`
- IP forwarding enabled on the host
- No `networks:` block: the service runs with `network_mode: host`

### Host requirements

Check all four before deploying:

```sh
ls -l /dev/net/tun                                   # must exist
lsmod | grep tailscale                               # module loaded
cat /proc/sys/net/ipv4/ip_forward                    # must be 1
docker run --rm --cap-add=NET_ADMIN --device=/dev/net/tun alpine \
  ip addr show tun0                                  # will fail until the module is loaded
```

Load the module and enable forwarding:

```sh
sudo modprobe tailscale
echo 'tailscale' | sudo tee /etc/modules-load.d/tailscale.conf
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-tailscale.conf
```

### Get an auth key

1. In the Tailscale admin console, open **Settings → Keys → Generate auth key**.
2. Choose **Reusable** if the key must survive re-creating the stack, and enable **Pre-approved** so the node does not sit waiting for approval.
3. Copy the key. It starts with `tskey-auth-`.

Without a pre-approved key the node stays offline until someone approves it in the console.

---

## Setup

### 1. Prepare the environment file

```sh
cd docker-compose/vpn-stack
cp .env.example .env
```

### 2. Deploy in Portainer

1. Go to **Stacks → Add stack**, name it `vpn-stack`.
2. Paste the contents of `docker-compose.yaml` into the Web editor.
3. Under **Environment variables**, load your `.env` with **Load variables from .env file**.

   Required values: `TS_AUTHKEY`.

4. Click **Deploy the stack**.

### 3. Verify

```sh
docker ps --format '{{.Names}}\t{{.Status}}' | grep tailscale
docker exec -it tailscale tailscale status
docker exec -it tailscale tailscale ip -4
```

`tailscale status` should show this host by name (`mallardserver2`, set as the container `hostname`) and no longer report "Logged out".

Confirm the subnet route was accepted:

```sh
docker exec -it tailscale tailscale status | grep -i subnet
```

An advertised route that the console has not approved shows up in the admin console under **Machines → mallardserver2 → Edit route settings**. Tick **192.168.1.0/24** and save.

### 4. Connect a client

1. Install Tailscale on a phone or laptop and sign in to the same account.
2. Accept subnet routes. On most clients this is a prompt; on Linux and Windows it is a toggle in the tray or app settings.
3. From the client, reach the host:

   ```sh
   ping 192.168.1.121
   curl http://192.168.1.121:8088        # Pi-hole
   curl http://gitea.mallard             # resolved on the LAN, not over Tailscale
   ```

Names ending in `.mallard` are the Pi-hole zone and only resolve on the LAN. Over Tailscale, use IP addresses or the node's MagicDNS name.

---

## Operations

### Inside the container

The image is a Tailscale node, so the CLI is available without a separate install:

```sh
docker exec -it tailscale tailscale status
docker exec -it tailscale tailscale ip -4
docker exec -it tailscale tailscale ping <peer>
docker exec -it tailscale tailscale netcheck
```

On the host, use `docker exec -it tailscale tailscale sudo <cmd>` for commands that need the node's own privileges.

### Logs

```sh
docker logs --tail 50 tailscale
```

### Reconnecting after an outage

If the node is stuck after a network change:

```sh
docker restart tailscale
docker exec -it tailscale tailscale status
```

Only log out as a last resort — it needs a new auth key:

```sh
docker exec -it tailscale tailscale logout
docker exec -it tailscale tailscale up --authkey=<TS_AUTHKEY>
```

### Identity and DNS

The container `hostname` is `mallardserver2`, which is the name clients see in `tailscale status`. The compose file does not set `--accept-dns`, so MagicDNS defaults apply: Tailscale resolves tailnet names, and the LAN resolver stays as configured on the host.

Two things can collide on the host side:

- Pi-hole already binds `:53`. If Tailscale is ever asked to run as a DNS forwarder on the host, it wants `127.0.0.53`, and the two services will fight. Keep Tailscale's DNS in MagicDNS-only mode.
- `network_mode: host` means Tailscale installs its own routes and firewall rules directly in the host network namespace, not in a container sandbox. Check `sudo iptables -t nat -L TS-ROUTER` and `ip route` when debugging.

### Removing the stack cleanly

```sh
docker rm -f tailscale
docker volume rm tailscale_state     # only after revoking the node in the console
```

Deleting the volume does not unregister the node. Revoke it in **Settings → Machines** first, or the console keeps showing a machine that can no longer exist.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts, log says `failed to create tailscale netstack` or `Tailscale needs to run in kernel mode` | `TS_USERSPACE=false` but the kernel module is not loaded | `sudo modprobe tailscale`, verify with `lsmod \| grep tailscale` |
| Container exits: `open /dev/net/tun: no such file or directory` | The device is missing | Load the module; the device appears with it |
| `tailscale status` says `Logged out` | `TS_AUTHKEY` empty, wrong, or already consumed | Check `.env`, update the stack, or set `TS_AUTHKEY` to a reusable key |
| Node shows in the console but stays `Offline` | Not approved | **Machines → mallardserver2 → Approve**, or generate the key with **Pre-approved** |
| Clients cannot reach `192.168.1.x` | Subnet route not advertised or not approved | `tailscale status \| grep -i subnet`, then approve it in the console |
| Subnet route rejected: `no route to host` from clients | IP forwarding disabled on the host | `sudo sysctl -w net.ipv4.ip_forward=1` and make it persistent |
| `netcheck` reports `UDP: false` | Tailscale cannot reach its DERP relays | Check the host's outbound UDP; a full-tunnel VPN or restrictive firewall usually causes this |
| Everything works over Wi-Fi but not over cellular | Carrier-grade NAT or UDP filtering | Tailscale falls back to DERP, which is slower but should still connect; check `tailscale netcheck` |
| LAN clients lose DNS after deploying | Tailscale changed the host resolver | Restore Pi-hole as the host resolver; keep Tailscale in MagicDNS-only mode |
| Changing `TS_ROUTES` has no effect | The old route is still advertised | Restart the container, then remove the stale route in the console |
| `docker exec tailscale tailscale ...` says `operation not permitted` | The command needs node privileges | Use `tailscale sudo <cmd>` inside the container |

---

## Ports

None. The service uses `network_mode: host` and publishes nothing; the host firewall is unchanged by the `ports:` key because there is none.

Tailscale listens on UDP `41641` and on the WireGuard interface it creates inside the host namespace. If `netcheck` reports `UDP: false`, that port is worth opening outbound.

---

## Notes

- `TS_USERSPACE=false` is deliberate: kernel mode is faster and is required for subnet routing to be useful. Userspace mode cannot advertise a subnet route at all.
- Because of `network_mode: host`, this container is not isolated. It shares the host's network namespace and its `NET_ADMIN` capability applies to the host's routing table. It also has `NET_RAW`, which allows packet capture and raw sockets.
- `TS_ROUTES=192.168.1.0/24` advertises the entire LAN, including this host's own address. Narrow it to a smaller range if only part of the LAN should be reachable.
- The auth key is stored in the environment and visible via `docker inspect`. Prefer a **reusable, ephemeral** key with a short expiry, and rotate it in the admin console when this host is decommissioned.
- `TS_STATE_DIR=/var/lib/tailscale` is where node identity lives, in the `tailscale_state` volume. Losing it means the host appears to Tailscale as a brand-new device.
- No `networks:` block means no `proxy` or `data-net` participation. Tailscale cannot reach the databases by container name; use `192.168.1.121` and the published ports.