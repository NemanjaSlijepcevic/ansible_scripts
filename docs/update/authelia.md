# Authelia

## What this is

Authelia is the single sign-on and two-factor authentication portal for this stack. The reverse
proxy on each host forwards every request on a protected route to Authelia first; Authelia answers
200 with the user's identity in `Remote-*` headers, or redirects the browser to its login page. It
owns the login form, TOTP enrolment, password reset over email, session cookies, and brute-force
regulation. On hosts that run applications capable of it, Authelia is also an OpenID Connect
provider, so those applications log users in through it instead of keeping their own accounts.

An instance runs on **every** host — the NAS, the monitoring box, the database host, the automation
host, the public server. Each one protects only the services on its own machine, but they share a
cookie domain, so a login on one host is a login on all of them.

It talks to three things: the local reverse proxy (which forwards authentication requests to it over
the shared network), the central PostgreSQL server (where sessions, TOTP secrets and the identity
audit trail live, reached over mutual TLS), and an SMTP server (password resets and security
notifications). User accounts themselves live in a flat file on this host, not in the database.

There are two situations. On a **single-domain host**, Authelia serves one login domain and issues a
session cookie for one domain. On the **public-facing host**, it serves several unrelated domains,
which means one login endpoint and one cookie entry per domain — a cookie for one domain cannot
authenticate a request for another.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

**The `./data` working directory exists and you are in it**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
```

All paths below are relative to `<deploy-dir>`.

**The shared `proxy` bridge network exists**

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

**The reverse proxy is running on this host**

Authelia is only reachable through it, and the forward-auth middleware that points at Authelia is
defined there.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
ls -l ./data/traefik/rules/authelia.yml
```

**The PostgreSQL database and login role exist**

Run on the database host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep authelia
docker exec -it postgres-db psql -U postgres -c '\du' | grep authelia
```

**The PostgreSQL client certificate is present on this host**

This is the prerequisite that most often bites. The database server requires
`clientcert=verify-full`, so a password alone is refused — Authelia must present a certificate whose
Common Name equals the database role it connects as.

```bash
ls -l ./data/certs/
sudo openssl x509 -in ./data/certs/authelia.crt -noout -subject -dates
```

You need exactly three files: `./data/certs/authelia.crt`, `./data/certs/authelia.key`, and the
issuing `./data/certs/ca.crt`. They are signed on the database host and copied here; Authelia never
generates its own. The `-subject` output must show `CN = <db-username>`, matching the role in
Step 8. Without these files Authelia starts and then fails every query with
`connection requires a valid client certificate (SQLSTATE 28000)`.

**You can reach the database from this host**

```bash
nc -zv <ip-address> 5432
```

**You have SMTP credentials**

An application password for the mailbox Authelia sends from. Password reset and the "new device"
notification are unusable without it.

**DNS for the login domain resolves to this host**

```bash
dig +short auth.your-domain.com
```

## Setup

### Overview

1. Create the directory layout.
2. Generate the OpenID Connect signing key — only on hosts with applications that use it.
3. Write the user database.
4. Write `configuration.yml`.
5. Write the five secret files.
6. Set up log rotation.
7. Set up the mutual-TLS block for the database.
8. Start the container.
9. Enrol the first user's second factor.

---

#### Step 1: Create the directory layout

```bash
cd <deploy-dir>
mkdir -p ./data/authelia/logs
sudo chown -R <username>:<pgid> ./data/authelia ./data/authelia/logs
sudo chmod 0755 ./data/authelia ./data/authelia/logs

mkdir -p ./data/authelia/config
sudo chown root:root ./data/authelia/config
sudo chmod 0755 ./data/authelia/config
```

**Explanation**: The configuration directory is deliberately owned by `root`, not by the deploy
account, and everything inside it is `0600` root-owned. It holds five secrets, a password hash and a
4096-bit signing key in cleartext, and the whole point of putting them in files instead of
environment variables is that a file cannot be read out of `docker inspect` or `/proc/<pid>/environ`
by anything running as a lesser user. The log directory stays deploy-owned because the
intrusion-detection agent on this host reads it as a bind mount and needs to get at it.

---

#### Step 2: Generate the OpenID Connect signing key

Do this only if an application on this host logs users in through Authelia rather than through the
forward-auth header — a photo library, a media server, a dashboard, a request portal, a database
admin UI. Skip it entirely on hosts with no such application.

```bash
cd <deploy-dir>
if [ ! -f ./data/authelia/config/authelia_oidc_jwk ]; then
  sudo openssl genrsa -out ./data/authelia/config/authelia_oidc_jwk 4096
