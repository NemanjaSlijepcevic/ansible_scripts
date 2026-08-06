# PostgreSQL (central database server)

## What this is

PostgreSQL is the shared backing store for this homelab. One container — `postgres-db`, built from
the `pgvector/pgvector:pg18` image (PostgreSQL 18 with the `pgvector` extension compiled in) — runs
on the dedicated database machine and holds the databases of almost everything else: the single
sign-on portal's sessions and TOTP secrets, the media indexers and their log databases, the request
front-end, the workflow engine. Nothing else in the stack keeps a server-side database of its own,
with one exception: the intrusion-detection agent uses a bundled SQLite file and never touches this
server.

The machine also acts as the **certificate authority** for database traffic. Every application that
connects presents a client certificate signed here, whose Common Name equals the database login role
it authenticates as. The server refuses anything else: `pg_hba.conf` demands
`cert clientcert=verify-full` for every non-loopback address range. The one client without a
certificate is the pgAdmin web UI, which gets a narrow TLS-plus-password exception.

The container sits on the shared `proxy` bridge network at a fixed address with the network alias
`postgres`, so containers on the same machine reach it as `postgres:5432`. Port `5432` is also
published on the host, because clients on other machines (media stack, monitoring agents, the
automation host) connect across the LAN.

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

**The `./data` working directory exists and you are in it**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every path below is relative to `<deploy-dir>`. Run all commands from there.

**The shared `proxy` bridge network exists**

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name.

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
**outside** that pool so nothing is ever assigned an address you have reserved. Note the subnet and
the gateway — both go into `pg_hba.conf` in Step 6:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

**`openssl` is available**

All certificate material is produced on this machine with plain `openssl`; nothing is downloaded and
no public CA is involved.

```bash
openssl version
```

**You know which machines will connect**

You need, before you write `pg_hba.conf`: the LAN subnets (in CIDR form) that application hosts sit
on, the `proxy` subnet and gateway from above, and the fixed address you have reserved for pgAdmin.

## Setup

### Overview

1. Create the data and certificate directories.
2. Create the certificate authority.
3. Issue the server certificate.
4. Issue one client certificate per application, with the Common Name set to its database login role.
5. Copy the CA certificate and each client's certificate and key to the machine that runs it.
6. Write `pg_hba.conf`.
7. Start the container.
8. Wait for it to accept connections.

---

#### Step 1: Create the data and certificate directories

```bash
mkdir -p ./data/postgres/certs/clients
sudo chown <username>:<pgid> ./data/postgres ./data/postgres/certs ./data/postgres/certs/clients
sudo chmod 0750 ./data/postgres ./data/postgres/certs ./data/postgres/certs/clients
```

**Explanation**: `./data/postgres` holds three separate things — the live database cluster under
`data/`, the authentication file `pg_hba.conf`, and all certificate material under `certs/`. Mode
`0750` keeps the private keys out of reach of other unprivileged accounts on the machine while the
deploy account's group can still read them. The `clients/` sub-directory is the archive of issued
client material; the copies that applications actually use live on their own machines.

---

#### Step 2: Create the certificate authority

```bash
openssl genrsa -out ./data/postgres/certs/ca.key 4096

openssl req -x509 -new -nodes \
  -key ./data/postgres/certs/ca.key \
  -sha256 -days 3650 \
  -subj "/CN=postgres-ca" \
  -out ./data/postgres/certs/ca.crt

sudo chown <username>:<pgid> ./data/postgres/certs/ca.key
sudo chmod 0600 ./data/postgres/certs/ca.key
```

Create the serial file the client-signing step consumes, once:

```bash
[ -f ./data/postgres/certs/ca.srl ] || printf '01\n' | sudo tee ./data/postgres/certs/ca.srl >/dev/null
sudo chown root:root ./data/postgres/certs/ca.srl
sudo chmod 0600 ./data/postgres/certs/ca.srl
```

**Explanation**: This one private CA signs both the server's certificate and every client
certificate, which is what makes mutual authentication possible: the server trusts a client because
the client's certificate chains to this CA, and the client trusts the server for the same reason.
`-nodes` leaves the CA key without a passphrase, because signing happens unattended; the key's file
mode is the only thing protecting it, so never copy `ca.key` off this machine. `CN=postgres-ca` is
a label only — it does not have to resolve to anything. Ten years of validity (`-days 3650`) is
deliberate: a database CA that expires takes every service in the stack down at once, and there is
no automated renewal here. The serial file keeps each issued client certificate's serial number
unique; without it two certificates could share a serial and revocation bookkeeping becomes
ambiguous.

