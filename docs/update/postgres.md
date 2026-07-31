# Role: postgres

## Purpose

Deploys the central PostgreSQL server as a **Docker container** (`postgres-db`, image `pgvector/pgvector:pg18`) on the `primary_postgres` host, with TLS enabled and mutual-TLS (client-certificate) authentication required for every application connection. This is the shared database backend most other roles in this repository connect to (Authelia, the `*arr` stack, Seerr, etc. — see `../CLAUDE.md` "Data-store topology").

The role does three things, in order:

1. **`certs.yml`** — generates a private CA plus a server key/certificate for `postgres-db` itself.
2. **`client_certs.yml`** — generates a client key/certificate per consuming application (`postgres_tls_clients`) and distributes the CA cert + client cert/key to each host that needs to connect (`postgres_tls_client_hosts`).
3. **`container.yml`** — renders `pg_hba.conf` and deploys the `postgres-db` container with TLS and `clientcert=verify-full` enforced.

> `enable_tls.yml` also exists in `tasks/` but is **not** invoked by `main.yml` — it is a leftover from an earlier bare-metal PostgreSQL 15 (`/etc/postgresql/15/main`) setup that this role has since replaced with the Docker deployment below. The `postgres_migrate_*` variables in `defaults/main.yml` (source paths under `/etc/postgresql/15/main/certs`) are likewise vestigial, kept only as a reference for the one-time PG15 → container migration. Neither is part of the current execution path; flagging here in case a human wants to delete them.

## Prerequisites

- The `common` role must have already run on the target host (creates the `proxy` Docker network and the `./data` working directory).
- `openssl` must be available on the target host (the role does not install it itself in the active task path).
- Docker Engine must be installed and running.
- Variables: `postgres.static`, `postgres.adm_user`, `postgres.adm_pass`, `pgid`, `postgres_tls_clients`, `postgres_tls_client_hosts`, `private_ips` (from `group_vars/all.yml`), `user.name`, `user.group`.

## Manual Execution Guide

### Overview

1. Create `./data/postgres/certs/` and `./data/postgres/certs/clients/`.
2. Generate a CA key + self-signed CA certificate.
3. Generate the server key, CSR (with a `subjectAltName` extension), and sign the server certificate with the CA.
4. Set ownership/permissions on the CA and server key/cert (server key must be owned by uid/gid `999`, the postgres image's internal user).
5. For each consuming application: generate a client key + CSR (CN = DB username) and sign it with the CA.
6. Distribute the CA cert + each client's cert/key to the application host's `./data/certs/` directory.
7. Render `pg_hba.conf` from the template (mutual-TLS required for the application subnets).
8. Deploy the `postgres-db` container with TLS enabled and `pg_hba.conf` bind-mounted in.

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

**Explanation**: `./data/postgres` is the role's working directory (relative to wherever the playbook is run from — normally the deploy user's home directory). `0750` keeps the certs directory closed to other unprivileged users while still readable by the deploy user's group.

---

#### Step 2: Generate the CA key and certificate

**Purpose**: A private Certificate Authority signs both the server certificate and every client certificate, so PostgreSQL can verify client identity via `clientcert=verify-full`.

```bash
# CA private key (4096-bit RSA)
openssl genrsa -out ./data/postgres/certs/ca.key 4096
chmod 0600 ./data/postgres/certs/ca.key
chown <username>:docker ./data/postgres/certs/ca.key

# Self-signed CA certificate, valid 10 years
openssl req -x509 -new -nodes \
  -key ./data/postgres/certs/ca.key \
  -sha256 -days 3650 \
  -subj "/CN=postgres-ca" \
  -out ./data/postgres/certs/ca.crt
```

**Explanation**: `-nodes` skips passphrase-protecting the CA key (the role stores it as a regular file, not encrypted). `-days 3650` gives a 10-year validity window. `CN=postgres-ca` is just a label; it does not need to resolve to anything.

---

#### Step 3: Generate the server key and certificate

**Purpose**: The certificate `postgres-db` presents to connecting clients during the TLS handshake.

