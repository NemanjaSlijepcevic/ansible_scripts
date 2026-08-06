# Seerr

## What this is

Seerr is the request front-end for the media library — the page users visit to ask for a film or a
series. It talks to Sonarr and Radarr to create the request, to Jellyfin to know what already exists,
and to the central PostgreSQL server for its own state (users, requests, issues, settings).

It runs as a single container on the NAS machine, alongside the media stack it drives. Two things
make it different from the rest of that stack:

- **It logs users in itself.** The reverse-proxy route deliberately does *not* force single sign-on;
  Seerr presents its own login page and delegates to Authelia over OpenID Connect, so a phone app or
  a shared link works without hitting a forward-auth wall.
- **It stores nothing locally except a small config file.** Everything else is in PostgreSQL, reached
  over mutual TLS with a client certificate.

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
docker compose version 2>/dev/null || true

# your account must be in the docker group, or every command below needs sudo
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent, install it from Docker's own repository (the distro package is usually
too old for the compose plugin) and enable the service:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in these guides is bind-mounted from here. Run all commands from
`<deploy-dir>` so the relative paths resolve.

### The shared `proxy` bridge network exists

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows
where to send a request.

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if it is missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

The `--ip-range` is the pool Docker hands out automatically; keep fixed container addresses
**outside** that pool so nothing is ever assigned an address you have reserved. Confirm the
addressing:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

### The reverse proxy (Traefik) is running

Traefik terminates TLS, owns ports 80 and 443, and routes to this service by the labels you put on
its container. It must be up before the service is reachable from a browser.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

`healthcheck --ping` exits 0 only when Traefik's own ping endpoint answers, which means the static
configuration parsed and the entrypoints are bound. If the container is missing or the ping fails,
nothing you publish below will be reachable.

Confirm from outside that TLS terminates and a certificate is in place:

```bash
curl -sI https://proxy.your-domain.com | head -1
```

### Authelia (single sign-on) is running

Any router that carries the `chain-auth@file` middleware is forward-authenticated by Authelia. If
Authelia is down, those routes return 500 rather than a login page.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

If the service you are installing must be reachable **without** a login prompt (a machine-to-machine
API, a webhook receiver, an app with its own login), give its router `chain-no-auth@file` instead,
and add its domain to Authelia's access-control rules with `policy: bypass`.

Seerr is exactly that third case, so its router below uses `chain-no-auth@file`. It additionally
needs an OpenID Connect client registered in Authelia — a client id, a client secret, and
`https://seerr.your-domain.com/login/oidc/callback/authelia` as an allowed redirect URI. Confirm the
issuer advertises itself before you continue:

```bash
curl -sf https://auth.your-domain.com/.well-known/openid-configuration | jq -r '.issuer, .authorization_endpoint'
```

### The service's DNS name resolves to this host

```bash
dig +short seerr.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### PostgreSQL client certificates are present

Services that store state in the central PostgreSQL server authenticate with a client certificate,
not just a password — the server requires `clientcert=verify-full`, and the certificate's Common
Name must equal the database role the service connects as.

```bash
ls -l ./data/certs/
sudo openssl x509 -in ./data/certs/seerr.crt -noout -subject -dates
```

You need three files on this host: `./data/certs/seerr.crt`, `./data/certs/seerr.key`, and
the issuing `./data/certs/ca.crt`. They are signed on the PostgreSQL host and copied here; the
service never generates its own. Without them the container starts and then fails every query with
`connection requires a valid client certificate (SQLSTATE 28000)`.

### The database and role exist on the PostgreSQL server

Run on the PostgreSQL host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep seerr
docker exec -it postgres-db psql -U postgres -c '\du' | grep seerr
```

The database and the login role must both exist and the role must own the database, otherwise the
service's first migration fails with `permission denied for schema public`.

## Setup

### Overview

1. Create the configuration directory.
2. Confirm the certificate material.
3. Start the container.
4. Wait for the API to answer.
5. Register Authelia as an OpenID Connect provider.

