# Lidarr

## What this is

Lidarr is the music manager. You add an artist once; from then on Lidarr tracks which albums exist,
which are missing and which are newly released, searches the indexers for a release that meets the
quality profile you chose, hands the torrent to the download client, and when the download finishes
imports the tracks into the library — tagging and renaming them, moving them onto the music drive,
and telling the media server to rescan.

It runs as a single container on the storage host, on the shared `proxy` bridge network with a fixed
address, and is published by the reverse proxy at `https://lidarr.your-domain.com`. Its database is
**not** local: it stores everything in the central PostgreSQL server, in two databases (`lidarr` and
`lidarr-log`), over a mutually-authenticated TLS connection.

What it talks to, all by container name on the shared network:

- **`transmission`** on port 9091 — the download client it sends torrents to.
- **`prowlarr`** on port 9696 — the indexer manager. Lidarr does not configure indexers itself; the
  indexer manager pushes them in, which is why you will not add any by hand here.
- **`jellyfin`** on port 8096 — the media server, notified after every successful import so a finished
  album appears in the library within seconds instead of at the next scheduled scan.
- **The central PostgreSQL server**, over TLS with a client certificate.
- **The MusicBrainz metadata service**, over the internet — this is where artist, album and track
  metadata comes from, and it is the one external dependency that will stop imports dead if it is
  unreachable.
- **Telegram**, over the internet, for grab/import/health notifications.

Everything on the inside of the bridge is addressed by **container name, never by IP and port on the
host**. Docker's embedded DNS resolves `transmission` and `jellyfin` to whatever address those
containers currently hold, so a container that gets recreated with a different address does not break
the link — and none of that traffic ever leaves the bridge, so it needs no published port, no TLS,
and no pass through the reverse proxy.

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

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in this guide is bind-mounted from here. Run all commands from `<deploy-dir>`
so the relative paths resolve.

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
health endpoint and every API call in this guide — and every call the indexer manager makes — get a
login redirect instead of JSON. The API path is not left unguarded by that: it is protected by the
API key instead.

Confirm the exception is live once the container is running:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://lidarr.your-domain.com/ping     # expect 200
curl -s -o /dev/null -w '%{http_code}\n' https://lidarr.your-domain.com/         # expect 302 to the portal
```

**The service's DNS name resolves to this host**

```bash
dig +short lidarr.your-domain.com
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
sudo openssl x509 -in ./data/certs/lidarr.crt -noout -subject -dates
```

You need three files on this host: `./data/certs/lidarr.crt`, `./data/certs/lidarr.key`, and the
issuing `./data/certs/ca.crt`. They are signed on the PostgreSQL host and copied here; the service
never generates its own. Without them the container starts and then fails every query with
`connection requires a valid client certificate (SQLSTATE 28000)`.

The `subject` printed above is what matters: the CN is the **database role**, which is not
necessarily the file name. The file is called `lidarr.crt` for convenience; the role inside it is the
shared media database account.

**The databases and role exist on the PostgreSQL server**

Run on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep -E 'lidarr'
docker exec -it postgres-db psql -U postgres -c '\du' | grep <db-user>
```

Both `lidarr` and `lidarr-log` must exist and be owned by the login role, otherwise the first start
fails part-way through its schema migration with `permission denied for schema public`. Create them
if they are missing:

```bash
docker exec -it postgres-db psql -U postgres <<'EOF'
CREATE DATABASE "lidarr"     OWNER "<db-user>";
CREATE DATABASE "lidarr-log" OWNER "<db-user>";
EOF
```

**The download client is running**

```bash
docker ps --filter 'name=^transmission$'
docker exec transmission curl -sf -o /dev/null -w '%{http_code}\n' http://localhost:9091/transmission/web/
```

**The media server is running** (only needed for Step 7)

```bash
docker ps --filter 'name=^jellyfin$'
curl -sf -o /dev/null -w '%{http_code}\n' https://jellyfin.your-domain.com/health
```

You also need its API key for Step 7; it is created in the media server's dashboard under API Keys.

**Outbound HTTPS works, and the metadata service answers**

```bash
docker run --rm curlimages/curl -sf -o /dev/null -w '%{http_code}\n' https://musicbrainz.org
```

Without metadata this service cannot add an artist at all — every search returns nothing and the
interface shows a metadata provider error.

