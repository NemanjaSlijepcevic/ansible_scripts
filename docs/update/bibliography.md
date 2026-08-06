# Bibliography

## What this is

Bibliography is a small self-hosted Django web application that catalogues a book collection — a
searchable library index with cover images and per-title detail pages. It runs as a single container
on the public-facing server, serves HTTP with gunicorn on port 8000 inside the container, and keeps
all of its data in one SQLite file bind-mounted from the host.

It talks to nothing else. There is no external database, no cache, no message queue: the container,
its SQLite file, and its collected static assets are the whole system. It is published to the
internet by Traefik, which terminates TLS and matches the request by `Host()`.

This host is **on the internet**. Ports 80 and 443 are the only things exposed, both owned by
Traefik, and the public domain is proxied through Cloudflare. Every request passes
Cloudflare → Traefik (TLS termination) → the middleware chain → gunicorn.

The container's router carries **no middleware label of its own**, so it inherits the default chain
that the `https` entrypoint applies to every router on this host: real-client-IP recovery from the
Cloudflare headers, country geo-blocking, the IP allow list (which on this host also contains
Cloudflare's published ranges so proxied traffic is not dropped), the CrowdSec bouncer, security
headers, a rate limit, and finally single sign-on. Because this is a public catalogue that anyone
should be able to browse, **its domain is explicitly bypassed in the single sign-on access-control
rules** — otherwise every visitor would be shown a login portal. The application has no user
accounts of its own; treat everything it serves as public.

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
included, so if Authelia is down the catalogue returns 500 rather than a page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

The catalogue's domain must appear in Authelia's access-control rules with `policy: bypass`:

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
      - "books.your-domain.com"
      policy: bypass
```

If you also publish the site under a second name, that name needs its own bypass entry — the
application accepting a hostname is not the same thing as the sign-on layer allowing it.

### The site's DNS name resolves to this host

```bash
dig +short books.your-domain.com
```

The name must resolve to the public address of this machine, or to Cloudflare if the record is
proxied. Traefik matches on the `Host()` rule, so a name that lands on the wrong machine produces a
404 from the wrong proxy rather than an error you can read.

### You have a Django secret key and, if you are migrating, the existing database

Generate a fresh key if this is a new installation:

```bash
openssl rand -base64 48
```

If you are moving an existing catalogue to this host, copy its `db.sqlite3` here first — Step 2
seeds from it and refuses to overwrite a database that already exists.

---

## Setup

### Overview

1. Create the data directories.
2. Put the SQLite database in place (seed an existing one, or start empty).
3. Start the container.
4. Collect static files and confirm the health check.

---

#### Step 1: Create the data directories

```bash
mkdir -p ./data/bibliography/staticfiles
sudo chown -R <username>:<pgid> ./data/bibliography
sudo chmod 0755 ./data/bibliography ./data/bibliography/staticfiles
```

**Explanation**: two paths are bind-mounted into the container — the SQLite database file itself and
the directory Django writes its collected CSS and JavaScript into. They are kept on the host rather
than inside the image so that a container replacement (an image update, a configuration change)
never destroys the catalogue. Ownership must match the account that runs Docker here; the
application process inside the container writes to both paths, and a root-owned directory produces a
500 on the first write with no useful message in the browser.

---

#### Step 2: Put the SQLite database in place

If you already have a database file, copy it in — **never overwrite an existing one**:

```bash
if [ ! -f ./data/bibliography/db.sqlite3 ]; then
  cp <path-to-seed-db>/db.sqlite3 ./data/bibliography/db.sqlite3
  sudo chown <username>:<pgid> ./data/bibliography/db.sqlite3
  sudo chmod 0644 ./data/bibliography/db.sqlite3
fi
```

If this is a brand-new installation with no data to carry over, create the file empty and let Django
build the schema in Step 4:

```bash
[ -f ./data/bibliography/db.sqlite3 ] || : > ./data/bibliography/db.sqlite3
sudo chown <username>:<pgid> ./data/bibliography/db.sqlite3
sudo chmod 0644 ./data/bibliography/db.sqlite3
```

**Explanation**: the guard is the whole point of this step. The database is bind-mounted as a
**single file**, and Docker creates a *directory* at that path if the file does not exist — which
makes the application fail at startup with `unable to open database file` and is confusing to
diagnose. Equally, an unconditional copy on redeploy would silently replace a live catalogue with a
stale seed, so the existence check is not a convenience but a safety interlock. Keep the file mode
at `0644`: SQLite also creates `-wal` and `-shm` siblings in the same directory during writes, so
the *directory* must stay writable by the same owner, not just the file.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name bibliography \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <ip-address> \
  -e TZ=Europe/Belgrade \
  -e DEFAULT_DOMAIN=books.your-domain.com \
  -e EXTRA_DOMAIN=library.your-domain.com \
  -e INTERNAL_HOSTS=bibliography \
  -e SECRET_KEY='<secret>' \
  -v "$(pwd)/data/bibliography/db.sqlite3:/app/db.sqlite3" \
  -v "$(pwd)/data/bibliography/staticfiles:/app/staticfiles" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.bibliography.entrypoints=https' \
  --label 'traefik.http.routers.bibliography.rule=Host(`books.your-domain.com`)' \
  --label 'traefik.http.routers.bibliography.tls=true' \
  --label 'traefik.http.services.bibliography.loadbalancer.server.port=8000' \
  --health-cmd 'wget -q --spider http://bibliography:8000/healthz' \
  --health-interval 30s \
  --health-timeout 6s \
  --health-retries 3 \
  --health-start-period 20s \
  nemanjaslijepcevic/bibliography:latest
```

**Explanation**: `DEFAULT_DOMAIN`, `EXTRA_DOMAIN` and `INTERNAL_HOSTS` all end up in Django's
`ALLOWED_HOSTS`. Django compares the incoming `Host` header against that list and answers **400 Bad
Request** for anything not on it — a deliberate defence against host-header poisoning of generated
links and password-reset URLs. `DEFAULT_DOMAIN` is the canonical public name, `EXTRA_DOMAIN` is any
additional name the site answers to, and `INTERNAL_HOSTS` is the container's own name so that
requests arriving over the internal network — Traefik's, and the health check's — are accepted too.

That is also why the health check probes `http://bibliography:8000/healthz` by container name rather
than `http://localhost:8000/`. A probe to `localhost` sends `Host: localhost`, which is not in
`ALLOWED_HOSTS`, so Django would answer 400 and the container would be marked unhealthy while
serving the public site perfectly. Docker's embedded DNS on a user-defined network resolves a
container's own name from inside itself, so the container-name probe works with no extra
configuration. `--spider` makes `wget` issue the request and discard the body, and a non-2xx status
makes it exit non-zero, which is exactly the signal the health check wants.

`SECRET_KEY` signs session cookies and any signed URL the application generates. Changing it
invalidates every existing session; leaking it lets someone forge them. `--dns <ip-address>` points
the container at the local resolver so the site's own names resolve internally rather than through
whatever DNS the Docker daemon inherited. TLS is terminated at Traefik, so gunicorn only ever speaks
plain HTTP on 8000, which is what the service port label advertises while the router carries
`tls=true`.

---

#### Step 4: Initialise the schema and collect static files

On a **new, empty** database, build the schema and create an administrator:

```bash
docker exec -it bibliography python manage.py migrate
docker exec -it bibliography python manage.py createsuperuser
```

Then, on any installation, make sure the static assets are on disk:

```bash
docker exec bibliography python manage.py collectstatic --noinput
ls ./data/bibliography/staticfiles | head
docker inspect --format '{{ .State.Health.Status }}' bibliography
```

**Explanation**: `migrate` is safe to run on an already-populated database — it applies only the
migrations that are missing — but it is required on an empty one, where the application otherwise
answers 500 with `no such table`. `collectstatic` copies the CSS and JavaScript out of the image
into the bind-mounted `staticfiles` directory, where the application serves them from; the image
normally does this at startup, but running it explicitly is how you confirm the directory is
writable, and it is what you re-run after an image update that ships new assets. The health status
should reach `healthy` within about a minute of the container starting.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | working directory on the host that holds `./data` | the deploy account's home, or a dedicated directory | Before you start |
| `<username>` / `<pgid>` | account that owns `./data`, and its group | the unprivileged deploy account, group `docker` | Steps 1, 2 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `<ip-address>` | DNS resolver handed to the container | the local resolver that knows the internal names | Step 3 |
| `<secret>` | Django `SECRET_KEY` | `openssl rand -base64 48`; store it somewhere you can retrieve | Step 3 |
| `books.your-domain.com` | the catalogue's public domain | DNS record pointing at this host or at Cloudflare | Before you start, Step 3 |
| `library.your-domain.com` | a second name the site answers to | optional; drop `EXTRA_DOMAIN` if unused | Step 3 |
| `<path-to-seed-db>` | directory holding an existing `db.sqlite3` | only when migrating an existing catalogue | Step 2 |
| `<backup-mount>` | directory backups are written to | any path with room for a copy of the database | Updating & day-to-day |

---

## Verification

```bash
# container up and health check green
docker ps --filter 'name=^bibliography$'
docker inspect --format '{{ .State.Health.Status }}' bibliography

# the app answers on its own port with an accepted Host header
docker exec bibliography wget -qO- http://bibliography:8000/healthz

# a request with an unknown Host is rejected — this proves ALLOWED_HOSTS is doing its job
docker exec bibliography wget -qO- --header 'Host: nope.invalid' http://bibliography:8000/ \
  || echo "unknown host rejected: expected"

# public site answers through Traefik with a real certificate
curl -sI https://books.your-domain.com | head -3

# static assets are served, not 404
curl -s -o /dev/null -w '%{http_code}\n' https://books.your-domain.com/static/

# the database is a file, not a directory, and is readable by the container
docker exec bibliography sh -c 'ls -l /app/db.sqlite3 && head -c 16 /app/db.sqlite3 | xxd | head -1'
```

The last command should show `SQLite format 3` in the hex dump of a populated database. An empty
output means the file is still zero bytes — run the migration in Step 4.

---

## Updating & day-to-day

**Update to a new image:**

```bash
docker pull nemanjaslijepcevic/bibliography:latest
docker stop bibliography && docker rm bibliography
# re-run the docker run command from Step 3 unchanged
docker exec bibliography python manage.py migrate
docker exec bibliography python manage.py collectstatic --noinput
```

The database and the static directory live on the host, so removing the container loses nothing.
Run `migrate` after every image update: a new release may ship schema changes, and the application
will answer 500 on the affected pages until they are applied.

**Back up the database:**

```bash
docker exec bibliography sqlite3 /app/db.sqlite3 ".backup '/app/staticfiles/backup.sqlite3'" \
  && mv ./data/bibliography/staticfiles/backup.sqlite3 <backup-mount>/bibliography-$(date +%F).sqlite3
```

Use SQLite's online backup command rather than `cp`. Copying the file while the application is
writing can capture a torn page or miss the contents of the write-ahead log, producing a backup that
opens but is missing recent rows. If `sqlite3` is not present in the image, stop the container first
and then copy the file, plus any `db.sqlite3-wal` sibling.

**Restore the database:**

```bash
docker stop bibliography
cp <backup-mount>/bibliography-<date>.sqlite3 ./data/bibliography/db.sqlite3
sudo chown <username>:<pgid> ./data/bibliography/db.sqlite3
docker start bibliography
```

Stop the container first — replacing the file underneath a running application leaves open file
handles pointing at the deleted inode, so the site keeps serving the old data until it is restarted
anyway.

**Logs:**

```bash
docker logs --tail 100 -f bibliography
```

Django and gunicorn both log to stdout, which is what the host's log agent collects. There are no
log files inside the container to rotate.

---

## Rollback / Uninstall

Stop the service but keep the catalogue:

```bash
docker stop bibliography && docker rm bibliography
```

Remove it completely, including all data:

```bash
docker stop bibliography && docker rm bibliography
sudo rm -rf ./data/bibliography
docker rmi nemanjaslijepcevic/bibliography:latest
```

Then remove the domain from the single sign-on bypass rules and delete the DNS record. Take a backup
first — `./data/bibliography/db.sqlite3` is the only copy of the catalogue.

---

## Troubleshooting

**Every URL returns 500, including the front page.**
Single sign-on is down. Every router on the `https` entrypoint inherits the authentication chain, so
when Authelia cannot be reached the chain errors before the application is consulted. Check
`docker exec authelia wget -qO- http://localhost:9091/api/health`.

**Visitors are sent to a login portal.**
The domain is missing from the access-control bypass list, or a `deny` rule above it matches first.
Rules are first-match-wins, top to bottom.

**`400 Bad Request` with an empty body.**
Django rejected the `Host` header. The name in the browser is not in `DEFAULT_DOMAIN`,
`EXTRA_DOMAIN` or `INTERNAL_HOSTS`. Add it and recreate the container; a restart is not enough
because the values are environment variables.

**Container starts, then exits with `unable to open database file`.**
`./data/bibliography/db.sqlite3` does not exist as a file, so Docker created a directory at that
path. Remove it and redo Step 2:
`docker rm -f bibliography && sudo rm -rf ./data/bibliography/db.sqlite3` then re-create the file.

**`attempt to write a readonly database` on any page that saves.**
The file or its parent directory is not writable by the container's user. SQLite needs to create
`-wal` and `-shm` files next to the database, so the *directory* permissions matter as much as the
file's: `sudo chown -R <username>:<pgid> ./data/bibliography`.

**Health check unhealthy while the site works in a browser.**
The probe targets the container by its own name; if you renamed the container without updating
`INTERNAL_HOSTS` and the health command, Django answers 400 to the probe. Run it by hand:
`docker exec bibliography wget -qO- http://bibliography:8000/healthz`.

**CSS and JavaScript 404 while pages render as plain text.**
`staticfiles` is empty or unreadable. Run
`docker exec bibliography python manage.py collectstatic --noinput` and check
`ls ./data/bibliography/staticfiles`.

**Everyone is logged out after a redeploy.**
`SECRET_KEY` changed. It signs session cookies; keep the same value across container replacements.

**The catalogue reverted to old contents after a redeploy.**
The seed copy in Step 2 ran without its existence guard and overwrote the live database. Restore
from the most recent backup, and never run the copy unconditionally.