fi
sudo chown root:root ./data/authelia/config/authelia_oidc_jwk
sudo chmod 0600 ./data/authelia/config/authelia_oidc_jwk
sudo openssl rsa -in ./data/authelia/config/authelia_oidc_jwk -noout -check
```

**Explanation**: This is the private key Authelia signs identity tokens with; every application that
trusts Authelia validates signatures against the matching public key it fetches from Authelia's
discovery endpoint. RSA at 4096 bits because RS256 is the algorithm every client library implements
without configuration. Generate it once and never regenerate it casually — rotating the key
invalidates every outstanding token and every client's cached key set at the same instant, logging
everyone out of every connected application. The `if` guard is what makes this step safe to repeat.

---

#### Step 3: Write the user database

Accounts live in a file, not in the database. Generate the password hash first — never write a
plaintext password into this file:

```bash
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 --password '<secret>'
```

Copy the resulting `$argon2id$...` string into the file:

```bash
cd <deploy-dir>
sudo tee ./data/authelia/config/users_database.yml >/dev/null <<'EOF'
---
users:
  <admin-user>:
    disable: false
    displayname: "<display-name>"
    password: "$argon2id$v=19$m=65536,t=3,p=4$<hash>"
    email: you@your-domain.com
    groups:
      - admins
      - dev
EOF
sudo chown root:root ./data/authelia/config/users_database.yml
sudo chmod 0600 ./data/authelia/config/users_database.yml
```

**Explanation**: A file backend rather than LDAP because this is a handful of accounts and running a
directory server for them would be more moving parts than the thing it protects. Authelia watches
this file and picks up changes without a restart. The hash is argon2id, which is memory-hard — the
parameters above make a GPU-based guessing attack expensive rather than trivial, which matters
because this one hash is the root of trust for every service on the host. `groups` are what
access-control rules and the applications' role mappings key off, so a user with no groups can
authenticate but may still be denied everywhere. The file is `0600` root-owned: it is a password
database.

---

#### Step 4: Write `configuration.yml`

This file carries only what cannot be expressed as an environment variable — the access-control
rules, the session cookie domains, the OpenID Connect clients, and the database TLS material.
Everything else is passed as environment variables in Step 8.

**On a host that runs services but no OpenID Connect applications:**

```bash
cd <deploy-dir>
sudo tee ./data/authelia/config/configuration.yml >/dev/null <<'EOF'
access_control:
  default_policy: deny
  rules:
    - domain:
        - "auth.your-domain.com"
      policy: bypass

    - domain:
        - "<service>.your-domain.com"
      resources:
        - "^/ping.*"
        - "^/api/.*"
      policy: bypass

    - domain:
        - "<service>.your-domain.com"
        - "proxy.your-domain.com"
      policy: two_factor

session:
  cookies:
  - domain: "your-domain.com"
    authelia_url: "https://auth.your-domain.com"

storage:
  postgres:
    tls:
      certificate_chain: |
        {{- fileContent "/postgres-certs/authelia.crt" | nindent 8 }}

      private_key: |
        {{- fileContent "/postgres-certs/authelia.key" | nindent 8 }}
EOF
sudo chown root:root ./data/authelia/config/configuration.yml
sudo chmod 0600 ./data/authelia/config/configuration.yml
```

**On a host that also acts as an OpenID Connect provider**, insert an `identity_providers` block
between the access-control rules and the session block. Hash each client secret first — the
configuration stores the hash, not the secret:

```bash
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
```

That prints both the plaintext (which you give to the application) and the digest (which goes here).
Read the signing key you generated in Step 2 and indent it by ten spaces so it nests correctly:

```bash
sudo sed 's/^/          /' ./data/authelia/config/authelia_oidc_jwk
```

The block, with that key pasted in place of the placeholder lines:

```yaml
identity_providers:
  oidc:
    jwks:
      - key_id: main
        algorithm: RS256
        use: sig
        key: |
          -----BEGIN PRIVATE KEY-----
          <the contents of authelia_oidc_jwk, every line indented by 10 spaces>
          -----END PRIVATE KEY-----
    cors:
      endpoints:
        - token
        - introspection
    claims_policies:
      <app>:
        id_token: ['email', 'name', 'groups', 'preferred_username']
    clients:
      - client_id: "<client-id>"
        client_name: <App Name>
        client_secret: "$pbkdf2-sha512$310000$<digest>"
        public: false
        authorization_policy: two_factor
        require_pkce: true
        pkce_challenge_method: S256
        redirect_uris:
          - "https://<service>.your-domain.com/login/generic_oauth"
        scopes:
          - openid
          - profile
          - groups
          - email
        grant_types:
          - authorization_code
        response_types:
          - code
        token_endpoint_auth_method: client_secret_basic
        access_token_signed_response_alg: none
        userinfo_signed_response_alg: none
        claims_policy: <app>
