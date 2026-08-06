# Public IP Tracker

## What this is

A small container that periodically checks this network's current public (WAN) address and serves
it over HTTP as `/current_ip`, protected by a bearer token instead of a login. It runs on the
monitoring machine — the one physically on the home network, so it is the machine that can actually
see the household's real public address.

It exists for one reason: the public-facing server, sitting on the internet with a fixed address, has
no way to know when the home network's ISP-assigned address changes, and needs to know exactly that
in order to keep letting the household reach it directly. This container is the source of truth that
other automation reads. Its own log line announcing a change (`IP has changed`) is also what a
separate log-watching container turns into a chat notification, so a change here is visible to a
human within seconds even before anything downstream reacts to it.

Its endpoint's router is deliberately published **without single sign-on** — `/current_ip` is queried
by another machine's script over the internet, not by a person in a browser, and that script cannot
complete an interactive login. A bearer token takes the place of a login instead: the same token that
protects the endpoint from anonymous callers is presented by every legitimate caller, including this
container's own health check.

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

### The reverse proxy (Traefik) is running

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

`healthcheck --ping` exits 0 only when Traefik's own ping endpoint answers. This container's router
is going to publish itself on this same proxy.

### The site's DNS name resolves to this host

```bash
dig +short node-ip.your-domain.com
```

### This endpoint's domain has a `bypass` rule in Authelia, even though its router skips Authelia

The router below carries `chain-no-auth@file`, which never calls Authelia's forward-auth at all — but
the domain still needs an explicit `bypass` entry in Authelia's own access-control rules, or a router
that overrides the authenticating chain with no matching rule produces inconsistent behaviour,
including redirect loops, on anything that later touches the same domain.

```bash
docker exec authelia grep -n -A20 '^access_control' /config/configuration.yml
```

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
      - "node-ip.your-domain.com"
      policy: bypass
```

### Pick a bearer token

```bash
openssl rand -hex 32
```

This is the value both this container and the allow-list updater on the other host will need to
agree on — keep it, you will use it again in the public IP allow-list guide.

---

## Setup

### Overview

1. Create the data directory and the log file the container appends to.
2. Start the container.
3. Install log rotation for the log file.

---

#### Step 1: Create the data directory and log file

```bash
mkdir -p ./data/public_ip_tracker
sudo chown <username>:<pgid> ./data/public_ip_tracker
sudo chmod 0744 ./data/public_ip_tracker

sudo touch ./data/public_ip_tracker/app.log
sudo chown <app-uid>:<app-gid> ./data/public_ip_tracker/app.log
sudo chmod 0644 ./data/public_ip_tracker/app.log
```

**Explanation**: the log file is created and owned **before** the container ever starts, and it is
created as a **file**, deliberately — a bind mount whose source does not yet exist becomes a
directory the moment Docker creates it, and the application then fails to open its own log with an
error that reads like a permissions problem. The ownership is not the deploy account: the image runs
its process as a fixed, non-root `appuser` baked into the image, and `<app-uid>`/`<app-gid>` is that
account's numeric id — the file has to be writable by that specific uid, not by whichever account
happens to run `docker`.

---

#### Step 2: Start the container

```bash
docker run -d \
  --name public_ip_tracker \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e API_IP_TOKEN='<secret>' \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/public_ip_tracker/app.log:/app/app.log:rw" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.public_ip_tracker.entrypoints=https' \
  --label 'traefik.http.routers.public_ip_tracker.rule=Host(`node-ip.your-domain.com`)' \
  --label 'traefik.http.routers.public_ip_tracker.tls=true' \
  --label 'traefik.http.routers.public_ip_tracker.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.public_ip_tracker.loadbalancer.server.port=5000' \
  --health-cmd 'wget -qO /dev/null --header "Authorization: Bearer <secret>" http://127.0.0.1:5000/current_ip' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  <dockerhub-user>/public_ip_tracker:latest
```

**Explanation**: `traefik.http.routers.public_ip_tracker.middlewares=chain-no-auth@file` is the label
that overrides the `https` entrypoint's default authenticating chain for this one router — everything
else on this host still gets single sign-on, this endpoint does not. `chain-no-auth` still runs the
IP allow list, the CrowdSec bouncer, security headers and a rate limit; it only drops the Authelia
step, because Authelia's forward-auth flow expects a browser to follow redirects and this endpoint's
only caller is a script.

`API_IP_TOKEN` does double duty: it is what this container presents as `Bearer` auth on its own
health check against its own `/current_ip`, and it is the same credential any other caller —
including the allow-list updater on the other host — must present. Since the router skips single
sign-on entirely, this token is the only thing standing between the internet and this endpoint; treat
it like any other credential and do not reuse it elsewhere.

The log file is mounted read-write because the application appends to it directly; there is no
configuration file for this service, everything it needs arrives as an environment variable.

---

#### Step 3: Install log rotation

```bash
sudo tee /etc/logrotate.d/public_ip_tracker >/dev/null <<EOF
$(pwd)/data/public_ip_tracker/app.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

