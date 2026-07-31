# Role: openbao

## Purpose

This role deploys **OpenBao** — the open-source, community-driven fork of HashiCorp Vault — as a dedicated secrets-management server. It provides an API and web UI for storing and issuing secrets (KV, dynamic database credentials, PKI, transit encryption, etc.).

OpenBao runs on the dedicated `primary_openbao` host with the standard baseline stack in front of it (`common` → `authelia` → `traefik` → `crowdsec` → `openbao` → `alloy`). TLS is terminated at **Traefik**; OpenBao itself listens on plain HTTP on the internal `proxy` network. Because OpenBao has its own strong authentication and UI, its Traefik router uses `chain-no-auth@file` — it is **not** fronted by Authelia forward-auth (same pattern as Grafana and pgAdmin).

Storage uses the **integrated Raft** backend (`/openbao/data`), which supports consistent live backups via `bao operator raft snapshot save` and can grow to an HA cluster later.

## Prerequisites

- `common` and `traefik` roles must have run (the `proxy` network and Traefik must exist).
- The `openbao.*` and `ip.*` variable blocks must be defined in `host_vars/primary_openbao.yml`.
- The `host.openbao` key must be defined in the vaulted `group_vars/all.yml` so the inventory `ansible_host: "{{ host.openbao }}"` resolves.
- A DNS record for the OpenBao FQDN pointing at Traefik.

> **Not idempotent past deploy**: Ansible deploys and configures the container, but **initialization and unsealing are one-time manual operations** (see below). OpenBao seals itself on every restart and must be unsealed by hand (or via an external auto-unseal mechanism, not configured here).

## Manual Execution Guide

### Overview

1. Create the config + data directories.
2. Render `config.hcl` (Raft storage, plain-HTTP listener behind Traefik).
3. Start the OpenBao container.
4. **Initialize** OpenBao once, save the unseal keys + root token.
5. **Unseal** OpenBao (after every restart).

---

### Step 1: Create directories

```bash
sudo mkdir -p ./data/openbao/config ./data/openbao/data
sudo chown -R <uid>:<gid> ./data/openbao
sudo chmod 0750 ./data/openbao ./data/openbao/config ./data/openbao/data
```

Replace `<uid>:<gid>` with `openbao_uid:openbao_gid` (default `1000:1000`) — the uid the container runs as, which must own the Raft data dir.

### Step 2: Render `config.hcl`

Write `./data/openbao/config/config.hcl`:

```hcl
ui = true
disable_mlock = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "<node-id>"
}

listener "tcp" {
  address                          = "0.0.0.0:8200"
  cluster_address                  = "0.0.0.0:8201"
  tls_disable                      = "true"
  x_forwarded_for_authorized_addrs = "<traefik-docker-ip>/32"
  telemetry { unauthenticated_metrics_access = true }
}

api_addr     = "https://openbao.your-domain.com"
cluster_addr = "http://<openbao-docker-ip>:8201"

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
```

`disable_mlock = true` is the recommended setting with the Raft backend (Raft memory-maps its DB). TLS is disabled on the listener because Traefik terminates TLS; only Traefik's IP is trusted for `X-Forwarded-For`.

### Step 3: Start the container

```bash
sudo docker run -d \
  --name openbao \
  --restart unless-stopped \
  --user <uid>:<gid> \
  --network proxy --ip <openbao-docker-ip> \
  --stop-signal SIGTERM --stop-timeout 30 \
  -p 127.0.0.1:8200:8200 \
  -e BAO_ADDR=http://127.0.0.1:8200 \
  -v ./data/openbao/config:/openbao/config:ro \
  -v ./data/openbao/data:/openbao/data \
  --label traefik.enable=true \
  --label "traefik.http.routers.openbao.entrypoints=https" \
  --label "traefik.http.routers.openbao.rule=Host(\`openbao.your-domain.com\`)" \
  --label "traefik.http.routers.openbao.tls=true" \
  --label "traefik.http.routers.openbao.middlewares=chain-no-auth@file" \
  --label "traefik.http.routers.openbao.service=openbao" \
  --label "traefik.http.services.openbao.loadbalancer.server.port=8200" \
  ghcr.io/openbao/openbao:latest \
  server -config=/openbao/config/config.hcl
```

The `-p 127.0.0.1:8200:8200` bind exposes the API to the host only (for local CLI/unseal over SSH); LAN clients reach OpenBao through Traefik. Drop it to keep the API purely internal and use `docker exec` instead.

### Step 4: Initialize (once, ever)

```bash
docker exec -it openbao bao operator init -address=http://127.0.0.1:8200
```

