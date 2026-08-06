# Traefik

## What this is

Traefik is the reverse proxy every host in this stack runs. It owns ports 80 and 443, terminates
TLS with wildcard certificates it obtains from Let's Encrypt over a Cloudflare DNS-01 challenge,
watches the local Docker daemon for containers that ask to be published, and sends each request
through a chain of middlewares — IP allow list, intrusion-detection bouncer, security headers, rate
limit, single sign-on — before it reaches the service behind it.

It runs on every host: the NAS, the monitoring box, the database host, the automation host and the
public server. Each host's Traefik only routes to containers on that host. It talks to the
Cloudflare API (to answer the ACME challenge), to the local Docker socket (to discover containers),
to Authelia over the shared network (forward authentication), and to the local CrowdSec agent
(decision stream). Its own dashboard is published behind single sign-on.

There are two situations. On an **internal host**, Traefik sits on the LAN, has one wildcard
certificate, and trusts the client address it sees directly. On the **public-facing host**, inbound
traffic arrives through Cloudflare's proxy, so Traefik additionally restores the real client address
from Cloudflare's headers, can drop requests by country, carries certificates for several domains,
and relays machine-to-machine webhooks. Both are covered below; where they differ it says so.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

**The `./data` working directory exists**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

All paths below are relative to `<deploy-dir>`. Run every command from there.

**The shared `proxy` bridge network exists**

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

**Ports 80 and 443 are free and open**

```bash
sudo ss -lntp | grep -E ':80 |:443 '
sudo ufw status verbose | grep -E '80/tcp|443/tcp'
```

Nothing else may hold those ports. If a distro web server is installed, stop and disable it.

**You have a Cloudflare API token that can edit DNS**

The token needs `Zone:DNS:Edit` on every zone you will request a certificate for, plus
`Zone:Zone:Read`. Prove it works before you start, or the first certificate request fails silently
into a retry loop:

```bash
curl -s -H "Authorization: Bearer <secret>" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .
```

**DNS for the dashboard resolves to this host**

```bash
dig +short proxy.your-domain.com
```

**Authelia is running, or you accept that protected routes will fail**

Traefik starts fine without it, but the `chain-auth@file` middleware forwards to Authelia, so every
protected route returns 500 until Authelia answers.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

**CrowdSec is running, or the bouncer enforces nothing**

```bash
docker ps --filter 'name=^crowdsec$'
docker exec crowdsec cscli lapi status
```

You need the bouncer API key CrowdSec issued for Traefik (`<secret>` in Step 5). Traefik with an
unknown key still loads the middleware and reports itself enabled while blocking nothing.

## Setup

### Overview

1. Create the directory layout.
2. Install the standing middleware definitions.
3. Create `acme.json` with `0600`.
4. Write the static configuration `traefik.yml`.
5. Write the allow-list and bouncer middlewares.
6. Write the four chains.
7. Public-facing host only: real-IP, country block, webhook relay.
8. Set up log rotation.
9. Start the container.
10. Confirm it answers its own ping.

---

#### Step 1: Create the directory layout

```bash
cd <deploy-dir>
mkdir -p ./data/traefik/rules ./data/traefik/logs
sudo chown -R <username>:<pgid> ./data/traefik
sudo chmod 0755 ./data/traefik ./data/traefik/rules ./data/traefik/logs
```

**Explanation**: Three directories with three different jobs. `./data/traefik` holds the static
configuration, which Traefik reads exactly once at start. `./data/traefik/rules` is the dynamic
configuration directory — Traefik watches it and reloads any change without a restart, which is why
routers and middlewares go there and entrypoints do not. `./data/traefik/logs` is bind-mounted so
the logs survive the container being recreated, and so the intrusion-detection agent on this host
can read them; if the logs stayed inside the container, every image pull would throw away the
evidence.

---

#### Step 2: Install the standing middleware definitions

These six files never change between hosts. Each defines one middleware that the chains in Step 6
compose.

```bash
cd <deploy-dir>

tee ./data/traefik/rules/authelia.yml >/dev/null <<'EOF'
http:
  middlewares:
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Name"
          - "Remote-Email"
EOF

tee ./data/traefik/rules/secure-headers.yml >/dev/null <<'EOF'
http:
  middlewares:
    secure-headers:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
        accessControlMaxAge: 100
        hostsProxyHeaders:
          - "X-Forwarded-Host"
        sslRedirect: true
        stsSeconds: 31536000 # 1 year
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=()"
        featurePolicy: "vibrate 'none'; geolocation 'none'"
        customResponseHeaders:
          server: "" # hide server info
EOF

tee ./data/traefik/rules/rate-limit.yml >/dev/null <<'EOF'
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100
        burst: 50
EOF

tee ./data/traefik/rules/compress.yml >/dev/null <<'EOF'
http:
  middlewares:
    compress:
      compress: {}
EOF

tee ./data/traefik/rules/https-redirectscheme.yml >/dev/null <<'EOF'
http:
  middlewares:
    https-redirectscheme:
      redirectScheme:
        scheme: https
        permanent: true
EOF

tee ./data/traefik/rules/redirectregex-admin.yml >/dev/null <<'EOF'
http:
  middlewares:
    redirectregex-admin:
      redirectRegex:
        regex: "/admin/(.*)"
        replacement: /
EOF

sudo chown -R <username>:<pgid> ./data/traefik/rules
sudo chmod 0755 ./data/traefik/rules/*.yml
```