---

#### Step 3: Issue the server certificate

```bash
openssl genrsa -out ./data/postgres/certs/server.key 2048

sudo tee ./data/postgres/certs/server_ext.cnf >/dev/null <<'EOF'
[v3_req]
subjectAltName = IP:<ip-address>,DNS:localhost
EOF
sudo chmod 0600 ./data/postgres/certs/server_ext.cnf

openssl req -new \
  -key ./data/postgres/certs/server.key \
  -subj "/CN=<ip-address>" \
  -out ./data/postgres/certs/server.csr

openssl x509 -req \
  -in ./data/postgres/certs/server.csr \
  -CA ./data/postgres/certs/ca.crt -CAkey ./data/postgres/certs/ca.key -CAcreateserial \
  -out ./data/postgres/certs/server.crt -days 3650 -sha256 \
  -extfile ./data/postgres/certs/server_ext.cnf -extensions v3_req
```

Then set the ownership the container needs:

```bash
sudo chown 999:999 ./data/postgres/certs/server.key
sudo chmod 0600 ./data/postgres/certs/server.key

sudo chown root:root ./data/postgres/certs/server.crt
sudo chmod 0644 ./data/postgres/certs/server.crt
```

**Explanation**: `<ip-address>` is the address clients dial this machine on. A modern TLS client
ignores the Common Name and checks the Subject Alternative Name, so the SAN block is what actually
makes `sslmode=verify-full` work — the CN is duplicated there for the address, and `DNS:localhost`
is added so `psql` run on this machine against `localhost` also verifies. Add extra `IP:`/`DNS:`
entries here if clients reach the server by another name; a name absent from the SAN fails
verification even though the certificate is otherwise valid.

The server key is owned by uid/gid `999` and readable by nobody else because that is the `postgres`
account **inside** the image, and PostgreSQL refuses to start if its key file is group- or
world-readable. The certificate is public material and stays world-readable so that ordinary tools
can inspect it.

---

#### Step 4: Issue one client certificate per application

Do this once for every application that will connect. Two names matter and they are usually
different: the *file name*, which identifies the application, and the **Common Name**, which must be
the exact PostgreSQL login role the application authenticates as.

```bash
CLIENT=<service>          # file name, e.g. the application's own name
DB_USER=<db-username>     # the PostgreSQL login role it connects as

openssl genrsa -out ./data/postgres/certs/clients/${CLIENT}.key 2048

openssl req -new \
  -key ./data/postgres/certs/clients/${CLIENT}.key \
  -subj "/CN=${DB_USER}" \
  -out ./data/postgres/certs/clients/${CLIENT}.csr

openssl x509 -req \
  -in ./data/postgres/certs/clients/${CLIENT}.csr \
  -CA ./data/postgres/certs/ca.crt -CAkey ./data/postgres/certs/ca.key \
  -CAserial ./data/postgres/certs/ca.srl \
  -out ./data/postgres/certs/clients/${CLIENT}.crt -days 3650 -sha256

sudo chown root:root ./data/postgres/certs/clients/${CLIENT}.key
sudo chmod 0600 ./data/postgres/certs/clients/${CLIENT}.key
sudo chown root:root ./data/postgres/certs/clients/${CLIENT}.crt
sudo chmod 0644 ./data/postgres/certs/clients/${CLIENT}.crt
```

Check what you produced before you ship it:

```bash
openssl x509 -in ./data/postgres/certs/clients/${CLIENT}.crt -noout -subject -dates
openssl verify -CAfile ./data/postgres/certs/ca.crt ./data/postgres/certs/clients/${CLIENT}.crt
```

**Explanation**: `clientcert=verify-full` in Step 6 makes PostgreSQL compare the certificate's Common
Name with the user name in the connection string and reject the connection when they differ. That is
the whole point of the scheme — a stolen password is useless without the matching key, and a stolen
key can only ever log in as the one role it was issued for. Several applications may share one login
role (the media stack does), in which case each still gets its own key file but they all carry the
same CN.

