# Role: sonarr

## Purpose

Deploys Sonarr (TV show manager) as a Docker container. Sonarr monitors RSS feeds, automatically searches for new episodes, and sends download tasks to Transmission. It uses PostgreSQL for its database. After the container starts and becomes healthy, the role automatically configures:

1. Transmission as the download client (via the Sonarr API).
2. Sonarr as an application in Prowlarr (for indexer sync).
3. Telegram notifications for grab, download, and health events.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- `transmission` and `prowlarr` roles must have run (Sonarr registers with them via API).
- `prepare_postgres` must have run (`sonarr` database exists).
- Variables: `sonarr.*`, `postgres.*`, `transmission.*`, `prowlarr.*`, `log_notification.*`, `puid`, `pgid`, `tv_drive`, `download_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/sonarr
chown <username>:docker ./data/sonarr
chmod 0755 ./data/sonarr
```

---

#### Step 2: Start the Sonarr container

```bash
sudo docker run -d \
  --name sonarr \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -e SONARR__AUTH__APIKEY=<sonarr_api_key> \
  -e SONARR__AUTH__METHOD=Forms \
  -e SONARR__AUTH__REQUIRED=Enabled \
  -e SONARR__SERVER__PORT=8989 \
  -e SONARR__POSTGRES__HOST=<ip-address> \
  -e SONARR__POSTGRES__PORT=5432 \
  -e SONARR__POSTGRES__USER=<db-username> \
  -e SONARR__POSTGRES__PASSWORD=<postgres_password> \
  -e SONARR__POSTGRES__MAINDB=sonarr \
  -v $(pwd)/data/sonarr/config:/config \
  -v <tv_drive>/Serije:/tv \
  -v <download_drive>/Download:/downloads \
  --label traefik.enable=true \
  --label "traefik.http.routers.sonarr.entrypoints=https" \
  --label "traefik.http.routers.sonarr.rule=Host(\`sonarr.your-domain.com\`)" \
  --label "traefik.http.routers.sonarr.tls=true" \
  --label "traefik.http.services.sonarr.loadbalancer.server.port=8989" \
  lscr.io/linuxserver/sonarr:latest
```

---

#### Step 3: Wait for Sonarr to be ready

```bash
until curl -sf http://localhost:8989/ping; do
  echo "Waiting for Sonarr..."
  sleep 10
done
```

---

#### Step 4: Configure Transmission as download client

Run only if Transmission is not already configured (check first):

```bash
EXISTING=$(curl -s http://localhost:8989/api/v3/downloadclient \
  -H "X-Api-Key: <sonarr_api_key>" | jq '[.[] | select(.name=="Transmission")] | length')

if [ "$EXISTING" -eq 0 ]; then
  curl -s -X POST http://localhost:8989/api/v3/downloadclient \
    -H "X-Api-Key: <sonarr_api_key>" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "Transmission",
      "implementation": "Transmission",
      "protocol": "torrent",
      "enable": true,
      "fields": [
        {"name": "host", "value": "transmission"},
        {"name": "port", "value": 9091},
        {"name": "useSsl", "value": false},
        {"name": "username", "value": "<transmission_user>"},
        {"name": "password", "value": "<transmission_password>"},
        {"name": "tvCategory", "value": "tv-sonarr"},
        {"name": "recentTvPriority", "value": 0}
      ]
    }'
fi
```

---

#### Step 5: Register Sonarr in Prowlarr

```bash
EXISTING=$(curl -s http://localhost:9696/api/v1/applications \
  -H "X-Api-Key: <prowlarr_api_key>" | jq '[.[] | select(.name=="Sonarr")] | length')

if [ "$EXISTING" -eq 0 ]; then
  curl -s -X POST http://localhost:9696/api/v1/applications \
    -H "X-Api-Key: <prowlarr_api_key>" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "Sonarr",
      "implementation": "Sonarr",
      "implementationName": "Sonarr",
      "configContract": "SonarrSettings",
      "fields": [
        {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
        {"name": "baseUrl", "value": "http://sonarr:8989"},
        {"name": "apiKey", "value": "<sonarr_api_key>"},
        {"name": "syncCategories", "value": [5000, 5030, 5040]}
      ]
    }'
fi
```

---

#### Step 6: Configure Telegram notification

```bash
EXISTING=$(curl -s http://localhost:8989/api/v3/notification \
  -H "X-Api-Key: <sonarr_api_key>" | jq '[.[] | select(.name=="Telegram")] | length')

if [ "$EXISTING" -eq 0 ]; then
  curl -s -X POST http://localhost:8989/api/v3/notification \
    -H "X-Api-Key: <sonarr_api_key>" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "Telegram",
      "implementation": "Telegram",
      "configContract": "TelegramSettings",
      "onGrab": true,
      "onDownload": true,
      "onUpgrade": true,
      "onRename": false,
      "onHealthIssue": true,
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
| `sonarr.api_key` | `<secret>` | Sonarr API key |
| `sonarr.host` | `Host(\`sonarr.your-domain.com\`)` | Traefik router rule |
| `sonarr.port` | `8989` | Sonarr port |
| `postgres.*` | see prepare_postgres.md | Database connection |
| `transmission.user` / `.password` | credentials | Transmission RPC credentials |
| `prowlarr.api_key` | `<secret>` | Prowlarr API key |
| `log_notification.telegram_bot` | (token) | Telegram bot token |
| `log_notification.chat_id` | `<telegram-chat-id>` | Telegram chat ID |
| `tv_drive` | `/srv/dev-disk-by-uuid-...` | Path to TV show storage |
| `download_drive` | `/srv/dev-disk-by-uuid-...` | Path to download directory |

---

## Verification

```bash
sudo docker ps | grep sonarr
curl -H "X-Api-Key: <api_key>" http://localhost:8989/api/v3/system/status | jq .version
```

---

## Rollback / Uninstall

```bash
sudo docker stop sonarr && sudo docker rm sonarr
rm -rf ./data/sonarr
```
