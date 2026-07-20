# Role: bibliography

## Purpose

Deploys the custom `bibliography` web application (image `nemanjaslijepcevic/bibliography`, a Django-style app) as a Docker container backed by a bundled SQLite database. On first run the role seeds the database from a shipped `db.sqlite3`; on subsequent runs the existing database is preserved.

## Prerequisites

- `common`, `traefik` roles must have run.
- Variables: `user.*`, `default.dns`, `bibliography.*`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the directories

```bash
mkdir -p ./data/bibliography/staticfiles
chown -R <username>:docker ./data/bibliography
chmod 0755 ./data/bibliography
```

---

#### Step 2: Seed the SQLite database (first run only)

Copy the shipped database **only if one does not already exist** — never overwrite live data:

```bash
if [ ! -f ./data/bibliography/db.sqlite3 ]; then
  cp <role>/files/db.sqlite3 ./data/bibliography/db.sqlite3
  chown <username>:docker ./data/bibliography/db.sqlite3
fi
```

> `*.sqlite3` is globally gitignored — the seed DB in `files/` is the only tracked copy; live data under `./data/` stays local.

---

#### Step 3: Start the container

```bash
sudo docker run -d \
  --name bibliography \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  --dns <dns-ip> \
  -e TZ=Europe/Belgrade \
  -e DEFAULT_DOMAIN=books.your-domain.com \
  -e EXTRA_DOMAIN=library.your-domain.com \
  -e SECRET_KEY='<secret>' \
  -v $(pwd)/data/bibliography/db.sqlite3:/app/db.sqlite3 \
  -v $(pwd)/data/bibliography/staticfiles:/app/staticfiles \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.bibliography.entrypoints=https' \
  --label 'traefik.http.routers.bibliography.rule=Host(`books.your-domain.com`)' \
  --label 'traefik.http.routers.bibliography.tls=true' \
  --label 'traefik.http.services.bibliography.loadbalancer.server.port=8000' \
  nemanjaslijepcevic/bibliography:latest
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `bibliography.static` | `<docker-ip>` | Static IP on proxy network |
| `bibliography.domain` | `books.your-domain.com` | Primary domain (`DEFAULT_DOMAIN`) |
| `bibliography.extra_domain` | `library.your-domain.com` | Secondary domain (`EXTRA_DOMAIN`) |
| `bibliography.secret_key` | `<secret>` | Django `SECRET_KEY` |
| `bibliography.host` | `` Host(`books.your-domain.com`) `` | Traefik host rule |
| `bibliography.port` | `8000` | Internal container port |
| `default.dns` | `<dns-ip>` | DNS server passed to the container |

---

## Verification

```bash
sudo docker ps | grep bibliography
sudo docker logs bibliography --tail 20
curl -ksI https://books.your-domain.com
```

---

## Rollback / Uninstall

```bash
sudo docker stop bibliography && sudo docker rm bibliography
# NOTE: keeps ./data/bibliography (contains the live database)
```

---

## Troubleshooting

**Database reset on redeploy**
The copy step must be guarded by the `if [ ! -f … ]` check (Ansible uses a `stat` + `when: not file_stat.stat.exists`). Running an unconditional copy overwrites live data with the seed DB.

**Static assets missing / 404 on CSS**
Ensure the `staticfiles` volume is mounted and writable; the app collects static files into `/app/staticfiles` on start.
