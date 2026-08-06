# Database Backups

## What this is

A small set of shell steps, run against each machine that carries a database, that dump every
database container's data into a timestamped directory under `./data/backups/` on that machine,
checksum the result, and pull it across to a control machine for staging. A separate archiving job
(run on the NAS) later pushes that staged copy into long-term storage and prunes it on its own
retention schedule — that push is out of scope here; this guide only covers producing a trustworthy
local dump and getting it off the host.

Four kinds of store are handled, all through the containers that are already running — nothing
extra is installed on the database host itself:

| Engine | Tool | Output file |
|---|---|---|
| PostgreSQL | `pg_dumpall --globals-only` + `pg_dump -Fc` per database | `pg_<container>_globals.sql.gz`, `pg_<container>_<database>.dump` |
| MySQL / MariaDB | `mariadb-dump` (or `mysqldump`, whichever exists) `--all-databases` | `mysql_<container>.sql.gz` |
| SQLite | Python's `sqlite3` online backup API | `sqlite_<name>.db.gz` |
| OpenBao (Raft) | `GET /v1/sys/storage/raft/snapshot` over the local API | `raft_<name>.snap.gz` |

Which of the four apply depends on the machine. A machine holding the shared PostgreSQL server and
the machine running the public web applications both dump PostgreSQL databases over the socket. A
monitoring machine has no server-side database of its own to speak of, but does have a handful of
SQLite files it is not safe to just `cp` — a dashboard tool and a home-automation platform both keep
state there. A media-server machine keeps one SQLite file worth saving. A secrets-management machine
holds nothing but a Raft store, so a snapshot is the only backup that makes sense for it. A machine
with none of the above configured is skipped without complaint; a machine that *is* configured but
produces zero files is treated as a failure, because that means a container was renamed, stopped, or
a path moved since the dump was last configured — silently shipping nothing forward is worse than
stopping and saying so.

One store deliberately gets no entry here at all: an intrusion-detection agent's bundled SQLite
database, which holds nothing but bans and alerts that rebuild themselves from live traffic within
hours. Backing it up would only add weight for no recovery benefit.

## Before you start

**Docker is running, and the containers you plan to dump are up**

```bash
docker --version
docker ps --format '{{.Names}}\t{{.Status}}'
```

**The tools these steps rely on are present**

Every step below is a plain shell command against a running container, or a local file; nothing is
downloaded at dump time except the OpenBao API calls.

```bash
command -v gzip curl jq sha256sum rsync ssh python3 >/dev/null \
  && echo "tools: ok" || echo "tools: one or more MISSING"
```

`jq` only matters on a machine with an OpenBao source (Step 5); `python3` only matters on a machine
with a SQLite source (Step 4). Both are present on every machine in this stack already.

**PostgreSQL containers accept a dump with no password**

The PostgreSQL server's access file grants `trust` authentication on the container's own Unix
socket, so a dump taken with `docker exec` needs no password and no TLS client certificate — it
never leaves the container's own network namespace. Confirm it:

```bash
docker exec <postgres-container> psql -U <admin-user> -c 'SELECT 1;'
```

If that prompts for a password, the socket trust rule is missing or the account you are using is
not the superuser; fix that before Step 2 rather than trying to pass a password on the command line.

**You know the MySQL/MariaDB admin credentials for any container you plan to dump**

You need the container's name, the admin user, and its password. There is no trust shortcut for
MySQL/MariaDB the way there is for PostgreSQL.

**You know the SQLite files you plan to snapshot**

The container's own data directory, e.g. `./data/<service>/<database>.db`. If you are not sure a
path is still correct:

```bash
sudo find ./data -maxdepth 4 -name '*.db'
```

**For an OpenBao Raft source: the node is unsealed, and you hold a scoped credential for it**

