# PostgreSQL (public web host instance)

## What this is

A PostgreSQL server that belongs to the public-facing web machine alone. It runs as the container
`postgres-db` from the `pgvector/pgvector:pg18` image (PostgreSQL 18 with the `pgvector` extension
compiled in) and stores the state of the applications on that same machine — the single sign-on
portal's sessions, TOTP secrets and identity audit trail, plus any other application you give a
database to here.

This is **not** the central database server the rest of the homelab shares. It is a second,
independent instance with its own certificate authority, its own superuser and its own data
directory. It exists because the public machine sits outside the private network and should not
reach across it for every session lookup.

Two consequences follow from being local-only, and they are the main differences from the central
instance:

- **Nothing is published on the host.** There is no `-p 5432:5432`. Only containers on the shared
  `proxy` bridge network can reach it, and they address it as `postgres-db` — Docker registers a
  container's own name as a DNS alias on user-defined bridge networks, so no extra alias is
  configured.
- **There is no password-only exception in the access policy.** Every client on this machine
  presents a client certificate, so `pg_hba.conf` requires `cert clientcert=verify-full` for every
  address range except the container's own Unix socket and loopback.

Blog content is not here — the blogs on this machine use MariaDB, a separate pair of containers.

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

Keep fixed container addresses outside the `--ip-range` auto-assign pool. Note the subnet — it goes
into `pg_hba.conf` in Step 6:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

**`openssl` is available**

```bash
openssl version
```

**This machine is not already receiving another server's CA certificate**

```bash
ls -l ./data/certs/ 2>/dev/null
[ -f ./data/certs/ca.crt ] && openssl x509 -in ./data/certs/ca.crt -noout -subject -dates
```

If `ca.crt` already exists here, find out where it came from before you continue. The central
database server distributes its own `ca.crt` to the machines that connect to it, using the same
subject `CN=postgres-ca` this instance will use. If both write that file, whichever ran last wins
and every client on this machine starts failing with `x509: certificate signed by unknown authority
… candidate authority certificate "postgres-ca"` — a message that looks like corruption and is
actually a collision. A machine that runs its own database server must not also be on the central
server's distribution list.

## Setup

### Overview

1. Create the data and certificate directories.
2. Create the certificate authority.
3. Issue the server certificate, with `postgres-db` among its names.
4. Issue one client certificate per application, with the Common Name set to its database login role.
5. Place the CA certificate and the client material where the applications will read it.
6. Write `pg_hba.conf`.
7. Start the container and wait for it to accept connections.
8. Create the login roles and databases the applications need.
9. Verify.

---

#### Step 1: Create the data and certificate directories

```bash
mkdir -p ./data/postgres/certs/clients
sudo chown <username>:<pgid> ./data/postgres ./data/postgres/certs ./data/postgres/certs/clients
sudo chmod 0750 ./data/postgres ./data/postgres/certs ./data/postgres/certs/clients
```

**Explanation**: `./data/postgres` holds the live cluster under `data/`, the access policy
`pg_hba.conf`, and all certificate material under `certs/`. Mode `0750` keeps private keys away from
other unprivileged accounts while the deploy account's group can still read them. On a machine that
is exposed to the internet this matters more than it would on the private side.

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

Create the serial file used when signing clients, once:

```bash
[ -f ./data/postgres/certs/ca.srl ] || printf '01\n' | sudo tee ./data/postgres/certs/ca.srl >/dev/null
sudo chown root:root ./data/postgres/certs/ca.srl
sudo chmod 0600 ./data/postgres/certs/ca.srl
```

**Explanation**: This CA signs the server certificate and every client certificate on this machine.
Mutual authentication works because both sides chain to it: the server trusts a client whose
certificate this CA signed, and the client verifies the server the same way. `-nodes` leaves the key
without a passphrase since signing is unattended — the file mode is the only protection, so `ca.key`
never leaves this machine. Ten years of validity is deliberate; an expired database CA takes every
application on the machine down at once and nothing renews it automatically. The serial file keeps
each issued certificate's serial unique.

---

#### Step 3: Issue the server certificate

