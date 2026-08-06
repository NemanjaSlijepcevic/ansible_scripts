# Transmission

## What this is

Transmission is the BitTorrent client for the media stack. It runs as a single container on the NAS
machine — the same machine that holds the download drive and runs Sonarr, Radarr, Lidarr, Prowlarr
and Bazarr.

Two very different kinds of traffic reach it:

- **The web UI and the RPC API on port 9091.** From a browser this arrives through the reverse
  proxy at `https://transmission.your-domain.com`, behind single sign-on. From the `*arr`
  applications it arrives directly over the shared container network as `http://transmission:9091`,
  never through the proxy.
- **Peer traffic on port 51413, TCP and UDP.** This is published straight onto the host and must be
  reachable from the internet, or you download slowly and seed nothing.

Everything Transmission writes lands on the download drive: finished and in-progress torrents under
`<download-drive>/Download`, which the `*arr` applications import from. `<download-drive>/Download/Watch`
is a drop folder — any `.torrent` file copied there is picked up and queued automatically.

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
docker compose version 2>/dev/null || true

# your account must be in the docker group, or every command below needs sudo
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent, install it from Docker's own repository (the distro package is usually
too old for the compose plugin) and enable the service:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in these guides is bind-mounted from here. Run all commands from
`<deploy-dir>` so the relative paths resolve.

### The shared `proxy` bridge network exists

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows
where to send a request.

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

The `--ip-range` is the pool Docker hands out automatically; keep fixed container addresses
**outside** that pool so nothing is ever assigned an address you have reserved. Confirm the
addressing:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

### The reverse proxy (Traefik) is running

Traefik terminates TLS, owns ports 80 and 443, and routes to this service by the labels you put on
its container. It must be up before the service is reachable from a browser.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

`healthcheck --ping` exits 0 only when Traefik's own ping endpoint answers, which means the static
configuration parsed and the entrypoints are bound. If the container is missing or the ping fails,
nothing you publish below will be reachable.

Confirm from outside that TLS terminates and a certificate is in place:

```bash
curl -sI https://proxy.your-domain.com | head -1
```

### Authelia (single sign-on) is running

Any router that carries the `chain-auth@file` middleware is forward-authenticated by Authelia. If
Authelia is down, those routes return 500 rather than a login page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

### The service's DNS name resolves to this host

```bash
dig +short transmission.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### The download drive is mounted

```bash
findmnt -T <download-drive> || echo "<download-drive> is NOT a mount point"
df -h <download-drive>
```

If the drive is not mounted when the container starts, Docker happily creates an empty directory at
that path on the root filesystem and Transmission fills your system disk instead of the array.

## Setup

### Overview

1. Prepare the download drive and its ownership.
2. Create the configuration directory.
3. Open the peer port in the host firewall.
4. Start the container.
5. Point the `*arr` applications at it.

---

#### Step 1: Prepare the download drive

```bash
sudo mkdir -p <download-drive>/Download/Watch
sudo chown <puid>:<pgid> <download-drive>
sudo chmod 0755 <download-drive>
```

**Explanation**: The container drops its privileges to `<puid>:<pgid>` at start-up, so every path it
writes to must be owned by that pair of ids. Those ids are not chosen freely — they must be the same
ids the `*arr` applications run as, because Sonarr and Radarr hardlink or move finished files out of
`Download` and into the library, and a hardlink across a permission boundary fails with a copy that
doubles the disk usage at best and an import error at worst. Only the top of the drive is chowned,
not its whole tree: an existing library can hold millions of files and a recursive chown over a
spinning array takes hours while changing nothing that matters.

---

#### Step 2: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/transmission
sudo chown <username>:<pgid> ./data/transmission
sudo chmod 0755 ./data/transmission
```

**Explanation**: The container creates `config/` inside this directory on first start and writes
`settings.json`, the resume files and the statistics database there. It is deliberately owned by
your own account rather than by the container's ids, because you edit `settings.json` by hand far
more often than the container recreates it; the container makes its own subdirectory with the ids it
needs.

---

#### Step 3: Open the peer port

```bash
sudo ufw allow 51413/tcp comment 'transmission peer'
sudo ufw allow 51413/udp comment 'transmission peer'
sudo ufw status numbered | grep 51413
```

**Explanation**: 51413 is Transmission's listening port for incoming peer connections, in both TCP
(the peer wire protocol) and UDP (µTP and DHT). Without it open you can still connect out to peers,
so downloads appear to work, but nobody can connect in — your ratio never moves and private trackers
mark you unconnectable. If this machine sits behind a router doing NAT you must also forward
51413/tcp and 51413/udp to it there; the firewall rule alone is not enough.

---

#### Step 4: Start the container

```bash
docker run -d \
  --name transmission \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TZ=Europe/Belgrade \
  -e TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false \
  -v "$(pwd)/data/transmission/config:/config" \
  -v "<download-drive>/Download:/downloads" \
  -v "<download-drive>/Download/Watch:/watch" \
  -p 51413:51413 \
  -p 51413:51413/udp \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.transmission.entrypoints=https' \
  --label 'traefik.http.routers.transmission.rule=Host(`transmission.your-domain.com`)' \
  --label 'traefik.http.routers.transmission.tls=true' \
  --label 'traefik.http.routers.transmission.middlewares=chain-auth@file' \
  --label 'traefik.http.services.transmission.loadbalancer.server.port=9091' \
  --health-cmd 'curl --fail http://localhost:9091/transmission/web/ || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  ghcr.io/linuxserver/transmission:latest
```