**Explanation**: `authelia` is the forward-auth middleware — Traefik asks Authelia about every
request on a protected route and, on a 200, copies the four `Remote-*` headers onto the request so
the backend knows who the user is. `trustForwardHeader` is safe here only because Traefik is the
first hop that a client can reach; the headers come from Traefik itself, not from the client.
`secure-headers` sets HSTS for a year including subdomains, disables MIME sniffing, restricts the
referrer, and blanks the `server` response header so an attacker cannot fingerprint the proxy
version. `rate-limit` caps a single source at 100 requests per second with a burst of 50 — high
enough that a media client streaming and scrubbing never trips it, low enough to make brute-force
and scraping expensive. The last three (`compress`, `https-redirectscheme`, `redirectregex-admin`)
are available for individual routers to reference but are not part of any chain; install them so
they are there when a service needs one.

---

#### Step 3: Create `acme.json` with `0600`

```bash
cd <deploy-dir>
if [ ! -f ./data/traefik/acme.json ]; then
  touch ./data/traefik/acme.json
  sudo chown <username>:<pgid> ./data/traefik/acme.json
  chmod 0600 ./data/traefik/acme.json
fi
ls -l ./data/traefik/acme.json
```

**Explanation**: This one file holds the ACME account key and every issued certificate's private
key. Traefik refuses to start if it is group- or world-readable — `0600` is not advice, it is a
start condition. Create it empty rather than letting Docker create it: a bind mount whose source
does not exist is created by Docker as a *directory*, and Traefik then fails with a permissions
error that points nowhere useful. Never copy an `acme.json` from another host; the account key is
bound to the account that requested the certificates. If you delete it, Traefik requests everything
again from scratch, and Let's Encrypt's duplicate-certificate limit (5 per identical name set per
week) is real — losing this file twice in a week costs you TLS until the window rolls.

---

#### Step 4: Write the static configuration

This is read once at start; changing it requires recreating the container. On an **internal host**:

```bash
cd <deploy-dir>
tee ./data/traefik/traefik.yml >/dev/null <<'EOF'
api:
  dashboard: true
  debug: true

experimental:
  plugins:
    crowdsec-bouncer-traefik-plugin:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.4.4

certificatesResolvers:
  cloudflare:
    acme:
      email: you@your-domain.com
      storage: acme.json
      caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: cloudflare
        propagation:
          disableChecks: false
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
  # Prometheus metrics endpoint. Not published to the host — the local metrics
  # agent scrapes it in-cluster at traefik:8082.
  metrics:
    address: ":8082"

log:
  level: "INFO"
  filePath: "/var/log/traefik/traefik.log"
accessLog:
  filePath: "/var/log/traefik/access.log"
  format: json
  fields:
    defaultMode: keep
    headers:
      defaultMode: drop
      names:
        User-Agent: keep

metrics:
  prometheus:
    entryPoint: metrics
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
EOF
sudo chown <username>:<pgid> ./data/traefik/traefik.yml
sudo chmod 0755 ./data/traefik/traefik.yml
```

On the **public-facing host**, use the same file but with two extra plugins declared:

```bash
cd <deploy-dir>
tee ./data/traefik/traefik.yml >/dev/null <<'EOF'
api:
  dashboard: true
  debug: true

experimental:
  plugins:
    crowdsec-bouncer-traefik-plugin:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.4.4
    cloudflarewarp:
      moduleName: github.com/BetterCorp/cloudflarewarp
      version: v1.3.3
    geoblock:
      moduleName: github.com/PascalMinder/geoblock
      version: v0.3.3

certificatesResolvers:
  cloudflare:
    acme:
      email: you@your-domain.com
      storage: acme.json
      caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: cloudflare
        propagation:
          disableChecks: false
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
  metrics:
    address: ":8082"

log:
  level: "INFO"
  filePath: "/var/log/traefik/traefik.log"
accessLog:
  filePath: "/var/log/traefik/access.log"
  format: json
  fields:
    defaultMode: keep
    headers:
      defaultMode: drop
      names:
        User-Agent: keep

metrics:
  prometheus:
    entryPoint: metrics
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
EOF
sudo chown <username>:<pgid> ./data/traefik/traefik.yml
sudo chmod 0755 ./data/traefik/traefik.yml
```

