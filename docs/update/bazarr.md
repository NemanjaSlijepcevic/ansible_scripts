# Bazarr

## What this is

Bazarr is the subtitle manager for the media stack. It reads the movie and TV libraries that Radarr
and Sonarr manage, works out which subtitle languages are missing for each file, searches subtitle
providers for them, and drops the result next to the video file in the format the media server
expects.

It runs as a single container on the storage host, on the shared `proxy` bridge network with a fixed
address, and is published by the reverse proxy at `https://bazarr.your-domain.com`. Unlike the
`*arr` applications it manages, Bazarr does not take its configuration from environment variables —
it reads a YAML file on disk at startup, so that file has to be written correctly *before* the
container's first start. Its database is **not** local either: it stores its state in the central
PostgreSQL server, in a single `bazarr` database, over a mutually-authenticated TLS connection.

What it talks to, all by container name on the shared network:

- **`sonarr`** on port 8989 and **`radarr`** on port 7878 — the TV and film managers whose libraries
  it scans for missing subtitles. Both connections, including their API keys, are baked into the
  config file at startup; Bazarr does not go looking for them itself.
- **The central PostgreSQL server**, over TLS with a client certificate.
- **Podnapisi and Titlovi.com**, over the internet, as subtitle providers.
- **Telegram**, over the internet, for notifications — configured as a row in its own database rather
  than a setting in the config file, so it is added after the first start rather than written into
  `config.yaml`.

Everything on the inside of the bridge is addressed by **container name, never by IP and port on the
host**. Docker's embedded DNS resolves `sonarr` and `radarr` to whatever address those containers
currently hold, so a container that gets recreated with a different address does not break the link —
and none of that traffic ever leaves the bridge, so it needs no published port, no TLS, and no pass
through the reverse proxy.

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

**The service's DNS name resolves to this host**

```bash
dig +short bazarr.your-domain.com
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
sudo openssl x509 -in ./data/certs/bazarr.crt -noout -subject -dates
```

You need three files on this host: `./data/certs/bazarr.crt`, `./data/certs/bazarr.key`, and the
issuing `./data/certs/ca.crt`. They are signed on the PostgreSQL host and copied here; the service
never generates its own. Without them the container starts but every query against the database
fails with `connection requires a valid client certificate (SQLSTATE 28000)`.

The `subject` printed above is what matters: the CN is the **database role**, which is not
necessarily the file name. The file is called `bazarr.crt` for convenience; the role inside it is the
shared media database account — the same account Sonarr, Radarr and Prowlarr connect as.

**The database and role exist on the PostgreSQL server**

Run on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep -E 'bazarr'
docker exec -it postgres-db psql -U postgres -c '\du' | grep <db-user>
```

`bazarr` must exist and be owned by the login role, otherwise the first start fails with a database
permission error before the web interface ever comes up. Create it if it is missing:

```bash
docker exec -it postgres-db psql -U postgres -c 'CREATE DATABASE "bazarr" OWNER "<db-user>";'
```

**Sonarr and Radarr are running, and you have their API keys**

```bash
docker ps --filter 'name=^sonarr$' --filter 'name=^radarr$'
curl -sf -o /dev/null -w 'sonarr: %{http_code}\n' https://sonarr.your-domain.com/ping
curl -sf -o /dev/null -w 'radarr: %{http_code}\n' https://radarr.your-domain.com/ping
```

Bazarr's connection to both is written into its config file at Step 2, complete with their API keys,
so it never has to discover them at runtime. If either is not yet running, Bazarr still starts but
finds no series or movies to fetch subtitles for.

**The movie and TV drives are mounted, and you know the UID that owns them**

```bash
findmnt -no TARGET,SOURCE,FSTYPE <movies-path> <tv-path>
ls -ld <movies-path> <tv-path>/Serije
stat -c '%u %g %n' <movies-path> <tv-path>
```

The two numbers from `stat` are `<puid>` and `<pgid>` for the rest of this guide. Bazarr only reads
video files and writes subtitle files next to them — it never renames or moves anything — but it
still needs write access in the library to drop the subtitle file, so these must be the same numbers
the media managers use.

## Setup

### Overview

1. Create the configuration directory.
2. Write the config file.
3. Start the container.
4. Wait for it to answer `/api/system/ping`.
5. Enable the languages you actually want.
6. Add the Telegram notification.

---

#### Step 1: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/bazarr/config ./data/bazarr/config/config
sudo chown <puid>:<pgid> ./data/bazarr/config ./data/bazarr/config/config
sudo chmod 0755 ./data/bazarr/config ./data/bazarr/config/config
```