```

**On the public-facing host**, the session block carries one entry per cookie domain, each pointing
at that domain's own login endpoint:

```yaml
session:
  cookies:
  - domain: "your-domain.com"
    authelia_url: "https://auth.your-domain.com"
  - domain: "your-second-domain.com"
    authelia_url: "https://auth.your-second-domain.com"
  - domain: "your-third-domain.com"
    authelia_url: "https://auth.your-third-domain.com"
```

**Explanation**: `default_policy: deny` is the spine of the whole design — a domain nobody wrote a
rule for is refused, so forgetting to configure a new service fails closed instead of publishing it.
Rules are evaluated **top to bottom, first match wins**, which is why the narrow `resources` rules
come before the broad domain rules: a media-manager's `/api/` paths are called by other services
with an API key and cannot complete an interactive login, so they are bypassed, while the same
domain's web interface below still demands two factors. The login domain itself must always be
`bypass` or the login page would require you to be logged in. `two_factor` means password **and**
TOTP, not password alone. The session cookie is issued for the parent domain, so one login covers
every subdomain on every host — which is exactly why a second, unrelated domain needs its own cookie
entry and its own login endpoint; browsers will not send a cookie across registrable domains.
Client secrets are stored as PBKDF2 digests so a readable configuration file does not hand over the
ability to impersonate an application, and `require_pkce` with S256 closes the authorization-code
interception path for clients that can support it.

---

#### Step 5: Write the five secret files

```bash
cd <deploy-dir>

# each of these should be a long random string; generate them if you do not have them
openssl rand -hex 32

for f in authelia_jwt_secret authelia_session_secret authelia_storage_encryption_key authelia_hmac; do
  printf '%s' '<secret>' | sudo tee "./data/authelia/config/$f" >/dev/null
done

printf '%s' '<secret>' | sudo tee ./data/authelia/config/authelia_smtp_password >/dev/null

