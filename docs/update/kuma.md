# Role: kuma

## Purpose

Deploys Uptime Kuma as a Docker container on the monitor host. Uptime Kuma is a self-hosted monitoring tool that periodically checks the availability of URLs, TCP ports, and other services, and provides a status page with incident history. It is accessible via Traefik at its configured subdomain.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- Variables: `kuma.*`, `default.dns`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create data directories

```bash
mkdir -p ./data/kuma/data
chown <username>:docker ./data/kuma ./data/kuma/data
chmod 0755 ./data/kuma ./data/kuma/data
```

---

#### Step 2: Start the Uptime Kuma container

```bash
sudo docker run -d \
  --name uptime-kuma \
  --restart always \
  --network proxy \
  --ip <docker-ip> \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/kuma/data:/app/data \
  --label traefik.enable=true \
  --label "traefik.http.routers.kuma.entrypoints=https" \
  --label "traefik.http.routers.kuma.rule=Host(\`kuma.your-domain.com\`)" \
  --label "traefik.http.routers.kuma.tls=true" \
  --label "traefik.http.services.kuma.loadbalancer.server.port=3001" \
  louislam/uptime-kuma:latest
```

On first access, create an admin account. All monitors are configured through the web UI.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `kuma.static` | `<docker-ip>` | Static IP on proxy network |
| `kuma.host` | `Host(\`kuma.your-domain.com\`)` | Traefik router rule |
| `kuma.port` | `3001` | Kuma web UI port |
| `default.dns` | `<local-dns-ip>` | DNS server for container |

---

## Verification

```bash
sudo docker ps | grep uptime-kuma
curl -sk https://kuma.your-domain.com/api/entry-page | jq .
```

---

## Rollback / Uninstall

```bash
sudo docker stop uptime-kuma && sudo docker rm uptime-kuma
rm -rf ./data/kuma
```
