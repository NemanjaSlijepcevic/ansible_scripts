# Immich

## What this is

Immich is a self-hosted photo and video backup platform — the same job Google Photos or iCloud
Photos does, running on your own hardware. Phones and desktops upload originals to it over its own
API; it stores them, extracts EXIF metadata, and runs machine-learning jobs (face recognition, CLIP
embeddings for text/image search, duplicate detection) so the library is searchable the way a cloud
photo service is.

It runs as a **four-container stack** on its own dedicated host, all four on the shared `proxy`
bridge network:

- **`immich-postgres`** — a PostgreSQL database built specifically for Immich, with the
  `pgvector`/`vectorchord` extensions compiled in. This is a **separate, dedicated** database
  server, not the central PostgreSQL server the rest of the stack shares — Immich stores the
  machine-learning embeddings as vector columns and searches them with similarity queries, and the
  central server does not carry the extensions that requires. `immich-postgres` is this stack's own
  data store; nothing else in the homelab reads or writes it.
- **`immich-redis`** — a Valkey (Redis-compatible) container that holds the background job queue
  between the application server and its workers. It is pure in-memory state; nothing here needs to
  survive a restart, so it has no volume.
- **`immich-machine-learning`** — runs the face detection, CLIP embedding and duplicate-detection
  models. It downloads model weights from the internet the first time each model is used and caches
  them to disk, so repeat jobs do not re-download.
- **`immich-server`** — the API and web front end everything else talks to. It is what phones,
  browsers and the other three containers connect to.

The photo library itself is **not** copied into any container. An existing photo archive on the
host is bind-mounted into `immich-server` **read-only**, and Immich indexes it in place as an
External Library — uploads from phones and the browser go to a separate, container-owned upload
directory.

Once the server is healthy, the administrator account is created and single sign-on is wired up
through Immich's **own admin API** — there is no configuration file for this, it is two API calls
against the running server. Immich's route at the reverse proxy carries **no forced login**
(`chain-no-auth@file`): Immich authenticates its own users (email/password, or the OIDC button this
guide sets up), and its mobile apps talk to the API directly rather than a browser, so a forward-auth
gate in front of the whole site would break every mobile client before it ever reaches Immich's own
login screen. The intrusion-prevention bouncer and the security headers still apply to this route —
only the SSO redirect is skipped.

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

Every path in this guide is relative to `<deploy-dir>`. Run all commands from there.

**The shared `proxy` bridge network exists**

Every container in this stack sits on one user-defined bridge network called `proxy`, so the four
containers can reach each other by name and the reverse proxy always knows where to send a request.

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

**The reverse proxy (Traefik) is running**

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
curl -sI https://proxy.your-domain.com | head -1
```

**Single sign-on (Authelia) is running, and an OIDC client is registered for Immich**

Immich's route bypasses forced login, but the OIDC button you configure in Step 8 authenticates
against the portal, so it must already be up:

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

You need a client identifier and client secret the portal has registered for Immich, with the
redirect URIs Immich's own login flow expects — the web client's callback
(`https://immich.your-domain.com/auth/login`) and, if you also use the mobile app,
`app.immich:///oauth-callback`. The portal stores the secret hashed and cannot show it back to you
later, so keep the value from when the client was registered.

**DNS resolves to this host**

```bash
dig +short immich.your-domain.com
```

**The photo library's host path exists and is readable**

```bash
findmnt -no TARGET,SOURCE,FSTYPE <library-path>
ls -ld <library-path>
```

Docker creates a missing bind-mount source as an empty root-owned directory rather than failing, so
if this path does not already exist, the container starts successfully against an empty library and
gives no obvious error.

## Setup

### Overview

1. Create the data directories.
2. Start `immich-postgres` (the database).
3. Start `immich-redis` (the job queue).
4. Start `immich-machine-learning`.
5. Start `immich-server`, mounting the upload directory and the external library.
6. Wait for the server to answer its health endpoint.
7. Create the administrator account.
8. Configure single sign-on through the admin API.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

