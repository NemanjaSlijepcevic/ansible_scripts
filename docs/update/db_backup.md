# Role: db_backup

## Purpose

Dumps every database on a host into a timestamped directory, checksums the dumps, pulls them to the Ansible control node, and prunes old on-host backups.

Three engines are handled, all through the running containers — nothing is installed on the host:

| Engine | Tool | Output |
|--------|------|--------|
| PostgreSQL | `pg_dumpall --globals-only` + `pg_dump -Fc` per database | `pg_<container>_globals.sql.gz`, `pg_<container>_<database>.dump` |
| MySQL / MariaDB | `mariadb-dump` (or `mysqldump`, probed) `--all-databases` | `mysql_<container>.sql.gz` |
| SQLite | Python `sqlite3` online backup API | `sqlite_<name>.db.gz` |

A host with no configured source is skipped silently; a host that *has* sources but produced no file fails the play (that means a container or path disappeared).

The companion role [`db_backup_sync`](db_backup_sync.md) pushes the staged dumps from the control node to the NAS.

## Prerequisites

- Docker running, with the database containers up.
- PostgreSQL containers accept `local … trust` on the unix socket (this is what `pg_hba.conf` from the `postgres` role does), so `docker exec … pg_dump` needs no password.
- `python3` on the host (used for the SQLite snapshot) — present on every host in this repo.
- `ansible.posix` collection on the control node (`synchronize`).
- `gather_facts: true` — the timestamp comes from `ansible_date_time`.
- `current_host` set by the playbook (`postgres`, `server`, `monitor`, `nas`).

## Manual Execution Guide

### Overview

1. Create the timestamped backup directory.
2. Dump PostgreSQL globals, then each database.
3. Dump MySQL/MariaDB servers.
4. Snapshot SQLite databases.
5. Write `SHA256SUMS`.
6. Pull the directory to the control node and verify it.
7. Delete backup directories older than the retention window.

---

### Step-by-Step Instructions

#### Step 1: Create the backup directory

```bash
STAMP=$(date +%Y%m%dT%H%M%S)
TARGET="./data/backups/$STAMP"
mkdir -p "$TARGET"
sudo chown <username>:docker "$TARGET"
chmod 0750 "$TARGET"
```

**Explanation**: Everything lives under the same `./data` working directory the service roles use, so a backup sits next to the data it came from. `<username>` is the deploy user — it must own the files for the later `rsync` pull, which runs unprivileged.

---

#### Step 2: Dump PostgreSQL

Roles, passwords and tablespaces live outside any single database, so they are dumped separately:

```bash
docker exec <postgres-container> pg_dumpall -U <admin-user> --globals-only \
  | gzip -c > "$TARGET/pg_<postgres-container>_globals.sql.gz"
```

List the real databases (templates excluded — `initdb` recreates them):

```bash
docker exec <postgres-container> psql -U <admin-user> -tAc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
```

Then dump each one in custom format:

```bash
docker exec <postgres-container> pg_dump -U <admin-user> -Fc -d '<database>' \
  > "$TARGET/pg_<postgres-container>_<database>.dump"
```

**Explanation**: `-Fc` is already compressed and is the only format `pg_restore` can restore selectively (single table, single schema, reordered). The dump goes over the container's unix socket as the superuser, so no password and no TLS client cert is involved.

---

#### Step 3: Dump MySQL / MariaDB

Find the dump binary — MariaDB 11 removed the `mysql*` symlinks, older images only ship `mysqldump`:

```bash
docker exec <mysql-container> sh -c "command -v mariadb-dump || command -v mysqldump"
```

```bash
docker exec -e MYSQL_PWD='<secret>' <mysql-container> \
  <dump-binary> -u<admin-user> --all-databases --single-transaction --routines --events \
  | gzip -c > "$TARGET/mysql_<mysql-container>.sql.gz"
```

**Explanation**: `MYSQL_PWD` keeps the password out of the container's process list (`-p<secret>` would expose it to anything running `ps`). `--single-transaction` takes a consistent InnoDB snapshot without locking the tables, so Ghost keeps serving while the dump runs.

---

#### Step 4: Snapshot SQLite

Never `cp` a live SQLite file — a write in progress produces a torn copy. Use the online backup API:

```bash
python3 -c 'import sqlite3, sys;
src = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True);
dst = sqlite3.connect(sys.argv[2]);
src.backup(dst); dst.close(); src.close()' \
  "./data/<service>/<database>.db" "$TARGET/sqlite_<name>.db"
gzip -f "$TARGET/sqlite_<name>.db"
```

**Explanation**: `.backup()` copies pages under a read lock and folds in any WAL content, so the result is a consistent database even though the service is writing to it.

---

#### Step 5: Checksums

```bash
cd "$TARGET" && sha256sum * > SHA256SUMS
```

---

#### Step 6: Pull to the control node

Run this **on the control node**:

```bash
mkdir -p /tmp/db-dumps/<host-alias>/$STAMP
rsync -a <username>@<ip-address>:data/backups/$STAMP/ /tmp/db-dumps/<host-alias>/$STAMP/
cd /tmp/db-dumps/<host-alias>/$STAMP && sha256sum -c SHA256SUMS
```

**Explanation**: The checksum file travels with the dumps, so the same command proves the transfer, and later the NAS copy, is byte-identical to what was dumped.

---

#### Step 7: Rotate

```bash
find ./data/backups -maxdepth 1 -type d -regextype posix-extended \
  -regex '.*/[0-9]{8}T[0-9]{6}$' -mtime +<retention-days> -exec rm -rf {} +
```

**Explanation**: Only timestamp-shaped directories are candidates, so nothing else that ends up under `./data/backups` can be deleted by mistake. The on-host copy only has to cover a quick restore — the long history lives on the NAS.

---

## Restoring

### PostgreSQL

```bash
# roles/passwords first, if you are restoring onto a fresh server
gunzip -c pg_<container>_globals.sql.gz | docker exec -i <postgres-container> psql -U <admin-user>

# then a single database (drops and recreates its objects)
docker cp pg_<container>_<database>.dump <postgres-container>:/tmp/restore.dump
docker exec <postgres-container> createdb -U <admin-user> '<database>'   # if it no longer exists
docker exec <postgres-container> pg_restore -U <admin-user> -d '<database>' --clean --if-exists /tmp/restore.dump
docker exec <postgres-container> rm -f /tmp/restore.dump
```

Inspect an archive without restoring it — also the quickest integrity check:

```bash
docker exec <postgres-container> pg_restore -l /tmp/restore.dump | head
```

### MySQL / MariaDB

```bash
gunzip -c mysql_<container>.sql.gz \
  | docker exec -i -e MYSQL_PWD='<secret>' <mysql-container> mariadb -u<admin-user>
```

### SQLite

Stop the service first — restoring under a running process corrupts it:

```bash
docker stop <service>
gunzip -c sqlite_<name>.db.gz > ./data/<service>/<database>.db
sudo chown <username>:docker ./data/<service>/<database>.db
docker start <service>
```

Delete any `-wal`/`-shm` sidecar files next to the restored database before starting the container; they belong to the old file.

---

## Variables

Documented with placeholders in `defaults/main.yml`.

| Variable | Meaning |
|----------|---------|
| `db_backup_dir` | Backup root on the host (`./data/backups`) |
| `db_backup_retention_days` | On-host retention (3) |
| `db_backup_local_dir` | Staging directory on the control node (`/tmp/db-dumps`) |
| `db_backup_sources` | Per-`current_host` dict: `postgres_containers` (list) + `sqlite` (list of `{name, path}`) |
| `db_backup_pg_admin_user` | Superuser for `pg_dump`/`pg_dumpall` (from `postgres.adm_user`) |
| `db_backup_pg_exclude` | Databases never dumped (`template0`, `template1`) |
| `db_backup_mysql_servers` | MySQL containers, defaults to the `sql` role's `db_server` list (`{name, admin, pass}`, optional `dump_cmd`) |
| `db_backup_mysql_dump_cmds` | Dump binaries probed inside the container, in order |
| `db_backup_no_log` | Set to `false` on the command line to un-hide MySQL dump errors |

## Verification

```bash
ls -l ./data/backups/<timestamp>/
cd ./data/backups/<timestamp>/ && sha256sum -c SHA256SUMS
gzip -t ./data/backups/<timestamp>/*.gz
```

Each PostgreSQL container should contribute one `_globals.sql.gz` plus one `.dump` per database; each MySQL container one `.sql.gz`; each configured SQLite path one `.db.gz`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `No dumps were produced on <host>` | Every configured source was skipped — read the "Skipping …" messages above it; a container was renamed or a SQLite path moved. Fix `db_backup_sources`. |
| `Skipping <name> — <path> not found` | The SQLite file moved (e.g. an image reorganised `/config`). Find it with `sudo find ./data/<service> -name '*.db'` and update the path. |
| MySQL dump fails, output censored | Re-run with `-e db_backup_no_log=false` to see the real error. |
| `command -v` task fails | Neither `mariadb-dump` nor `mysqldump` exists in that image — add `dump_cmd:` to the container's `db_server` entry. |
| `pg_dump: error: … permission denied` | The container's `pg_hba.conf` lost its `local all all trust` line, or `db_backup_pg_admin_user` is not a superuser. |
| Pull step permission denied | The dumps are not owned by the deploy user — the "Hand the dumps to the deploy user" task must run before the pull. |

## Reversing

The role only writes into `./data/backups` on the host and `/tmp/db-dumps` on the control node:

```bash
rm -rf ./data/backups          # on the host
rm -rf /tmp/db-dumps           # on the control node
```

No packages, containers, services or firewall rules are touched.