sudo chown root:root ./data/authelia/config/authelia_*
sudo chmod 0600 ./data/authelia/config/authelia_*
ls -l ./data/authelia/config/
```

Use a **different** random value for each of the four, and the mailbox's application password for
the fifth.

| File | What it protects |
| --- | --- |
| `authelia_jwt_secret` | Signs the password-reset links sent by email — anyone who can forge one can reset any password |
| `authelia_session_secret` | Signs session cookies — anyone who can forge one is logged in as anybody |
| `authelia_storage_encryption_key` | Encrypts TOTP secrets and identity data at rest in the database |
| `authelia_hmac` | Signs OpenID Connect artefacts; only needed on hosts with connected applications |
| `authelia_smtp_password` | The mailbox application password |

**Explanation**: Files, not environment variables, and `printf` rather than `echo` because `echo`
appends a newline that becomes part of the secret — a trailing byte here is the difference between
sessions that validate and sessions that silently do not. Each value is separate on purpose: reusing
one string across the session signer and the storage encryption key means a single leak
simultaneously forges logins and decrypts every stored TOTP seed. Losing
`authelia_storage_encryption_key` is unrecoverable — the two-factor secrets in the database cannot
be decrypted without it, and every user must re-enrol. Back it up somewhere that is not this host.

---

#### Step 6: Set up log rotation

```bash
sudo tee /etc/logrotate.d/authelia >/dev/null <<'EOF'
<deploy-dir>/data/authelia/logs/authelia.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
sudo chown root:root /etc/logrotate.d/authelia
sudo chmod 0644 /etc/logrotate.d/authelia
sudo logrotate -d /etc/logrotate.d/authelia
```

Use the absolute path in place of `<deploy-dir>`; logrotate does not accept a relative one.

**Explanation**: `copytruncate` because Authelia holds the log file open for the container's whole
lifetime. Renaming it away would leave Authelia writing to an unlinked inode, and the
intrusion-detection agent — which reads this exact file to ban addresses that fail authentication
repeatedly — would go blind while the disk kept filling. This log is a security control, not just
diagnostics, which is why it is written to a file at all rather than only to the container's stdout.

---

#### Step 7: Set up the mutual-TLS block for the database

Nothing to write here beyond what Step 4 already contains, but confirm the pieces line up before you
start the container:

```bash
cd <deploy-dir>
sudo openssl x509 -in ./data/certs/authelia.crt -noout -subject
sudo openssl x509 -in ./data/certs/ca.crt -noout -subject -dates
sudo grep -A2 certificate_chain ./data/authelia/config/configuration.yml
```

**Explanation**: The `fileContent` expressions in the storage block are **not** placeholders for you
to substitute — they are Authelia's own configuration filter syntax, evaluated by the Authelia
process itself when it starts, and they must appear in the file literally. Each one reads a PEM file
from the mounted certificate directory and inlines its contents into the configuration, indented
eight spaces, so the certificate and key end up embedded in Authelia's in-memory configuration rather
than referenced by path. That evaluation only happens because `X_AUTHELIA_CONFIG_FILTERS=template`
is set on the container in Step 8; without that variable Authelia treats the braces as literal text
and hands the database a string that is not a certificate. Two separate mechanisms are at work and
both are required: the certificate directory environment variable makes Authelia trust the CA when
verifying the *database server's* certificate, while this block is what presents Authelia's *own*
certificate to prove who it is. The Common Name on that certificate must equal the database role, or
the server rejects it even though the CA is trusted.

---

#### Step 8: Start the container

```bash
cd <deploy-dir>
docker run -d \
  --name authelia \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=<timezone> \
  -e X_AUTHELIA_CONFIG_FILTERS=template \
  -e AUTHELIA_SERVER_ADDRESS='tcp://0.0.0.0:9091/' \
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
  -e AUTHELIA_STORAGE_POSTGRES_ADDRESS='tcp://<ip-address>:5432' \
  -e AUTHELIA_STORAGE_POSTGRES_DATABASE=authelia \
  -e AUTHELIA_STORAGE_POSTGRES_SCHEMA=public \
  -e AUTHELIA_STORAGE_POSTGRES_USERNAME=<db-username> \
  -e AUTHELIA_STORAGE_POSTGRES_PASSWORD=<secret> \
  -e AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME=<ip-address> \
  -e AUTHELIA_STORAGE_POSTGRES_TLS_SKIP_VERIFY=false \
  -e AUTHELIA_CERTIFICATES_DIRECTORY=/postgres-certs \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/authelia_storage_encryption_key \
  -e AUTHELIA_NOTIFIER_SMTP_ADDRESS='submissions://smtp.your-mail-provider.com:465' \
  -e AUTHELIA_NOTIFIER_SMTP_USERNAME=you@your-domain.com \
  -e AUTHELIA_NOTIFIER_SMTP_SENDER=you@your-domain.com \
  -e AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE=/config/authelia_smtp_password \
  -v "$(pwd)/data/authelia/config:/config" \
  -v "$(pwd)/data/authelia/logs:/var/log/" \
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
  --health-cmd 'wget --quiet --spider http://localhost:9091/api/health || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 90s \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.authelia.entrypoints=https' \
  --label 'traefik.http.routers.authelia.rule=Host(`auth.your-domain.com`)' \
  --label 'traefik.http.routers.authelia.tls=true' \
  --label 'traefik.http.routers.authelia.middlewares=chain-no-auth@file' \
  authelia/authelia:latest
```

On a host with OpenID Connect applications, add one more variable:

```bash
  -e AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE=/config/authelia_hmac \
```

On the **public-facing host**, add a router per additional login domain:

```bash
  --label 'traefik.http.routers.authelia-2.rule=Host(`auth.your-second-domain.com`)' \
  --label 'traefik.http.routers.authelia-2.tls=true' \
  --label 'traefik.http.routers.authelia-2.tls.certresolver=cloudflare' \
  --label 'traefik.http.routers.authelia-2.entryPoints=https' \
  --label 'traefik.http.routers.authelia-3.rule=Host(`auth.your-third-domain.com`)' \
  --label 'traefik.http.routers.authelia-3.tls=true' \
  --label 'traefik.http.routers.authelia-3.tls.certresolver=cloudflare' \
  --label 'traefik.http.routers.authelia-3.entryPoints=https' \
