# Prometheus

## What this is

Prometheus is the metrics store for the whole homelab, and it runs as a single container on the
monitoring machine. It does two jobs that most Prometheus deployments keep separate:

- **Receiver.** Every machine in the fleet runs a metrics agent that remote-writes to it over HTTPS.
  That is the majority of what ends up in this database — host metrics, per-container metrics, HTTP
  uptime checks, and a handful of per-service scrapes, all pushed in from the outside.
- **Scraper.** Two devices in this network cannot push at all — the Proxmox hypervisor and the
  pfSense firewall neither run nor can run an agent — so for those two, Prometheus reaches out itself
  on a timer: to a small bridging exporter for Proxmox, and directly to the firewall's own metrics
  endpoint for pfSense.

Everything Grafana shows — every dashboard panel, every alert rule threshold — is a PromQL query
against this one database. If this container is down, dashboards go blank and every alert rule based
on it flips into an evaluation error, which is treated as its own kind of alarm.

It is reachable two ways:

- `http://prometheus:9090` from other containers on the same machine — how Grafana queries it, and
  how the exporters below are scraped.
- `https://prometheus.your-domain.com` through the reverse proxy — how every other machine's agent
  pushes to it, and how a human browses its own built-in query UI.

The public route is deliberately **not** behind single sign-on. A remote-write push has no browser
session to present, and Prometheus's HTTP API has no login concept of its own to redirect to even if
it did — so the route sits on the middleware chain that still runs the intrusion-detection bouncer,
rate limiting and the IP allow-list, just not the forced sign-in step. It is not an open door; it is
one specific door left unlocked for machines instead of people.

Data lives entirely on local disk under `./data/prometheus/data` — there is no remote storage, no
clustering, and no replication. Losing that directory loses the metric history; nothing else in the
stack keeps a second copy of it.

---

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

All paths in this guide are relative to `<deploy-dir>`.

### The shared `proxy` bridge network exists

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

### The reverse proxy (Traefik) is running

Every other machine's agent reaches this container only through the proxy — there is no published
port on the Prometheus container itself.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

### The service's DNS name resolves to this host

```bash
dig +short prometheus.your-domain.com
```

### Disk space for the retention window you intend to keep

Prometheus's on-disk size is roughly proportional to the number of active series times the
retention window; with a fleet this size (roughly a dozen exporters and scrape jobs across eight
machines, scraped every 15 seconds) a 90-day retention window is on the order of a few gigabytes, not
tens — but check headroom before committing to a longer window, because Prometheus does not warn you
before it fills the disk, it just fails writes.

```bash
df -h .
```

### If you will deploy the Proxmox bridge or the pfSense scrape target on day one