**Explanation**: Certificates are issued over the DNS-01 challenge, not HTTP-01, for one decisive
reason: DNS-01 is the only challenge that can issue a **wildcard** certificate, and it works for
hosts that are not reachable from the internet at all — an internal machine can hold a valid public
certificate without ever accepting an inbound connection. `disableChecks: false` keeps Traefik
verifying that the `_acme-challenge` record has actually propagated before it tells Let's Encrypt to
look, and the two public resolvers are named explicitly so that check does not consult a local
resolver that is still serving a cached negative answer. The `http` entrypoint does nothing but
redirect to `https`. The `https` entrypoint carries `chain-auth@file` as an entrypoint-level
middleware, which means **every** route is authenticated by default and a service becomes public
only by deliberately overriding the chain on its own router — a fail-closed default, so forgetting a
label exposes nothing. The `metrics` entrypoint on 8082 is not published to the host; the local
metrics agent reaches it over the shared network, so engine metrics never cross the LAN unauthenticated.
`exposedByDefault: false` means a container is invisible to Traefik until it carries
`traefik.enable=true`. The access log is JSON with all fields kept but headers dropped except
`User-Agent` — full headers would put cookies and authorization tokens into a file the
intrusion-detection agent reads and the log shipper forwards. `insecureSkipVerify: false` keeps
Traefik validating certificates on the backend side too.

---

#### Step 5: Write the allow-list and bouncer middlewares

```bash
cd <deploy-dir>

tee ./data/traefik/rules/default-whitelist.yml >/dev/null <<'EOF'
http:
  middlewares:
    default-whitelist:
      ipAllowList:
        sourceRange:
          - <private-network-cidr>
          - <docker-subnet>
          - 127.0.0.1/32
EOF

tee ./data/traefik/rules/tunnel-whitelist.yml >/dev/null <<'EOF'
http:
  middlewares:
    tunnel-whitelist:
      ipAllowList:
        sourceRange:
          - <private-network-cidr>
          - <docker-subnet>
          - 127.0.0.1/32
EOF

tee ./data/traefik/rules/crowdsec-bouncer.yml >/dev/null <<'EOF'
http:
  middlewares:
    crowdsec-bouncer:
      plugin:
        crowdsec-bouncer-traefik-plugin:
          enabled: "true"
          logLevel: INFO
          crowdsecMode: stream
          updateIntervalSeconds: 60
          defaultDecisionSeconds: 60
          httpTimeoutSeconds: 10
          crowdsecLapiScheme: http
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiKey: "<secret>"
          forwardedHeadersTrustedIPs:
            - "<docker-subnet>"
          clientTrustedIPs:
            - <private-network-cidr>
            - <docker-subnet>
            - 127.0.0.1/32
EOF

sudo chown <username>:<pgid> ./data/traefik/rules/*.yml
sudo chmod 0755 ./data/traefik/rules/*.yml
```

On the **public-facing host**, `default-whitelist` must additionally contain Cloudflare's published
edge ranges — otherwise the allow list sees Cloudflare's address as the client and rejects the whole
internet. Append them:

```bash
cd <deploy-dir>
tee ./data/traefik/rules/default-whitelist.yml >/dev/null <<'EOF'
http:
  middlewares:
    default-whitelist:
      ipAllowList:
        sourceRange:
          - <private-network-cidr>
          - <docker-subnet>
          - 127.0.0.1/32
          - <this-host-public-ip>/32
          - 103.21.244.0/22
          - 103.22.200.0/22
          - 103.31.4.0/22
          - 104.16.0.0/13
          - 104.24.0.0/14
          - 108.162.192.0/18
          - 131.0.72.0/22
          - 141.101.64.0/18
          - 162.158.0.0/15
          - 172.64.0.0/13
          - 173.245.48.0/20
          - 188.114.96.0/20
          - 190.93.240.0/20
          - 197.234.240.0/22
          - 198.41.128.0/17
          - 2400:cb00::/32
          - 2606:4700::/32
          - 2803:f800::/32
          - 2405:b500::/32
          - 2405:8100::/32
          - 2a06:98c0::/29
          - 2c0f:f248::/32
EOF
sudo chown <username>:<pgid> ./data/traefik/rules/default-whitelist.yml
sudo chmod 0755 ./data/traefik/rules/default-whitelist.yml
```

Your own current public address belongs in that list too, because a service on the public host that
fetches one of its own public URLs comes back to itself from the outside. If you run an address
tracker, read it:

```bash
curl -s -H "Authorization: Bearer <secret>" https://node-ip.your-domain.com/current_ip | jq -r .ip
```

