# Role: db_backup_sync

## Purpose

Pushes the database dumps staged on the Ansible control node by the [`db_backup`](db_backup.md) role to the NAS, verifies them against the checksums that travelled with them, prunes backups older than the NAS retention window, and clears the staging directory.

Layout on the NAS:

```
/<backup-mount>/Backup/databases/
├── primary_postgres/20260101T031500/{pg_*.dump,pg_*_globals.sql.gz,SHA256SUMS}
├── primary_server/20260101T031500/{pg_*.dump,mysql_*.sql.gz,SHA256SUMS}
├── primary_monitor/20260101T031500/{sqlite_*.db.gz,SHA256SUMS}
└── primary_nas/20260101T031500/{sqlite_*.db.gz,SHA256SUMS}
```

This is the long-term copy. The dumping hosts keep only a few days for a quick restore.

## Prerequisites

- Runs on the NAS, as the last play of `update/backup.yml`, after every dump play.
- Dumps present in `db_backup_local_dir` on the control node — i.e. the `db_backup` plays ran in the same invocation.
- The backup mount (`/<backup-mount>`) exists on the NAS; the role creates the directories below it.
- `ansible.posix` collection on the control node (`synchronize`).

## Manual Execution Guide

### Overview

1. Check what is staged on the control node.
2. Create the destination directory on the NAS.
3. `rsync` the staging tree to the NAS.
4. Verify each pushed directory against its `SHA256SUMS`.
5. Delete backups older than the retention window.
6. Remove the staging copy.

---

### Step-by-Step Instructions

#### Step 1: See what is staged (control node)

```bash
find /tmp/db-dumps -type f | head
```

If this is empty there is nothing to do — run the dump plays first.

---

#### Step 2: Create the destination (NAS)

```bash
sudo mkdir -p /<backup-mount>/Backup/databases
sudo chown <username>:docker /<backup-mount>/Backup/databases
sudo chmod 0750 /<backup-mount>/Backup/databases
```

---

#### Step 3: Push (from the control node)

```bash
rsync -a --chown=<username>:docker \
  /tmp/db-dumps/ <username>@<ip-address>:/<backup-mount>/Backup/databases/
```

**Explanation**: No `--delete`. The NAS keeps a much longer history than the staging directory ever holds, and a `--delete` here would erase it on the first run after the staging copy is cleaned.

---

#### Step 4: Verify (NAS)

```bash
cd /<backup-mount>/Backup/databases/<host-alias>/<timestamp>
sha256sum -c SHA256SUMS
```

**Explanation**: Only the directories pushed by this run are verified. Re-hashing the whole archive would take longer with every backup ever taken, for no extra safety — the older directories were verified when they arrived and nothing writes to them afterwards.

---

#### Step 5: Prune (NAS)

```bash
find /<backup-mount>/Backup/databases -mindepth 2 -maxdepth 2 -type d \
  -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}$' \
  -mtime +<retention-days> -exec rm -rf {} +
```

**Explanation**: The timestamp-shaped pattern means only whole backup runs can be deleted — never a host directory or the archive root.

---

#### Step 6: Clean staging (control node)

```bash
rm -rf /tmp/db-dumps
```

---

## Variables

Documented with placeholders in `defaults/main.yml`; the real destination is set in `host_vars/primary_nas.yml`.

| Variable | Meaning |
|----------|---------|
| `db_backup_local_dir` | Staging directory on the control node — must match the `db_backup` role |
| `db_backup_nas_dir` | Archive root on the NAS (`/<backup-mount>/Backup/databases`) |
| `db_backup_nas_retention_days` | How long a backup run is kept on the NAS (90) |
| `db_backup_clean_local` | Delete the staging copy after a successful push (`true`) |

## Verification

```bash
du -sh /<backup-mount>/Backup/databases/*
ls -R /<backup-mount>/Backup/databases | head -40
gzip -t /<backup-mount>/Backup/databases/*/*/*.gz
```

Every host that ran a dump play should have a directory with the current timestamp, and `sha256sum -c SHA256SUMS` inside it must pass.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `No dumps staged in /tmp/db-dumps` | The dump plays did not run (or were filtered out by `--limit`/`--tags`). The sync role never fails on this — it just reports and skips. |
| `sha256sum: WARNING: N computed checksums did NOT match` | The transfer or the storage corrupted a dump. Re-run the whole playbook; if it repeats, check the NAS filesystem. |
| `rsync: … Permission denied` | The archive root is not owned by the deploy user, or the backup mount is not mounted — `mount \| grep <backup-mount>`. |
| Old backups never disappear | `mtime` on the directory is refreshed by writes into it; only complete, untouched runs age out. Verify with `find … -mtime +<days>` before suspecting the role. |
| NAS fills up | Lower `db_backup_nas_retention_days` in `host_vars/primary_nas.yml`, or move `db_backup_nas_dir` to a larger drive. |

## Reversing

```bash
sudo rm -rf /<backup-mount>/Backup/databases   # deletes the entire archive
rm -rf /tmp/db-dumps                            # control node staging
```

Nothing else is changed on the NAS — no packages, containers or services.