```bash
# Server private key (2048-bit RSA)
openssl genrsa -out ./data/postgres/certs/server.key 2048

# SAN extension file — CN alone is not enough for modern TLS clients
cat > ./data/postgres/certs/server_ext.cnf <<'EOF'
[v3_req]
subjectAltName = IP:<ip-address>,DNS:localhost
EOF

# Server CSR (CN = the postgres host's address)
openssl req -new \
  -key ./data/postgres/certs/server.key \
  -subj "/CN=<ip-address>" \
  -out ./data/postgres/certs/server.csr

# Sign the server certificate with the CA, embedding the SAN
openssl x509 -req \
  -in ./data/postgres/certs/server.csr \
  -CA ./data/postgres/certs/ca.crt -CAkey ./data/postgres/certs/ca.key -CAcreateserial \
  -out ./data/postgres/certs/server.crt -days 3650 -sha256 \
  -extfile ./data/postgres/certs/server_ext.cnf -extensions v3_req
```

**Explanation**: `<ip-address>` is the value of `ansible_host` for `primary_postgres` (its reachable IP). The `subjectAltName` includes both that IP and `DNS:localhost`, so clients connecting either by IP or via `localhost` (e.g. `psql` run on the postgres host itself) pass hostname verification.

Set final permissions — note the server key is owned by uid/gid `999` (the `postgres` user/group *inside* the `pgvector/pgvector` image), not the deploy user, because the container reads it directly:

```bash
chown 999:999 ./data/postgres/certs/server.key
chmod 0600 ./data/postgres/certs/server.key

chown root:root ./data/postgres/certs/server.crt
chmod 0644 ./data/postgres/certs/server.crt
```

---

#### Step 4: Generate a client certificate per consuming application

**Purpose**: Every application that connects to PostgreSQL authenticates with its own client certificate; `pg_hba.conf` requires `clientcert=verify-full`, which checks that the certificate's `CN` matches the PostgreSQL role name being used to log in.

Repeat for each entry in `postgres_tls_clients` (e.g. an application named `authelia` connecting as DB user `authelia`):

```bash
CLIENT=authelia          # postgres_tls_clients[].name
DB_USER=<db-username>    # postgres_tls_clients[].db_user

# One shared serial file across all clients (first run only)
[ -f ./data/postgres/certs/ca.srl ] || printf '01\n' > ./data/postgres/certs/ca.srl
chown root:root ./data/postgres/certs/ca.srl
chmod 0600 ./data/postgres/certs/ca.srl

# Client private key
openssl genrsa -out ./data/postgres/certs/clients/${CLIENT}.key 2048

# Client CSR — CN MUST equal the PostgreSQL username the client authenticates as
openssl req -new \
  -key ./data/postgres/certs/clients/${CLIENT}.key \
  -subj "/CN=${DB_USER}" \
  -out ./data/postgres/certs/clients/${CLIENT}.csr

# Sign with the CA
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

#### Step 5: Distribute the CA cert and client certs to consuming hosts

**Purpose**: Each application host needs the CA cert (to verify the server) and its own client cert + key (to authenticate itself), placed under `postgres_tls_client_base_dir` (default `./data/certs`) on that host.

> **Never list a host that runs its own `postgres_server`.** That role writes the same
> `./data/certs/ca.crt` with a *different* CA that happens to share the subject
> `CN=postgres-ca`, so the two distributions clobber each other and the last playbook run
> wins. See `postgres_server.md`.

```bash
# On each host listed in postgres_tls_client_hosts for this client:
ssh <username>@<target-host> "mkdir -p ./data/certs && chmod 0755 ./data/certs"

scp ./data/postgres/certs/ca.crt              <username>@<target-host>:./data/certs/ca.crt
scp ./data/postgres/certs/clients/${CLIENT}.crt <username>@<target-host>:./data/certs/${CLIENT}.crt
scp ./data/postgres/certs/clients/${CLIENT}.key <username>@<target-host>:./data/certs/${CLIENT}.key

ssh <username>@<target-host> "chmod 0644 ./data/certs/ca.crt ./data/certs/${CLIENT}.crt && \
  chown root:<pgid> ./data/certs/${CLIENT}.key && chmod 0640 ./data/certs/${CLIENT}.key"