A sealed OpenBao node has no root key and cannot produce a snapshot. Snapshotting also requires
authenticating — this guide uses an AppRole login limited to exactly one capability
(`read` on `sys/storage/raft/snapshot`, nothing else), issued in advance by whoever administers that
OpenBao instance, and delivered to you as two small files: a role ID and a secret ID. Confirm both
before you start:

```bash
curl -sf http://127.0.0.1:8200/v1/sys/health?standbyok=true | jq '.sealed'
# expect: false

test -f <role-id-file> && test -f <secret-id-file> && echo "AppRole credential files: ok"
```

**SSH access from the control machine to every host you will pull from**

Step 7 runs from a separate machine — the one you keep the staged copies on before they are archived
— and needs a working, non-interactive login to each host being backed up.

```bash
ssh <username>@<ip-address> true && echo "ssh: ok"
```

**You have decided how long to keep dumps on the host itself**

The default is 3 days. Keep this short: the on-host copy exists only to make a same-day restore
fast, not to be the long-term history — that lives on the NAS archive with a much longer retention.

## Setup

### Overview

1. Create the timestamped backup directory.
2. Dump PostgreSQL databases.
3. Dump MySQL/MariaDB databases.
4. Snapshot SQLite databases.
5. Snapshot OpenBao Raft storage.
6. Confirm something was actually produced, then checksum it.
7. Pull the directory to the control machine and verify the transfer.
8. Delete on-host backup directories older than the retention window.
9. Automate it.

Steps 1–6 and 8 run **on the machine being backed up**. Step 7 runs **on the control machine**. Step
9 ties both halves together.

---

#### Step 1: Create the backup directory

```bash
STAMP=$(date +%Y%m%dT%H%M%S)
TARGET="./data/backups/$STAMP"
mkdir -p "$TARGET"
sudo chown <username>:docker "$TARGET"
chmod 0750 "$TARGET"
```

**Explanation**: Everything lives under the same `./data` working directory every other service on
this machine uses, so a backup sits next to the data it came from instead of scattered across the
filesystem. The timestamp format is deliberately sortable and grep-able (`20260805T140000`), which
is what lets the rotation step in Step 8 recognise a backup directory by pattern alone. `<username>`
must own the files because the pull in Step 7 runs unprivileged from the control machine and needs
read access without `sudo`.

---

#### Step 2: Dump PostgreSQL

Do this once per PostgreSQL container on this machine. Roles, passwords and tablespaces live outside
any single database, so they are dumped separately from the databases themselves:

```bash
docker exec <postgres-container> pg_dumpall -U <admin-user> --globals-only \
  | gzip -c > "$TARGET/pg_<postgres-container>_globals.sql.gz"
```

List the real databases — templates are excluded, because `initdb` recreates them on any fresh
cluster and dumping them would only be dead weight:

```bash
docker exec <postgres-container> psql -U <admin-user> -tAc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
```

Then dump each one, in PostgreSQL's own custom format:

```bash
docker exec <postgres-container> pg_dump -U <admin-user> -Fc -d '<database>' \
  > "$TARGET/pg_<postgres-container>_<database>.dump"
```

**Explanation**: `-Fc` is already compressed and is the only format `pg_restore` can restore
selectively — a single table, a single schema, or a different order than it was dumped in. Every
command here goes over the container's Unix socket as the superuser, matched by the `trust` rule
confirmed above, so nothing here ever touches a password or a TLS certificate — which is also what
makes a restore possible later even if the certificate material itself is part of what you are
recovering from.

---

#### Step 3: Dump MySQL / MariaDB

Do this once per MySQL/MariaDB container. First find which dump binary the image actually ships —
MariaDB 11 dropped the `mysql*` compatibility symlinks, so a newer image only has `mariadb-dump`
while an older one only has `mysqldump`:

```bash
docker exec <mysql-container> sh -c "command -v mariadb-dump || command -v mysqldump"
```

