# Role: sql

## Purpose

This role deploys MariaDB database server containers and an Adminer web-based database management UI. It loops over the `db_server` inventory list, creating one MariaDB container per entry (supporting multiple independent instances on the same host with different static IPs). It then deploys a single Adminer instance that can connect to any of them.

In this project, the MariaDB instances are used as database backends for Ghost CMS blog sites. The Adminer interface is protected behind a Traefik middleware chain (`chain-tunnel`) that restricts access.

> **No replication.** The role sets up no replication topology: it passes no `--server-id`, no `--log-bin`, and configures no source/replica relationship. Every `db_server` entry is an independent standalone instance. A replica entry was removed after it was found running for weeks holding nothing but system databases.

## Prerequisites

- `common` and `traefik` roles must have run.
- The `db_server` list and `adminer` variable block must be defined in `host_vars/primary_server.yml`.
- Named Docker volumes referenced by `db_server[].volume` must either be pre-existing or will be auto-created by Docker on first run.
- The proxy Docker network must exist.

## Manual Execution Guide

### Overview

1. Start one MariaDB container per entry in `db_server`.
2. Start the Adminer container.

---

### Step-by-Step Instructions

#### Step 1: Start MariaDB database containers

**Purpose**: Each Ghost CMS site needs its own database server. The containers use named Docker volumes for data persistence and set a UTF-8 server charset so Ghost content round-trips correctly.

For each entry in `db_server`, run:

```bash
sudo docker run -d \
  --name <db-name> \
  --restart unless-stopped \
  --network proxy \
  --ip <db-static-ip> \
  -e TZ=Europe/Belgrade \
  -e MARIADB_ROOT_PASSWORD=<db-pass> \
  -v <db-volume>:/var/lib/mysql \
  --health-cmd 'healthcheck.sh --connect --innodb_initialized' \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 30s \
  mariadb:11 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci
```

**Explanation of MariaDB startup flags**:

| Flag | Value | Meaning |
|------|-------|---------|
| `--character-set-server` | `utf8mb4` | Server default charset; `utf8mb4` covers the full Unicode range including emoji |
| `--collation-server` | `utf8mb4_unicode_ci` | Case-insensitive Unicode collation matching the charset |

The healthcheck uses `healthcheck.sh`, shipped by the official image: `--connect` proves it accepts connections and `--innodb_initialized` proves startup/recovery has finished.

**Using default values from `host_vars/primary_server.yml`**:

```bash
sudo docker run -d \
  --name skup-ghost-db \
  --restart unless-stopped \
  --network proxy \
  --ip <static-ip> \
  -e TZ=Europe/Belgrade \
  -e MARIADB_ROOT_PASSWORD=<db-password> \
  -v ServerDataBase:/var/lib/mysql \
  mariadb:11 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci
```

> **Note**: This role configures **no replication**. There is no `--server-id`, no binary logging and no source/replica setup; each `db_server` entry is an independent instance. A `mariadb-replica` entry and its `configure_replica.yml` task were removed after the container was found up and "healthy" for weeks while holding only system databases — the task had never been wired into `main.yml`, and was itself incomplete. If you add replication later, verify it with `SHOW SLAVE STATUS\G` rather than trusting container health.

---

#### Step 2: Start the Adminer container

**Purpose**: Adminer is a lightweight, single-file PHP database management tool. It allows browsing, querying, and managing the MariaDB instances through a web UI.

```bash
sudo docker run -d \
  --name adminer \
  --restart unless-stopped \
  --network proxy \
  --ip <adminer-static-ip> \
  -e TZ=Europe/Belgrade \
  --label traefik.enable=true \
  --label "traefik.http.routers.adminer.entrypoints=https" \
  --label "traefik.http.routers.adminer.rule=Host(\`<adminer-domain>\`)" \
  --label "traefik.http.routers.adminer.tls=true" \
  --label "traefik.http.routers.adminer.middlewares=chain-tunnel@file" \
  --label "traefik.http.services.adminer.loadbalancer.server.port=<adminer-port>" \
  adminer
```

The `chain-tunnel@file` middleware is a Traefik middleware chain defined in a dynamic configuration file by the `traefik` role. It restricts access to Adminer — typically allowing only specific IP ranges or requiring authentication.

---

## Configuration Reference

### Variables (from `host_vars/primary_server.yml`)

**`db_server` list structure**:

```yaml
db_server:
  - name: "skup-ghost-db"
    user: "root"
    admin: "root"
    pass: "<root-password>"
    volume: "ServerDataBase"
```

| Field | Description |
|-------|-------------|
| `name` | Container name and Docker hostname. Also the key looked up in the `ip` dict for the container's static IP, so every entry needs a matching `ip[<name>]` |
| `user` / `admin` | Account names used by the `db_backup` role when dumping this instance |
| `pass` | MariaDB root password (`MARIADB_ROOT_PASSWORD`) |
| `volume` | Named Docker volume for `/var/lib/mysql` data |

> Entries here are also consumed by the `db_backup` role — `db_backup_mysql_servers` defaults to `db_server`, so adding an instance automatically enrols it in backups, and removing one drops it.

**`adminer` variable block**:

| Variable | Example | Description |
|----------|---------|-------------|
| `adminer.domain` | `<adminer-host>.<private-subzone>.your-domain.com` | Adminer FQDN (private subzone — not published to public DNS) |
| `adminer.host` | `Host(\`<adminer-host>.<private-subzone>.your-domain.com\`)` | Traefik routing rule |
| `adminer.port` | `8000` | Internal Adminer port |
| `adminer.static` | `<static-ip>` | Static IP on proxy network |

---

## Handlers & Service Management

This role has no Ansible handlers. Containers restart automatically via Docker's `unless-stopped` policy.

To manually restart an instance:

```bash
sudo docker restart skup-ghost-db
sudo docker restart adminer
```

---

## Verification

```bash
# Check all containers are running and healthy
sudo docker ps --filter name=skup-ghost-db --filter name=adminer \
  --format '{{.Names}}\t{{.Status}}'

# Test connectivity and list databases
sudo docker exec -it skup-ghost-db mariadb -u root -p<password> -e "SHOW DATABASES;"

# Check Adminer is accessible
curl -sk https://<adminer-domain>/ | head -5
```

> Container health is not evidence that a database holds anything. `SHOW DATABASES;`
> is the check that matters — an empty instance reports `healthy` indefinitely.

---

## Rollback / Uninstall

```bash
# Stop and remove containers
sudo docker stop skup-ghost-db adminer
sudo docker rm skup-ghost-db adminer

# Remove named volumes (WARNING: destroys all database data)
sudo docker volume rm ServerDataBase
```

Do not remove volumes unless you have a backup. Database data lives entirely within the Docker named volumes.

---

## Troubleshooting

**MariaDB container exits immediately on startup**
Check logs: `sudo docker logs skup-ghost-db`. Common causes: invalid startup flags, volume permission issues, or a corrupt data directory.

**Container never becomes healthy**
The healthcheck runs `healthcheck.sh --connect --innodb_initialized`. A container stuck in `starting` past the 30s start period usually means InnoDB recovery is still running on a large or unclean data directory — check the logs before restarting it, since a restart mid-recovery makes it worse.

**Cannot connect from the Ghost container**
Verify both containers are on the `proxy` network: `sudo docker network inspect proxy`. Ensure Ghost is using the correct static IP of the database container as its host.

**Adminer returns 403 Forbidden**
The `chain-tunnel@file` middleware is blocking access. This is expected — ensure your IP is in the allowlist or disable the middleware temporarily for debugging. Check Traefik logs for middleware decisions.