This prints **5 unseal key shares** and an **initial root token**. Store them in a password manager immediately — they are shown once and cannot be recovered. By default any **3 of 5** shares are required to unseal.

> Losing all unseal keys makes the data permanently unrecoverable. Losing the root token is recoverable (regenerate with a quorum of unseal keys). Never commit these anywhere.

### Step 5: Unseal (after every restart)

```bash
# Repeat with 3 different unseal keys:
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200
```

Verify:

```bash
docker exec openbao bao status -address=http://127.0.0.1:8200
# Sealed  false
```

Then log in and start using it:

```bash
export BAO_ADDR=http://127.0.0.1:8200
docker exec -it openbao bao login <root-token>
docker exec -it openbao bao secrets enable -path=secret kv-v2
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `openbao.static` | `172.20.0.x` | Container static IP on the `proxy` network |
| `openbao.host` | `Host(\`openbao.your-domain.com\`)` | Traefik router rule |
| `openbao.domain` | `openbao.your-domain.com` | Bare FQDN |
| `openbao.url` | `https://openbao.your-domain.com` | External `api_addr` / UI URL |
| `openbao.port` | `8200` | API + UI listener port |
| `openbao.node_id` | `openbao-1` | Raft node id — stable, never reuse across nodes |
| `openbao_uid` / `openbao_gid` | `1000` | uid:gid the container runs as; owns the data dir |
| `openbao_image` | `ghcr.io/openbao/openbao:latest` | Container image |
| `ip.traefik` | `172.20.0.x` | Traefik IP — trusted `X-Forwarded-For` source |
| `ip.openbao` | `172.20.0.x` | OpenBao container IP (used for `cluster_addr`) |

### Volumes

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `./data/openbao/config` | `/openbao/config` (ro) | Rendered `config.hcl` |
| `./data/openbao/data` | `/openbao/data` | Raft integrated storage (encrypted at rest) |

---

## Backup & Restore (Raft snapshots)

```bash
# Snapshot (OpenBao must be unsealed and you must be authenticated):
docker exec openbao bao operator raft snapshot save /openbao/data/backup.snap
docker cp openbao:/openbao/data/backup.snap ./openbao-$(date +%F).snap

# Restore into a running, unsealed node:
docker cp ./openbao-YYYY-MM-DD.snap openbao:/tmp/restore.snap
docker exec openbao bao operator raft snapshot restore /tmp/restore.snap
```

---

## Verification

```bash
# Container running
sudo docker ps | grep openbao

# Seal status (rc 0 unsealed, rc 2 sealed, else error)
docker exec openbao bao status -address=http://127.0.0.1:8200

# UI reachable through Traefik
curl -sk https://openbao.your-domain.com/v1/sys/health

# Prometheus metrics (unauthenticated, internal)
docker exec openbao wget -qO- http://127.0.0.1:8200/v1/sys/metrics?format=prometheus | head
```

The container healthcheck reports **healthy** while unsealed *or* sealed (sealed = up but awaiting unseal); it only goes unhealthy on a real error.

Alloy on this host scrapes `http://openbao:8200/v1/sys/metrics?format=prometheus` as job `openbao` (see `update/roles/alloy/templates/config.alloy.j2`, `current_host == 'openbao'` block) and remote-writes it to Prometheus. That endpoint returns **503 while the node is sealed**, so the scrape stays down until the first unseal — liveness is tracked by the blackbox `http_check` in `alloy.http_checks`, which forces 200 on sealed/uninitialized.

---

## Rollback / Uninstall

```bash
sudo docker stop openbao
sudo docker rm openbao
sudo rm -rf ./data/openbao   # DESTROYS all secrets — snapshot first
```

Removing `./data/openbao` deletes the Raft store and every stored secret irreversibly. Take a snapshot first.

---

## Troubleshooting

**Sealed after reboot** — expected. OpenBao seals on every restart; unseal with 3 shares (Step 5). Automate only with a real auto-unseal backend (transit/KMS), never by storing keys on the host.

**`missing client token` / permission denied** — you are unauthenticated. `bao login <token>` first; the root token comes from init.

**UI redirect loop / wrong scheme** — `api_addr` must be the external `https://` URL and Traefik must forward `X-Forwarded-Proto: https`. Confirm `ip.traefik` matches Traefik's real IP so `x_forwarded_for_authorized_addrs` trusts it.

**`failed to lock memory` on start** — ensure `disable_mlock = true` is in `config.hcl` (it is, by default, for the Raft backend).

**Permission denied writing to `/openbao/data`** — the data dir must be owned by `openbao_uid:openbao_gid`; re-run `chown` (Step 1).
