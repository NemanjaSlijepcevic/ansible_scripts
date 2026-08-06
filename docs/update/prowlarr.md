# Prowlarr

## What this is

Prowlarr is the indexer manager for the media stack. You add a torrent or Usenet indexer once, here,
and Prowlarr pushes it out to every application that needs it — you never add an indexer inside
Sonarr, Radarr or Lidarr directly. It also owns the one download client connection those applications
share for interactive searches performed from inside Prowlarr itself, and raises a notification when
an indexer starts failing.

It runs as a single container on the storage host, on the shared `proxy` bridge network with a fixed
address, and is published by the reverse proxy at `https://prowlarr.your-domain.com`. Its database is
**not** local: it stores everything in the central PostgreSQL server, in two databases (`prowlarr` and
`prowlarr-log`), over a mutually-authenticated TLS connection.

What it talks to, all by container name on the shared network:

- **`sonarr`** on port 8989, **`radarr`** on port 7878, **`lidarr`** on port 8686 — the applications it
  keeps synced with its indexer list. Prowlarr calls each one's API to register itself as an
  indexer source; from that point on the sync runs on Prowlarr's own schedule, in Prowlarr's
  direction — you manage indexers once, here, never in the individual applications.
- **`transmission`** on port 9091 — registered as a download client so that a search run from inside
  Prowlarr itself (rather than from one of the `*arr` applications) can still be sent somewhere.
- **The central PostgreSQL server**, over TLS with a client certificate.
- **Telegram**, over the internet, for health notifications only — a failing indexer is the one thing
  in this stack you want to know about immediately, since every application depends on it silently.

Everything on the inside of the bridge is addressed by **container name, never by IP and port on the
host**. Docker's embedded DNS resolves `sonarr`, `radarr`, `lidarr` and `transmission` to whatever
address those containers currently hold, so a container that gets recreated with a different address
does not break the link — and none of that traffic ever leaves the bridge, so it needs no published
port, no TLS, and no pass through the reverse proxy.

## Before you start

**Docker is installed and your account can use it**

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

**The `./data` working directory exists**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and every
container path in this guide is bind-mounted from here. Run all commands from `<deploy-dir>` so the
relative paths resolve.

**The shared `proxy` bridge network exists**

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows where
to send a request.

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

**The reverse proxy (Traefik) is running**

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

**Authelia (single sign-on) is running**

The web interface is behind `chain-auth@file`, so it is forward-authenticated. If the portal is down,
the interface returns 500 rather than a login page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy portal answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

The portal's access rules must carve two exceptions out of that protection for this hostname:
`^/ping.*` and `^/api/.*` must be `policy: bypass`, everything else `two_factor`. Without those, the
health endpoint and every API call in this guide — and every call the media managers make into
Prowlarr — get a login redirect instead of JSON. The API path is not left unguarded by that: it is
protected by the API key instead.

Confirm the exception is live once the container is running:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://prowlarr.your-domain.com/ping     # expect 200
curl -s -o /dev/null -w '%{http_code}\n' https://prowlarr.your-domain.com/         # expect 302 to the portal
```

**The service's DNS name resolves to this host**

```bash
dig +short prowlarr.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong machine
produces a 404 from the wrong proxy rather than an error you can read.

**PostgreSQL client certificates are present**

Services that store state in the central PostgreSQL server authenticate with a client certificate,
not just a password — the server requires `clientcert=verify-full`, and the certificate's Common
Name must equal the database role the service connects as.

```bash
ls -l ./data/certs/
sudo openssl x509 -in ./data/certs/prowlarr.crt -noout -subject -dates
```

You need three files on this host: `./data/certs/prowlarr.crt`, `./data/certs/prowlarr.key`, and the
issuing `./data/certs/ca.crt`. They are signed on the PostgreSQL host and copied here; the service
never generates its own. Without them the container starts and then fails every query with
`connection requires a valid client certificate (SQLSTATE 28000)`.