```bash
openssl genrsa -out ./data/postgres/certs/server.key 2048

sudo tee ./data/postgres/certs/server_ext.cnf >/dev/null <<'EOF'
[v3_req]
subjectAltName = IP:<ip-address>,DNS:localhost,DNS:postgres-db
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

Set the ownership the container needs:

```bash
sudo chown 999:999 ./data/postgres/certs/server.key
sudo chmod 0600 ./data/postgres/certs/server.key

sudo chown root:root ./data/postgres/certs/server.crt
sudo chmod 0644 ./data/postgres/certs/server.crt
```

**Explanation**: `DNS:postgres-db` is the entry that matters on this machine, and it is the one
difference from the central server's certificate. Clients here dial the container by name over the
bridge network, and a TLS client validating with `sslmode=verify-full` compares the name it dialled
against the Subject Alternative Name list — the Common Name is ignored by modern clients. Without
that entry every local client would have to drop to `verify-ca`, which stops checking *which* server
answered. `IP:<ip-address>` and `DNS:localhost` are kept as well so a `psql` session from the host
itself also verifies.

The key is owned by uid/gid `999` — the `postgres` account inside the image — and is unreadable by
anyone else, because PostgreSQL refuses to start when its private key is group- or world-readable.

---

#### Step 4: Issue one client certificate per application

Repeat for each application. The file name identifies the application; the **Common Name must be the
exact PostgreSQL login role** it authenticates as.

```bash
CLIENT=<service>          # file name
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

Confirm what you produced:

```bash
openssl x509 -in ./data/postgres/certs/clients/${CLIENT}.crt -noout -subject -dates
openssl verify -CAfile ./data/postgres/certs/ca.crt ./data/postgres/certs/clients/${CLIENT}.crt
```

**Explanation**: `clientcert=verify-full` makes the server compare the certificate's Common Name with
the user name in the connection string and reject the connection when they differ. On this instance
there is no password-only fallback for any address range, so a client with a wrong CN cannot connect
at all — there is no degraded path it can quietly slip into. Only run this block for a client that
has no key yet, or when you are deliberately rotating that one client; re-issuing invalidates the
copy already in use.

---

#### Step 5: Place the CA certificate and client material

Applications read their certificates from `./data/certs` on the machine they run on, mounted
read-only into the container (usually at `/postgres-certs`). On this machine that is a local copy,
not a transfer:

```bash
mkdir -p ./data/certs
sudo chmod 0755 ./data/certs

sudo install -m 0644 ./data/postgres/certs/ca.crt                ./data/certs/ca.crt
sudo install -m 0644 ./data/postgres/certs/clients/${CLIENT}.crt ./data/certs/${CLIENT}.crt
sudo install -o root -g <pgid> -m 0640 \
  ./data/postgres/certs/clients/${CLIENT}.key ./data/certs/${CLIENT}.key
```

If a client of this server runs on a different machine, copy the same three files there instead:

```bash
ssh <username>@<target-host> "mkdir -p ./data/certs && chmod 0755 ./data/certs"
scp ./data/postgres/certs/ca.crt                <username>@<target-host>:./data/certs/ca.crt
scp ./data/postgres/certs/clients/${CLIENT}.crt <username>@<target-host>:./data/certs/${CLIENT}.crt
scp ./data/postgres/certs/clients/${CLIENT}.key <username>@<target-host>:./data/certs/${CLIENT}.key
ssh <username>@<target-host> "sudo chown root:<pgid> ./data/certs/${CLIENT}.key && \
  sudo chmod 0640 ./data/certs/${CLIENT}.key"
```

**Explanation**: One shared `./data/certs` directory per machine means a single read-only bind mount
serves every container that needs database credentials. The key is `root:<pgid>` mode `0640` because
`<pgid>` is the group the database image — and most consuming containers — run as, so group-read is
exactly enough and nothing is world-readable. The certificate itself is public material and stays
`0644`.

---

#### Step 6: Write `pg_hba.conf`

```bash
sudo tee ./data/postgres/pg_hba.conf >/dev/null <<'EOF'
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
# All docker/LAN clients: SSL + client certificate required. pg_hba is
# first-match-wins top to bottom, so no broad password line may sit above
# these (that would make the client-cert requirement unreachable).
hostssl all       all   <lan-subnet>   cert clientcert=verify-full
hostssl all       all   <other-private-subnet>   cert clientcert=verify-full
hostssl all       all   <single-host-ip>/32   cert clientcert=verify-full
hostssl all       all   <docker-subnet>   cert clientcert=verify-full
EOF
sudo chown <username>:<pgid> ./data/postgres/pg_hba.conf
sudo chmod 0644 ./data/postgres/pg_hba.conf
```