Those two are covered by their own guides (the Proxmox exporter is a separate container; the
pfSense target is that firewall's own node exporter, reached through its own reverse proxy). This
guide's configuration file references both regardless — an unreachable scrape target does not stop
Prometheus from starting, it just shows that one target as `down` until the target exists.

---

## Setup

### Overview

1. Create the data directory.
2. Write the Prometheus configuration file.
3. Start the container.
4. Wait for readiness.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

sudo mkdir -p ./data/prometheus ./data/prometheus/data
sudo chown -R 65534:65534 ./data/prometheus
sudo chmod -R 0755 ./data/prometheus
```

**Explanation**: `65534` is the numeric uid/gid of `nobody` — the account the official Prometheus
image runs as by default, unprivileged and with no matching entry needed on the host. As with every
other service in this stack that runs as a fixed non-root uid, the bind-mounted directory has to be
owned by that number before the container starts, or the process cannot create its own write-ahead
log and exits immediately.

---

#### Step 2: Write the configuration file

```bash
sudo tee ./data/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
        labels:
          host: monitor

  # Proxmox VE via prometheus-pve-exporter (multi-target pattern: the exporter
  # is asked to poll ?target=<pve_api_host>, but the series carry the PVE host
  # as their instance).
  - job_name: pve
    metrics_path: /pve
    params:
      module: [default]
      cluster: ['1']
      node: ['1']
    static_configs:
      - targets: ["<pve-api-host>"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: pve-exporter:9221

  # pfSense node_exporter (FreeBSD). Reached through pfSense's own HAProxy on
  # :443, so the target is a bare hostname. No tls_config here: the cert is
  # verified, which is why the target stays on a name the apex wildcard covers.
  - job_name: pfsense
    scheme: https
    static_configs:
      - targets: ["<pfsense-hostname>"]
        labels:
          host: pfsense
EOF

sudo chown 65534:65534 ./data/prometheus/prometheus.yml
sudo chmod 0644 ./data/prometheus/prometheus.yml
```

**Explanation**: `scrape_interval` and `evaluation_interval` at 30 seconds set the default for
everything in this file, but they do not govern what every machine's agent pushes — a remote-write
push carries whatever interval the pushing agent scraped at (15 seconds, in this stack), and
Prometheus stores samples at whatever cadence it receives them on the receiver path. The 30-second
default here only applies to the two jobs Prometheus itself scrapes, below.

The `prometheus` job scrapes the container's own `/metrics` on `localhost:9090` — its self-monitoring,
labelled `host: monitor` by hand because there is no agent pushing this one in from outside; it
never leaves the container.

The `pve` job is the unusual one, and the shape is the "multi-target" pattern Prometheus exporters
use when one exporter process fronts several possible targets: Prometheus is not scraping the
hypervisor directly (it cannot; the hypervisor exposes an authenticated management API, not a metrics
endpoint), so it scrapes the bridging exporter and tells it, via the `target` query parameter, which
Proxmox API host to poll on this particular request. The three relabel steps are what make that work:
the first copies the address you wrote in `static_configs` (the real Proxmox host) into
`__param_target` — that becomes the querystring value; the second copies that same value into
`instance`, so the resulting series are labelled with the Proxmox host, not the exporter's own
address; the third then overwrites `__address__` itself to point at the exporter container — without
that last step Prometheus would try to scrape the Proxmox host directly on port 9221 and get nothing.

The `pfsense` job is comparatively ordinary — a node exporter running on FreeBSD, reached over HTTPS
because pfSense's own reverse proxy terminates TLS in front of it. `scheme: https` with no
`tls_config` block means Prometheus verifies the certificate normally, which only works because the
target is written as a hostname the certificate actually covers, not a bare IP address; pointing this
job at an IP instead produces a certificate-name mismatch and every scrape fails closed.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name prometheus \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --user 65534:65534 \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/prometheus/data:/prometheus" \
  -v "$(pwd)/data/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  --health-cmd 'wget --spider -q http://localhost:9090/-/healthy' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  --label traefik.enable=true \
  --label 'traefik.http.routers.prometheus.entrypoints=https' \
  --label 'traefik.http.routers.prometheus.rule=Host(`prometheus.your-domain.com`)' \
  --label 'traefik.http.routers.prometheus.tls=true' \
  --label 'traefik.http.routers.prometheus.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.prometheus.loadbalancer.server.port=9090' \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=<retention-days>d \
  --web.enable-remote-write-receiver \
  --web.external-url=https://prometheus.your-domain.com
```

**Explanation**: `--web.enable-remote-write-receiver` is the single most important flag on this
container — without it, the HTTP API still answers queries and still serves the two scrape jobs
above, but every push from every machine's agent is rejected with `404 page not found`, silently,
because the endpoint the agents post to simply does not exist. It is off by default upstream because
a remote-write receiver with no further access control accepts metrics from anything that can reach
it; here that is acceptable because the only thing that can reach it is the intrusion-detection
bouncer-protected proxy route or another container on the same bridge network.

`--storage.tsdb.retention.time` is the only knob that bounds disk usage — Prometheus has no separate
compaction-by-size default that would otherwise cap it, so an unset or too-generous retention window
is a slow, silent path to a full disk. `--web.external-url` has to be the exact public URL for the
same reason `GF_SERVER_ROOT_URL` matters for Grafana: it is what Prometheus uses to build the links
in its own web UI (the "graph" page, alert state pages) and to construct the base path it expects
requests to arrive under when it sits behind a reverse proxy — get it wrong and internal links in the
UI point at `localhost:9090`.

`--user 65534:65534` matches the ownership set in Step 1; the router carries `chain-no-auth@file`
for the reason explained under *What this is* — this route has to accept unattended pushes.

---

#### Step 4: Wait until Prometheus is ready

```bash
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' https://prometheus.your-domain.com/-/ready)
  echo "attempt $i: $code"
  [ "$code" = "200" ] && break
  sleep 5
done
```

**Explanation**: `/-/ready` only returns 200 once the write-ahead log has replayed and the TSDB head
block is open for writes; querying or pushing before that point returns a `503` with a body
explaining the database is not ready. On a fresh start with an empty data directory this is fast
(seconds); on a restart with months of retained data, replaying the write-ahead log can take longer,
which is the scenario this loop is patient enough for.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data` | The unprivileged login on this machine | Before you start |
| `<docker-ip>` | Prometheus's fixed address on the `proxy` network | Any free address outside the automatic pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | The bridge network's addressing | As created | Before you start |
| `<pve-api-host>` | The Proxmox management API's address and port | As configured on the hypervisor, typically `<ip-address>:8006` | Step 2 |
| `<pfsense-hostname>` | The firewall's own hostname, matching its TLS certificate | Must be a name, not an IP — the certificate check depends on it | Step 2 |
| `<retention-days>` | How many days of metric history to keep on disk | Balance against the disk headroom check in *Before you start*; 90 is the starting point here | Step 3 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

The receiver uid/gid `65534` and the port `9090` are fixed and appear in several places each; do not
change them independently of one another.

---

## Verification

```bash
docker ps --filter 'name=^prometheus$'
docker inspect --format '{{.State.Health.Status}}' prometheus

curl -sf https://prometheus.your-domain.com/-/healthy && echo
curl -sf https://prometheus.your-domain.com/-/ready && echo

# the remote-write receiver is actually on
curl -sf https://prometheus.your-domain.com/api/v1/status/flags \
  | jq -r '.data["web.enable-remote-write-receiver"]'

# every machine's agent is present and recently scraped/pushed
curl -sf https://prometheus.your-domain.com/api/v1/query \
  --data-urlencode 'query=up' | jq -r '.data.result[] | "\(.metric.job)\t\(.metric.host // .metric.instance)\t\(.value[1])"'

# the two scraped-not-pushed targets specifically
curl -sf https://prometheus.your-domain.com/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.labels.job=="pve" or .labels.job=="pfsense") | "\(.labels.job)\t\(.health)\t\(.lastError)"'
```

Disk is filling as expected:

```bash
sudo du -sh ./data/prometheus/data
```

From Grafana, open a panel backed by Prometheus and confirm data renders for a machine you know is
up — that proves the whole path, agent to receiver to dashboard.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
cd <deploy-dir>
docker pull prom/prometheus:latest
docker stop prometheus && docker start prometheus
```

Use `docker stop` then `docker start`, not `docker restart` and not a bare recreate — the same
reasoning as every other single-file-config container in this stack: `docker restart` can race stale
graphdriver state on a `fuse-overlayfs` host and fail to pick up a replaced config file, and a sparse
recreate would drop the two bind mounts back to nothing.

**After editing `prometheus.yml`** (adding a scrape job, changing an interval), the same stop/start
applies it — there is no reload endpoint enabled on this container, since exposing one would let
anything on the network with access to that route change what Prometheus scrapes.

**Logs:**

```bash
docker logs -f prometheus
```

**Retention is the recurring chore.** Watch disk usage and adjust `--storage.tsdb.retention.time` if
the fleet grows (more machines, more exporters, or a shorter scrape interval all increase it):

```bash
sudo du -sh ./data/prometheus/data
df -h .
```

**Back up** `./data/prometheus/data` if the metric history itself matters to you beyond what
dashboards have already rendered and saved; it is otherwise treated as reconstructible from nothing —
once a gap happens, it happens.

---

## Rollback / Uninstall

```bash
docker stop prometheus && docker rm prometheus
```

The stored metrics survive, so re-running Step 3 brings everything back, including history. To
remove completely:

```bash
sudo rm -rf ./data/prometheus
docker rmi prom/prometheus:latest
```

Removing the directory deletes every metric ever collected. Take a copy first if there is any chance
you want it back:

```bash
sudo tar czf ~/prometheus-$(date +%F).tar.gz ./data/prometheus/data
```

Every machine's agent will keep trying to push after this container is gone; either stop them or
point them elsewhere, or their own logs fill with connection errors.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container exits immediately, log mentions opening the write-ahead log | `./data/prometheus/data` is not owned by `65534:65534`. Re-run the `chown` from Step 1. |
| Configuration edits are ignored after a restart | The `--config.file` flag or the bind mount for `prometheus.yml` is missing from the `docker run`. `docker inspect --format '{{.Args}}' prometheus`. |
| Every agent's push returns `404` | `--web.enable-remote-write-receiver` is missing from the command. Confirm with the flags query in *Verification*. |
| `up == 0` for one machine, everything else fine | That machine's agent is down, or cannot reach this container — check that machine's own agent guide and its network path, not this container. |
| `pve` target shows `down` with a connection-refused error | The Proxmox bridging exporter container is not running, or `<pve-api-host>` does not match what the exporter itself is configured to reach. |
| `pfsense` target shows a TLS/certificate error | The target is written as an IP address rather than a hostname the certificate covers, or the certificate has expired. |
| Disk fills up over weeks | `--storage.tsdb.retention.time` is too generous for the disk available, or the fleet grew without revisiting it. Lower the retention and restart; Prometheus reclaims space on its own compaction cycle after that, not immediately. |
| `/-/ready` stays `503` for a long time after a restart | Normal on a large data directory — the write-ahead log has to replay before writes resume. Give it longer than the loop in Step 4 and watch `docker logs prometheus` for replay progress. |
| Grafana panels are empty but `up` looks fine in Prometheus's own UI | The query's time range or label selector does not match what is actually stored — check the exact label names (`host` vs `instance`) a series carries with `/api/v1/labels` before assuming data is missing. |
| Public URL unreachable, container healthy | The reverse proxy is down, or DNS for `prometheus.your-domain.com` does not point at this machine — this container has no other way in from outside. |
