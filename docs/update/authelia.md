# Role: authelia

## Purpose

Authelia is the Single Sign-On (SSO) and Two-Factor Authentication (2FA) portal that protects all services behind Traefik. When a user accesses a protected service, Traefik's `chain-auth@file` middleware forwards the authentication check to Authelia. Authelia handles login, TOTP setup, session management, and ban logic.

This role:
- Creates the Authelia config directory and a log directory.
- Generates the Authelia configuration file from a host-specific template.
- Generates five secret files (JWT secret, session secret, HMAC key, SMTP password, storage encryption key), each with `0600` permissions.
- Sets up log rotation for the Authelia log file.
- Deploys the Authelia container connected to the `proxy` network.

Authelia stores its data in a PostgreSQL database (see the `postgres` and `prepare_postgres` roles) and uses TLS client certificates to connect to it.

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- The `postgres` and `prepare_postgres` roles must have run and the `authelia` database must exist.
- **TLS client certificates for Authelia must be distributed to `./data/certs/authelia.crt`, `./data/certs/authelia.key`, and `./data/certs/ca.crt` *before* Authelia starts.** These are generated and pushed by the `postgres` role's `client_certs.yml` tasks, run as part of `update/postgres.yml` — Authelia is only ever a client of that distribution step, it never generates its own cert. `update/postgres.yml` must be (re-)run any time a host is added to that role's `postgres_tls_clients` / `postgres_tls_client_hosts` lists, otherwise the files are simply absent on the target host.
- Variables: `authelia.*`, `authelia_log_level`, `postgres.*`, `authelia_db.*`, `traefik_links.*`, `authelia_links.*`.

## Manual Execution Guide

### Overview

0. **Prerequisite (external to this role)**: `update/postgres.yml` distributes Authelia's Postgres client cert/key/CA to `./data/certs/` on this host. This must have run at least once before step 5 below, or the container will fail to authenticate to Postgres.
1. Create directories.
2. Generate the Authelia configuration file (host-specific), including the templated Postgres TLS block.
3. Generate secret files.
4. Set up log rotation.
5. Start the Authelia container.

---

### Step-by-Step Instructions

#### Step 1: Create directories

```bash
mkdir -p ./data/authelia/config ./data/authelia/logs
chown <username>:docker ./data/authelia ./data/authelia/config ./data/authelia/logs
chmod 0755 ./data/authelia ./data/authelia/config ./data/authelia/logs
```

---

#### Step 2: Generate the configuration file

Authelia's configuration is host-specific (NAS, server, or monitor) because different hosts expose different services. The template is `configuration-<current_host>.yml.j2`.

The configuration covers:
- Server address and logging settings
- TOTP issuer (set to the root domain, e.g., `your-domain.com`)
- User database path (`/config/users_database.yml`)
- Session settings (expiration 3600s, inactivity 300s)
- Regulation (brute-force: max 3 retries, 2-minute find window, 5-minute ban)
- PostgreSQL storage backend with mutual-TLS client authentication (see below)
- SMTP notifier (Gmail via port 465/submissions)
- Access control rules (defined in the host-specific configuration template)

The rendered file is placed at `./data/authelia/config/configuration.yml`.

**Postgres mutual TLS block.** Every `configuration-<host>.yml.j2` template ends with `{% include 'storage_tls.yml.j2' %}`. This appends:

```yaml
storage:
  postgres:
    tls:
      certificate_chain: |
        {{- fileContent "/postgres-certs/authelia.crt" | nindent 8 }}

      private_key: |
        {{- fileContent "/postgres-certs/authelia.key" | nindent 8 }}
```

The double-curly-brace expressions here are **not** Jinja2 — Jinja has already rendered the file by the time it reaches Authelia. They are Authelia's own [go-template config filter](https://www.authelia.com/configuration/methods/files/#template-filtering) syntax, evaluated by the Authelia process itself at container startup. `fileContent` reads the PEM file at the given in-container path and inlines its contents into the YAML (indented 8 spaces via `nindent 8`) so that the certificate and key end up embedded directly in Authelia's in-memory config, rather than referenced by path. This is why `X_AUTHELIA_CONFIG_FILTERS=template` (see Step 5) must be set — without it, Authelia treats these braces as literal text and the config fails to parse as a valid PEM block.