Write one `hostssl … cert clientcert=verify-full` line per private range that may hold a client, then
one final line for the `proxy` subnet — which, on this machine, is where every real client comes
from.

**Explanation**: PostgreSQL walks this file **top to bottom and stops at the first line whose
connection type, database, user and address all match**. It never looks for a better match further
down, and a failed authentication on the matched line ends the connection rather than falling
through. So:

- `local … trust` is the container's own Unix socket. It never leaves the container's namespace, so
  there is nothing to authenticate; this is also what makes `docker exec postgres-db psql` and the
  nightly dump work without a certificate.
- `127.0.0.1/32` is loopback inside the container, password only, same reasoning.
- Everything else is mutual TLS, with no exceptions. Unlike the central server, this instance has no
  browser-based client that cannot hold a key, so nothing needs a password-only line — and because
  a wide password line above the certificate lines would shadow them completely, not having one is
  the safest state to stay in.

> **Every address needs a prefix length.** PostgreSQL reads the address field three ways: with a `/`
> it is CIDR and the next token is the method; a **bare** numeric address means the next token must
> be a netmask (the legacy `address netmask method` form); a non-numeric token means the next token
> is the method. A single host written without `/32` therefore makes the parser read the following
> `cert` as a netmask and the server refuses to start:
>
> ```
> LOG:  invalid IP mask "cert": Name or service not known
> FATAL:  could not load /etc/postgresql/pg_hba.conf
> ```
>
> The same list of private addresses is also used for the reverse proxy's and the intrusion
> detector's whitelists, which accept bare addresses happily — so a single host added there for
> whitelisting breaks only this file. Always append `/32`.

> **Overwrite this file in place.** The container bind-mounts it as a single file, and a single-file
> bind mount follows the *inode* that existed when the container started. Replacing the file with an
> editor or `mv` creates a new inode and silently detaches the mount — the running server keeps
> serving the old rules however often you reload. `sudo tee` truncates and rewrites in place, which
> preserves the inode.

There is **no `postgresql.conf` to write**: every setting this deployment changes is passed on the
command line in the next step.

---

#### Step 7: Start the container and wait for it

```bash
docker run -d \
  --name postgres-db \
  --restart unless-stopped \
  --stop-signal SIGINT \
  --stop-timeout 90 \
  --network proxy \
  --ip <docker-ip> \
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

Then block until it actually answers, before doing anything else:

```bash
for i in $(seq 1 30); do
  docker exec postgres-db pg_isready -U <admin-user> && break
  sleep 2
done
```

**Explanation**:

- **No published port and no extra network alias.** The container is reachable only from the `proxy`
  network, by the name `postgres-db` that Docker registers automatically. On a machine with a public
  address that is the point: there is no way to reach the database from the internet even if a
  firewall rule is wrong, because nothing is bound on the host at all.
- `--stop-signal SIGINT --stop-timeout 90` is the flag pair that matters most. Docker's default
  `SIGTERM` is interpreted by PostgreSQL as a **"smart" shutdown** that waits indefinitely for every
  connected client to disconnect by itself. Application containers hold idle pooled connections open
  forever, so that never completes, and with Docker's ten-second default grace period every stop
  ended in a `SIGKILL` — an unclean crash, which means WAL recovery on the next start and the
  `pg_stat_*` counters wiped each time. `SIGINT` requests the **"fast" shutdown**: in-flight
  transactions rolled back, a clean checkpoint forced, clients disconnected by the server, normally
  within seconds. The 90-second timeout is a ceiling for a checkpoint under load, not the expected
  duration.
- The five `-c` flags enable TLS, point at the certificate material and move the access-policy file.
  `ssl_ca_file` is what makes client-certificate verification possible at all — without it the server
  has nothing to check an offered certificate against and `cert` authentication fails for everyone.
- All mounted configuration and certificate files are read-only; the server never writes to them.
- `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` are read **only on the first start**, when the
  data directory is empty. Changing them later does nothing; use `ALTER ROLE` to change the password.
- The wait loop exists because the first start runs the whole `initdb` sequence. Anything that
  creates roles or databases straight afterwards — Step 8 — races the initialisation if it does not
  wait for `pg_isready`.

---

#### Step 8: Create the login roles and databases

For each application that needs one:

```bash
DB_USER=<db-username>
DB_PASS='<secret>'
DB_NAME=<database>