**The music and download drives are mounted, and you know the UID that owns them**

```bash
findmnt -no TARGET,SOURCE,FSTYPE <music-path> <downloads-path>
ls -ld <music-path> <downloads-path>/Download
stat -c '%u %g %n' <music-path> <downloads-path>
```

The two numbers from `stat` are `<puid>` and `<pgid>` for the rest of this guide. They must be the
same numbers the download client and the media server run as.

## Setup

### Overview

1. Make sure the drives and the category folder exist with the right ownership.
2. Create the configuration directory.
3. Start the container.
4. Wait for it to answer `/ping`.
5. Add the download client.
6. Add the Telegram notification.
7. Add the media server connection.
8. Apply the interface and host settings.

---

#### Step 1: Prepare the drives and the category folder

```bash
cd <deploy-dir>

sudo chmod 0755 <music-path> <downloads-path>
sudo mkdir -p <downloads-path>/Download/complete/lidarr
sudo chown <puid>:<pgid> <downloads-path>/Download/complete/lidarr
sudo chmod 0755 <downloads-path>/Download/complete/lidarr
```

**Explanation**: the two `chmod` calls make the drive roots traversable by the container's user; if
either fails because the filesystem is a network share that does not accept mode changes, that is not
fatal — what matters is that the container can traverse them, which you confirm in the Verification
section. The category folder is where the download client will place finished music torrents, and its
name must exactly equal the category label you configure in Step 5 (`lidarr`). Creating it up front
with the container's own UID means the very first completed download can be moved in without a
permission failure; left to be created later by whichever process gets there first, it can end up
owned by root and every import then fails with "permission denied" long after you have forgotten
about this step.

---

#### Step 2: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/lidarr
sudo chown <username>:<pgid> ./data/lidarr
sudo chmod 0755 ./data/lidarr
```

**Explanation**: only the parent is created here. The container creates `./data/lidarr/config` itself
on first start, as its own user, and populates it with `config.xml`, the log files and the cached
cover art. The parent belongs to your deploy account so you can inspect and back it up without
`sudo`.

---

#### Step 3: Start the container

```bash
cd <deploy-dir>

docker run -d \
  --name lidarr \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TZ=<timezone> \
  -e LIDARR__AUTH__APIKEY='<secret>' \
  -e LIDARR__AUTH__METHOD=External \
  -e LIDARR__AUTH__REQUIRED=DisabledForLocalAddresses \
  -e LIDARR__SERVER__PORT=8686 \
  -e LIDARR__POSTGRES__HOST=<postgres-host> \
  -e LIDARR__POSTGRES__PORT=5432 \
  -e LIDARR__POSTGRES__USER='<db-user>' \
  -e LIDARR__POSTGRES__PASSWORD='<secret>' \
  -e LIDARR__POSTGRES__MAINDB=lidarr \
  -e LIDARR__POSTGRES__LOGDB=lidarr-log \
  -e PGSSLMODE=verify-ca \
  -e PGSSLCERT=/postgres-certs/lidarr.crt \
  -e PGSSLKEY=/postgres-certs/lidarr.key \
  -e PGSSLROOTCERT=/postgres-certs/ca.crt \
  -v "$(pwd)/data/lidarr/config:/config" \
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
  -v "<music-path>:/music" \
  -v "<downloads-path>/Download:/downloads" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.lidarr.entrypoints=https' \
  --label 'traefik.http.routers.lidarr.rule=Host(`lidarr.your-domain.com`)' \
  --label 'traefik.http.routers.lidarr.tls=true' \
  --label 'traefik.http.routers.lidarr.middlewares=chain-auth@file' \
  --label 'traefik.http.services.lidarr.loadbalancer.server.port=8686' \
  --health-cmd 'curl --fail http://localhost:8686/ping || exit 1' \
  --health-interval 90s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  lscr.io/linuxserver/lidarr:latest
