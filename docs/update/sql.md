# Role: sql

## Purpose

This role deploys MySQL 8 database server containers and an Adminer web-based database management UI. It loops over the `db_server` inventory list, creating one MySQL container per entry (supporting multiple independent MySQL instances on the same host with different static IPs). It then deploys a single Adminer instance that can connect to any of them.

In this project, the MySQL instances are used as database backends for Ghost CMS blog sites. The Adminer interface is protected behind a Traefik middleware chain (`chain-tunnel`) that restricts access.

## Prerequisites

- `common` and `traefik` roles must have run.
- The `db_server` list and `adminer` variable block must be defined in `host_vars/primary_server.yml`.
- Named Docker volumes referenced by `db_server[].volume` must either be pre-existing or will be auto-created by Docker on first run.
- The proxy Docker network must exist.

## Manual Execution Guide

### Overview

1. Start one MySQL container per entry in `db_server`.
2. Start the Adminer container.

---

### Step-by-Step Instructions

#### Step 1: Start MySQL database containers

**Purpose**: Each Ghost CMS site needs its own MySQL database server. The containers use named Docker volumes for data persistence, have binary logging enabled for replication readiness, and use `mysql-native-password` authentication for compatibility.

For each entry in `db_server`, run:

```bash
sudo docker run -d \
  --name <db-name> \
  --restart unless-stopped \
  --network proxy \
  --ip <db-static-ip> \
  -e TZ=Europe/Belgrade \
  -e MYSQL_ROOT_PASSWORD=<db-pass> \
  -v <db-volume>:/var/lib/mysql \
  mysql:8.4.1 \
  --mysql-native-password=ON \
  --server-id=<db-id> \
  --log-bin=mysql-bin \
  --binlog-format=row
```

**Explanation of MySQL startup flags**:

| Flag | Value | Meaning |
|------|-------|---------|
| `--mysql-native-password=ON` | ON | Enables the legacy `mysql_native_password` authentication plugin, required by many older client libraries |
| `--server-id` | Unique integer per instance | Identifies this server in a replication topology; must be unique across all servers |
| `--log-bin=mysql-bin` | `mysql-bin` | Enables binary logging with the given filename prefix, required for replication |
| `--binlog-format=row` | `row` | Uses row-based binary logging — replicates individual row changes, not SQL statements |

**Using default values from `host_vars/primary_server.yml`**:

Instance 1 — `skup-ghost-db`:
```bash
sudo docker run -d \
  --name skup-ghost-db \
  --restart unless-stopped \
  --network proxy \
  --ip <static-ip-1> \
  -e TZ=Europe/Belgrade \
  -e MYSQL_ROOT_PASSWORD=<db-password> \
  -v ServerDataBase:/var/lib/mysql \
  mysql:8.4.1 \
  --mysql-native-password=ON \
  --server-id=1 \
  --log-bin=mysql-bin \
  --binlog-format=row
```

Instance 2 — `mysql-replica`:
```bash
sudo docker run -d \
  --name mysql-replica \
  --restart unless-stopped \
  --network proxy \
  --ip <static-ip-2> \
  -e TZ=Europe/Belgrade \
  -e MYSQL_ROOT_PASSWORD=<db-password> \
  -v ServerDataBaseReplica:/var/lib/mysql \
  mysql:8.4.1 \
  --mysql-native-password=ON \
  --server-id=2 \
  --log-bin=mysql-bin \
  --binlog-format=row
```

> **Note**: The replica configuration task (`configure_replica.yml`) is currently commented out in the playbook. Replication is not automatically configured — the containers are only prepared for replication with correct server IDs and binary logging.

---

#### Step 2: Start the Adminer container

**Purpose**: Adminer is a lightweight, single-file PHP database management tool. It allows browsing, querying, and managing the MySQL instances through a web UI.

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
    id: "1"
    pass: "<root-password>"
    volume: "ServerDataBase"
    static: "<static-ip-1>"
  - name: "mysql-replica"
    id: "2"
    pass: "<root-password>"
    volume: "ServerDataBaseReplica"
    static: "<static-ip-2>"
```

| Field | Description |
|-------|-------------|
| `name` | Container name and Docker hostname |
| `id` | MySQL server-id (must be unique) |
| `pass` | MySQL root password |
| `volume` | Named Docker volume for `/var/lib/mysql` data |
| `static` | Static IP on the proxy network |

**`adminer` variable block**:

| Variable | Example | Description |
|----------|---------|-------------|
| `adminer.domain` | `baza.your-domain.com` | Adminer FQDN |
| `adminer.host` | `Host(\`baza.your-domain.com\`)` | Traefik routing rule |
| `adminer.port` | `8000` | Internal Adminer port |
| `adminer.static` | `<static-ip>` | Static IP on proxy network |

---

## Handlers & Service Management

This role has no Ansible handlers. Containers restart automatically via Docker's `unless-stopped` policy.

To manually restart either MySQL instance:

```bash
sudo docker restart skup-ghost-db
sudo docker restart mysql-replica
sudo docker restart adminer
```

---

## Verification

```bash
# Check all containers are running
sudo docker ps | grep -E 'skup-ghost-db|mysql-replica|adminer'

# Test MySQL connectivity (from inside the proxy network, or via another container)
sudo docker exec -it skup-ghost-db mysql -u root -p<password> -e "SHOW DATABASES;"

# Check binary logging is active
sudo docker exec -it skup-ghost-db mysql -u root -p<password> -e "SHOW BINARY LOGS;"

# Check Adminer is accessible
curl -sk https://<adminer-domain>/ | head -5
```

---

## Rollback / Uninstall

```bash
# Stop and remove containers
sudo docker stop skup-ghost-db mysql-replica adminer
sudo docker rm skup-ghost-db mysql-replica adminer

# Remove named volumes (WARNING: destroys all database data)
sudo docker volume rm ServerDataBase ServerDataBaseReplica
```

Do not remove volumes unless you have a backup. MySQL data is entirely within the Docker named volumes.

---

## Troubleshooting

**MySQL container exits immediately on startup**
Check logs: `sudo docker logs skup-ghost-db`. Common causes: invalid startup flags (check MySQL version compatibility), volume permission issues, or a corrupt data directory.

**Cannot connect to MySQL from Ghost container**
Verify both containers are on the `proxy` network: `sudo docker network inspect proxy`. Ensure Ghost is using the correct static IP of the MySQL container as the database host.

**Adminer returns 403 Forbidden**
The `chain-tunnel@file` middleware is blocking access. This is expected — ensure your IP is in the allowlist or disable the middleware temporarily for debugging. Check Traefik logs for middleware decisions.

**`--mysql-native-password` flag causes a warning**
In MySQL 8.4+, `mysql_native_password` is deprecated. The flag is still functional but may show deprecation notices. Ghost and older clients still require it.
