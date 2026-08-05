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
sudo mkdir -p ./data/openbao/config ./data/openbao/data ./data/openbao/audit
sudo chown -R <uid>:<gid> ./data/openbao
sudo chmod 0750 ./data/openbao ./data/openbao/config ./data/openbao/data ./data/openbao/audit
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

audit "file" "file" {
  description = "Managed by Ansible (update/roles/openbao)"

  options {
    file_path = "/openbao/audit/audit.log"
  }
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
  -v ./data/openbao/audit:/openbao/audit \
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

Then log in:

```bash
export BAO_ADDR=http://127.0.0.1:8200
docker exec -it openbao bao login <root-token>
```

---

## Operational setup

> **Automated**: `update/openbao_setup.yml` does everything in this section — unseal, KV v2, policies, auth methods, admin account, AppRole, backup token — prompting for the root token and unseal shares so they never touch the inventory or the host. See [openbao_setup.md](openbao_setup.md). The steps below are the manual equivalent, kept for debugging and for understanding what that playbook does.
>
> ```bash
> ansible-playbook update/openbao_setup.yml --vault-password-file pass.file
> ansible-playbook update/openbao_setup.yml --vault-password-file pass.file --tags unseal   # after a reboot
> ```

Ansible deploys the container and declares the audit device; everything *else* inside OpenBao is API state that needs a privileged token. Do this once, in this order, after the first unseal.

**Authenticating**: the container runs as a non-root uid with `HOME=/`, so `bao login` cannot persist a token (`Error storing token: open /.vault-token.tmp: permission denied`) and the next `docker exec` gets `403 permission denied`. Pass the token through the environment instead of argv, so it never reaches `ps` or shell history:

```bash
read -rs BAO_TOKEN        # paste the token, Enter — not echoed, not in history
export BAO_TOKEN
docker exec -e BAO_TOKEN openbao bao token lookup     # policies ["root"]
# ... run the commands below ...
unset BAO_TOKEN
```

Every `docker exec … bao` command in this section needs that `-e BAO_TOKEN`.

### 1. Audit device — Ansible-managed, nothing to do by hand

The audit device is **not** enabled with `bao audit enable`. OpenBao ≥ 2.5 rejects that with `400 … cannot enable audit device via API; use declarative, config-based audit device management instead` — a file device can write to any path and a socket device to any socket, so it is treated as operator territory, not token territory.

The role therefore declares it in `config.hcl`:

```hcl
audit "file" "file" {
  description = "Managed by Ansible (update/roles/openbao)"

  options {
    file_path = "/openbao/audit/audit.log"
  }
}
```

Controlled by `openbao_audit_enabled` / `openbao_audit_device_path` / `openbao_audit_file_path`. The role also creates and mounts `./data/openbao/audit` and installs `/etc/logrotate.d/openbao` (copytruncate, `openbao_audit_log_max_size`, `openbao_audit_log_rotate_count`). Declarative devices are (re)applied on restart and on SIGHUP.

```bash
docker exec -e BAO_TOKEN openbao bao audit list -detailed   # file/ present
ls -l ./data/openbao/audit/                                 # audit.log growing
```

> If **every** enabled audit device fails to write, OpenBao stops answering requests — designed behaviour, not a bug. Keep the audit device on its own directory and let logrotate cap it; never point it at the Raft data dir.

### 2. KV v2 engine

```bash
docker exec -e BAO_TOKEN openbao bao secrets enable -path=kv -version=2 kv
```

Path layout: `kv/homelab/<host>/<service>`, one key per field.

```bash
docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/<host>/<service> user=<username> password=<secret>
docker exec -e BAO_TOKEN openbao bao kv get -field=password kv/homelab/<host>/<service>
```

### 3. Policies

```hcl
# admin.hcl — human administrators
path "kv/*"    { capabilities = ["create","read","update","delete","list"] }
path "sys/*"   { capabilities = ["create","read","update","delete","list","sudo"] }
path "auth/*"  { capabilities = ["create","read","update","delete","list","sudo"] }

# ansible-read.hcl — the deploy control node (read-only)
path "kv/data/homelab/*"     { capabilities = ["read"] }
path "kv/metadata/homelab/*" { capabilities = ["read","list"] }

# backup.hcl — update/backup.yml, nothing else
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
```

```bash
docker exec -i -e BAO_TOKEN openbao bao policy write admin - < admin.hcl
docker exec -i -e BAO_TOKEN openbao bao policy write ansible-read - < ansible-read.hcl
docker exec -i -e BAO_TOKEN openbao bao policy write backup - < backup.hcl
```

### 4. Human auth (userpass), then stop using root

```bash
docker exec -e BAO_TOKEN openbao bao auth enable userpass
docker exec -e BAO_TOKEN openbao bao write auth/userpass/users/<username> password=<secret> policies=admin
# log in as that user in the UI, confirm it works, then:
docker exec -e BAO_TOKEN openbao bao token revoke -self          # revokes the root token
```

A revoked root token is recoverable — `bao operator generate-root` with a quorum of unseal shares. The shares stay offline; that is the break-glass path.

### 5. Ansible auth (AppRole)

```bash
docker exec -e BAO_TOKEN openbao bao auth enable approle
docker exec -e BAO_TOKEN openbao bao write auth/approle/role/ansible \
    token_policies=ansible-read token_ttl=20m token_max_ttl=1h secret_id_ttl=0
docker exec -e BAO_TOKEN openbao bao read -field=role_id  auth/approle/role/ansible/role-id
docker exec -e BAO_TOKEN openbao bao write -f -field=secret_id auth/approle/role/ansible/secret-id
```

Store the two values on the control node in `.secrets/bao_role_id` and `.secrets/bao_secret_id` (`.secrets/` is gitignored). Then a playbook reads a secret at runtime instead of carrying it in `host_vars`:

```yaml
- name: Read a secret from OpenBao
  ansible.builtin.set_fact:
    some_password: "{{ lookup('community.hashi_vault.vault_kv2_get',
                       'homelab/<host>/<service>',
                       url='https://openbao.your-domain.com',
                       auth_method='approle',
                       role_id=lookup('file', '.secrets/bao_role_id'),
                       secret_id=lookup('file', '.secrets/bao_secret_id')).secret.password }}"
  no_log: true
```

Requires `community.hashi_vault` (in `requirements.yml`) and `hvac` importable by Ansible's own interpreter: `pipx inject ansible hvac` (or `pip install hvac` if Ansible is not pipx-installed — a pipx venv is isolated from user site-packages).

> Migrate one secret at a time and keep the vaulted value until the lookup is proven. OpenBao is sealed after every reboot — a deploy of an unrelated host must never depend on it being unsealed.

### 6. Backup credentials

`update/backup.yml` uses the **`backup` AppRole**, not a stored token. `openbao_setup` creates it and writes `.secrets/backup_role_id` / `.secrets/backup_secret_id`; the `db_backup` role exchanges them for a short-lived token at the start of every run.

An earlier design used a periodic token pasted into `host_vars` as `openbao.backup_token`. That is gone: a long-lived credential in the inventory had to be renewed inside each 768h window or backups silently began failing with 403, and the inventory is mirrored into KV, so the token ended up inside the store it was meant to back up. If you still have one, revoke it:

```bash
docker exec -e BAO_TOKEN openbao bao token revoke <old-token>
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
| `openbao_audit_log_max_size` | `50M` | Rotate the audit log at this size |
| `openbao_audit_log_rotate_count` | `7` | Rotated audit logs kept |
| `openbao_verify_expect_unsealed` | `true` | `--tags verify` fails on a sealed node; set `false` to allow sealed |
| `openbao_verify_expect_audit_device` | `true` | `--tags verify` fails when no audit log is being written |
| `ip.traefik` | `172.20.0.x` | Traefik IP — trusted `X-Forwarded-For` source |
| `ip.openbao` | `172.20.0.x` | OpenBao container IP (used for `cluster_addr`) |

### Volumes

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `./data/openbao/config` | `/openbao/config` (ro) | Rendered `config.hcl` |
| `./data/openbao/data` | `/openbao/data` | Raft integrated storage (encrypted at rest) |
| `./data/openbao/audit` | `/openbao/audit` | File audit device target, rotated by `/etc/logrotate.d/openbao` |

---

## Backup & Restore (Raft snapshots)

Automated: `update/backup.yml` includes an OpenBao play. The `db_backup` role's `raft` source type (`update/roles/db_backup/tasks/raft.yml`) pulls a snapshot from `http://127.0.0.1:8200/v1/sys/storage/raft/snapshot` with a per-run token from the `backup` AppRole, gzips it into `./data/backups/<timestamp>/raft_openbao.snap.gz`, checksums it and ships it to the NAS like every other dump (3 days local, 90 on the NAS).

```bash
ansible-playbook update/backup.yml --vault-password-file pass.file --limit primary_openbao
```

A **sealed node cannot be snapshotted** — the play reports it and then fails the assert, because a sealed node has had no usable backup since its last reboot. Unseal, re-run.

By hand:

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
# Read-only role checks: container running, initialized, unsealed, audit log
# growing, health endpoint answering through Traefik.
ansible-playbook update/openbao.yml --vault-password-file pass.file --tags verify
```

`verify.yml` is tagged `never` as well as `verify`, so it stays off the deploy path — a fresh node is legitimately uninitialized and a rebooted one is legitimately sealed, and neither should fail a deploy.

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

**Every request returns 500 / "no audit devices could be reached"** — the audit device cannot write (disk full, `./data/openbao/audit` not owned by `openbao_uid`, or the mount missing). Fix the directory and, if the log was rotated out from under the device, reload it: `docker kill -s HUP openbao`.

**Backup play fails with 403 on `sys/storage/raft/snapshot`** — the `backup` AppRole lost its policy or its SecretID was revoked. Re-run `openbao_setup.yml`.