```

**Explanation**, setting by setting:

`PUID`/`PGID` are honoured by this image's init, which drops to those numbers before starting the
application. They must match the owner of the music and download directories, and must be the **same**
numbers the download client uses, because importing a finished album is a rename or a hardlink from
the download folder into the library — an operation that needs write access on both sides. Different
UIDs turn every import into a copy at best and a permission error at worst. Music matters here more
than elsewhere: this service also **rewrites the tags** in the imported files, so it needs write
access to the file itself, not just to the directory.

`LIDARR__AUTH__APIKEY` sets the API key from the outside instead of letting the application generate
a random one into `config.xml` on first start. That is what makes the rest of this guide possible: you
know the key before the service exists, so the indexer manager and every command below can be
configured without first reading a generated value back out of a file inside the container. All of
these double-underscore variables map onto the application's own configuration keys — `SECTION__KEY`
— so anything you can set in `config.xml` you can set here, and the environment wins.

`LIDARR__AUTH__METHOD=External` means the application does not render its own login form: it trusts
that whatever is in front of it has already authenticated the user. That "whatever" is the single
sign-on portal, applied by the `chain-auth@file` middleware on the route. Combined with
`LIDARR__AUTH__REQUIRED=DisabledForLocalAddresses`, requests arriving from private addresses — the
other containers on the bridge — skip the check entirely, which is how the indexer manager talks to
it. Anything from outside comes through the proxy and is authenticated there. Never publish this
container's port to the host: that combination would put an unauthenticated interface on the LAN.

`LIDARR__POSTGRES__MAINDB` and `__LOGDB` are two separate databases on purpose. The log database takes
the overwhelming majority of the writes — every search, every grab, every health check writes rows —
and keeping it out of the main database means its bloat, its vacuum load and its size never touch the
library data, and you can truncate it wholesale without risking a single artist record.

The four `PGSSL*` variables are read by the PostgreSQL driver itself, not by the application.
`verify-ca` makes the client verify the server's certificate against `ca.crt`, so it cannot be
tricked into talking to an impostor database. The client certificate is not optional decoration: the
server's rules use certificate authentication, so the Common Name inside `lidarr.crt` is what actually
decides which database role you connect as — the password is supplied but the certificate is what
authenticates. The certificate directory is mounted **read-only**; nothing in this container has any
business writing to it, and the key is shared with the other services on the host.

`/downloads` is mounted as the whole `Download` tree, not just the completed subfolder. Both this
container and the download client must see the finished file at the *same path*, because the download
client reports the path it saved to and this service then acts on that exact string. Mount only the
completed folder and the reported path does not exist here, producing the "downloaded album could not
be imported" errors that are the single most common problem in this stack.

The music drive is mounted at its root (`<music-path>` → `/music`), so the root folder you add inside
the application is simply `/music`.

The route uses `chain-auth@file`: TLS at the proxy, the intrusion-prevention bouncer, security
headers, then forward-authentication against the single sign-on portal.

---

#### Step 4: Wait for it to answer `/ping`

```bash
for i in $(seq 1 10); do
  curl -sf https://lidarr.your-domain.com/ping && { echo; echo "lidarr: ready"; break; }
  echo "waiting for lidarr..."; sleep 10
done

docker inspect --format '{{.State.Health.Status}}' lidarr
```

**Explanation**: `/ping` answers `{"status":"OK"}` only after the schema migration against PostgreSQL
has finished and the HTTP pipeline is up. A first start against an empty database creates dozens of
tables and can take a minute; every configuration call below fails with a connection error if you run
it too early. If the loop never succeeds, `docker logs lidarr` will name the database problem
directly.

---

#### Step 5: Add the download client

```bash
KEY='<secret>'   # the API key from Step 3
BASE='https://lidarr.your-domain.com/api/v1'

# do not add a second copy
curl -s "$BASE/downloadclient" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/downloadclient" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Transmission",
    "implementation": "Transmission",
    "configContract": "TransmissionSettings",
    "protocol": "torrent",
    "priority": 1,
    "enable": true,
    "fields": [
      {"name": "host", "value": "transmission"},
      {"name": "port", "value": 9091},
      {"name": "useSsl", "value": false},
      {"name": "username", "value": "<username>"},
      {"name": "password", "value": "<secret>"},
      {"name": "musicCategory", "value": "lidarr"},
      {"name": "recentMusicPriority", "value": 0}
    ]
  }'