**Explanation**: `TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false` turns off Transmission's own
username/password prompt. That is safe only because of the two paths described at the top: from the
outside the only way in is the `chain-auth@file` middleware, which forces an Authelia login before
Traefik ever forwards a byte, and from the inside only containers already on the `proxy` network can
reach port 9091 — that port is never published on the host. Leaving RPC auth on would mean keeping a
second password in sync inside four `*arr` configurations for no additional protection. The
consequence to remember is that anything that can reach the container network has full control of
Transmission, so never publish 9091 and never attach an untrusted container to `proxy`.

The fixed `--ip` on the shared network means the address in the proxy's routing table and in any
firewall rule stays put across restarts. `/downloads` is where completed and incomplete torrents
live, and `/watch` is scanned every few seconds for new `.torrent` files. Timezone matters more than
it looks: the scheduler that throttles speeds by time of day reads it, and the web UI timestamps
every log line with it.

---

#### Step 5: Point the download managers at it

Each of Sonarr, Radarr and Lidarr needs Transmission registered as a download client. In each
application's UI: **Settings → Download Clients → + → Transmission**, then

| Field | Value |
| --- | --- |
| Host | `transmission` |
| Port | `9091` |
| Use SSL | off |
| Username | `<username>` |
| Password | `<secret>` |
| Category | `sonarr` / `radarr` / `lidarr` |

**Explanation**: The host is the container name, not an IP and not the public domain — the shared
container network provides name resolution, and going out through the public name would bounce off
the single sign-on layer and fail with an HTML login page where the application expects JSON. The
username and password fields are filled in for completeness and are ignored while RPC authentication
is off; leaving them set means that turning authentication back on later does not break the
integration. The category makes Transmission label each torrent, which is how each application finds
its own downloads again and how it avoids importing another application's files.

## Verification

```bash
docker ps --filter 'name=^transmission$'
docker inspect --format '{{.State.Health.Status}}' transmission
```

The web UI, from the host itself:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' http://localhost:9091/transmission/web/ 2>/dev/null || \
  docker exec transmission curl -sf -o /dev/null -w '%{http_code}\n' http://localhost:9091/transmission/web/
```

Through the proxy — expect a redirect to the sign-on page rather than a direct 200:

```bash
curl -sI https://transmission.your-domain.com | head -1
```

The RPC API as another container sees it:

```bash
docker exec sonarr curl -s -o /dev/null -w '%{http_code}\n' http://transmission:9091/transmission/rpc
```

`409` is the correct answer here: Transmission rejects the first RPC call and hands back a session
id header that the client must repeat. A `409` proves the daemon is answering; a connection refused
means the container is not on the network.

Confirm the peer port is really published and reachable:

```bash
docker port transmission
ss -ulnp | grep 51413
```

In the web UI, a torrent's peer list showing incoming connections is the only end-to-end proof that
port forwarding works.

## Updating & day-to-day

Pull a new image and recreate the container with the same command from Step 4:

```bash
docker pull ghcr.io/linuxserver/transmission:latest
docker stop transmission && docker rm transmission
# re-run the docker run command from Step 4
```

Configuration and torrent state live in `./data/transmission/config`, outside the container, so
nothing is lost.

Logs:

```bash
docker logs transmission --tail 100 -f
```

Routine chores:

- Editing `./data/transmission/config/settings.json` requires the container to be **stopped** first —
  Transmission rewrites the whole file on shutdown and will overwrite your edit otherwise.
  ```bash
  docker stop transmission
  sudo -e ./data/transmission/config/settings.json
  docker start transmission
  ```
- Queue a torrent without the UI by dropping the file into the watch folder:
  ```bash
  sudo cp <file>.torrent <download-drive>/Download/Watch/
  ```
- Watch free space on the download drive; the `*arr` applications only delete a torrent once their
  retention rules say so, and a full drive stalls every download silently.
  ```bash
  df -h <download-drive>
  ```

## Rollback / Uninstall

```bash
docker stop transmission && docker rm transmission
rm -rf ./data/transmission
sudo ufw delete allow 51413/tcp
sudo ufw delete allow 51413/udp
```

Downloaded files under `<download-drive>/Download` are untouched by this. Remove them separately, and
only after checking that the `*arr` applications have imported what they need:

```bash
du -sh <download-drive>/Download
```

Also remove the download client entry from Sonarr, Radarr and Lidarr, otherwise each one logs a
connection failure on every search.

## Troubleshooting

**The container starts and immediately stops**
Check the logs for a permissions error on `/config`. It means `<puid>:<pgid>` cannot write into
`./data/transmission/config`. Fix with `sudo chown -R <puid>:<pgid> ./data/transmission/config`.

**Everything downloads at a few KB/s and nothing seeds**
The peer port is not reachable. Verify all three layers: `docker port transmission` shows 51413
published, `sudo ufw status` allows it in both protocols, and the router forwards it to this
machine. Transmission's UI reports "Port is closed" under Preferences → Network.

**Sonarr/Radarr report "Unable to connect to Transmission"**
They reach it by container name over the shared network. Confirm both are on it and that the name
resolves:
```bash
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' transmission sonarr
docker exec sonarr getent hosts transmission
```

**Imports fail with "Couldn't import episode … permission denied"**
The download drive and the library are owned by different ids, or the `*arr` container runs as a
different `<puid>` than Transmission. Both must use the same pair, and both must mount the download
path at a path the other can also see.

**A browser gets a login page from the API**
You pointed an application at `https://transmission.your-domain.com` instead of
`http://transmission:9091`. The public name always goes through single sign-on.

**Torrents sit at "Queued" forever**
Transmission's own queue limits are in Preferences → Queue. Also check free space — with less than
the size of the active torrents remaining, Transmission pauses rather than fails.

**The watch folder ignores a file**
The file must end in `.torrent` and be readable by `<puid>`. Files written directly by root with
mode 0600 are silently skipped.
