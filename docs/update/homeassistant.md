# Home Assistant

## What this is

Home Assistant is the home-automation hub: it talks to the Zigbee/Z-Wave radio plugged into this
machine's USB port, to IoT devices over MQTT, and to a Telegram bot for notifications and remote
commands. It runs as one container on the monitoring machine and is published by the reverse proxy at
`https://ha.your-domain.com`.

Two containers are set up here, because one is useless without the other:

- **`homeassistant`** — the hub itself, on port `8123`, with `/dev/ttyUSB0` and the host's D-Bus
  socket passed in.
- **`mosquitto`** — the MQTT broker devices publish to, on port `1883`, published on the host so
  devices on the LAN can reach it. Anonymous access is off; every client authenticates.

Home Assistant also exposes its entity states as metrics at `/api/prometheus`, which the metric agent
on this machine scrapes and forwards to the central metrics store, so battery levels, temperatures
and leak sensors end up on a dashboard and in alert rules.

Its route is **not** forward-authenticated by the proxy: Home Assistant has its own login and its own
long-lived tokens, and its companion apps and webhooks cannot present a single sign-on session.

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

Note the subnet — Home Assistant needs it as its trusted proxy range.

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
dig +short ha.your-domain.com
dig +short mqtt.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### The radio is plugged in and visible on the host

```bash
ls -l /dev/ttyUSB0
ls -l /dev/serial/by-id/
dmesg | grep -i ttyUSB | tail -5
```

The Zigbee/Z-Wave coordinator must appear as a character device before the container can be given
it. `/dev/serial/by-id/` prints a stable name for the same device — write it down, because
`ttyUSB0` and `ttyUSB1` swap around when more than one serial device is present or the machine
reboots with the dongle in a different port.

### Port 1883 is free

```bash
sudo ss -lntp '( sport = :1883 )'
```

The broker publishes this port on the host so LAN devices can reach it. Nothing else may hold it.

---

## Setup

### Overview

1. Create the directories for both services.
2. Write the broker configuration and create its password file.
3. Start the broker.
4. Write Home Assistant's configuration files.
5. Start Home Assistant.
6. Finish onboarding and connect the MQTT integration.
7. Issue the long-lived token the metric agent uses.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

sudo mkdir -p ./data/homeassistant/config
sudo chown -R <username>:<pgid> ./data/homeassistant
sudo chmod -R 0755 ./data/homeassistant

sudo mkdir -p ./data/mosquitto/data ./data/mosquitto/log ./data/mosquitto/config
sudo chown -R 1883:1883 ./data/mosquitto
sudo chmod -R 0755 ./data/mosquitto
```

**Explanation**: Home Assistant's container runs as root and writes its entire state — the SQLite
recorder database, the device registry, every integration's stored credentials — into `/config`, so
the host directory just has to exist and be writable. The broker is different: the Mosquitto image
drops to uid/gid `1883` immediately after start, so its data, log and config directories must be
owned by that numeric id up front or it exits with `Error: Unable to open log file` before it has
logged anything you can read.

---

#### Step 2: Write the broker configuration and create the password file

```bash
sudo tee ./data/mosquitto/config/mosquitto.conf >/dev/null <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
## to test:protocol websockets
listener 1883

## Authentication ##
allow_anonymous false
password_file /mosquitto/config/passwd
EOF

sudo chown 1883:1883 ./data/mosquitto/config/mosquitto.conf
sudo chmod 0644 ./data/mosquitto/config/mosquitto.conf
```

Create the password file with a throwaway container, since the tool that writes it ships in the
broker image and nowhere else:

```bash
docker run --rm \
  -v "$(pwd)/data/mosquitto/config:/work" \
  eclipse-mosquitto \
  mosquitto_passwd -c -b /work/passwd '<mqtt-user>' '<mqtt-password>'

sudo chown 1883:1883 ./data/mosquitto/config/passwd
sudo chmod 0640 ./data/mosquitto/config/passwd
```

**Explanation**: `allow_anonymous false` plus a `password_file` is the whole security model here — an
MQTT broker with anonymous access on a LAN is an open door onto every device in the house, since any
client can subscribe to `#` and watch everything. Every MQTT client you ever configure, Home
Assistant's integration included, must use these same credentials; there is one account, not one per
device.

`-c` **creates** the file, discarding anything already in it, so run that command exactly once. It is
also why the file must never be regenerated on a whim: `mosquitto_passwd` salts the hash freshly
every run, so the file's contents change even when the password does not, and a tool that rewrites it
unconditionally would churn it forever and restart the broker each time. To change the password,
delete `./data/mosquitto/config/passwd` and run the command again — then update every client.

