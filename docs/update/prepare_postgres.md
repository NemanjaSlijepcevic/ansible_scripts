# PostgreSQL application databases

## What this is

The procedure that creates, on the central PostgreSQL server, the login roles and databases the
applications on a given machine need — and grants each role enough privilege that the application's
first migration succeeds.

You run it **from the machine whose applications need the databases**, not on the database server:
the connection goes over the network as the PostgreSQL superuser, authenticated with an
administrative client certificate that lives on the application machine. Nothing is installed on the
database server and no container is started or restarted here.

What gets created depends on which machine you are on:

- **Every machine** gets the single sign-on portal's database, `authelia`, with its own dedicated
  login role. That instance of the portal stores sessions, TOTP secrets and its identity audit trail
  there.
- **The media machine** additionally gets one database per media application — `sonarr`, `radarr`,
  `lidarr`, `bazarr`, `prowlarr`, `seerr` — plus a separate log database for each of the five
  indexers (`sonarr-log`, `radarr-log`, `lidarr-log`, `bazarr-log`, `prowlarr-log`). All of them are
  owned by a single shared application login role rather than one role per application.
- **The automation machine** additionally gets the workflow engine's database, `kestra`, with its own
  login role.
- Any other machine gets the sign-on database and nothing else.

The intrusion-detection agent is deliberately absent from all of this — it uses a bundled SQLite file
and never touches PostgreSQL.

## Before you start

**You are in the working directory**

```bash
cd <deploy-dir>
ls -d ./data
```

Every path below is relative, including the certificate paths in the connection settings — running
these commands from anywhere else silently produces "certificate file not found" instead of
connecting.

**A PostgreSQL client is installed**

```bash
psql --version || sudo apt-get install -y postgresql-client
```

If any Python tooling on this machine also talks to the database, it needs the driver library as
well:

```bash
sudo apt-get install -y python3-psycopg2
```

**The administrative client certificate is present**

The database server requires `clientcert=verify-full`: a password alone is refused, and the
certificate's Common Name must equal the login role you connect as. Provisioning connects as the
superuser, so the certificate you need here is the one issued for that account.

```bash
ls -l ./data/certs/
sudo openssl x509 -in ./data/certs/postgres_admin.crt -noout -subject -dates
```

You need three files: `./data/certs/postgres_admin.crt`, `./data/certs/postgres_admin.key`, and the
issuing `./data/certs/ca.crt`. The `-subject` output must read `CN = <admin-user>` — the superuser's
name. These are signed on the database machine and copied here; nothing on this machine generates
them.

**The database server is up and reachable**

```bash
export PGSSLMODE=verify-ca
export PGSSLROOTCERT=./data/certs/ca.crt
export PGSSLCERT=./data/certs/postgres_admin.crt
export PGSSLKEY=./data/certs/postgres_admin.key
export PGPASSWORD='<secret>'

psql -h <ip-address> -p 5432 -U <admin-user> -d postgres -c 'SELECT version();'
```

A refusal here is worth reading carefully: `connection requires a valid client certificate` means the
certificate was not offered or not trusted, while `no pg_hba.conf entry for host` means this
machine's address is not covered by the server's access policy at all.

## Setup

### Overview

1. Export the connection settings once for the whole session.
2. Check what already exists.
3. Create the single sign-on database, its login role and its grants.
4. On the media machine: create the shared application role and its databases.
5. On the automation machine: create the workflow engine's role and database.
6. Confirm the result.

---

#### Step 1: Export the connection settings

```bash
cd <deploy-dir>

export PGHOST=<ip-address>
export PGPORT=5432
export PGUSER=<admin-user>
export PGPASSWORD='<secret>'
export PGSSLMODE=verify-ca
export PGSSLROOTCERT=./data/certs/ca.crt
export PGSSLCERT=./data/certs/postgres_admin.crt
export PGSSLKEY=./data/certs/postgres_admin.key
```