```

**Explanation**: note the API prefix — this service uses `/api/v1`, not the `/api/v3` used by the TV
and movie managers. Everything else is the same shape.

`host` is the literal container name `transmission` and `port` is 9091 — the port *inside* the bridge
network, which is not necessarily published on the host at all. Using the container name means
Docker's embedded DNS resolves it at connect time, so recreating the download client with a different
address changes nothing here; using an IP would hard-code something that is guaranteed to change
eventually. `useSsl` is false because this hop never leaves the bridge: there is nothing to intercept
between two containers on the same host, and terminating TLS internally would mean issuing and
rotating a certificate for a container name.

`musicCategory` is the label attached to every torrent this service hands over. The download client
turns that label into the subdirectory it saves to — `Download/complete/lidarr`, the folder created in
Step 1 — and this service then looks there for finished downloads. The category string and the folder
name must match exactly; if you change one, change the other. `recentMusicPriority: 0` puts recent
releases in the normal queue rather than at the front of it.

The credentials are sent because the download client *may* be configured to require RPC
authentication. If it is not, they are simply ignored; supplying them costs nothing and means the
connection keeps working the day you turn authentication on.

Check the existing list before posting. The API happily accepts two identically named download
clients, and then every release gets grabbed twice.

---

#### Step 6: Add the Telegram notification

```bash
KEY='<secret>'
BASE='https://lidarr.your-domain.com/api/v1'

curl -s "$BASE/notification" -H "X-Api-Key: $KEY" | jq -r '.[] | .name'

curl -sf -X POST "$BASE/notification" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Telegram",
    "implementation": "Telegram",
    "configContract": "TelegramSettings",
    "onGrab": true,
    "onDownload": true,
    "onUpgrade": true,
    "onRename": false,
    "onArtistDelete": false,
    "onAlbumDelete": false,
    "onHealthIssue": true,
    "onApplicationUpdate": false,
    "fields": [
      {"name": "botToken", "value": "<telegram-bot-token>"},
      {"name": "chatId", "value": "<telegram-chat-id>"}
    ]
  }'
```

**Explanation**: the event flags are chosen so the channel stays readable. Grab, import and upgrade
are the three events you actually want to see, and `onHealthIssue` is the one that matters most —
that is how you find out an indexer has started returning errors, the metadata service is refusing
requests, or the download client has become unreachable, without watching the interface. Renames and
deletions are off because a single library reorganisation would otherwise send hundreds of messages,
and `onApplicationUpdate` is off because the image is updated by pulling it, not by the application
updating itself.

The credentials go in the request body rather than on a command line where possible — a bot token in
a shell history or a process list is a token that can post to your channel forever. If you would
rather not have it in shell history at all, put the JSON in a file and use `-d @file`.

---

#### Step 7: Add the media server connection

```bash
KEY='<secret>'
BASE='https://lidarr.your-domain.com/api/v1'

curl -sf -X POST "$BASE/notification" \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{
    "name": "Jellyfin",
    "implementation": "MediaBrowser",
    "configContract": "MediaBrowserSettings",
    "onGrab": false,
    "onDownload": true,
    "onUpgrade": true,
    "onRename": true,
    "onArtistAdd": false,
    "onArtistDelete": false,
    "onAlbumDelete": false,
    "onTrackRetag": false,
    "onHealthIssue": false,
    "onApplicationUpdate": false,
    "fields": [
      {"name": "host", "value": "jellyfin"},
      {"name": "port", "value": 8096},
      {"name": "useSsl", "value": false},
      {"name": "apiKey", "value": "<jellyfin-api-key>"},
      {"name": "urlBase", "value": ""},
      {"name": "notify", "value": true},
      {"name": "updateLibrary", "value": true},
      {"name": "sendOnGrab", "value": false}
    ]
  }'
```

**Explanation**: despite living under `/notification`, this is not really a notification — it is the
library-update hook. `updateLibrary: true` is the part that matters: after a successful import this
service calls the media server's API and tells it to rescan the affected folder, so a finished album
is playable within seconds instead of whenever the media server's own scheduled scan next runs.
Turning the scheduled scan down and relying on this hook is much cheaper on a spinning disk than
scanning the whole library every hour — and a music library has far more files per gigabyte than a
video one, so a full scan is correspondingly more expensive.

The implementation is called `MediaBrowser` because that is what the media server's API dialect was
called before it was forked; it is the right value for Jellyfin.

Again the connection is by container name over plain HTTP on the bridge (`jellyfin:8096`), not
through the public hostname. Going out through the proxy and back in would add TLS, the bouncer and a
DNS round-trip to a call that happens after every single import, and would break entirely whenever
external DNS is unavailable.

`onGrab` and `sendOnGrab` are false — there is nothing for the media server to do when a torrent is
merely grabbed; the file does not exist yet. `onTrackRetag` is also false: re-tagging changes the
file's metadata but not its path, so the media server has nothing to rescan. `onRename: true` is on so
that a library reorganisation does not leave the media server pointing at paths that no longer exist.

`<jellyfin-api-key>` is the permanent API key from the media server, not a session token.

---

#### Step 8: Apply the interface and host settings

```bash
KEY='<secret>'
BASE='https://lidarr.your-domain.com/api/v1'

