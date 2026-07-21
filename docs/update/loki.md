# Role: loki

## Purpose

Deploys [Loki](https://grafana.com/docs/loki/latest/) as a Docker container — the central log-aggregation backend that receives streams from every host's Alloy agent. Runs on the `monitor` host with filesystem (TSDB) storage. After the container is healthy, the role auto-registers Loki as a data source in Grafana.

## Prerequisites

- `common`, `traefik`, and `grafana` roles must have run.
- Variables: `loki.*`, `grafana.url`, `grafana.admin_user`, `grafana.admin_password`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the directories

Loki's container runs as UID/GID `10001`, so the data dirs must be owned by that id.

```bash
mkdir -p ./data/loki/{chunks,rules,tsdb-shipper-cache}
sudo chown -R 10001:10001 ./data/loki
chmod 0755 ./data/loki
```

---

#### Step 2: Render the config

Generated from `loki/templates/loki-config.yml.j2` — single-binary mode, `auth_enabled: false`, filesystem storage under `/loki`, TSDB schema `v13`. Place the rendered file at `./data/loki/loki-config.yml` (owned `10001:10001`).

---

#### Step 3: Start the Loki container

```bash
sudo docker run -d \
  --name loki \
  --restart unless-stopped \
  --network proxy \
  -p 3100:3100 \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/loki:/loki \
  -v $(pwd)/data/loki/loki-config.yml:/etc/loki/loki-config.yml:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.loki.entrypoints=https' \
  --label 'traefik.http.routers.loki.rule=Host(`loki.your-domain.com`)' \
  --label 'traefik.http.routers.loki.tls=true' \
  --label 'traefik.http.routers.loki.middlewares=chain-auth@file' \
  --label 'traefik.http.services.loki.loadbalancer.server.port=3100' \
  grafana/loki:latest \
  -config.file=/etc/loki/loki-config.yml
```

---

#### Step 4: Wait for readiness, then register in Grafana

```bash
curl -sf https://loki.your-domain.com/ready

# Register the data source (skip if one named "Loki" already exists)
curl -s -u "<username>:<secret>" -X POST \
  https://grafana.your-domain.com/api/datasources \
  -H 'Content-Type: application/json' \
  -d '{"name":"Loki","type":"loki","access":"proxy","url":"http://loki:3100","jsonData":{"tlsSkipVerify":true}}'
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `loki.host` | `` Host(`loki.your-domain.com`) `` | Traefik host rule |
| `loki.url` | `https://loki.your-domain.com` | External URL (readiness probe) |
| `loki.port` | `3100` | HTTP listen port |
| `loki_log_level` | `info` | Loki `server.log_level`. Kept at Loki's default `info` — the per-query stats lines are filtered out of the error-only dashboard via a `!= "query_hash"` line filter (`grafana/files/loki-overview.json`) rather than silenced here, so query logs stay available. Lower to `warn` to silence at the source instead |
| `grafana.url` | `https://grafana.your-domain.com` | Grafana API endpoint for data-source registration |
| `grafana.admin_user` / `grafana.admin_password` | `<username>` / `<secret>` | Grafana admin basic-auth |

---

## Verification

```bash
sudo docker ps | grep loki
curl -sf https://loki.your-domain.com/ready && echo "ready"
# Confirm the data source exists
curl -s -u "<username>:<secret>" https://grafana.your-domain.com/api/datasources | grep -o '"name":"Loki"'
```

---

## Rollback / Uninstall

```bash
sudo docker stop loki && sudo docker rm loki
rm -rf ./data/loki
# Optionally remove the Grafana data source via the UI or API
```

---

## Troubleshooting

**Container restarts / permission denied on `/loki`**
The data directory must be owned by `10001:10001`. Re-run the `chown` in Step 1.

**Grafana data source not registered**
The role only POSTs when no data source named `Loki` exists. Check Grafana admin credentials and that `grafana.url` is reachable from the control host. Inter-service query URL is `http://loki:3100` (container name), not the public host.
