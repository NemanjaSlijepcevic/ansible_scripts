# Uptime Kuma

## What this is

Uptime Kuma is a self-hosted uptime monitor. It polls URLs, TCP ports, ping targets, DNS records and
certificate expiry on a schedule you set in its web interface, keeps the history in a local SQLite
database, notifies you when something goes down, and can publish a public status page.

It runs as a single container on the monitoring machine, listens on port `3001`, and is published by
the reverse proxy at `https://kuma.your-domain.com`. It has no configuration file at all — every
monitor, notification channel and status page is created through the UI and stored in its database
under `./data/kuma/data`.

**It is not currently part of the deployed stack.** The same job — probing every service internally
and from outside, alerting on failures and on certificates about to expire — is done by a blackbox
prober feeding the central metrics store, with the results on an HTTP-uptime dashboard and in alert
rules. This guide stands on its own for anyone who wants Uptime Kuma back, either as a second opinion
or as a simpler standalone monitor on a machine that has none.

Its own availability is the catch worth thinking about first: a monitor that lives on the machine it
monitors tells you nothing when that machine dies.

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

Sitting on this network is also what lets Uptime Kuma probe other containers by name
(`http://jellyfin:8096`) instead of going out through the proxy and back in.

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

### The service's DNS name resolves to this host

```bash
dig +short kuma.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### Outbound access for the checks you intend to run

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://api.telegram.org
ping -c1 1.1.1.1
```

Uptime Kuma initiates every check itself, so whatever it is going to probe — and whatever
notification service it is going to call — must be reachable from this machine. Ping checks
additionally need the container to be able to send ICMP, which the default capability set allows on
most hosts.

---

## Setup

### Overview

1. Create the data directory.
2. Start the container.
3. Create the admin account and turn off open registration.
4. Add the first monitors and a notification channel.

---

#### Step 1: Create the data directory

```bash
cd <deploy-dir>
sudo mkdir -p ./data/kuma/data
sudo chown -R <username>:<pgid> ./data/kuma
sudo chmod -R 0755 ./data/kuma
```

**Explanation**: Everything Uptime Kuma knows lives in `./data/kuma/data` as a SQLite database:
monitors, check history, notification channels, status pages and the login accounts. The container
runs as root and will fix the ownership of what it creates inside, so the only requirement is that
the directory exists — but keeping it owned by your own account means you can copy the database out
for a backup without `sudo`. Note the doubled path: the mount source is `./data/kuma/data` and it
lands on `/app/data` inside the container.

---

#### Step 2: Start the container

```bash
docker run -d \
  --name uptime-kuma \
  --restart always \
  --network proxy \
  --ip <docker-ip> \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -e UPTIME_KUMA_DISABLE_FRAME_SAMEORIGIN=0 \
  -v "$(pwd)/data/kuma/data:/app/data" \
  --health-cmd 'extra/healthcheck' \
  --health-interval 60s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  --label traefik.enable=true \
  --label 'traefik.http.routers.kuma.entrypoints=https' \
  --label 'traefik.http.routers.kuma.rule=Host(`kuma.your-domain.com`)' \
  --label 'traefik.http.routers.kuma.tls=true' \
  --label 'traefik.http.routers.kuma.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.kuma.loadbalancer.server.port=3001' \
  louislam/uptime-kuma:latest
```

**Explanation**: `--dns <local-dns-ip>` points the container at the LAN resolver rather than the
host's. That matters more here than anywhere else in the stack: Uptime Kuma's whole job is resolving
and connecting to names, and if it uses a public resolver it will check the *public* address of a
service that is actually reachable internally — you end up monitoring the path through your own
firewall's hairpin instead of the service.

The route carries the non-authenticating middleware chain. Uptime Kuma has its own login and its own
session; a forward-auth in front of it would break the WebSocket the UI keeps open for live status,
and it would make public status pages unreachable for the people they exist for. The chain still
runs the intrusion-detection bouncer, so the route is not unguarded.

`--restart always` rather than `unless-stopped`: a monitor that silently fails to come back after a
host reboot is worse than no monitor, because its silence reads as "everything is fine".

The image ships a health-check script at `extra/healthcheck` that probes the app's own port, which is
more honest than a plain TCP check because it verifies the Node process is serving rather than merely
listening.

Being on the shared bridge network is what lets you monitor a container as `http://<container>:<port>`
directly. Prefer that for internal services: a check against the public URL goes out through DNS,
the firewall and the proxy, so when it fails you have learned that *something* in a chain of five
things is broken, not which.

---

#### Step 3: Create the admin account immediately

Open `https://kuma.your-domain.com`. The first page is a setup form, not a login — anyone who reaches
the site before you do becomes the administrator.

```bash
# confirm the setup page is being served, then go create the account
curl -sf -o /dev/null -w '%{http_code}\n' https://kuma.your-domain.com
```

Afterwards, in *Settings → Security*, disable further sign-ups.

**Explanation**: There is no environment variable for the initial credentials — the account can only
be created through that form, and until it is created the instance is wide open. Do it in the same
minute you start the container. Disabling sign-ups afterwards is what stops a second account being
created later; there is no invitation flow to fall back on.

---

#### Step 4: Add monitors and a notification channel

Create the notification channel first, under *Settings → Notifications*, so you can attach it to each
monitor as you create it. For Telegram you need the bot token and the numeric chat id; check both
before pasting them in:

```bash
curl -sf "https://api.telegram.org/bot<telegram-bot-token>/getMe" | jq -r '.result.username'
curl -sf "https://api.telegram.org/bot<telegram-bot-token>/sendMessage" \
  -d chat_id='<telegram-chat-id>' -d text='uptime kuma test' | jq -r '.ok'
```

Then add monitors. A reasonable starting set:

| Type | Target | What it tells you |
|---|---|---|
| HTTP(s) | `http://<container>:<port>` | The service itself is up, independent of DNS and the proxy |
| HTTP(s) | `https://<service>.your-domain.com` | The whole external path works, certificate included |
| TCP port | `<ip-address>:<port>` | A service with no HTTP endpoint is listening |
| Ping | `<ip-address>` | A machine is alive when its services are not |

**Explanation**: Pair each externally-facing service with both an internal and an external check. When
only the external one fails, the problem is DNS, the certificate or the proxy; when both fail, it is
the service. One check cannot distinguish those, and that distinction is most of the value.

Turn on certificate-expiry notification per monitor for the HTTPS ones — it is the cheapest possible
guard against the renewal quietly having stopped working two months ago.

Keep the check interval sane. Sixty seconds is plenty for a household; twenty-second intervals across
thirty monitors is a measurable load on a small machine and buys you nothing.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data` and its group | The unprivileged login on this machine | Before you start, Step 1 |
| `<docker-ip>` | Fixed address on the `proxy` network | Any free address in the network's subnet, outside the automatic pool | Step 2 |
| `<local-dns-ip>` | LAN DNS resolver | The resolver that returns *internal* addresses for your own names | Step 2 |
| `<telegram-bot-token>` / `<telegram-chat-id>` | Notification channel credentials | From `@BotFather`; group ids are negative | Step 4 |
| `<container>` / `<port>` | An internal service to monitor | The container's name on the shared network | Step 4 |
| `<ip-address>` | A machine or device to monitor | Its LAN address | Step 4 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

---

## Verification

```bash
docker ps --filter 'name=^uptime-kuma$'
docker inspect --format '{{.State.Health.Status}}' uptime-kuma

# the app answers through the proxy
curl -sf -o /dev/null -w '%{http_code}\n' https://kuma.your-domain.com

# its unauthenticated entry-page endpoint (also tells you whether setup is done)
curl -sf https://kuma.your-domain.com/api/entry-page | jq .

# name resolution inside the container uses the LAN resolver
docker exec uptime-kuma cat /etc/resolv.conf
docker exec uptime-kuma getent hosts <service>.your-domain.com

# the database is being written
ls -l ./data/kuma/data/kuma.db
```

Then, in the UI, force one monitor to fail — stop the container it watches, or point a throwaway
monitor at a closed port — and confirm the notification actually arrives. An untested notification
channel is the default failure mode of every uptime monitor ever installed.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull louislam/uptime-kuma:latest
docker stop uptime-kuma && docker rm uptime-kuma
# re-run the docker run from Step 2
```

The database migrates itself on first start after an upgrade. Take a copy first — see below.

**Back up before any upgrade**, and periodically:

```bash
docker stop uptime-kuma
sudo tar czf ~/kuma-$(date +%F).tar.gz ./data/kuma
docker start uptime-kuma
```

Stop the container first: SQLite is being written continuously and a copy taken from underneath a
running writer can be torn. If you would rather not stop it, take a consistent snapshot with SQLite's
own backup mechanism instead:

```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db ".backup '/app/data/kuma-backup.db'"
sudo mv ./data/kuma/data/kuma-backup.db ~/kuma-$(date +%F).db
```

**Logs:**

```bash
docker logs -f uptime-kuma
```

Check results are not in the container log; they are in the database and the UI.

**Chores:** trim retention in *Settings → Monitor History* — the database grows with every check of
every monitor, and at a 60-second interval that is 1,440 rows per monitor per day. Review the monitor
list occasionally and delete checks for services that no longer exist, or you train yourself to
ignore a permanently red dashboard.

---

## Rollback / Uninstall

```bash
docker stop uptime-kuma && docker rm uptime-kuma
```

The database survives, so re-running Step 2 brings every monitor and all history back. To remove it
completely:

```bash
sudo tar czf ~/kuma-final-$(date +%F).tar.gz ./data/kuma
sudo rm -rf ./data/kuma
docker rmi louislam/uptime-kuma:latest
```

Deleting the directory destroys every monitor definition, all check history and any status page. Take
the archive first — recreating thirty monitors by hand is an afternoon.

---

## Troubleshooting

**The site shows a setup form and you did not create the account**
Someone else may have reached it first, or the database is empty because the mount is wrong. Check
`ls -l ./data/kuma/data/` — an empty directory means the container is writing somewhere else. Stop it,
fix the `-v` path, recreate.

**Live status does not update in the browser, page has to be reloaded**
The WebSocket is not getting through. Confirm the router has no forward-auth middleware on it and
that nothing in front of the proxy is stripping upgrade headers.

**Every external monitor is down but the services work in a browser**
The container is resolving your own domain names to the public address and cannot hairpin back in.
Point `--dns` at the LAN resolver, or monitor internal services by container name instead.

**Ping monitors always fail**
The container cannot send ICMP. Either use TCP-port monitors instead, or add `--cap-add=NET_RAW` when
starting the container.

**Certificate-expiry warnings for a certificate that was renewed**
Uptime Kuma reads the certificate presented on the connection. If it is still seeing the old one, the
proxy did not reload after renewal — check the proxy, not Kuma.

**Notifications never arrive**
Test the channel from its own edit screen; there is a *Test* button. For Telegram, verify the token
and chat id with the two `curl` calls in Step 4 — a bot that was never added to the target group
fails silently.

**Alerts stop arriving after the machine reboots**
The container did not come back. `--restart always` in Step 2 is what prevents this; check with
`docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' uptime-kuma`.

**Nothing at all is reported while the whole machine is down**
Expected, and unavoidable for a monitor that runs on the machine it watches. Either run this instance
somewhere else, or pair it with an external dead-man's-switch that alerts when it stops hearing from
this one.
