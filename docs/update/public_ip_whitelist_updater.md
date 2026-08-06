# Public IP Allow-list Updater

## What this is

A small container on the public-facing server that keeps the reverse proxy's IP allow list pointed at
the home network's current public address. It polls the public IP tracker running on the monitoring
machine (back at home), and whenever the reported address differs from what is currently allow-listed,
it rewrites the proxy's allow-list file on this host in place.

The reason this needs to exist at all: this host publishes services from a VPS on the open internet,
and every one of its routers shares the same IP allow-list middleware — the same list that lets the
household reach this server directly, bypassing the CDN in front of it, and lets Cloudflare's own edge
ranges through so proxied traffic is not itself blocked. The household's address is assigned by a
consumer ISP and changes without warning. Without something watching for that and updating the list,
the household would eventually be locked out of its own server with no way back in except editing the
file by hand from a console session.

The container mounts the live allow-list file **read-write**, and the reverse proxy is configured to
watch its rules directory for changes — so an update here takes effect within moments, with no proxy
restart and no interruption to traffic already flowing.

---

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

Every service keeps its configuration and state in `./data/<service>` under this directory, and every
container path below is bind-mounted from here. Run all commands from `<deploy-dir>` so the relative
paths resolve.

### The shared `proxy` bridge network exists

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

### The reverse proxy is running, and its dynamic rules directory exists

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
ls -l ./data/traefik/rules/default-whitelist.yml
```

The last command must show a file, not "No such file or directory" — that file is what this container
is going to rewrite. It is deployed once as part of the reverse proxy's own setup, seeded with the LAN
ranges (and, on this host, Cloudflare's published edge ranges) that every router's allow-list
middleware reads from. This container only ever edits the household's single dynamic entry inside it;
it never touches the static ranges the file starts out with.

### The public IP tracker is reachable, with the same bearer token

This service's only job is to relay what the tracker reports, so the tracker must already be running
and answering:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer <secret>' \
  https://node-ip.your-domain.com/current_ip
```

A 200 here means the tracker is up and the token is accepted. If you have not already picked a token
shared between the two services, do that now:

```bash
openssl rand -hex 32
```

### A local DNS resolver is reachable from this host

```bash
dig @<ip-address> node-ip.your-domain.com +short
```

The container is pointed at this resolver explicitly rather than whatever the host's default is, so
that container-internal name resolution stays consistent regardless of what else changes on the host.

---

## Setup

### Overview

1. Create the data directory and the log file the container appends to.
2. Start the container.
3. Install log rotation for the log file.

---

#### Step 1: Create the data directory and log file

```bash
mkdir -p ./data/public_ip_whitelist_updater
sudo chown <username>:<pgid> ./data/public_ip_whitelist_updater
sudo chmod 0744 ./data/public_ip_whitelist_updater

sudo touch ./data/public_ip_whitelist_updater/app.log
sudo chown <username>:<pgid> ./data/public_ip_whitelist_updater/app.log
sudo chmod 0640 ./data/public_ip_whitelist_updater/app.log
```

**Explanation**: as with every other single-file bind mount in this stack, the log has to exist as a
**file** before the container starts — Docker creates a directory at a bind-mount source that is
missing, and the application then fails to open its own log with an error that looks like a
permissions problem and is not. Ownership here is the ordinary deploy account, not a fixed numeric
image uid, which is the one visible difference from the tracker's own log file on the other host.

---

#### Step 2: Start the container

```bash
docker run -d \
  --name public_ip_whitelist_updater \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <ip-address> \
  -e API_IP_TOKEN='<secret>' \
  -e NODE_IP_DOMAIN='https://node-ip.your-domain.com/current_ip' \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/traefik/rules/default-whitelist.yml:/app/configuration.yml:rw" \
  -v "$(pwd)/data/public_ip_whitelist_updater/app.log:/app/app.log:rw" \
  --health-cmd 'pgrep -f main.py' \
  --health-interval 60s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 15s \
  <dockerhub-user>/public_ip_updater:latest
```

