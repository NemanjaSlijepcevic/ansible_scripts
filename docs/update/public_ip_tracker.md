# Role: public_ip_tracker

## Purpose

Deploys a custom Docker container (`<dockerhub-user>/public_ip_tracker`) on the monitor host that periodically queries an external API to discover the current public IP address of the host and stores/serves it. Other services (such as `public_ip_whitelist_updater`) query this service to keep Traefik's IP whitelist up to date. The application log is set up with logrotate to prevent unbounded growth.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- Variables: `public_ip_tracker.*`, `api_ip_token`, `node.ip.*`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create data directory and log file

```bash
mkdir -p ./data/public_ip_tracker
chown <username>:docker ./data/public_ip_tracker
chmod 0744 ./data/public_ip_tracker

# Create the log file if it doesn't exist
touch ./data/public_ip_tracker/app.log
chmod 0755 ./data/public_ip_tracker/app.log
chown <username>:docker ./data/public_ip_tracker/app.log
```

---

#### Step 2: Start the public_ip_tracker container

```bash
sudo docker run -d \
  --name public_ip_tracker \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e API_IP_TOKEN=<secret> \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/public_ip_tracker/app.log:/app/app.log:rw \
  --label traefik.enable=true \
  --label "traefik.http.routers.public_ip_tracker.entrypoints=https" \
  --label "traefik.http.routers.public_ip_tracker.rule=Host(\`node-monitor-ip.your-domain.com\`)" \
  --label "traefik.http.routers.public_ip_tracker.tls=true" \
  --label "traefik.http.services.public_ip_tracker.loadbalancer.server.port=5000" \
  <dockerhub-user>/public_ip_tracker:latest
```

---

#### Step 3: Configure log rotation

```bash
sudo nano /etc/logrotate.d/public_ip_tracker
```

```
/path/to/data/public_ip_tracker/app.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0755
    sharedscripts
    postrotate
        systemctl reload rsyslog
    endscript
}
```

Replace `/path/to/data` with the actual absolute path to the working directory (e.g., `/home/<username>`).

```bash
sudo chmod 0644 /etc/logrotate.d/public_ip_tracker
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `public_ip_tracker.static` | `<docker-ip>` | Static IP on proxy network |
| `node.ip.host` | `Host(\`node-monitor-ip.your-domain.com\`)` | Traefik router rule |
| `node.ip.port` | `5000` | Application port |
| `api_ip_token` | `<secret>` | Token for the IP tracking API |

---

## Verification

```bash
sudo docker ps | grep public_ip_tracker
curl -sk https://node-monitor-ip.your-domain.com/current_ip
sudo docker logs public_ip_tracker --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop public_ip_tracker && sudo docker rm public_ip_tracker
rm -rf ./data/public_ip_tracker
sudo rm /etc/logrotate.d/public_ip_tracker
```