The central Postgres server's `pg_hba.conf` enforces `cert clientcert=verify-full` for LAN clients, so presenting this client certificate is not optional — a CA-only trust store (`AUTHELIA_CERTIFICATES_DIRECTORY`, see Step 5) lets Authelia verify the *server's* certificate, but Postgres also requires Authelia to prove its own identity with a client cert whose Common Name (CN) matches the `authelia` database role. That is what `certificate_chain`/`private_key` provide.

---

#### Step 3: Generate secret files

Each secret is stored as a separate file with `0600` permissions owned by root. Authelia reads these at startup via the `_FILE` environment variable convention.

| File | Variable in inventory | Purpose |
|------|----------------------|---------|
| `authelia_hmac` | `authelia.hmc_key` | HMAC key for the identity validation flow |
| `authelia_jwt_secret` | `authelia.jwt_secret` | JWT signing secret for reset-password tokens |
| `authelia_session_secret` | `authelia.session_secret` | Session cookie signing key |
| `authelia_smtp_password` | `authelia.mail.password` | Gmail app password for SMTP notifications |
| `authelia_storage_encryption_key` | `authelia.storage_encryption_key` | Encryption key for data stored in PostgreSQL |

```bash
# Example for jwt_secret — repeat for each secret file
echo -n '<value_from_inventory>' | sudo tee ./data/authelia/config/authelia_jwt_secret
sudo chmod 0600 ./data/authelia/config/authelia_jwt_secret
sudo chown root:root ./data/authelia/config/authelia_jwt_secret
```

---

#### Step 4: Configure log rotation

```bash
sudo nano /etc/logrotate.d/authelia
```

```
/path/to/data/authelia/logs/authelia.log {
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

```bash
sudo chmod 0644 /etc/logrotate.d/authelia
```

---

#### Step 5: Start the Authelia container

The container is configured entirely through environment variables. Secrets are passed via `_FILE` variables pointing to files mounted from `./data/authelia/config/`.

```bash
sudo docker run -d \
  --name authelia \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e X_AUTHELIA_CONFIG_FILTERS=template \
  -e AUTHELIA_SERVER_ADDRESS="tcp://0.0.0.0:9091/" \
  -e AUTHELIA_THEME=dark \
  -e AUTHELIA_LOG_LEVEL=info \
  -e AUTHELIA_LOG_FORMAT=json \
  -e AUTHELIA_LOG_FILE_PATH=/var/log/authelia.log \
  -e AUTHELIA_LOG_KEEP_STDOUT=true \
  -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/authelia_jwt_secret \
  -e AUTHELIA_TOTP_ISSUER=your-domain.com \
  -e AUTHELIA_TOTP_SKEW=1 \
  -e AUTHELIA_AUTHENTICATION_BACKEND_FILE_PATH=/config/users_database.yml \
  -e AUTHELIA_SESSION_NAME=authelia_session \
  -e AUTHELIA_SESSION_EXPIRATION=3600 \
  -e AUTHELIA_SESSION_INACTIVITY=300 \
  -e AUTHELIA_SESSION_SECRET_FILE=/config/authelia_session_secret \
  -e AUTHELIA_REGULATION_MAX_RETRIES=3 \
  -e AUTHELIA_REGULATION_FIND_TIME=120 \
  -e AUTHELIA_REGULATION_BAN_TIME=300 \
  -e AUTHELIA_STORAGE_POSTGRES_ADDRESS="tcp://<ip-address>:5432" \
  -e AUTHELIA_STORAGE_POSTGRES_DATABASE=authelia \
  -e AUTHELIA_STORAGE_POSTGRES_SCHEMA=public \
  -e AUTHELIA_STORAGE_POSTGRES_USERNAME=<db-username> \
  -e AUTHELIA_STORAGE_POSTGRES_PASSWORD=<secret> \
  -e AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME=<ip-address> \
  -e AUTHELIA_STORAGE_POSTGRES_TLS_SKIP_VERIFY=false \
  -e AUTHELIA_CERTIFICATES_DIRECTORY=/postgres-certs \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/authelia_storage_encryption_key \
  -e AUTHELIA_NOTIFIER_SMTP_ADDRESS="submissions://smtp.gmail.com:465" \
  -e AUTHELIA_NOTIFIER_SMTP_USERNAME=user@example.com \
  -e AUTHELIA_NOTIFIER_SMTP_SENDER=user@example.com \
  -e AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE=/config/authelia_smtp_password \
  -v $(pwd)/data/authelia/config:/config \
  -v $(pwd)/data/authelia/logs:/var/log/ \
  -v $(pwd)/data/certs:/postgres-certs:ro \
  --label traefik.enable=true \
  --label "traefik.http.routers.authelia.entrypoints=https" \
  --label "traefik.http.routers.authelia.rule=Host(\`auth-nas.your-domain.com\`)" \
  --label "traefik.http.routers.authelia.tls=true" \
  --label "traefik.http.routers.middlewares=chain-no-auth@file" \
  authelia/authelia:latest
