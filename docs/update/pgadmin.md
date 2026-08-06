# pgAdmin

## What this is

pgAdmin 4 is the browser interface to the central PostgreSQL server: schema browser, query tool,
table editor, server activity. It runs as the container `pgadmin` from the `dpage/pgadmin4:latest`
image on the database machine, alongside the database it manages.

It is deployed with the connection to that server already registered, so nobody has to type host,
port and TLS settings into a browser form. Operators log in with the homelab's single sign-on
account — pgAdmin talks OpenID Connect to the sign-on portal itself, rather than sitting behind a
forwarded-authentication check — and pgAdmin then connects to the database as the superuser using a
password it reads from a file.

pgAdmin is the one database client in the stack **without** a client certificate. Everything else
authenticates with a certificate whose Common Name equals its login role; a browser tool has no way
to hold a per-operator key, so the database server's access policy carries two narrow
password-with-TLS exceptions scoped to the addresses pgAdmin can arrive from. It still verifies the
server's certificate against the same certificate authority.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

Add yourself to the group and start a new login session if it is missing:

```bash
sudo usermod -aG docker <username>
newgrp docker
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

Create it if it is missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

**The reverse proxy is running on this machine**

It terminates TLS, owns ports 80 and 443, and routes to pgAdmin by the labels you attach in Step 5.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

**The single sign-on portal is running and reachable**

pgAdmin sends the operator's browser to it for login and then exchanges a code for a token itself, so
the portal must answer both from the browser and from inside this container's network.

```bash
docker ps --filter 'name=^authelia$'
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
curl -sf https://auth.your-domain.com/.well-known/openid-configuration | head -c 200; echo
```

You also need an OpenID Connect client registered there for pgAdmin — a client identifier and a
client secret, with the redirect URI `https://pgadmin.your-domain.com/oauth2/authorize` and the
scopes `openid email profile`. And because pgAdmin runs its own login, its domain must be listed in
the portal's access-control rules with a **bypass** policy; otherwise the portal will try to
authenticate the OAuth callback itself and the login loops.

**The name resolves to this machine**

```bash
dig +short pgadmin.your-domain.com
```

**The PostgreSQL server is up and its CA certificate is on this machine**

```bash
docker ps --filter 'name=^postgres-db$'
ls -l ./data/certs/ca.crt
openssl x509 -in ./data/certs/ca.crt -noout -subject -dates
```

pgAdmin needs only `ca.crt` — it verifies the server, it does not authenticate with a certificate of
its own.

**The database server's access policy has a password exception for pgAdmin**

Check the rules the server has actually loaded:

```bash
docker exec postgres-db psql -U <admin-user> \
  -c "SELECT line_number, type, address, auth_method FROM pg_hba_file_rules ORDER BY line_number;"
```

You must see two `hostssl … scram-sha-256` lines — one for the address you will pin pgAdmin to on the
bridge network, one for the bridge gateway — and both must appear **above** the broad
`cert clientcert=verify-full` lines, because the first matching line wins. Without them pgAdmin gets
`connection requires a valid client certificate` on every attempt.

## Setup

### Overview

1. Create the data directory owned by the account inside the image.
2. Write the registered-server definition.
3. Write the password file.
4. Write the single sign-on configuration.
5. Start the container.

---

#### Step 1: Create the data directory

```bash
mkdir -p ./data/pgadmin
sudo chown -R 5050:5050 ./data/pgadmin
sudo chmod 0750 ./data/pgadmin
```

**Explanation**: The image runs as uid/gid `5050` and treats `/var/lib/pgadmin` as writable state —
it creates its own SQLite database of operator accounts, saved queries and preferences there on first
start. If the directory is owned by anyone else the container exits during startup while trying to
create that file, and the error in the log points at a Python traceback rather than at permissions.
`0750` is enough: nothing outside the container needs to read it.

---

#### Step 2: Write the registered-server definition

```bash
sudo tee ./data/pgadmin/servers.json >/dev/null <<'EOF'
{
  "Servers": {
    "1": {
      "Name": "Primary PostgreSQL",
      "Group": "Servers",
      "Host": "<postgres-host>",
      "Port": 5432,
      "MaintenanceDB": "postgres",
      "Username": "<admin-user>",
      "SSLMode": "verify-full",
      "SSLRootCert": "/postgres-certs/ca.crt",
      "PassFile": "/pgpass",
      "Shared": false
    }
  }
}
EOF
sudo chown 5050:5050 ./data/pgadmin/servers.json
sudo chmod 0640 ./data/pgadmin/servers.json
```