**Explanation**: `API_IP_TOKEN` must be the exact value the tracker was started with — this is the
credential presented as `Bearer` auth against `NODE_IP_DOMAIN`, and a mismatch fails silently from
here, showing up only as an allow list that never updates. `--dns <ip-address>` points the container
at the local resolver rather than whatever the host's own default is, so that name resolution for the
tracker's domain and anything else the container needs stays consistent regardless of what changes
elsewhere on the host.

There is no `traefik.*` label on this container and no router — it has no web interface of its own,
it is a background loop, so it never needs to be published.

The `default-whitelist.yml` mount is the one that matters: it is writable, and the container rewrites
it, not appends to it. The file's `sourceRange` list has to represent the current state of the world —
the LAN ranges, Cloudflare's ranges on this host, and **one** entry for the household's current
address — not a running history of every address the household has ever had. Appending instead of
rewriting would mean a former address, quite possibly reassigned to an unrelated customer by the ISP
by the time it is stale, stays allow-listed forever; every entry left in the file after a change is a
standing door left open on the origin server for no reason. The file provider on the reverse proxy
watches this directory for changes and reloads automatically, so nothing here needs to (or should)
restart the proxy — a restart would just be a slower, noisier way to get the same effect the file
watcher already provides for free.

The health check here does not probe an HTTP endpoint like the tracker's does, because this container
does not expose one — it just checks that the update loop's own process is still alive.

---

#### Step 3: Install log rotation

```bash
sudo tee /etc/logrotate.d/whitlist_updater >/dev/null <<EOF
$(pwd)/data/public_ip_whitelist_updater/app.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 <username> docker
}
EOF

sudo chmod 0644 /etc/logrotate.d/whitlist_updater
```

**Explanation**: the file is named `whitlist_updater`, missing an `e` — that is not a typo to fix, it
is the exact name this setup has always used, and changing it now would leave the old rule in
`/etc/logrotate.d/` as an orphan while a second, differently-named rule rotates the same file; keep
the name exactly as shown for compatibility with whatever else on this host may already expect it.
Unlike the tracker's own rotation, this one does **not** use `copytruncate` — it lets logrotate rename
the file aside and create a fresh one, which is the ordinary behaviour for a log nothing else holds a
long-lived write handle on. If you ever have a second process tailing this exact file by path (a
log-notification container, for instance), confirm it tolerates a renamed-and-recreated log, or
recreate it after every rotation the same way you would for a single-file bind mount elsewhere in this
stack.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | working directory on the host that holds `./data` | the deploy account's home, or a dedicated directory | Before you start |
| `<username>` / `<pgid>` | account that owns `./data`, and its group | the unprivileged deploy account, group `docker` | Before you start, Steps 1, 3 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Step 2 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `<ip-address>` | local DNS resolver handed to the container | the resolver this host already uses for internal names | Before you start, Step 2 |
| `<secret>` | bearer token for the tracker's `/current_ip` | must be identical to the value set on the public IP tracker | Before you start, Step 2 |
| `node-ip.your-domain.com` | the tracker's public domain | the domain the tracker's own guide set up | Before you start, Step 2 |
| `<dockerhub-user>` | registry account the image is published under | the account that built `public_ip_updater` | Step 2 |

---

## Verification

```bash
docker ps --filter 'name=^public_ip_whitelist_updater$'
docker inspect --format '{{ .State.Health.Status }}' public_ip_whitelist_updater

# it is actually calling the tracker and getting an answer
docker logs public_ip_whitelist_updater --tail 20

# the allow-list file was rewritten, not left at its seeded state
cat ./data/traefik/rules/default-whitelist.yml

# the reverse proxy picked the change up without a restart
docker logs traefik --tail 20 | grep -i -E 'rules|provider'

# the container is appending to its own log on the host
tail -3 ./data/public_ip_whitelist_updater/app.log
```