The `subject` printed above is what matters: the CN is the **database role**, which is not
necessarily the file name. The file is called `prowlarr.crt` for convenience; the role inside it is
the shared media database account — the same account Sonarr, Radarr and Bazarr connect as.

**The databases and role exist on the PostgreSQL server**

Run on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep -E 'prowlarr'
docker exec -it postgres-db psql -U postgres -c '\du' | grep <db-user>
```

Both `prowlarr` and `prowlarr-log` must exist and be owned by the login role, otherwise the first
start fails part-way through its schema migration with `permission denied for schema public`. Create
them if they are missing:

```bash
docker exec -it postgres-db psql -U postgres <<'EOF'
CREATE DATABASE "prowlarr"     OWNER "<db-user>";
CREATE DATABASE "prowlarr-log" OWNER "<db-user>";
EOF
```

**Sonarr, Radarr, Lidarr and the download client are running, and you have their API keys**

```bash
docker ps --filter 'name=^sonarr$' --filter 'name=^radarr$' --filter 'name=^lidarr$' --filter 'name=^transmission$'
curl -sf -o /dev/null -w 'sonarr: %{http_code}\n' https://sonarr.your-domain.com/ping
curl -sf -o /dev/null -w 'radarr: %{http_code}\n' https://radarr.your-domain.com/ping
curl -sf -o /dev/null -w 'lidarr: %{http_code}\n' https://lidarr.your-domain.com/ping
docker exec transmission curl -sf -o /dev/null -w 'transmission: %{http_code}\n' http://localhost:9091/transmission/web/
```

Prowlarr can start and answer without any of these, but the setup steps below that register each one
will fail their verification if the target application is not reachable yet. Read each application's
API key from its own configuration before you continue.

## Setup

### Overview

1. Create the configuration directory.
2. Start the container.
3. Wait for it to answer `/ping`.
4. Add the download client.
5. Add the Telegram notification.
6. Apply the host settings.
7. Add the public indexers.
8. Register Radarr, Sonarr and Lidarr so they receive the indexer sync.

---

#### Step 1: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/prowlarr
sudo chown <username>:<pgid> ./data/prowlarr
sudo chmod 0755 ./data/prowlarr
```

**Explanation**: only the parent is created here. The container creates `./data/prowlarr/config`
itself on first start, as its own user, and populates it with `config.xml` and the log files. The
parent belongs to your deploy account so you can inspect and back it up without `sudo`.

---

#### Step 2: Start the container

```bash
cd <deploy-dir>

docker run -d \
  --name prowlarr \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TZ=<timezone> \
  -e PROWLARR__AUTH__APIKEY='<secret>' \
  -e PROWLARR__AUTH__METHOD=External \
  -e PROWLARR__AUTH__REQUIRED=DisabledForLocalAddresses \
  -e PROWLARR__SERVER__PORT=9696 \
  -e PROWLARR__POSTGRES__HOST=<postgres-host> \
  -e PROWLARR__POSTGRES__PORT=5432 \
  -e PROWLARR__POSTGRES__USER='<db-user>' \
  -e PROWLARR__POSTGRES__PASSWORD='<secret>' \
  -e PROWLARR__POSTGRES__MAINDB=prowlarr \
  -e PROWLARR__POSTGRES__LOGDB=prowlarr-log \
  -e PGSSLMODE=verify-ca \
  -e PGSSLCERT=/postgres-certs/prowlarr.crt \
  -e PGSSLKEY=/postgres-certs/prowlarr.key \
  -e PGSSLROOTCERT=/postgres-certs/ca.crt \
  -v "$(pwd)/data/prowlarr/config:/config" \
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.prowlarr.entrypoints=https' \
  --label 'traefik.http.routers.prowlarr.rule=Host(`prowlarr.your-domain.com`)' \
  --label 'traefik.http.routers.prowlarr.tls=true' \
  --label 'traefik.http.routers.prowlarr.middlewares=chain-auth@file' \
  --label 'traefik.http.services.prowlarr.loadbalancer.server.port=9696' \
  --health-cmd 'curl --fail http://localhost:9696/ping || exit 1' \
  --health-interval 90s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  lscr.io/linuxserver/prowlarr:latest
```