# interface: Monday-first weeks, day/month/year dates, 24-hour clock
curl -s "$BASE/config/ui" -H "X-Api-Key: $KEY" \
  | jq '. + {
      firstDayOfWeek: 1,
      calendarWeekColumnHeader: "ddd D/M",
      shortDateFormat: "DD/MM/YYYY",
      longDateFormat: "dddd, DD MMMM YYYY",
      timeFormat: "HH:mm"
    }' \
  | curl -sf -X PUT "$BASE/config/ui" -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d @-

# host: no analytics, served at the root of its own hostname
curl -s "$BASE/config/host" -H "X-Api-Key: $KEY" \
  | jq '. + { analyticsEnabled: false, urlBase: "" }' \
  | curl -sf -X PUT "$BASE/config/host" -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d @-
```

**Explanation**: both calls read the current object, merge a handful of keys into it, and write the
whole thing back. That is not an optimisation — these configuration endpoints replace the entire
resource, and they require the `id` field that came with it. Sending only the keys you want to change
either fails validation or silently resets everything you omitted to its default.

`urlBase` is deliberately empty. This service is served at the root of its own hostname by the
reverse proxy, so it must not prefix its links and API paths with a subpath; a non-empty value moves
every URL and immediately breaks the proxy route and the indexer manager's connection to it.

`analyticsEnabled: false` stops the application phoning usage data home. On a private homelab there is
no reason for it, and it is one fewer outbound connection to account for.

## How this fits with the other media services

| Direction | What happens | How it is addressed |
| --- | --- | --- |
| Indexer manager → this service | Pushes the indexer list in and keeps it in sync. You never add indexers here. | The indexer manager holds this service's API key and calls `http://lidarr:8686` |
| This service → download client | Sends the torrent with the category `lidarr` | `transmission:9091` on the bridge |
| Download client → disk | Writes the finished files into `Download/complete/lidarr` | Shared `<downloads-path>` mount |
| This service → library | Imports (hardlink or move) into `<music-path>`, re-tags and renames | Both are visible in the container as `/downloads` and `/music` |
| This service → media server | "Rescan this folder" after every import | `jellyfin:8096` on the bridge |
| This service → MusicBrainz | Artist, album and track metadata | Outbound HTTPS |

If the indexer manager is not yet running, this service will simply have no indexers and find
nothing. Confirm it is up:

```bash
docker ps --filter 'name=^prowlarr$'
curl -sf -o /dev/null -w '%{http_code}\n' https://prowlarr.your-domain.com/ping
```

## Path layout

