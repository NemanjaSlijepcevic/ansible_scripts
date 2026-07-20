# Role: postgres_server

## Purpose

Deploys a **second, host-local PostgreSQL server as a Docker container** (`postgres-db`, image `pgvector/pgvector:pg18`) on the `server` host, with TLS material generated and (optionally) provisions application roles/databases directly. This is a **separate deployment from the `postgres` role** (which runs the shared central database on `primary_postgres`) — see `../CLAUDE.md` "Per-Machine Baseline Stack" (`server` = ... + `sql`/`postgres_server`).

The role runs five task groups in order, via `main.yml`:

1. **`certs.yml`** — generates a private CA plus a server key/certificate for this host's `postgres-db`.
2. **`client_certs.yml`** — generates a client key/certificate per consuming application (`postgres_tls_clients`) and distributes the CA cert + client cert/key to each host in `postgres_tls_client_hosts` (which, on this host, typically includes the `server` host itself as a local consumer).
3. **`container.yml`** — renders `pg_hba.conf` and deploys the `postgres-db` container, then waits for it to accept connections.
4. **`create_service_users.yml`** *(only when `postgres_service_users` is non-empty)* — creates PostgreSQL roles and databases directly via `docker exec … psql`/`createdb`, and grants schema privileges. The `postgres` role has no equivalent step; it relies on the separate `prepare_postgres` role instead.
5. **`verify.yml`** *(always runs)* — lists databases and per-database tables, and asserts that the expected client cert/key files exist under `postgres_tls_client_base_dir`.

`postgres_migrate_local_dbs` and `postgres_migrate_source_host` also exist in `defaults/main.yml`. No task file in this role currently reads either variable — they are reserved for a manual/future one-time migration, not part of the active execution path today.

### Key differences from the `postgres` role