**Explanation**, setting by setting:

`PUID`/`PGID` are honoured by this image's init, which drops to those numbers before starting the
application. Prowlarr never touches the movie, TV or download drives itself, so these only need to be
a valid, consistent pair for the config directory — they do not have to match the media managers the
way theirs must match each other.

`PROWLARR__AUTH__APIKEY` sets the API key from the outside instead of letting the application
generate a random one into `config.xml` on first start. That is what makes the rest of this guide
possible: you know the key before the service exists, so every command below can be run without
first reading a generated value back out of a file inside the container. All of these
double-underscore variables map onto the application's own configuration keys — `SECTION__KEY` — so
anything you can set in `config.xml` you can set here, and the environment wins.

`PROWLARR__AUTH__METHOD=External` means the application does not render its own login form: it trusts
that whatever is in front of it has already authenticated the user. That "whatever" is the single
sign-on portal, applied by the `chain-auth@file` middleware on the route. Combined with
`PROWLARR__AUTH__REQUIRED=DisabledForLocalAddresses`, requests arriving from private addresses — the
other containers on the bridge — skip the check entirely, which is how Sonarr, Radarr and Lidarr pull
their indexer list from it without a login. Anything from outside comes through the proxy and is
authenticated there. Never publish this container's port to the host: that combination would put an
unauthenticated interface, with control over every indexer credential behind it, on the LAN.

`PROWLARR__POSTGRES__MAINDB` and `__LOGDB` are two separate databases on purpose. The log database
takes the overwhelming majority of the writes — every indexer test and every search writes rows — and
keeping it out of the main database means its bloat, its vacuum load and its size never touch the
indexer configuration, and you can truncate it wholesale without risking a single indexer definition.

The four `PGSSL*` variables are read by the PostgreSQL driver itself, not by the application.
`verify-ca` makes the client verify the server's certificate against `ca.crt`, so it cannot be
tricked into talking to an impostor database. The client certificate is not optional decoration: the
server's rules use certificate authentication, so the Common Name inside `prowlarr.crt` is what
actually decides which database role you connect as — the password is supplied but the certificate is
what authenticates. The certificate directory is mounted **read-only**; nothing in this container has
any business writing to it, and the key is shared with the other services on the host.

There are no library or download volumes here at all — this is the one media-stack application with
nothing to mount besides its own config and the database certificates, because it never handles a
file, only indexer definitions and API calls.

The route uses `chain-auth@file`: TLS at the proxy, the intrusion-prevention bouncer, security
headers, then forward-authentication against the single sign-on portal.

---

#### Step 3: Wait for it to answer `/ping`

```bash
for i in $(seq 1 10); do
  curl -sf https://prowlarr.your-domain.com/ping && { echo; echo "prowlarr: ready"; break; }
  echo "waiting for prowlarr..."; sleep 10
done

docker inspect --format '{{.State.Health.Status}}' prowlarr
```

**Explanation**: `/ping` answers `{"status":"OK"}` only after the schema migration against
PostgreSQL has finished and the HTTP pipeline is up. A first start against an empty database creates
dozens of tables and can take a minute; every configuration call below fails with a connection error
if you run it too early. If the loop never succeeds, `docker logs prowlarr` will name the database
problem directly.

---

#### Step 4: Add the download client

```bash
KEY='<secret>'   # the API key from Step 2
BASE='https://prowlarr.your-domain.com/api/v1'

# do not add a second copy
curl -s "$BASE/downloadclient" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/downloadclient" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Transmission",
    "implementation": "Transmission",
    "configContract": "TransmissionSettings",
    "protocol": "torrent",
    "enable": true,
    "priority": 1,
    "categories": [],
    "fields": [
      {"name": "host", "value": "transmission"},
      {"name": "port", "value": 9091},
      {"name": "useSsl", "value": false},
      {"name": "urlBase", "value": "/transmission/"},
      {"name": "username", "value": ""},
      {"name": "password", "value": ""},
      {"name": "category", "value": ""},
      {"name": "directory", "value": ""},
      {"name": "priority", "value": 0},
      {"name": "addPaused", "value": false}
    ]
  }'
```

