# Database Backup Archive

## What this is

The second half of the database-backup pipeline: it takes whatever has been staged on a control
machine — one or more machines' worth of timestamped database dumps, each already checksummed — and
pushes them into a long-term archive on the NAS, re-verifies every pushed directory against its own
checksum file, prunes archive entries older than the archive's retention window, and clears the
staging copy once the push is confirmed good.

This is the durable copy. Whatever produced the staged dumps in the first place only keeps a few
days locally — enough for a same-day restore — and depends on this job to be the actual history.

Archive layout, one directory per machine per run:

```
<archive-path>/
├── <host-alias>/20260101T031500/{pg_*.dump,pg_*_globals.sql.gz,SHA256SUMS}
├── <host-alias>/20260101T031500/{mysql_*.sql.gz,SHA256SUMS}
├── <host-alias>/20260101T031500/{sqlite_*.db.gz,SHA256SUMS}
└── <host-alias>/20260101T031500/{raft_*.snap.gz,SHA256SUMS}
```

## Before you start

**Something is actually staged on the control machine**

```bash
find /tmp/db-dumps -type f | head
```

If this is empty, there is nothing to push yet — the per-machine dump jobs have to run and land
their output in the staging directory first.

**The NAS backup mount exists and is writable**

```bash
mount | grep <archive-path> || echo "NOT MOUNTED"
sudo mkdir -p <archive-path>
sudo chown <username>:docker <archive-path>
```

**SSH access from the control machine to the NAS**

```bash
ssh <username>@<nas-host> true && echo "ssh: ok"
```

**`rsync` and `sha256sum` are available on both ends**

```bash
command -v rsync sha256sum >/dev/null && echo "tools: ok"
ssh <username>@<nas-host> 'command -v rsync sha256sum >/dev/null && echo "tools on NAS: ok"'
```

**You have decided how long the archive keeps a backup run**

The default here is 90 days — deliberately far longer than the 3 days kept on the machine that
produced the dump, since this is the copy meant to survive a mistake noticed weeks later, not just a
same-day restore.

## Setup

### Overview

1. Check what is staged on the control machine.
2. Create the destination directory on the NAS.
3. Push the staged tree to the NAS.
4. Verify each pushed directory against its checksum file.
5. Delete archive entries older than the retention window.
6. Clear the staging copy.

---

#### Step 1: See what is staged (control machine)

```bash
find /tmp/db-dumps -type f | head
```

**Explanation**: If nothing shows up, stop here — there is nothing to push, and running the rest of
this guide against an empty staging directory would only push nothing (harmless) and then try to
verify nothing.

---

#### Step 2: Create the destination (NAS)

```bash
sudo mkdir -p <archive-path>
sudo chown <username>:docker <archive-path>
sudo chmod 0750 <archive-path>
```

**Explanation**: Mode `0750` keeps the archive readable only by the account that owns it and the
group it shares with the other Docker-adjacent accounts on the NAS — database dumps are exactly the
kind of file you do not want world-readable, since a PostgreSQL custom-format dump or a MySQL dump
can contain any row in any table, credentials included.

---

#### Step 3: Push (from the control machine)

```bash
rsync -a --chown=<username>:docker /tmp/db-dumps/ <username>@<nas-host>:<archive-path>/
```

**Explanation**: No `--delete` here, deliberately. The archive holds a much longer history than the
staging directory ever does — the staging copy is cleared after every successful push, while the
archive keeps 90 days of runs — so a `--delete` synced from the (nearly empty) staging tree would
erase the archive's own history on the very next run after staging was cleaned out.

---

#### Step 4: Verify (NAS)

```bash
cd <archive-path>/<host-alias>/<timestamp>
sha256sum -c SHA256SUMS
```

**Explanation**: Only the directories this run actually pushed are re-verified — not the whole
archive. Re-hashing everything ever archived would take a little longer with every backup that has
ever been taken, for no extra safety: older directories were already verified the day they arrived,
and nothing writes into them afterward, so their checksums cannot have drifted since.

---

#### Step 5: Prune (NAS)

```bash
find <archive-path> -mindepth 2 -maxdepth 2 -type d \
  -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}$' \
  -mtime +<retention-days> -exec rm -rf {} +
```