**Explanation**: This file is imported once, when the container creates its default operator account
on first start. Editing it later does not change an already-imported entry — pgAdmin copies the
definition into its own database and works from that copy afterwards. To change a registered server
after the fact, either edit it in the UI or remove `./data/pgadmin/pgadmin4.db` and let the container
rebuild its state from scratch.

`SSLMode: verify-full` means pgAdmin checks the chain **and** that the name in `Host` appears in the
server certificate's Subject Alternative Name list. That constrains what you may put in `Host`: use
the name the server's certificate actually carries. Pointing it at the database container's name
works if that name is in the certificate; pointing it at the machine's LAN address works if the
address is. A name that is not in the certificate fails with a hostname mismatch even though
everything else is correct.

The choice also decides which address the connection arrives from, and therefore which line of the
server's access policy matches it. Dialling the container name over the bridge network arrives from
pgAdmin's own fixed address. Dialling the host's LAN address instead sends the connection out of the
container, into the host, and back in through Docker's NAT — so it arrives from the bridge gateway.
That is why the server has a password exception for *both* addresses.

`Shared: false` keeps the registration private to the account that imported it, rather than
publishing it to every operator who later logs in through single sign-on.

---

#### Step 3: Write the password file

```bash
sudo tee ./data/pgadmin/pgpass >/dev/null <<'EOF'
<postgres-host>:5432:*:<admin-user>:<secret>
EOF
sudo chown 5050:5050 ./data/pgadmin/pgpass
sudo chmod 0600 ./data/pgadmin/pgpass
```

**Explanation**: The format is `host:port:database:user:password`, and the `*` matches every
database, so one line covers the whole server. Keeping the password in a file referenced by
`PassFile` rather than embedding it in `servers.json` means the credential sits in a file that only
uid `5050` can read, while the server definition can stay group-readable.

Mode `0600` is not advisory: pgAdmin (like `libpq`) **silently ignores** a password file with looser
permissions, and the symptom is a password prompt on a connection you configured to be automatic —
no error mentioning the file at all. The host and port fields must match `servers.json` exactly, or
the lookup misses and you get the same silent prompt.

---

#### Step 4: Write the single sign-on configuration

```bash
sudo tee ./data/pgadmin/config_local.py >/dev/null <<'EOF'
AUTHENTICATION_SOURCES = ['oauth2', 'internal']
MASTER_PASSWORD_REQUIRED = False
OAUTH2_AUTO_CREATE_USER = True
OAUTH2_CONFIG = [{
    'OAUTH2_NAME': 'Authelia',
    'OAUTH2_DISPLAY_NAME': 'Authelia',
    'OAUTH2_CLIENT_ID': '<oidc-client-id>',
    'OAUTH2_CLIENT_SECRET': '<secret>',
    'OAUTH2_API_BASE_URL': 'https://auth.your-domain.com',
    'OAUTH2_AUTHORIZATION_URL': 'https://auth.your-domain.com/api/oidc/authorization',
    'OAUTH2_TOKEN_URL': 'https://auth.your-domain.com/api/oidc/token',
    'OAUTH2_USERINFO_ENDPOINT': 'https://auth.your-domain.com/api/oidc/userinfo',
    'OAUTH2_SERVER_METADATA_URL': 'https://auth.your-domain.com/.well-known/openid-configuration',
    'OAUTH2_SCOPE': 'openid email profile',
    'OAUTH2_USERNAME_CLAIM': 'email',
    'OAUTH2_ICON': 'fa-openid',
    'OAUTH2_CHALLENGE_METHOD': 'S256',
    'OAUTH2_RESPONSE_TYPE': 'code',
}]
EOF
sudo chown 5050:5050 ./data/pgadmin/config_local.py
sudo chmod 0640 ./data/pgadmin/config_local.py
```

**Explanation**: `config_local.py` is the supported override point — pgAdmin imports it after its
built-in configuration, so nothing in the image has to be patched.

`AUTHENTICATION_SOURCES` lists sign-on first and keeps the internal database second on purpose: the
built-in account created from the environment variables in Step 5 stays usable as a way back in when
the sign-on portal is down or its client registration is broken. Drop `'internal'` only if you are
prepared to fix an outage without a login.

`OAUTH2_AUTO_CREATE_USER` creates a pgAdmin account the first time someone authenticates
successfully, keyed by the claim named in `OAUTH2_USERNAME_CLAIM` — the email address. Access control
therefore lives in the sign-on portal's rules, not in pgAdmin's user list; whoever the portal lets
through gets an account here.

`OAUTH2_CHALLENGE_METHOD: 'S256'` with `OAUTH2_RESPONSE_TYPE: 'code'` is the authorization-code flow
with PKCE. The homelab's OpenID provider requires it, and without PKCE the token exchange is rejected
with an opaque `invalid_request`.