```bash
docker exec -e MYSQL_PWD='<secret>' <mysql-container> \
  <dump-binary> -u<admin-user> --all-databases --single-transaction --routines --events \
  | gzip -c > "$TARGET/mysql_<mysql-container>.sql.gz"
```

**Explanation**: The password is passed through the `MYSQL_PWD` environment variable rather than as
a `-p<secret>` argument, because command-line arguments are visible to anything running `ps` on the
same machine, while an environment variable set only for this one `docker exec` is not.
`--single-transaction` takes a consistent InnoDB snapshot without locking the tables for the duration
of the dump, so the application keeps serving normally while the dump runs; without it a dump of a
busy database can block writers for its entire length.

---

#### Step 4: Snapshot SQLite

Do this once per SQLite file. Never `cp` a live SQLite database — a write in progress produces a
torn, unusable copy — so use the engine's own online backup API instead:

```bash
python3 -c 'import sqlite3, sys;
src = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True);
dst = sqlite3.connect(sys.argv[2]);
src.backup(dst); dst.close(); src.close()' \
  "./data/<service>/<database>.db" "$TARGET/sqlite_<name>.db"
gzip -f "$TARGET/sqlite_<name>.db"
```

**Explanation**: `.backup()` copies pages under a read lock and folds in any write-ahead-log content
that has not yet been checkpointed into the main file, so what lands in `$TARGET` is a consistent
database even while the service that owns it keeps writing. Some of these files are far more
expensive to lose than their size suggests — a smart-home platform's Zigbee pairing table, for
instance, is a few hundred kilobytes but represents every device that would otherwise have to be
re-paired by hand.

---

#### Step 5: Snapshot OpenBao Raft storage

This only applies on the one machine that runs OpenBao. Log in with the scoped AppRole credential
from "Before you start" to get a short-lived token — this is deliberately not a long-lived token
sitting in a file somewhere, so a leaked credential from this step is worthless within the hour:

```bash
ROLE_ID=$(cat <role-id-file>)
SECRET_ID=$(cat <secret-id-file>)
TOKEN=$(curl -sf -X POST http://127.0.0.1:8200/v1/auth/approle/login \
  -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" | jq -r '.auth.client_token')
```

Check the node is actually unsealed and initialized before trying to use that token — a bare `curl`
against a sealed node returns HTTP 503, which is why the query string below forces a 200 either way
so the script can inspect the body instead of just failing on the status code:

```bash
SEALED=$(curl -sf 'http://127.0.0.1:8200/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200' \
  | jq -r '.sealed')
```

```bash
if [ "$SEALED" = "true" ]; then
  echo "SKIPPING openbao — node is sealed. Unseal it and re-run; nothing has been backed up since."
else
  curl -sf -H "X-Vault-Token: $TOKEN" \
    http://127.0.0.1:8200/v1/sys/storage/raft/snapshot \
    -o "$TARGET/raft_openbao.snap"
  gzip -f "$TARGET/raft_openbao.snap"
fi
```

**Explanation**: The token is carried in an HTTP header rather than as a command-line flag or an
environment variable read by the OpenBao CLI, because `bao operator raft snapshot save` wants the
token where `ps` or the shell's own history file can see it; a header sent by `curl` is not visible
either way. The AppRole's policy grants exactly one capability — `read` on
`sys/storage/raft/snapshot` — so even if this short-lived token leaked, the most it could do is
produce one more copy of the same snapshot; it cannot read secrets, write policy, or unseal anything.

---

#### Step 6: Confirm something was produced, then checksum it

```bash
count=$(find "$TARGET" -maxdepth 1 -type f | wc -l)
if [ "$count" -eq 0 ]; then
  echo "No dumps were produced in $TARGET — check that the containers and paths" >&2
  echo "configured for this machine still exist." >&2
  exit 1
fi

(cd "$TARGET" && sha256sum * > SHA256SUMS)
```