**Explanation**: The pattern matches only directories that look like the timestamps this pipeline
itself produces, at exactly two levels below the archive root (`<host-alias>/<timestamp>`) — so a
whole backup run can be deleted once it ages out, but a host directory or the archive root itself
never can, no matter how old its `mtime` looks.

---

#### Step 6: Clean staging (control machine)

```bash
rm -rf /tmp/db-dumps
```

**Explanation**: The staging directory is transient by design — every dump job repopulates it on its
own schedule, and holding on to old staged copies once they are safely archived only wastes space on
the control machine and risks a future push re-sending data that is already there.

---

## Restoring

Restoring from the archive is a two-part job: get the right files back onto the target machine, then
apply the same restore procedure for whichever engine produced them. Stop the application that owns
the data before you start the second part — every one of these restores either overwrites live state
or drops and recreates database objects in place, and doing that under a running writer produces a
database the application half-trusts and then corrupts further.

### Find and retrieve the backup

List what is available for a machine, newest first:

```bash
ssh <username>@<nas-host> "ls -1t <archive-path>/<host-alias>"
```

Verify it before you trust it — this is the same command the push step already ran, and re-running
it costs nothing:

```bash
ssh <username>@<nas-host> "cd <archive-path>/<host-alias>/<timestamp> && sha256sum -c SHA256SUMS"
```

Copy it back to wherever you are going to restore it from:

```bash
mkdir -p ./restore/<timestamp>
rsync -a <username>@<nas-host>:<archive-path>/<host-alias>/<timestamp>/ ./restore/<timestamp>/
cd ./restore/<timestamp> && sha256sum -c SHA256SUMS
```

### Restore the dump you retrieved

**PostgreSQL** — a single database, into a running server:

```bash
docker stop <service>
docker cp pg_<postgres-container>_<database>.dump <postgres-container>:/tmp/restore.dump
docker exec <postgres-container> createdb -U <admin-user> '<database>' 2>/dev/null || true
docker exec <postgres-container> pg_restore -U <admin-user> -d '<database>' --clean --if-exists /tmp/restore.dump
docker exec <postgres-container> rm -f /tmp/restore.dump
docker start <service>
```

Restoring into a fresh cluster that has never seen these role names needs the globals loaded first —
otherwise every restored object ends up owned by the admin account instead of the application's own:

```bash
gunzip -c pg_<postgres-container>_globals.sql.gz | docker exec -i <postgres-container> psql -U <admin-user>
```

Confirm it landed:

```bash
docker exec <postgres-container> psql -U <admin-user> -d '<database>' -c '\dt'
```

**MySQL / MariaDB**:

```bash
docker stop <service>
gunzip -c mysql_<mysql-container>.sql.gz \
  | docker exec -i -e MYSQL_PWD='<secret>' <mysql-container> mariadb -u<admin-user>
docker start <service>
docker exec -e MYSQL_PWD='<secret>' <mysql-container> mariadb -u<admin-user> -e 'SHOW DATABASES;'
```

**SQLite** — stopping the owning service first is not optional; restoring underneath a running
process leaves it holding a stale file handle, and the next write corrupts the result:

```bash
docker stop <service>
gunzip -c sqlite_<name>.db.gz > ./data/<service>/<database>.db
sudo chown <username>:docker ./data/<service>/<database>.db
rm -f ./data/<service>/<database>.db-wal ./data/<service>/<database>.db-shm
docker start <service>
```

Confirm it with an integrity check before trusting the service against it:

```bash
docker run --rm -v "$(pwd)/data/<service>:/data:ro" keinos/sqlite3 \
  sqlite3 /data/<database>.db 'PRAGMA integrity_check;'
# expect: ok
```

**OpenBao (Raft)** — restore into a running, unsealed node that holds the same unseal keys the
snapshot was taken under; the snapshot carries the store in its already-encrypted form:

```bash
gunzip -c raft_openbao.snap.gz > /tmp/restore.snap
docker cp /tmp/restore.snap openbao:/tmp/restore.snap
docker exec openbao bao operator raft snapshot inspect /tmp/restore.snap
docker exec openbao bao operator raft snapshot restore /tmp/restore.snap
docker exec openbao bao status
```