**Explanation**: `default-whitelist` is the outer gate — everything in the standard chains passes
through it first, so an address that is not listed never reaches authentication, never reaches a
backend, and costs nothing to reject. `tunnel-whitelist` is the same idea without the Cloudflare
ranges: it is for routes that must only be reachable over the private network even on a host whose
other routes are public. The bouncer middleware runs the CrowdSec plugin **inside** the Traefik
process — there is no bouncer container to deploy. `crowdsecMode: stream` is the important setting:
instead of asking the local decision API about every request, the plugin pulls the complete decision
list every 60 seconds and keeps it in memory, which is what makes it viable to enforce a
twenty-thousand-entry community blocklist at zero per-request latency. `crowdsecLapiHost:
crowdsec:8080` is a container name on the shared network, so the decision stream never leaves the
host. `forwardedHeadersTrustedIPs` limits which sources the plugin will believe an
`X-Forwarded-For` header from — restricting it to the shared network is what stops a client from
spoofing its own address past the bouncer. `clientTrustedIPs` are addresses the plugin never blocks,
so a mistaken ban cannot lock you out from the LAN. The key must be one CrowdSec has actually
issued; an unknown key is rejected with 403 and, in stream mode, the plugin's decision list simply
stays empty — it enforces nothing while still reporting itself enabled.

---

#### Step 6: Write the four chains

```bash
cd <deploy-dir>

tee ./data/traefik/rules/chain-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-auth:
      chain:
        middlewares:
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

tee ./data/traefik/rules/chain-no-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-no-auth:
      chain:
        middlewares:
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
EOF

tee ./data/traefik/rules/chain-basic-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-basic-auth:
      chain:
        middlewares:
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

tee ./data/traefik/rules/chain-tunnel.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-tunnel:
      chain:
        middlewares:
          - tunnel-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

sudo chown <username>:<pgid> ./data/traefik/rules/chain-*.yml
sudo chmod 0755 ./data/traefik/rules/chain-*.yml
```

On the **public-facing host**, every chain gains `cloudflarewarp` as its **first** entry, and — if
you block any countries — `geoblock` immediately after it:

```bash
cd <deploy-dir>

tee ./data/traefik/rules/chain-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-auth:
      chain:
        middlewares:
          - cloudflarewarp
          - geoblock
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

tee ./data/traefik/rules/chain-no-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-no-auth:
      chain:
        middlewares:
          - cloudflarewarp
          - geoblock
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
EOF

tee ./data/traefik/rules/chain-basic-auth.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-basic-auth:
      chain:
        middlewares:
          - cloudflarewarp
          - geoblock
          - default-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

tee ./data/traefik/rules/chain-tunnel.yml >/dev/null <<'EOF'
http:
  middlewares:
    chain-tunnel:
      chain:
        middlewares:
          - cloudflarewarp
          - tunnel-whitelist
          - crowdsec-bouncer
          - secure-headers
          - rate-limit
          - authelia
EOF

sudo chown <username>:<pgid> ./data/traefik/rules/chain-*.yml
sudo chmod 0755 ./data/traefik/rules/chain-*.yml
```

If you block no countries, leave `geoblock` out of the chains entirely — a chain that names a
middleware you never defined makes every route using it return 500. Note that `chain-tunnel` never
carries `geoblock`: it is already restricted to the private network, where country lookup is
meaningless.

**Explanation**: Order in a chain is execution order, and it is chosen so that the cheapest,
most-certain rejection happens first. On the public host `cloudflarewarp` must be first of all,
because it is what rewrites the client address from Cloudflare's `CF-Connecting-IP` header — every
middleware after it then sees the real visitor rather than a Cloudflare edge address, and putting
the allow list or the bouncer ahead of it would have them judging Cloudflare instead of the client.
Then country blocking, then the address allow list, then the intrusion-detection bouncer, then
headers, then rate limiting, and only then the single sign-on round trip, which is the one step that
costs a network call to another container. `chain-auth` is the default for anything a human uses.
`chain-no-auth` is the same protection without the login redirect, for services that carry their own
authentication or for APIs called by machines. `chain-tunnel` swaps the allow list for the
private-network-only one.

---

#### Step 7: Public-facing host only — real-IP, country block, webhook relay

Skip this entire step on an internal host.