| Path | Contents |
| --- | --- |
| `./data/lidarr/config/` | `config.xml`, logs, cached cover art. **Not** the database. |
| `./data/lidarr/config/logs/` | `lidarr.txt` and rotated copies — where import and indexer errors actually appear |
| `./data/certs/` | Client certificate, key and CA for the database connection; mounted read-only as `/postgres-certs` |
| `<music-path>` | The music library, mounted as `/music`; add `/music` as the root folder inside the application |
| `<downloads-path>/Download` | The whole download tree, mounted as `/downloads` |
| `<downloads-path>/Download/complete/lidarr` | Where the download client places finished music torrents |
| PostgreSQL `lidarr` | Artists, albums, tracks, quality and metadata profiles, history — the real state |
| PostgreSQL `lidarr-log` | Application log rows; safe to truncate |

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–3 |
| `<username>` | Owner of the deploy directories | The account you administer this host with | Step 2 |
| `<puid>` / `<pgid>` | Numeric UID and GID the container runs as | Must equal the owner of the music and download directories, and match the download client and media server | Steps 1, 3 |
| `<docker-ip>` | Fixed address on the shared bridge network | Inside the bridge subnet, outside the auto-allocation pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Bridge network addressing | Any private range that does not collide with your LAN | Before you start |
| `<timezone>` | IANA timezone name | The host's, so the calendar and release dates read correctly | Step 3 |
| `<music-path>` / `<downloads-path>` | Mount points of the music and download drives | Where the drives are actually mounted; check with `findmnt` | Steps 1, 3 |
| `<secret>` (API key) | This service's API key | 32 hex characters: `openssl rand -hex 16`. Choose it before the first start | Steps 3, 5–8, and in the indexer manager |
| `<postgres-host>` | Address of the central database server | Its address or resolvable name; not a container name if it lives on another machine | Step 3 |
| `<db-user>` | Database login role | The shared media database account; must equal the Common Name in `lidarr.crt` | Step 3, Before you start |
| `<secret>` (database password) | Password for that role | Supplied, but the certificate is what authenticates | Step 3 |
| `<username>` / `<secret>` (download client) | Download client RPC credentials | Whatever the download client is configured with; ignored if it does not require them | Step 5 |
| `<telegram-bot-token>` | Bot token | From BotFather | Step 6 |
| `<telegram-chat-id>` | Destination chat | The numeric id of the chat or channel the bot posts to | Step 6 |
| `<jellyfin-api-key>` | Media server API key | Created in the media server's dashboard under API Keys | Step 7 |

## Verification

```bash
# container is up and healthy
docker ps --filter 'name=^lidarr$'
docker inspect --format '{{.State.Health.Status}}' lidarr

# it answers, and the API key works
curl -s https://lidarr.your-domain.com/ping
curl -s https://lidarr.your-domain.com/api/v1/system/status -H 'X-Api-Key: <secret>' \
  | jq '{version, isProduction, appData, startTime}'

# the database connection is the PostgreSQL one, not a local SQLite file
docker logs lidarr 2>&1 | grep -i -m5 'postgres\|database'
ls ./data/lidarr/config/*.db 2>/dev/null && echo "WARNING: a local database exists — the PostgreSQL settings were not applied"

# the download client, notifications and media server hook are registered
curl -s https://lidarr.your-domain.com/api/v1/downloadclient -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.name)\t\(.enable)"'
curl -s https://lidarr.your-domain.com/api/v1/notification   -H 'X-Api-Key: <secret>' | jq -r '.[] | .name'

# indexers arrived from the indexer manager
curl -s https://lidarr.your-domain.com/api/v1/indexer -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.name)\t\(.enableRss)"'

# nothing is unhealthy
curl -s https://lidarr.your-domain.com/api/v1/health -H 'X-Api-Key: <secret>' | jq -r '.[] | "\(.type)\t\(.message)"'

# the container can actually read and write both trees
docker exec lidarr ls -ld /music /downloads /downloads/complete/lidarr
docker exec lidarr touch /music/.write-test && docker exec lidarr rm /music/.write-test && echo "library writable: ok"

# the download client, media server and metadata service are reachable from inside this container
docker exec lidarr curl -sf -o /dev/null -w 'transmission: %{http_code}\n' http://transmission:9091/transmission/web/
docker exec lidarr curl -sf -o /dev/null -w 'jellyfin: %{http_code}\n' http://jellyfin:8096/health
docker exec lidarr curl -sf -o /dev/null -w 'musicbrainz: %{http_code}\n' https://musicbrainz.org
```

An empty `health` array is the goal. The presence of a `*.db` file under `config/` means the
PostgreSQL environment variables were not picked up and the service quietly built a local database
instead — stop, fix the variables, delete the file and start again before you add any artists.

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull lscr.io/linuxserver/lidarr:latest
docker rm -f lidarr
# re-run the docker run command from Step 3 verbatim
```

Nothing is lost: the state is in PostgreSQL and the settings are in the environment. This is also why
the environment variables are the source of truth rather than `config.xml` — recreating the container
re-applies them, so the configuration cannot drift.

**Logs:**

```bash
docker logs -f --tail 100 lidarr
tail -f ./data/lidarr/config/logs/lidarr.txt
```

The file log is the useful one; import failures, metadata errors and database problems are written
there with full stack traces.

**Routine chores:**

```bash
# what is failing right now
curl -s https://lidarr.your-domain.com/api/v1/health -H 'X-Api-Key: <secret>' | jq