Issuing is per-file: re-running these commands for a client that already has a key would mint a new
key and invalidate the copies already distributed, so only ever run this block for a client that has
no `.key` yet, or when you are deliberately rotating that one client (Step 5 then has to be repeated
for it).

---

#### Step 5: Distribute the CA certificate and the client material

Each application machine needs three files in its own `./data/certs` directory: the CA certificate,
its client certificate, and its client key.

```bash
ssh <username>@<target-host> "mkdir -p ./data/certs && chmod 0755 ./data/certs"

scp ./data/postgres/certs/ca.crt                  <username>@<target-host>:./data/certs/ca.crt
scp ./data/postgres/certs/clients/${CLIENT}.crt   <username>@<target-host>:./data/certs/${CLIENT}.crt
scp ./data/postgres/certs/clients/${CLIENT}.key   <username>@<target-host>:./data/certs/${CLIENT}.key

ssh <username>@<target-host> "sudo chmod 0644 ./data/certs/ca.crt ./data/certs/${CLIENT}.crt && \
  sudo chown root:<pgid> ./data/certs/${CLIENT}.key && sudo chmod 0640 ./data/certs/${CLIENT}.key"
```

**Explanation**: `./data/certs` is a single shared directory per machine, mounted read-only into
every container that needs it (typically at `/postgres-certs`), so one bind mount serves all the
applications on that host. The key is `root:<pgid>` mode `0640` rather than world-readable because
`<pgid>` — the group id the database image runs as — happens to be the group most consuming
containers also run as, so group-read is exactly enough.

Some containers run as their own uid and read the key as that user instead. For those, set the
owner, group and modes to match the container's account when you copy the files. Getting this wrong
is not fatal but is annoying in a specific way: the application will chown the files back to itself
on every start, so the files flip ownership forever and nothing ever settles.

A single client's material may go to more than one machine (a service with a standby, or two
services sharing a login role). Copy the same `.crt`/`.key` pair to each; do not issue a second
certificate for the same CN unless you want two independently revocable identities.

> **Do not send this CA to a machine that runs its own database server.** A machine that operates
> its own PostgreSQL instance also writes `./data/certs/ca.crt` — with a *different* CA that happens
> to carry the same subject, `CN=postgres-ca`. Whichever copy lands last wins, and the failure shows
> up in a client as `x509: certificate signed by unknown authority … candidate authority certificate
> "postgres-ca"`, which reads like a corruption problem rather than a collision. Keep the two sets of
> consumers disjoint.

---

#### Step 6: Write `pg_hba.conf`

This file is the entire access policy. Order is significant.

```bash
sudo tee ./data/postgres/pg_hba.conf >/dev/null <<'EOF'
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
# pgAdmin is the only client without a client certificate (CA-only trust) -
# TLS + password. It reaches postgres via the host IP, so its connections
# hairpin through the docker gateway NAT as well as its own static IP.
hostssl all       all   <pgadmin-docker-ip>/32   scram-sha-256
hostssl all       all   <docker-gateway>/32   scram-sha-256
# Everything else: SSL + client certificate required. pg_hba is first-match-
# wins top to bottom, so these broad lines must stay BELOW the pgAdmin
# exceptions and no broad password line may sit above them.
hostssl all       all   <lan-subnet>   cert clientcert=verify-full
hostssl all       all   <other-private-subnet>   cert clientcert=verify-full
hostssl all       all   <single-host-ip>/32   cert clientcert=verify-full
hostssl all       all   <docker-subnet>   cert clientcert=verify-full
EOF
sudo chown <username>:<pgid> ./data/postgres/pg_hba.conf
sudo chmod 0644 ./data/postgres/pg_hba.conf
```

Write one `hostssl … cert clientcert=verify-full` line per private subnet that application machines
live on, then one final line for the `proxy` subnet you noted earlier.

**Explanation**: PostgreSQL walks this file **top to bottom and stops at the first line whose
connection type, database, user and address all match**. It does not keep looking for a better
match, and a rejected authentication on the matched line is a rejected connection — not a fall
through to the next line. Everything about the ordering follows from that:

- `local … trust` covers the Unix socket inside the container. It never leaves the container's
  namespace, so there is nothing to authenticate against; this is also what lets `docker exec
  postgres-db psql -U <admin-user>` and the nightly dumps work without a password or a certificate.