mkdir -p ./data/immich/upload ./data/immich/postgres ./data/immich/model-cache
sudo chown -R <username>:<pgid> ./data/immich
sudo chmod 0755 ./data/immich
```

**Explanation**: unlike the media-server images elsewhere in this stack, none of the four Immich
images take a `PUID`/`PGID` pair — they manage their own internal accounts, so ownership by your
deploy account is enough everywhere under `./data/immich`. `postgres/` is the database's own data
directory (this must survive container recreation — it **is** the library's metadata). `upload/` is
where files land when a phone or browser uploads through the API. `model-cache/` holds the
machine-learning weights once they are downloaded, so a container recreation does not mean
re-downloading them from the internet.

---

#### Step 2: Start the database container

```bash
docker run -d \
  --name immich-postgres \
  --restart unless-stopped \
  --network proxy \
  -e POSTGRES_USER='<db-user>' \
  -e POSTGRES_PASSWORD='<secret>' \
  -e POSTGRES_DB='<db-name>' \
  -e POSTGRES_INITDB_ARGS='--data-checksums' \
  -v "$(pwd)/data/immich/postgres:/var/lib/postgresql/data" \
  --health-cmd "pg_isready -d <db-name> -U <db-user>" \
  --health-interval 1m \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0
```

**Explanation**: this image is PostgreSQL 14 with `pgvector` and `vectorchord` already compiled in —
the reason Immich brings its own database rather than a client certificate into the central server
like almost everything else in this stack. `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` are
read only on the very first start, when the empty data directory is initialised, and this one
account doubles as both the database's superuser and the login Immich's server connects as — this
is a single-tenant instance, so there is no separate admin-vs-application-role split the way the
central server has. `--data-checksums` turns on page-level checksums at `initdb` time; it can only be
set when the cluster is created, which is why it is passed as an `initdb` argument here rather than
a setting you could change later, and it is what lets corruption in a photo library's metadata be
detected rather than silently served.

---

#### Step 3: Start the job-queue container

```bash
docker run -d \
  --name immich-redis \
  --restart unless-stopped \
  --network proxy \
  --health-cmd "valkey-cli ping || exit 1" \
  --health-interval 1m \
  --health-timeout 10s \
  --health-retries 3 \
  docker.io/valkey/valkey:8-bookworm
```

**Explanation**: Valkey is the open-source fork of Redis used here purely as a broker — the server
pushes jobs onto it (thumbnail generation, metadata extraction, face detection, library scans) and
the machine-learning container and the server's own background workers pull from it. There is no
volume because none of that state is meant to survive a restart; a lost queue just means the pending
jobs run again on the next scan.

---

#### Step 4: Start the machine-learning container

```bash
docker run -d \
  --name immich-machine-learning \
  --restart unless-stopped \
  --network proxy \
  -v "$(pwd)/data/immich/model-cache:/cache" \
  --health-cmd 'python3 -c "import urllib.request; urllib.request.urlopen(\"http://localhost:3003/ping\")"' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 60s \
  ghcr.io/immich-app/immich-machine-learning:release
```

**Explanation**: this container has no database or queue connection of its own — the server calls it
directly over HTTP for each job and hands back the result. `/cache` is where downloaded model
weights (the face-detection and CLIP models) land the first time they are used; without a persistent
mount here, every container recreation re-downloads them, which on a slow link can make the first
job after an update take minutes instead of seconds. The 60-second health-check start period exists
for the same reason — the first classification request after a cold start may still be loading a
model into memory.

---

#### Step 5: Start the application server

```bash
docker run -d \
  --name immich-server \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -e DB_HOSTNAME=immich-postgres \
  -e DB_USERNAME='<db-user>' \
  -e DB_PASSWORD='<secret>' \
  -e DB_DATABASE_NAME='<db-name>' \
  -e REDIS_HOSTNAME=immich-redis \
  -e UPLOAD_LOCATION=/usr/src/app/upload \
  -e IMMICH_MACHINE_LEARNING_URL=http://immich-machine-learning:3003 \
  -v "$(pwd)/data/immich/upload:/usr/src/app/upload" \
  -v "<library-path>:/external:ro" \
  -v /etc/localtime:/etc/localtime:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.immich.entrypoints=https' \
  --label 'traefik.http.routers.immich.rule=Host(`immich.your-domain.com`)' \
  --label 'traefik.http.routers.immich.tls=true' \
  --label 'traefik.http.routers.immich.middlewares=chain-no-auth@file' \
  --label 'traefik.http.routers.immich.service=immich' \
  --label 'traefik.http.services.immich.loadbalancer.server.port=2283' \
  --health-cmd 'wget --quiet --spider http://localhost:2283/api/server/ping || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 60s \
  --health-start-interval 10s \
  ghcr.io/immich-app/immich-server:release