**Explanation**: Every command below inherits these, so the certificate never has to be repeated on a
command line. `verify-ca` — rather than `verify-full` — is deliberate: it proves the server's
certificate chains to the CA you trust, but does not require the name you dialled to appear in the
certificate. That keeps one set of settings working whether you reach the server by its LAN address
or by a container name, which differ from machine to machine. The certificate is still mandatory in
both directions; only the hostname check is relaxed.

The paths are relative, which is why Step 0 was `cd <deploy-dir>`. `PGPASSWORD` in the environment
keeps the password off the command line, where anything running `ps` could read it; clear it with
`unset PGPASSWORD` when you are done.

---

#### Step 2: Check what already exists

```bash
psql -d postgres -c '\l'
psql -d postgres -c '\du'

psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'authelia';"
```

**Explanation**: Creating a database that exists is an error, and — much worse — re-running a
`CREATE ROLE … PASSWORD` against an existing account would silently reset the password of a working
service. So each block below is guarded by an existence check, and the guard is on the **database**,
not the role.

That has a consequence worth knowing: once a database exists, none of the grants in that block are
re-applied. If you later widen a privilege, add a table outside the default-privilege rules, or
change a password, you have to run that statement by hand — re-running the whole procedure will skip
straight past it.

---

#### Step 3: Create the single sign-on database

Run this on every machine that runs the sign-on portal.

```bash
psql -d postgres <<EOF
CREATE ROLE "<authelia-db-user>" WITH LOGIN PASSWORD '<secret>';
CREATE DATABASE authelia OWNER "<authelia-db-user>";
EOF

psql -d authelia <<EOF
GRANT ALL ON SCHEMA public TO "<authelia-db-user>";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "<authelia-db-user>" WITH GRANT OPTION;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "<authelia-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO "<authelia-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO "<authelia-db-user>" WITH GRANT OPTION;
EOF
```

**Explanation**: Four things are happening and each covers a gap the previous one leaves.

`CREATE ROLE … WITH LOGIN` makes an account that can connect but has no special powers — no
`CREATEDB`, no `CREATEROLE`. An application never needs to create databases or accounts at runtime,
and an account that cannot do so is one less thing an application compromise can abuse.

`OWNER` makes the role the database's owner, but ownership of the database is not ownership of the
`public` schema. Since PostgreSQL 15 the `public` schema no longer grants `CREATE` to everyone, so
without the explicit `GRANT ALL ON SCHEMA public` the application connects successfully and then
fails its very first migration with `permission denied for schema public`.

The two `GRANT ALL ON ALL …` statements cover objects that exist **right now** — they do nothing for
tables created later, which is why they are paired with `ALTER DEFAULT PRIVILEGES`. That sets the
privileges every *future* table and sequence will be created with, so an application that adds a
table during an upgrade does not need another manual grant.

`WITH GRANT OPTION` lets the role hand those privileges on. Applications that create helper roles
during a migration need it; without it such a migration aborts halfway, which is worse than not
starting.

The password set here must match what the portal is configured with. It also still presents a client
certificate whose Common Name is `<authelia-db-user>` — the certificate proves the identity, the
password is the second factor the access policy asks for on top of it.

---

#### Step 4: The media machine's databases

Only on the machine running the media stack. All of these are owned by one shared application login
role.

```bash
psql -d postgres <<EOF
CREATE ROLE "<app-db-user>" WITH LOGIN PASSWORD '<secret>';
EOF

for DB in sonarr radarr lidarr bazarr prowlarr seerr \
          sonarr-log radarr-log lidarr-log bazarr-log prowlarr-log; do
  psql -d postgres -c "CREATE DATABASE \"$DB\" OWNER \"<app-db-user>\";"
  psql -d "$DB" <<EOF
GRANT ALL ON SCHEMA public TO "<app-db-user>";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "<app-db-user>" WITH GRANT OPTION;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "<app-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO "<app-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO "<app-db-user>" WITH GRANT OPTION;
EOF
done
```