**Explanation**: `host` is the literal container name `transmission` and `port` is 9091 — the port
*inside* the bridge network, addressed the same way every other service on it addresses Transmission.
This connection is not for the media managers' own downloads; each of them keeps its own download
client entry (see their guides). It exists so that an interactive search run from inside Prowlarr's
own interface — testing whether an indexer actually returns usable results — has somewhere to send a
grab. `categories: []` is deliberate: Prowlarr does not sort downloads into a library the way the
media managers do, so there is no category label to route a finished torrent by.

Check the existing list before posting. The API happily accepts two identically named download
clients.

---

#### Step 5: Add the Telegram notification

```bash
KEY='<secret>'
BASE='https://prowlarr.your-domain.com/api/v1'

curl -s "$BASE/notification" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/notification" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Telegram",
    "implementation": "Telegram",
    "configContract": "TelegramSettings",
    "onHealthIssue": true,
    "onApplicationUpdate": false,
    "fields": [
      {"name": "botToken", "value": "<telegram-bot-token>"},
      {"name": "chatId", "value": "<telegram-chat-id>"}
    ]
  }'
```

**Explanation**: `onHealthIssue` is the only event flag Prowlarr sends here, and it is turned on
deliberately — an indexer silently returning errors or captchas is invisible from inside any of the
media managers, since they only see "no results" and never learn why. This notification is the
earliest and often the only warning that an indexer needs re-authenticating or has changed its
layout. `onApplicationUpdate` stays off because the image is updated by pulling it, not by the
application updating itself.

The credentials go in the request body rather than on a command line where possible — a bot token in
shell history or a process list is a token that can post to your channel forever. If you would rather
not have it in shell history at all, put the JSON in a file and use `-d @file`.

---

#### Step 6: Apply the host settings

```bash
KEY='<secret>'
BASE='https://prowlarr.your-domain.com/api/v1'

curl -s "$BASE/config/host" -H "X-Api-Key: $KEY" \
  | jq '. + { analyticsEnabled: false, urlBase: "" }' \
  | curl -sf -X PUT "$BASE/config/host" -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d @-
```

**Explanation**: this call reads the current object, merges two keys into it, and writes the whole
thing back. That is not an optimisation — this configuration endpoint replaces the entire resource,
and it requires the `id` field that came with it. Sending only the keys you want to change either
fails validation or silently resets everything you omitted to its default.

`urlBase` is deliberately empty. This service is served at the root of its own hostname by the
reverse proxy, so it must not prefix its links and API paths with a subpath; a non-empty value moves
every URL and immediately breaks the proxy route and every media manager's connection to it.
`analyticsEnabled: false` stops the application phoning usage data home — on a private homelab there
is no reason for it, and it is one fewer outbound connection to account for.

---

#### Step 7: Add the public indexers

```bash
KEY='<secret>'
BASE='https://prowlarr.your-domain.com/api/v1'

curl -s "$BASE/indexer" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/indexer" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "<indexer-name>",
    "implementation": "Cardigann",
    "configContract": "CardigannSettings",
    "protocol": "torrent",
    "privacy": "public",
    "definitionName": "<indexer-definition>",
    "enableRss": true,
    "enableAutomaticSearch": true,
    "enableInteractiveSearch": true,
    "appProfileId": 1,
    "priority": 25,
    "fields": [
      {"name": "definitionFile", "value": "<indexer-definition>"}
    ]
  }'

curl -s "$BASE/indexer" -H "X-Api-Key: $KEY" | jq -r 'length'
```