```

**Explanation**: `DB_HOSTNAME=immich-postgres` and `REDIS_HOSTNAME=immich-redis` resolve through
Docker's own DNS on the `proxy` network — all four containers must stay on it for this to work.
`UPLOAD_LOCATION` must match the mount target exactly, because every file Immich stores — originals,
thumbnails, re-encoded video — lives under this path; the bind mount to `./data/immich/upload` is
what makes that survive a container recreation. `TZ` is fixed to a literal value here rather than a
per-host variable: it only affects timestamps Immich writes into its own logs and job records, not
the photo dates themselves (those come from EXIF), so a single timezone for this deployment is
deliberate rather than an oversight. `/etc/localtime` is mounted read-only alongside it because some
of Immich's internal libraries read the system timezone file directly rather than the `TZ`
environment variable.

`<library-path>:/external:ro` is the existing photo archive, mounted **read-only** — Immich never
writes into it, only reads. Mounting it does not make it appear automatically: after the container is
up, add it from the admin console as an **External Library** pointing at the container path
`/external`, not the host path. Immich stores whatever path you give it verbatim, and a host path it
cannot see produces a library that scans zero items.

The route carries `chain-no-auth@file`, not the authenticated chain. The intrusion-prevention bouncer
and the security headers still run; only the forced sign-on redirect is skipped, because Immich's
mobile apps authenticate directly against its API and cannot complete a browser login redirect.

---

#### Step 6: Wait for the server to answer its health endpoint

```bash
for i in $(seq 1 10); do
  curl -sf -o /dev/null https://immich.your-domain.com/api/server/ping && { echo "immich: ready"; break; }
  echo "waiting for immich..."; sleep 15
done

docker inspect --format '{{.State.Health.Status}}' immich-server
```

**Explanation**: the first start runs Immich's database schema migrations before it can answer
anything, which takes noticeably longer than a restart. Ten attempts fifteen seconds apart gives it
up to two and a half minutes; every step after this one is an HTTP call against the running server,
so there is nothing to gain by proceeding before it answers.

---

#### Step 7: Create the administrator account

```bash
curl -s -X POST https://immich.your-domain.com/api/auth/admin-sign-up \
  -H 'Content-Type: application/json' \
  -d '{"email":"<admin-email>","name":"Admin","password":"<secret>"}'
```

**Explanation**: this endpoint only ever creates the **first** account and refuses every call after
that with a `400`, which makes the command safe to re-run — re-running this guide against an
already-set-up server just gets a harmless `400` here instead of a second administrator. This is the
local, non-SSO account: keep its password somewhere durable, because it is the only way in if the
single sign-on portal is ever down.

---

#### Step 8: Configure single sign-on through the admin API

```bash
TOKEN=$(curl -s -X POST https://immich.your-domain.com/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"<admin-email>","password":"<secret>"}' | jq -r .accessToken)

CONFIG=$(curl -s https://immich.your-domain.com/api/admin/system-config \
  -H "Authorization: Bearer $TOKEN")

echo "$CONFIG" | jq '.oauth.enabled'   # if this already prints "true", the rest of this step is done

curl -s -X PUT https://immich.your-domain.com/api/admin/system-config \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(echo "$CONFIG" | jq '.oauth = {
        "enabled": true,
        "issuerUrl": "https://auth.your-domain.com/.well-known/openid-configuration",
        "clientId": "<oidc-client-id>",
        "clientSecret": "<secret>",
        "scope": "openid profile email",
        "buttonText": "Login with Authelia",
        "autoRegister": true,
        "autoLaunch": false,
        "mobileOverrideEnabled": false,
        "mobileRedirectUri": "",
        "defaultStorageQuota": 0,
        "storageLabelClaim": "preferred_username",
        "storageQuotaClaim": "immich_quota",
        "signingAlgorithm": "RS256",
        "profileSigningAlgorithm": "none"
      }')"
