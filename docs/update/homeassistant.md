# Role: homeassistant

## Purpose

Deploys Home Assistant (home automation platform) as a Docker container on the monitor host. This role also deploys the Mosquitto MQTT broker as a companion container, which Home Assistant uses for IoT device communication. Home Assistant has access to a USB serial device (`/dev/ttyUSB0`) for Zigbee/Z-Wave coordinator communication and the D-Bus socket for Bluetooth.

## Prerequisites

- `common`, `traefik` roles must have run.
- The USB Zigbee/Z-Wave coordinator must be connected at `/dev/ttyUSB0`.
- The `mosquitto.conf` file must exist in the Ansible role's files directory.
- Variables: `homeassistant.*`, `mqtt.*`.

## Manual Execution Guide

### Overview

1. Deploy Mosquitto MQTT broker.
2. Deploy Home Assistant.

---

### Step-by-Step Instructions

#### Step 1: Create data directories

```bash
mkdir -p ./data/homeassistant/config
chown <username>:docker ./data/homeassistant ./data/homeassistant/config
chmod 0755 ./data/homeassistant ./data/homeassistant/config

# Mosquitto directories (owned by UID 1883 — the mosquitto user)
mkdir -p ./data/mosquitto/data ./data/mosquitto/log ./data/mosquitto/config
chown -R 1883:1883 ./data/mosquitto
chmod 0755 ./data/mosquitto ./data/mosquitto/data ./data/mosquitto/log ./data/mosquitto/config
```

---

#### Step 2: Deploy mosquitto.conf

Copy the `mosquitto.conf` from the role's files directory to `./data/mosquitto/config/mosquitto.conf`. The exact content is in `update/roles/homeassistant/files/mosquitto.conf` (not shown in this documentation as it was not read — check the file directly).

```bash
cp /path/to/homeassistant/files/mosquitto.conf ./data/mosquitto/config/mosquitto.conf
chown 1883:1883 ./data/mosquitto/config/mosquitto.conf
chmod 0755 ./data/mosquitto/config/mosquitto.conf
```

---

#### Step 3: Start the Mosquitto container

```bash
sudo docker run -d \
  --name mosquitto \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -p 1883:1883 \
  -v $(pwd)/data/mosquitto:/mosquitto \
  -v $(pwd)/data/mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf \
  --label traefik.enable=true \
  --label "traefik.http.routers.mosquitto.entrypoints=https" \
  --label "traefik.http.routers.mosquitto.rule=Host(\`mqtt.your-domain.com\`)" \
  --label "traefik.http.routers.mosquitto.tls=true" \
  --label "traefik.http.services.mosquitto.loadbalancer.server.port=9001" \
  eclipse-mosquitto:latest
```

---

#### Step 4: Start the Home Assistant container

```bash
sudo docker run -d \
  --name homeassistant \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/homeassistant/config:/config \
  -v /run/dbus:/run/dbus:ro \
  --device /dev/ttyUSB0:/dev/ttyUSB0 \
  --label traefik.enable=true \
  --label "traefik.http.routers.homeassistant.entrypoints=https" \
  --label "traefik.http.routers.homeassistant.rule=Host(\`ha.your-domain.com\`)" \
  --label "traefik.http.routers.homeassistant.tls=true" \
  --label "traefik.http.services.homeassistant.loadbalancer.server.port=8123" \
  ghcr.io/home-assistant/home-assistant:stable
```

Note: `--privileged` is commented out in the Ansible role — Home Assistant can run without full privilege escalation when only specific devices are passed via `--device`.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `homeassistant.host` | `Host(\`ha.your-domain.com\`)` | Traefik router rule |
| `homeassistant.port` | `8123` | Home Assistant web UI port |
| `mqtt.host` | `Host(\`mqtt.your-domain.com\`)` | Mosquitto Traefik router rule |
| `mqtt.port` | `9001` | Mosquitto WebSocket port |

---

## Verification

```bash
sudo docker ps | grep -E 'homeassistant|mosquitto'
curl -sk https://ha.your-domain.com/api/ -H "Authorization: Bearer <ha_token>" | jq .message
```

---

## Rollback / Uninstall

```bash
sudo docker stop homeassistant mosquitto
sudo docker rm homeassistant mosquitto
rm -rf ./data/homeassistant ./data/mosquitto
```

**Warning**: Removing `./data/homeassistant/config` deletes all automations, entity configurations, and history stored in Home Assistant.

---

## Troubleshooting

**USB device not found in container**
Verify the device exists on the host: `ls -la /dev/ttyUSB0`. If the device number differs (e.g., `ttyUSB1`), update the `--device` flag. Consider using the device's `/dev/serial/by-id/` symlink for stability across reboots.

**Mosquitto authentication fails**
Check `./data/mosquitto/config/mosquitto.conf` for `allow_anonymous` and `password_file` settings. If a password file is required, create it with `mosquitto_passwd`.

**Home Assistant cannot reach Mosquitto**
Both containers must be on the `proxy` Docker network. Home Assistant connects to Mosquitto using the container name `mosquitto` as the hostname in the MQTT integration settings.