| Aspect | `postgres` (primary_postgres) | `postgres_server` (server host) |
|---|---|---|
| Docker network alias | `aliases: [postgres]` — clients use hostname `postgres` | none — clients use Docker's automatic container-name alias `postgres-db` (matches `postgres.ip: "postgres-db"` in defaults) |
| Host port publish | `-p 5432:5432` (reachable from outside `proxy`) | none — only reachable by containers on the `proxy` network |
| Server cert SAN | `IP:<ansible_host>,DNS:localhost` | `IP:<ansible_host>,DNS:localhost,DNS:postgres-db` (extra SAN for the alias name clients actually connect to) |
| `pg_hba.conf` enforcement | `hostssl … cert clientcert=verify-full` mandatory for every `private_ips` CIDR **and** `docker.subnet` | identical structure and coverage — mutual TLS is mandatory here too; see Step 6 |
| `pg_hba.conf` password exceptions | Two `hostssl … scram-sha-256` lines *above* the cert block, scoped to `pgadmin.static` and `docker.gateway` — pgAdmin is the only client that connects without a client certificate | none — this role's only client (`authelia`) uses a client certificate, so there is no password-auth exception carved out above the cert block |
| Stop signal | `SIGINT` / 90s timeout (see below) | `SIGINT` / 90s timeout — **same fix, same reasoning** (see below) |
| Restart mechanism | stop+start (not `docker restart`) — fuse-overlayfs mount-safety, see Handlers section | identical — same two-task stop+start handler |
| Startup readiness | healthcheck only | healthcheck **plus** a blocking `docker exec … pg_isready` retry loop (30 × 2s = up to 60s) before the role continues |
| Application provisioning | none (delegated to `prepare_postgres`) | `create_service_users.yml` creates roles/DBs/grants in-role |
| Post-deploy verification | none (manual, see this doc's Verification section) | `verify.yml` runs automatically every time the role runs |

## Prerequisites

- The `common` role must have already run on the target host (creates the `proxy` Docker network and `./data` working directory).
- `openssl` must be available on the target host.
- Docker Engine must be installed and running.
- Variables: `postgres.static` / `postgres.ip` / `postgres.port` / `postgres.adm_user` / `postgres.adm_pass`, `pgid`, `postgres_tls_clients`, `postgres_tls_client_hosts`, `postgres_service_users`, `user.name`, `user.group`.

## Manual Execution Guide

### Overview

1. Create `./data/postgres/certs/` and `./data/postgres/certs/clients/`.
2. Generate a CA key + self-signed CA certificate.
3. Generate the server key, CSR (SAN = host IP, `localhost`, and `postgres-db`), and sign the server certificate with the CA.
4. Set ownership/permissions (server key owned by uid/gid `999`, the image's internal postgres user).
5. For each consuming application: generate a client key + CSR (CN = DB username) and sign it with the CA.
6. Distribute the CA cert + each client's cert/key to every host in that client's `hosts` list (commonly including this host itself).
7. Render `pg_hba.conf` — mutual TLS (`hostssl … cert clientcert=verify-full`) mandatory for every application subnet and the Docker subnet; no password-only exception lines (this host's only client, `authelia`, connects with a client cert).
8. Deploy the `postgres-db` container (TLS enabled, `SIGINT`/90s stop, no published port, no network alias) and wait for it to accept connections.
9. If any service users are configured, create their roles/databases/grants.
10. Verify databases, tables, and that expected cert files landed on disk.

---

### Step-by-Step Instructions

#### Step 1: Create the certificate directories

**Purpose**: Holds the CA, server, and per-client TLS material, plus the rendered `pg_hba.conf` and the container's persistent data.

```bash
mkdir -p ./data/postgres
mkdir -p ./data/postgres/certs
mkdir -p ./data/postgres/certs/clients
chown <username>:docker ./data/postgres ./data/postgres/certs ./data/postgres/certs/clients
chmod 0750 ./data/postgres/certs ./data/postgres/certs/clients
```

---

#### Step 2: Generate the CA key and certificate

**Purpose**: A private Certificate Authority signs both the server certificate and every client certificate issued by this role.

```bash
openssl genrsa -out ./data/postgres/certs/ca.key 4096
chmod 0600 ./data/postgres/certs/ca.key
chown <username>:docker ./data/postgres/certs/ca.key

openssl req -x509 -new -nodes \
  -key ./data/postgres/certs/ca.key \
  -sha256 -days 3650 \
  -subj "/CN=postgres-ca" \
  -out ./data/postgres/certs/ca.crt
```

---

#### Step 3: Generate the server key and certificate

**Purpose**: The certificate this host's `postgres-db` presents during the TLS handshake. It carries **three** SAN entries because clients on this host reach it by three different names/addresses.

```bash
openssl genrsa -out ./data/postgres/certs/server.key 2048

cat > ./data/postgres/certs/server_ext.cnf <<'EOF'
[v3_req]
subjectAltName = IP:<ip-address>,DNS:localhost,DNS:postgres-db
EOF

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

**Explanation**: `<ip-address>` is `ansible_host` for the `server` host. Unlike the `postgres` role, `DNS:postgres-db` is included because Docker automatically registers a container's own `name` as a DNS alias on user-defined bridge networks — clients configured with `postgres.ip: "postgres-db"` connect using that hostname, so it must be a valid SAN for TLS hostname verification (`sslmode=verify-full`) to succeed for any client that chooses to use it.

Final permissions — server key owned by uid/gid `999` (the container's internal `postgres` user):

```bash
chown 999:999 ./data/postgres/certs/server.key
chmod 0600 ./data/postgres/certs/server.key

chown root:root ./data/postgres/certs/server.crt
chmod 0644 ./data/postgres/certs/server.crt
```

---

#### Step 4: Generate a client certificate per consuming application

**Purpose**: Every entry in `postgres_tls_clients` gets its own key/cert pair, CN = the PostgreSQL username it will authenticate as (if/when it chooses to connect with a client cert — see the `pg_hba.conf` note in Step 6).

```bash
CLIENT=authelia          # postgres_tls_clients[].name
DB_USER=<db-username>    # postgres_tls_clients[].db_user

[ -f ./data/postgres/certs/ca.srl ] || printf '01\n' > ./data/postgres/certs/ca.srl
chown root:root ./data/postgres/certs/ca.srl
chmod 0600 ./data/postgres/certs/ca.srl

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

chown root:root ./data/postgres/certs/clients/${CLIENT}.key
chmod 0600 ./data/postgres/certs/clients/${CLIENT}.key
chown root:root ./data/postgres/certs/clients/${CLIENT}.crt
chmod 0644 ./data/postgres/certs/clients/${CLIENT}.crt
```

---

#### Step 5: Distribute the CA cert and client certs

**Purpose**: Every host in a client's `hosts` list (in the inventory, `postgres_tls_clients[].hosts`) receives the CA cert plus that client's cert/key under `postgres_tls_client_base_dir` (default `./data/certs`). On this role, that list commonly **includes the `server` host itself** — i.e. certs are frequently copied to the same machine `postgres_server` runs on, for locally-running consumer apps.

```bash
# For each host in postgres_tls_client_hosts (may be this same host):
ssh <username>@<target-host> "mkdir -p ./data/certs && chmod 0755 ./data/certs"

scp ./data/postgres/certs/ca.crt              <username>@<target-host>:./data/certs/ca.crt
scp ./data/postgres/certs/clients/${CLIENT}.crt <username>@<target-host>:./data/certs/${CLIENT}.crt
scp ./data/postgres/certs/clients/${CLIENT}.key <username>@<target-host>:./data/certs/${CLIENT}.key

ssh <username>@<target-host> "chmod 0644 ./data/certs/ca.crt ./data/certs/${CLIENT}.crt && \
  chown root:<pgid> ./data/certs/${CLIENT}.key && chmod 0640 ./data/certs/${CLIENT}.key"
```

If the target is the same host `postgres_server` runs on, this is a local file copy rather than `scp`/`ssh`.

---

#### Step 6: Render `pg_hba.conf`

**Purpose**: Host-based authentication rules for this instance.

```bash
mkdir -p ./data/postgres
cat > ./data/postgres/pg_hba.conf <<'EOF'
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
# All docker/LAN clients: SSL + client certificate required. pg_hba is
# first-match-wins top to bottom, so no broad password line may sit above
# these (that would make the client-cert requirement unreachable).
hostssl all       all   <private-subnet-1>    cert clientcert=verify-full
hostssl all       all   <private-subnet-2>    cert clientcert=verify-full
hostssl all       all   <private-subnet-3>    cert clientcert=verify-full
hostssl all       all   <docker-subnet>       cert clientcert=verify-full
EOF
chown <username>:docker ./data/postgres/pg_hba.conf
chmod 0644 ./data/postgres/pg_hba.conf
```

**Explanation**: Mutual TLS is **mandatory** here, identically to the `postgres` role — every line matching an application subnet (`private_ips`) or the Docker bridge (`docker.subnet`) is `hostssl … cert clientcert=verify-full`. Only `local` (Unix socket) and loopback (`127.0.0.1/32`) connections skip the client-cert requirement, and those never leave the container/host.

`pg_hba.conf` is evaluated **first-match-wins, top to bottom** — the first line whose TYPE/DATABASE/USER/ADDRESS all match a connection attempt decides how it's authenticated, and no further lines are checked. That's why the broad `hostssl … cert clientcert=verify-full` lines are written last in the file: if a permissive password-based line were placed above them (or covered a broader address range), it would shadow the cert requirement and silently make it unreachable for any connection matching both.

The `postgres` role's template carries the same structure but adds two `hostssl … scram-sha-256` lines *above* the cert block, scoped narrowly to `pgadmin.static/32` and `docker.gateway/32` — pgAdmin is that instance's one client without an issued certificate, so it authenticates with TLS + password instead. `postgres_server` has no equivalent lines because its only configured client, `authelia`, always connects with a client certificate — there's no cert-less consumer to carve an exception for.

---

#### Step 7: Deploy the PostgreSQL container

**Purpose**: Runs PostgreSQL with the certs and `pg_hba.conf` from the previous steps wired in via `-c` flags.

```bash
sudo docker run -d \
  --name postgres-db \
  --restart unless-stopped \
  --stop-signal SIGINT \
  --stop-timeout 90 \
  --network proxy \
  --ip <docker-ip> \
  -e POSTGRES_USER='<db-username>' \
  -e POSTGRES_PASSWORD='changeme' \
  -e POSTGRES_DB=postgres \
  -e PGDATA=/var/lib/postgresql/data \
  -v "$(pwd)/data/postgres/data:/var/lib/postgresql/data" \
  -v "$(pwd)/data/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
  -v "$(pwd)/data/postgres/certs/server.crt:/certs/server.crt:ro" \
  -v "$(pwd)/data/postgres/certs/server.key:/certs/server.key:ro" \
  -v "$(pwd)/data/postgres/certs/ca.crt:/certs/ca.crt:ro" \
  --health-cmd "pg_isready -U <db-username>" \
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
- No `--network-alias` flag and no `-p 5432:5432`: this container is deliberately reachable only from other containers on the `proxy` network, addressed by Docker's automatic container-name alias `postgres-db` (which is exactly the value configured in `postgres.ip`) — it is never exposed on the host's own network interface.
- **`--stop-signal SIGINT --stop-timeout 90`**: identical fix and identical reasoning to the `postgres` role. Docker's default `SIGTERM` is interpreted by PostgreSQL as a "smart" shutdown that waits indefinitely for every connected client to disconnect on its own; long-lived pooled connections from application containers never do, so the default 10-second stop timeout used to force a `SIGKILL` — an unclean crash that triggers WAL crash recovery and wipes `pg_stat_*` counters on every stop/restart. `SIGINT` requests PostgreSQL's "fast" shutdown instead: in-flight transactions are rolled back, a clean checkpoint is forced, and clients are disconnected by the server itself — normally finishing in a few seconds. `--stop-timeout 90` is a generous ceiling for a checkpoint under load, not the expected duration.

Then wait for the database to actually accept connections before treating the deploy as complete (the role does this automatically; `docker run` alone does not):

```bash
for i in $(seq 1 30); do
  docker exec postgres-db pg_isready -U <db-username> && break
  sleep 2
done
```

---

#### Step 8: Provision service users and databases (conditional)

**Purpose**: For every entry in `postgres_service_users`, create the PostgreSQL role (if it doesn't already exist), create its database, and grant it schema privileges. Only runs when `postgres_service_users` is non-empty.

```bash
DB_USER=<service-db-username>
DB_PASS='changeme'
DB_NAME=<service-db-name>

# Create the role only if it doesn't already exist
exists=$(docker exec postgres-db psql -U <db-username> -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'")
if [ "$(echo "$exists" | tr -d '[:space:]')" != "1" ]; then
  docker exec postgres-db psql -U <db-username> -c \
    "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}'"
fi

# Create the database (ignore "already exists")
docker exec postgres-db createdb -U <db-username> -O "${DB_USER}" "${DB_NAME}" || true

# Grant schema privileges
docker exec postgres-db psql -U <db-username> -d "${DB_NAME}" -c \
  "GRANT ALL ON SCHEMA public TO ${DB_USER}"
```

**Explanation**: This is functionally equivalent to what the separate `prepare_postgres` role does for the central `postgres` instance, but folded into `postgres_server` itself so this host's local databases are provisioned in the same run that deploys the container.

---

#### Step 9: Verify

**Purpose**: Confirms the deploy actually produced usable databases and that every expected cert file landed on disk. The role runs this every time, not just on first deploy.

```bash
# List databases
docker exec postgres-db psql -U <db-username> -c "\l"

# List tables in each service database
docker exec postgres-db psql -U <db-username> -d <service-db-name> -c "\dt"

# Confirm expected client cert files are present
ls ./data/certs
# expected: ca.crt, plus <client-name>.crt and <client-name>.key for every
# entry in postgres_tls_clients (matched against postgres_tls_client_base_dir)
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `postgres.static` | `172.20.0.8` | Static IP for `postgres-db` on the `proxy` network |
| `postgres.ip` | `postgres-db` | Hostname consumers connect to (Docker's automatic container-name alias — there is no explicit `--network-alias`) |
| `postgres.port` | `5432` | Port consumers connect to (not published to the host) |
| `postgres.adm_user` / `postgres.adm_pass` | `<db-username>` / `changeme` | Postgres superuser name/password (`POSTGRES_USER`/`POSTGRES_PASSWORD`) |
| `pgid` | `999` | GID the `postgres-db` container runs as; owns distributed client key files |
| `postgres_service_users` | `[]` | List of `{ user, password, db }` — roles/databases this role provisions directly |
| `postgres_tls_clients` | `[]` | List of `{ name, db_user, hosts: [...] }` — one entry per application needing a client cert |
| `postgres_tls_client_hosts` | `[]` | Fallback/global list of hosts to receive distributed client certs |
| `postgres_tls_client_base_dir` | `./data/certs` | Destination directory for CA cert + client cert/key on consumer hosts (also what `verify.yml` checks) |
| `postgres_tls_dir` | `./data/postgres/certs` | CA + server cert/key directory on this host |
| `postgres_tls_client_dir` | `./data/postgres/certs/clients` | Per-client cert/key directory on this host |
| `postgres_tls_ca_key` / `postgres_tls_ca_cert` / `postgres_tls_ca_serial` | `.../ca.key` / `.../ca.crt` / `.../ca.srl` | CA material paths |
| `postgres_tls_server_key` / `postgres_tls_server_cert` | `.../server.key` / `.../server.crt` | Server cert material paths |
| `postgres_migrate_local_dbs` | `[]` | Not consumed by any current task — reserved for a one-time migration switch |
| `postgres_migrate_source_host` | `primary_postgres` | Not consumed by any current task — vestigial, same migration-reference pattern as the `postgres` role's `postgres_migrate_*` vars |
| `user.name` / `user.group` | `<username>` / `docker` | Owner of created directories and `pg_hba.conf` |

### Templates & Configuration Files

**`templates/pg_hba.conf.j2` → `./data/postgres/pg_hba.conf`**

```
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
# All docker/LAN clients: SSL + client certificate required. pg_hba is
# first-match-wins top to bottom, so no broad password line may sit above
# these (that would make the client-cert requirement unreachable).
{% for ip in private_ips %}
hostssl all       all   {{ ip }}              cert clientcert=verify-full
{% endfor %}
hostssl all       all   {{ docker.subnet }}   cert clientcert=verify-full
```

Same loop-over-`private_ips` pattern as the `postgres` role's template, plus one extra fixed line for `docker.subnet`. The only structural difference is the absence of a password-auth exception block — see Step 6 and the differences table above.

> **Single-file bind-mount gotcha**: `container.yml` bind-mounts this file directly (`./data/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro`), and Ansible's `template` module rewrites a file by writing a new temp file and renaming it over the old path — a new inode, not an in-place edit. A single-file bind mount is attached to the inode that existed at container-start time, so after `pg_hba.conf` is re-templated, the *running* container keeps serving the **old** rules from its now-detached mount until the container itself is restarted (or the file is overwritten in place, preserving the inode — the template module doesn't do this by default). This is exactly why `container.yml` sets `notify: Restart PostgreSQL` on the template task: without that restart, a `pg_hba.conf` change (e.g. tightening or loosening an enforcement rule) silently has no effect on the live container. Reproducing this by hand: after editing `pg_hba.conf`, always follow with the stop+start sequence in the Handlers section below — never assume the edit alone is enough.

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Restart PostgreSQL` (`Stop PostgreSQL` + `Start PostgreSQL`, both `listen: Restart PostgreSQL`) | `pg_hba.conf` re-templated with different content | `sudo docker stop postgres-db && sudo docker start postgres-db` |

Identical handler shape to the `postgres` role: two separate tasks (`state: stopped` then `state: started`) rather than a single `docker restart`. The inline comment in `handlers/main.yml` explains why: on fuse-overlayfs hosts, `docker restart` races the stale graphdriver state and can leave the container with a broken rootfs mount — permanently unhealthy, `docker exec` failing with `setns`-style errors (the same mount-safety class of issue documented for `common`'s `docker-sock-rebind.service`, see `docs/update/common.md`). A plain stop followed by a separate start avoids that race and is safe on every host, not just fuse-overlayfs ones.

Because `stop_signal` is `SIGINT` (Step 7), the `Stop PostgreSQL` task performs a fast/clean shutdown rather than a smart one — it won't hang waiting on idle client connections. This handler is also what actually applies a `pg_hba.conf` change to the running container — see the single-file bind-mount gotcha under Templates & Configuration Files above.

---

## Verification

```bash
# Container is running and healthy
sudo docker ps --filter name=postgres-db
sudo docker inspect --format '{{.State.Health.Status}}' postgres-db

# Healthcheck manually
docker exec postgres-db pg_isready -U <db-username>

# TLS is enabled and enforced
docker exec postgres-db psql -U <db-username> -c "SHOW ssl;"

# Confirm the effective stop signal/timeout
docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db
# expect: SIGINT 90

# Confirm no host port is published
docker inspect --format '{{.NetworkSettings.Ports}}' postgres-db
# expect: empty/no 5432 mapping

# List databases / tables (mirrors verify.yml)
docker exec postgres-db psql -U <db-username> -c "\l"
docker exec postgres-db psql -U <db-username> -d <service-db-name> -c "\dt"

# From a client host on the proxy network, confirm mutual TLS is enforced
# (should be rejected — no client certificate presented)
psql "host=postgres-db port=5432 user=<db-username> dbname=postgres sslmode=require"

# ...and succeed with a valid client certificate
psql "host=postgres-db port=5432 user=<db-username> dbname=postgres sslmode=verify-full \
  sslcert=./data/certs/<client-name>.crt \
  sslkey=./data/certs/<client-name>.key \
  sslrootcert=./data/certs/ca.crt"
```

---

## Rollback / Uninstall

```bash
# Stop and remove the container (SIGINT/90s stop still applies — no data corruption on removal)
sudo docker stop postgres-db
sudo docker rm postgres-db

# WARNING: destroys all databases on this host — only if you intend to lose the data
rm -rf ./data/postgres
```

---

## Troubleshooting

**Container exits/restarts and `pg_stat_*` counters reset unexpectedly**
Check `docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db` — if it does not read `SIGINT 90`, the container was started without the flags from Step 7 and falls back to Docker's default `SIGTERM`/10s. Recreate with `--stop-signal SIGINT --stop-timeout 90`.

**A client certificate is rejected even though the cert/CA look correct**
Check whether the client is actually hitting the `hostssl … cert clientcert=verify-full` line at all — remember `pg_hba.conf` is first-match-wins (Step 6). If any earlier line in the file matches the same TYPE/DATABASE/USER/ADDRESS combination first (e.g. a mistakenly-broadened address range), the cert requirement on the later line is never reached and the connection is evaluated against the wrong rule instead.

**Edited `pg_hba.conf` but the container's behavior didn't change**
This is the single-file bind-mount gotcha (see Templates & Configuration Files above): editing the file on disk doesn't affect a container that already has it bind-mounted, because `template`/most editors replace the file via a new inode. Restart the container (`docker stop postgres-db && docker start postgres-db`, or trigger the `Restart PostgreSQL` handler) after every `pg_hba.conf` change.

**New client added to `postgres_tls_clients` can't connect over TLS**
Since every non-loopback line in `pg_hba.conf` now requires `clientcert=verify-full` (no password fallback like `postgres`'s pgAdmin exception), a client that hasn't yet received its cert/key (Steps 4–5) or whose `sslmode` isn't at least `require` cannot connect at all — there's no degraded password-only path to fall back to. Confirm the cert was generated and distributed, and that the client's connection string actually presents it.

**"role ... already exists" / "database ... already exists" during Step 8**
`create_service_users.yml` already guards against this (checks `pg_roles` before creating, and treats `createdb`'s "already exists" stderr as non-fatal) — running it again is safe. Manually, just skip the `CREATE ROLE`/`createdb` step for that entry.

**Verify step fails: "Missing client cert files in ./data/certs"**
A client listed in `postgres_tls_clients` is missing its cert/key (or `ca.crt`) under `postgres_tls_client_base_dir`. Confirm that host is actually present in that client's `hosts` list (or in the global `postgres_tls_client_hosts`), then re-run Steps 4–5 for that client.

**"SSL SYSCALL error: EOF detected" / certificate verification errors**
Same causes as the `postgres` role: client not requesting TLS at all when it should, or a `CN`/SAN mismatch. Verify with `openssl verify -CAfile ca.crt <client>.crt` and `openssl x509 -in server.crt -noout -text | grep -A1 'Subject Alternative Name'` (expect the host IP, `localhost`, and `postgres-db`).

> Related: the `postgres` role documents the shared central database on `primary_postgres` — same mutual-TLS enforcement structure, but with a published port, a network alias (`postgres`), and a password-auth exception carved out for its pgAdmin client. See that manual for the counterpart deployment.
