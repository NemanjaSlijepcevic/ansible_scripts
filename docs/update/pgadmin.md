# Role: pgadmin

## Purpose

Deploys [pgAdmin 4](https://www.pgadmin.org/) as a Docker container — a web UI for the central PostgreSQL server. The role pre-registers the server connection (`servers.json`), seeds credentials (`pgpass`), and templates `config_local.py` for Authelia OIDC login. The CA certificate is mounted so pgAdmin can verify the Postgres TLS connection.

## Prerequisites

- `common`, `traefik`, `authelia` roles must have run.
- The central PostgreSQL server is reachable and `./data/certs/ca.crt` exists.
- Variables: `pgadmin.*`, `postgres.*`, `authelia_links.url`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

pgAdmin runs as UID/GID `5050`.

```bash
mkdir -p ./data/pgadmin
sudo chown -R 5050:5050 ./data/pgadmin
chmod 0750 ./data/pgadmin
```

---

#### Step 2: Render the config files

Three templates are rendered into `./data/pgadmin/` (all owned `5050:5050`):

| File | Source template | Purpose |
|------|-----------------|---------|
| `servers.json` | `servers.json.j2` | Pre-registered Postgres connection (host, port, SSL mode) |
| `pgpass` | `pgpass.j2` (mode `0600`) | Saved DB password for the connection |
| `config_local.py` | `config_local.py.j2` | Authelia OAuth2 endpoints (`OAUTH2_*` from `authelia_links.url`) |

---

#### Step 3: Start the pgAdmin container

```bash
sudo docker run -d \
  --name pgadmin \
  --restart unless-stopped \
  --network proxy \
  -e PGADMIN_DEFAULT_EMAIL='<admin-email>' \
  -e PGADMIN_DEFAULT_PASSWORD='<secret>' \
  -e PGADMIN_CONFIG_SERVER_MODE=True \
  -e PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION=True \
  -e PGADMIN_SERVER_JSON_FILE=/var/lib/pgadmin/servers.json \
  -e PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False \
  -v $(pwd)/data/pgadmin:/var/lib/pgadmin \
  -v $(pwd)/data/pgadmin/pgpass:/pgpass:ro \
  -v $(pwd)/data/pgadmin/config_local.py:/pgadmin4/config_local.py:ro \
  -v $(pwd)/data/certs/ca.crt:/postgres-certs/ca.crt:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.pgadmin.entrypoints=https' \
  --label 'traefik.http.routers.pgadmin.rule=Host(`pgadmin.your-domain.com`)' \
  --label 'traefik.http.routers.pgadmin.tls=true' \
  --label 'traefik.http.routers.pgadmin.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.pgadmin.loadbalancer.server.port=80' \
  dpage/pgadmin4:latest
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `pgadmin.static` | `<docker-ip>` | Static IP on proxy network |
| `pgadmin.host` | `` Host(`pgadmin.your-domain.com`) `` | Traefik host rule |
| `pgadmin.email` / `pgadmin.password` | `<admin-email>` / `<secret>` | Default login |
| `pgadmin.port` | `80` | Internal container port |
| `postgres.ip` / `postgres.port` | `<postgres-host>` / `5432` | Pre-registered server connection |
| `postgres.adm_user` / `postgres.adm_pass` | `<db-user>` / `<secret>` | Saved connection credentials |
| `authelia_links.url` | `https://auth.your-domain.com` | OAuth2 endpoints for SSO login |

---

## Verification

```bash
sudo docker ps | grep pgadmin
curl -ksI https://pgadmin.your-domain.com
sudo docker logs pgadmin --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop pgadmin && sudo docker rm pgadmin
rm -rf ./data/pgadmin
```

---

## Troubleshooting

**Permission errors on start**
`./data/pgadmin` and its files must be owned by `5050:5050`; `pgpass` must be mode `0600` or pgAdmin ignores it.

**Can't connect to Postgres (SSL required)**
The connection uses TLS; the CA at `/postgres-certs/ca.crt` must match the server certificate. If the server requires client certs (`verify-full`), a UI-only tool like pgAdmin may also need the client cert/key configured in `servers.json`.