```

**Explanation**: `PUT /api/admin/system-config` replaces the **entire** configuration document, not
just the section you care about — every other setting (storage template, job concurrency, backup
schedule) would reset to its default if you sent the `oauth` block alone. That is why the current
config is fetched first and only its `oauth` key is overwritten before sending the whole thing back.

`issuerUrl` here is the full discovery-document URL, not just the portal's base address — Immich
fetches it directly rather than appending `/.well-known/openid-configuration` itself, so leaving that
suffix off produces a login button that fails immediately. `scope` must include `profile` and
`email` because `storageLabelClaim` reads the `preferred_username` claim those scopes carry.
`autoRegister: true` means the first successful SSO login creates the matching Immich account itself,
so no user has to be pre-created by hand; `autoLaunch: false` keeps the normal login form visible
alongside the SSO button rather than redirecting every visitor straight to the portal.
`defaultStorageQuota: 0` is Immich's convention for "no limit" — `storageQuotaClaim` lets a specific
user's token override that with a custom `immich_quota` claim if the portal is ever configured to
send one, but nothing in this deployment does, so every SSO user gets the unlimited default.
`signingAlgorithm`/`profileSigningAlgorithm` describe how the portal signs its tokens; leaving the
profile algorithm as `none` matches the portal, which does not sign its plain userinfo response.

## Restoring

`immich-postgres` is this stack's only data store — the upload directory and the external library
are plain files, restored the way you restore any other files on this host. **This host is not
covered by the stack's automatic database backup** — that job only runs against the central
database server and the other core hosts. Back this database up yourself, on a schedule:

```bash
docker exec immich-postgres pg_dumpall -U <db-user> --globals-only | gzip -c > immich_globals.sql.gz
docker exec immich-postgres pg_dump -U <db-user> -Fc -d <db-name> > immich_<db-name>.dump
```

**Restore into the running container.** Stop the server first, so nothing writes while the restore
runs:

```bash
docker stop immich-server

docker exec -i immich-postgres pg_restore -U <db-user> -d <db-name> --clean --if-exists \
  < immich_<db-name>.dump

docker start immich-server
```

**Restore into an empty cluster** — the case after losing the machine entirely:

```bash
docker stop immich-postgres && docker rm immich-postgres
sudo rm -rf ./data/immich/postgres
```

Start the container again exactly as in Step 2 (it runs `initdb` and recreates the account from the
environment variables), wait for `pg_isready`, then load the globals and the database:

```bash
docker exec immich-postgres pg_isready -U <db-user>

zcat immich_globals.sql.gz | docker exec -i immich-postgres psql -U <db-user> -d postgres
docker exec immich-postgres createdb -U <db-user> <db-name> 2>/dev/null || true
docker exec -i immich-postgres pg_restore -U <db-user> -d <db-name> --clean --if-exists \
  < immich_<db-name>.dump

docker start immich-server
```

**Explanation**: because this instance's superuser and Immich's own login role are the same account,
the restore needs no owner remapping the way a restore into the central server does. The upload
directory (`./data/immich/upload`) is not part of these dumps — back it up separately with whatever
file-level tool you use elsewhere (`rsync`, `tar`), since it holds the actual image and video bytes
the database only has metadata for. The model cache never needs restoring; it re-downloads on demand.
The external library is untouched by any of this — it is a read-only mount of a photo archive that
lives outside Immich's control entirely.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Before you start, all steps |
| `<username>` | Owner of `./data/immich` | The account you administer this host with | Step 1 |
| `<pgid>` | Group id for that ownership | Any group your deploy account belongs to | Step 1 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | Any private range that does not collide with your LAN | Before you start |
| `<db-user>` / `<secret>` (db password) / `<db-name>` | Immich's dedicated PostgreSQL account and database | Chosen once, used by both the database and server containers | Steps 2, 5, Restoring |
| `<library-path>` | Host path of the existing photo archive | Wherever that archive is already mounted on this host | Before you start, Step 5 |
| `<admin-email>` | Local administrator's login | Anything; it is the break-glass account used when the portal is down | Steps 7, 8 |
| `<secret>` (admin password) | Password for that account | Generate one: `openssl rand -base64 24` | Steps 7, 8 |
| `<oidc-client-id>` / `<secret>` (OIDC client secret) | The client Authelia has registered for Immich | Set when you register the client with the portal; the secret cannot be read back afterwards | Before you start, Step 8 |

## Verification

```bash
# all four containers are up and healthy
docker ps --filter 'name=immich'
for c in immich-postgres immich-redis immich-machine-learning immich-server; do
  printf '%s: ' "$c"; docker inspect --format '{{.State.Health.Status}}' "$c"
done

# the server answers
curl -sf https://immich.your-domain.com/api/server/ping

# the database has the extensions this stack needs
docker exec immich-postgres psql -U <db-user> -d <db-name> -c '\dx'