**Explanation**: both directories are created with the container's own UID rather than left for the
container to create on first start. That matters here specifically because Step 2 writes the config
file into `config/config/config.yaml` *before* the container ever runs — if the directory does not
exist yet, or is owned by the wrong user, the container's first start fails to open a config file that
is either missing or unwritable, instead of reading the one you prepared.

---

#### Step 2: Write the config file

Bazarr reads a single YAML file at startup and does not regenerate it once it exists. Write the whole
thing now, with every value it needs filled in — there is no environment-variable equivalent for any
of this.

```bash
sudo tee ./data/bazarr/config/config/config.yaml >/dev/null <<'EOF'
general:
  use_radarr: true
  use_sonarr: true
  language_equals:
    - bos:srp
    - hrv:srp
    - hbs:srp
  enabled_providers:
    - podnapisi
    - titlovi

auth:
  apikey: <secret>
  type: null
  username: ''
  password: ''

postgresql:
  enabled: true
  host: <postgres-host>
  port: 5432
  database: bazarr
  username: <db-user>
  password: <secret>

sonarr:
  ip: sonarr
  port: 8989
  base_url: ''
  ssl: false
  apikey: <sonarr-api-key>
  http_timeout: 60
  full_update: Daily
  full_update_day: 6
  full_update_hour: 4
  only_monitored: false
  series_sync: 60
  series_sync_on_live: true
  use_ffprobe_cache: true
  exclude_season_zero: false
  defer_search_signalr: false
  sync_only_monitored_series: false
  sync_only_monitored_episodes: false
  excluded_tags: []
  excluded_series_types: []

titlovi:
  username: <titlovi-username>
  password: <titlovi-password>

radarr:
  ip: radarr
  port: 7878
  base_url: ''
  ssl: false
  apikey: <radarr-api-key>
  http_timeout: 60
  full_update: Daily
  full_update_day: 6
  full_update_hour: 4
  only_monitored: false
  movies_sync: 60
  movies_sync_on_live: true
  use_ffprobe_cache: true
  defer_search_signalr: false
  sync_only_monitored_movies: false
  excluded_tags: []
EOF

sudo chown <username>:docker ./data/bazarr/config/config/config.yaml
sudo chmod 0644 ./data/bazarr/config/config/config.yaml
```

**Explanation**: the `sonarr`/`radarr` blocks are the entirety of "wiring Bazarr to the TV and film
managers" — there is no separate API call to make afterwards, because Bazarr reads these fields
itself on every scheduled sync (`series_sync`/`movies_sync`, in minutes) and calls out to
`http://sonarr:8989` and `http://radarr:7878` by container name, the same addressing every other
service on the bridge uses. `ssl: false` and empty `base_url` match how those two are actually served
internally: plain HTTP on the bridge, at the root of their path, never through the public hostname.

`language_equals` folds several closely related regional language tags into one for matching
purposes — Bosnian, Croatian and Serbo-Croatian subtitles are treated as equivalent to Serbian here,
which matters when a provider only tags a subtitle with one of the related codes.

`postgresql.enabled: true` is what stops Bazarr from falling back to a local SQLite file the moment
the file exists; get any of the four connection fields wrong and it silently does exactly that,
which is why the Verification section below checks for a stray database file under `config/`.

