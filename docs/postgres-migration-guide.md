# PostgreSQL Migration Guide
## TurnKey → Docker (pgvector/pgvector:pg15)

---

## 1. Prerequisites

- New postgres LXC is running (`postgres.yml` playbook completed successfully)
- Both old TurnKey and new Docker postgres are reachable
- You have the old admin credentials: `postgres / 0voJeMojaSifraZaPostGress!`

---

## 2. Dump All Databases from TurnKey

SSH into the **old TurnKey postgres** host and run:

```bash
# Full dump of all databases, roles, and tablespaces
pg_dumpall -U postgres > /tmp/postgres_full_backup.sql

# Verify the dump is not empty
wc -l /tmp/postgres_full_backup.sql
```

Or dump each database individually (safer for large DBs):

```bash
for db in authelia crowdsec; do
    pg_dump -U postgres -Fc $db > /tmp/${db}.dump
done
```

Copy dumps to a safe location (e.g., your laptop or NAS):

```bash
scp root@<ip-address>:/tmp/postgres_full_backup.sql ./
# or individual dumps
scp root@<ip-address>:/tmp/*.dump ./
```

---

## 3. Stop Services That Use the Old Database

On **NAS**, **server**, **netboot**, and **monitor** — stop containers that connect to postgres:

```bash
docker stop authelia crowdsec
```

This prevents new writes during migration.

---

## 4. Bring Up New Docker PostgreSQL

Run the updated playbook (targets only the postgres role):

```bash
ansible-playbook update/postgres.yml --vault-password-file pass.file --limit postgres_local
```

Verify the new container is healthy:

```bash
docker ps | grep postgres-db
docker exec postgres-db pg_isready -U postgres
```

---

## 5. Restore Data to New PostgreSQL

From the machine where you copied the dumps, restore:

### Option A — Full dump restore

```bash
# Copy dump into the new postgres container
docker cp postgres_full_backup.sql postgres-db:/tmp/

# Restore (skip role creation errors if roles already exist)
docker exec -i postgres-db psql -U postgres < /tmp/postgres_full_backup.sql
```

### Option B — Per-database restore

```bash
for db in authelia crowdsec; do
    # Create DB first
    docker exec postgres-db createdb -U postgres $db
    # Restore
    docker cp ${db}.dump postgres-db:/tmp/
    docker exec postgres-db pg_restore -U postgres -d $db /tmp/${db}.dump
done
```

---

## 6. Verify Data

```bash
# List databases
docker exec postgres-db psql -U postgres -c "\l"

# Check authelia table count
docker exec postgres-db psql -U postgres -d authelia -c "\dt"

# Check crowdsec alerts exist
docker exec postgres-db psql -U postgres -d crowdsec -c "SELECT COUNT(*) FROM alerts;"
```

---

## 7. Run Full prepare_postgres Plays

This creates any missing databases, users, and privileges on the new instance:

```bash
ansible-playbook update/postgres.yml --vault-password-file pass.file
```

---

## 8. Restart Services on All Hosts

On each host (NAS, netboot, immich, server):

```bash
docker start authelia crowdsec
```

Or re-run the respective playbook:

```bash
ansible-playbook update/nas.yml --vault-password-file pass.file
ansible-playbook update/netboot.yml --vault-password-file pass.file
```

---

## 9. Verify Services

Check Authelia is healthy:

```bash
docker logs authelia --tail 50
# Look for: "server is listening for requests"
```

Check CrowdSec is healthy:

```bash
docker exec crowdsec cscli lapi status
```

Check Authelia web UI is reachable at its domain.

---

## 10. Decommission TurnKey

Once all services are confirmed healthy for 24–48 hours:

1. Stop the TurnKey postgres LXC in Proxmox
2. Take a final snapshot of the TurnKey LXC before deleting (keep for 7 days)
3. Delete the TurnKey LXC

---

## Notes

- The new postgres uses **pgvector** — Immich can now use the shared postgres instead of its own container. Remove the `immich-postgres` container and point Immich at `<ip-address>:5432`.
- Client certificates are in `./data/certs/` on each host — distributed automatically by the postgres playbook.
- pgAdmin is available at `https://pgadmin.your-domain.com` for database management.
