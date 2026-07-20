# Role: influxdb

## Purpose

Deploys InfluxDB 2.x as a Docker container on the monitor host. InfluxDB is the time-series database that receives metrics from Telegraf and makes them available to Grafana dashboards. The container persists data in `./data/influxdb/` and is exposed via Traefik at its configured subdomain.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- Variables: `influxdb.*`, `default.dns`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/influxdb
chown <username>:docker ./data/influxdb
chmod 0755 ./data/influxdb
```

#### Step 2: Start the InfluxDB container

```bash
sudo docker run -d \
  --name influxdb \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/influxdb:/var/lib/influxdb2 \
  --label traefik.enable=true \
  --label "traefik.http.routers.influxdb.entrypoints=https" \
  --label "traefik.http.routers.influxdb.rule=Host(\`influxdb.your-domain.com\`)" \
  --label "traefik.http.routers.influxdb.tls=true" \
  --label "traefik.http.services.influxdb.loadbalancer.server.port=8086" \
  influxdb:latest
```

On first run, InfluxDB requires initial setup via the web UI at `https://influxdb.your-domain.com`. Configure:
- Organization: (your organization name, stored in `influxdb.organization`)
- Bucket: (your bucket name, stored in `influxdb.bucket`)
- Admin token (save this — it is used by Telegraf and Grafana)

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `influxdb.static` | `<docker-ip>` | Static IP on proxy network |
| `influxdb.host` | `Host(\`influxdb.your-domain.com\`)` | Traefik router rule |
| `influxdb.port` | `8086` | InfluxDB API port |
| `influxdb.api_token` | `<secret>` | Admin API token (set after first-run setup) |
| `influxdb.organization` | `<org-name>` | InfluxDB organization name |
| `influxdb.bucket` | `<bucket-name>` | Default data bucket |
| `default.dns` | `<local-dns-ip>` | DNS server for the container |

---

## Verification

```bash
sudo docker ps | grep influxdb
curl -sk https://influxdb.your-domain.com/health | jq .
sudo docker logs influxdb --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop influxdb && sudo docker rm influxdb
rm -rf ./data/influxdb
```

---

## Troubleshooting

**Web UI returns 502 Bad Gateway**
InfluxDB may still be starting. Wait 30 seconds and retry. Check: `sudo docker logs influxdb --tail 20`.

**Telegraf cannot write data**
Check the InfluxDB token, organization, and bucket match `telegraf.conf`. Test: `curl -H "Authorization: Token <secret>" https://influxdb.your-domain.com/api/v2/buckets`.