- `127.0.0.1/32` covers loopback inside the container, password only, for the same reason.
- The two `scram-sha-256` lines are the pgAdmin exception, and they are deliberately as narrow as a
  line can be — one address each, `/32`. pgAdmin is a browser UI with no way to hold a client key
  per logged-in operator, so it authenticates with TLS plus the database password and verifies the
  server against the CA. Two addresses are needed because pgAdmin may arrive from either its own
  fixed address on the bridge network, or, when it is pointed at the host's LAN address instead of
  the container alias, from the bridge gateway after the connection hairpins out of the host and
  back in through Docker's NAT.
- The broad `cert clientcert=verify-full` lines come last. If any password-authenticated line with a
  wide address range sat above them, every connection from that range would match the password line
  first and the certificate requirement below would be unreachable — the policy would look enforced
  in the file and be off in practice. An earlier revision of this file had exactly that bug with a
  broad `172.0.0.0/8` password line; do not reintroduce one.

> **Every address needs a prefix length.** PostgreSQL reads the address field three ways: with a `/`
> it is CIDR and the next token is the method; a **bare** numeric address means the next token must
> be a separate netmask (the legacy `address netmask method` form); a non-numeric token (`all`,
> `samenet`, a hostname) means the next token is the method. So a single host written without `/32`
> makes the parser read the following `cert` as a netmask and the server refuses to start:
>
> ```
> LOG:  invalid IP mask "cert": Name or service not known
> FATAL:  could not load /etc/postgresql/pg_hba.conf
> ```
>
> This bites when the same list of private addresses is also used for the reverse proxy's and the
> intrusion-detection agent's whitelists, which accept bare addresses happily. Always append `/32` to
> single hosts here.

> **Overwrite this file in place.** The container bind-mounts it as a single file, and a single-file
> bind mount follows the *inode* that existed when the container started. Rewriting the file with an
> editor or `mv` creates a new inode and silently detaches the mount: the running server keeps
> serving the old rules no matter how many times you reload. `sudo tee` (as above) truncates and
> rewrites in place, which keeps the inode and the mount intact.

There is **no `postgresql.conf` to write.** Every setting this deployment changes is passed on the
command line in the next step, so the image's built-in configuration file stays untouched and there
is one less file to keep in sync.

---

#### Step 7: Start the container

```bash
docker run -d \
  --name postgres-db \
  --restart unless-stopped \
  --stop-signal SIGINT \
  --stop-timeout 90 \
  --network proxy \
  --ip <docker-ip> \
  --network-alias postgres \
  -p 5432:5432 \
  -e POSTGRES_USER='<admin-user>' \
  -e POSTGRES_PASSWORD='<secret>' \
  -e POSTGRES_DB=postgres \
  -e PGDATA=/var/lib/postgresql/data \
  -v "$(pwd)/data/postgres/data:/var/lib/postgresql/data" \
  -v "$(pwd)/data/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
  -v "$(pwd)/data/postgres/certs/server.crt:/certs/server.crt:ro" \
  -v "$(pwd)/data/postgres/certs/server.key:/certs/server.key:ro" \
  -v "$(pwd)/data/postgres/certs/ca.crt:/certs/ca.crt:ro" \
  --health-cmd "pg_isready -U <admin-user>" \
  --health-interval 1m \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  pgvector/pgvector:pg18 \
  postgres \
    -c ssl=on \
    -c ssl_cert_file=/certs/server.crt \
    -c ssl_key_file=/certs/server.key \
    -c ssl_ca_file=/certs/ca.crt \
    -c hba_file=/etc/postgresql/pg_hba.conf
```

**Explanation**:

- `--stop-signal SIGINT --stop-timeout 90` is the most important pair of flags here. Docker's
  default stop signal is `SIGTERM`, which PostgreSQL treats as a **"smart" shutdown**: it waits
  indefinitely for every connected client to disconnect by itself. The media indexers and other
  services hold idle pooled connections open forever, so a smart shutdown never completes on its
  own. With Docker's default ten-second grace period that meant every single stop or restart ended
  in a `SIGKILL`, which PostgreSQL treats as a crash — WAL recovery on the next start and the
  `pg_stat_*` counters wiped every time. `SIGINT` requests the **"fast" shutdown** instead:
  in-flight transactions are rolled back, a clean checkpoint is forced, and the server disconnects
  clients itself, normally in a couple of seconds. The 90-second timeout is a ceiling for a
  checkpoint under heavy load, not the expected duration.