```

**Explanation**: `X_AUTHELIA_CONFIG_FILTERS=template` is the single most important variable here —
it turns on the configuration filter that loads the database client certificate and key out of the
mounted directory, and without it Authelia never becomes a database client at all. Every secret is
passed as a `_FILE` path rather than a value so nothing sensitive appears in `docker inspect`, in the
process environment, or in a shell history. Authelia's own router uses `chain-no-auth@file`: putting
the login portal behind the login portal would be a redirect loop. `AUTHELIA_TOTP_SKEW=1` accepts
codes one 30-second window either side of now, which covers ordinary clock drift on a phone without
meaningfully widening the guessing window. The regulation settings ban an account for 5 minutes
after 3 failures within 2 minutes — enough to make online guessing pointless, short enough that a
user who fat-fingers their password three times is not locked out for the evening. The session
expires after an hour and after 5 minutes of inactivity, both re-checked on every forwarded request.
The certificate directory is mounted read-only because Authelia only ever reads it, and the entire
mount is shared with the configuration filter and the CA trust store at once. The health check uses
`wget --spider` because that is what the image ships; the 90-second start period exists because
Authelia runs database schema migrations on first start and must not be declared unhealthy while it
does.

---

#### Step 9: Enrol the first user's second factor

```bash
docker logs -f authelia | grep -i -E 'listening|migrat|error'
```

Then open `https://auth.your-domain.com` in a browser, sign in with the account from Step 3, and
follow the prompt to register a one-time-password application. Confirm it landed in the database:

```bash
docker exec authelia wget -qO- http://localhost:9091/api/health
```

**Explanation**: The TOTP secret is generated by Authelia, encrypted with the storage encryption key
and written to the database — it is not in any file on this host, which is why that key is the one
piece of material you cannot lose. Until at least one user has enrolled, every rule with
`policy: two_factor` is effectively an enrolment prompt rather than a login, so do this before you
depend on any protected service.

## Access-control rules — how they are evaluated

Rules are matched **in order, first match wins**, and anything that matches nothing falls through to
`default_policy: deny`. That has three practical consequences:

- **Specific before general.** A rule that bypasses `^/api/.*` on a domain must appear above the
  rule that demands two factors on the whole domain, or it will never be reached.
- **The login domain is always `bypass`.** So are the login domains of any other zones this host
  serves.
- **Any route your proxy publishes with `chain-no-auth@file` still needs a `bypass` rule here.**
  The proxy's `https` entrypoint applies the authenticating chain by default, so a route that
  overrides it at the router but has no matching bypass rule produces inconsistent behaviour and, in
  the worst case, a redirect loop.

The three policies you will use:

| Policy | Meaning |
| --- | --- |
| `bypass` | No authentication at all. For login pages, machine-called APIs, health endpoints, webhook receivers, and applications that authenticate users themselves through OpenID Connect. |
| `one_factor` | Password only. Rarely the right answer here. |
| `two_factor` | Password and a one-time code. The default for anything a human administers. |

A `resources` list narrows a rule to specific paths on the listed domains, as regular expressions
anchored with `^`. That is how a service's web interface stays behind two factors while the API paths
its sibling services call remain reachable with an API key.

Applications that log in *through* Authelia with OpenID Connect must be listed as `bypass` at the
domain level — their login is handled at the token endpoint, and forcing forward-auth on top of it
breaks the redirect back from the provider.

## Adding a user

```bash
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 --password '<secret>'

sudo <editor> ./data/authelia/config/users_database.yml
```

Append the new block, keeping the file `0600` root-owned:

```yaml
  <username>:
    disable: false
    displayname: "<display-name>"
    password: "$argon2id$v=19$m=65536,t=3,p=4$<hash>"
    email: <username>@your-domain.com
    groups:
      - dev
```