```bash
cd <deploy-dir>

tee ./data/traefik/rules/cloudflarewarp.yml >/dev/null <<'EOF'
http:
  middlewares:
    cloudflarewarp:
      plugin:
        cloudflarewarp:
          disableDefault: false
EOF

tee ./data/traefik/rules/geoblock.yml >/dev/null <<'EOF'
http:
  middlewares:
    geoblock:
      plugin:
        geoblock:
          silentStartUp: false
          allowLocalRequests: true
          logLocalRequests: false
          logAllowedRequests: false
          logApiRequests: false
          api: "https://get.geojs.io/v1/ip/country/{ip}"
          apiTimeoutMs: 750
          cacheSize: 15
          forceMonthlyUpdate: true
          allowUnknownCountries: true
          unknownCountryApiResponse: "nil"
          blackListMode: true
          countries:
            - <country-code>
            - <country-code>
EOF

tee ./data/traefik/rules/hooks.yml >/dev/null <<'EOF'
http:
  routers:
    hook-example:
      rule: "Host(`hooks.your-domain.com`) && PathPrefix(`/<hook-path>`)"
      entryPoints: [https]
      tls: {}
      service: upstream
      middlewares:
        - chain-no-auth@file
        - hook-example-rewrite

  middlewares:
    hook-example-rewrite:
      replacePathRegex:
        regex: "^/<hook-path>"
        replacement: "/api/v1/main/executions/webhook"

  services:
    upstream:
      loadBalancer:
        passHostHeader: false
        servers:
          - url: "https://<internal-service>.your-domain.com"
EOF

sudo chown <username>:<pgid> ./data/traefik/rules/*.yml
sudo chmod 0755 ./data/traefik/rules/*.yml
```

**Explanation**: `cloudflarewarp` with `disableDefault: false` keeps the plugin's built-in list of
Cloudflare edge ranges, so it only rewrites the client address when the request genuinely came from
Cloudflare — a request arriving directly at the origin address cannot forge a `CF-Connecting-IP`
header and have it believed. `geoblock` is in blacklist mode: only the named countries are rejected,
everything else passes. `allowLocalRequests: true` exempts private ranges (the lookup service knows
nothing about them), and `allowUnknownCountries: true` fails **open** — if the country lookup API is
unreachable or slow past the 750 ms timeout, visitors are let through rather than the whole site
going dark because of a third-party outage. The webhook relay exists because the internal
orchestration host has no public address: the public host accepts the call on a path only the caller
knows, strips that path prefix and replaces it with the real endpoint, and forwards it to the
internal service over its own name. It uses `chain-no-auth@file` deliberately — the callers are
machines that cannot complete an interactive login — and the receiving service authenticates the
call itself with a key embedded in the path. `passHostHeader: false` makes Traefik send the *backend*
URL's host name, which is the name the internal proxy routes that service on; forwarding the public
host name instead would produce a 404 at the far end.

---

#### Step 8: Set up log rotation

```bash
sudo tee /etc/logrotate.d/traefik >/dev/null <<'EOF'
<deploy-dir>/data/traefik/logs/traefik.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

sudo tee /etc/logrotate.d/traefik-access >/dev/null <<'EOF'
<deploy-dir>/data/traefik/logs/access.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

sudo chown root:root /etc/logrotate.d/traefik /etc/logrotate.d/traefik-access
sudo chmod 0644 /etc/logrotate.d/traefik /etc/logrotate.d/traefik-access
sudo logrotate -d /etc/logrotate.d/traefik
```

Replace `<deploy-dir>` with the absolute path — logrotate does not accept a relative one.

**Explanation**: `copytruncate` rather than `create` is required here because Traefik holds both log
files open for the container's whole lifetime and never reopens them. Renaming the file out from
under it would leave Traefik writing to an unlinked inode: the log would appear to stop, disk would
keep filling, and nothing would say so. `copytruncate` copies the content away and truncates the
original in place, so the open file descriptor stays valid and ownership and mode are preserved.
The access log on a public host is the largest file this stack produces — 50 MB × 3 is a deliberate
cap, and the intrusion-detection agent has already read each line long before it rotates.

---

#### Step 9: Start the container

On an **internal host**:

```bash
cd <deploy-dir>
docker run -d \
  --name traefik \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  --add-host host.docker.internal:host-gateway \
  -p 80:80 \
  -p 443:443 \
  -e CF_API_EMAIL=you@your-domain.com \
  -e CF_DNS_API_TOKEN=<secret> \
  -v /etc/localtime:/etc/localtime:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$(pwd)/data/traefik/traefik.yml:/traefik.yml:ro" \
  -v "$(pwd)/data/traefik/acme.json:/acme.json" \
  -v "$(pwd)/data/traefik/rules:/rules" \
  -v "$(pwd)/data/traefik/logs:/var/log/traefik" \
  --health-cmd 'traefik healthcheck --ping' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.traefik.entrypoints=http' \
  --label 'traefik.http.routers.traefik.rule=Host(`proxy.your-domain.com`)' \
  --label 'traefik.http.middlewares.traefik-https-redirect.redirectscheme.scheme=https' \
  --label 'traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https' \
  --label 'traefik.http.routers.traefik.middlewares=traefik-https-redirect' \
  --label 'traefik.http.routers.traefik-secure.entrypoints=https' \
  --label 'traefik.http.routers.traefik-secure.rule=Host(`proxy.your-domain.com`)' \
  --label 'traefik.http.routers.traefik-secure.middlewares=chain-auth@file' \
  --label 'traefik.http.routers.traefik-secure.service=api@internal' \
  --label 'traefik.http.routers.traefik-secure.tls=true' \
  --label 'traefik.http.routers.traefik-secure.tls.certresolver=cloudflare' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[0].main=your-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[0].sans=*.your-domain.com' \
  traefik:latest

# second network, for reaching the host's own published ports
docker network connect bridge traefik
```