- The five `-c` flags turn on TLS, point at the certificate material, and override the location of
  the authentication file. Passing them here instead of shipping a `postgresql.conf` means the image
  keeps its own defaults for everything else, and the deviations from stock are all visible in one
  place: `docker inspect postgres-db` shows the whole command.
- `ssl_ca_file` is what makes client-certificate verification possible at all — without it the
  server has nothing to check an offered client certificate against and `cert` authentication fails
  for everyone.
- All four mounted configuration/certificate files are read-only. The server never writes to them,
  and read-only mounts mean a compromised server process cannot rewrite its own access policy.
- `--network-alias postgres` gives containers on the same machine the short name `postgres` to dial,
  so nothing has to hard-code an address.
- `-p 5432:5432` exposes the port on the host for clients on other machines. Note that Docker
  publishes ports by inserting its own NAT rules ahead of the host firewall, so this port is
  reachable from anywhere the host is reachable — the `pg_hba.conf` from Step 6 is the real access
  control, not the firewall. That is precisely why no address range in it gets password-only access.
- `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` are read **only on the very first start**, when
  the data directory is empty and the cluster is initialised. Changing them later has no effect;
  change the password with `ALTER ROLE` instead.

---

#### Step 8: Wait for it to accept connections

```bash
for i in $(seq 1 30); do
  docker exec postgres-db pg_isready -U <admin-user> && break
  sleep 2
done

docker exec postgres-db psql -U <admin-user> -c "SHOW ssl;"
```

**Explanation**: The first start does the whole `initdb` sequence, which takes noticeably longer
than a restart; the container reports `starting` for up to the 30-second health start period even
after it is usable. Anything that provisions databases must wait for `pg_isready` rather than for
`docker run` to return, or the first `CREATE DATABASE` races the initialisation and fails.

---

## What lives where

| Path | Contents |
|---|---|
| `./data/postgres/data` | The live cluster. Everything else is reproducible; this is not. |
| `./data/postgres/pg_hba.conf` | Access policy, bind-mounted read-only into the container. |
| `./data/postgres/certs/ca.key`, `ca.crt`, `ca.srl` | The certificate authority. `ca.key` must never leave this machine. |
| `./data/postgres/certs/server.key`, `server.crt`, `server_ext.cnf` | The server's own identity. Key owned by uid/gid `999`. |
| `./data/postgres/certs/clients/` | Archive of every issued client key and certificate. |
| `./data/certs/` on each application machine | The distributed copies: `ca.crt` plus one `.crt`/`.key` pair per application. |

## Restoring

The dumps produced by the nightly backup are, per instance, one `pg_<container>_globals.sql.gz`
(login roles, passwords, tablespaces — these live outside any single database) and one
`pg_<container>_<database>.dump` per database in PostgreSQL's custom format.

**Restore a single database** into a running server. Stop the application that owns it first, so
nothing writes while the restore runs:

```bash
docker stop <service>

docker exec postgres-db createdb -U <admin-user> -O <db-username> <database> 2>/dev/null || true

docker exec -i postgres-db pg_restore -U <admin-user> -d <database> \
  --clean --if-exists --no-owner --role=<db-username> \
  < pg_postgres-db_<database>.dump

docker start <service>
```

**Restore everything into an empty cluster** — the case after losing the machine:

```bash
docker stop postgres-db && docker rm postgres-db
sudo rm -rf ./data/postgres/data
```

Start the container again exactly as in Step 7 (it will run `initdb` and recreate the admin role
from the environment variables), wait for `pg_isready`, then load the globals first and the
databases afterwards:

```bash
zcat pg_postgres-db_globals.sql.gz | docker exec -i postgres-db psql -U <admin-user> -d postgres

for f in pg_postgres-db_*.dump; do
  db=$(basename "$f" .dump); db=${db#pg_postgres-db_}
  docker exec postgres-db createdb -U <admin-user> "$db" 2>/dev/null || true
  docker exec -i postgres-db pg_restore -U <admin-user> -d "$db" --clean --if-exists < "$f"
done
```

**Explanation**: Globals go first because every dump refers to an owner role that must already
exist; restoring a database before its owner leaves every object owned by the admin account and the
application then fails with `permission denied for schema public`. The restore runs through
`docker exec`, which means it arrives on the container's Unix socket and matches the `local … trust`
line — no client certificate is involved, which is what makes a restore possible even when the
certificate material is what you are recovering from. `--clean --if-exists` makes a restore into a
non-empty database idempotent instead of erroring on every existing object.