Authelia watches the file and reloads it — no restart. To disable an account instead of deleting it,
set `disable: true`, which invalidates it immediately while keeping its audit history intact.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–8 |
| `<username>` / `<pgid>` | Owner and group of the data directory | The deploy account and the `docker` group | Step 1 |
| `<docker-ip>` | Authelia's fixed address on the shared network | Any address in the shared subnet outside the auto-allocation pool | Step 8 |
| `<timezone>` | IANA timezone name | Whatever the host uses, so log timestamps and ban windows read correctly | Step 8 |
| `<admin-user>` / `<display-name>` | The first account | Anything; it is the login name | Step 3 |
| `<secret>` (password) | The account's password | Long and unique — this one password fronts every service on the host | Step 3 |
| `<secret>` (four signing keys) | Session, JWT, storage-encryption, HMAC | Four *different* 32-byte random hex strings from `openssl rand -hex 32` | Step 5 |
| `<secret>` (SMTP) | Mailbox application password | Issued by your mail provider, not the mailbox's own password | Step 5 |
| `<ip-address>` | The PostgreSQL server's address | Also used as the TLS server name, so it must appear in that server's certificate | Step 8 |
| `<db-username>` | Database login role | Must equal the Common Name on `./data/certs/authelia.crt` | Steps 7, 8 |
| `<secret>` (database) | Database password | Still required alongside the client certificate | Step 8 |
| `your-domain.com` | Base domain | Also the one-time-password issuer name shown in users' authenticator apps | Steps 4, 8 |
| `auth.your-domain.com` | Login endpoint | Must be `bypass` in the access-control rules | Steps 4, 8 |
| `smtp.your-mail-provider.com` | Outbound mail server | Port 465 with implicit TLS, as written | Step 8 |
| `<client-id>` / `<digest>` | OpenID Connect client credentials | Generate both with the hash command in Step 4; the plaintext goes to the application, the digest here | Step 4 |

Log verbosity is `info` by default. `debug` is available while troubleshooting but emits a full
authorization trace per request, which floods the log store within hours — set it per host, never
permanently. Authentication failures are logged at warn and error, so the intrusion-detection agent's
parsing is unaffected at `info`.

## Verification

```bash
# the process is up and answering
docker inspect authelia | jq -r '.[0].State.Health.Status'
docker exec authelia wget -qO- http://localhost:9091/api/health

# through the proxy from outside
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health

# the configuration filter actually ran — this must show a PEM block, not braces
docker exec authelia cat /config/configuration.yml | grep -A3 certificate_chain
docker exec authelia env | grep X_AUTHELIA_CONFIG_FILTERS

# the database connection came up and the schema migrated
docker logs authelia 2>&1 | grep -iE 'storage|migrat' | tail -10

# secret files are present, root-owned and 0600
sudo ls -l ./data/authelia/config/

# a protected route actually redirects to the login page
curl -sI https://<service>.your-domain.com | grep -i location

# forward-auth answers the way the proxy expects
docker run --rm --network proxy curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  http://authelia:9091/api/authz/forward-auth

# the log file exists and is being written (the intrusion-detection agent reads it)
sudo tail -3 ./data/authelia/logs/authelia.log | jq -r '.time, .level, .msg'
```

On a host acting as an OpenID Connect provider, the discovery document must be reachable and list
your clients' algorithms:

```bash
curl -s https://auth.your-domain.com/.well-known/openid-configuration | jq -r '.issuer, .jwks_uri'
curl -s https://auth.your-domain.com/jwks.json | jq -r '.keys[].kid'
```

## Updating & day-to-day

**Pull a new image.**

```bash
cd <deploy-dir>
docker pull authelia/authelia:latest
docker stop authelia && docker rm authelia
# re-run the docker run command from Step 8
docker logs -f authelia | grep -iE 'listening|migrat|error'
```

Read the release notes first. Authelia renames configuration keys between minor versions, and a
renamed key is a start-up failure, not a warning. Schema migrations run automatically on first start
of the new version and are not reversible — take a database dump before a major upgrade.

**Change the access-control rules or the clients.** Edit `./data/authelia/config/configuration.yml`
and restart; this file is read at start, not watched.

```bash
docker stop authelia && docker start authelia
```

**Add or disable a user.** Edit `./data/authelia/config/users_database.yml`. That file *is* watched
— no restart.

**Reset someone's second factor** when they lose their phone: delete their TOTP registration through
the portal's own management page, or, failing that, from the database. They re-enrol on next login.

**Unban an account** that tripped the regulation limits — the ban is 5 minutes and clears itself; if
you cannot wait, restart the container.

**Where the logs are.** `./data/authelia/logs/authelia.log` is the JSON log the intrusion-detection
agent parses; `docker logs authelia` carries the same lines plus start-up and migration output.

**Back up**, in order of how badly you will miss it: `authelia_storage_encryption_key` (without it
every stored second factor is unreadable), `users_database.yml`, the OpenID Connect signing key, the
remaining secret files, and the `authelia` database.

## Rollback / Uninstall

