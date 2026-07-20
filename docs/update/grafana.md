# Role: grafana

## Purpose

Deploys Grafana OSS as a Docker container on the monitor host. Grafana is the dashboarding layer that visualises metrics stored in InfluxDB and Prometheus. The container runs as a specific user/group (`puid:pgid`) and stores its configuration and dashboards in `./data/grafana/`.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- `influxdb` and `prometheus` roles should have run (data sources).
- Variables: `grafana.*`, `puid`, `pgid`, `default.dns`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create data directories

```bash
mkdir -p ./data/grafana/lib
chown 1001:1002 ./data/grafana ./data/grafana/lib
chmod 0755 ./data/grafana ./data/grafana/lib
```

(Use the actual `puid` and `pgid` values: `1001` and `1002` on the monitor host.)

---

#### Step 2: Start the Grafana container

```bash
sudo docker run -d \
  --name grafana \
  --restart always \
  --network proxy \
  --user "1001:1002" \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -e GF_SERVER_ROOT_URL=https://grafana.your-domain.com \
  -v $(pwd)/data/grafana:/var/lib/grafana \
  --label traefik.enable=true \
  --label "traefik.http.routers.grafana.entrypoints=https" \
  --label "traefik.http.routers.grafana.rule=Host(\`grafana.your-domain.com\`)" \
  --label "traefik.http.routers.grafana.tls=true" \
  --label "traefik.http.services.grafana.loadbalancer.server.port=3000" \
  grafana/grafana-oss:latest
```

On first access, log in with the default credentials `admin`/`admin` and immediately change the password.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `grafana.host` | `Host(\`grafana.your-domain.com\`)` | Traefik router rule |
| `grafana.port` | `3000` | Grafana port |
| `grafana.url` | `https://grafana.your-domain.com` | Root URL (set so links in alerts work correctly) |
| `grafana.static` | `<docker-ip>` | Static IP on proxy network (not used by this role — grafana joins without static IP) |
| `puid` | `1001` | UID Grafana runs as |
| `pgid` | `1002` | GID Grafana runs as |
| `default.dns` | `<local-dns-ip>` | DNS server for the container |

---

## Provisioned Alerting

Alert rules, the Telegram contact point, and the notification policy are file-provisioned from `templates/provisioning/alerting/` (`rules.yaml.j2`, `contact-points.yaml.j2`, `policies.yaml.j2`). Thresholds and evaluation windows live in the role's `alerts` dict (see `defaults/main.yml`); the monitored host list is derived from `telegraf_buckets` / `traefik_alert_buckets`. Hosts not yet deployed stay commented out in `telegraf_buckets` — their node-gap/log-gap dead-man rules would otherwise fire forever. When a per-host rule is removed from the template, its uid must also be added to `deleteRules` at the top of `rules.yaml.j2`; file provisioning never deletes an already-provisioned rule on its own.

**Log noise (`grafana_log_filters`):** Grafana's `expr` engine logs a `warn` ("Ignoring InfluxDB data frame due to missing numeric fields") on every alert evaluation where a query returns an empty frame — e.g. a service with no 5xx or no recent requests. It's benign (the rule still evaluates its numeric frames) but very high-volume. The role sets `GF_LOG_FILTERS` from `grafana_log_filters` (default `expr:error,tsdb.loki:error`) to raise those loggers to error — `expr` kills the numeric-fields warns, `tsdb.loki` kills the per-query "Response received from loki" info lines. Genuine errors still log. Set it to `""` to restore full verbosity.

| Group | Rules | Source |
|-------|-------|--------|
| `homelab-http-uptime` | service down, slow response (warn/crit), per-host telegraf gap (`noDataState: Alerting`) | InfluxDB, `http_response` + `system` |
| `homelab-system` | CPU, memory, disk-space per host | InfluxDB, `cpu`/`mem`/`disk` |
| `homelab-proxmox` | host CPU, memory | InfluxDB `proxmox` bucket |
| `homelab-traefik` | 5xx rate, p95 latency per host | InfluxDB `traefik-*` buckets |
| `homelab-pfsense` | CPU, memory, WAN no-traffic, PF state table | InfluxDB `pfsense` bucket |
| `homelab-postgres` | metrics gap (`noDataState: Alerting`), connection count (`pg_conn_warn`), deadlock increase | InfluxDB `telegraf-postgres`, `inputs.postgresql` |
| `homelab-containers` | container persisting in `exited` (> `container_exited_min` samples/10m — ephemeral task containers stay below it), OOM-killed container | InfluxDB, `docker_container_status` across all buckets |
| `homelab-logs` | per-host log ingest gap: zero Loki lines with `node=<host>` in 15m (`noDataState: Alerting`) — catches a dead/stuck promtail | Loki datasource |

Alerts fan out to two contact points (all provisioned rules carry a `severity` label, which both routes match):

- **Telegram** (`log_notification` bot) — raw alert, immediately, repeat 4h.
- **Kestra** (webhook, `grafana_alert_webhook`) — posts the firing alert to the `grafana-alert-triage` flow on the automation host, where Claude Code produces a diagnosis that arrives in the same Telegram chat as a follow-up; repeat 24h so each firing alert is analyzed roughly once. The webhook URL embeds the flow's trigger key and must match the kestra role's `grafana_webhook_key` — treat it as a secret.

Rules with `noDataState: Alerting` are the dead-man-style checks; the rest treat missing data as OK.

---

## Verification

```bash
sudo docker ps | grep grafana
curl -sk https://grafana.your-domain.com/api/health | jq .
sudo docker logs grafana --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop grafana && sudo docker rm grafana
rm -rf ./data/grafana
```

---

## Troubleshooting

**"GF_SERVER_ROOT_URL" mismatch warning**
The URL in the config must match the URL you access Grafana through. If behind Traefik, set it to the full HTTPS URL including trailing path if any.

**Dashboards/data sources lost after container removal**
All data is persisted in `./data/grafana`. As long as that directory is intact, restarting the container restores everything.