`persistence true` makes the broker write retained messages and subscriptions to
`/mosquitto/data/`, so a restart does not lose the last known state of every sensor. The log goes to
a file inside the container rather than stdout, which is why `docker logs mosquitto` is nearly empty
and you read `./data/mosquitto/log/mosquitto.log` instead. The `websockets` line is commented out —
there is only a plain TCP listener on 1883.

---

#### Step 3: Start the broker

```bash
docker run -d \
  --name mosquitto \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -p 1883:1883 \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/mosquitto:/mosquitto" \
  -v "$(pwd)/data/mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf" \
  --health-cmd 'mosquitto_pub -h 127.0.0.1 -u <mqtt-user> -P <mqtt-password> -t healthcheck/ping -m ok' \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 10s \
  --label traefik.enable=true \
  --label 'traefik.http.routers.mosquitto.entrypoints=https' \
  --label 'traefik.http.routers.mosquitto.rule=Host(`mqtt.your-domain.com`)' \
  --label 'traefik.http.routers.mosquitto.tls=true' \
  --label 'traefik.http.services.mosquitto.loadbalancer.server.port=1883' \
  eclipse-mosquitto:latest
```

**Explanation**: The health check is a real functional test, not a port probe: MQTT has no HTTP
endpoint to curl, so the check publishes a message to a throwaway topic using the broker's own
credentials. Passing therefore proves three things at once — the process is alive, the listener
accepts connections on 1883, and the password file is readable and correct. The `mosquitto_pub`
client ships in the image, so nothing extra is installed.

Port 1883 is published on the host because the devices that publish to this broker are on the LAN,
not on the Docker network. Home Assistant, being a container on the same bridge, reaches it as
`mosquitto:1883` instead.

The proxy labels give the broker an HTTPS route, but be clear about what that does: an HTTP router
in front of a raw MQTT port is only useful once you uncomment a websockets listener in the
configuration and point the router at it. As written, MQTT clients connect to `<ip-address>:1883` on
the LAN or `mosquitto:1883` on the bridge — not to `https://mqtt.your-domain.com`.

Restart the broker with `docker stop mosquitto && docker start mosquitto`, never `docker restart`.
The single-file bind mount of `mosquitto.conf` is bound by inode; if you have replaced that file
(a new inode), a restart keeps serving the old contents, and on hosts using a userspace overlay
filesystem `docker restart` can leave the container's root filesystem mounts in a broken state
entirely.

---

#### Step 4: Write Home Assistant's configuration files

```bash
sudo tee ./data/homeassistant/config/configuration.yaml >/dev/null <<'EOF'

# Loads default set of integrations. Do not remove.
default_config:

# HIDDEN: no Bluetooth hardware is passed into this container, so HA's
# bluetooth auto-recovery loops and spams WARNINGs every ~20s. Suppress just
# those two loggers (rest of HA logging unchanged). Remove this block when
# Bluetooth is actually available so the warnings surface again.
logger:
  logs:
    bluetooth_auto_recovery: error
    homeassistant.components.bluetooth: error

# Load frontend themes from the themes folder
# frontend:
#   themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <docker-subnet>

telegram_bot:
  - platform: polling
    api_key: "<telegram-bot-token>"
    allowed_chat_ids:
      - <telegram-chat-id>

notify:
  - platform: telegram
    name: HomeAssistant
    chat_id: <telegram-chat-id>

prometheus:
  namespace: hass
EOF

sudo chown <username>:<pgid> ./data/homeassistant/config/configuration.yaml
sudo chmod 0644 ./data/homeassistant/config/configuration.yaml
```

The three included files must exist, or Home Assistant refuses to start with
`Error loading /config/configuration.yaml: Unable to read file /config/scripts.yaml`. Create them
empty — Home Assistant rewrites them itself once you save an automation or a script from the UI:

```bash
printf '[]\n' | sudo tee ./data/homeassistant/config/automations.yaml >/dev/null
printf '[]\n' | sudo tee ./data/homeassistant/config/scripts.yaml    >/dev/null
printf '[]\n' | sudo tee ./data/homeassistant/config/scenes.yaml     >/dev/null

sudo chown <username>:<pgid> ./data/homeassistant/config/*.yaml
sudo chmod 0644 ./data/homeassistant/config/*.yaml
```

