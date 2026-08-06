# MariaDB and Adminer

## What this is

The MySQL-family side of the public web machine: one or more MariaDB 11 containers, plus Adminer —
a single-file PHP database manager — as a web UI in front of them.

Each MariaDB container is an independent, standalone server. They exist because the blog engine on
this machine speaks MySQL and nothing else; every other stateful service in the homelab uses
PostgreSQL. A blog container reaches its database over the shared `proxy` bridge network by the
database container's name, so no port is published on the host and nothing is reachable from
outside the machine.

Adminer is deployed once and can connect to any of them. It is published through the reverse proxy
and sits behind the single sign-on portal.

> **There is no replication here.** No server identifier is set, binary logging is off, and no
> source/replica relationship is configured. Every instance stands alone. A replica container did
> once exist and was removed after it was found running "healthy" for weeks holding nothing but the
> system databases — nothing had ever been wired up to feed it. If you add replication later, judge
> it by `SHOW REPLICA STATUS\G`, never by container health.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

Add yourself to the group and start a new login session if it is missing:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

**The `./data` working directory exists and you are in it**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
```

All paths below are relative to `<deploy-dir>`.

**The shared `proxy` bridge network exists**

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

Keep the fixed addresses you assign below **outside** the `--ip-range` auto-assign pool, or Docker
will eventually hand one of them to another container.

**The reverse proxy is running**

Adminer is only reachable through it.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

**The single sign-on portal is running**

Adminer's route carries the authenticating middleware chain, so a portal that is down turns Adminer
into a 500 rather than a login page.

```bash
docker ps --filter 'name=^authelia$'
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

**The Adminer name resolves to this machine**

```bash
dig +short adminer.your-domain.com
```

## Setup

### Overview

1. Create a named volume per database instance.
2. Start one MariaDB container per instance.
3. Start Adminer.

---

#### Step 1: Create a named volume per instance

```bash
docker volume create <db-volume>
docker volume inspect <db-volume> --format '{{.Mountpoint}}'
```

**Explanation**: The database's files live in a Docker named volume rather than under `./data`,
because MariaDB's data directory has to be owned by the `mysql` account inside the image and a
named volume gets that ownership set correctly on creation without anybody chowning a bind-mounted
path by hand. The trade-off is that the data is no longer next to everything else in `./data` — note
the mount point above so you know where it actually lives on disk.

Docker creates the volume implicitly on first run, but doing it explicitly means a typo in the name
produces an empty new volume you notice immediately, rather than an existing blog silently coming
up with no content.

---

#### Step 2: Start a MariaDB container per instance

Repeat once per database instance, with a different name, address and volume each time.

```bash
docker run -d \
  --name <db-container> \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=<timezone> \
  -e MARIADB_ROOT_PASSWORD='<secret>' \
  -v <db-volume>:/var/lib/mysql \
  --health-cmd 'healthcheck.sh --connect --innodb_initialized' \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 30s \
  mariadb:11 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci
```

**Explanation**:

- `--character-set-server=utf8mb4` and `--collation-server=utf8mb4_unicode_ci` are passed as server
  arguments, not environment variables, so they apply to the server itself and become the default
  every database and table inherits. `utf8mb4` is real four-byte UTF-8; MySQL's historical `utf8` is
  three-byte and silently truncates anything outside the Basic Multilingual Plane — emoji in a blog
  post, most notably. Setting this at server level and before the first start means content
  round-trips correctly instead of needing a painful conversion later.
- The health check calls `healthcheck.sh`, a script the official image ships for exactly this.
  `--connect` proves the server accepts a connection, and `--innodb_initialized` proves that startup
  and any crash recovery have finished — a server can accept connections while InnoDB is still
  replaying, and a check that only connects would call that healthy.
- `--health-start-period 30s` gives that recovery room before failures start counting. A large or
  unclean data directory can exceed it; that shows as `starting` for longer, not as a restart loop.
- No port is published. The blog containers reach the database over the `proxy` network at
  `<db-container>` or its fixed address, and nothing outside this machine can reach it at all —
  which is why a root password is the only credential involved and no TLS is configured for these
  instances.
- `MARIADB_ROOT_PASSWORD` is read **only on the first start**, when the volume is empty and the
  server is initialised. Changing it later does nothing; use `ALTER USER` inside the running server.

---

#### Step 3: Start Adminer

