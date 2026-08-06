# Netboot

## What this is

netboot.xyz is a network boot server: any machine on the LAN whose firmware supports PXE boot can
select it as a boot source and load an OS installer, a live environment, or a recovery tool straight
over the network, with no USB stick involved. It runs as a single container on its own dedicated
host, on the shared `proxy` bridge network with a fixed address, and it serves three separate things:

- **TFTP on UDP port 69** — the very first thing a PXE-capable network card asks for at boot. It
  fetches a small iPXE boot loader binary over this protocol before it can do anything more
  sophisticated.
- **An HTTP asset server on an internal port 80** — once the iPXE binary from TFTP is running, it
  switches to HTTP(S) to fetch the boot menu and the actual OS images (kernels, initrd files, ISOs).
  This is proxied by Traefik at a separate domain from the management UI.
- **A web management UI on an internal port 3000** — where you customise the boot menu, browse the
  catalogue of available OS images, and pre-cache images locally so they do not have to be
  downloaded from the internet at boot time. This is proxied by Traefik at the service's main domain
  and sits behind single sign-on, since it is a human-operated dashboard, not something a booting
  machine talks to.

The one thing this container cannot do anything about is getting PXE clients to find it in the first
place — that is your DHCP server's job (option 66/67, "next-server" and "boot filename"), and most
consumer routers do not support it. See *Before you start*.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
docker compose version 2>/dev/null || true

id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent, install it from Docker's own repository and enable the service:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

**The `./data` working directory exists**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every path in this guide is relative to `<deploy-dir>`. Run all commands from there.

**The shared `proxy` bridge network exists**

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if it is missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

The `--ip-range` is the pool Docker hands out automatically; the fixed address you reserve for this
container in Step 2 must sit **outside** that pool.

**The reverse proxy (Traefik) is running**

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
curl -sI https://proxy.your-domain.com | head -1
```

**Single sign-on (Authelia) is running**

The management UI's route is forward-authenticated, so it must already be up, and your account must
already be permitted by the portal's access rules to reach this domain:

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

**DNS resolves for both domains this service needs**

```bash
dig +short netboot.your-domain.com
dig +short netboot-assets.your-domain.com
```

**UDP port 69 is free and reachable at the host firewall**

This is the one port this container needs published straight onto the host, not routed through
Traefik — see Step 2 for why.

```bash
ss -ulnp | grep ':69 ' || echo "port 69: free"
```

If the host firewall is UFW, confirm a rule allows it inbound; if not, add one before continuing:

```bash
sudo ufw status | grep 69
```

**You have decided the numeric UID and GID the container will run as**

Unlike the media-server containers elsewhere in this stack, nothing forces these numbers — there is
no existing media library this container has to match ownership with. Pick any UID/GID pair that is
not already in use for another purpose on this host; these are `<puid>`/`<pgid>` below.

**You have a DHCP server capable of pointing PXE clients here**

Most consumer routers do not implement DHCP options 66 (`next-server`) and 67 (`boot filename`).
Without one of those, PXE clients never learn this host's address and none of the rest of this guide
matters. A dedicated DHCP server (dnsmasq, ISC DHCP, a router running OpenWrt/dd-wrt) or your
existing DHCP server's vendor-specific option configuration is what you need; this container does
not provide DHCP itself.

## Setup

### Overview

1. Create the data directories.
2. Start the netboot.xyz container.
3. Wait for it to report healthy.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

sudo mkdir -p ./data/netboot
sudo chown <username>:<pgid> ./data/netboot
sudo chmod 0755 ./data/netboot

sudo mkdir -p ./data/netboot/config ./data/netboot/assets
sudo chown <puid>:<pgid> ./data/netboot/config ./data/netboot/assets
sudo chmod 0755 ./data/netboot/config ./data/netboot/assets
```

**Explanation**: the two-tier ownership matches the two audiences for these files. `./data/netboot`
itself belongs to your deploy account for the same reason every service's top-level directory does.
`config/` and `assets/` are owned by the **numeric** UID/GID the container's own init rewrites its
internal service account to at start — `config/` holds custom menu entries the running process
writes when you edit them from the web UI, and `assets/` is where it caches every OS image a client
downloads, so the same image is served locally on the next boot instead of being pulled from the
internet again. Leave either directory owned by your login account and the container's writes into
it fail silently or with permission errors the UI does not surface clearly.