**Explanation**: `Cardigann` is Prowlarr's generic scraping engine for indexers that do not have a
dedicated native implementation — most public indexers fall into this category, and
`definitionName`/`definitionFile` name the site-specific definition bundled with the image (its exact
spelling matters and is case-sensitive). `appProfileId: 1` is the default application profile created
by Prowlarr on first start, which controls which categories are synced to which application type;
change it only if you have created additional profiles. Repeat the POST once per indexer you want,
checking the existing list first each time — same reasoning as the download client, a duplicate
indexer just doubles every search against the same site. This is the **only** place indexers are
added anywhere in this stack; do not add one directly inside Sonarr, Radarr or Lidarr.

---

#### Step 8: Register Radarr, Sonarr and Lidarr

```bash
KEY='<secret>'
BASE='https://prowlarr.your-domain.com/api/v1'

curl -s "$BASE/applications" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/applications" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Sonarr",
    "implementation": "Sonarr",
    "implementationName": "Sonarr",
    "configContract": "SonarrSettings",
    "enable": true,
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
      {"name": "baseUrl", "value": "http://sonarr:8989"},
      {"name": "apiKey", "value": "<sonarr-api-key>"},
      {"name": "syncCategories", "value": [5000, 5030, 5040]}
    ]
  }'

curl -sf -X POST "$BASE/applications" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Radarr",
    "implementation": "Radarr",
    "implementationName": "Radarr",
    "configContract": "RadarrSettings",
    "enable": true,
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
      {"name": "baseUrl", "value": "http://radarr:7878"},
      {"name": "apiKey", "value": "<radarr-api-key>"},
      {"name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060]}
    ]
  }'

curl -sf -X POST "$BASE/applications" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Lidarr",
    "implementation": "Lidarr",
    "implementationName": "Lidarr",
    "configContract": "LidarrSettings",
    "enable": true,
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
      {"name": "baseUrl", "value": "http://lidarr:8686"},
      {"name": "apiKey", "value": "<lidarr-api-key>"},
      {"name": "syncCategories", "value": [3000, 3010, 3020, 3030, 3040]}
    ]
  }'
```

**Explanation**: this is the step that actually wires the indexers you added in Step 7 out to the
media managers — everything before it configures Prowlarr itself, this is what makes it useful to
the rest of the stack. `prowlarrUrl` is what each application uses to call back into Prowlarr, and it
must be the internal bridge address, never the public hostname — routing this call through the proxy
and single sign-on would turn an automated background sync into a request that needs a browser
session. `baseUrl` is how Prowlarr reaches each application to push the sync, by container name for
the same reason.

`syncLevel: "fullSync"` means Prowlarr keeps that application's indexer list in permanent lockstep
with its own — add, remove, or disable an indexer here and every registered application picks up the
change on its own schedule, with no further action from you. The alternative, `addOnly`, only ever
adds and never removes, which quietly leaves a dead indexer configured in three places after you take
it out of the fourth.

`syncCategories` is what limits the sync to categories that make sense for each application — TV
categories to Sonarr, movie categories to Radarr, music categories to Lidarr — so a music-only
indexer never shows up as a phantom option inside Radarr. The numbers are the standard Newznab/Torznab
category codes for each media type; you do not need to memorise them, only to keep the mapping
correct if you add a specialised indexer with different categories later.

Check the existing applications list before posting each one — a duplicate registration syncs the
same indexer list into the same application twice and produces confusing "already exists" errors on
the far side.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–2 |
| `<username>` | Owner of the deploy directories | The account you administer this host with | Step 1 |
| `<puid>` / `<pgid>` | Numeric UID and GID the container runs as | Any consistent pair; Prowlarr never touches the media drives | Steps 1, 2 |
| `<docker-ip>` | Fixed address on the shared bridge network | Inside the bridge subnet, outside the auto-allocation pool | Step 2 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Bridge network addressing | Any private range that does not collide with your LAN | Before you start |
| `<timezone>` | IANA timezone name | The host's, so scheduled syncs and logs read correctly | Step 2 |
| `<secret>` (API key) | This service's API key | 32 hex characters: `openssl rand -hex 16`. Choose it before the first start | Steps 2, 4–8 |
| `<postgres-host>` | Address of the central database server | Its address or resolvable name; not a container name if it lives on another machine | Step 2 |
| `<db-user>` | Database login role | The shared media database account; must equal the Common Name in `prowlarr.crt` | Step 2, Before you start |
| `<secret>` (database password) | Password for that role | Supplied, but the certificate is what authenticates | Step 2 |
| `<telegram-bot-token>` | Bot token | From BotFather | Step 5 |
| `<telegram-chat-id>` | Destination chat | The numeric id of the chat or channel the bot posts to | Step 5 |
| `<indexer-name>` / `<indexer-definition>` | The indexer to add | The site's display name and the Cardigann definition filename bundled with the image | Step 7 |
| `<sonarr-api-key>` / `<radarr-api-key>` / `<lidarr-api-key>` | API keys of the media managers | Read from each application's own configuration | Step 8 |

