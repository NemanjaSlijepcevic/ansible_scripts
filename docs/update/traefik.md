# Role: traefik

## Purpose

Traefik is the reverse proxy and TLS termination point for all services in this infrastructure. This role:

- Creates the required directory structure and configuration files.
- Generates the main Traefik configuration (`traefik.yml`) and four middleware rule files.
- Creates a blank `acme.json` for ACME certificate storage (with strict permissions).
- Deploys the Traefik container with Cloudflare DNS-01 challenge TLS, the Docker provider, and a file provider pointing at the `rules/` directory.
- Exposes the Traefik dashboard behind Authelia SSO.
- Sets up log rotation for Traefik access and error logs.

## Prerequisites

- The `common` role must have run (Docker running, `proxy` network exists, `./data` directory exists).
- Cloudflare API credentials must be configured (`cloudflare.account`, `cloudflare.api_token`).
- `authelia` must eventually be deployed for the `chain-auth@file` middleware to resolve (Traefik will start without it but protected routes will fail).
- Variables: `traefik_links`, `traefik.basic_auth`, `cloudflare.*`, `node.*`, `user.*`, `private_ips`.

## Manual Execution Guide

### Overview

1. Create data directories.
2. Copy/synchronise the `traefik/` role files into `./data/traefik/`.
3. Create `acme.json` if absent.
4. Generate rule files from templates.
5. Set up log rotation.
6. Start the Traefik container.
7. Install `curl` inside the running container (for health checks).

---

### Step-by-Step Instructions

#### Step 1: Create directories

```bash
mkdir -p ./data/traefik/rules
chown <username>:docker ./data/traefik ./data/traefik/rules
chmod 0755 ./data/traefik ./data/traefik/rules
```

---

#### Step 2: Create acme.json