Certificates are **not** in the dumps. If you lost the machine, re-do Steps 2–5 as well: the CA is
new, so every client certificate in the stack has to be re-issued and re-distributed before the
applications can connect again.

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory; every path here is relative to it |
| `<username>` | Account that owns `./data` | The unprivileged account you administer the host with |
| `<pgid>` | Group id shared with the database image's internal account | `999` for this image; used for the distributed key files |
| `<ip-address>` | This machine's address as clients dial it | The LAN address; goes into the server certificate's SAN and CN |
| `<docker-ip>` | Fixed address for `postgres-db` on the `proxy` network | Any address inside `<docker-subnet>` but outside the auto-assign pool |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy`; the subnet and gateway both appear in `pg_hba.conf` |
| `<pgadmin-docker-ip>` | Fixed address of the pgAdmin container | The address you reserved for it; only this one gets password auth |
| `<lan-subnet>`, `<other-private-subnet>`, `<single-host-ip>` | Private ranges application machines live on | One `hostssl … cert` line each; single hosts need `/32` |
| `<admin-user>` | PostgreSQL superuser name | Conventionally `postgres`; set once at first start |
| `<secret>` | Superuser password | Long random string; read only at first start |
| `<service>` | An application's short name | Used as the client certificate's file name |
| `<db-username>` | The login role an application connects as | Must equal the client certificate's Common Name |
| `<target-host>` | A machine that runs a client application | Where Step 5 copies the certificate material |
| `<database>` | A database name | Used in the restore commands |

## Verification

```bash
docker ps --filter 'name=^postgres-db$'
docker inspect --format '{{.State.Health.Status}}' postgres-db

# the stop behaviour is the thing that silently regresses — check it explicitly
docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db   # expect: SIGINT 90

docker exec postgres-db pg_isready -U <admin-user>
docker exec postgres-db psql -U <admin-user> -c "SHOW ssl;"
docker exec postgres-db psql -U <admin-user> -c "SHOW hba_file;"
docker exec postgres-db psql -U <admin-user> -c '\l'
docker exec postgres-db psql -U <admin-user> -c '\du'
```

Confirm the loaded rules are the ones on disk (this reads the parsed file, so it catches the
detached-bind-mount case):

```bash
docker exec postgres-db psql -U <admin-user> \
  -c "SELECT line_number, type, address, auth_method FROM pg_hba_file_rules ORDER BY line_number;"
```

From an application machine, prove that a certificate is genuinely required — the first must fail,
the second must succeed:

```bash
psql "host=<ip-address> port=5432 user=<db-username> dbname=<database> sslmode=require"

psql "host=<ip-address> port=5432 user=<db-username> dbname=<database> sslmode=verify-full \
  sslrootcert=./data/certs/ca.crt \
  sslcert=./data/certs/<service>.crt \
  sslkey=./data/certs/<service>.key"
