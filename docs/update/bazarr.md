# Role: bazarr

## Purpose

Deploys Bazarr (subtitle manager) as a Docker container. Bazarr automatically downloads subtitles for movies and TV shows managed by Radarr and Sonarr. Unlike the \*arr apps, Bazarr uses an INI-format configuration file rather than environment variables for most settings. This role writes the config file before starting the container, then uses the Bazarr API to configure its connections to Sonarr and Radarr.

Bazarr uses PostgreSQL as its database backend and sends Telegram notifications via its own built-in notification system.

## Prerequisites

- `common`, `traefik`, `sonarr`, `radarr` roles must have run.
- `prepare_postgres` must have run (`bazarr` database exists).
- Variables: `bazarr.*`, `postgres.*`, `sonarr.*`, `radarr.*`, `log_notification.*`, `puid`, `pgid`, `movie_drive`, `tv_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create data directories

```bash
mkdir -p ./data/bazarr/config
chown <username>:docker ./data/bazarr ./data/bazarr/config
chmod 0755 ./data/bazarr ./data/bazarr/config
```

---

#### Step 2: Write the config.ini file

The configuration is written section-by-section before the container starts. Create `./data/bazarr/config/config.ini`:

```bash
nano ./data/bazarr/config/config.ini
```

```ini
[General]
apikey = <bazarr_api_key>
telegram_enabled = True
telegram_token = <telegram_bot_token>
telegram_userid = <telegram_chat_id>

[Database]
type = postgresql
host = <ip-address>
port = 5432
name = bazarr
user = <db-username>
password = <secret>
```

```bash
chmod 0644 ./data/bazarr/config/config.ini
```

---

#### Step 3: Start the Bazarr container

```bash
sudo docker run -d \
  --name bazarr \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/bazarr/config:/config \
  -v <movie_drive>/Filmovi:/movies \
  -v <tv_drive>/Serije:/tv \
  --label traefik.enable=true \
  --label "traefik.http.routers.bazarr.entrypoints=https" \
  --label "traefik.http.routers.bazarr.rule=Host(\`bazarr.your-domain.com\`)" \
  --label "traefik.http.routers.bazarr.tls=true" \
  --label "traefik.http.services.bazarr.loadbalancer.server.port=6767" \
  lscr.io/linuxserver/bazarr:latest
```

---

#### Step 4: Wait for Bazarr to be ready

```bash
until curl -sf -H "X-API-KEY: <bazarr_api_key>" http://localhost:6767/api/system/status; do
  echo "Waiting for Bazarr..."
  sleep 10
done
```

---

#### Step 5: Configure Sonarr connection

```bash
curl -s -X PATCH http://localhost:6767/api/configuration/sonarr \
  -H "X-API-KEY: <bazarr_api_key>" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "ip": "sonarr",
    "port": 8989,
    "base_url": "",
    "use_ssl": false,
    "apikey": "<sonarr_api_key>"
  }'
```

---

#### Step 6: Configure Radarr connection

```bash
curl -s -X PATCH http://localhost:6767/api/configuration/radarr \
  -H "X-API-KEY: <bazarr_api_key>" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "ip": "radarr",
    "port": 7878,
    "base_url": "",
    "use_ssl": false,
    "apikey": "<radarr_api_key>"
  }'
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `bazarr.api_key` | `<secret>` | Bazarr API key |
| `bazarr.host` | `Host(\`bazarr.your-domain.com\`)` | Traefik router rule |
| `bazarr.port` | `6767` | Bazarr web UI port |
| `postgres.*` | see prepare_postgres.md | Database connection settings |
| `sonarr.api_key` | `<secret>` | Sonarr API key for Bazarr integration |
| `radarr.api_key` | `<secret>` | Radarr API key for Bazarr integration |
| `log_notification.telegram_bot` | (token) | Telegram bot token |
| `log_notification.chat_id` | (ID) | Telegram chat ID |

---

## Verification

```bash
sudo docker ps | grep bazarr
curl -H "X-API-KEY: <api_key>" http://localhost:6767/api/system/status | jq .
```

---

## Rollback / Uninstall

```bash
sudo docker stop bazarr && sudo docker rm bazarr
rm -rf ./data/bazarr
```