**Explanation**: A machine that is configured to have sources but ends up with an empty directory
almost always means a container was renamed or stopped, or a SQLite path moved when an image was
updated — not that there was genuinely nothing to back up. Stopping loudly here is what turns that
into something you notice the same day instead of the day you need the backup and it isn't there.
The checksum file travels with the dumps from here on, so every later step — the pull to the control
machine, and the eventual push to the archive — can prove byte-for-byte that nothing was corrupted
in transit, using the exact same command each time.

---

#### Step 7: Pull to the control machine

Run this **on the control machine**, not on the host you just dumped:

```bash
mkdir -p /tmp/db-dumps/<host-alias>/$STAMP
rsync -a <username>@<ip-address>:./data/backups/$STAMP/ /tmp/db-dumps/<host-alias>/$STAMP/
(cd /tmp/db-dumps/<host-alias>/$STAMP && sha256sum -c SHA256SUMS)
```

**Explanation**: `<host-alias>` is just a label you pick to keep one machine's dumps apart from
another's under the shared staging directory — nothing enforces it beyond that. Re-verifying the
checksum file here, immediately after the transfer, catches network or disk corruption at the
earliest possible point, before the archiving job trusts this copy enough to push it onward.

---

#### Step 8: Rotate on-host backups

```bash
find ./data/backups -maxdepth 1 -type d -regextype posix-extended \
  -regex '.*/[0-9]{8}T[0-9]{6}$' -mtime +<retention-days> -exec rm -rf {} +
```

**Explanation**: The pattern only matches directories that look like the timestamps this process
itself creates, so nothing else that ever ends up under `./data/backups` can be deleted by accident.
Keeping only a few days locally is deliberate — the point of the on-host copy is a same-day restore
without waiting on a network transfer; the real history lives in the archive, on its own, much
longer retention.

---

#### Step 9: Automate it

Wrap Steps 1–6 and 8 into one script per machine you back up. Fill in only the sources that machine
actually has and leave the rest of the arrays empty — an empty array means that whole section is
simply skipped.