```

Check certificate expiry across the board — nothing warns you before the day it breaks:

```bash
for f in ./data/postgres/certs/ca.crt ./data/postgres/certs/server.crt ./data/postgres/certs/clients/*.crt; do
  printf '%s: ' "$f"; openssl x509 -in "$f" -noout -enddate
done
```

## Updating & day-to-day

**Pull a new image and recreate the container.** The image tag pins the major version, so a pull
brings minor releases only and the existing data directory is compatible. A **major** version jump is
not — it needs a dump from the old version and a restore into a freshly initialised cluster.

```bash
docker pull pgvector/pgvector:pg18
docker stop postgres-db && docker rm postgres-db
# re-run the docker run command from Step 7 verbatim
```

**Apply a change to `pg_hba.conf`.** Rewrite it in place with `sudo tee`, then ask the server to
re-read it:

```bash
docker exec postgres-db psql -U <admin-user> -c "SELECT pg_reload_conf();"
docker exec postgres-db psql -U <admin-user> -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
```

If the second query returns rows, the file did not parse and the server is still running the old
rules. Fix the file and reload again.

**Restart properly.** Always stop and start as two separate commands rather than `docker restart`:

```bash
docker stop postgres-db
docker start postgres-db
```

`docker restart` races the container's storage layer on hosts using `fuse-overlayfs` and can leave
the container with a broken root filesystem mount — permanently unhealthy, with `docker exec`
failing in confusing ways. A stop followed by a separate start avoids that and is safe everywhere.
Because the stop signal is `SIGINT`, the stop is a clean fast shutdown and will not hang on idle
client connections.

**Logs**: `docker logs -f postgres-db`. Authentication failures, `pg_hba.conf` parse errors and
checkpoint activity all land there.

**Adding a new application**: issue its certificate (Step 4), copy it out (Step 5), and only widen
`pg_hba.conf` if its machine sits in a range not already covered. Existing clients are untouched.

**Rotating one client's key**: delete that client's `.key`, `.csr` and `.crt` under
`./data/postgres/certs/clients/`, redo Step 4 and Step 5 for it, and restart that application. No
server restart is needed — the CA has not changed.

## Rollback / Uninstall

```bash
docker stop postgres-db
docker rm postgres-db
```

The data survives in `./data/postgres/data`; re-running Step 7 brings the same cluster back.

To remove it completely — **this destroys every database in the stack**:

```bash
sudo rm -rf ./data/postgres
```

And on each application machine, the distributed material:

```bash
sudo rm -f ./data/certs/ca.crt ./data/certs/<service>.crt ./data/certs/<service>.key
```

To relax certificate enforcement temporarily while debugging, change the `cert
clientcert=verify-full` lines to `scram-sha-256`, rewrite the file in place and reload. Put it back
afterwards; a password-only line covering a wide range is exactly the failure mode described in
Step 6.

## Troubleshooting

**`connection requires a valid client certificate` (SQLSTATE 28000)**
The client offered no certificate, or offered one this CA did not sign. Confirm the three files
exist on the client machine and that the key is readable by the account inside the container:
`ls -l ./data/certs/`. Then `openssl verify -CAfile ./data/certs/ca.crt ./data/certs/<service>.crt`.

**`certificate authentication failed for user "<db-username>"`**
The certificate is valid but its Common Name is not the user name in the connection string. Check
with `openssl x509 -in ./data/certs/<service>.crt -noout -subject`. Re-issue with the correct CN
(Step 4); there is no way to make `verify-full` ignore the mismatch.

**`x509: certificate signed by unknown authority … candidate authority certificate "postgres-ca"`**
The client machine has a `ca.crt` from a *different* database server that uses the same CA subject.
Two servers are distributing their CA to the same machine — see the warning in Step 5.

**`no pg_hba.conf entry for host "…", user "…", SSL on`**
The connecting address is in no line of the file. Add its subnet as another `hostssl … cert
clientcert=verify-full` line, rewrite in place, reload. The address in the message is the one the
server actually saw — if it is the bridge gateway rather than the client's own address, the
connection hairpinned through the host's NAT.

**The server will not start; log shows `invalid IP mask "cert"`**
An address in `pg_hba.conf` has no prefix length. Append `/32` to it — see the note in Step 6.

**Edited `pg_hba.conf`, reloaded, nothing changed**
The bind mount is detached because the file was replaced with a new inode. Compare what the server
parsed (`SELECT * FROM pg_hba_file_rules`) against the file on disk; if they differ, rewrite the
file with `sudo tee` and restart the container with a stop and a start.

**`pg_stat_*` counters reset and the log shows crash recovery after every restart**
The container is running with Docker's default stop behaviour. Check
`docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db`; if it is not
`SIGINT 90`, recreate the container with those flags.

**`docker stop postgres-db` takes close to 90 seconds**
A fast shutdown normally finishes in seconds. Consistently hitting the ceiling means the final
checkpoint has a lot to flush — look at `checkpoint_timeout` and the write volume before assuming
the container is stuck.

**TLS handshake fails with a hostname mismatch under `sslmode=verify-full`**
The name in the connection string is not in the server certificate's SAN. Inspect it with
`openssl x509 -in ./data/postgres/certs/server.crt -noout -text | grep -A1 'Subject Alternative Name'`
and re-issue the server certificate (Step 3) with the missing entry added, then restart the
container.

**A newly issued client certificate does not work, an old one still does**
The signing serial file was missing and `-CAcreateserial` restarted numbering, producing two
certificates with the same serial. Confirm the serials differ
(`openssl x509 -noout -serial -in …`), recreate `ca.srl`, and re-issue the newer one.