**Explanation**: Two design choices are visible here.

**One shared login role for the whole media stack.** These applications are deployed and upgraded
together, they trust each other by design, and separating them would mean maintaining six passwords
and six client certificates with no security boundary actually gained. It also explains something you
see on the certificate side: each media application has its own certificate *file*, but every one of
them carries the same Common Name — the shared role's name — because the Common Name has to equal the
login role, not the application.

**A separate `-log` database per indexer.** Each of those applications writes its own application log
to a second database. Keeping it apart from the main one means the high-churn, disposable table
traffic never competes with the catalogue for autovacuum attention, and a corrupted or oversized log
database can simply be dropped and recreated without touching the library.

The database names contain a hyphen, which is why they are quoted everywhere — unquoted,
`sonarr-log` parses as a subtraction.

---

#### Step 5: The automation machine's database

Only on the machine running the workflow engine.

```bash
psql -d postgres <<EOF
CREATE ROLE "<kestra-db-user>" WITH LOGIN PASSWORD '<secret>';
CREATE DATABASE kestra OWNER "<kestra-db-user>";
EOF

psql -d kestra <<EOF
GRANT ALL ON SCHEMA public TO "<kestra-db-user>";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "<kestra-db-user>" WITH GRANT OPTION;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "<kestra-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO "<kestra-db-user>" WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO "<kestra-db-user>" WITH GRANT OPTION;
EOF
```

**Explanation**: The workflow engine gets its own login role rather than sharing the media stack's,
because it runs arbitrary flows and orchestrates containers — the one component in the stack where a
blast radius limited to its own database is worth the extra account. It creates and migrates a large
number of tables on first start, which is exactly the case the default-privilege grants exist for.

---

#### Step 6: Confirm

```bash
psql -d postgres -c '\l'
psql -d postgres -c '\du'
psql -d authelia -c '\dn+'
unset PGPASSWORD
```

**Explanation**: `\dn+` prints the access privileges on the `public` schema, which is the grant that
most often turns out to be missing — a database can exist, be owned by the right role, and still
reject that role's first `CREATE TABLE`.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory; the relative certificate paths depend on it |
| `<ip-address>` | Address of the central PostgreSQL server | Its LAN address — the same name must be reachable from this machine |
| `<admin-user>` | PostgreSQL superuser name | Conventionally `postgres`; must equal the Common Name of `postgres_admin.crt` |
| `<secret>` | A password | The superuser's, and a fresh long random one per application role |
| `<authelia-db-user>` | Login role for the sign-on portal | Conventionally `authelia`; must equal the Common Name on the portal's client certificate |
| `<app-db-user>` | Shared login role for the media stack | One name for all media databases; equals the Common Name on every media client certificate |
| `<kestra-db-user>` | Login role for the workflow engine | Its own account, not shared |

## Verification

```bash
psql -h <ip-address> -U <admin-user> -d postgres -c '\l'
psql -h <ip-address> -U <admin-user> -d postgres -c '\du'
```

Confirm a database is not merely present but usable by its owner — connect **as the application
role**, with that application's own certificate:

```bash
PGPASSWORD='<secret>' psql \
  "host=<ip-address> port=5432 user=<app-db-user> dbname=sonarr sslmode=verify-ca \
   sslrootcert=./data/certs/ca.crt \
   sslcert=./data/certs/<service>.crt \
   sslkey=./data/certs/<service>.key" \
  -c "CREATE TABLE _probe(x int); DROP TABLE _probe;"
```

If that succeeds, the role, the grants and the certificate all line up. If it fails on `permission
denied for schema public`, the grants from Step 3 were not applied to this database.

List what each database actually contains — an empty database and a working one look identical from
the outside:

```bash
psql -h <ip-address> -U <admin-user> -d sonarr -c '\dt'
```

## Updating & day-to-day