---

#### Step 1: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/seerr
sudo chown <username>:<pgid> ./data/seerr
sudo chmod 0755 ./data/seerr
```

**Explanation**: Seerr keeps a `settings.json` here holding the connections to Sonarr, Radarr and
Jellyfin, plus its logs. Everything user-facing — accounts, requests, issue reports — is in
PostgreSQL instead, which is why this directory is small and why losing it costs you a few minutes of
re-entering service connections rather than the request history.

---

#### Step 2: Confirm the certificate material and read it out

```bash
ls -l ./data/certs/seerr.crt ./data/certs/seerr.key ./data/certs/ca.crt
sudo openssl x509 -in ./data/certs/seerr.crt -noout -subject
```

The subject's Common Name must be exactly the database role name you will pass as the database user.

**Explanation**: Two different consumers inside the container need this material in two different
shapes. The PostgreSQL driver is a Node library that takes certificate *contents* as strings, so the
three PEM files are read on the host and handed over as environment variable values. Node's own TLS
stack, used for outbound HTTPS, takes a *path* instead, so the same directory is additionally
bind-mounted read-only. Passing only paths breaks the database connection; mounting only, without the
environment variables, breaks it in the same way with a less obvious error.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name seerr \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e LOG_LEVEL=info \
  -e API_KEY='<secret>' \
  -e DB_TYPE=postgres \
  -e DB_HOST='<ip-address>' \
  -e DB_PORT=5432 \
  -e DB_USER='seerr' \
  -e DB_PASS='<secret>' \
  -e DB_NAME=seerr \
  -e DB_LOG_QUERIES=false \
  -e DB_USE_SSL=true \
  -e DB_SSL_CA="$(sudo cat ./data/certs/ca.crt)" \
  -e DB_SSL_CERT="$(sudo cat ./data/certs/seerr.crt)" \
  -e DB_SSL_KEY="$(sudo cat ./data/certs/seerr.key)" \
  -e NODE_EXTRA_CA_CERTS=/postgres-certs/ca.crt \
  -v "$(pwd)/data/seerr:/app/config" \
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.seerr.entrypoints=https' \
  --label 'traefik.http.routers.seerr.rule=Host(`seerr.your-domain.com`)' \
  --label 'traefik.http.routers.seerr.tls=true' \
  --label 'traefik.http.routers.seerr.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.seerr.loadbalancer.server.port=5055' \
  --health-cmd 'wget -qO- http://localhost:5055/api/v1/status || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  ghcr.io/seerr-team/seerr:latest
```

**Explanation**: `API_KEY` is fixed up front rather than letting Seerr generate one on first start,
because the configuration in Step 5 is done through the API and because Sonarr and Radarr call back
into Seerr with it — a value that changes on every rebuild means re-pasting it into three places.
`DB_USE_SSL=true` together with the three PEM values is what satisfies the server's
`clientcert=verify-full` requirement; the password alone is refused. `NODE_EXTRA_CA_CERTS` adds the
same internal authority to Node's trust store so that outbound calls to other internal services over
HTTPS do not fail certificate validation.

The router carries `chain-no-auth@file`, not the authenticated chain. Forward-auth in front of Seerr
would break it in three ways at once: its own OpenID Connect redirect never completes because the
callback is intercepted, the mobile clients cannot present a session cookie, and Sonarr and Radarr
webhooks receive an HTML login page where they expect JSON. Access control is Seerr's job here, not
the proxy's — which also means the domain must be listed as a bypass rule in Authelia, or the
forward-auth layer will still try to claim it.

---

#### Step 4: Wait for the API

```bash
until curl -sf -o /dev/null https://seerr.your-domain.com/api/v1/status; do sleep 5; done
curl -s https://seerr.your-domain.com/api/v1/status | jq
```