On the **public-facing host**, add one `domains[n]` pair per extra zone before starting:

```bash
  --label 'traefik.http.routers.traefik-secure.tls.domains[1].main=your-second-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[1].sans=*.your-second-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[2].main=your-third-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[2].sans=*.your-third-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[3].main=your-fourth-domain.com' \
  --label 'traefik.http.routers.traefik-secure.tls.domains[3].sans=*.your-fourth-domain.com' \
```

**Explanation**: The Docker socket is mounted **read-only** — Traefik only ever needs to list
containers and watch events, and a writable socket inside a container is equivalent to giving that
container root on the host. `no-new-privileges` blocks any setuid escalation inside the container
for the same reason. Ports 80 and 443 are the only published ports on the whole host; every other
service reaches the world through this one. `acme.json` is mounted writable (Traefik writes new
certificates into it) while the static configuration is read-only, so a compromised proxy cannot
rewrite its own configuration and restart into it. Attaching the default `bridge` network as a
second interface, together with `host.docker.internal` mapped to the host gateway, is what lets
Traefik proxy to something listening on the host itself rather than in a container. Credentials go
in as environment variables consumed only by the ACME client. The dashboard is published on two
routers: a plain HTTP one that redirects, and an HTTPS one bound to Traefik's own internal API
service and protected by `chain-auth@file`, so the dashboard sits behind full single sign-on rather
than a shared password. The `domains[n]` labels are what actually request the wildcard
certificates — the DNS-01 challenge issues one certificate per `main`/`sans` pair, so a host serving
four zones needs four pairs.

---

#### Step 10: Confirm it answers its own ping

```bash
for i in $(seq 1 6); do
  docker exec traefik traefik healthcheck --ping && break
  sleep 10
done

docker ps --filter 'name=^traefik$'
docker logs traefik --tail 40
```

**Explanation**: `traefik healthcheck --ping` runs the same binary that is serving traffic and asks
its own ping endpoint, so a zero exit means the static configuration parsed, the entrypoints bound
to 80/443, and the plugins downloaded and compiled. That last part is why the retry loop exists:
the CrowdSec, Cloudflare and geo-block plugins are fetched from source and built at first start, and
on a cold cache that takes tens of seconds during which the process is alive but not yet serving.
A container that is `Up` proves nothing on its own.

## The middleware chains — which one to use

Every service you publish attaches to the `proxy` network, carries `traefik.enable=true`, and names
exactly one chain on its router. The `https` entrypoint applies `chain-auth@file` to everything by
default, so naming a chain on the router is how you *reduce* protection, never how you add it.

| Chain | Who reaches it | Use it for |
| --- | --- | --- |
| `chain-auth@file` | Allow-listed addresses, after single sign-on | Anything a human logs into that has no good authentication of its own — admin UIs, dashboards, management tools |
| `chain-no-auth@file` | Allow-listed addresses, no login prompt | Services with their own login (media servers, orchestration UIs, secret stores), machine-called APIs, health endpoints, and anything that must accept a request without a browser session |
| `chain-tunnel@file` | Private network only, after single sign-on | Routes that must never be reachable from the internet even on a host whose other routes are public |
| `chain-basic-auth@file` | Same as `chain-auth@file` | Currently identical to `chain-auth@file`; kept for routers that reference it |

Choosing `chain-no-auth@file` is a real decision, not a shortcut: it removes the login wall but keeps
the address allow list, the intrusion-detection bouncer, the security headers and the rate limit.
Whenever you put a route on `chain-no-auth@file`, add its domain to the single sign-on service's
access-control rules with `policy: bypass` as well — otherwise the entrypoint-level default and the
router-level chain disagree and you get redirect loops.

A minimal service router looks like this:

```bash
docker run -d --name <service> \
  --network proxy --ip <docker-ip> \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.<service>.entrypoints=https' \
  --label 'traefik.http.routers.<service>.rule=Host(`<service>.your-domain.com`)' \
  --label 'traefik.http.routers.<service>.tls=true' \
  --label 'traefik.http.routers.<service>.middlewares=chain-auth@file' \
  --label 'traefik.http.services.<service>.loadbalancer.server.port=<container-port>' \
  <image>
```