Do not overwrite `automations.yaml` on a machine that already has automations — the UI writes into
that same file, so a fresh copy silently deletes everything anyone has built.

**Explanation**: `default_config:` pulls in the whole standard integration set (discovery, the
recorder database, the history and logbook, the mobile app endpoint). Removing it is how you end up
with a hub that cannot see anything.

`http.use_x_forwarded_for` with `trusted_proxies` is mandatory behind a reverse proxy. Without it
every request appears to come from the proxy's container address, so Home Assistant's brute-force
lockout bans the proxy after a few failed logins and locks everybody out at once; with it, the real
client address is read from the forwarded header — but only when the request came from the listed
range, which is why the range must be the bridge network's subnet and nothing wider. Listing a
subnet you do not control lets anyone spoof their address.

The Bluetooth logger block is a deliberate silencer. No Bluetooth adapter is passed into this
container, so Home Assistant's auto-recovery code retries a device that is not there and logs a
warning roughly every twenty seconds, which drowns the log. Raising just those two loggers to `error`
leaves every other component's logging untouched. Delete the block the day a Bluetooth adapter is
actually available, so the warnings become meaningful again.

The Telegram bot uses `polling`, which means Home Assistant reaches out to Telegram rather than
Telegram reaching in — no inbound webhook, no port to expose, and it works behind the proxy without
any route of its own. `allowed_chat_ids` is an allow-list: a chat that is not listed can message the
bot all it likes and Home Assistant ignores it. The `notify` block turns the same bot into a
notification target automations can call as `notify.homeassistant`.

`prometheus:` exposes every entity's state as metrics at `/api/prometheus`, prefixed `hass_`. That
endpoint requires authentication, which is why Step 7 issues a long-lived token for the metric agent
to send. Without the namespace, the metrics collide with names from other exporters.

---

#### Step 5: Start Home Assistant

```bash
docker run -d \
  --name homeassistant \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/homeassistant/config:/config" \
  -v /run/dbus:/run/dbus:ro \
  --device /dev/ttyUSB0:/dev/ttyUSB0 \
  --health-cmd 'curl -fsS -o /dev/null http://127.0.0.1:8123/manifest.json' \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 60s \
  --label traefik.enable=true \
  --label 'traefik.http.routers.homeassistant.entrypoints=https' \
  --label 'traefik.http.routers.homeassistant.rule=Host(`ha.your-domain.com`)' \
  --label 'traefik.http.routers.homeassistant.tls=true' \
  --label 'traefik.http.routers.homeassistant.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.homeassistant.loadbalancer.server.port=8123' \
  ghcr.io/home-assistant/home-assistant:stable
```

**Explanation**: The container is **not** run privileged. Home Assistant's own documentation reaches
for `--privileged` because that is the easy way to hand it every device on the machine, but
everything it actually needs here is named explicitly: `--device /dev/ttyUSB0` for the radio and the
read-only D-Bus socket for host-level integrations. Privileged mode would give a process that
executes user-supplied automations full access to the host's devices, which is not a trade worth
making for convenience.

The health check probes `/manifest.json`, not `/`. The root path redirects — to onboarding on a fresh
install, to the login page afterwards — so a check on `/` would either follow a redirect or record a
30x as a failure depending on the flags. `/manifest.json` is a static, unauthenticated 200 in every
state, which makes it the one honest liveness signal. The image ships `curl`, so nothing extra is
needed. The 60-second start period covers the first-boot database migration, which is slow enough to
mark a perfectly healthy container unhealthy without it.

The route carries the non-authenticating middleware chain. Home Assistant has its own login, its own
long-lived tokens and its own mobile apps; putting a forward-auth in front of it breaks the companion
app, every webhook and the media stream, none of which can present a browser session. The chain still
runs the intrusion-detection bouncer.

The recorder database inside `/config` is SQLite and is written constantly. Back up
`./data/homeassistant/config`, and stop the container before copying it if you want a clean file.

---

#### Step 6: Finish onboarding and connect MQTT

Open `https://ha.your-domain.com` and create the first user — that account is the owner and cannot be
recreated later without wiping `/config`.

Then add the MQTT integration under *Settings → Devices & Services → Add Integration → MQTT*, with:

| Field | Value |
|---|---|
| Broker | `mosquitto` |
| Port | `1883` |
| Username | `<mqtt-user>` |
| Password | `<mqtt-password>` |

**Explanation**: The broker hostname is the container name, not an address and not the public
domain — both containers are on the same bridge network, where Docker's embedded resolver turns
`mosquitto` into the right address even if that address changes. The credentials are the ones from
Step 2; anonymous access is disabled, so a blank username fails with `Not authorised` and no further
explanation.

