# Role: lidarr

## Purpose

Deploys Lidarr (music manager) as a Docker container. Lidarr monitors for new music releases, searches via Prowlarr, and downloads via Transmission. It uses PostgreSQL for persistence. After startup the role auto-configures Transmission, registers Lidarr in Prowlarr (sync categories: music), and sets up Telegram notifications.

## Prerequisites

- `common`, `traefik`, `transmission`, `prowlarr` roles must have run.
- `prepare_postgres` must have run (`lidarr` database exists).
- Variables: `lidarr.*`, `postgres.*`, `transmission.*`, `prowlarr.*`, `log_notification.*`, `puid`, `pgid`, `music_drive`, `download_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/lidarr
chown <username>:docker ./data/lidarr
chmod 0755 ./data/lidarr
```

---

#### Step 2: Start the Lidarr container

```bash
sudo docker run -d \
  --name lidarr \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -e LIDARR__AUTH__APIKEY=<lidarr_api_key> \
  -e LIDARR__AUTH__METHOD=Forms \
  -e LIDARR__AUTH__REQUIRED=Enabled \
  -e LIDARR__SERVER__PORT=8686 \
  -e LIDARR__POSTGRES__HOST=<ip-address> \
  -e LIDARR__POSTGRES__PORT=5432 \
  -e LIDARR__POSTGRES__USER=<db-username> \
  -e LIDARR__POSTGRES__PASSWORD=<postgres_password> \
  -e LIDARR__POSTGRES__MAINDB=lidarr \
  -v $(pwd)/data/lidarr/config:/config \
  -v <music_drive>/Muzika:/music \
  -v <download_drive>/Download:/downloads \
  --label traefik.enable=true \
  --label "traefik.http.routers.lidarr.entrypoints=https" \
  --label "traefik.http.routers.lidarr.rule=Host(\`lidarr.your-domain.com\`)" \
  --label "traefik.http.routers.lidarr.tls=true" \
  --label "traefik.http.services.lidarr.loadbalancer.server.port=8686" \
  lscr.io/linuxserver/lidarr:latest
```

After starting, configure Transmission (download client), Prowlarr (sync categories `[3000, 3010, 3020, 3030, 3040]` for Music), and Telegram notification via the Lidarr API (port 8686, `/api/v1/` prefix) — same pattern as Sonarr and Radarr.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `lidarr.api_key` | `<secret>` | Lidarr API key |
| `lidarr.host` | `Host(\`lidarr.your-domain.com\`)` | Traefik router rule |
| `lidarr.port` | `8686` | Lidarr port |
| `music_drive` | `/srv/dev-disk-by-uuid-...` | Path to music storage |
| `download_drive` | `/srv/dev-disk-by-uuid-...` | Path to download directory |

---

## Verification

```bash
sudo docker ps | grep lidarr
curl -H "X-Api-Key: <api_key>" http://localhost:8686/api/v1/system/status | jq .version
```

---

## Rollback / Uninstall

```bash
sudo docker stop lidarr && sudo docker rm lidarr
rm -rf ./data/lidarr
```