## Path layout

| Path | Contents | Reload behaviour |
| --- | --- | --- |
| `./data/traefik/traefik.yml` | Static configuration: entrypoints, providers, ACME resolver, logging, plugins | Read once at start — recreate the container to apply |
| `./data/traefik/rules/` | Dynamic configuration: middlewares, chains, file-defined routers and services | Watched; changes apply within seconds, no restart |
| `./data/traefik/acme.json` | ACME account key and every issued certificate | Written by Traefik; must stay `0600` |
| `./data/traefik/logs/traefik.log` | Proxy's own log at INFO | Rotated by size |
| `./data/traefik/logs/access.log` | One JSON object per request | Rotated by size; read by the intrusion-detection agent |

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–9 |
| `<username>` / `<pgid>` | Owner and group of the data directory | The deploy account and the `docker` group | Steps 1–8 |
| `<docker-ip>` | Traefik's fixed address on the shared network | Any address in `<docker-subnet>` outside the auto-allocation pool | Step 9 |
| `<docker-subnet>` | CIDR of the shared network | Whatever the network was created with | Steps 5, 9 |
| `<private-network-cidr>` | Your LAN range(s) | Every range that should reach services without going through the internet; list more than one if you have several | Step 5 |
| `<this-host-public-ip>` | The public host's own outside address | Only on the public host, and only because services there fetch their own public URLs | Step 5 |
| `<secret>` (bouncer key) | The API key CrowdSec issued for Traefik | Read it from CrowdSec, do not invent it | Step 5 |
| `<secret>` (Cloudflare token) | API token with `Zone:DNS:Edit` | Create it in the Cloudflare dashboard, scoped to the zones you serve | Step 9 |
| `you@your-domain.com` | ACME registration address | Where Let's Encrypt sends expiry warnings | Steps 4, 9 |
| `your-domain.com` | Base domain | The zone you hold a wildcard certificate for | Steps 4, 7, 9 |
| `proxy.your-domain.com` | Dashboard host name | Any name in the wildcard zone | Step 9 |
| `<country-code>` | Two-letter code to reject | Public host only; leave the list empty and drop `geoblock` from the chains if you block nothing | Step 7 |
| `hooks.your-domain.com` / `<hook-path>` | Public webhook host and secret path | Public host only; the path is the shared secret, so make it long and random | Step 7 |
| `<internal-service>.your-domain.com` | Where relayed webhooks go | The internal service's own name on its own proxy | Step 7 |

## Verification

```bash
# the process is serving
docker exec traefik traefik healthcheck --ping
docker inspect traefik | jq -r '.[0].State.Health.Status'

# the dynamic configuration loaded with no errors
docker logs traefik --tail 50 | grep -iE 'error|cannot|unable' || echo "no errors"

# every chain and middleware Traefik knows about
docker exec traefik wget -qO- http://localhost:8080/api/http/middlewares 2>/dev/null \
  | jq -r '.[].name' || curl -sk https://proxy.your-domain.com/api/http/middlewares | jq -r '.[].name'

# certificates actually issued, and by whom
curl -vI https://proxy.your-domain.com 2>&1 | grep -E 'subject:|issuer:|expire'

# the ACME store has content and correct permissions
ls -l ./data/traefik/acme.json
sudo jq -r '.cloudflare.Certificates[].domain.main' ./data/traefik/acme.json

# HTTP redirects to HTTPS
curl -sI http://proxy.your-domain.com | head -3

# the metrics entrypoint answers inside the network but is not published
docker run --rm --network proxy curlimages/curl -s http://traefik:8082/metrics | head -3
sudo ss -lntp | grep 8082 || echo "8082 correctly not published"

# requests are being logged
tail -2 ./data/traefik/logs/access.log | jq -r '.RequestHost, .DownstreamStatus'
```

On the public host, confirm the real client address is being restored — the access log's
`ClientHost` should be a visitor address, never a Cloudflare edge address:

```bash
tail -20 ./data/traefik/logs/access.log | jq -r '.ClientHost' | sort -u
```

## Updating & day-to-day

**Pull a new image.** Traefik's configuration lives entirely on disk, so recreating is safe.

```bash
cd <deploy-dir>
docker pull traefik:latest
docker stop traefik && docker rm traefik
# re-run the docker run command from Step 9, then:
docker network connect bridge traefik
docker exec traefik traefik healthcheck --ping
```

**Change a middleware or chain.** Edit the file in `./data/traefik/rules/` and save. Traefik
watches that directory and reloads within seconds. Watch the log while you do it — a malformed file
is ignored and the *previous* configuration stays live, which is safe but silent:

```bash
docker logs -f traefik | grep -i 'configuration'
```