This replaces the entire store, not one path inside it. To inspect a snapshot without touching the
live node, start a throwaway container against an empty data directory, initialize it, restore with
`-force`, and unseal that throwaway node with the original unseal keys — a snapshot restored under
different keys does not unseal.

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<username>` | Account used on both the control machine and the NAS | The unprivileged account you administer these machines with |
| `<nas-host>` | The NAS, as reached over SSH | Its LAN address or name |
| `<archive-path>` | Root of the long-term archive on the NAS | A path on a mount with enough room for months of dumps — this guide creates it in Step 2 |
| `<host-alias>` | Label distinguishing one backed-up machine's dumps from another's | Whatever label the dump job used when staging that machine's copy |
| `<timestamp>` | One backup run, e.g. `20260805T140000` | Chosen by listing the archive as shown under "Restoring" |
| `<retention-days>` | How long a backup run is kept in the archive | 90 by default; longer than the few days kept on the machine that produced it |
| `<postgres-container>` / `<mysql-container>` / `<name>` / `<service>` / `<database>` / `<admin-user>` / `<secret>` | Identify one specific dump and how to restore it | Match the file names inside the retrieved backup directory |

## Verification

```bash
ssh <username>@<nas-host> "du -sh <archive-path>/*"
ssh <username>@<nas-host> "ls -R <archive-path> | head -40"
ssh <username>@<nas-host> "gzip -t <archive-path>/*/*/*.gz"
```

Every machine that ran a dump job recently should have a directory under it named for the current
timestamp, and `sha256sum -c SHA256SUMS` inside that directory must pass.

## Updating & day-to-day

Nothing here is a running service — there is no image to pull. The routine work is watching that the
pipeline keeps producing what you expect and that the archive is not quietly filling up or falling
behind.

**Confirm the latest run landed for every machine you expect**:

```bash
ssh <username>@<nas-host> "for d in <archive-path>/*/; do echo \"\$d: \$(ls -1t \"\$d\" | head -1)\"; done"
```

A machine missing from this listing, or showing an old timestamp, means either its own dump job did
not run or the push never reached it — check the staging directory on the control machine first.

**Check archive size** and act before the NAS runs out of room, not after:

```bash
ssh <username>@<nas-host> "df -h <archive-path>"
```

**Adjust retention**: change `<retention-days>` in Step 5 (and in the automated version of it, if
you scheduled one) — lowering it frees space sooner, raising it keeps a longer history at the cost of
more disk.

**Move the archive to a bigger volume**: copy the existing tree to the new path, update `<archive-path>`
everywhere it is used, and confirm with the Step 4 checksum check before deleting the old copy.

**Log locations**: whatever you redirected the push job's output to, if you scheduled it with cron or
a systemd timer the same way the dump job is scheduled — there is no dedicated log file created by
these steps on their own.

## Rollback / Uninstall

```bash
ssh <username>@<nas-host> "sudo rm -rf <archive-path>"   # deletes the entire archive
rm -rf /tmp/db-dumps                                      # control machine staging
```

Nothing else on the NAS is touched — no packages, containers, or services are installed by this
guide, only the archive directory and whatever cron entry or systemd timer you set up to run it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `find /tmp/db-dumps -type f` is empty | The per-machine dump jobs have not run yet, or produced nothing this cycle. Nothing to push — this is not itself a failure of the push step. |
| `sha256sum -c SHA256SUMS` reports mismatched checksums, on the NAS | The transfer or the storage corrupted a file. Re-push from the still-intact staging copy if it has not been cleared yet; if the mismatch recurs, check the NAS filesystem for underlying disk errors. |
| `rsync: … Permission denied` | The archive root is not owned by the account doing the push, or the backup mount on the NAS is not actually mounted — check with `mount \| grep <archive-path>`. |
| Old backup runs never disappear | A directory's `mtime` gets refreshed by anything that writes into it — confirm with `find <archive-path> -mtime +<retention-days>` before assuming the prune step is broken; only untouched, complete runs age out. |
| The NAS is filling up | Lower `<retention-days>`, or move `<archive-path>` to a larger volume. |
| A machine is missing from the archive entirely | Its dump job never staged anything on the control machine, or the push step's SSH access to the NAS failed silently — check the staging directory for that machine's alias before assuming the push is at fault. |
| Restoring a PostgreSQL dump fails on ownership | The globals were not loaded into the target cluster first — every dumped object refers to an owner role that has to exist before the objects that depend on it are restored. |
| SQLite restore comes back corrupted | Leftover `-wal`/`-shm` sidecar files from the old database were not removed before the container started against the restored file. |
