# Role: immich

## Purpose

Deploys [Immich](https://immich.app/) — a self-hosted photo/video backup platform — as a **four-container stack** on its own host: PostgreSQL (with pgvector/vectorchord), Redis (Valkey), the machine-learning service, and the Immich server. After the server is healthy the role bootstraps the admin account and wires up Authelia OAuth login via the Immich admin API.

Unlike most services, Immich brings its **own** dedicated `immich-postgres` container (it needs specific pgvector extensions), rather than using the shared central PostgreSQL server.

## Prerequisites

- `common`, `traefik`, `authelia` roles must have run.
- A Proxmox bind mount for the external photo library (e.g. `mp0: /podaci/Slike,mp=/mnt/Slike`) exposing the read-only source at `/mnt/<library>`.
- Variables: `immich.*` (incl. `immich.db.*`, `immich.admin_email`, `immich.admin_password`), `authelia.oidc.immich.*`, `authelia_links.url`.

## Manual Execution Guide

### Overview

1. Create data directories.
2. Start `immich-postgres` (database).
3. Start `immich-redis` (Valkey cache).
4. Start `immich-machine-learning`.
5. Start `immich-server`.
6. Bootstrap admin + configure Authelia OAuth.

---

### Step-by-Step Instructions

#### Step 1: Create the directories

```bash
mkdir -p ./data/immich/{upload,postgres,model-cache}
chown -R <username>:docker ./data/immich
chmod 0755 ./data/immich
```

---

#### Step 2: Start the database container

```bash
sudo docker run -d \
  --name immich-postgres \
  --restart unless-stopped \
  --network proxy \
  -e POSTGRES_USER='<db-user>' \
  -e POSTGRES_PASSWORD='<secret>' \
  -e POSTGRES_DB='<db-name>' \
  -e POSTGRES_INITDB_ARGS='--data-checksums' \
  -v $(pwd)/data/immich/postgres:/var/lib/postgresql/data \
  ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0
```

---

#### Step 3: Start the Redis (Valkey) container

```bash
sudo docker run -d --name immich-redis --restart unless-stopped \
  --network proxy docker.io/valkey/valkey:8-bookworm
```

---

#### Step 4: Start the machine-learning container

```bash
sudo docker run -d --name immich-machine-learning --restart unless-stopped \
  --network proxy \
  -v $(pwd)/data/immich/model-cache:/cache \
  ghcr.io/immich-app/immich-machine-learning:release
```

---

#### Step 5: Start the Immich server

```bash
sudo docker run -d \
  --name immich-server \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -e DB_HOSTNAME=immich-postgres \
  -e DB_USERNAME='<db-user>' \
  -e DB_PASSWORD='<secret>' \
  -e DB_DATABASE_NAME='<db-name>' \
  -e REDIS_HOSTNAME=immich-redis \
  -e UPLOAD_LOCATION=/usr/src/app/upload \
  -e IMMICH_MACHINE_LEARNING_URL=http://immich-machine-learning:3003 \
  -v $(pwd)/data/immich/upload:/usr/src/app/upload \
  -v /mnt/<library>:/external:ro \
  -v /etc/localtime:/etc/localtime:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.immich.entrypoints=https' \
  --label 'traefik.http.routers.immich.rule=Host(`immich.your-domain.com`)' \
  --label 'traefik.http.routers.immich.tls=true' \
  --label 'traefik.http.routers.immich.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.immich.loadbalancer.server.port=2283' \
  ghcr.io/immich-app/immich-server:release
```

> Uses `chain-no-auth@file`: Immich handles its own auth (native + Authelia OAuth), so Traefik does not force SSO in front of it.

---

#### Step 6: Bootstrap admin + Authelia OAuth (via API)

```bash
# First-run admin sign-up (idempotent; 400 if already created)
curl -s -X POST https://immich.your-domain.com/api/auth/admin-sign-up \
  -H 'Content-Type: application/json' \
  -d '{"email":"<admin-email>","name":"Admin","password":"<secret>"}'

# Login, capture accessToken, then PUT /api/admin/system-config with oauth{...}
# enabling issuerUrl=https://auth.your-domain.com/.well-known/openid-configuration,
# clientId=<client-id>, clientSecret=<secret>, scope="openid profile email".
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `immich.host` / `immich.url` | `` Host(`immich.your-domain.com`) `` / `https://immich.your-domain.com` | Traefik routing + probe |
| `immich.port` | `2283` | Server container port |
| `immich.static` (+ `postgres`/`redis`/`ml` `.static`) | `<docker-ip>` | Static IPs for each stack container |
| `immich.db.user` / `.password` / `.name` | `<db-user>` / `<secret>` / `<db-name>` | Dedicated Immich DB |
| `immich.upload_location` | `/usr/src/app/upload` | In-container upload path |
| `immich.external_path` | `/external` | Mount point for the read-only library |
| `immich.admin_email` / `.admin_password` | `<admin-email>` / `<secret>` | First-run admin account |
| `authelia.oidc.immich.*` | `<client-id>` / `<secret>` | OAuth client id + secret |
| `authelia_links.url` | `https://auth.your-domain.com` | Authelia issuer |

---

## Verification

```bash
sudo docker ps | grep immich
curl -sf https://immich.your-domain.com/api/server/ping
sudo docker logs immich-server --tail 30 | grep -i -E 'error|listening'
```

---

## Rollback / Uninstall

```bash
for c in immich-server immich-machine-learning immich-redis immich-postgres; do
  sudo docker stop "$c" && sudo docker rm "$c"
done
# WARNING: deletes the library DB and uploads
rm -rf ./data/immich
```

---

## Troubleshooting

**Server can't reach the database**
`DB_HOSTNAME=immich-postgres` resolves via the shared `proxy` network — all four containers must be on it. Check `immich-postgres` is healthy (`pg_isready`).

**Photos from the external library missing**
The library is mounted read-only from the Proxmox bind mount at `/mnt/<library>`. Confirm the container mount `/mnt/<library>:/external:ro` and that Immich has an external library configured pointing at `/external`.
