# Role: kaleidoscope

## Purpose

This role deploys the **Kaleidoscope** web application — a custom Django-based image gallery application (`<dockerhub-user>/kaleidoscope`) served through Traefik. It creates the required directory structure, seeds an initial SQLite database (only if one does not already exist), and starts the container with per-instance configuration via environment variables.

The application supports watermarked image display and operates across multiple domains via `DEFAULT_DOMAIN` and `EXTRA_DOMAIN` settings.

## Prerequisites

- `common` and `traefik` roles must have run.
- The `kaleidoscope.*` variable block must be defined in `host_vars/primary_server.yml`.
- If pre-seeding the database, a `db.sqlite3` file must exist in the Ansible working directory (`./db.sqlite3` relative to the playbook).
- The proxy Docker network (`<docker-subnet>`) must exist.

## Manual Execution Guide

### Overview

1. Create the data directories on the host.
2. Copy the initial SQLite database (if not already present).
3. Start the Kaleidoscope Docker container.

---

### Step-by-Step Instructions

#### Step 1: Create data directories

**Purpose**: Kaleidoscope needs separate directories for the database, collected static files (CSS/JS), and uploaded media.

```bash
sudo mkdir -p ./data/kaleidoscope
sudo mkdir -p ./data/kaleidoscope/staticfiles
sudo mkdir -p ./data/kaleidoscope/media
sudo chown -R <user>:<group> ./data/kaleidoscope
sudo chmod -R 0755 ./data/kaleidoscope
```

Replace `<user>` and `<group>` with the values from `user.name` and `user.group` in the inventory (e.g., `<username>:docker`).

---

#### Step 2: Seed the SQLite database (first deploy only)

**Purpose**: On first deployment, if no database exists yet, copy a pre-existing database file to initialize the application schema and any seed data.

```bash
# Only run this if ./data/kaleidoscope/db.sqlite3 does not exist
if [ ! -f ./data/kaleidoscope/db.sqlite3 ]; then
  cp ./db.sqlite3 ./data/kaleidoscope/db.sqlite3
  chmod 0755 ./data/kaleidoscope/db.sqlite3
  chown <user>:<group> ./data/kaleidoscope/db.sqlite3
fi
```

On subsequent runs, this step is skipped — the existing database is preserved.

---

#### Step 3: Start the Kaleidoscope container

**Purpose**: Run the Django application behind Traefik with the correct domain and secret key configuration.

```bash
sudo docker run -d \
  --name kaleidoscope \
  --restart unless-stopped \
  --network proxy \
  --ip <kaleidoscope-static-ip> \
  --dns <default-dns> \
  -e TZ=Europe/Belgrade \
  -e DEFAULT_DOMAIN=<kaleidoscope-domain> \
  -e EXTRA_DOMAIN=<extra-domain> \
  -e SECRET_KEY=<secret-key> \
  -e IMAGE_WATERMARK_TEXT=<watermark-text> \
  -v ./data/kaleidoscope/db.sqlite3:/app/db.sqlite3 \
  -v ./data/kaleidoscope/staticfiles:/app/staticfiles \
  -v ./data/kaleidoscope/media:/app/media \
  --label traefik.enable=true \
  --label "traefik.http.routers.kaleidoscope.entrypoints=https" \
  --label "traefik.http.routers.kaleidoscope.rule=<kaleidoscope-host-rule>" \
  --label "traefik.http.routers.kaleidoscope.tls=true" \
  --label "traefik.http.services.kaleidoscope.loadbalancer.server.port=<kaleidoscope-port>" \
  <dockerhub-user>/kaleidoscope:latest
```

**Explanation of environment variables**:

| Variable | Description |
|----------|-------------|
| `DEFAULT_DOMAIN` | Primary domain the Django app uses for generating absolute URLs |
| `EXTRA_DOMAIN` | Secondary domain accepted by the application (Django `ALLOWED_HOSTS`) |
| `SECRET_KEY` | Django secret key — must be long, random, and kept secret |
| `IMAGE_WATERMARK_TEXT` | Text string embedded as a watermark on served images |

---

## Configuration Reference

### Variables (from `host_vars/primary_server.yml`)

| Variable | Example | Description |
|----------|---------|-------------|
| `kaleidoscope.domain` | `kaleidoskop.your-domain.com` | Primary domain |
| `kaleidoscope.extra_domain` | `your-domain.com` | Secondary allowed domain |
| `kaleidoscope.host` | `Host(\`kaleidoskop.your-domain.com\`)` | Traefik routing rule |
| `kaleidoscope.port` | `8000` | Internal Django port |
| `kaleidoscope.static` | `<static-ip>` | Static IP on the proxy network |
| `kaleidoscope.secret_key` | `<secret>` | Django SECRET_KEY |
| `kaleidoscope.watermark` | `<watermark-text>` | Watermark text on images |

### Volumes

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `./data/kaleidoscope/db.sqlite3` | `/app/db.sqlite3` | SQLite database |
| `./data/kaleidoscope/staticfiles` | `/app/staticfiles` | Django collected static files |
| `./data/kaleidoscope/media` | `/app/media` | User-uploaded media files |

---

## Handlers & Service Management

This role has no Ansible handlers. The container uses `restart_policy: unless-stopped` and is self-healing.

---

## Verification

```bash
# Confirm the container is running
sudo docker ps | grep kaleidoscope

# Check container logs for Django startup errors
sudo docker logs kaleidoscope --tail 50

# Test HTTPS via Traefik
curl -sk https://<kaleidoscope-domain>/ | head -10
```

---

## Rollback / Uninstall

```bash
sudo docker stop kaleidoscope
sudo docker rm kaleidoscope
sudo rm -rf ./data/kaleidoscope
```

The SQLite database is inside `./data/kaleidoscope/db.sqlite3`. Back it up before removing if the data is needed.

---

## Troubleshooting

**Container starts but returns 500 errors**
Check logs: `sudo docker logs kaleidoscope`. Common cause: `SECRET_KEY` is empty or malformed, or the database file is corrupt/incompatible with the current schema.

**Static files not loading (CSS/JS missing)**
The `staticfiles/` directory must be populated. On first run, Django's `collectstatic` should run automatically at container startup. If not, exec into the container: `sudo docker exec -it kaleidoscope python manage.py collectstatic --noinput`.

**Domain not resolving / Traefik not routing**
Verify the container is on the `proxy` network (`sudo docker inspect kaleidoscope | grep proxy`) and that the Traefik label rules match the DNS records.