Verify from the other side before blaming Home Assistant:

```bash
docker exec mosquitto mosquitto_sub -h 127.0.0.1 -u '<mqtt-user>' -P '<mqtt-password>' -t 'homeassistant/#' -C 1 -W 10
```

---

#### Step 7: Issue the long-lived token for metrics

In the Home Assistant UI, click your user name (bottom left) → *Security* → *Long-lived access
tokens* → *Create token*. Copy it once; it is never shown again.

Test the endpoint with it:

```bash
curl -sf -H 'Authorization: Bearer <ha-token>' \
  https://ha.your-domain.com/api/prometheus | head -20
```

**Explanation**: `/api/prometheus` is authenticated like any other Home Assistant API path, so the
metric agent on this machine has to send that token as a bearer header on every scrape. The token
never expires and is not tied to a session, which is exactly what an unattended scraper needs and
exactly why it must be treated as a password: it grants full API access, including calling services
that switch things on and off. Store it where the agent's configuration lives and nowhere else.

Once the agent is scraping, `hass_*` metrics appear centrally, and the alert rules that watch battery
levels, leak and smoke sensors, and climate sensors that stop reporting start working.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data` and its group | The unprivileged login on this machine | Steps 1, 4 |
| `<docker-ip>` | Fixed address on the `proxy` network | One per container, free and outside the automatic pool | Steps 3, 5 |
| `<docker-subnet>` | The bridge network's CIDR | As created; used as Home Assistant's trusted proxy range | Step 4 |
| `<ip-address>` | This machine's LAN address | What LAN devices point their MQTT client at, on port 1883 | Step 3 |
| `<mqtt-user>` / `<mqtt-password>` | The one broker account | Anything; every MQTT client uses these | Steps 2, 3, 6 |
| `<telegram-bot-token>` | Telegram bot API token | From `@BotFather` | Step 4 |
| `<telegram-chat-id>` | Chat the bot may talk to | Numeric id; anything not listed is ignored | Step 4 |
| `<ha-token>` | Long-lived access token | Created in the UI in Step 7; full API access, treat as a password | Step 7 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

The uid/gid `1883` and the port `1883` are fixed by the broker image and its configuration; do not
substitute them.

---

## Verification

```bash
docker ps --filter 'name=^homeassistant$' --filter 'name=^mosquitto$'
docker inspect --format '{{.Name}} {{.State.Health.Status}}' homeassistant mosquitto

# the hub answers, unauthenticated
curl -sf -o /dev/null -w '%{http_code}\n' https://ha.your-domain.com/manifest.json

# the API answers with the token
curl -sf -H 'Authorization: Bearer <ha-token>' https://ha.your-domain.com/api/ | jq .

# entity metrics are being produced
curl -sf -H 'Authorization: Bearer <ha-token>' https://ha.your-domain.com/api/prometheus \
  | grep -c '^hass_'

# the radio really is inside the container
docker exec homeassistant ls -l /dev/ttyUSB0

# the broker accepts an authenticated publish and delivers it
docker exec mosquitto mosquitto_pub -h 127.0.0.1 -u '<mqtt-user>' -P '<mqtt-password>' \
  -t 'test/verify' -m 'hello' && echo 'publish ok'

# an anonymous publish must be refused
docker exec mosquitto mosquitto_pub -h 127.0.0.1 -t 'test/verify' -m 'nope' \
  && echo 'ANONYMOUS ACCESS IS OPEN — fix mosquitto.conf' || echo 'anonymous refused: ok'