```

The `-v $(pwd)/data/certs:/postgres-certs:ro` mount serves two distinct purposes:
- `AUTHELIA_CERTIFICATES_DIRECTORY=/postgres-certs` tells Authelia to trust `ca.crt` found in that directory when verifying the **Postgres server's** certificate (standard CA trust store — this alone does **not** supply a client certificate).
- The `storage.postgres.tls.certificate_chain` / `private_key` block rendered into `configuration.yml` (see Step 2) reads `authelia.crt` / `authelia.key` from that same mounted directory via Authelia's go-template `fileContent` filter, and is what actually presents Authelia's **client** certificate to Postgres.

Both pieces are required together: `AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME` / `_TLS_SKIP_VERIFY` and `AUTHELIA_CERTIFICATES_DIRECTORY` control server-certificate verification, while the config-file TLS block controls what Authelia presents as its own identity.

Static IPs per host:
- NAS: `<docker-ip>` (see `host_vars/primary_nas.yml`)
- Monitor: `<docker-ip>` (see `host_vars/primary_monitor.yml`)
- Server: `<docker-ip>` (see `host_vars/primary_server.yml`)

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `authelia_log_level` | `info` | Log verbosity (`trace`/`debug`/`info`/`warn`/`error`); default `info`. `debug` floods Loki with per-request authz traces — use per host only while troubleshooting. Auth-failure events are error/warn, so CrowdSec parsing is unaffected at `info` |
| `authelia_links.static` | `<docker-ip>` | Static IP on the proxy network |
| `authelia_links.host` | `Host(\`auth-nas.your-domain.com\`)` | Traefik router rule |
| `authelia_links.host_2` | (server only) | Second domain auth endpoint |
| `authelia_links.host_3` | (server only) | Third domain auth endpoint |
| `authelia.mail.user` | `user@example.com` | SMTP sender address |
| `authelia.mail.password` | `<secret>` | SMTP app password |
| `authelia.jwt_secret` | `<secret>` | JWT signing secret |
| `authelia.session_secret` | `<secret>` | Session cookie signing key |
| `authelia.hmc_key` | `<secret>` | HMAC key |
| `authelia.storage_encryption_key` | `<secret>` | Storage encryption key |
| `postgres.ip` | `<ip-address>` | PostgreSQL server IP; also used as `AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME` for server-cert verification |
| `postgres.port` | `5432` | PostgreSQL port |
| `authelia_db.user` | `<db-username>` | PostgreSQL role Authelia connects as (must match the client cert CN) |
| `authelia_db.password` | `<secret>` | PostgreSQL password |
| `traefik_links.zero.main` | `your-domain.com` | TOTP issuer name |
| `current_host` | `nas`/`server`/`monitor` | Selects host-specific configuration template |

None of the Postgres client-cert material is an Ansible variable — the cert/key/CA are files dropped into `./data/certs/` by the `postgres` role (`client_certs.yml`), then read at container-startup time by Authelia itself (via `fileContent`, not by Ansible).

### Templates & Configuration Files

| File | Destination | Purpose |
|------|------------|---------|
| `configuration-nas.yml.j2` | `./data/authelia/config/configuration.yml` | Authelia config for the NAS host |
| `configuration-server.yml.j2` | `./data/authelia/config/configuration.yml` | Authelia config for the server host |
| `storage_tls.yml.j2` | included at the end of every `configuration-<host>.yml.j2` | Renders the `storage.postgres.tls.certificate_chain`/`private_key` block. Contains Authelia go-template (`fileContent ...`) syntax that Jinja2 deliberately leaves untouched (wrapped in `{% raw %}`) so it is evaluated by Authelia at container startup, not by Ansible. |
| `authelia_hmac.j2` | `./data/authelia/config/authelia_hmac` | HMAC key secret file |
| `authelia_jwt_secret.j2` | `./data/authelia/config/authelia_jwt_secret` | JWT secret file |
| `authelia_session_secret.j2` | `./data/authelia/config/authelia_session_secret` | Session secret file |
| `authelia_smtp_password.j2` | `./data/authelia/config/authelia_smtp_password` | SMTP password file |
| `authelia_storage_encryption_key.j2` | `./data/authelia/config/authelia_storage_encryption_key` | Storage encryption key file |

---

## Handlers & Service Management

No Ansible handlers. To restart Authelia:

```bash
sudo docker restart authelia
```

---

## Verification

```bash
# Container running
sudo docker ps | grep authelia

# Health endpoint
curl -sk https://auth-nas.your-domain.com/api/state | jq .

# Logs
sudo docker logs authelia --tail 30

# Check secret files exist with correct permissions
sudo ls -la ./data/authelia/config/authelia_*
```

---

## Rollback / Uninstall

```bash
sudo docker stop authelia
sudo docker rm authelia
rm -rf ./data/authelia
```

Dropping the `authelia` PostgreSQL database also removes all user session data.

---

## Troubleshooting

**"storage encryption key is empty" error**
The `authelia_storage_encryption_key` file is empty or missing. Check `sudo cat ./data/authelia/config/authelia_storage_encryption_key`.

**PostgreSQL connection refused or certificate error**
Verify the TLS client certs exist in `./data/certs/`. Check `postgres.ip` and `postgres.port` match the actual PostgreSQL server. Check PostgreSQL logs on the postgres host.

**`connection requires a valid client certificate (SQLSTATE 28000)`**
Postgres rejected the connection because Authelia did not present a client certificate (or presented one it didn't trust). This almost always means one of:
- `./data/certs/authelia.crt` and/or `./data/certs/authelia.key` are missing or empty on this host. Check with:
  ```bash
  sudo ls -la ./data/certs/
  sudo openssl x509 -in ./data/certs/authelia.crt -noout -subject
  ```
  The `-subject` CN must match the `authelia_db.user` role Authelia is connecting as.
- `update/postgres.yml` was never run against this host, or was run *before* this host was added to that role's client-cert distribution lists — re-run it:
  ```bash
  ansible-playbook update/postgres.yml --vault-password-file pass.file
  ```
- `X_AUTHELIA_CONFIG_FILTERS=template` is missing from the container's environment, so Authelia never evaluated the `fileContent "..."` expressions in `configuration.yml` and instead sent the literal template string as the certificate. Check with:
  ```bash
  sudo docker exec authelia env | grep X_AUTHELIA_CONFIG_FILTERS
  sudo docker exec authelia cat /config/configuration.yml | grep -A2 certificate_chain
  ```
  If the output still contains `{{- fileContent ...}}` instead of a `-----BEGIN CERTIFICATE-----` block, the filter did not run — restart the container after confirming the env var is set.
- `AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME` doesn't match a Subject Alternative Name on the Postgres server certificate, causing Authelia to abort the TLS handshake before it gets far enough to send the client cert. Compare against `postgres.ip` / the server cert's SANs.

**TOTP not working**
Ensure the system clocks on the Authelia container and client device are synchronised (NTP). The `AUTHELIA_TOTP_SKEW=1` setting allows ±1 TOTP windows (90 seconds), which handles minor drift.

**Users cannot log in after migration**
If the `users_database.yml` was restored from backup, ensure it is in `/config/` inside the container. Authelia reads it at `AUTHELIA_AUTHENTICATION_BACKEND_FILE_PATH`.