## Verification

```bash
# container is up and healthy
docker ps --filter 'name=^prowlarr$'
docker inspect --format '{{.State.Health.Status}}' prowlarr

# it answers, and the API key works
curl -s https://prowlarr.your-domain.com/ping
curl -s https://prowlarr.your-domain.com/api/v1/system/status -H 'X-Api-Key: <secret>' \
  | jq '{version, isProduction, appData, startTime}'

# the database connection is the PostgreSQL one, not a local SQLite file
docker logs prowlarr 2>&1 | grep -i -m5 'postgres\|database'
ls ./data/prowlarr/config/*.db 2>/dev/null && echo "WARNING: a local database exists — the PostgreSQL settings were not applied"

# download client, notification and indexers are registered
curl -s https://prowlarr.your-domain.com/api/v1/downloadclient -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.name)\t\(.enable)"'
curl -s https://prowlarr.your-domain.com/api/v1/notification   -H 'X-Api-Key: <secret>' | jq -r '.[] | .name'
curl -s https://prowlarr.your-domain.com/api/v1/indexer         -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.name)\t\(.enable)"'

# the media managers are registered and their sync level is correct
curl -s https://prowlarr.your-domain.com/api/v1/applications -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.name)\t\(.syncLevel)"'

# nothing is unhealthy
curl -s https://prowlarr.your-domain.com/api/v1/health -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.type)\t\(.message)"'

# each application actually received the indexers, from its own side
curl -s https://sonarr.your-domain.com/api/v3/indexer -H 'X-Api-Key: <sonarr-api-key>' | jq -r '.[] | .name'
curl -s https://radarr.your-domain.com/api/v3/indexer -H 'X-Api-Key: <radarr-api-key>' | jq -r '.[] | .name'
curl -s https://lidarr.your-domain.com/api/v1/indexer -H 'X-Api-Key: <lidarr-api-key>' | jq -r '.[] | .name'

# the download client and each application are reachable from inside this container by name
docker exec prowlarr curl -sf -o /dev/null -w 'transmission: %{http_code}\n' http://transmission:9091/transmission/web/
docker exec prowlarr curl -sf -o /dev/null -w 'sonarr: %{http_code}\n' http://sonarr:8989/ping
docker exec prowlarr curl -sf -o /dev/null -w 'radarr: %{http_code}\n' http://radarr:7878/ping
docker exec prowlarr curl -sf -o /dev/null -w 'lidarr: %{http_code}\n' http://lidarr:8686/ping
```

An empty `health` array is the goal. The presence of a `*.db` file under `config/` means the
PostgreSQL environment variables were not picked up and the service quietly built a local database
instead — stop, fix the variables, delete the file and start again before you add any indexers.

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull lscr.io/linuxserver/prowlarr:latest
docker rm -f prowlarr
# re-run the docker run command from Step 2 verbatim
```

Nothing is lost: the state is in PostgreSQL and the settings are in the environment. This is also why
the environment variables are the source of truth rather than `config.xml` — recreating the container
re-applies them, so the configuration cannot drift.

**Logs:**

```bash
docker logs -f --tail 100 prowlarr
tail -f ./data/prowlarr/config/logs/prowlarr.txt
```

The file log is the useful one; indexer failures and database problems are written there with full
stack traces.

**Routine chores:**

```bash
# what is failing right now
curl -s https://prowlarr.your-domain.com/api/v1/health -H 'X-Api-Key: <secret>' | jq

