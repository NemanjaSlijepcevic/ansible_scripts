# Role: crowdsec

## Purpose

CrowdSec is a collaborative intrusion detection and prevention system. This role deploys the CrowdSec agent as a Docker container that ingests logs from Traefik, Authelia, and core system log files to detect attack patterns. It also deploys two bouncers:

1. **Traefik plugin bouncer** (not a container): the `crowdsec-bouncer-traefik-plugin` is declared in `traefik.yml.j2` under `experimental.plugins` and runs *inside* the Traefik process. The `crowdsec-bouncer` middleware (`crowdsec-bouncer.yml.j2`, `crowdsecMode: stream`) is wired into every chain, pulling the full decision set (local scenario bans **plus** the ~27k community blocklist) from the local LAPI every 60s — no size cap. The `bouncer-traefik.yml` task only registers the LAPI API key and removes the legacy standalone sidecar container.
2. **Cloudflare bouncer** (`cloudflare-bouncer`, server-only — the only bouncer *container*): pushes banned IPs to a Cloudflare IP List to block at the CDN edge. Cloudflare Lists cap at ~10k items (non-Enterprise), so it's filtered to **local** decisions only (`only_include_decisions_from: ["cscli", "crowdsec"]`) — a small, high-value set. The community blocklist is deliberately **not** pushed here (it would overflow the list and rate-limit the Cloudflare API); it stays on the in-Traefik plugin. Both `crowdsec_update_frequency` and the per-account `update_frequency` are set to `60s` (not 10s) — local bans don't need faster edge-push, and 10s hammered the Cloudflare API into `10040 "you have been ratelimited"`.

**Database:** CrowdSec runs on its bundled **SQLite** (`/var/lib/crowdsec/data/crowdsec.db`), with `USE_WAL=true` so bouncers keep reading while the community blocklist is bulk-written. Note: the crowdsec image does **not** honour `DB_BACKEND`/`POSTGRES_*` env vars — switching to Postgres would require a mounted `config.yaml` with a `db_config:` block, not env.

After the containers are running, the role updates and upgrades the CrowdSec hub (detection scenarios and collections).

## Prerequisites

- `common` role must have run (Docker, `proxy` network, `./data` directory).
- `traefik` role must have run (provides `./data/traefik/logs/` for ingestion).
- `authelia` role must have run (provides `./data/authelia/logs/` for ingestion).
- Variables: `crowdsec.*`, `node.crowdsec.*`, `current_host`.

## Manual Execution Guide

### Overview

1. Create data directory.
2. Generate `acquis.yaml` (log acquisition config).
3. Start the CrowdSec container.
4. Update the hub and upgrade installed scenarios/parsers.
5. (Server only) Generate `cfg.yaml` and deploy the Cloudflare bouncer.
6. Deploy the Traefik bouncer.

---

### Step-by-Step Instructions

#### Step 1: Create data directory

```bash
mkdir -p ./data/crowdsec
chown <username>:docker ./data/crowdsec
chmod 0755 ./data/crowdsec
```

---

#### Step 2: Generate acquis.yaml

This file tells CrowdSec which log files to ingest and how to label them.

Create `./data/crowdsec/acquis.yaml`:

```yaml
filenames:
  - /var/log/traefik/*.log
labels:
  type: traefik
---
filenames:
  - /var/log/authelia/authelia.log
labels:
  type: authelia
---
filenames:
  - /var/log/auth.log
  - /var/log/syslog
  - /var/log/kern.log
  - /var/log/ufw.log
  - /var/log/mail.log
labels:
  type: syslog
```

```bash
chmod 0755 ./data/crowdsec/acquis.yaml
```

---

#### Step 3: Start the CrowdSec container

CrowdSec requires read access to the host log directories.

**Default collections** (all hosts):
- `crowdsecurity/traefik`
- `crowdsecurity/http-cve`
- `LePresidente/authelia`
- `crowdsecurity/wordpress`

```bash
# Set collections string (all hosts)
CROWDSEC_COLLECTIONS="crowdsecurity/traefik crowdsecurity/http-cve LePresidente/authelia crowdsecurity/wordpress"

# Ensure every bind-mounted log file exists BEFORE the first docker run —
# Docker creates a missing source path as a DIRECTORY (LXC guests often
# lack kern.log), which then breaks crowdsec and promtail.
sudo touch /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/ufw.log /var/log/mail.log

sudo docker run -d \
  --name crowdsec \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e GID=1000 \
  -e "COLLECTIONS=$CROWDSEC_COLLECTIONS" \
  -e USE_WAL=true \
  -v $(pwd)/data/crowdsec/acquis.yaml:/etc/crowdsec/acquis.yaml \
  -v $(pwd)/data/crowdsec/db:/var/lib/crowdsec/data/ \
  -v $(pwd)/data/crowdsec/config:/etc/crowdsec/ \
  -v $(pwd)/data/traefik/logs:/var/log/traefik/:ro \
  -v $(pwd)/data/authelia/logs:/var/log/authelia/:ro \
  -v /var/log/auth.log:/var/log/auth.log:ro \
  -v /var/log/syslog:/var/log/syslog:ro \
  -v /var/log/kern.log:/var/log/kern.log:ro \
  -v /var/log/ufw.log:/var/log/ufw.log:ro \
  -v /var/log/mail.log:/var/log/mail.log:ro \
  --label traefik.enable=true \
  --label "traefik.http.routers.crowdsec-metrics.entrypoints=https" \
  --label "traefik.http.routers.crowdsec-metrics.rule=Host(\`node-nas-cs.your-domain.com\`)" \
  --label "traefik.http.routers.crowdsec-metrics.tls=true" \
  --label "traefik.http.routers.crowdsec-metrics.middlewares=basic-auth@file" \
  --label "traefik.http.services.crowdsec-metrics.loadbalancer.server.port=6060" \
  crowdsecurity/crowdsec:latest
```