**Adding a database for a new application**: create its role (or reuse an existing one), create the
database with that owner, and run the same five grant statements against it. Then issue that
application a client certificate whose Common Name equals the login role — a database without the
matching certificate is unreachable.

**Changing an application's password**: do it directly, and remember nothing here will do it for you,
because the existence check skips a database that already exists.

```bash
psql -d postgres -c "ALTER ROLE \"<app-db-user>\" WITH PASSWORD '<secret>';"
```

Then update the application's configuration and restart it.

**Applying a grant you missed**: run the grant block from Step 3 against the affected database. The
statements are idempotent — granting a privilege that is already held changes nothing.

**Reclaiming space from a log database**: the `-log` databases are disposable. Stop the application,
drop and recreate the database with the same owner and grants, and start it again; it recreates its
own schema.

## Rollback / Uninstall

Dropping a database destroys the application's data permanently. Stop the application first —
PostgreSQL refuses to drop a database that still has a connected client.

```bash
psql -d postgres <<'EOF'
DROP DATABASE IF EXISTS "sonarr-log";
DROP DATABASE IF EXISTS "radarr-log";
DROP DATABASE IF EXISTS "lidarr-log";
DROP DATABASE IF EXISTS "bazarr-log";
DROP DATABASE IF EXISTS "prowlarr-log";
DROP DATABASE IF EXISTS sonarr;
DROP DATABASE IF EXISTS radarr;
DROP DATABASE IF EXISTS lidarr;
DROP DATABASE IF EXISTS bazarr;
DROP DATABASE IF EXISTS prowlarr;
DROP DATABASE IF EXISTS seerr;
DROP DATABASE IF EXISTS kestra;
DROP DATABASE IF EXISTS authelia;
EOF

psql -d postgres -c 'DROP ROLE IF EXISTS "<app-db-user>";'
psql -d postgres -c 'DROP ROLE IF EXISTS "<kestra-db-user>";'
psql -d postgres -c 'DROP ROLE IF EXISTS "<authelia-db-user>";'
```

A role cannot be dropped while it still owns objects, so drop the databases first. The client
certificates issued for those roles become useless but are harmless; remove them from
`./data/certs/` if you want the machine clean.

## Troubleshooting

**`connection requires a valid client certificate` (SQLSTATE 28000)**
The connection carried no certificate. Almost always because the commands were run from a directory
other than `<deploy-dir>`, so the relative paths in `PGSSLCERT`/`PGSSLKEY` pointed nowhere. Confirm
with `ls -l ./data/certs/` from your current directory.

**`certificate authentication failed for user "<admin-user>"`**
The administrative certificate's Common Name is not the superuser's name. Check with
`openssl x509 -in ./data/certs/postgres_admin.crt -noout -subject`. It has to be re-issued on the
database machine; nothing on this side can work around it.

**`no pg_hba.conf entry for host "…"`**
This machine's address is not covered by the server's access policy. It needs a
`hostssl … cert clientcert=verify-full` line for this machine's subnet on the database server, then
a configuration reload there.

**`private key file "…" has group or world access`**
`postgres_admin.key` is too permissive. `sudo chmod 0640` and make sure the group matches the account
reading it.

**`role already exists`**
Harmless — the account was created on an earlier pass. Do **not** re-run `CREATE ROLE … PASSWORD` to
"fix" it; that resets a working password. Use `ALTER ROLE` if you actually intend to change it.

**`database already exists`**
Also harmless, but note that its grants were not re-applied. If the application misbehaves with a
privilege error, run the grant block from Step 3 against that database explicitly.

**`permission denied for schema public` on an application's first start**
The grant block never ran for that database — the most common outcome of the existence check
skipping a database that was created by hand earlier. Run Step 3's grants against it.

**`syntax error at or near "-"`**
A hyphenated database name was used unquoted. Wrap `sonarr-log` and friends in double quotes.

**`database "…" is being accessed by other users` on drop**
An application still holds a connection. Stop its container, or terminate the sessions:
`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '<database>';`