```

**Explanation**: The client key is group-readable by `pgid` (default `999`) rather than world-readable, since most consuming containers also run as uid/gid `999`. `postgres_tls_clients[].hosts` in the inventory controls which hosts receive which client's cert — a client can be distributed to more than one host (e.g. a service with an HA standby).

---

#### Step 6: Render `pg_hba.conf`

**Purpose**: PostgreSQL's host-based authentication file. Controls which connections are allowed and by what method.

```bash
mkdir -p ./data/postgres
cat > ./data/postgres/pg_hba.conf <<'EOF'
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
# pgAdmin only - TLS + password (it has no client certificate). It reaches
# postgres via the host IP, so it also hairpins through the docker gateway.
hostssl all       all   <pgadmin-docker-ip>/32     scram-sha-256
hostssl all       all   <docker-gateway-ip>/32     scram-sha-256
# Everything else: SSL + client certificate required
hostssl all       all   <private-subnet-1>    cert clientcert=verify-full
hostssl all       all   <private-subnet-2>    cert clientcert=verify-full
hostssl all       all   <single-host-ip>/32   cert clientcert=verify-full
hostssl all       all   <docker-subnet>       cert clientcert=verify-full
EOF
chown <username>:docker ./data/postgres/pg_hba.conf
chmod 0644 ./data/postgres/pg_hba.conf
```

**Explanation**: `pg_hba.conf` is **first-match-wins, top to bottom** — the narrow password exceptions for pgAdmin (`pgadmin.static` and the docker gateway, which pgAdmin's hairpin-NAT'd connections arrive from) must sit **above** the broad `cert clientcert=verify-full` lines, and no broad password line may sit above those. One `hostssl … cert` line is generated per CIDR in `private_ips` (`group_vars/all.yml`) plus one for `docker.subnet` — every client from those ranges must present a valid client certificate signed by the role's CA. `local`/`127.0.0.1` connections stay password-based (`trust`/`scram-sha-256`) since they never leave the container. (An earlier revision had a broad `172.0.0.0/8` password line above the cert lines, which made the client-cert requirement unreachable for docker-network clients — do not reintroduce it.)

> **Every ADDRESS needs a prefix length.** PostgreSQL parses the ADDRESS field three ways: containing `/` → CIDR, and the next token is the METHOD; a **bare** numeric IP → the next token is required to be a separate netmask (the legacy `address netmask method` form); non-numeric (`all`, `samenet`, a hostname) → the next token is the METHOD. A single host written without `/32` therefore makes the parser read the following `cert` as a netmask and the server refuses to start:
>
> ```
> LOG:  invalid IP mask "cert": Name or service not known
> FATAL:  could not load /etc/postgresql/pg_hba.conf
> ```
>
> `private_ips` is shared with the Traefik/CrowdSec whitelist templates, which accept bare IPs happily — a single host added there for whitelisting breaks only pg_hba. The template appends `/32` to any entry lacking a prefix; when writing the file by hand, do the same.

> **Bind-mount gotcha**: the container mounts `pg_hba.conf` as a single-file bind. Replacing the file with `install`/`mv` (new inode) silently severs the mount — the container keeps the old content even after `pg_reload_conf()`. Overwrite in place (`cat new > pg_hba.conf`) and reload, or restart the container after an inode-changing replace.

---

#### Step 7: Deploy the PostgreSQL container

**Purpose**: Runs PostgreSQL itself, with the certs and `pg_hba.conf` from the previous steps wired in via `-c` command-line flags rather than baked into the image.

```bash
sudo docker run -d \
  --name postgres-db \
  --restart unless-stopped \
  --stop-signal SIGINT \
  --stop-timeout 90 \
  --network proxy \
  --ip <docker-ip> \
  --network-alias postgres \
  -p 5432:5432 \
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
- `--network proxy --ip <docker-ip> --network-alias postgres` attaches the container to the shared `proxy` bridge network at its static IP (`postgres.static`) and registers the DNS alias `postgres`, so other containers on `proxy` connect via the hostname `postgres` rather than a hardcoded IP.
- `-p 5432:5432` publishes Postgres on the host as well, for connections from outside the `proxy` network (e.g. pgAdmin, other hosts' Alloy agents, or manual `psql` from the host itself).
- The three bind-mounted cert files plus `pg_hba.conf` are read-only (`:ro`) — the container never writes back to them.
- The `-c ssl=on … -c hba_file=…` flags are appended to the `postgres` entrypoint command, overriding the image's baked-in defaults without needing a custom `postgresql.conf`.
- **`--stop-signal SIGINT --stop-timeout 90`**: this is the important one. Docker's default stop signal is `SIGTERM`, which PostgreSQL interprets as a **"smart" shutdown** — it waits indefinitely for every currently-connected client to disconnect on its own before exiting. The `*arr` stack (Sonarr/Radarr/Lidarr/etc.) and other services hold idle pooled connections open, so a smart shutdown effectively never completes on its own. With Docker's default 10-second stop timeout, that meant every `docker stop`/`docker restart` ended in Docker giving up and sending `SIGKILL`, which PostgreSQL treats as an unclean crash — triggering WAL crash recovery on the next start and wiping `pg_stat_*` counters. `SIGINT` instead requests a **"fast" shutdown**: Postgres rolls back in-flight transactions, forces a clean checkpoint, and disconnects clients itself, typically finishing in a few seconds. The `--stop-timeout 90` is a generous backstop in case a checkpoint under load takes longer than usual — it is a ceiling, not the expected duration.
- Real `POSTGRES_PASSWORD` / `POSTGRES_USER` values come from `postgres.adm_pass` / `postgres.adm_user` in the inventory — never hardcode real credentials when reproducing this manually.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `postgres.static` | `172.20.0.8` | Static IP for `postgres-db` on the `proxy` network |
| `postgres.adm_user` | `<db-username>` | Postgres superuser name (`POSTGRES_USER`) |
| `postgres.adm_pass` | `changeme` | Postgres superuser password (`POSTGRES_PASSWORD`) |
| `pgid` | `999` | GID the `postgres-db` container runs as; owns distributed client key files on consumer hosts |
| `postgres_tls_clients` | `[]` | List of `{ name, db_user, hosts: [...] }` — one entry per application needing a client cert |
| `postgres_tls_client_hosts` | `[]` | Fallback/global list of hosts to receive distributed client certs |
| `postgres_tls_client_base_dir` | `./data/certs` | Destination directory for CA cert + client cert/key on **consumer** hosts |
| `postgres_tls_dir` | `./data/postgres/certs` | CA + server cert/key directory on the postgres host |
| `postgres_tls_client_dir` | `./data/postgres/certs/clients` | Per-client cert/key directory on the postgres host |
| `postgres_tls_ca_key` / `postgres_tls_ca_cert` / `postgres_tls_ca_serial` | `.../ca.key` / `.../ca.crt` / `.../ca.srl` | CA material paths |
| `postgres_tls_server_key` / `postgres_tls_server_cert` | `.../server.key` / `.../server.crt` | Server cert material paths |
| `postgres_migrate_source_host` | `primary_postgres` | Vestigial — source host alias for the one-time PG15→container migration (not used by the active task path) |
| `postgres_migrate_tls_dir` / `postgres_migrate_tls_ca_cert` / `postgres_migrate_tls_ca_key` / `postgres_migrate_tls_ca_serial` / `postgres_migrate_tls_client_dir` | `/etc/postgresql/15/main/certs/...` | Vestigial — paths on the old bare-metal PG15 host, referenced only by the unused `enable_tls.yml`; kept as migration reference |
| `private_ips` | list of CIDRs | (from `group_vars/all.yml`) Application subnets; one `hostssl … clientcert=verify-full` line per entry in `pg_hba.conf` |
| `user.name` / `user.group` | `<username>` / `docker` | Owner of created directories and `pg_hba.conf` |

### Templates & Configuration Files

**`templates/pg_hba.conf.j2` → `./data/postgres/pg_hba.conf`**

Renders PostgreSQL's host-based authentication rules:

```
# TYPE  DATABASE  USER  ADDRESS              METHOD
local   all       all                         trust
host    all       all   127.0.0.1/32          scram-sha-256
hostssl all       all   {{ ip['pgadmin'] }}/32   scram-sha-256
hostssl all       all   {{ docker.gateway }}/32   scram-sha-256
{% for cidr in private_ips %}
hostssl all       all   {{ cidr if '/' in cidr else cidr ~ '/32' }}   cert clientcert=verify-full
{% endfor %}
hostssl all       all   {{ docker.subnet }}   cert clientcert=verify-full
```

The templated loop is the only dynamic part — it expands to one `hostssl` line per CIDR in `private_ips`, each requiring TLS plus a client certificate whose `CN` matches the connecting role. The loop variable is `cidr`, not `ip`, because `ip` is the static-address dict used by the pgAdmin exception line above it.

The `'/' in cidr` guard is what keeps a prefix-less `private_ips` entry from producing `invalid IP mask "cert"` at server startup — see the ADDRESS-parsing note in Step 6. `private_ips` is shared with the Traefik/CrowdSec whitelists (which accept bare IPs) and is appended to at runtime with a bare public IP by `roles/traefik/tasks/environment.yml`, so the normalisation lives here rather than in the inventory.

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Restart PostgreSQL` | `pg_hba.conf` changes (re-templated with different content) | `sudo docker restart postgres-db` |

**Explanation**: the handler is a `community.docker.docker_container` task with `state: started, restart: true` against the existing `postgres-db` container — it does not recreate the container, just restarts it so PostgreSQL re-reads `pg_hba.conf` (bind-mounted, so the file itself doesn't need to change inside the container). Because `stop_signal` is `SIGINT` (see Step 7 above), this restart performs a fast/clean shutdown rather than a smart one — it will not hang waiting on idle client connections.

---

## Verification

```bash
# Container is running and healthy
sudo docker ps --filter name=postgres-db
sudo docker inspect --format '{{.State.Health.Status}}' postgres-db

# Healthcheck manually
docker exec postgres-db pg_isready -U <db-username>

# TLS is enabled
docker exec postgres-db psql -U <db-username> -c "SHOW ssl;"

# Confirm the effective stop signal/timeout
docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db
# expect: SIGINT 90

# From a client host, confirm mutual TLS is enforced (should fail without a client cert)
psql "host=postgres port=5432 user=<db-username> dbname=postgres sslmode=require"

# ...and succeed with a valid client certificate
psql "host=postgres port=5432 user=<db-username> dbname=postgres sslmode=verify-ca \
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

# WARNING: destroys all databases — only do this if you intend to lose the data
rm -rf ./data/postgres
```

To temporarily disable TLS enforcement without tearing anything down, edit `./data/postgres/pg_hba.conf`, change the `hostssl … cert clientcert=verify-full` lines to `host … scram-sha-256`, and restart:

```bash
sudo docker restart postgres-db
```

---

## Troubleshooting

**Container exits/restarts and `pg_stat_*` counters reset unexpectedly**
Check `docker inspect --format '{{.Config.StopSignal}} {{.Config.StopTimeout}}' postgres-db` — if it does not read `SIGINT 90`, the container was started without the flags from Step 7 and is falling back to Docker's default `SIGTERM`/10s, which forces an unclean `SIGKILL` under load from long-lived client pools. Recreate the container with `--stop-signal SIGINT --stop-timeout 90`.

**`docker stop postgres-db` hangs for a long time**
With `SIGINT` this should resolve in a few seconds under normal load. If it consistently runs close to the 90s ceiling, check for a large checkpoint backlog (`SHOW checkpoint_timeout;`, `pg_stat_bgwriter`) or an unusually large `shared_buffers` that takes long to flush.

**"SSL SYSCALL error: EOF detected" / "server does not support SSL"**
The client is not requesting TLS. Add `sslmode=require` (or stronger) to the connection string. Confirm the container is actually running with `-c ssl=on` (`docker inspect postgres-db` → `Config.Cmd`).

**"certificate verify failed" / "connection requires a valid client certificate"**
The client's certificate `CN` doesn't match the PostgreSQL role it's connecting as, isn't signed by this CA, or is missing/expired. Verify with `openssl verify -CAfile ca.crt <client>.crt`, and confirm the CN with `openssl x509 -in <client>.crt -noout -subject`. Re-issue from Step 4 if needed.

**"no pg_hba.conf entry for host ..."**
The connecting IP isn't covered by any line in `pg_hba.conf` — its subnet is missing from `private_ips` in `group_vars/all.yml`. Add the CIDR and re-render (Step 6), then restart the container.

**New client can't connect after `postgres_tls_clients` update**
Client certs are only generated/distributed when the role runs `client_certs.yml` — `openssl ... creates: ...` tasks are idempotent per-file, so adding a new entry to `postgres_tls_clients` and re-running the role generates just the new client's cert without touching existing ones. Manually, repeat Steps 4–5 for the new client only.