```bash
sudo tee /usr/local/bin/db-backup.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd <deploy-dir>

# --- per-machine configuration --------------------------------------------
POSTGRES_CONTAINERS=("<postgres-container>")
PG_ADMIN_USER="<admin-user>"
PG_EXCLUDE_DBS=("template0" "template1")

MYSQL_SERVERS=("<mysql-container>:<admin-user>:<secret>")   # name:admin:password

SQLITE_DBS=("<name>:./data/<service>/<database>.db")        # name:path

RAFT_URL="http://127.0.0.1:8200"          # leave RAFT_NAME empty to skip this machine
RAFT_NAME=""
RAFT_ROLE_ID_FILE="<role-id-file>"
RAFT_SECRET_ID_FILE="<secret-id-file>"

RETENTION_DAYS=<retention-days>
BACKUP_ROOT="./data/backups"
# ---------------------------------------------------------------------------

STAMP=$(date +%Y%m%dT%H%M%S)
TARGET="$BACKUP_ROOT/$STAMP"
mkdir -p "$TARGET"

for c in "${POSTGRES_CONTAINERS[@]}"; do
  [ -z "$c" ] && continue
  running=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)
  if [ "$running" != "true" ]; then echo "Skipping $c — not running"; continue; fi
  docker exec "$c" pg_dumpall -U "$PG_ADMIN_USER" --globals-only \
    | gzip -c > "$TARGET/pg_${c}_globals.sql.gz"
  for db in $(docker exec "$c" psql -U "$PG_ADMIN_USER" -tAc \
      "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"); do
    skip=false
    for ex in "${PG_EXCLUDE_DBS[@]}"; do [ "$db" = "$ex" ] && skip=true; done
    [ "$skip" = true ] && continue
    docker exec "$c" pg_dump -U "$PG_ADMIN_USER" -Fc -d "$db" > "$TARGET/pg_${c}_${db}.dump"
  done
done

for entry in "${MYSQL_SERVERS[@]}"; do
  [ -z "$entry" ] && continue
  IFS=':' read -r name admin pass <<< "$entry"
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
  if [ "$running" != "true" ]; then echo "Skipping $name — not running"; continue; fi
  dumpbin=$(docker exec "$name" sh -c 'command -v mariadb-dump || command -v mysqldump')
  docker exec -e MYSQL_PWD="$pass" "$name" "$dumpbin" -u"$admin" \
    --all-databases --single-transaction --routines --events \
    | gzip -c > "$TARGET/mysql_${name}.sql.gz"
done

for entry in "${SQLITE_DBS[@]}"; do
  [ -z "$entry" ] && continue
  IFS=':' read -r name path <<< "$entry"
  if [ ! -f "$path" ]; then echo "Skipping $name — $path not found"; continue; fi
  python3 -c 'import sqlite3, sys;
src = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True);
dst = sqlite3.connect(sys.argv[2]);
src.backup(dst); dst.close(); src.close()' "$path" "$TARGET/sqlite_${name}.db"
  gzip -f "$TARGET/sqlite_${name}.db"
done

if [ -n "$RAFT_NAME" ]; then
  ROLE_ID=$(cat "$RAFT_ROLE_ID_FILE")
  SECRET_ID=$(cat "$RAFT_SECRET_ID_FILE")
  TOKEN=$(curl -sf -X POST "$RAFT_URL/v1/auth/approle/login" \
    -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" | jq -r '.auth.client_token')
  SEALED=$(curl -sf "$RAFT_URL/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" | jq -r '.sealed')
  if [ "$SEALED" = "true" ]; then
    echo "SKIPPING $RAFT_NAME — sealed"
  else
    curl -sf -H "X-Vault-Token: $TOKEN" "$RAFT_URL/v1/sys/storage/raft/snapshot" \
      -o "$TARGET/raft_${RAFT_NAME}.snap"
    gzip -f "$TARGET/raft_${RAFT_NAME}.snap"
  fi
fi

count=$(find "$TARGET" -maxdepth 1 -type f | wc -l)
if [ "$count" -eq 0 ]; then
  echo "No dumps were produced in $TARGET" >&2
  rmdir "$TARGET"
  exit 1
fi
(cd "$TARGET" && sha256sum * > SHA256SUMS)

find "$BACKUP_ROOT" -maxdepth 1 -type d -regextype posix-extended \
  -regex '.*/[0-9]{8}T[0-9]{6}$' -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
EOF
sudo chmod 0750 /usr/local/bin/db-backup.sh
sudo chown <username>:docker /usr/local/bin/db-backup.sh
```

Schedule it, on the machine being backed up, as the deploy account:

```bash
( crontab -l -u <username> 2>/dev/null; echo "0 2 * * * /usr/local/bin/db-backup.sh >> <deploy-dir>/data/backups/db-backup.log 2>&1" ) \
  | crontab -u <username> -
```

Or, as a systemd timer instead of cron:

```bash
sudo tee /etc/systemd/system/db-backup.service >/dev/null <<EOF
[Unit]
Description=Database backup

[Service]
Type=oneshot
User=<username>
ExecStart=/usr/local/bin/db-backup.sh
EOF

sudo tee /etc/systemd/system/db-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Run database backup nightly

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now db-backup.timer
```

On the **control machine**, schedule the pull shortly after — enough of a gap that the dump job has
finished before the pull starts:

```bash
sudo tee /usr/local/bin/db-backup-pull.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date +%Y%m%dT%H%M%S)
declare -A HOSTS=( ["<host-alias>"]="<ip-address>" )
for alias in "${!HOSTS[@]}"; do
  ip="${HOSTS[$alias]}"
  latest=$(ssh <username>@"$ip" 'ls -1 ./data/backups | sort | tail -1')
  [ -z "$latest" ] && continue
  mkdir -p "/tmp/db-dumps/$alias/$latest"
  rsync -a <username>@"$ip":./data/backups/"$latest"/ "/tmp/db-dumps/$alias/$latest/"
  (cd "/tmp/db-dumps/$alias/$latest" && sha256sum -c SHA256SUMS)
done
EOF
sudo chmod 0750 /usr/local/bin/db-backup-pull.sh
sudo chown <username>:docker /usr/local/bin/db-backup-pull.sh

( crontab -l -u <username> 2>/dev/null; echo "30 2 * * * /usr/local/bin/db-backup-pull.sh >> /tmp/db-dumps/pull.log 2>&1" ) \
  | crontab -u <username> -
```

**Explanation**: The pull job is deliberately its own script and its own schedule rather than being
triggered directly by the dump job over SSH — it needs to reach every machine being backed up, not
just the one it happens to be running on, and keeping it separate means a hang or failure pulling
from one machine cannot block the dump running on another. Once the control machine holds the
staged copy, a separate, later job pushes that whole staging tree into the NAS archive with its own
checksum verification and its own — much longer — retention window, and only then clears the staging
directory; that push is outside the scope of this guide.

---

## Restoring

Stop the application that owns the data before restoring into it — every one of these restores
either overwrites live state or, for a database server, drops and recreates objects in place, and
doing that under a running writer produces a database the application half-trusts and then corrupts
further.

### PostgreSQL

Restore a single database, into a running server:

```bash
docker stop <service>

docker cp pg_<postgres-container>_<database>.dump <postgres-container>:/tmp/restore.dump
docker exec <postgres-container> createdb -U <admin-user> '<database>' 2>/dev/null || true
docker exec <postgres-container> pg_restore -U <admin-user> -d '<database>' --clean --if-exists /tmp/restore.dump
docker exec <postgres-container> rm -f /tmp/restore.dump

docker start <service>
```

Restoring the globals (roles, passwords, tablespaces) matters when the target is a fresh cluster
that has never seen these role names — do this first, or every restored object ends up owned by the
admin account instead of the application's own role:

```bash
gunzip -c pg_<postgres-container>_globals.sql.gz | docker exec -i <postgres-container> psql -U <admin-user>
```

Confirm the restore landed — this is also the quickest way to inspect an archive's contents without
touching a live database at all:

```bash
docker exec <postgres-container> pg_restore -l /tmp/restore.dump | head
docker exec <postgres-container> psql -U <admin-user> -d '<database>' -c '\dt'
```

### MySQL / MariaDB

```bash
docker stop <service>

gunzip -c mysql_<mysql-container>.sql.gz \
  | docker exec -i -e MYSQL_PWD='<secret>' <mysql-container> mariadb -u<admin-user>

docker start <service>
```

Confirm it landed by checking that the expected databases and tables are present:

```bash
docker exec -e MYSQL_PWD='<secret>' <mysql-container> mariadb -u<admin-user> -e 'SHOW DATABASES;'
```

### SQLite

Stopping the service first is not optional here — restoring the file underneath a running process
produces a database the process is still holding a stale file handle for, and the next write can
corrupt it:

```bash
docker stop <service>
gunzip -c sqlite_<name>.db.gz > ./data/<service>/<database>.db
sudo chown <username>:docker ./data/<service>/<database>.db
rm -f ./data/<service>/<database>.db-wal ./data/<service>/<database>.db-shm
docker start <service>
```

The `-wal`/`-shm` sidecar files, if any are left over from before the restore, belong to the old
database file, not the one you just put in place; leaving them causes the engine to try to replay
writes that no longer make sense against the restored file. Confirm the restore landed with an
integrity check before trusting the service to start cleanly against it:

```bash
docker run --rm -v "$(pwd)/data/<service>:/data:ro" keinos/sqlite3 \
  sqlite3 /data/<database>.db 'PRAGMA integrity_check;'
# expect: ok
```

