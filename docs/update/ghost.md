# Role: ghost

## Purpose

Deploys one or more Ghost blogging sites as Docker containers. The role iterates over the `ghost_sites` list and creates one container per site. Each Ghost site connects to a corresponding MySQL database container (deployed by the `sql` role) and uses Gmail SMTP for email sending. All sites run on the `proxy` network with static IPs and are routed by Traefik.

## Prerequisites

- `common`, `traefik`, `sql` roles must have run (Ghost requires MySQL).
- Variables: `ghost_sites` list (per host_vars).

## Manual Execution Guide

### Step-by-Step Instructions

The role loops over `ghost_sites`. For each site, it starts a Ghost container. Below is the configuration for the `skup-ghost` site as an example:

#### Step 1: Start a Ghost container

```bash
sudo docker run -d \
  --name skup-ghost \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --link skup-ghost-db:db \
  -e TZ=Europe/Belgrade \
  -e database__client=mysql \
  -e database__connection__host=db \
  -e database__connection__user=<db_user> \
  -e database__connection__password=<db_password> \
  -e database__connection__database=ghost \
  -e mail__transport=SMTP \
  -e mail__from=<mail_user> \
  -e mail__options__service=Gmail \
  -e mail__options__host=smtp.gmail.com \
  -e mail__options__port=465 \
  -e mail__options__auth__user=<mail_user> \
  -e mail__options__auth__pass=<mail_password> \
  -e url=https://your-domain.com \
  -v skup-ghost:/var/lib/ghost/content \
  --label traefik.enable=true \
  --label "traefik.http.routers.skup-ghost.entrypoints=https" \
  --label "traefik.http.routers.skup-ghost.rule=(Host(\`your-domain.com\`) || Host(\`www.your-domain.com\`))" \
  --label "traefik.http.routers.skup-ghost.tls=true" \
  --label "traefik.http.services.skup-ghost.loadbalancer.server.port=2368" \
  ghost:alpine
```

Repeat for `kgb-ghost` with the corresponding site-specific values.

---

## Configuration Reference

### Variables (`ghost_sites` list from `host_vars/primary_server.yml`)

Each entry in `ghost_sites` has:

| Field | Example | Description |
|-------|---------|-------------|
| `container_name` | `skup-ghost` | Docker container name |
| `db_user` | `<db-username>` | MySQL database user |
| `db_pass` | `<secret>` | MySQL database password |
| `db_name` | `ghost` | MySQL database name |
| `mail_user` | `user@example.com` | SMTP sender address |
| `mail_pass` | `<secret>` | SMTP app password |
| `url` | `https://your-domain.com` | Ghost public URL |
| `host` | `(Host(\`your-domain.com\`) || ...)` | Traefik router rule |
| `volume_name` | `skup-ghost` | Named Docker volume for content |
| `static` | `<docker-ip>` | Static IP on proxy network |

**Sites deployed**: see `host_vars/primary_server.yml` for the `ghost_sites` list.

---

## Verification

```bash
sudo docker ps | grep ghost
curl -sk https://your-domain.com/ghost/api/v3/site/ | jq .site.url
```

---

## Rollback / Uninstall

```bash
sudo docker stop skup-ghost kgb-ghost
sudo docker rm skup-ghost kgb-ghost
# Named volumes are preserved unless explicitly removed:
sudo docker volume rm skup-ghost kgb-ghost
```