---

#### Step 2: Start the container

```bash
docker run -d \
  --name netbootxyz \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TFTPD_OPTS='--tftp-single-port' \
  -v "$(pwd)/data/netboot/config:/config" \
  -v "$(pwd)/data/netboot/assets:/assets" \
  -p 69:69/udp \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.netbootxyz.entrypoints=https' \
  --label 'traefik.http.routers.netbootxyz.rule=Host(`netboot.your-domain.com`)' \
  --label 'traefik.http.routers.netbootxyz.tls=true' \
  --label 'traefik.http.routers.netbootxyz.middlewares=chain-auth@file' \
  --label 'traefik.http.routers.netbootxyz.service=netbootxyz' \
  --label 'traefik.http.services.netbootxyz.loadbalancer.server.port=3000' \
  --label 'traefik.http.routers.netbootxyz-assets.entrypoints=https' \
  --label 'traefik.http.routers.netbootxyz-assets.rule=Host(`netboot-assets.your-domain.com`)' \
  --label 'traefik.http.routers.netbootxyz-assets.tls=true' \
  --label 'traefik.http.routers.netbootxyz-assets.middlewares=chain-no-auth@file' \
  --label 'traefik.http.routers.netbootxyz-assets.service=netbootxyz-assets' \
  --label 'traefik.http.services.netbootxyz-assets.loadbalancer.server.port=80' \
  --health-cmd 'curl --fail http://localhost:3000 || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  --health-start-interval 10s \
  ghcr.io/netbootxyz/netbootxyz
```

**Explanation**:

`--ip <docker-ip>` fixes this container's address on the `proxy` network — the only network it is
attached to. It needs a stable address of its own the way every other service on this bridge does,
so nothing else on the network has to look it up by name for the pieces that are not HTTP.

`PUID`/`PGID` are honoured by this image's init exactly the way the media-server images are: it
rewrites its internal service account to those numbers before starting, so the files it writes into
`config/` and `assets/` come out owned the way Step 1 set them up.

`TFTPD_OPTS=--tftp-single-port` exists because of a mismatch between how TFTP normally works and how
Docker publishes ports. Standard TFTP does its initial request on port 69, then negotiates a **new,
random** UDP port for the actual file transfer — fine on a bare host, but this container only has
port 69 published through Docker's NAT, so a reply from some other random port would never reach the
client correctly. This flag keeps the entire exchange, control and data both, on port 69, which is
the one port actually published, so transfers complete through the container boundary instead of
timing out.

**Only port 69/UDP is published straight onto the host.** Nothing else is — the management UI and the
asset server are reached exclusively through Traefik. This is not a choice, it is what PXE requires:
a network card's firmware speaks raw TFTP to whatever address and port DHCP hands it (options
66/67), with no concept of a Host header, TLS, or a reverse proxy in front of it — that first hop
cannot be proxied by anything HTTP-based. Once the small iPXE binary fetched over TFTP is running, it
is capable of HTTP(S) itself, so every request after that — the boot menu, the OS images — goes out
through Traefik's normal TLS termination at `netboot-assets.your-domain.com` like any other service
here.

The two routers carry different middleware for the same reason Jellyfin's route does: the assets
router (`chain-no-auth@file`) is what booting machines talk to, and a booting machine cannot complete
a browser login redirect any more than a TV app can — the intrusion-prevention bouncer and security
headers still apply, only the forced sign-on is skipped. The main router (`chain-auth@file`) is the
human-facing dashboard, where a login redirect is exactly what you want.

The health check calls the management UI on port 3000, not the TFTP or asset side — a `healthy`
status means the whole application process is up and answering, which is a reasonable proxy for "the
TFTP and asset servers next to it in the same process are also up."

---

#### Step 3: Wait for it to report healthy

```bash
for i in $(seq 1 12); do
  status=$(docker inspect --format '{{.State.Health.Status}}' netbootxyz)
  [ "$status" = "healthy" ] && { echo "netboot: ready"; break; }
  echo "waiting for netboot ($status)..."; sleep 10
done
```