# force an immediate sync out to every registered application
curl -sf -X POST https://prowlarr.your-domain.com/api/v1/command \
  -H 'X-Api-Key: <secret>' -H 'Content-Type: application/json' \
  -d '{"name": "ApplicationIndexerSync"}'

# trim the log database when it gets large (run on the PostgreSQL host)
docker exec -it postgres-db psql -U postgres -d prowlarr-log -c 'TRUNCATE "Logs";'
```

## Rollback / Uninstall

```bash
cd <deploy-dir>

docker rm -f prowlarr
sudo rm -rf ./data/prowlarr
docker image rm lscr.io/linuxserver/prowlarr:latest
```

That removes the container and its configuration. The state is in the database, so to remove it
completely, on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres <<'EOF'
DROP DATABASE IF EXISTS "prowlarr";
DROP DATABASE IF EXISTS "prowlarr-log";
EOF
```

Removing this container leaves Sonarr, Radarr and Lidarr with the indexer list they last synced —
they do not remove it on their own — so also clear it in each application:

```bash
curl -s https://sonarr.your-domain.com/api/v3/indexer -H 'X-Api-Key: <sonarr-api-key>' \
  | jq -r '.[].id' | xargs -I{} curl -sf -X DELETE https://sonarr.your-domain.com/api/v3/indexer/{} -H 'X-Api-Key: <sonarr-api-key>'
```

Repeat with the corresponding `/api/v3/indexer` or `/api/v1/indexer` endpoint and API key for Radarr
and Lidarr.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container restarts in a loop on first start | It cannot reach the database. `docker logs prowlarr` names it: wrong host, missing database, or the client certificate is not readable. Check `docker exec prowlarr ls -l /postgres-certs`. |
| `connection requires a valid client certificate` | `./data/certs/prowlarr.crt`/`.key` are missing, expired, or the CN does not match the database role. `openssl x509 -in ./data/certs/prowlarr.crt -noout -subject -dates`. |
| `permission denied for schema public` | The database exists but is not owned by the login role. Re-create it with `OWNER "<db-user>"` or `ALTER DATABASE ... OWNER TO`. |
| A `.db` file appears under `config/` | The `PROWLARR__POSTGRES__*` variables were not applied, so it built a local database. Recreate the container with the full environment and delete the file. |
| Every API call returns a login page or 302 | The single sign-on portal's bypass rules for `^/ping.*` and `^/api/.*` on this hostname are missing. Add them there. |
| API calls return 401 | Wrong API key. It is whatever `PROWLARR__AUTH__APIKEY` was set to at start — `docker inspect prowlarr --format '{{json .Config.Env}}' \| tr ',' '\n' \| grep APIKEY`. |
| An application never receives an indexer | It is not registered under `/api/v1/applications`, or its `syncLevel` is not `fullSync`. Check with `curl .../api/v1/applications`. |
| An indexer syncs to the wrong applications, or none | `syncCategories` on that application's registration does not overlap the indexer's own categories. Re-check the category numbers in Step 8. |
| Indexer returns "test failed" or repeated captchas | The site requires authentication fields this indexer definition needs (cookie, API key) that were not filled in through the interface, or the site is blocking the host's address. |
| Two of everything gets synced | A duplicate application or indexer was added. `curl .../api/v1/applications` or `.../api/v1/indexer` and delete the extra by its id. |
| Telegram messages stop | The bot token was rotated, or the bot was removed from the chat. Test with the notification's "Test" button in the interface. |
| Search from inside Prowlarr never grabs | The registered download client is unreachable. `docker exec prowlarr curl -v http://transmission:9091/transmission/web/`. |
| Everything is slow and the database grows fast | The log database has not been trimmed. `TRUNCATE "Logs";` in the `prowlarr-log` database. |