# oauth is configured
TOKEN=$(curl -s -X POST https://immich.your-domain.com/api/auth/login \
  -H 'Content-Type: application/json' -d '{"email":"<admin-email>","password":"<secret>"}' | jq -r .accessToken)
curl -s https://immich.your-domain.com/api/admin/system-config \
  -H "Authorization: Bearer $TOKEN" | jq '.oauth.enabled, .oauth.issuerUrl'

# the SSO login start redirects to the portal
curl -s -o /dev/null -w '%{http_code}\n' https://immich.your-domain.com/api/oauth/authorize
```

`\dx` should list `vector` and `vectorchord` among the installed extensions. `oauth.enabled` should
read `true`.

## Updating & day-to-day

**Pull new images and recreate.** The machine-learning and server images are pulled with `:release`,
a rolling tag, so recreate them whenever you want the latest version; the database image is pinned to
a specific PostgreSQL major version and should only move deliberately:

```bash
docker pull docker.io/valkey/valkey:8-bookworm
docker pull ghcr.io/immich-app/immich-machine-learning:release
docker pull ghcr.io/immich-app/immich-server:release

docker rm -f immich-redis immich-machine-learning immich-server
# re-run the docker run commands from Steps 3, 4 and 5 verbatim
```

All state — the database, the uploads, the model cache — lives under `./data/immich`, so recreating
any of the four containers loses nothing. A move to a newer `immich-postgres` image tag with a
different PostgreSQL major version needs a dump-and-restore into a freshly initialised data
directory, the same as the central server.

**Logs:**

```bash
docker logs -f --tail 100 immich-server
docker logs -f --tail 100 immich-machine-learning
```

**Trigger a library scan by hand** (after adding or changing the external library):

```bash
curl -sf -X POST https://immich.your-domain.com/api/libraries/<library-id>/scan \
  -H "Authorization: Bearer $TOKEN"
```

**Routine chores**: watch the size of `./data/immich/model-cache` (grows the first time each new
model type is used) and `./data/immich/postgres` (grows with the library). The upload directory
grows with every photo uploaded through the app and is the one directory here that genuinely needs
its own backup story beyond this guide's database dumps.

## Rollback / Uninstall

```bash
for c in immich-server immich-machine-learning immich-redis immich-postgres; do
  docker rm -f "$c"
done
```

```bash
# WARNING: destroys the database, the upload directory and the ML model cache
sudo rm -rf ./data/immich
```

The external library at `<library-path>` is never touched by any of this — it was mounted
read-only and Immich never wrote to it.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `immich-server` cannot reach the database | `DB_HOSTNAME=immich-postgres` resolves via the shared `proxy` network — confirm all four containers are attached to it and `immich-postgres` reports `healthy` (`docker exec immich-postgres pg_isready -U <db-user>`). |
| `immich-machine-learning` never becomes healthy | The first model download is stalled or blocked — the container needs outbound internet access the first time each model type runs. Check `docker logs immich-machine-learning`. |
| External library shows zero items | The library was added by its host path instead of the container path `/external`, or the bind-mount source did not exist when the container started (Docker silently creates an empty directory). Remove and re-add the library pointing at `/external`; confirm the source with `ls -ld <library-path>` before starting the container. |
| Admin sign-up returns `400` on a fresh install | Another account already claimed the administrator slot — check the login page rather than re-running Step 7. |
| SSO button is missing or fails immediately | `oauth.enabled` is `false`, or `issuerUrl` is missing the `/.well-known/openid-configuration` suffix. Re-check with the `Verification` query above. |
| SSO login succeeds but no account is created | `autoRegister` is `false`, or the portal is not sending the `email`/`profile` scopes. Confirm `scope` in the OAuth config and that the portal's discovery document advertises them. |
| `PUT /api/admin/system-config` appears to reset unrelated settings | The call sent a partial body instead of the full config merged with the new `oauth` block — always fetch the current config first, as in Step 8. |
| Uploads succeed but disappear after a restart | `UPLOAD_LOCATION` does not match the volume mount target, so files landed inside the container's writable layer instead of `./data/immich/upload`. Recreate the container with the flags from Step 5. |
| Restore fails with a role/ownership error | This instance's login role and superuser are the same account (`<db-user>`), unlike the central server — do not pass `--no-owner` or a different `--role` here; it is unnecessary and can mask a mismatched username instead. |