**Change the static configuration.** Editing `./data/traefik/traefik.yml` does nothing until the
container is recreated. `docker restart` is not enough on hosts using `fuse-overlayfs`; stop and
start instead:

```bash
docker stop traefik && docker start traefik
```

**Certificate renewal** is automatic — Traefik renews 30 days before expiry over the same DNS
challenge. Check what it holds:

```bash
sudo jq -r '.cloudflare.Certificates[] | .domain.main' ./data/traefik/acme.json
```

**Rotate the Cloudflare token.** Create the new token, verify it, then recreate the container with
the new value. The old certificates in `acme.json` are unaffected.

**Where the logs are.** `./data/traefik/logs/traefik.log` (the proxy's own events, INFO),
`./data/traefik/logs/access.log` (one JSON object per request), `docker logs traefik` (start-up,
plugin compilation, ACME).

## Rollback / Uninstall

```bash
cd <deploy-dir>
docker stop traefik
docker rm traefik
```

Keep `acme.json` unless you are certain — it is the only copy of your certificates, and re-issuing
is rate-limited:

```bash
cp ./data/traefik/acme.json ~/acme.json.backup
```

Full removal:

```bash
sudo rm -f /etc/logrotate.d/traefik /etc/logrotate.d/traefik-access
rm -rf ./data/traefik
```

With Traefik gone, nothing on this host is reachable over 80/443 — every service depends on it for
TLS and routing. To reach a single service in the meantime, publish its port directly and reach it
over plain HTTP on the LAN.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container restarts immediately, log says the ACME storage permissions are too open | `acme.json` is not `0600`. `chmod 0600 ./data/traefik/acme.json` and start again. |
| `acme.json` is a directory | Docker created the missing bind-mount source. Stop the container, `rm -rf ./data/traefik/acme.json`, `touch` it, `chmod 0600`, recreate. |
| Everything returns 404 | The router rule does not match, or the container is not on the `proxy` network, or it lacks `traefik.enable=true`. `docker inspect <container> \| jq '.[0].Config.Labels'` and check the `Host()` rule against the name you typed. |
| Everything returns 500 on protected routes | The forward-auth target is down. `docker ps --filter 'name=^authelia$'` and `docker exec authelia wget -qO- http://localhost:9091/api/health`. |
| A route returns 500 and the log names a middleware | A chain references a middleware that was never defined — most often `geoblock` on a host where you skipped Step 7. Either define it or remove it from the chains. |
| 403 from the allow list for everyone on the public host | Cloudflare's edge ranges are missing from `default-whitelist`, or `cloudflarewarp` is not the first middleware in the chain, so the allow list is judging Cloudflare's address instead of the client's. |
| 403 for one address that should be allowed | An intrusion-detection ban. `docker exec crowdsec cscli decisions list --ip <ip-address>` and delete it with `docker exec crowdsec cscli decisions delete --ip <ip-address>`. Put addresses that must never be blocked in the bouncer's `clientTrustedIPs`. |
| No certificate; browser shows Traefik's default self-signed one | The DNS challenge failed. Check the token with the verify call from "Before you start", confirm it covers *this* zone, and read `docker logs traefik \| grep -i acme`. A wildcard needs `Zone:DNS:Edit`, not just read. |
| ACME errors mentioning rate limits | Let's Encrypt allows 5 duplicate certificates per identical name set per week. Stop recreating the container, and if you must keep testing, point `caServer` at `https://acme-staging-v02.api.letsencrypt.org/directory` until it works, then switch back and delete `acme.json` once. |
| Certificate never appears and the log shows propagation checks timing out | The challenge record is not visible to the public resolvers. If your zone is served by a provider with slow propagation, the resolvers listed under `dnsChallenge` are the ones being asked — confirm with `dig +short TXT _acme-challenge.your-domain.com @1.1.1.1`. |
| Dashboard prompts for login forever, or loops | The dashboard router is on `chain-auth@file` and the single sign-on service does not have the dashboard's domain in a `two_factor` rule, or its session cookie domain does not cover this host name. |
| New containers stop appearing, but Traefik reports healthy | The Docker socket bind went stale after a daemon restart. `docker stop traefik && docker start traefik`. Install the socket-rebind unit on this host so it repairs itself. |
| Plugins fail to load at start | The container cannot reach GitHub to fetch plugin sources. Check outbound connectivity from the container, then `docker stop traefik && docker start traefik`; the compiled plugins are cached in the container's filesystem, so a recreated container downloads them again. |
| Access log is empty but requests work | The log file was rotated with `create` instead of `copytruncate`, so Traefik is writing to an unlinked inode. Fix the rotation configuration per Step 8 and restart the container once. |
| Webhook relay returns 404 from the internal service | `passHostHeader: false` is missing, so the public host name is being forwarded and the internal proxy has no router for it. |