Owning the file with your own account (not the container's UID) after writing it is deliberate: you
will edit it again by hand far more often than the container writes to it, and Bazarr only re-reads
it at its own next start.

---

#### Step 3: Start the container

```bash
cd <deploy-dir>

docker run -d \
  --name bazarr \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TZ=<timezone> \
  -e PGSSLMODE=verify-ca \
  -e PGSSLCERT=/postgres-certs/bazarr.crt \
  -e PGSSLKEY=/postgres-certs/bazarr.key \
  -e PGSSLROOTCERT=/postgres-certs/ca.crt \
  -v "$(pwd)/data/bazarr/config:/config" \
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
  -v "<movies-path>:/movies" \
  -v "<tv-path>/Serije:/tv" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.bazarr.entrypoints=https' \
  --label 'traefik.http.routers.bazarr.rule=Host(`bazarr.your-domain.com`)' \
  --label 'traefik.http.routers.bazarr.tls=true' \
  --label 'traefik.http.routers.bazarr.middlewares=chain-auth@file' \
  --label 'traefik.http.services.bazarr.loadbalancer.server.port=6767' \
  --health-cmd "curl --fail -H 'X-API-KEY: <secret>' http://localhost:6767/api/system/ping || exit 1" \
  --health-interval 90s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  lscr.io/linuxserver/bazarr:latest
```

**Explanation**: `PUID`/`PGID` are honoured by this image's init the same way as the media managers,
and must be the same numbers that own the movie and TV directories — Bazarr writes the subtitle file
directly into the library, so the write has to succeed under those ids.

The `PGSSL*` variables are read by the PostgreSQL driver itself, separately from the `postgresql:`
block in `config.yaml`. `verify-ca` makes the client verify the server's certificate against
`ca.crt` so it cannot be pointed at an impostor database, and the client certificate is what actually
authenticates the connection under `clientcert=verify-full` — the password in the config file is
supplied but the certificate is what decides which role you connect as. The certificate directory is
mounted **read-only**; nothing in this container has any business writing to it.

The API key is not set through the environment here — unlike the media managers, Bazarr has no
`AUTH__APIKEY`-style variable; the key it uses is whatever `auth.apikey` was set to in `config.yaml`
in Step 2. Every `X-API-KEY` header in this guide must match that value.

There is no equivalent of `AUTH__METHOD=External` for Bazarr either. `auth.type: null` in the config
file already disables Bazarr's own login form, and the route is protected the same way as every other
interface in this stack — by `chain-auth@file` at the proxy — so the two layers do the same job by
different means and neither one needs to know about the other. Never publish this container's port to
the host: doing so would put an unauthenticated interface on the LAN.

`/movies` and `/tv` are mounted read-write, not read-only: Bazarr has to be able to write the
subtitle file it downloads next to the video. It is never given the download tree at all — it has no
business there, since it works only against files that are already in the library.

The route uses `chain-auth@file`: TLS at the proxy, the intrusion-prevention bouncer, security
headers, then forward-authentication against the single sign-on portal. The health check repeats the
API key because `/api/system/ping` (like every route under `/api/`) requires it — unlike the media
managers, Bazarr does not expose a separate unauthenticated `/ping`.

---

#### Step 4: Wait for it to answer `/api/system/ping`

```bash
for i in $(seq 1 10); do
  curl -sf -H 'X-API-KEY: <secret>' https://bazarr.your-domain.com/api/system/ping \
    && { echo; echo "bazarr: ready"; break; }
  echo "waiting for bazarr..."; sleep 10
done

docker inspect --format '{{.State.Health.Status}}' bazarr
```

**Explanation**: the endpoint answers only once Bazarr has read `config.yaml`, connected to
PostgreSQL and finished its schema migration if one was needed. Every call below needs that to have
finished, or it fails with a connection error rather than a meaningful one. If the loop never
succeeds, `docker logs bazarr` will usually show the config file failing to parse or the database
being unreachable.

---

#### Step 5: Enable the languages you actually want

Bazarr ships with every language disabled and no language profile defined. Do both directly against
its database — there is no API endpoint for either.

```bash
docker exec -it postgres-db psql -U postgres -d bazarr <<'EOF'
UPDATE table_settings_languages
SET enabled = 1
WHERE code3 IN ('bos', 'hrv', 'hbs', 'srp')
  AND enabled IS DISTINCT FROM 1;

INSERT INTO table_languages_profiles ("profileId", cutoff, "originalFormat", items, name, "mustContain", "mustNotContain", tag)
SELECT 1, NULL, 0,
  '[{"id": 1, "language": "sr", "audio_exclude": "False", "audio_only_include": "False", "hi": "False", "forced": "False"}]',
  'Srpski', '[]', '[]', NULL
WHERE NOT EXISTS (
  SELECT 1 FROM table_languages_profiles WHERE "profileId" = 1
);
EOF
```

**Explanation**: `table_settings_languages` is Bazarr's master list of every subtitle language it
knows about; only enabled rows are ever searched. `code3 IN (...)` here enables the closely related
regional languages the `language_equals` block in `config.yaml` already treats as interchangeable —
enabling the codes without also folding them together in the config would leave Bazarr matching
subtitles too strictly and finding almost nothing for a mixed-language library.

The profile insert is guarded by `WHERE NOT EXISTS` so running this twice does not create a second
profile with the same id and confuse the "which profile does this series use" logic. Change the
`language` code and `name` for a different primary language; this example is Serbian. A language
profile is what you then attach to a series or movie's monitoring settings in the web interface —
enabling the language alone is not enough for Bazarr to search for it.

---

#### Step 6: Add the Telegram notification

```bash
docker exec -it postgres-db psql -U postgres -d bazarr <<'EOF'
INSERT INTO table_settings_notifier (name, url, enabled)
SELECT 'Telegram', 'tgram://<telegram-bot-token>/<telegram-chat-id>', 1
WHERE NOT EXISTS (
  SELECT 1 FROM table_settings_notifier WHERE name = 'Telegram'
);
EOF
```

**Explanation**: Bazarr's notification channels are Apprise URLs stored as rows in
`table_settings_notifier`, not a REST resource like the media managers use — there is no
`/api/notification` endpoint to POST to. `tgram://<bot-token>/<chat-id>` is Apprise's own URL scheme
for Telegram; get the token or chat id wrong and the row is created successfully but every send then
fails silently until you check the logs. The `WHERE NOT EXISTS` guard exists for the same reason as
the language profile insert: running this step twice must not produce two Telegram rows sending the
same message twice.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–3 |
| `<username>` | Owner of the deploy directories | The account you administer this host with | Step 2 |
| `<puid>` / `<pgid>` | Numeric UID and GID the container runs as | Must equal the owner of the movie and TV directories | Steps 1, 3, Before you start |
| `<docker-ip>` | Fixed address on the shared bridge network | Inside the bridge subnet, outside the auto-allocation pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Bridge network addressing | Any private range that does not collide with your LAN | Before you start |
| `<timezone>` | IANA timezone name | The host's, so scheduled syncs run when you expect | Step 3 |
| `<movies-path>` / `<tv-path>` | Mount points of the movie and TV drives | Where the drives are actually mounted; check with `findmnt` | Steps 2 (`Before you start`), 3 |
| `<secret>` (API key) | Bazarr's own API key | 32 hex characters: `openssl rand -hex 16`. Set it in `config.yaml`, it is never generated for you | Steps 2, 3, 4 |
| `<postgres-host>` | Address of the central database server | Its address or resolvable name; not a container name if it lives on another machine | Step 2 |
| `<db-user>` | Database login role | The shared media database account; must equal the Common Name in `bazarr.crt` | Step 2, Before you start |
| `<secret>` (database password) | Password for that role | Supplied, but the certificate is what authenticates | Step 2 |
| `<sonarr-api-key>` / `<radarr-api-key>` | API keys of the TV and film managers | Read from each service's own configuration | Step 2 |
| `<titlovi-username>` / `<titlovi-password>` | Titlovi.com account | A registered account on that subtitle provider; leave blank to skip it | Step 2 |
| `<telegram-bot-token>` | Bot token | From BotFather | Step 6 |
| `<telegram-chat-id>` | Destination chat | The numeric id of the chat or channel the bot posts to | Step 6 |

## Verification

```bash
# container is up and healthy
docker ps --filter 'name=^bazarr$'
docker inspect --format '{{.State.Health.Status}}' bazarr

# it answers, and the API key works
curl -s -H 'X-API-KEY: <secret>' https://bazarr.your-domain.com/api/system/status | jq

# the database connection is the PostgreSQL one, not a local SQLite file
docker logs bazarr 2>&1 | grep -i -m5 'postgres\|database'
ls ./data/bazarr/config/config/db/*.db 2>/dev/null && echo "WARNING: a local database exists — the PostgreSQL settings were not applied"

# Sonarr and Radarr are connected
curl -s -H 'X-API-KEY: <secret>' https://bazarr.your-domain.com/api/system/status | jq '.sonarrVersion, .radarrVersion'

# languages and profile landed
docker exec -it postgres-db psql -U postgres -d bazarr -c "SELECT name, code3, enabled FROM table_settings_languages WHERE enabled = 1;"
docker exec -it postgres-db psql -U postgres -d bazarr -c 'SELECT "profileId", name FROM table_languages_profiles;'

# Telegram row landed
docker exec -it postgres-db psql -U postgres -d bazarr -c "SELECT name, enabled FROM table_settings_notifier;"

# the container can actually write into both libraries
docker exec bazarr ls -ld /movies /tv
docker exec bazarr touch /tv/.write-test && docker exec bazarr rm /tv/.write-test && echo "library writable: ok"

# Sonarr and Radarr are reachable from inside this container by name
docker exec bazarr curl -sf -o /dev/null -w 'sonarr: %{http_code}\n' http://sonarr:8989/ping
docker exec bazarr curl -sf -o /dev/null -w 'radarr: %{http_code}\n' http://radarr:7878/ping
```

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull lscr.io/linuxserver/bazarr:latest
docker rm -f bazarr
# re-run the docker run command from Step 3 verbatim
```

The state is in PostgreSQL and the settings are in `config.yaml`, so nothing is lost by recreating the
container. Unlike the media managers, Bazarr does read `config.yaml` back on every start rather than
trusting environment variables for its own settings — if you edit the file, a restart is enough; you
do not need to recreate the container.

**Logs:**

```bash
docker logs -f --tail 100 bazarr
tail -f ./data/bazarr/config/log/bazarr.log
```

**Routine chores:**

```bash
# subtitles missing right now
curl -s -H 'X-API-KEY: <secret>' 'https://bazarr.your-domain.com/api/episodes/wanted?length=50' | jq '.data[] | .title'
curl -s -H 'X-API-KEY: <secret>' 'https://bazarr.your-domain.com/api/movies/wanted?length=50' | jq '.data[] | .title'

# force a full library resync instead of waiting for the scheduled one
curl -s -X POST -H 'X-API-KEY: <secret>' https://bazarr.your-domain.com/api/system/tasks \
  -H 'Content-Type: application/json' -d '{"taskid": "update_series"}'
```

## Rollback / Uninstall

```bash
cd <deploy-dir>

docker rm -f bazarr
sudo rm -rf ./data/bazarr
docker image rm lscr.io/linuxserver/bazarr:latest
```

That removes the container and its configuration. The state is in the database, so to remove it
completely, on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres -c 'DROP DATABASE IF EXISTS "bazarr";'
```

Existing subtitle files it already wrote into the movie and TV libraries are untouched — both are
bind mounts and nothing in the uninstall touches them.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container starts but the web interface never comes up | `config.yaml` failed to parse. `docker logs bazarr` names the offending line — YAML is indentation-sensitive, unlike the environment variables the media managers use. |
| `connection requires a valid client certificate` | `./data/certs/bazarr.crt`/`.key` are missing, expired, or the CN does not match the database role. `openssl x509 -in ./data/certs/bazarr.crt -noout -subject -dates`. |
| A `.db` file appears under `config/config/db/` | One of the four `postgresql:` fields in `config.yaml` is wrong, so Bazarr fell back to SQLite. Fix the file, delete the stray database, restart. |
| Every page returns a login page instead of the interface | The single sign-on portal is down, or `chain-auth@file` is missing from the router. Confirm with `docker exec authelia wget -qO- http://localhost:9091/api/health`. |
| API calls return 401 | Wrong API key. It is whatever `auth.apikey` was set to in `config.yaml` — `grep apikey ./data/bazarr/config/config/config.yaml`. |
| No series or movies show up | Sonarr or Radarr connection details in `config.yaml` are wrong, or one of them is not running. Check `sonarrVersion`/`radarrVersion` in `/api/system/status`. |
| Subtitles never download for a title | No language profile is attached to that series or movie in the interface — enabling a language (Step 5) is not the same as assigning its profile to a title. |
| Wrong or no regional-language subtitles found | `language_equals` in `config.yaml` does not include the code the provider tagged the subtitle with, or the language was never enabled in `table_settings_languages`. |
| Telegram never sends | The bot token or chat id in the Apprise URL is wrong, or the bot was removed from the chat — Bazarr does not surface a connection test for this the way the media managers do. Check the row directly: `SELECT url FROM table_settings_notifier WHERE name = 'Telegram';`. |
| "permission denied" writing a subtitle | `PUID`/`PGID` do not match the owner of the movie or TV directory. `docker exec bazarr id` and `stat -c '%u %g' <movies-path>`. |