The `acme.json` file stores ACME (Let's Encrypt) certificates. It must have permissions `0600` or Traefik will refuse to start.

```bash
if [ ! -f ./data/traefik/acme.json ]; then
  touch ./data/traefik/acme.json
  chmod 0600 ./data/traefik/acme.json
  chown <username>:docker ./data/traefik/acme.json
fi
```

**Warning**: Never copy an `acme.json` from another host — certificates are bound to the requesting account and domain. If you wipe it, Traefik will obtain fresh certificates (subject to Let's Encrypt rate limits).

---

#### Step 3: Generate traefik.yml

Create `./data/traefik/traefik.yml`:

```yaml
api:
  dashboard: true
  debug: true

certificatesResolvers:
  cloudflare:
    acme:
      email: user@example.com
      storage: acme.json
      caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: cloudflare
        propagation:
          disableChecks: true
          delayBeforeCheck: 60s
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"

entryPoints:
  http:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: https
          scheme: https
  https:
    address: ":443"
    http:
      middlewares:
        - chain-auth@file

log:
  level: "INFO"
  filePath: "/var/log/traefik/traefik.log"
accessLog:
  filePath: "/var/log/traefik/access.log"

metrics:
  prometheus:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true

ping: {}

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /rules
    watch: true

serversTransport:
  insecureSkipVerify: false
```

```bash
chmod 0755 ./data/traefik/traefik.yml
chown <username>:docker ./data/traefik/traefik.yml
```

Key points:
- All HTTP is redirected to HTTPS.
- The `chain-auth@file` middleware is applied globally to the `https` entrypoint — meaning all HTTPS routes get Authelia SSO by default unless overridden.
- The `file` provider watches `./data/traefik/rules/` for dynamic middleware and router definitions.
- Prometheus metrics are exposed on `/metrics` via the internal `prometheus@internal` service.

---

#### Step 4: Generate rule files

Four rule files go into `./data/traefik/rules/`. They are generated from templates. The key variables and rendered outputs are described below.

**`traefik.yml`** — Traefik-specific middleware (the dashboard TLS configuration is handled via container labels).

**`basic-auth.yml`** — Defines a `basic-auth@file` middleware for routes that require HTTP Basic Auth (used by metrics endpoints):

```yaml
http:
  middlewares:
    basic-auth:
      basicAuth:
        users:
          - "<username>:<bcrypt-hash>"
```

**`default-whitelist.yml`** — Defines an IP allowlist middleware (`default-whitelist@file`) that permits only private network ranges and (on the `server` host) Cloudflare's published IP ranges:

```yaml
http:
  middlewares:
    default-whitelist:
      ipAllowList:
        sourceRange:
          - <private-network-cidr>
          - <docker-subnet>
          - <docker-bridge-subnet>
          - 127.0.0.11/32
          - 127.0.0.1/32
          # (server host only — Cloudflare IP ranges added here)
```

**`docker-metrics.yml`** — Defines routing for the Docker daemon metrics endpoint:

```yaml
http:
  routers:
    docker-metrics:
      entryPoints: ["https"]
      rule: "Host(`<docker-metrics-host>.<private-subzone>.your-domain.com`)"
      tls: true
      middlewares: ["basic-auth@file"]
      service: docker-metrics
  services:
    docker-metrics:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:9323"
```

---

#### Step 5: Configure log rotation

```bash
# Traefik error log
sudo nano /etc/logrotate.d/traefik
```

```
/path/to/data/traefik/logs/traefik.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 755
    sharedscripts
    postrotate
        systemctl reload rsyslog
    endscript
}
```

```bash
# Traefik access log
sudo nano /etc/logrotate.d/traefik-access
```

```
/path/to/data/traefik/logs/access.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 644
    sharedscripts
    postrotate
        systemctl reload rsyslog
    endscript
}
```

Replace `/path/to/data` with the actual absolute path to the working directory (e.g., `/home/<username>`).

---

#### Step 6: Start the Traefik container

The following is the equivalent `docker run` command. Adjust the variable values (`CF_API_EMAIL`, `CF_DNS_API_TOKEN`, IP addresses, and domain names) from the relevant host_vars file.

```bash
sudo docker run -d \
  --name traefik \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  --network bridge \
  -p 80:80 \
  -p 443:443 \
  -e CF_API_EMAIL=user@example.com \
  -e CF_DNS_API_TOKEN=<secret> \
  -v /etc/localtime:/etc/localtime:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/data/traefik/traefik.yml:/traefik.yml:ro \
  -v $(pwd)/data/traefik/acme.json:/acme.json \
  -v $(pwd)/data/traefik/rules:/rules \
  -v $(pwd)/data/traefik/logs:/var/log/traefik \
  --add-host host.docker.internal:host-gateway \
  --label traefik.enable=true \
  --label "traefik.http.routers.traefik.entrypoints=http" \
  --label "traefik.http.routers.traefik.rule=Host(\`proxy-nas.your-domain.com\`)" \
  --label "traefik.http.middlewares.traefik-https-redirect.redirectscheme.scheme=https" \
  --label "traefik.http.routers.traefik.middlewares=traefik-https-redirect" \
  --label "traefik.http.routers.traefik-secure.entrypoints=https" \
  --label "traefik.http.routers.traefik-secure.rule=Host(\`proxy-nas.your-domain.com\`)" \
  --label "traefik.http.routers.traefik-secure.middlewares=chain-auth@file" \
  --label "traefik.http.routers.traefik-secure.service=api@internal" \
  --label "traefik.http.routers.traefik-secure.tls=true" \
  --label "traefik.http.routers.traefik-secure.tls.certresolver=cloudflare" \
  --label "traefik.http.routers.traefik-secure.tls.domains[0].main=your-domain.com" \
  --label "traefik.http.routers.traefik-secure.tls.domains[0].sans=*.your-domain.com" \
  traefik:latest
```

Static IPs per host:
- NAS: `<docker-ip>` (see `host_vars/primary_nas.yml`)
- Monitor: `<docker-ip>` (see `host_vars/primary_monitor.yml`)
- Server: `<docker-ip>` (see `host_vars/primary_server.yml`)

---

#### Step 7: Install curl inside the container

The health check uses `curl`. Traefik's official image (based on Alpine) does not include it by default:

```bash
sudo docker exec traefik sh -lc "apk add --no-cache curl"
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `traefik_links.static` | `<docker-ip>` | Static IP on the proxy network |
| `traefik_links.name.host` | `Host(\`proxy-nas.your-domain.com\`)` | Traefik dashboard router rule |
| `traefik_links.zero.main` | `your-domain.com` | Primary wildcard cert domain |
| `traefik_links.zero.sans` | `*.your-domain.com` | SAN for wildcard cert |
| `traefik_links.one.*` | (server only) | Second domain cert |
| `traefik_links.two.*` | (server only) | Third domain cert |
| `traefik.basic_auth` | `<username>:<bcrypt-hash>` | bcrypt-hashed credentials for Traefik dashboard HTTP Basic Auth |
| `cloudflare.account` | `user@example.com` | Cloudflare account email |
| `cloudflare.api_token` | `<secret>` | Cloudflare DNS API token for ACME challenge |
| `private_ips` | list | IP ranges allowed by `default-whitelist` middleware |
| `current_host` | `nas`/`server` | Controls whether extra TLS domains and Cloudflare IPs are added |

### Templates & Configuration Files

| File | Destination | Purpose |
|------|------------|---------|
| `traefik.yml.j2` | `./data/traefik/traefik.yml` | Main static Traefik configuration |
| `basic-auth.yml.j2` | `./data/traefik/rules/basic-auth.yml` | HTTP Basic Auth middleware definition |
| `default-whitelist.yml.j2` | `./data/traefik/rules/default-whitelist.yml` | IP allowlist middleware |
| `docker-metrics.yml.j2` | `./data/traefik/rules/docker-metrics.yml` | Route to Docker daemon metrics |
| `traefik.yml.j2` (rules) | `./data/traefik/rules/traefik.yml` | Traefik-specific router/service definitions |

---

## Handlers & Service Management

This role has no handlers. The container is started directly.

To restart Traefik manually:

```bash
sudo docker restart traefik
```

To reload configuration dynamically (file provider changes are picked up automatically without restart since `watch: true` is set):

```bash
# No restart needed for rule file changes — Traefik reloads them automatically
# For static config (traefik.yml) changes, restart is required:
sudo docker restart traefik
```

---

## Verification

```bash
# Container running
sudo docker ps | grep traefik

# Health check
sudo docker inspect traefik --format='{{.State.Health.Status}}'

# TLS certificate obtained
curl -vI https://proxy-nas.your-domain.com 2>&1 | grep -E 'SSL|issuer|subject'

# Traefik dashboard accessible
curl -sk --user <username>:<password> https://proxy-nas.your-domain.com/api/rawdata | jq '.routers | keys | length'

# Check logs
sudo docker logs traefik --tail 30
```

---

## Rollback / Uninstall

```bash
sudo docker stop traefik
sudo docker rm traefik
# Optionally remove data (preserves acme.json for certificate reuse)
rm -rf ./data/traefik
```

---

## Troubleshooting

**ACME rate limit hit**
Let's Encrypt allows 5 duplicate certificate requests per week. If you hit the limit, the error appears in `./data/traefik/logs/traefik.log`. Switch to the staging server temporarily by changing `caServer` to `https://acme-staging-v02.api.letsencrypt.org/directory`.

**DNS challenge fails**
Check `CF_DNS_API_TOKEN` is correct and has `Zone:DNS:Edit` permission. Check `./data/traefik/logs/traefik.log` for ACME errors.

**Dashboard returns 401**
The `chain-auth@file` middleware requires Authelia. If Authelia is not running, the middleware resolution fails. Use the `traefik-auth` HTTP Basic Auth middleware temporarily on the dashboard router.

**Containers do not appear in Traefik**
Ensure the container is on the `proxy` network and has `traefik.enable=true` label.
