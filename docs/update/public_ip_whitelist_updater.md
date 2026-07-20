# Role: public_ip_whitelist_updater

## Purpose

Deploys a custom Docker container (`<dockerhub-user>/public_ip_updater`) on the server host. This service queries the `public_ip_tracker` API running on the monitor host to get the current public IP address of the network, then updates the Traefik `default-whitelist.yml` rule file in real time. This allows the Traefik IP allowlist to automatically update whenever the home network's public IP changes, maintaining access without manual intervention.

The container mounts the live Traefik whitelist rule file (`./data/traefik/rules/default-whitelist.yml`) read-write, so changes take effect immediately since Traefik watches the `/rules` directory.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run (provides `./data/traefik/rules/default-whitelist.yml`).
- `public_ip_tracker` must be running on the monitor host.
- Variables: `public_ip_whitelist_updater.*`, `api_ip_token`, `public_ip_url`, `default.dns`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create data directory and log file

```bash
mkdir -p ./data/public_ip_whitelist_updater
chown <username>:docker ./data/public_ip_whitelist_updater
chmod 0744 ./data/public_ip_whitelist_updater

touch ./data/public_ip_whitelist_updater/app.log
chmod 0755 ./data/public_ip_whitelist_updater/app.log
chown <username>:docker ./data/public_ip_whitelist_updater/app.log
```

---

#### Step 2: Start the public_ip_whitelist_updater container

```bash
sudo docker run -d \
  --name public_ip_whitelist_updater \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <local-dns-ip> \
  -e API_IP_TOKEN=<secret> \
  -e NODE_IP_DOMAIN=https://node-monitor-ip.your-domain.com/current_ip \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/traefik/rules/default-whitelist.yml:/app/configuration.yml:rw \
  -v $(pwd)/data/public_ip_whitelist_updater/app.log:/app/app.log:rw \
  <dockerhub-user>/public_ip_updater:latest
```

**Key volume mounts**:
- The Traefik `default-whitelist.yml` is mounted read-write. When the IP changes, the container rewrites this file. Traefik's file provider picks up the change immediately without a restart.
- The log file is mounted so logrotate can manage it from the host.

---

#### Step 3: Configure log rotation

```bash
sudo nano /etc/logrotate.d/whitlist_updater
```

```
/path/to/data/public_ip_whitelist_updater/app.log {
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
sudo chmod 0644 /etc/logrotate.d/whitlist_updater
```

Note: the logrotate file is named `whitlist_updater` (with the typo from the Ansible role) to match the existing system configuration.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `public_ip_whitelist_updater.static` | `<docker-ip>` | Static IP on proxy network |
| `api_ip_token` | `<secret>` | Authentication token for the IP API |
| `public_ip_url` | `https://node-monitor-ip.your-domain.com/current_ip` | URL of the public_ip_tracker endpoint |
| `default.dns` | `<local-dns-ip>` | DNS server for container |

---

## Verification

```bash
sudo docker ps | grep public_ip_whitelist_updater
sudo docker logs public_ip_whitelist_updater --tail 20
# Check the whitelist was updated with current public IP
cat ./data/traefik/rules/default-whitelist.yml
```

---

## Rollback / Uninstall

```bash
sudo docker stop public_ip_whitelist_updater && sudo docker rm public_ip_whitelist_updater
rm -rf ./data/public_ip_whitelist_updater
sudo rm /etc/logrotate.d/whitlist_updater
```

Note: Removing this container will leave the `default-whitelist.yml` frozen at whatever IP was last written. Update it manually if needed.