**Explanation**: the health-check start period is 30 seconds and the check itself runs every 90, so
a cold start can take a couple of minutes before the container reports `healthy` even though the
process came up quickly — this loop just avoids testing the service before it is actually listening.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Before you start, Step 1 |
| `<username>` | Owner of `./data/netboot` | The account you administer this host with | Step 1 |
| `<puid>` / `<pgid>` | Numeric UID/GID the container runs as | Any pair not already used for another purpose on this host — nothing existing has to match it | Before you start, Steps 1, 2 |
| `<docker-ip>` | Fixed address for this container on the `proxy` network | Any address inside `<docker-subnet>` but outside the auto-allocation pool | Step 2 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy`, or chosen fresh if you are creating the network | Before you start |

## Verification

```bash
# container is up and healthy
docker ps --filter 'name=^netbootxyz$'
docker inspect --format '{{.State.Health.Status}}' netbootxyz

# TFTP is listening on the host
ss -ulnp | grep :69

# the management UI is reachable and demands a login
curl -s -o /dev/null -w '%{http_code}\n' https://netboot.your-domain.com/
# expect a redirect toward auth.your-domain.com, not a bare 200

# the asset side is reachable without a login
curl -sI https://netboot-assets.your-domain.com/ | head -1

# TFTP itself answers, from another machine on the LAN
tftp <ip-address> -c get netboot.xyz.kpxe
```

**PXE boot test**: point a spare machine or VM at PXE boot. It should pull a small file over TFTP
almost instantly, then present the netboot.xyz OS selection menu a moment later — that second part is
the HTTP(S) side working through Traefik.

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull ghcr.io/netbootxyz/netbootxyz
docker rm -f netbootxyz
# re-run the docker run command from Step 2 verbatim
```

Menu customisations and cached images live under `./data/netboot`, so recreating the container loses
nothing.

**Logs:**

```bash
docker logs -f --tail 100 netbootxyz
```

**Pre-cache images** so PXE clients boot from local disk instead of the internet: use the web UI's
local-assets feature, then confirm they landed under `./data/netboot/assets`.

**Routine chores**: cached OS images can add up to several gigabytes. Check periodically:

```bash
du -sh ./data/netboot/assets
```

## Rollback / Uninstall

```bash
docker rm -f netbootxyz
sudo rm -rf ./data/netboot
```

Removing `./data/netboot` deletes both custom menu configuration and every cached image. Check the
size first if you are unsure whether that matters:

```bash
du -sh ./data/netboot/assets
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| PXE clients never find the boot server | Confirm port 69/UDP is actually published (`ss -ulnp \| grep 69`) and, separately, that your DHCP server sends option 66/67 pointing at this host — most consumer routers cannot do this and need a dedicated DHCP server instead. |
| TFTP answers but transfers hang or time out | `TFTPD_OPTS=--tftp-single-port` is missing from the container. Without it, TFTP tries to negotiate a random data port that Docker never published; recreate the container with the flag from Step 2. |
| The iPXE boot file loads but the OS menu never appears | The asset side (`netboot-assets.your-domain.com`) is unreachable — check its Traefik router and that DNS for that domain resolves; iPXE switches to HTTP(S) for everything after the initial TFTP fetch. |
| Management UI redirects in a loop instead of showing a login page | The router's middleware and the portal's access-control rules disagree — `chain-auth@file` on the router but no matching rule in the portal (or the reverse) produces this. Confirm both sides name the same domain. |
| Web UI unreachable through Traefik but the container is healthy | The load-balancer port label does not match the internal port. The router in Step 2 must point at `3000`; confirm with `docker exec netbootxyz ss -tlnp | grep 3000`. |
| Asset downloads at boot are slow | Nothing has been pre-cached yet — the container fetches OS images from the internet the first time a client requests one. Pre-cache commonly used images through the web UI's local-assets feature. |
| Disk usage under `./data/netboot/assets` keeps growing | Expected — every distinct image a client has booted gets cached. Remove entries you no longer need from the web UI, or clear the directory and let it re-populate. |