### OpenBao (Raft)

Restore into a **running, unsealed** node — the snapshot carries the store in its already-encrypted
form, so the target node must already hold the same unseal keys the snapshot was taken under:

```bash
gunzip -c raft_openbao.snap.gz > /tmp/restore.snap
docker cp /tmp/restore.snap openbao:/tmp/restore.snap
docker exec openbao bao operator raft snapshot inspect /tmp/restore.snap
docker exec openbao bao operator raft snapshot restore /tmp/restore.snap
```

Restoring replaces the **entire** store, not one path inside it — there is no equivalent of the
per-database restore that PostgreSQL offers. To check a snapshot's contents without touching the
live node, start a throwaway OpenBao container against its own empty data directory, initialize it,
restore the snapshot with `-force`, and unseal that throwaway node with the **original** unseal keys
— a snapshot restored under different keys does not unseal.

Confirm the restore landed:

```bash
docker exec openbao bao status
docker exec -e BAO_TOKEN openbao bao kv get kv/homelab/<host>/<service>
```

A value you know existed before the restore reading back correctly is the only real proof; the
snapshot carries no manifest of what it should contain.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` on the backed-up machine | The deploy account's home directory; every relative path in this guide is under it |
| `<username>` | Account that owns the dumps and runs the pull/push jobs | The unprivileged account you administer these machines with |
| `<postgres-container>` | Name of a running PostgreSQL container | `docker ps` on the machine |
| `<admin-user>` | PostgreSQL superuser name | Conventionally `postgres` |
| `<mysql-container>` | Name of a running MySQL/MariaDB container | `docker ps` on the machine |
| `<dump-binary>` | `mariadb-dump` or `mysqldump` | Whichever `command -v` found inside that container |
| `<secret>` | A database or AppRole credential | Long random string; never printed, only passed via environment or a file |
| `<name>` | Short label for a SQLite database | Your own choice; becomes part of the output file name |
| `<service>` | The application container that owns a given database | Used to stop/start it around a restore |
| `<database>` | A PostgreSQL or MySQL database name | Used in the dump and restore commands |
| `<role-id-file>` / `<secret-id-file>` | Local files holding the OpenBao AppRole credential | Issued in advance by whoever administers OpenBao access policies; kept off any shared or synced location |
| `<retention-days>` | How long dumps are kept on the backed-up machine | 3 is the default; keep it short — the archive is the long-term copy |
| `<ip-address>` | Address of a machine being backed up | Reached from the control machine over SSH |
| `<host-alias>` | Label distinguishing one machine's staged dumps from another's | Your own choice, e.g. the machine's role |

## Verification

On the backed-up machine:

```bash
ls -l ./data/backups/<timestamp>/
(cd ./data/backups/<timestamp>/ && sha256sum -c SHA256SUMS)
gzip -t ./data/backups/<timestamp>/*.gz
```

Each PostgreSQL container should contribute one `_globals.sql.gz` plus one `.dump` per database;
each MySQL/MariaDB container one `.sql.gz`; each configured SQLite path one `.db.gz`; the OpenBao
machine one `.snap.gz`. A missing category means its source was skipped — check the command output
from that run for a `Skipping …` line.

On the control machine, after Step 7 or the automated pull:

```bash
find /tmp/db-dumps -maxdepth 2 -type d
(cd /tmp/db-dumps/<host-alias>/<timestamp> && sha256sum -c SHA256SUMS)
```

## Updating & day-to-day

There is no image to pull and no container belonging to this guide — every command runs against
containers that other guides deploy and update on their own schedule. Day-to-day, this comes down to
watching that it keeps running and adjusting what it covers as services change.

**Check the last backup actually happened**:

```bash
ls -lt ./data/backups | head
tail -20 <deploy-dir>/data/backups/db-backup.log
```

**Check disk usage** on the backed-up machine — a runaway database or a rotation that stopped
working shows up here first:

```bash
du -sh ./data/backups
```

**Add a new database container**: add its entry to the per-machine configuration at the top of
`/usr/local/bin/db-backup.sh` (or repeat the manual Steps 2–4 for it once, to confirm it works,
before automating it). If it is the first PostgreSQL container on a machine, re-confirm the trust
check from "Before you start" — a fresh container does not inherit another one's access rules.

**Remove a decommissioned container**: delete its entry from the script. Leaving a stale entry is
harmless — it will simply be skipped with a `Skipping … not running` message — but a clean
configuration is easier to audit later.

**Rotate the OpenBao AppRole credential**: ask whoever administers that OpenBao instance to issue a
new secret ID for the backup identity, overwrite `<secret-id-file>` with it, and confirm with the
seal-status check from "Before you start". No change is needed anywhere else — the role ID does not
change when only the secret ID is rotated.

**Adjust retention**: change `RETENTION_DAYS` in the script (host copy) — the archive's own retention
is configured where the archive push runs, not here.

**Logs**: whatever you redirected cron or the systemd unit's output to —
`<deploy-dir>/data/backups/db-backup.log` in the cron example above, or `journalctl -u db-backup` for
the timer.

## Rollback / Uninstall

```bash
crontab -l -u <username> | grep -v db-backup | crontab -u <username> -
sudo systemctl disable --now db-backup.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/db-backup.{service,timer}
sudo rm -f /usr/local/bin/db-backup.sh /usr/local/bin/db-backup-pull.sh

rm -rf ./data/backups          # on each backed-up machine
rm -rf /tmp/db-dumps           # on the control machine
```

No packages, containers, or firewall rules are touched by any of this — it only ever wrote into the
two staging locations above and, optionally, a cron entry or a systemd unit.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No dumps were produced in <target>` | Every configured source was skipped on this run — look for the `Skipping …` line right above it; a container was renamed, stopped, or a SQLite path moved. Update the per-machine configuration. |
| `Skipping <name> — <path> not found` | The SQLite file moved, often because an image reorganised its data layout on update. Find it with `sudo find ./data -name '*.db'` and update the path. |
| `command -v mariadb-dump \|\| command -v mysqldump` prints nothing | Neither dump binary exists in that image. Check the image's tag/version, or run the dump from a separate client container instead. |
| `pg_dump: error: … permission denied` | The container's access file lost its `local all all trust` line, or the admin account you used is not actually a superuser. |
| Pull step fails with permission denied | The dumps under `./data/backups/<timestamp>` are not owned by the account you SSH in as — confirm Step 1's `chown` ran, or that Step 6's checksum step (which also fixes ownership implicitly if you run the whole script as that account) completed. |
| `curl` to `/v1/sys/health` times out or connection refused | OpenBao is not running, or you are not on the machine that runs it — the snapshot is only ever taken over the loopback API. |
| `SEALED=true` in Step 5 | The node sealed itself, most often after a reboot. Unseal it and re-run; nothing has been backed up since it sealed. |
| Raft snapshot request answers `403` | The AppRole's secret ID was rotated or revoked, or its policy no longer grants `read` on `sys/storage/raft/snapshot`. Get a fresh secret ID from whoever administers that OpenBao instance and overwrite the local file. |
| `TOKEN` comes back empty from the AppRole login | The role ID or secret ID file is stale, missing, or `jq` failed to parse an error response — run the `curl` command by hand without piping to `jq` and read the raw body. |
| Restoring a PostgreSQL dump fails with `schema "public" already contains objects` and ownership errors | You skipped restoring the globals into a fresh cluster first — every dumped object refers to an owner role that has to already exist. |
| SQLite restore starts corrupted | Leftover `-wal`/`-shm` files from the old database were not removed before the container started against the restored file. Stop the container again, delete the sidecar files, and start it. |