```bash
docker run -d \
  --name adminer \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=<timezone> \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.adminer.entrypoints=https' \
  --label 'traefik.http.routers.adminer.rule=Host(`adminer.your-domain.com`)' \
  --label 'traefik.http.routers.adminer.tls=true' \
  --label 'traefik.http.routers.adminer.middlewares=chain-auth@file' \
  --label 'traefik.http.services.adminer.loadbalancer.server.port=8080' \
  --health-cmd 'curl -fsS -o /dev/null http://127.0.0.1:8080/' \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 10s \
  adminer
```

**Explanation**:

- **`chain-auth@file` — the authenticating chain, not the IP-restricted one.** An IP-allowlist chain
  would be the obvious choice for an admin tool, and it is unusable on this machine: the container
  that keeps the home address up to date only maintains the general whitelist file, so the tunnel
  whitelist never learns the current address and the result is a 403 for everyone including you.
  Requiring a single sign-on session instead is the protection that actually works here. Do not
  switch this route to the tunnel chain without first fixing the address updater.
- The health check requests Adminer's login page on port 8080, which answers a plain 200 with no
  redirect, so the check tests the application rather than a redirect chain. The image ships `curl`,
  so no extra tooling is needed.
- Adminer holds no credentials and stores nothing: every session starts by typing a server, user and
  password into its login form. That is why it needs no volume and why losing the container costs
  nothing — but also why the single sign-on gate in front of it is the only thing standing between
  the internet and a root password prompt for every database on this machine.
- The connection from Adminer to a database goes over the `proxy` network, so the "Server" field in
  its login form takes the database container's name, not `localhost`.

---

## Restoring

Backups of these instances are one gzipped full dump per container, taken with `--single-transaction`
so InnoDB tables are consistent without the blog being locked out during the dump.

**Restore into a running server.** Stop whatever writes to it first:

```bash
docker stop <web-container>

zcat mysql_<db-container>.sql.gz \
  | docker exec -i -e MYSQL_PWD='<secret>' <db-container> mariadb -u root

docker start <web-container>
```

**Rebuild an instance from scratch** — a corrupt data directory, or a new machine:

```bash
docker stop <db-container> && docker rm <db-container>
docker volume rm <db-volume>
docker volume create <db-volume>
```

Start the container again exactly as in Step 2 — it initialises a fresh data directory with the same
root password — wait for it to report healthy, then load the dump:

```bash
until [ "$(docker inspect --format '{{.State.Health.Status}}' <db-container>)" = healthy ]; do sleep 2; done

zcat mysql_<db-container>.sql.gz \
  | docker exec -i -e MYSQL_PWD='<secret>' <db-container> mariadb -u root
```

**Explanation**: The dump is a full one — it recreates the databases, their users and their grants —
so it must be loaded as `root`, and into a server that has finished initialising. Waiting for the
health status rather than for `docker run` to return is what avoids a half-applied restore: the
`--innodb_initialized` part of the check is precisely the signal that the server is ready for bulk
writes.

`MYSQL_PWD` in the environment keeps the password out of the container's process list, where
`-p<secret>` would leave it visible to anything able to run `ps`.

Do not restore a dump taken from a newer MariaDB into an older one. Within the same major version
the reverse direction is fine.

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory |
| `<username>` / `<pgid>` | Account and group owning `./data` | The account you administer the host with |
| `<db-container>` | Name of one MariaDB container | Also the hostname the blog connects to; one per instance |
| `<db-volume>` | Named Docker volume for that instance | One per instance; never shared between two servers |
| `<docker-ip>` | Fixed address on the `proxy` network | A different one per container, outside the auto-assign pool |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy` |
| `<secret>` | MariaDB root password for that instance | Long random string, set at first start, one per instance |
| `<timezone>` | Timezone inside the containers | An IANA name such as `Europe/Berlin`; affects timestamps in logs and queries |
| `<web-container>` | The application using a database | Stopped during a restore |
| `adminer.your-domain.com` | Public name of the database UI | Must resolve to this machine |

## Verification

```bash
docker ps --filter 'name=<db-container>' --filter 'name=^adminer$' \
  --format '{{.Names}}\t{{.Status}}'
docker inspect --format '{{.State.Health.Status}}' <db-container>