```bash
cd <deploy-dir>
docker stop authelia
docker rm authelia
```

Every route on `chain-auth@file` returns 500 the moment Authelia is gone — the proxy has nothing to
forward to. To keep a service reachable while Authelia is down, move its router to
`chain-no-auth@file`, which keeps the address allow list, the bouncer, the headers and the rate limit
but drops the login requirement:

```bash
docker stop <service> && docker rm <service>
# recreate with: --label 'traefik.http.routers.<service>.middlewares=chain-no-auth@file'
```

Full removal, secrets first:

```bash
sudo shred -u ./data/authelia/config/authelia_* ./data/authelia/config/users_database.yml
rm -rf ./data/authelia
sudo rm -f /etc/logrotate.d/authelia
```

Dropping the `authelia` database on the PostgreSQL host removes all sessions, all enrolled second
factors and the identity audit trail. Do it only if you intend everyone to re-enrol.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `connection requires a valid client certificate (SQLSTATE 28000)` | The database refused Authelia's identity. Check, in order: the three files exist (`sudo ls -l ./data/certs/`); the certificate's Common Name equals the database role (`sudo openssl x509 -in ./data/certs/authelia.crt -noout -subject`); `X_AUTHELIA_CONFIG_FILTERS=template` is set (`docker exec authelia env \| grep X_AUTHELIA`); and the configuration inside the container shows a real PEM block rather than literal braces (`docker exec authelia cat /config/configuration.yml \| grep -A3 certificate_chain`). |
| Start-up fails with a certificate parse error | The configuration filter did not run, so Authelia passed the unevaluated expression to the TLS library as if it were a certificate. Set `X_AUTHELIA_CONFIG_FILTERS=template` and recreate the container. |
| TLS handshake to the database fails before any certificate is sent | The TLS server name does not match a Subject Alternative Name on the *server's* certificate. Compare `AUTHELIA_STORAGE_POSTGRES_TLS_SERVER_NAME` against `openssl s_client -connect <ip-address>:5432 -starttls postgres` output. |
| `storage encryption key is empty` | The file is missing or was written with an empty value. `sudo wc -c ./data/authelia/config/authelia_storage_encryption_key`. |
| Sessions do not stick; every page asks to log in again | The session secret file has a trailing newline, or the cookie domain does not cover the host name you are visiting. Rewrite the secret with `printf` (not `echo`) and check the `domain:` entries in the session block. |
| Protected routes return 500 | Authelia is down or unreachable from the proxy. `docker ps --filter 'name=^authelia$'`, then `docker run --rm --network proxy curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://authelia:9091/api/authz/forward-auth`. |
| Redirect loop between a service and the login page | The service's router uses `chain-no-auth@file` but its domain has no `bypass` rule here — or the reverse. Make the router chain and the access-control policy agree. |
| A service is refused with "access denied" for a user who exists | No rule matches that domain, so `default_policy: deny` applied; or the user lacks the group the rule requires. Add the domain to a rule and check the account's `groups`. |
| API calls between services get an HTML login page instead of JSON | The API paths are not bypassed, or the bypass rule sits *below* the two-factor rule for the same domain. Move it above; first match wins. |
| One-time codes are always rejected | Clock drift. The skew setting tolerates ±30 seconds; beyond that, sync time on the host (`timedatectl status`) and on the phone. |
| Locked out after a few wrong passwords | The regulation ban: 3 failures in 2 minutes bans for 5 minutes. Wait it out, or restart the container to clear it. |
| Password-reset emails never arrive | SMTP credentials or the sender address. `docker logs authelia \| grep -i notifier`. The password file must contain an application password, not the mailbox password, and must have no trailing newline. |
| Logged in on one domain but not on another on the same host | Each registrable domain needs its own `session.cookies` entry and its own login endpoint. A cookie for one domain is never sent to another. |
| An OpenID Connect client fails with `invalid_client` | The stored digest does not match the plaintext the application is sending, or the client is sending it by a method the client entry does not allow. Regenerate the pair and confirm `token_endpoint_auth_method`. |
| Every connected application logs everyone out at once | The signing key changed. Restore the previous `authelia_oidc_jwk`, or accept the re-login and make sure clients refresh the key set. |
| The log file stops growing while the service still works | Rotation used `create` instead of `copytruncate`, leaving Authelia writing to an unlinked inode — and the intrusion-detection agent blind. Fix the rotation configuration and restart the container once. |
