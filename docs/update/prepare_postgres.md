# Role: prepare_postgres

## Purpose

This role creates the PostgreSQL databases and users that applications need. It connects to the PostgreSQL server using admin credentials and provisions databases for each service. It runs against the `primary_postgres` host but the provisioned databases are accessible from all application hosts.

Two levels of provisioning occur:

1. **Base database** (all hosts): Creates the `authelia` database with its dedicated user. (CrowdSec is **not** here — it runs on bundled SQLite, not Postgres.)
2. **Host-specific databases**: Additional databases for NAS applications (`sonarr`, `radarr`, `lidarr`, `bazarr`, `prowlarr`, `authelia`, `jellyseerr`) — these use a shared application user (`<db-username>`) rather than per-service users.

For each database, the role creates the user, creates the database, and grants full privileges on the public schema including default privileges for future tables and sequences.

## Prerequisites

- PostgreSQL must be running and accepting connections from the Ansible control host.
- `python3-psycopg2` must be installed on the Ansible control host or the target host.
- The admin credentials (`postgres.adm_user`, `postgres.adm_pass`) must have superuser access.
- Variables: `postgres.*`, `authelia_db.*`.

## Manual Execution Guide

### Overview

1. Install `python3-psycopg2` (required by Ansible's PostgreSQL modules; also needed if running `psql` scripts).
2. Create the `authelia` database user and database.
3. Create NAS application databases (on NAS host runs).
4. Grant privileges.

---

### Step-by-Step Instructions

#### Step 1: Install PostgreSQL Python library

```bash
sudo apt-get install -y python3-psycopg2
```

---

#### Step 2: Create the base database (authelia)

Connect to PostgreSQL as the admin user and run:

```sql
-- Connect as postgres superuser
-- psql -h <ip-address> -U postgres

-- Create authelia user
CREATE USER "<authelia-db-user>" WITH PASSWORD '<secret>';

-- Create authelia database
CREATE DATABASE authelia OWNER "<authelia-db-user>";

-- Grant privileges
GRANT ALL ON SCHEMA public TO "<authelia-db-user>";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "<authelia-db-user>" WITH GRANT OPTION;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "<authelia-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "<authelia-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "<authelia-db-user>" WITH GRANT OPTION;
```

**Shell commands using psql**:

```bash
PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres -c "
  CREATE USER <authelia-db-user> WITH PASSWORD '<secret>';
  CREATE DATABASE authelia OWNER <authelia-db-user>;
"

PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres -d authelia -c "
  GRANT ALL ON SCHEMA public TO <authelia-db-user>;
  GRANT ALL ON ALL TABLES IN SCHEMA public TO <authelia-db-user> WITH GRANT OPTION;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO <authelia-db-user> WITH GRANT OPTION;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO <authelia-db-user> WITH GRANT OPTION;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO <authelia-db-user> WITH GRANT OPTION;
"
```

---

#### Step 3: Create NAS application databases

The NAS host uses a shared database user (`<db-username>`) for all application databases. These databases are only created if they do not already exist.

Databases created for the NAS host:
- `sonarr`
- `radarr`
- `lidarr`
- `bazarr`
- `prowlarr`
- `authelia` (separate from the shared one above — same name, different user scope)
- `jellyseerr`

```bash
PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres <<'EOF'
-- Create shared NAS application user
CREATE USER <app-db-username> WITH PASSWORD '<secret>';

-- Create all NAS application databases
CREATE DATABASE sonarr OWNER <app-db-username>;
CREATE DATABASE radarr OWNER <app-db-username>;
CREATE DATABASE lidarr OWNER <app-db-username>;
CREATE DATABASE bazarr OWNER <app-db-username>;
CREATE DATABASE prowlarr OWNER <app-db-username>;
CREATE DATABASE authelia OWNER <app-db-username>;
CREATE DATABASE jellyseerr OWNER <app-db-username>;
EOF

# Grant privileges in each database
for DB in sonarr radarr lidarr bazarr prowlarr authelia jellyseerr; do
  PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres -d "$DB" <<EOF
  GRANT ALL ON SCHEMA public TO <app-db-username>;
  GRANT ALL ON ALL TABLES IN SCHEMA public TO <app-db-username> WITH GRANT OPTION;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO <app-db-username> WITH GRANT OPTION;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO <app-db-username> WITH GRANT OPTION;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO <app-db-username> WITH GRANT OPTION;
EOF
done
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `postgres.adm_user` | `postgres` | PostgreSQL superuser for admin operations |
| `postgres.adm_pass` | `<secret>` | Superuser password |
| `postgres.ip` | `<ip-address>` | PostgreSQL server IP |
| `postgres.port` | `5432` | PostgreSQL port |
| `postgres.user` | `<app-db-username>` | Shared application user (NAS) |
| `postgres.password` | `<secret>` | Shared application user password |
| `authelia_db.user` | `<authelia-db-user>` | Authelia database user |
| `authelia_db.password` | `<secret>` | Authelia database user password |
| `current_host` | `nas`/`server`/`monitor` | Controls which host-specific databases are created |

---

## Handlers & Service Management

This role has no handlers. No services are restarted.

---

## Verification

```bash
# List all databases
PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres -c "\l"

# List all roles/users
PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres -c "\du"

# Test connection as application user
PGPASSWORD="<secret>" psql -h <ip-address> -U <app-db-username> -d sonarr -c "SELECT version();"
```

---

## Rollback / Uninstall

```bash
PGPASSWORD="<admin_password>" psql -h <ip-address> -U postgres <<'EOF'
DROP DATABASE IF EXISTS authelia;
DROP DATABASE IF EXISTS sonarr;
DROP DATABASE IF EXISTS radarr;
DROP DATABASE IF EXISTS lidarr;
DROP DATABASE IF EXISTS bazarr;
DROP DATABASE IF EXISTS prowlarr;
DROP DATABASE IF EXISTS jellyseerr;
DROP ROLE IF EXISTS <app-db-username>;
DROP ROLE IF EXISTS <authelia-db-user>;
EOF
```

**Warning**: This permanently destroys all application data stored in these databases.

---

## Troubleshooting

**"role already exists"**
The user was created in a previous run. This is harmless — the task is idempotent and only creates if absent.

**"database already exists"**
Same as above. The NAS host task checks for existence before creating (`SELECT 1 FROM pg_database WHERE datname = ?`).

**Connection refused from application host**
Check `pg_hba.conf` allows the application host's IP with the correct auth method. Ensure PostgreSQL is listening on the right interface (`listen_addresses` in `postgresql.conf`).

**Permission denied on tables**
The `ALTER DEFAULT PRIVILEGES` grants apply to future tables. Existing tables created before the grant may need explicit grants. Run `GRANT ALL ON ALL TABLES IN SCHEMA public TO <user>` in the specific database.
