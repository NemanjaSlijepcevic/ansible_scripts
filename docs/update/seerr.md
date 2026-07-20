# Role: seerr

## Purpose

Deploys Seerr (a Jellyseerr/Overseerr-compatible media request manager) as a Docker container, backed by the central PostgreSQL server over **mutual TLS**. After the container is healthy, the role configures Authelia OIDC login through the Seerr API.

> This role replaces the removed `jellyseerr`/`plex` media-request docs. Seerr connects to Postgres with client certificates (see the `postgres`/`prepare_postgres` roles), not a plaintext password only.

## Prerequisites

- `common`, `traefik`, `authelia` roles must have run.
- The central PostgreSQL server is reachable and a `seerr` database + role exist (provisioned by `prepare_postgres`).
- Client TLS material present at `./data/certs/seerr.crt`, `./data/certs/seerr.key`, `./data/certs/ca.crt`.
- Variables: `seerr.*`, `postgres.*`, `authelia.oidc.seerr.*`, `authelia_links.url`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the config directory

```bash
mkdir -p ./data/seerr
chown <username>:docker ./data/seerr
chmod 0755 ./data/seerr
```

---

#### Step 2: Confirm the Postgres client certs

The role reads these three files and injects their **contents** as env vars (`DB_SSL_CERT`/`DB_SSL_KEY`/`DB_SSL_CA`). They are also bind-mounted for `NODE_EXTRA_CA_CERTS`.

```bash
ls -l ./data/certs/seerr.crt ./data/certs/seerr.key ./data/certs/ca.crt
```

---

#### Step 3: Start the Seerr container

```bash
sudo docker run -d \
  --name seerr \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -e LOG_LEVEL=info \
  -e API_KEY='<secret>' \
  -e DB_TYPE=postgres \
  -e DB_HOST='<postgres-host>' \
  -e DB_PORT=5432 \
  -e DB_USER='<db-user>' \
  -e DB_PASS='<secret>' \
  -e DB_NAME=seerr \
  -e DB_USE_SSL=true \
  -e DB_SSL_CA="$(cat ./data/certs/ca.crt)" \
  -e DB_SSL_CERT="$(cat ./data/certs/seerr.crt)" \
  -e DB_SSL_KEY="$(cat ./data/certs/seerr.key)" \
  -e NODE_EXTRA_CA_CERTS=/postgres-certs/ca.crt \
  -v $(pwd)/data/seerr:/app/config \
  -v $(pwd)/data/certs:/postgres-certs:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.seerr.entrypoints=https' \
  --label 'traefik.http.routers.seerr.rule=Host(`seerr.your-domain.com`)' \
  --label 'traefik.http.routers.seerr.tls=true' \
  --label 'traefik.http.routers.seerr.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.seerr.loadbalancer.server.port=5055' \
  ghcr.io/seerr-team/seerr:latest
```

> Uses `chain-no-auth@file` (not `chain-auth`) because Seerr handles its own login via OIDC.

---

#### Step 4: Configure Authelia OIDC (via the API)

After `/api/v1/status` returns 200, add the Authelia OIDC provider through `POST /api/v1/settings/main` (the role only adds it if a provider with slug `authelia` is absent):

```bash
curl -s -X POST https://seerr.your-domain.com/api/v1/settings/main \
  -H 'X-Api-Key: <secret>' -H 'Content-Type: application/json' \
  -d '{"oidcLogin":true,"oidcProviders":[{"slug":"authelia","name":"Authelia",
       "issuerUrl":"https://auth.your-domain.com",
       "clientId":"<client-id>","clientSecret":"<secret>",
       "scopes":"openid profile email groups","newUserLogin":true}]}'
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `seerr.host` / `seerr.url` | `` Host(`seerr.your-domain.com`) `` / `https://seerr.your-domain.com` | Traefik routing + probe |
| `seerr.static` | `<docker-ip>` | Static IP on proxy network |
| `seerr.api_key` | `<secret>` | Seerr API key |
| `seerr.port` | `5055` | Internal container port |
| `postgres.ip` / `postgres.port` | `<postgres-host>` / `5432` | Database endpoint |
| `postgres.user` / `postgres.password` | `<db-user>` / `<secret>` | Database credentials |
| `authelia.oidc.seerr.*` | `<client-id>` / `<secret>` | OIDC client id + secret |
| `authelia_links.url` | `https://auth.your-domain.com` | Authelia issuer URL |

> Login is OIDC via Authelia only. A legacy `trusted_headers.yml` forward-auth task was removed 2026-07-19: it trusted `remote-user` headers from the whole docker subnet (any container could forge an admin session), and the settings schema it wrote no longer exists in current Seerr.

---

## Verification

```bash
sudo docker ps | grep seerr
curl -sf https://seerr.your-domain.com/api/v1/status
sudo docker logs seerr --tail 30 | grep -i -E 'error|ssl|database'
```

---

## Rollback / Uninstall

```bash
sudo docker stop seerr && sudo docker rm seerr
rm -rf ./data/seerr
```

---

## Troubleshooting

**`self-signed certificate` / TLS handshake fails to Postgres**
Seerr (Node) validates the DB chain against `NODE_EXTRA_CA_CERTS`. Ensure `ca.crt` is mounted at `/postgres-certs/ca.crt` and the server certificate's SAN matches `DB_HOST`. The client key must be readable by the container user.

**OIDC provider not added**
The API call is skipped when a provider with slug `authelia` already exists. Delete it in Settings → Users → OIDC, or re-run after removing it.