exists=$(docker exec postgres-db psql -U <admin-user> -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'")
if [ "$(echo "$exists" | tr -d '[:space:]')" != "1" ]; then
  docker exec postgres-db psql -U <admin-user> -c \
    "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}'"
fi

docker exec postgres-db createdb -U <admin-user> -O "${DB_USER}" "${DB_NAME}" || true

docker exec postgres-db psql -U <admin-user> -d "${DB_NAME}" -c \
  "GRANT ALL ON SCHEMA public TO ${DB_USER}"
```

**Explanation**: The existence check before `CREATE ROLE` is what makes this safe to run again —
re-creating a role is an error, and worse, blindly running `CREATE ROLE … PASSWORD` on an existing
account would be a silent password reset that breaks a working application. `createdb` failing with
"already exists" is likewise expected on a second run and is ignored.

The explicit `GRANT ALL ON SCHEMA public` is not redundant with database ownership: since PostgreSQL
15 the `public` schema no longer grants `CREATE` to everyone, so an owner that never received the
grant can connect and then fail its first migration with `permission denied for schema public`.

The password set here must match the one the application uses, and the application must *also*
present the client certificate from Step 4 whose Common Name equals this role — the certificate
proves who it is, the password is checked on top of it only where the policy asks for one. On this
instance every real connection matches a `cert` line, so the certificate is the authenticator.

---

#### Step 9: Verify

```bash
docker exec postgres-db psql -U <admin-user> -c '\l'
docker exec postgres-db psql -U <admin-user> -d <database> -c '\dt'

ls -l ./data/certs
```

**Explanation**: Listing the tables of each application database is the check that distinguishes "a
database exists" from "the application actually migrated into it" — an empty database and a healthy
container look identical from the outside. The `./data/certs` listing must show `ca.crt` plus one
`.crt` and one `.key` for every application; a missing pair is the most common reason a service comes
up and then cannot authenticate.

---

## What lives where

| Path | Contents |
|---|---|
| `./data/postgres/data` | The live cluster. The only irreplaceable thing here. |
| `./data/postgres/pg_hba.conf` | Access policy, bind-mounted read-only into the container. |
| `./data/postgres/certs/ca.key`, `ca.crt`, `ca.srl` | This machine's certificate authority. |
| `./data/postgres/certs/server.key`, `server.crt`, `server_ext.cnf` | The server's identity. Key owned by uid/gid `999`. |
| `./data/postgres/certs/clients/` | Archive of every issued client key and certificate. |
| `./data/certs/` | The working copies the containers read: `ca.crt` plus a pair per application. |

## Restoring

The nightly dumps for this instance are one `pg_postgres-db_globals.sql.gz` (login roles, passwords,
tablespaces — these live outside any database) and one `pg_postgres-db_<database>.dump` per database
in PostgreSQL's custom format.

**Restore one database.** Stop the application that owns it first so nothing writes during the
restore:

```bash
docker stop <service>

docker exec postgres-db createdb -U <admin-user> -O <db-username> <database> 2>/dev/null || true

docker exec -i postgres-db pg_restore -U <admin-user> -d <database> \
  --clean --if-exists --no-owner --role=<db-username> \
  < pg_postgres-db_<database>.dump

docker start <service>
```

**Restore the whole instance** after losing the machine:

```bash
docker stop postgres-db && docker rm postgres-db
sudo rm -rf ./data/postgres/data
```

Start the container again exactly as in Step 7, wait for `pg_isready`, then load globals first and
databases after:

```bash
zcat pg_postgres-db_globals.sql.gz | docker exec -i postgres-db psql -U <admin-user> -d postgres

for f in pg_postgres-db_*.dump; do
  db=$(basename "$f" .dump); db=${db#pg_postgres-db_}
  docker exec postgres-db createdb -U <admin-user> "$db" 2>/dev/null || true
  docker exec -i postgres-db pg_restore -U <admin-user> -d "$db" --clean --if-exists < "$f"
done
```

**Explanation**: Globals go first because every database dump refers to an owner role that must
already exist; without them everything ends up owned by the superuser and the applications fail with
`permission denied for schema public`. The restore goes through `docker exec`, so it arrives on the
container's Unix socket and matches the `local … trust` line — no client certificate is needed, which
is what lets you restore even when the certificates are part of what you lost. `--clean --if-exists`
makes a restore into a non-empty database repeatable.

Certificates are not in the dumps. After a full rebuild, redo Steps 2–5: the CA is new, so every
client certificate must be re-issued and the applications restarted.

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory; all paths are relative to it |
| `<username>` | Account that owns `./data` | The unprivileged account you administer the host with |
| `<pgid>` | Group id the database image runs as | `999` for this image; owns the distributed key files |
| `<ip-address>` | This machine's own address | Goes into the server certificate's CN and SAN |
| `<docker-ip>` | Fixed address for `postgres-db` on the `proxy` network | Inside `<docker-subnet>`, outside the auto-assign pool |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy`; the subnet appears in `pg_hba.conf` |
| `<lan-subnet>`, `<other-private-subnet>`, `<single-host-ip>` | Private ranges that may hold a client | One `hostssl … cert` line each; single hosts need `/32` |
| `<admin-user>` | PostgreSQL superuser name | Conventionally `postgres`; fixed at first start |
| `<secret>` | Superuser password, and each application role's password | Long random strings, one per account |
| `<service>` | An application's short name | Used as the client certificate's file name, and as its container name when stopping it |
| `<db-username>` | Login role an application connects as | Must equal its certificate's Common Name |
| `<database>` | Database name for an application | Usually the same word as the application |
| `<target-host>` | A machine outside this one that runs a client | Only needed if a client is not local |

## Verification

```bash
docker ps --filter 'name=^postgres-db$'
docker inspect --format '{{.State.Health.Status}}' postgres-db

# stop behaviour — the setting that silently regresses on a manual recreate
docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db   # expect: SIGINT 90

# nothing must be published on the host
docker inspect --format '{{.NetworkSettings.Ports}}' postgres-db   # expect: map[] / no 5432

docker exec postgres-db pg_isready -U <admin-user>
docker exec postgres-db psql -U <admin-user> -c "SHOW ssl;"
docker exec postgres-db psql -U <admin-user> -c "SHOW hba_file;"
docker exec postgres-db psql -U <admin-user> -c '\l'
docker exec postgres-db psql -U <admin-user> -c '\du'
docker exec postgres-db psql -U <admin-user> -d <database> -c '\dt'
```

Confirm the rules the server actually parsed, which catches a detached bind mount:

```bash
docker exec postgres-db psql -U <admin-user> \
  -c "SELECT line_number, type, address, auth_method FROM pg_hba_file_rules ORDER BY line_number;"
```

Prove mutual TLS is enforced. From a container on the `proxy` network, the first must fail and the
second must succeed:

```bash
psql "host=postgres-db port=5432 user=<db-username> dbname=<database> sslmode=require"

psql "host=postgres-db port=5432 user=<db-username> dbname=<database> sslmode=verify-full \
  sslrootcert=/postgres-certs/ca.crt \
  sslcert=/postgres-certs/<service>.crt \
  sslkey=/postgres-certs/<service>.key"
```

Check the certificate names and expiry dates:

```bash
openssl x509 -in ./data/postgres/certs/server.crt -noout -text | grep -A1 'Subject Alternative Name'
for f in ./data/postgres/certs/ca.crt ./data/postgres/certs/clients/*.crt; do
  printf '%s: ' "$f"; openssl x509 -in "$f" -noout -subject -enddate
done
```

## Updating & day-to-day

**Pull a new image and recreate.** The tag pins the major version, so a pull brings minor releases
only and the existing data directory stays compatible. A major version jump is not — that needs a
dump from the old version and a restore into a fresh cluster.

```bash
docker pull pgvector/pgvector:pg18
docker stop postgres-db && docker rm postgres-db
# re-run the docker run command from Step 7 verbatim
```

**Apply an access-policy change.** Rewrite `pg_hba.conf` in place with `sudo tee`, then:

```bash
docker exec postgres-db psql -U <admin-user> -c "SELECT pg_reload_conf();"
docker exec postgres-db psql -U <admin-user> -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
```

Rows in the second query mean the file did not parse and the old rules are still in force.

**Restart properly** — stop and start as two commands, never `docker restart`:

```bash
docker stop postgres-db
docker start postgres-db
```

`docker restart` races the container's storage layer on hosts using `fuse-overlayfs` and can leave a
broken root filesystem mount behind: the container stays unhealthy and `docker exec` fails in
confusing ways. A separate stop and start avoids that and is safe everywhere. With `SIGINT` as the
stop signal the stop is a clean fast shutdown and will not hang on idle connections.

**Logs**: `docker logs -f postgres-db`.

**Adding an application**: issue its certificate (Step 4), place it (Step 5), create its role and
database (Step 8). No server restart is needed unless its machine sits in a range `pg_hba.conf` does
not already cover.

**Rotating a client key**: delete that client's `.key`, `.csr` and `.crt` under
`./data/postgres/certs/clients/`, redo Steps 4 and 5, restart the application.

## Rollback / Uninstall

```bash
docker stop postgres-db
docker rm postgres-db
```

The cluster survives in `./data/postgres/data` and re-running Step 7 brings it back.

To remove it completely — **this destroys every database on this machine**:

```bash
sudo rm -rf ./data/postgres
sudo rm -f ./data/certs/ca.crt ./data/certs/<service>.crt ./data/certs/<service>.key
```

## Troubleshooting

**`connection requires a valid client certificate` (SQLSTATE 28000)**
The client presented no certificate, or one this CA did not sign. There is no password fallback on
this instance, so this is fatal until fixed. Check `ls -l ./data/certs/` and
`openssl verify -CAfile ./data/certs/ca.crt ./data/certs/<service>.crt`.

**`certificate authentication failed for user "<db-username>"`**
The certificate is valid but its Common Name is not the user name in the connection string. Check
with `openssl x509 -in ./data/certs/<service>.crt -noout -subject` and re-issue with the right CN.

**`x509: certificate signed by unknown authority … candidate authority certificate "postgres-ca"`**
`./data/certs/ca.crt` on this machine belongs to a different database server. Both CAs use the
subject `CN=postgres-ca`, so the message names the right subject and the wrong key. Restore this
instance's own `ca.crt` (Step 5) and stop the other server from distributing here.

**A client certificate is rejected even though the certificate and CA look correct**
Check which line the connection actually matched. The file is first-match-wins, so an earlier line
covering the same address range decides the outcome and the `cert` line below it is never consulted.
`SELECT * FROM pg_hba_file_rules ORDER BY line_number;` shows the order the server sees.

**Edited `pg_hba.conf`, reloaded, nothing changed**
The single-file bind mount is detached because the file was replaced with a new inode. Compare
`pg_hba_file_rules` with the file on disk; if they differ, rewrite with `sudo tee` and restart the
container with a stop and a start.

**Server will not start; log shows `invalid IP mask "cert"`**
An address in `pg_hba.conf` is missing its prefix length. Append `/32` — see Step 6.

**`role … already exists` or `database … already exists` in Step 8**
Expected on a re-run. The existence check skips the role; `createdb` is allowed to fail. Do not
re-issue `CREATE ROLE … PASSWORD` for an existing account — that resets a working password.

**`permission denied for schema public` on an application's first migration**
The `GRANT ALL ON SCHEMA public` from Step 8 was not run for that database. Ownership alone is not
enough on PostgreSQL 15 and later.

**Hostname mismatch under `sslmode=verify-full`**
The name the client dialled is not in the server certificate's SAN. Inspect it with
`openssl x509 -in ./data/postgres/certs/server.crt -noout -text | grep -A1 'Subject Alternative Name'`
— it must contain `DNS:postgres-db` for local clients — then re-issue (Step 3) and restart.

**`pg_stat_*` counters reset and crash recovery runs after every restart**
The container lost its stop settings. Check
`docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db` and recreate
with `--stop-signal SIGINT --stop-timeout 90` if it is not `SIGINT 90`.

**A newly issued client certificate does not work while an older one still does**
The serial file was missing and `-CAcreateserial` restarted numbering, so two certificates share a
serial. Compare with `openssl x509 -noout -serial`, recreate `ca.srl`, re-issue the newer one.