Static IPs per host:
- NAS: `<docker-ip>` (see `host_vars/primary_nas.yml`)
- Monitor: `<docker-ip>` (see `host_vars/primary_monitor.yml`)
- Server: `<docker-ip>` (see `host_vars/primary_server.yml`)

---

#### Step 4: Update and upgrade the CrowdSec hub

```bash
# Update hub index
sudo docker exec crowdsec cscli hub update

# Upgrade all installed scenarios/parsers to latest versions
sudo docker exec crowdsec cscli hub upgrade
```

---

#### Step 5: Deploy the Traefik bouncer (all hosts)

The Traefik bouncer acts as a forward-auth middleware. Traefik forwards every request to it; the bouncer checks CrowdSec and returns 200 (allow) or 403 (block).

```bash
sudo docker run -d \
  --name bouncer-traefik \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e CROWDSEC_BOUNCER_API_KEY=<secret> \
  -e CROWDSEC_AGENT_HOST=crowdsec:8080 \
  fbonalair/traefik-crowdsec-bouncer:latest
```

Replace `CROWDSEC_BOUNCER_API_KEY` with the value from the relevant host_vars (`crowdsec.traefik.bouncer_key`).

Static IPs per host:
- NAS: (not set — NAS host_vars do not define `crowdsec.traefik.static`)
- Monitor: (check host_vars)
- Server: `<docker-ip>` (see `host_vars/primary_server.yml`)

---

#### Step 6: Deploy the Cloudflare bouncer (server host only)

First generate `./data/crowdsec/cfg.yaml` from the `cfg.yaml.j2` template. This file contains the Cloudflare API credentials. Then start the container:

```bash
sudo docker run -d \
  --name cloudflare-bouncer \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -v $(pwd)/data/crowdsec/cfg.yaml:/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml \
  crowdsecurity/cloudflare-bouncer
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `crowdsec.static` | `<docker-ip>` | Static IP for CrowdSec on the proxy network |
| `crowdsec.traefik.static` | `<docker-ip>` | Static IP for the Traefik bouncer |
| `crowdsec.traefik.bouncer_key` | `<secret>` | API key for the Traefik bouncer |
| `crowdsec.cloudflare.static` | `<docker-ip>` | Static IP for the Cloudflare bouncer |
| `crowdsec.cloudflare.access_key` | `<secret>` | Cloudflare API key for the bouncer |
| `crowdsec.cloudflare.bouncer_key` | `<secret>` | CrowdSec API key for the Cloudflare bouncer |
| `node.crowdsec.host` | `Host(\`node-nas-cs.your-domain.com\`)` | Traefik router rule for the metrics endpoint |
| `node.crowdsec.port` | `6060` | CrowdSec metrics port |
| `current_host` | `server`/`nas`/`monitor` | Controls which collections and bouncers are deployed |

### Templates & Configuration Files

| File | Destination | Purpose |
|------|------------|---------|
| `acquis.yaml.j2` | `./data/crowdsec/acquis.yaml` | Log file acquisition configuration |
| `cfg.yaml.j2` | `./data/crowdsec/cfg.yaml` | Cloudflare bouncer configuration (server only) |

---

## Handlers & Service Management

This role has no handlers.

To restart CrowdSec:

```bash
sudo docker restart crowdsec
```

To check CrowdSec metrics:

```bash
sudo docker exec crowdsec cscli metrics
```

---

## Verification

```bash
# Container running
sudo docker ps | grep -E 'crowdsec|bouncer'

# CrowdSec hub status
sudo docker exec crowdsec cscli hub list

# Active collections
sudo docker exec crowdsec cscli collections list

# Active decisions (currently banned IPs)
sudo docker exec crowdsec cscli decisions list

# Metrics endpoint
curl -sk https://node-nas-cs.your-domain.com/metrics | head -10
```

---

## Rollback / Uninstall

```bash
sudo docker stop crowdsec bouncer-traefik cloudflare-bouncer
sudo docker rm crowdsec bouncer-traefik cloudflare-bouncer
rm -rf ./data/crowdsec
```

---

## Troubleshooting

**CrowdSec not detecting attacks**
Check `acquis.yaml` paths match actual log file locations. Verify logs exist: `ls -la /var/log/traefik/`. Check CrowdSec logs: `sudo docker logs crowdsec --tail 50`.

**Bouncer key authentication fails**
The bouncer API key must be registered with the CrowdSec agent. If starting fresh, generate a key: `sudo docker exec crowdsec cscli bouncers add <name>` and update the bouncer's `CROWDSEC_BOUNCER_API_KEY` environment variable.

**False positives blocking legitimate traffic**
Add IPs to the whitelist: `sudo docker exec crowdsec cscli decisions delete --ip <ip>`. For permanent whitelisting, add to the CrowdSec whitelist config inside `./data/crowdsec/config/`.

**Hub update fails**
Check internet connectivity from the container: `sudo docker exec crowdsec wget -qO- https://hub.crowdsec.net`. If behind a proxy, configure Docker proxy settings.
