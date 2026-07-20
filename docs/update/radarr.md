# Role: radarr

## Purpose

Deploys Radarr (movie manager) as a Docker container. Radarr monitors for new movie releases, searches indexers via Prowlarr, and downloads via Transmission. It uses PostgreSQL for persistence. After startup, the role auto-configures Transmission as the download client, registers Radarr in Prowlarr, and sets up Telegram notifications — all via the Radarr API.

## Prerequisites

- `common`, `traefik`, `transmission`, `prowlarr` roles must have run.
- `prepare_postgres` must have run (`radarr` database exists).
- Variables: `radarr.*`, `postgres.*`, `transmission.*`, `prowlarr.*`, `log_notification.*`, `puid`, `pgid`, `movie_drive`, `download_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/radarr
chown <username>:docker ./data/radarr
chmod 0755 ./data/radarr
```

---

#### Step 2: Start the Radarr container

```bash
sudo docker run -d \
  --name radarr \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -e RADARR__AUTH__APIKEY=<radarr_api_key> \
  -e RADARR__AUTH__METHOD=Forms \
  -e RADARR__AUTH__REQUIRED=Enabled \
  -e RADARR__SERVER__PORT=7878 \
  -e RADARR__POSTGRES__HOST=<ip-address> \
  -e RADARR__POSTGRES__PORT=5432 \
  -e RADARR__POSTGRES__USER=<db-username> \
  -e RADARR__POSTGRES__PASSWORD=<postgres_password> \
  -e RADARR__POSTGRES__MAINDB=radarr \
  -v $(pwd)/data/radarr/config:/config \
  -v <movie_drive>/Filmovi:/movies \
  -v <download_drive>/Download:/downloads \
  --label traefik.enable=true \
  --label "traefik.http.routers.radarr.entrypoints=https" \
  --label "traefik.http.routers.radarr.rule=Host(\`radarr.your-domain.com\`)" \
  --label "traefik.http.routers.radarr.tls=true" \
  --label "traefik.http.services.radarr.loadbalancer.server.port=7878" \
  lscr.io/linuxserver/radarr:latest
```

After starting, wait for readiness (`curl http://localhost:7878/ping`), then use the Radarr API (port 7878, endpoint `/api/v3/downloadclient`, `/api/v3/notification`) to configure Transmission and Telegram — the same pattern shown in the `sonarr` role documentation, adapted for Radarr's API path and `movieCategory: "radarr"` field.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `radarr.api_key` | `<secret>` | Radarr API key |
| `radarr.host` | `Host(\`radarr.your-domain.com\`)` | Traefik router rule |
| `radarr.port` | `7878` | Radarr port |
| `movie_drive` | `/srv/dev-disk-by-uuid-...` | Path to movie storage |
| `download_drive` | `/srv/dev-disk-by-uuid-...` | Path to download directory |
| `postgres.*` | see prepare_postgres.md | Database connection |

Prowlarr sync categories for Radarr: `[2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060]` (Movies).

---

## Verification

```bash
sudo docker ps | grep radarr
curl -H "X-Api-Key: <api_key>" http://localhost:7878/api/v3/system/status | jq .version
```

---

## Rollback / Uninstall

```bash
sudo docker stop radarr && sudo docker rm radarr
rm -rf ./data/radarr
```
