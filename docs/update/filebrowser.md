# Role: filebrowser

## Purpose

Deploys [Filebrowser](https://filebrowser.org/) as a Docker container — a web file manager for browsing the mounted storage drives. Authentication is delegated to Authelia via Traefik: Filebrowser runs in `proxy` auth mode and trusts the `Remote-User` header set by the `chain-auth@file` middleware, so users log in through Authelia SSO rather than a local Filebrowser password.

## Prerequisites

- `common`, `traefik`, and `authelia` roles must have run.
- Variables: `filebrowser.*`, `puid`, `pgid`, `filebrowser_base_volumes`, `access_drives`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directories

```bash
mkdir -p ./data/filebrowser/config
chown -R <puid>:<pgid> ./data/filebrowser
chmod 0755 ./data/filebrowser

# Any local ./data/… entry in access_drives must exist and be writable by
# <puid>:<pgid>, or filebrowser answers 403 on create/upload. (The role
# creates these automatically; external mounts are left untouched.)
mkdir -p ./data/filebrowser/drive
chown <puid>:<pgid> ./data/filebrowser/drive
```

---

#### Step 2: Create the database file

```bash
touch ./data/filebrowser/database.db
chown <puid>:<pgid> ./data/filebrowser/database.db
chmod 0640 ./data/filebrowser/database.db
```

---

#### Step 3: Start the Filebrowser container

The container's entrypoint initialises the config, sets proxy auth, seeds an admin user, then serves `/srv`. Volumes are `filebrowser_base_volumes` (config + database) plus every entry in `access_drives` (the host paths exposed for browsing).

```bash
sudo docker run -d \
  --name filebrowser \
  --restart unless-stopped \
  --network proxy \
  --user "<puid>:<pgid>" \
  -v $(pwd)/data/filebrowser/config:/config \
  -v $(pwd)/data/filebrowser/database.db:/database/filebrowser.db \
  -v /mnt/<share>:/srv/<share>:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.filebrowser.entrypoints=https' \
  --label 'traefik.http.routers.filebrowser.rule=Host(`files.your-domain.com`)' \
  --label 'traefik.http.routers.filebrowser.tls=true' \
  --label 'traefik.http.routers.filebrowser.middlewares=chain-auth@file' \
  --label 'traefik.http.services.filebrowser.loadbalancer.server.port=80' \
  --entrypoint /bin/sh \
  filebrowser/filebrowser:latest \
  -c 'filebrowser config init -d /database/filebrowser.db 2>/dev/null || true && \
      filebrowser config set -d /database/filebrowser.db --auth.method=proxy --auth.header=Remote-User --address 0.0.0.0 && \
      filebrowser users add <username> placeholder --perm.admin -d /database/filebrowser.db 2>/dev/null || true && \
      filebrowser -r /srv -d /database/filebrowser.db -p 80'
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `filebrowser.static` | `<docker-ip>` | Static IP on proxy network |
| `filebrowser.host` | `` Host(`files.your-domain.com`) `` | Traefik host rule |
| `filebrowser.port` | `80` | Internal container port |
| `filebrowser.username` | `<username>` | Seeded admin username (SSO maps real users) |
| `puid` / `pgid` | `<uid>` / `<gid>` | User/group the container runs as |
| `filebrowser_base_volumes` | see defaults | Config + database bind mounts |
| `access_drives` | see `host_vars` | Host storage paths exposed for browsing (optional — role defaults to `[]`) |

---

## Verification

```bash
sudo docker ps | grep filebrowser
sudo docker logs filebrowser --tail 20
curl -ksI https://files.your-domain.com   # should redirect through Authelia
```

---

## Rollback / Uninstall

```bash
sudo docker stop filebrowser && sudo docker rm filebrowser
rm -rf ./data/filebrowser
```

---

## Troubleshooting

**Redirected to Authelia login loop**
Confirm the `chain-auth@file` middleware is applied and that Authelia sets the `Remote-User` header. Filebrowser must be in `proxy` auth mode (`--auth.method=proxy`), otherwise it shows its own login form.

**"forbidden" browsing a drive**
The mounted host path is read-only (`:ro`) and/or not included in `access_drives`. Add the path and restart the container.

**403 Forbidden creating files or directories**
The target directory is not writable by the container user (`<puid>:<pgid>`). With `access_drives` empty this is guaranteed — the image's internal `/srv` is root-owned. Mount a host path and `chown <puid>:<pgid>` it.