# broker log (it writes to a file, not stdout)
sudo tail -20 ./data/mosquitto/log/mosquitto.log
```

---

## Updating & day-to-day

**Update Home Assistant:**

```bash
docker pull ghcr.io/home-assistant/home-assistant:stable
docker stop homeassistant && docker rm homeassistant
# re-run the docker run from Step 5
```

Home Assistant migrates its database on first start after an upgrade, which can take minutes on a
large recorder database. Read the release notes for breaking changes before a monthly version jump —
integrations do get removed.

**Update the broker:**

```bash
docker pull eclipse-mosquitto:latest
docker stop mosquitto && docker rm mosquitto
# re-run the docker run from Step 3
```

**After editing `configuration.yaml`:** check it first, then restart. Home Assistant will not start
on a syntax error and you lose the hub until you fix it.

```bash
docker exec homeassistant python -m homeassistant --script check_config --config /config
docker restart homeassistant
```

**After editing `mosquitto.conf`:**

```bash
docker stop mosquitto && docker start mosquitto
```

Stop-then-start, not `docker restart` — see Step 3.

**Logs:**

```bash
docker logs -f homeassistant
sudo tail -f ./data/mosquitto/log/mosquitto.log
```

Home Assistant also keeps `./data/homeassistant/config/home-assistant.log`, which is the same content
with more context and survives a container recreate.

**Chores:**

- `./data/mosquitto/log/mosquitto.log` is never rotated by the broker. Truncate it, or add a
  logrotate entry, before it becomes the largest file on the machine.
- The recorder database `./data/homeassistant/config/home-assistant_v2.db` grows with every state
  change. If it gets large, add a `recorder:` block with `purge_keep_days` and an entity exclusion
  list.
- Back up `./data/homeassistant/config` — it holds every automation, every device pairing and every
  integration's stored credentials. The Zigbee network keys live there too, so losing it means
  re-pairing every device by hand.

---

## Rollback / Uninstall

```bash
docker stop homeassistant mosquitto
docker rm homeassistant mosquitto
```

Both keep their state on disk, so re-running Steps 3 and 5 brings the same installation back.

To remove completely:

```bash
sudo tar czf ~/homeassistant-$(date +%F).tar.gz ./data/homeassistant ./data/mosquitto
sudo rm -rf ./data/homeassistant ./data/mosquitto
docker rmi ghcr.io/home-assistant/home-assistant:stable eclipse-mosquitto:latest
```

Take that archive. Deleting `./data/homeassistant/config` destroys all automations, all entity
customisation, all history and the Zigbee network keys — every battery-powered device would have to
be re-paired physically.

---

## Troubleshooting

**Container will not start, log ends at `Error loading /config/configuration.yaml`**
A YAML error, or one of `automations.yaml` / `scripts.yaml` / `scenes.yaml` is missing. Create the
missing file with `[]` as in Step 4, then:
`docker run --rm -v "$(pwd)/data/homeassistant/config:/config" ghcr.io/home-assistant/home-assistant:stable python -m homeassistant --script check_config --config /config`.

**`400: Bad Request` when opening the site**
`trusted_proxies` does not include the address the request arrives from. Find it in
`./data/homeassistant/config/home-assistant.log` — the error names the address — and make sure the
bridge subnet in Step 4 covers it.

**Everyone gets locked out after a few bad logins**
`use_x_forwarded_for` is missing or `trusted_proxies` is wrong, so every request looks like it comes
from the proxy and the ban applies to all of them at once. Fix Step 4, then delete
`./data/homeassistant/config/ip_bans.yaml` and restart.

**The USB radio is not found inside the container**
`ls -l /dev/ttyUSB0` on the host first. If the device is now `ttyUSB1`, or swaps after reboots, pass
the stable path instead: `--device /dev/serial/by-id/<stable-name>:/dev/ttyUSB0`. The container must
be recreated for a device change; a restart is not enough.

**Radio present but the integration cannot open it**
Something else on the host has the port open — a previously running container, or a modem manager.
`sudo fuser -v /dev/ttyUSB0` names it.

**MQTT integration fails with `Not authorised`**
Wrong credentials, or the password file is unreadable by the broker. Check ownership
(`ls -l ./data/mosquitto/config/passwd` must be `1883:1883`), then test from a shell with
`mosquitto_pub` as in *Verification*.

**Broker starts and exits immediately with nothing in `docker logs`**
It logs to a file, and it could not open it. `./data/mosquitto/log` must be owned by `1883:1883`.
Temporarily comment out the `log_dest file` line to get the error on stdout.

**Home Assistant cannot reach the broker**
Both containers must be on the `proxy` network — `docker network inspect proxy | jq -r
'.[0].Containers[].Name'`. Use `mosquitto` as the hostname, not an address and not the public domain.

**Devices on the LAN cannot reach the broker**
Port 1883 must be published (`docker port mosquitto`) and allowed through the host firewall. It is
plain, unencrypted MQTT — keep it to the LAN.

**No `hass_*` metrics appear centrally**
The scraper's bearer token is wrong or missing. Test it by hand as in Step 7; a bad token gives
`401`, an absent `prometheus:` block gives `404`.

**Log fills with Bluetooth warnings**
The suppression block in Step 4 is missing from `configuration.yaml`. It is expected on a machine
with no Bluetooth adapter passed into the container.
