# Kaleidoscope

## What this is

Kaleidoscope is a self-hosted Django image gallery — albums of photographs served over the web, with
a text watermark stamped onto the images it delivers. It runs as a single container on the
public-facing server, serves HTTP with gunicorn on port 8000 inside the container, and keeps all of
its state on the host: one SQLite file, one directory of uploaded media, one directory of collected
static assets.

It talks to nothing else. There is no external database, no cache, no object store. It is published
to the internet by Traefik, which terminates TLS and matches the request by `Host()`.

This host is **on the internet**. Ports 80 and 443 are the only things exposed, both owned by
Traefik, and the public domain is proxied through Cloudflare. Every request passes
Cloudflare → Traefik (TLS termination) → the middleware chain → gunicorn.

The container's router carries **no middleware label of its own**, so it inherits the default chain
that the `https` entrypoint applies to every router on this host: real-client-IP recovery from the
Cloudflare headers, country geo-blocking, the IP allow list (which on this host also contains
Cloudflare's published ranges so proxied traffic is not dropped), the CrowdSec bouncer, security
headers, a rate limit, and finally single sign-on. Because the gallery is meant to be viewable by
anyone, **its domain is explicitly bypassed in the single sign-on access-control rules** — otherwise
every visitor would be shown a login portal. Django's own admin at `/admin/` is the only protection
on the write side, so give the administrator account a strong password; nothing in the proxy chain
is guarding it.

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
every container path below is bind-mounted from here. Run all commands from `<deploy-dir>` so the
relative paths resolve.

### The shared `proxy` bridge network exists

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

### Single sign-on (Authelia) is running, and this site is bypassed in it

Any router that carries the `chain-auth@file` middleware is forward-authenticated by Authelia. The
`https` entrypoint on this host applies that chain to **every** router by default, this one
included, so if Authelia is down the gallery returns 500 rather than a page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

The gallery's domain must appear in Authelia's access-control rules with `policy: bypass`:

```bash
docker exec authelia grep -n -A30 '^access_control' /config/configuration.yml
```

The block must contain an entry like this, and rules are evaluated top to bottom with the first
match winning:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
      - "gallery.your-domain.com"
      policy: bypass
```

If the gallery is also published under a second name, that name needs its own bypass entry too. The
application accepting a hostname and the sign-on layer allowing it are two separate lists, and it is
easy to add one and forget the other.

### The site's DNS name resolves to this host

```bash
dig +short gallery.your-domain.com
```

The name must resolve to the public address of this machine, or to Cloudflare if the record is
proxied. Traefik matches on the `Host()` rule, so a name that lands on the wrong machine produces a
404 from the wrong proxy rather than an error you can read.

### Enough disk for the media directory

Uploaded originals live on the host and never expire. Check the free space before you start:

```bash
df -h <deploy-dir>
```

### A Django secret key

```bash
openssl rand -base64 48
```

Keep it — it must stay identical across container replacements.

---

## Setup

### Overview

1. Create the data directories.
2. Put the SQLite database in place.
3. Start the container.
4. Initialise the schema, create the administrator, collect static files.

---

#### Step 1: Create the data directories

```bash
mkdir -p ./data/kaleidoscope/staticfiles ./data/kaleidoscope/media
sudo chown -R <username>:<pgid> ./data/kaleidoscope
sudo chmod -R 0755 ./data/kaleidoscope
```

**Explanation**: three things are bind-mounted into the container and all three must outlive it — the
SQLite database, the `media` directory holding every uploaded original, and `staticfiles`, where
Django puts the CSS and JavaScript it collects out of the image. Keeping them on the host is what
makes an image update a non-event. The ownership has to match the account Docker runs under here,
because the application writes uploads and collected assets as itself; a root-owned directory turns
the first upload into a 500 with nothing useful in the browser.

---

#### Step 2: Put the SQLite database in place

If you are carrying a gallery over from another host, copy its database in — **never overwrite one
that already exists**:

```bash
if [ ! -f ./data/kaleidoscope/db.sqlite3 ]; then
  cp <path-to-seed-db>/db.sqlite3 ./data/kaleidoscope/db.sqlite3
  sudo chown <username>:<pgid> ./data/kaleidoscope/db.sqlite3
  sudo chmod 0644 ./data/kaleidoscope/db.sqlite3
fi
```

For a fresh installation, create the file empty and let Django build the schema in Step 4:

```bash
[ -f ./data/kaleidoscope/db.sqlite3 ] || : > ./data/kaleidoscope/db.sqlite3
sudo chown <username>:<pgid> ./data/kaleidoscope/db.sqlite3
sudo chmod 0644 ./data/kaleidoscope/db.sqlite3
```

**Explanation**: the existence guard is a safety interlock, not a convenience. The database is
bind-mounted as a **single file**, and Docker silently creates a *directory* at that path when the
file is missing, after which the application dies with `unable to open database file` — an error
that looks like a permissions problem and is not. And an unconditional copy on redeploy would
replace a live gallery with a stale seed. Keep the parent directory writable as well as the file:
SQLite creates `-wal` and `-shm` siblings next to the database whenever it writes.

Note that the media files and the database are two halves of one dataset. A database restored
without its matching `media` directory renders as a gallery full of broken images, so treat them as
a pair whenever you copy, back up or restore.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name kaleidoscope \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <ip-address> \
  -e TZ=Europe/Belgrade \
  -e DEFAULT_DOMAIN=gallery.your-domain.com \
  -e EXTRA_DOMAIN=your-domain.com \
  -e INTERNAL_HOSTS=kaleidoscope \
  -e SECRET_KEY='<secret>' \
  -e EMBED_PARENT_ORIGIN=https://your-domain.com \
  -e IMAGE_WATERMARK_TEXT='<org-name>' \
  -v "$(pwd)/data/kaleidoscope/db.sqlite3:/app/db.sqlite3" \
  -v "$(pwd)/data/kaleidoscope/staticfiles:/app/staticfiles" \
  -v "$(pwd)/data/kaleidoscope/media:/app/media" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.kaleidoscope.entrypoints=https' \
  --label 'traefik.http.routers.kaleidoscope.rule=Host(`gallery.your-domain.com`)' \
  --label 'traefik.http.routers.kaleidoscope.tls=true' \
  --label 'traefik.http.services.kaleidoscope.loadbalancer.server.port=8000' \
  --health-cmd 'wget -q --spider http://kaleidoscope:8000/healthz' \
  --health-interval 30s \
  --health-timeout 6s \
  --health-retries 3 \
  --health-start-period 20s \
  nemanjaslijepcevic/kaleidoscope:latest
```

**Explanation**: `DEFAULT_DOMAIN`, `EXTRA_DOMAIN` and `INTERNAL_HOSTS` all feed Django's
`ALLOWED_HOSTS`. Django compares the incoming `Host` header against that list and answers **400 Bad
Request** for anything not on it, which is a deliberate defence against host-header poisoning of
generated links. `DEFAULT_DOMAIN` is the canonical public name, `EXTRA_DOMAIN` a second name the
site answers to (the bare domain, typically), and `INTERNAL_HOSTS` the container's own name so that
requests arriving over the internal network are accepted.

That last one is why the health check probes `http://kaleidoscope:8000/healthz` by container name
instead of `localhost`. A probe to `localhost` sends `Host: localhost`, which is not in
`ALLOWED_HOSTS`, so Django would answer 400 and the container would be flagged unhealthy while
serving the public site perfectly. Docker's embedded DNS on a user-defined network resolves a
container's own name from inside itself, so the container-name probe needs no extra wiring.
`--spider` makes `wget` fetch the headers and drop the body, exiting non-zero on a non-2xx status.

`IMAGE_WATERMARK_TEXT` is stamped onto the images the gallery serves; set it to whatever attribution
you want on the pictures. `EMBED_PARENT_ORIGIN` is the origin of the site that shows this page inside a frame. The page
reports its own height to that parent so the frame can be sized to fit, and it accepts the
parent's script (Cyrillic/Latin) and light/dark choices so a visitor who picks one on the outer
site sees it applied here too. Give it scheme and host only — it is compared against the
browser's report of who sent a message, which never includes a path, so a trailing slash makes
it match nothing. Leave it unset and the page still works: the height report goes to any parent
rather than a named one, and the outer site's two toggles stop reaching inside the frame.

`SECRET_KEY` signs session cookies and signed URLs — keep it stable across
redeploys or every logged-in session is invalidated. `--dns <ip-address>` points the container at
the local resolver so internal names resolve internally. TLS is terminated at Traefik, so gunicorn
only ever speaks plain HTTP on 8000: that is what the service port label advertises while the router
carries `tls=true`.

---

#### Step 4: Initialise the schema and collect static files

On a **new, empty** database:

```bash
docker exec -it kaleidoscope python manage.py migrate
docker exec -it kaleidoscope python manage.py createsuperuser
```

Then, on any installation:

```bash
docker exec kaleidoscope python manage.py collectstatic --noinput
ls ./data/kaleidoscope/staticfiles | head
docker inspect --format '{{ .State.Health.Status }}' kaleidoscope
```

**Explanation**: `migrate` applies only the migrations that are missing, so it is harmless on a
populated database and mandatory on an empty one, where the application otherwise answers 500 with
`no such table`. `collectstatic` copies the image's CSS and JavaScript into the bind-mounted
`staticfiles` directory the application serves them from; the image usually does this at startup,
but running it by hand is how you prove the directory is writable, and it is the step to repeat
after an image update that ships new assets. The administrator account created here is the only way
into `/admin/`, which is where albums and uploads are managed.

---

## Path layout

| Host path | Container path | What lives there |
| --- | --- | --- |
| `./data/kaleidoscope/db.sqlite3` | `/app/db.sqlite3` | albums, image metadata, users, sessions |
| `./data/kaleidoscope/media` | `/app/media` | uploaded originals — the irreplaceable part |
| `./data/kaleidoscope/staticfiles` | `/app/staticfiles` | CSS/JS collected out of the image; regenerable |

Back up the first two together. The third can always be rebuilt with `collectstatic`.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | working directory on the host that holds `./data` | the deploy account's home, or a dedicated directory | Before you start |
| `<username>` / `<pgid>` | account that owns `./data`, and its group | the unprivileged deploy account, group `docker` | Steps 1, 2 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `<ip-address>` | DNS resolver handed to the container | the local resolver that knows the internal names | Step 3 |
| `<secret>` | Django `SECRET_KEY` | `openssl rand -base64 48`; must stay stable | Step 3 |
| `<org-name>` | watermark text stamped on served images | the attribution you want on the pictures | Step 3 |
| `gallery.your-domain.com` | the gallery's public domain | DNS record pointing at this host or at Cloudflare | Before you start, Step 3 |
| `your-domain.com` | a second name the site answers to | optional; drop `EXTRA_DOMAIN` if unused | Step 3 |
| `https://your-domain.com` | origin of the site that embeds this page in a frame | scheme and host only, no trailing slash | Step 3 |
| `<path-to-seed-db>` | directory holding an existing `db.sqlite3` | only when migrating an existing gallery | Step 2 |
| `<backup-mount>` | directory backups are written to | needs room for the database and the whole media tree | Updating & day-to-day |

---

## Verification

```bash
# container up and health check green
docker ps --filter 'name=^kaleidoscope$'
docker inspect --format '{{ .State.Health.Status }}' kaleidoscope

# the app answers on its own port with an accepted Host header
docker exec kaleidoscope wget -qO- http://kaleidoscope:8000/healthz

# an unknown Host is rejected — proves ALLOWED_HOSTS is in force
docker exec kaleidoscope wget -qO- --header 'Host: nope.invalid' http://kaleidoscope:8000/ \
  || echo "unknown host rejected: expected"

# public site answers through Traefik with a real certificate
curl -sI https://gallery.your-domain.com | head -3

# static assets are served, not 404
curl -s -o /dev/null -w '%{http_code}\n' https://gallery.your-domain.com/static/

# the media mount is writable by the application
docker exec kaleidoscope sh -c 'touch /app/media/.probe && rm /app/media/.probe && echo "media writable"'

# the database is a file, not a directory
docker exec kaleidoscope sh -c 'ls -l /app/db.sqlite3 && head -c 16 /app/db.sqlite3 | xxd | head -1'
```

A populated database shows `SQLite format 3` in the hex dump. An empty result means the file is
still zero bytes — run the migration from Step 4.

---

## Updating & day-to-day

**Update to a new image:**

```bash
docker pull nemanjaslijepcevic/kaleidoscope:latest
docker stop kaleidoscope && docker rm kaleidoscope
# re-run the docker run command from Step 3 unchanged
docker exec kaleidoscope python manage.py migrate
docker exec kaleidoscope python manage.py collectstatic --noinput
```

The database, media and static directories live on the host, so removing the container loses
nothing. Run `migrate` after every image update — a new release may ship schema changes, and the
affected pages answer 500 until they are applied.

**Back up the database and the media together:**

```bash
docker exec kaleidoscope sqlite3 /app/db.sqlite3 ".backup '/app/staticfiles/backup.sqlite3'" \
  && mv ./data/kaleidoscope/staticfiles/backup.sqlite3 <backup-mount>/kaleidoscope-$(date +%F).sqlite3

tar czf <backup-mount>/kaleidoscope-media-$(date +%F).tar.gz -C ./data/kaleidoscope media
```

SQLite's online backup command takes a consistent snapshot of a live database, including the
contents of the write-ahead log; copying the file with `cp` while the application is writing can
capture a torn page or lose recent rows. If the image has no `sqlite3` binary, stop the container
and copy `db.sqlite3` together with any `db.sqlite3-wal` sibling.

**Restore:**

```bash
docker stop kaleidoscope
cp <backup-mount>/kaleidoscope-<date>.sqlite3 ./data/kaleidoscope/db.sqlite3
tar xzf <backup-mount>/kaleidoscope-media-<date>.tar.gz -C ./data/kaleidoscope
sudo chown -R <username>:<pgid> ./data/kaleidoscope
docker start kaleidoscope
```

Stop the container first. Replacing the database under a running application leaves it holding an
open handle on the deleted inode, so it keeps serving the old data until restarted regardless.
Restore both halves from the same date, or the gallery will list images whose files are absent.

**Logs:**

```bash
docker logs --tail 100 -f kaleidoscope
```

Django and gunicorn log to stdout, which the host's log agent collects. Nothing inside the container
needs rotating.

**Routine chores:** watch `df -h <deploy-dir>` — the media directory only ever grows, and a full disk
turns SQLite writes into `database or disk is full` errors that look like corruption.

---

## Rollback / Uninstall

Stop the service but keep the gallery:

```bash
docker stop kaleidoscope && docker rm kaleidoscope
```

Remove it completely, including every uploaded image:

```bash
docker stop kaleidoscope && docker rm kaleidoscope
sudo rm -rf ./data/kaleidoscope
docker rmi nemanjaslijepcevic/kaleidoscope:latest
```

Then remove the domain from the single sign-on bypass rules and delete the DNS record. Take the
backup above first — `./data/kaleidoscope` is the only copy of both the database and the originals.

---

## Troubleshooting

**Every URL returns 500, including the front page.**
Single sign-on is down. Every router on the `https` entrypoint inherits the authentication chain, so
when Authelia cannot be reached the chain errors before the application is consulted. Check
`docker exec authelia wget -qO- http://localhost:9091/api/health`.

**Visitors are sent to a login portal.**
The domain is missing from the access-control bypass list, or a `deny` rule above it matches first.
Rules are first-match-wins, top to bottom. The second domain is the one people forget.

**`400 Bad Request` with an empty body.**
Django rejected the `Host` header — the name in the browser is not in `DEFAULT_DOMAIN`,
`EXTRA_DOMAIN` or `INTERNAL_HOSTS`. Add it and recreate the container; a restart will not do,
because these are environment variables baked in at creation.

**Container exits at startup with `unable to open database file`.**
`./data/kaleidoscope/db.sqlite3` was missing when the container was created, so Docker made a
directory at that path. `docker rm -f kaleidoscope`, `sudo rm -rf ./data/kaleidoscope/db.sqlite3`,
then redo Step 2.

**`attempt to write a readonly database`.**
The database file or its parent directory is not writable by the container's user. SQLite must be
able to create `-wal` and `-shm` files beside the database, so fix the whole directory:
`sudo chown -R <username>:<pgid> ./data/kaleidoscope`.

**Uploads fail with a 500.**
`./data/kaleidoscope/media` is not writable, or the disk is full. Test with
`docker exec kaleidoscope sh -c 'touch /app/media/.probe'` and check `df -h`.

**Gallery lists images but every thumbnail is broken.**
The database and the media directory are out of sync — usually a database restored without its
matching media tarball. Restore both from the same date.

**Images appear without a watermark.**
`IMAGE_WATERMARK_TEXT` is empty or was not passed. It is read at container creation, so set it and
recreate. Images already rendered and cached keep their old stamp until regenerated.

**CSS and JavaScript 404, pages render unstyled.**
`staticfiles` is empty. Run `docker exec kaleidoscope python manage.py collectstatic --noinput`.

**Everyone is logged out after a redeploy.**
`SECRET_KEY` changed. It signs session cookies and must be identical across container replacements.

**Health check unhealthy while the site works in a browser.**
The probe addresses the container by its own name; if the container was renamed without updating
`INTERNAL_HOSTS` and the health command, Django answers 400 to the probe. Reproduce with
`docker exec kaleidoscope wget -qO- http://kaleidoscope:8000/healthz`.
