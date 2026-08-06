# Ghost

## What this is

Ghost is a self-hosted publishing platform — a blog and newsletter engine with its own admin UI at
`/ghost/`. This deployment runs **one Ghost container per site** on the public-facing server, each
with its own MariaDB database, its own public domains, and its own named Docker volume for uploaded
content (images, themes, exports).

Every Ghost container:

- sits on the shared `proxy` bridge network with a fixed address,
- is published by Traefik on the `https` entrypoint, matched by a `Host()` rule,
- stores posts and settings in MariaDB (the `mysql` client driver) running in a separate container
  on the same network,
- sends transactional mail (member signups, password resets, newsletters) through Gmail SMTP on
  port 465.

This host is **on the internet**. Ports 80 and 443 are the only things exposed, both owned by
Traefik, and the public domains are proxied through Cloudflare. Every request passes
Cloudflare → Traefik (TLS termination) → the middleware chain → Ghost.

Ghost's routers carry **no middleware label of their own**, so they inherit the default chain that
the `https` entrypoint applies to every router on this host: real-client-IP recovery from the
Cloudflare headers, country geo-blocking, the IP allow list (which on this host also contains
Cloudflare's published ranges, so proxied traffic is not dropped), the CrowdSec bouncer, security
headers, a rate limit, and finally single sign-on. A public blog obviously cannot demand a login, so
**the site's public domains are explicitly bypassed in the single sign-on access-control rules**.
The intent is that `/ghost/*` — the admin area — stays behind two-factor login while the rest of the
site is open; see *Before you start* for the rule ordering that actually achieves that.

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
`<deploy-dir>` so the relative paths resolve. Ghost itself keeps its content in a **named Docker
volume** rather than under `./data`, but the neighbouring containers you inspect below do use it.

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

Note Traefik's own address on the `proxy` network — Step 3 needs it:

```bash
docker inspect -f '{{ .NetworkSettings.Networks.proxy.IPAddress }}' traefik
```

### Single sign-on (Authelia) is running, and this site is bypassed in it

Any router that carries the `chain-auth@file` middleware is forward-authenticated by Authelia. The
`https` entrypoint on this host applies that chain to **every** router by default, Ghost included,
so if Authelia is down the blog returns 500 rather than a page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

Both of the site's public names must appear in Authelia's access-control rules with
`policy: bypass`, or readers hit a login portal. Inspect the effective rules:

```bash
docker exec authelia grep -n -A30 '^access_control' /config/configuration.yml
```

The block must contain the site's domains, like this:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
      - "blog.your-domain.com"
      resources:
        - "^/ghost/.*"
      policy: two_factor
    - domain:
      - "blog.your-domain.com"
      - "www.blog.your-domain.com"
      policy: bypass
```

**Order is load-bearing.** Authelia evaluates rules top to bottom and the first match wins. A rule
that lists a domain with no `resources:` key matches *every* path on that domain — so if the
domain-wide `bypass` is written above the `/ghost/*` `two_factor` rule, the admin rule can never
fire and the admin UI is reachable from the open internet with nothing but Ghost's own login form in
front of it. Put the narrow admin rule **first**, exactly as shown.

### The site's DNS names resolve to this host

```bash
dig +short blog.your-domain.com
dig +short www.blog.your-domain.com
```

Both names must resolve to the public address of this machine, or to Cloudflare if the record is
proxied. Traefik matches on the `Host()` rule, so a name that lands on the wrong machine produces a
404 from the wrong proxy rather than an error you can read.

### The MariaDB container is up and holds an empty database for this site

Ghost will not start without a reachable MySQL-protocol database. Confirm the database container is
healthy:

```bash
docker ps --filter 'name=<db-container>'
docker exec <db-container> healthcheck.sh --connect --innodb_initialized && echo "mariadb: ok"
```

Create the database and the login Ghost will use, if they do not exist yet:

```bash
docker exec -i <db-container> mariadb -u root -p'<secret>' <<'EOF'
CREATE DATABASE IF NOT EXISTS <db-name>
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '<db-user>'@'%' IDENTIFIED BY '<db-password>';
GRANT ALL PRIVILEGES ON <db-name>.* TO '<db-user>'@'%';
FLUSH PRIVILEGES;
EOF
```

`utf8mb4` is not optional. Ghost stores post content, emoji and non-Latin titles; the older 3-byte
`utf8` character set truncates them and the failure surfaces halfway through a migration. Verify:

```bash
docker exec <db-container> mariadb -u '<db-user>' -p'<db-password>' \
  -e "SELECT @@character_set_database, @@collation_database;" <db-name>
```

### A Gmail app password for outbound mail

Ghost sends through `smtp.gmail.com:465` with a Google **app password**, not the account password —
Google rejects plain password authentication on SMTP for accounts with two-factor enabled. Generate
one in the Google account security settings and keep it for Step 3.

---

## Setup

### Overview

1. Create the named Docker volume that holds the site's content.
2. Reserve the site's fixed address on the `proxy` network.
3. Start the Ghost container with its database, mail, URL and routing settings.
4. Wait for the health check to go green and complete the owner setup in the admin UI.
5. Repeat 1–4 for every additional site.

---

#### Step 1: Create the content volume

```bash
docker volume create <volume-name>
docker volume inspect <volume-name> --format '{{ .Mountpoint }}'
```

**Explanation**: everything a Ghost site accumulates outside the database — uploaded images, the
active theme, generated member exports, the settings cache and Ghost's own log files — lives under
`/var/lib/ghost/content`. A **named volume** rather than a bind mount is deliberate: the Ghost image
runs as its own unprivileged user, and a named volume inherits the image's ownership the first time
it is mounted, whereas an empty host directory arrives owned by root and Ghost dies on its first
write with `EACCES` under `content/data`. The volume also survives `docker rm`, so recreating the
container to pick up a new image never touches the site's media.

---

#### Step 2: Reserve the site's address on the `proxy` network

```bash
docker network inspect proxy \
  --format '{{ range .Containers }}{{ .Name }} {{ .IPv4Address }}{{ "\n" }}{{ end }}'
```

Pick a free `<docker-ip>` inside `<docker-subnet>` but **outside** the automatic `--ip-range` pool,
and record it. Each site gets its own address.

**Explanation**: fixed addresses keep the routing table, the allow lists and any host firewall rules
stable across restarts. Docker's automatic pool hands out a different address after every recreate,
and anything that pinned the old one silently breaks — most visibly the self-fetch pin in the next
step, which points at Traefik's address.

---

#### Step 3: Start the Ghost container

```bash
TRAEFIK_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.proxy.IPAddress }}' traefik)

docker run -d \
  --name <container> \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --add-host "blog.your-domain.com:${TRAEFIK_IP}" \
  --add-host "www.blog.your-domain.com:${TRAEFIK_IP}" \
  -e TZ=Europe/Belgrade \
  -e database__client=mysql \
  -e database__connection__host=<db-container> \
  -e database__connection__user=<db-user> \
  -e database__connection__password='<db-password>' \
  -e database__connection__database=<db-name> \
  -e mail__transport=SMTP \
  -e mail__from='<mail-user>' \
  -e mail__options__service=Gmail \
  -e mail__options__host=smtp.gmail.com \
  -e mail__options__port=465 \
  -e mail__options__auth__user='<mail-user>' \
  -e mail__options__auth__pass='<mail-password>' \
  -e url=https://blog.your-domain.com \
  -v <volume-name>:/var/lib/ghost/content \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.<container>.entrypoints=https' \
  --label 'traefik.http.routers.<container>.rule=Host(`blog.your-domain.com`) || Host(`www.blog.your-domain.com`)' \
  --label 'traefik.http.routers.<container>.tls=true' \
  --label 'traefik.http.services.<container>.loadbalancer.server.port=2368' \
  --health-cmd "node -e \"const h=require('http');const r=h.get('http://localhost:2368/ghost/api/admin/site',s=>process.exit(s.statusCode<500?0:1));r.on('error',()=>process.exit(1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)});\"" \
  --health-interval 30s \
  --health-timeout 6s \
  --health-retries 3 \
  --health-start-period 90s \
  ghost:alpine
```

**Explanation**: Ghost has no configuration file in this setup — every setting arrives as an
environment variable using Ghost's double-underscore nesting convention, so
`database__connection__host` is the `database.connection.host` key of its config tree. `url` is the
single most important one: Ghost bakes it into every generated link, canonical tag, RSS item and
outbound email, and a wrong value produces a site that redirects visitors somewhere else. It must be
the public `https://` URL even though TLS is terminated upstream and Ghost itself only ever speaks
plain HTTP on 2368 — which is exactly why the router carries `tls=true` while the service port label
says 2368.

The two `--add-host` entries are the subtle part. While rendering a page, Ghost's image-size utility
fetches the site's **own** favicon and feature images over the public `url`. Those domains are
Cloudflare-proxied, and Cloudflare challenges requests that originate from this VPS's own datacenter
address with a 403 — so the container floods its log with `IMAGE_SIZE_URL` 403 errors while
rendering perfectly ordinary pages. Pinning the site's own domains to the local Traefik address
inside the container makes that self-fetch loop back through the local proxy and skip Cloudflare
entirely. Public inbound traffic is untouched and still flows through Cloudflare. The pin must be
computed from Traefik's live address, as done above; a hard-coded value goes stale the moment
Traefik is recreated.

Mail goes out over implicit TLS on 465, with `mail__options__service=Gmail` selecting the provider
preset and `auth__pass` holding a Google app password. Ghost only uses mail for member and staff
messages, so a broken mail configuration never stops the site from serving — it surfaces later as
invites that never arrive.

The health check probes Ghost with `node` rather than `curl` or `wget` because the Alpine-based
Ghost image ships neither, only the Node runtime the app itself uses. It targets the admin site
endpoint on localhost, and Ghost canonicalises any localhost request to its configured `https` URL,
so that endpoint answers **301** internally. Anything below 500 therefore means "Ghost answered" and
counts as healthy; only a connection error or a timeout is a real failure. The 90-second start
period covers Ghost's first-boot database migrations, which on an empty database take far longer
than an ordinary restart.

---

#### Step 4: Complete the owner setup

```bash
docker logs -f <container>
# wait for: "Your site is now available on https://blog.your-domain.com"

docker inspect --format '{{ .State.Health.Status }}' <container>
```

Then open `https://blog.your-domain.com/ghost/` in a browser and create the owner account.

**Explanation**: the owner account is created through the setup form on first visit and cannot be
created from the command line. Do this immediately after the first start — until the form is
submitted, anyone who reaches `/ghost/` can claim ownership of the site. The two-factor rule in
front of the admin path (see *Before you start*) is what protects that window, which is why its
ordering matters.

---

#### Step 5: Repeat for each additional site

Every site is a completely independent container: its own database, its own volume, its own address,
its own router name, and its own domains added to the single sign-on bypass list.

```bash
docker volume create <volume-name-2>

docker exec -i <db-container> mariadb -u root -p'<secret>' <<'EOF'
CREATE DATABASE IF NOT EXISTS <db-name-2>
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '<db-user-2>'@'%' IDENTIFIED BY '<db-password-2>';
GRANT ALL PRIVILEGES ON <db-name-2>.* TO '<db-user-2>'@'%';
FLUSH PRIVILEGES;
EOF

# then repeat Step 3 with the second site's container name, address, domains and volume
```

**Explanation**: Ghost has no multi-tenant mode — two sites in one container is not possible, and
pointing two Ghost containers at one database corrupts both, because Ghost assumes exclusive
ownership of its schema and runs migrations without coordinating. Keep the router label names unique
as well: router and service names are global in Traefik's dynamic configuration, so a duplicate name
means the second container silently replaces the first one's route.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | working directory on the host that holds `./data` | the deploy account's home, or a dedicated directory | Before you start |
| `<username>` / `<pgid>` | account that owns `./data`, and its group | the unprivileged deploy account, group `docker` | Before you start |
| `<container>` | Ghost container name; also the router and service name | one per site, e.g. `<site>-ghost`; must be unique across the host | Steps 3, 5 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Steps 2, 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `<volume-name>` | named Docker volume for `/var/lib/ghost/content` | one per site, e.g. `<site>_ghost_content` | Steps 1, 3 |
| `<db-container>` | MariaDB container name | the database container already on the `proxy` network | Before you start, Step 3 |
| `<db-name>` | database for this site | one per site | Before you start, Step 3 |
| `<db-user>` / `<db-password>` | login Ghost connects as | one per site; `openssl rand -base64 24` for the password | Before you start, Step 3 |
| `<secret>` | MariaDB root password | set when the database container was created | Before you start, Steps 5 and Rollback |
| `<mail-user>` | Gmail address mail is sent from | the mailbox that owns the app password | Step 3 |
| `<mail-password>` | Gmail **app password** | generated in Google account security settings | Step 3 |
| `blog.your-domain.com` | the site's public domain | DNS record pointing at this host or at Cloudflare | Steps 3, 4 |
| `www.blog.your-domain.com` | the `www` alias | optional; drop the router term and the matching `--add-host` if unused | Step 3 |
| `<backup-mount>` | directory backups are written to | any path with room for a database dump and a content tarball | Updating & day-to-day |

---

## Verification

```bash
# container up and health check green
docker ps --filter 'name=<container>'
docker inspect --format '{{ .State.Health.Status }}' <container>

# Ghost answers on its own port inside the network (301 is the expected code)
docker exec <container> node -e \
  "require('http').get('http://localhost:2368/ghost/api/admin/site',r=>console.log(r.statusCode))"

# the database connection really works — Ghost writes its migration table on boot
docker exec <db-container> mariadb -u '<db-user>' -p'<db-password>' <db-name> \
  -e "SELECT COUNT(*) AS migrations FROM migrations;"

# the public site answers through Traefik with a real certificate
curl -sI https://blog.your-domain.com | head -3

# the self-fetch pin resolves to the local proxy, not to Cloudflare
docker exec <container> getent hosts blog.your-domain.com

# the admin area sends you to the single sign-on portal rather than Ghost's own form
curl -sI https://blog.your-domain.com/ghost/ | grep -i '^location'
```

If the last command prints nothing and the request returns 200, the admin path is **not** protected
by two-factor login — fix the access-control rule ordering shown in *Before you start*.

---

## Updating & day-to-day

**Update to a new Ghost release:**

```bash
docker pull ghost:alpine
docker stop <container> && docker rm <container>
# re-run the docker run command from Step 3 unchanged
docker logs -f <container>
```

The content volume and the database are untouched by this; Ghost applies any pending schema
migrations on the first boot of the new version, which is why that first start takes a minute or
two. Do not skip a major version — Ghost's migrations are only supported from the immediately
preceding major release.

**Back a site up before upgrading:**

```bash
docker exec <db-container> mariadb-dump --single-transaction --quick \
  -u root -p'<secret>' <db-name> > <backup-mount>/<db-name>-$(date +%F).sql

docker run --rm -v <volume-name>:/content -v <backup-mount>:/backup alpine \
  tar czf /backup/<volume-name>-$(date +%F).tar.gz -C /content .
```

`--single-transaction` takes the dump inside one consistent InnoDB snapshot without locking tables,
so the site keeps serving while the dump runs.

**Restore a site:**

```bash
docker stop <container>
docker exec -i <db-container> mariadb -u root -p'<secret>' <db-name> < <backup-mount>/<db-name>-<date>.sql
docker run --rm -v <volume-name>:/content -v <backup-mount>:/backup alpine \
  sh -c 'rm -rf /content/* && tar xzf /backup/<volume-name>-<date>.tar.gz -C /content'
docker start <container>
```

Stop Ghost first: restoring under a running Ghost leaves its in-memory settings cache pointing at
rows that no longer exist.

**Logs:**

```bash
docker logs --tail 100 -f <container>                    # boot, migrations, mail errors
docker exec <container> ls /var/lib/ghost/content/logs   # Ghost's own rotating JSON logs
```

Ghost writes structured logs into the content volume as well as to stdout. The stdout stream is what
the host's log agent collects; the files inside the volume grow slowly and Ghost rotates them itself.

**Routine chores:** check the health status after every restart, and send a test newsletter from the
admin UI after any change to the Google account — app passwords are revoked whenever the account's
two-factor setup changes.

---

## Rollback / Uninstall

Remove one site but keep its data:

```bash
docker stop <container> && docker rm <container>
```

Remove one site completely, including every post and upload:

```bash
docker stop <container> && docker rm <container>
docker volume rm <volume-name>
docker exec -i <db-container> mariadb -u root -p'<secret>' <<'EOF'
DROP DATABASE IF EXISTS <db-name>;
DROP USER IF EXISTS '<db-user>'@'%';
EOF
```

Then remove the site's domains from the single sign-on access-control rules and delete the DNS
records. `docker volume rm` is irreversible — take the tarball backup above first.

---

## Troubleshooting

**Every URL returns 500, including the front page.**
Single sign-on is down. Every router on the `https` entrypoint inherits the authentication chain, so
when Authelia cannot be reached the chain errors before Ghost is ever consulted. Check
`docker exec authelia wget -qO- http://localhost:9091/api/health` and restart Authelia.

**Visitors are asked to log in before they can read a post.**
The site's domain is missing from the access-control bypass list, or a `deny` rule above it matches
first. Rules are first-match-wins, top to bottom.

**The admin UI opens without a two-factor prompt.**
A domain-wide `bypass` rule sits above the `/ghost/*` rule and shadows it. Move the `/ghost/*`
`two_factor` rule above the bypass and restart Authelia.

**The log fills with `IMAGE_SIZE_URL` 403 errors.**
The container is resolving its own public domain through Cloudflare, which is challenging the
request because it comes from this server's own datacenter address. Confirm with
`docker exec <container> getent hosts blog.your-domain.com` — it must return Traefik's address on
the `proxy` network. Recreate the container with the `--add-host` entries from Step 3; the pin is
stale if Traefik was recreated after Ghost.

**Container restart-loops with `ER_ACCESS_DENIED_ERROR` or `ECONNREFUSED`.**
The database is unreachable or the credentials are wrong. Ghost resolves `<db-container>` by
container name, which only works while both containers are on the `proxy` network — check with
`docker inspect -f '{{ json .NetworkSettings.Networks }}' <container>`. Test the login directly:
`docker exec <db-container> mariadb -u '<db-user>' -p'<db-password>' -e 'SELECT 1' <db-name>`.

**Health check stuck at `starting` for several minutes on a fresh install.**
Normal on an empty database — the initial migration set is large. Watch `docker logs -f <container>`;
if migration lines are still appearing, wait. If the log is silent and the check keeps failing, run
the probe by hand:
`docker exec <container> node -e "require('http').get('http://localhost:2368/ghost/api/admin/site',r=>console.log(r.statusCode))"`.

**Health check says unhealthy but the site works in a browser.**
The probe accepts anything below 500, so an unhealthy verdict means Ghost did not answer at all —
typically out of memory during a migration, or a crash after the port was already bound.
`docker inspect --format '{{ json .State.Health }}' <container> | jq` shows the last probe outputs.

**Images 404 after moving the site to another host.**
The content volume did not travel with it. Restore it from the tarball:
`docker run --rm -v <volume-name>:/content -v <backup-mount>:/backup alpine tar xzf /backup/<volume-name>-<date>.tar.gz -C /content`.

**Member emails never arrive.**
Google revoked the app password, or the mailbox hit its daily send limit; `docker logs <container>`
shows the SMTP rejection verbatim. Generate a new app password and recreate the container with the
new `mail__options__auth__pass`.

**A second site's route disappeared from Traefik.**
Two containers used the same name in their `traefik.http.routers.<name>` labels. Router names are
global; the last container to register wins. Rename and recreate.

**`docker run` fails with `Address already in use` for the fixed address.**
Another container already holds `<docker-ip>`, or Docker's automatic pool handed it out. Re-check
the address list from Step 2 and pick one outside the pool.
