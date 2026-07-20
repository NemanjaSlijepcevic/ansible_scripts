# Role: log_notification

## Purpose

Deploys a custom Docker container (`<dockerhub-user>/log_notification`) that monitors a log file for specific pattern matches and sends Telegram notifications when those patterns are found. The container and the patterns it watches are configured differently per host:

- **Server host**: Monitors `public_ip_whitelist_updater/app.log` for `WARNING`, `EXCEPTION`, `ERROR`, `INFO`.
- **Monitor host**: Monitors `public_ip_tracker/app.log` for `WARNING`, `EXCEPTION`, `ERROR`, `IP has changed`.

The `IP has changed` pattern on the monitor host allows real-time notification whenever the home network's public IP address changes.

## Prerequisites

- `common` role must have run.
- `public_ip_tracker` (monitor) or `public_ip_whitelist_updater` (server) must have run and the log file must exist.
- Variables: `log_notification.*`, `current_host`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/log_notification
chmod 0744 ./data/log_notification
```

---

#### Step 2: Start the log_notification container

**For the monitor host** (watches public_ip_tracker log):

```bash
sudo docker run -d \
  --name log_notification \
  --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=<telegram_bot_token> \
  -e TELEGRAM_CHAT_ID=<telegram_chat_id> \
  -e NOTIFICATION_PATTERNS="WARNING, EXCEPTION, ERROR, IP has changed" \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/public_ip_tracker/app.log:/app/logs/public_ip.log \
  <dockerhub-user>/log_notification:latest
```

**For the server host** (watches public_ip_whitelist_updater log):

```bash
sudo docker run -d \
  --name log_notification \
  --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=<telegram_bot_token> \
  -e TELEGRAM_CHAT_ID=<telegram_chat_id> \
  -e NOTIFICATION_PATTERNS="WARNING, EXCEPTION, ERROR, INFO" \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/public_ip_whitelist_updater/app.log:/app/logs/whitelist.log \
  <dockerhub-user>/log_notification:latest
```

Replace `<telegram_bot_token>` and `<telegram_chat_id>` with values from `log_notification.telegram_bot` and `log_notification.chat_id` in `group_vars/all.yml`.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `log_notification.telegram_bot` | `<secret>` | Telegram Bot API token |
| `log_notification.chat_id` | `<telegram-chat-id>` | Telegram chat/user ID to send notifications to |
| `current_host` | `server`/`monitor` | Determines which log file and patterns to use |

### Behaviour per host

| Host | Log file monitored | Patterns |
|------|--------------------|---------|
| `server` | `./data/public_ip_whitelist_updater/app.log` | WARNING, EXCEPTION, ERROR, INFO |
| `monitor` | `./data/public_ip_tracker/app.log` | WARNING, EXCEPTION, ERROR, IP has changed |

---

## Verification

```bash
sudo docker ps | grep log_notification
sudo docker logs log_notification --tail 20
# Trigger a test by writing a matching pattern to the monitored log
echo "TEST WARNING message" >> ./data/public_ip_tracker/app.log
# Check Telegram for the notification
```

---

## Rollback / Uninstall

```bash
sudo docker stop log_notification && sudo docker rm log_notification
rm -rf ./data/log_notification
```