# items stuck in the queue
curl -s 'https://lidarr.your-domain.com/api/v1/queue?pageSize=100' -H 'X-Api-Key: <secret>' \
  | jq -r '.records[] | "\(.title)\t\(.status)\t\(.trackedDownloadState)\t\(.errorMessage // "")"'

# trim the log database when it gets large (run on the PostgreSQL host)
docker exec -it postgres-db psql -U postgres -d lidarr-log -c 'TRUNCATE "Logs";'
```

Watch disk on the download drive: torrents seed after import, so the download tree only shrinks when
you or the download client removes completed items.

## Rollback / Uninstall

```bash
cd <deploy-dir>

docker rm -f lidarr
sudo rm -rf ./data/lidarr
docker image rm lscr.io/linuxserver/lidarr:latest
```

That removes the container and its configuration. The state is in the database, so to remove it
completely, on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres <<'EOF'
DROP DATABASE IF EXISTS "lidarr";
DROP DATABASE IF EXISTS "lidarr-log";
EOF
```

Also remove the entry for this service in the indexer manager, otherwise it keeps trying to sync
indexers into a service that is gone and reports a health error.

The music library and the downloads are untouched — both are bind mounts and nothing in the uninstall
touches them.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container restarts in a loop on first start | It cannot reach the database. `docker logs lidarr` names it: wrong host, missing database, or the client certificate is not readable. Check `docker exec lidarr ls -l /postgres-certs`. |
| `connection requires a valid client certificate` | `./data/certs/lidarr.crt`/`.key` are missing, expired, or the CN does not match the database role. `openssl x509 -in ./data/certs/lidarr.crt -noout -subject -dates`. |
| `permission denied for schema public` | The database exists but is not owned by the login role. Re-create it with `OWNER "<db-user>"` or `ALTER DATABASE ... OWNER TO`. |
| A `.db` file appears under `config/` | The `LIDARR__POSTGRES__*` variables were not applied, so it built a local database. Recreate the container with the full environment and delete the file. |
| Every API call returns a login page or 302 | The single sign-on portal's bypass rules for `^/ping.*` and `^/api/.*` on this hostname are missing. Add them there. |
| API calls return 401 | Wrong API key. It is whatever `LIDARR__AUTH__APIKEY` was set to at start — `docker inspect lidarr --format '{{json .Config.Env}}' \| tr ',' '\n' \| grep APIKEY`. |
| API calls return 404 on paths that work elsewhere | This service uses `/api/v1`, not `/api/v3`. |
| Web interface loads but every page is empty | `urlBase` is not empty, so the interface is asking for its assets under a subpath the proxy does not route. Set it back to `""` (Step 8). |
| Cannot add any artist; search returns nothing | The metadata service is unreachable or rate-limiting. `docker exec lidarr curl -v https://musicbrainz.org` and check the health list. |
| "Downloaded album could not be imported" | The path the download client reports does not exist in this container. Both must mount the same tree at the same path: `/downloads` here must contain the folder the download client says it saved to. |
| Imports copy instead of hardlinking, and the disk fills | The download tree and the library are on different filesystems, or the UIDs differ. Hardlinks only work within one filesystem; check `df <music-path> <downloads-path>`. |
| Import fails with "permission denied" | `PUID`/`PGID` do not match the owner of the completed folder. `docker exec lidarr id` and `stat -c '%u %g' <downloads-path>/Download/complete/lidarr`. |
| Files import but tags are not written | The files themselves are not writable by the container's user — check the file mode, not just the directory. |
| No indexers at all | The indexer manager has not synced. Check that this service is registered there and that its sync level is a full sync. |
| Two of everything gets grabbed | A duplicate download client was added. `curl .../api/v1/downloadclient` and delete the extra by its id. |
| Telegram messages stop | The bot token was rotated, or the bot was removed from the chat. Test with the notification's "Test" button in the interface. |
| Media server never picks up new albums | The connection's `updateLibrary` is false, or its API key was revoked. Re-test the connection and confirm `docker exec lidarr curl -sf http://jellyfin:8096/health`. |
| Everything is slow and the database grows fast | The log database has not been trimmed. `TRUNCATE "Logs";` in the `lidarr-log` database. |