If `default-whitelist.yml` still shows only the ranges seeded at deploy time with no address that
looks like a household WAN address, the container has not successfully written yet — check its logs
for the token or DNS problems covered in *Troubleshooting*.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull <dockerhub-user>/public_ip_updater:latest
docker stop public_ip_whitelist_updater && docker rm public_ip_whitelist_updater
# re-run the docker run command from Step 2
```

The allow-list file and the log both live on the host, so recreating the container loses no state and
does not touch the file's current contents.

**Logs:**

```bash
docker logs --tail 100 -f public_ip_whitelist_updater
tail -f ./data/public_ip_whitelist_updater/app.log
```

A successful update is worth watching for once after any change to the tracker or its token — silence
here is ambiguous between "nothing has changed" and "every attempt is failing", and the only way to
tell them apart is to read a log line.

**Routine chores:** rotate the shared bearer token occasionally, and update it on **both** hosts in
the same maintenance window — a token changed on one side and not the other breaks this container
silently rather than loudly.

---

## Rollback / Uninstall

```bash
docker stop public_ip_whitelist_updater && docker rm public_ip_whitelist_updater
sudo rm -rf ./data/public_ip_whitelist_updater
sudo rm -f /etc/logrotate.d/whitlist_updater
docker rmi <dockerhub-user>/public_ip_updater:latest
```

Removing this container leaves `default-whitelist.yml` frozen at whatever address was last written.
That is not itself a problem — the reverse proxy keeps using it exactly as it is — but the household
will eventually be locked out the next time its address changes with nothing left running to update
it. Edit the file by hand at that point if you have removed this container permanently:

```bash
sudo nano ./data/traefik/rules/default-whitelist.yml
```

The reverse proxy picks up a manual edit the same way it picks up this container's own edits — no
restart needed.

---

## Troubleshooting

**Allow-list never updates, container looks healthy.**
The health check here only proves the process is alive, not that it is succeeding — check the token
first:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer <secret>' https://node-ip.your-domain.com/current_ip
```
A non-200 means the token this container was started with does not match the tracker's.

**Allow-list never updates, and the token checks out.**
DNS resolution inside the container may be failing. Confirm:
```bash
docker exec public_ip_whitelist_updater getent hosts node-ip.your-domain.com
```
If that fails or times out, the `--dns` flag points at a resolver this container cannot reach; fix and
recreate.

**The household gets locked out of the server after an address change.**
This container was not running when the change happened, or it failed silently. Edit
`default-whitelist.yml` by hand from a console session (Proxmox/VPS provider console, not SSH, since
SSH is presumably also behind the stale allow list) to add the new address immediately, then get this
container running again.

**`default-whitelist.yml` keeps growing with old addresses instead of replacing them.**
This would mean the update logic is appending rather than rewriting — which is not how this service is
designed to behave. If you observe it, treat it as a defect in the image itself rather than something
to fix in this file; in the meantime, prune stale entries by hand.

**Reverse proxy does not seem to pick up the change.**
Confirm the file provider is actually watching the rules directory:
```bash
docker exec traefik cat /traefik.yml | grep -A3 'file:'
```
It should show `directory: /rules` and `watch: true`. If a manual edit to the file also fails to take
effect, the mount itself may be stale — restart the reverse proxy as a last resort.

**Container exits immediately with a permissions error on `configuration.yml`.**
The mounted `default-whitelist.yml` is not writable by whatever user the image runs as. Check the file
on the host is not accidentally root-owned with restrictive permissions, and that it is a file, not a
directory Docker invented because it was missing when the reverse proxy was first deployed.

**Logrotate rule seems to have no effect, or duplicates another rule.**
Confirm you have not created a second, correctly-spelled `whitelist_updater` rule alongside the
existing `whitlist_updater` one — `ls /etc/logrotate.d/ | grep -i whit` should show exactly one file.