`MASTER_PASSWORD_REQUIRED = False` — and its environment-variable twin in Step 5 — turns off
pgAdmin's own secondary passphrase. In server mode pgAdmin otherwise asks each operator for a master
password to unlock stored server credentials, which cannot work here: the operators authenticate
through single sign-on and never set one, so the pre-registered connection would be permanently
locked.

---

#### Step 5: Start the container

```bash
docker run -d \
  --name pgadmin \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e PGADMIN_DEFAULT_EMAIL='<admin-email>' \
  -e PGADMIN_DEFAULT_PASSWORD='<secret>' \
  -e PGADMIN_CONFIG_SERVER_MODE=True \
  -e PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION=True \
  -e PGADMIN_SERVER_JSON_FILE=/var/lib/pgadmin/servers.json \
  -e PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False \
  -v "$(pwd)/data/pgadmin:/var/lib/pgadmin" \
  -v "$(pwd)/data/pgadmin/pgpass:/pgpass:ro" \
  -v "$(pwd)/data/pgadmin/config_local.py:/pgadmin4/config_local.py:ro" \
  -v "$(pwd)/data/certs/ca.crt:/postgres-certs/ca.crt:ro" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.pgadmin.entrypoints=https' \
  --label 'traefik.http.routers.pgadmin.rule=Host(`pgadmin.your-domain.com`)' \
  --label 'traefik.http.routers.pgadmin.tls=true' \
  --label 'traefik.http.routers.pgadmin.middlewares=chain-no-auth@file' \
  --label 'traefik.http.routers.pgadmin.service=pgadmin' \
  --label 'traefik.http.services.pgadmin.loadbalancer.server.port=80' \
  --health-cmd 'wget --quiet --spider http://localhost:80/misc/ping || exit 1' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 60s \
  dpage/pgadmin4:latest
```

**Explanation**:

- **`chain-no-auth@file`, not the authenticating chain.** pgAdmin performs its own OpenID Connect
  login, so a forwarded-authentication check in front of it would demand a session before the browser
  ever reached pgAdmin's login page — and would intercept the OAuth callback, which must arrive at
  pgAdmin unauthenticated to complete the exchange. The route is still not open: the intrusion
  detection bouncer and TLS are part of that chain too, and pgAdmin refuses everything until the
  sign-on portal has issued a token.
- **`--ip <docker-ip>` matters more here than elsewhere.** This address is one of the two written
  into the database server's access policy as a password exception. If the container is allowed to
  pick an address from the automatic pool, it will eventually get a different one and every database
  connection starts failing with `connection requires a valid client certificate`.
- The data directory is mounted read-write because pgAdmin owns its state there. `pgpass`,
  `config_local.py` and `ca.crt` are mounted read-only, individually: they are inputs, and pgAdmin
  has no business rewriting them.
- `ca.crt` lands at `/postgres-certs/ca.crt`, matching `SSLRootCert` in `servers.json`. Only the CA
  is mounted — deliberately no client key, since pgAdmin's identity is the password.
- `PGADMIN_DEFAULT_EMAIL`/`PGADMIN_DEFAULT_PASSWORD` create the built-in fallback account on first
  start and are read only then; changing them later does nothing.
- `SERVER_MODE=True` makes pgAdmin multi-user with real login sessions rather than the single-user
  desktop mode. `ENHANCED_COOKIE_PROTECTION=True` binds the session cookie to the client address, so
  a stolen cookie is not portable to another machine.
- The health check hits `/misc/ping`, which answers 200 without a session — unlike `/`, which
  redirects to the login page and would make the check depend on the sign-on portal being up.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory |
| `<username>` / `<pgid>` | Account and group owning `./data` | The account you administer the host with |
| `<docker-ip>` | Fixed address for the pgAdmin container | Must be exactly the address named in the database server's password-exception line |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy` |
| `<postgres-host>` | How pgAdmin dials the database | A name or address present in the server certificate's SAN; the same value in `servers.json` and `pgpass` |
| `<admin-user>` | PostgreSQL superuser name | The account the registered connection uses |
| `<secret>` | Passwords | One for the database superuser, one for the built-in fallback account, one for the OpenID client |
| `<admin-email>` | Login name of the built-in fallback account | Any address; it is a local account, not a mailbox |
| `<oidc-client-id>` | OpenID client identifier for pgAdmin | Whatever you registered in the sign-on portal |
| `pgadmin.your-domain.com` | Public name of this UI | Must resolve to this machine and be a bypass rule in the sign-on portal |

## Verification

```bash
docker ps --filter 'name=^pgadmin$'
docker inspect --format '{{.State.Health.Status}}' pgadmin
docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pgadmin

docker exec pgadmin wget -qO- http://localhost:80/misc/ping; echo
curl -sI https://pgadmin.your-domain.com | head -1
```