**Explanation**: On first start Seerr runs its schema migrations against an empty database, which can
take a minute or two. The status endpoint answers only after they finish, so it is the correct signal
that the next step can talk to the API. Configuring it earlier gets a connection reset half-way
through a write.

---

#### Step 5: Register Authelia as an OpenID Connect provider

First look at what is already configured, so you extend the provider list rather than replace it:

```bash
curl -s https://seerr.your-domain.com/api/v1/settings/main \
  -H 'X-Api-Key: <secret>' | jq '.oidcLogin, [.oidcProviders[]?.slug]'
```

If no provider with the slug `authelia` is listed, add one:

```bash
curl -s -X POST https://seerr.your-domain.com/api/v1/settings/main \
  -H 'X-Api-Key: <secret>' \
  -H 'Content-Type: application/json' \
  -d '{
    "oidcLogin": true,
    "oidcProviders": [
      {
        "slug": "authelia",
        "name": "Authelia",
        "issuerUrl": "https://auth.your-domain.com",
        "clientId": "<secret>",
        "clientSecret": "<secret>",
        "scopes": "openid profile email groups",
        "newUserLogin": true
      }
    ]
  }'
```

**Explanation**: This is a POST to the settings endpoint carrying the *whole* provider list, so if
another provider already exists you must include it in the array as well — the endpoint replaces the
list, it does not append to it. That is why you read the current state first, and why the check for
an existing `authelia` slug matters: repeating this call blindly duplicates the provider and users
then see two identical login buttons. The API key travels in a header rather than in the URL so it
does not end up in the proxy's access log or in your shell history as part of a query string.

`newUserLogin: true` lets a person who authenticates successfully against Authelia get a Seerr
account created on the spot; without it every new user has to be pre-created by hand. The `groups`
scope is requested so that Authelia group membership can later drive Seerr permissions.

---

#### Step 6: Connect the media services

In the Seerr UI, **Settings → Services**, add:

| Service | Hostname | Port | SSL |
| --- | --- | --- | --- |
| Sonarr | `sonarr` | `8989` | off |
| Radarr | `radarr` | `7878` | off |

and under **Settings → Jellyfin**, the internal URL `http://jellyfin:8096`.

**Explanation**: Each of these is a container name on the shared network, not the public domain.
Going out through the public name would leave the machine, come back through the reverse proxy and —
for the services that do sit behind single sign-on — return a login page instead of the JSON Seerr
expects. Staying inside the container network also means a request survives an outage of the public
DNS or the certificate.

## Values to fill in

| Placeholder | What it is | How to choose it |
| --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` on this machine | Wherever you keep service state; every relative path in this guide is relative to it |
| `<username>` | Account that owns `./data/seerr` | The login you deploy as; must be in the `docker` group |
| `<pgid>` | Group that owns `./data/seerr` | The Docker group id on this host, from `getent group docker` |
| `<docker-ip>` | Fixed address of the container on the shared network | Any free address inside the network's subnet but **outside** its automatic pool |
| `<ip-address>` | Address of the central PostgreSQL server | The host that runs the database container; used in `DB_HOST` in Step 3 |
| `<secret>` (API key) | Seerr's own API key | 32+ random characters, e.g. `openssl rand -hex 32`; used in Steps 3 and 5 |
| `<secret>` (database password) | Password of the `seerr` database role | Set when the role was created on the PostgreSQL server; used in `DB_PASS` |
| `<secret>` (client id) | OpenID Connect client id registered in Authelia | A readable identifier such as `seerr`; used in Step 5 |
| `<secret>` (client secret) | OpenID Connect client secret | Generated when the client was registered; used in Step 5 |
| `your-domain.com` | Base domain | The domain the reverse proxy holds a certificate for |

## Verification

```bash
docker ps --filter 'name=^seerr$'
docker inspect --format '{{.State.Health.Status}}' seerr
```

The API answers and reports its version:

```bash
curl -s https://seerr.your-domain.com/api/v1/status | jq
```

The database connection actually succeeded — a failure here appears in the log, not in the status
endpoint:

```bash
docker logs seerr --tail 50 | grep -i -E 'error|ssl|database|migration'
```

The OpenID Connect provider is registered exactly once:

```bash
curl -s https://seerr.your-domain.com/api/v1/settings/main \
  -H 'X-Api-Key: <secret>' | jq '.oidcLogin, [.oidcProviders[].slug]'