sudo chmod 0644 /etc/logrotate.d/public_ip_tracker
```

**Explanation**: `copytruncate` is not the logrotate default, and it is chosen on purpose here. The
default rotation renames the live file aside and creates a new, empty one in its place — which
changes the file's inode. This log is bind-mounted into the container by path, and the container's
own process holds that file open and keeps writing to it; a rename-based rotation would leave the
process writing into a file nobody reads any more while the new file sits empty. `copytruncate`
instead copies the current content out to the rotated name and truncates the original **in place**,
so the same inode — and the container's open handle on it — stays valid across every rotation.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | working directory on the host that holds `./data` | the deploy account's home, or a dedicated directory | Before you start |
| `<username>` / `<pgid>` | account that owns `./data`, and its group | the unprivileged deploy account, group `docker` | Before you start, Step 1 |
| `<app-uid>` / `<app-gid>` | numeric id the image's own process runs as | fixed by the image; check with `docker inspect --format '{{ .Config.User }}' <dockerhub-user>/public_ip_tracker:latest` if unsure | Step 1 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Step 2 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `<secret>` | bearer token for `/current_ip` | `openssl rand -hex 32`; must match the value used by the allow-list updater | Before you start, Step 2 |
| `node-ip.your-domain.com` | this endpoint's public domain | DNS record pointing at this host or at Cloudflare | Before you start, Step 2 |
| `<dockerhub-user>` | registry account the image is published under | the account that built `public_ip_tracker` | Step 2 |

---

## Verification

```bash
# container up and health check green
docker ps --filter 'name=^public_ip_tracker$'
docker inspect --format '{{ .State.Health.Status }}' public_ip_tracker

# the endpoint answers with a token, and refuses without one
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer <secret>' \
  https://node-ip.your-domain.com/current_ip
curl -s -o /dev/null -w '%{http_code}\n' https://node-ip.your-domain.com/current_ip

# it is reachable without going through a login page
curl -sI https://node-ip.your-domain.com/current_ip | grep -i '^location' \
  || echo "no redirect: expected, this endpoint bypasses single sign-on"

# the container is actually appending to the host's log file
docker exec public_ip_tracker tail -3 /app/app.log
tail -3 ./data/public_ip_tracker/app.log
```

The unauthenticated request should return something other than 200 (401/403 depending on the image),
and the authenticated one should return 200 with the current address as its body.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull <dockerhub-user>/public_ip_tracker:latest
docker stop public_ip_tracker && docker rm public_ip_tracker
# re-run the docker run command from Step 2
```

The log file lives on the host, so recreating the container loses no history.

**Logs:**

```bash
docker logs --tail 100 -f public_ip_tracker
tail -f ./data/public_ip_tracker/app.log
```

Watch for the `IP has changed` line — that is the event everything downstream depends on. A
log-watching container elsewhere is configured to alert on exactly that pattern; a working alert path
is the fastest way to notice this container has stopped working at all, since a silent tracker looks
identical to a tracker that is simply reporting no change.

**Routine chores:** once in a while, confirm the token still works end to end with the `curl` checks
above — a token rotated on one side and not the other fails silently from the allow-list updater's
point of view, since it will simply stop receiving a usable answer.

---

## Rollback / Uninstall

```bash
docker stop public_ip_tracker && docker rm public_ip_tracker
sudo rm -rf ./data/public_ip_tracker
sudo rm -f /etc/logrotate.d/public_ip_tracker
docker rmi <dockerhub-user>/public_ip_tracker:latest
```

Then remove the domain from Authelia's access-control rules and delete the DNS record. Removing this
container also breaks the allow-list updater on the other host, which depends on it — expect that
host's allow list to go stale from this point on.

---

## Troubleshooting

**Container is unhealthy immediately after creation.**
The health check's own bearer token does not match `API_IP_TOKEN`, or the two were typed differently
across the two `-e`/`--health-cmd` flags. Recreate the container with both values identical.

**`/current_ip` returns 401/403 even with the right token in `curl`.**
Confirm the header name and scheme exactly: `Authorization: Bearer <token>`, no extra whitespace, no
quotes carried into the value itself.

**Log rotation runs but the container stops logging afterwards.**
`copytruncate` was dropped from the logrotate rule (for instance by hand-editing it later) and a
rename-based rotation broke the container's open file handle. Recreate the container to reopen the
log file at its current path, and put `copytruncate` back.

**Container tails/writes to a directory instead of a file.**
`./data/public_ip_tracker/app.log` did not exist when the container was created, so Docker created a
directory there. `docker rm -f public_ip_tracker`, remove the directory, redo Step 1, recreate.

**The allow-list on the other host never updates, but this container looks healthy.**
Confirm this endpoint is reachable from the *other* host specifically, not just locally — test with
the same `curl -H 'Authorization: Bearer <secret>' https://node-ip.your-domain.com/current_ip` from
the server host. A firewall or DNS issue on that side is invisible from here.

**No `IP has changed` line ever appears, even though you know the address changed.**
This container only detects a change if it is still running and still able to reach whatever it
queries to learn the current address; check `docker logs public_ip_tracker` for repeated errors
rather than assuming silence means "no change".