Confirm the container can reach the database and that TLS verification succeeds:

```bash
docker exec pgadmin python3 -c "import socket; s=socket.create_connection(('<postgres-host>',5432),5); print('tcp ok'); s.close()"
docker exec pgadmin ls -l /postgres-certs/ca.crt /pgpass
openssl x509 -in ./data/certs/ca.crt -noout -subject -enddate
```

Then, in the browser: open `https://pgadmin.your-domain.com`, log in through the sign-on button, and
expand "Primary PostgreSQL" in the tree. It must connect without prompting for a password — a prompt
means the password file was ignored (see the mode note in Step 3) or its host/port fields do not
match the registered server.

## Updating & day-to-day

**Update the image.** The tag is `latest`, so a pull genuinely changes versions:

```bash
docker pull dpage/pgadmin4:latest
docker stop pgadmin && docker rm pgadmin
# re-run the docker run command from Step 5 verbatim
```

Operator accounts, saved queries and server registrations survive because they live in
`./data/pgadmin`, not in the container.

**Change the registered connection.** Editing `servers.json` after the first start has no effect —
edit the server in the UI instead. To force a clean re-import, stop the container, remove
`./data/pgadmin/pgadmin4.db`, and start it again; that also erases saved queries and operator
preferences.

**Change the database password.** Update it in the database, then rewrite `./data/pgadmin/pgpass`
with `sudo tee` (keeping mode `0600`) and restart the container.

**Back up.** `./data/pgadmin/pgadmin4.db` is the whole of pgAdmin's own state. It is small and worth
copying before an upgrade:

```bash
docker stop pgadmin
sudo cp -a ./data/pgadmin/pgadmin4.db ./data/pgadmin/pgadmin4.db.bak
docker start pgadmin
```

**Logs**: `docker logs -f pgadmin`. Sign-on failures and database connection errors both appear here.

## Rollback / Uninstall

```bash
docker stop pgadmin
docker rm pgadmin
```

The state stays in `./data/pgadmin`, so re-running Step 5 brings the same accounts and registrations
back. To remove it completely:

```bash
sudo rm -rf ./data/pgadmin
```

Then remove the two password-exception lines for pgAdmin from the database server's access policy —
they exist only for this container, and leaving a password-authenticated address behind after the
client is gone is exactly the kind of stale rule that weakens the policy silently. Rewrite the file
in place and reload the server.

## Troubleshooting

**Container exits seconds after start, log ends in a Python traceback about a path**
`./data/pgadmin` is not owned by `5050:5050`. Fix with `sudo chown -R 5050:5050 ./data/pgadmin` and
start it again.

**Connecting to the registered server prompts for a password**
The password file was ignored or missed. Check `ls -l ./data/pgadmin/pgpass` shows `0600` and
`5050:5050`, and that its host and port fields are byte-identical to `Host`/`Port` in `servers.json`.

**`connection requires a valid client certificate` (SQLSTATE 28000)**
pgAdmin matched one of the database server's certificate-required lines instead of its password
exception. Either the container's address changed, or the connection hairpinned in from the bridge
gateway and only the other address is excepted. Compare the address in the database server's log with
the loaded rules (`SELECT … FROM pg_hba_file_rules`).

**`server certificate for "…" does not match host name`**
The `Host` value is not in the server certificate's Subject Alternative Name list. Either use a name
that is, or re-issue the server certificate on the database machine with that name added.

**`SSL error: certificate verify failed`**
`/postgres-certs/ca.crt` is not the authority that signed the server certificate — usually a stale
copy left over from a different database server. Replace `./data/certs/ca.crt` with the current one
and restart the container.

**Login loops back to the sign-on portal forever**
The domain is not excluded from forwarded authentication. Its access-control rule in the portal must
be a bypass, and the route must carry the non-authenticating middleware chain — otherwise the OAuth
callback is intercepted before pgAdmin can complete the exchange.

**Sign-on button returns `invalid_request` or `invalid_client`**
The client identifier or secret in `config_local.py` does not match what the portal has registered,
or the registered redirect URI is not `https://pgadmin.your-domain.com/oauth2/authorize`. Both sides
must also agree on PKCE with `S256`.

**A master password is demanded after logging in**
`MASTER_PASSWORD_REQUIRED` is still on. It has to be off in both places — the line in
`config_local.py` and `PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False` in the container environment.

**Health check reports unhealthy while the UI works**
The check requests `/misc/ping` inside the container on port 80. If you changed the internal port,
the label `traefik.http.services.pgadmin.loadbalancer.server.port` and the health command must both
follow.