# no port may be published for a database container
docker inspect --format '{{.NetworkSettings.Ports}}' <db-container>   # expect: map[]
```

Prove the server holds what you think it holds — container health says nothing about content:

```bash
docker exec -e MYSQL_PWD='<secret>' <db-container> mariadb -u root -e "SHOW DATABASES;"
docker exec -e MYSQL_PWD='<secret>' <db-container> mariadb -u root \
  -e "SELECT table_schema, COUNT(*) AS tables FROM information_schema.tables
      WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
      GROUP BY table_schema;"
```

Confirm the character set really took:

```bash
docker exec -e MYSQL_PWD='<secret>' <db-container> mariadb -u root \
  -e "SHOW VARIABLES LIKE 'character_set_server'; SHOW VARIABLES LIKE 'collation_server';"
```

And that Adminer answers, both inside and through the proxy:

```bash
docker exec adminer curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
curl -sI https://adminer.your-domain.com | head -1
```

The public request should return a redirect to the sign-on portal rather than the Adminer login page
— that is the middleware chain doing its job.

## Updating & day-to-day

**Update a database image.** The tag pins the major version, so a pull brings minor releases and the
existing data directory stays compatible; MariaDB runs any needed in-place upgrade itself on the next
start. A **major** version jump is a different operation — take a dump first, and read that release's
upgrade notes.

```bash
docker pull mariadb:11
docker stop <db-container> && docker rm <db-container>
# re-run the docker run command from Step 2 verbatim, with the same volume
```

The volume is what carries the data across; as long as you pass the same `<db-volume>`, removing and
recreating the container loses nothing.

**Update Adminer.** It is stateless, so this is risk-free:

```bash
docker pull adminer
docker stop adminer && docker rm adminer
# re-run the docker run command from Step 3
```

**Add another instance.** Repeat Steps 1 and 2 with a new name, a new volume and a new address. It is
worth checking afterwards that the new instance is picked up by whatever dumps the databases on this
machine — an instance nobody backs up is the failure you only discover during a restore.

**Change a root password.** The environment variable is inert after the first start:

```bash
docker exec -it -e MYSQL_PWD='<secret>' <db-container> \
  mariadb -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '<secret>';"
```

Then update anything that used the old one, including the container's own environment on the next
recreate.

**Logs**: `docker logs -f <db-container>` and `docker logs -f adminer`. InnoDB recovery, aborted
connections and access-denied errors all appear in the database log.

## Rollback / Uninstall

```bash
docker stop adminer && docker rm adminer
docker stop <db-container> && docker rm <db-container>
```

The data is untouched — it is in the volume, and re-running Step 2 with the same volume brings the
server back exactly as it was.

To destroy the data as well, after confirming you have a dump you can actually restore:

```bash
docker volume rm <db-volume>
```

## Troubleshooting

**The container exits immediately on first start**
Read `docker logs <db-container>`. The usual causes are an unrecognised server argument (they are
positional, after the image name), or a volume that already holds a data directory initialised with a
different root password — in which case the environment variable is ignored and the old password is
still the real one.

**Stuck in `starting` well past the 30-second start period**
InnoDB recovery is still running on a large or unclean data directory. Watch the log and let it
finish. Restarting the container mid-recovery makes it strictly worse.

**`Access denied for user 'root'@'…'`**
The password in the environment applied only at initialisation. If the volume predates the current
container, the password stored inside it is the one that counts. Change it with `ALTER USER` from a
session that does work, or rebuild the instance from a dump.

**A blog container cannot reach the database**
Confirm both are on the same network: `docker network inspect proxy`. The application must dial the
database container's name (or its fixed address), never `localhost` — inside a container that is the
container itself.

**Adminer returns 403 or redirects endlessly**
The route's middleware chain is the cause. With the authenticating chain the redirect goes to the
sign-on portal and stops there; an endless loop means the portal is not issuing a session for this
domain. A flat 403 usually means the route was switched to the IP-restricted chain, which cannot
work here — see the explanation in Step 3.

**Adminer's login form rejects a correct password**
The "Server" field must name the database container, not `localhost` and not the host machine.
Verify the credentials independently with the `docker exec … mariadb` command from the Verification
section.

**Content shows as `?` or truncates at emoji**
The affected table or database was created before the `utf8mb4` server defaults were in place. Check
with `SHOW CREATE DATABASE <name>;` and convert with `ALTER DATABASE … CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci` plus a per-table `ALTER TABLE … CONVERT TO CHARACTER SET`.

**A dump restores but the application still sees an empty database**
The dump was loaded into a different instance than the one the application connects to. With several
independent servers on the same network this is easy to do — check the application's configured
host against the container you restored into.
