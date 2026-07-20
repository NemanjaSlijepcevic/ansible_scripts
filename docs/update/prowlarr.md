# Role: prowlarr

## Purpose

Deploys Prowlarr (indexer manager) as a Docker container. Prowlarr manages torrent/Usenet indexers in a central place and syncs them to Sonarr, Radarr, and Lidarr. It uses PostgreSQL for persistence. After startup the role sets up a Telegram notification for health events.

## Prerequisites

- `common`, `traefik` roles must have run.
- `prepare_postgres` must have run (`prowlarr` database exists).
- Variables: `prowlarr.*`, `postgres.*`, `log_notification.*`, `puid`, `pgid`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/prowlarr
chown <username>:docker ./data/prowlarr
chmod 0755 ./data/prowlarr
```

---

#### Step 2: Start the Prowlarr container

```bash
sudo docker run -d \
  --name prowlarr \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -e PROWLARR__AUTH__APIKEY=<prowlarr_api_key> \
  -e PROWLARR__AUTH__METHOD=Forms \
  -e PROWLARR__AUTH__REQUIRED=Enabled \
  -e PROWLARR__SERVER__PORT=9696 \
  -e PROWLARR__POSTGRES__HOST=<ip-address> \
  -e PROWLARR__POSTGRES__PORT=5432 \
  -e PROWLARR__POSTGRES__USER=<db-username> \
  -e PROWLARR__POSTGRES__PASSWORD=<postgres_password> \
  -e PROWLARR__POSTGRES__MAINDB=prowlarr \
  -v $(pwd)/data/prowlarr/config:/config \
  --label traefik.enable=true \
  --label "traefik.http.routers.prowlarr.entrypoints=https" \
  --label "traefik.http.routers.prowlarr.rule=Host(\`prowlarr.your-domain.com\`)" \
  --label "traefik.http.routers.prowlarr.tls=true" \
  --label "traefik.http.services.prowlarr.loadbalancer.server.port=9696" \
  lscr.io/linuxserver/prowlarr:latest
```

---

#### Step 3: Wait for readiness and configure Telegram

```bash
until curl -sf http://localhost:9696/ping; do sleep 10; done

EXISTING=$(curl -s http://localhost:9696/api/v1/notification \
  -H "X-Api-Key: <prowlarr_api_key>" | jq '[.[] | select(.name=="Telegram")] | length')

if [ "$EXISTING" -eq 0 ]; then
  curl -s -X POST http://localhost:9696/api/v1/notification \
    -H "X-Api-Key: <prowlarr_api_key>" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "Telegram",
      "implementation": "Telegram",
      "configContract": "TelegramSettings",
      "onHealthIssue": true,
      "onApplicationUpdate": false,
      "fields": [
        {"name": "botToken", "value": "<telegram_bot_token>"},
        {"name": "chatId", "value": "<telegram_chat_id>"}
      ]
    }'
fi
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `prowlarr.api_key` | `<secret>` | Prowlarr API key |
| `prowlarr.host` | `Host(\`prowlarr.your-domain.com\`)` | Traefik router rule |
| `prowlarr.port` | `9696` | Prowlarr port |
| `postgres.*` | see prepare_postgres.md | Database connection |

---

## Verification

```bash
sudo docker ps | grep prowlarr
curl -H "X-Api-Key: <api_key>" http://localhost:9696/api/v1/system/status | jq .version
```

---

## Rollback / Uninstall

```bash
sudo docker stop prowlarr && sudo docker rm prowlarr
rm -rf ./data/prowlarr
```