```

Finally, open `https://seerr.your-domain.com` in a private browser window. You should see Seerr's own
login page with a "Sign in with Authelia" button — not an Authelia login page, which would mean the
router picked up the authenticated middleware chain by mistake.

## Updating & day-to-day

```bash
docker pull ghcr.io/seerr-team/seerr:latest
docker stop seerr && docker rm seerr
# re-run the docker run command from Step 3
```

The container is stateless apart from `./data/seerr`, so a rebuild is cheap; the request history is
in PostgreSQL and survives.

Logs, both on stdout and on disk:

```bash
docker logs seerr --tail 100 -f
ls -l ./data/seerr/logs/
```

Routine chores:

- After renewing the PostgreSQL client certificate, the container must be recreated — the PEM
  contents were read into environment variables at creation time and a restart alone re-uses the old
  ones.
- Check the certificate's expiry occasionally:
  ```bash
  sudo openssl x509 -in ./data/certs/seerr.crt -noout -enddate
  ```
- Failed requests pile up under **Requests → Filter → Failed**; they usually mean Sonarr or Radarr
  refused the request, and the reason is in that application's log rather than Seerr's.

## Rollback / Uninstall

```bash
docker stop seerr && docker rm seerr
rm -rf ./data/seerr
```

The database is not touched by that. Drop it on the PostgreSQL host only if you are sure:

```bash
docker exec -it postgres-db psql -U postgres -c 'DROP DATABASE seerr;'
docker exec -it postgres-db psql -U postgres -c 'DROP ROLE seerr;'
```

Also remove the OpenID Connect client from Authelia's configuration, and delete the client
certificate files if nothing else uses them.

## Troubleshooting

**`connection requires a valid client certificate` or `no pg_hba.conf entry`**
The certificate is missing, expired, or its Common Name does not match the database user. Check with
`openssl x509 -in ./data/certs/seerr.crt -noout -subject -dates` and compare the CN against `DB_USER`.

**`self-signed certificate in certificate chain`**
The issuing authority is not trusted. `ca.crt` must be present both as the `DB_SSL_CA` value and at
`/postgres-certs/ca.crt` inside the container for `NODE_EXTRA_CA_CERTS`. Verify the mount:
```bash
docker exec seerr ls -l /postgres-certs/
```

**`Hostname/IP does not match certificate's altnames`**
`DB_HOST` must match a Subject Alternative Name on the *server's* certificate. Use the same form
(address or name) that the server certificate was issued for.

**The login page shows no Authelia button**
`oidcLogin` is false or the provider list is empty. Re-read the settings endpoint; a POST that
omitted `oidcLogin: true` silently disables the button while keeping the provider.

**Sign-in with Authelia fails with `redirect_uri_mismatch`**
Authelia's client registration must list `https://seerr.your-domain.com/login/oidc/callback/authelia`
exactly, including the slug at the end. Changing the slug in Seerr changes the callback URL.

**Two identical Authelia buttons**
The registration call was run twice. Read the current provider list, remove the duplicate entry, and
POST the corrected list back.

**Sonarr/Radarr show as unreachable in Settings → Services**
They are addressed by container name. Confirm both are on the shared network:
```bash
docker exec seerr getent hosts sonarr radarr
```

**Everything 404s through the proxy**
The DNS name does not point here, or the domain is not exempted from forward-auth. Check
`dig +short seerr.your-domain.com` and confirm the router shows `chain-no-auth@file`:
```bash
docker inspect -f '{{index .Config.Labels "traefik.http.routers.seerr.middlewares"}}' seerr
```
