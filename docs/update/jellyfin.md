# Jellyfin

## What this is

Jellyfin is the media server for this homelab: it indexes the movies, TV shows, music, home videos,
pictures and books that live on the storage host, fetches metadata and artwork for them, and streams
them to browsers, phones, tablets and TV apps — transcoding on the fly when a client cannot play the
original file.

It runs as a single container on the storage host (the machine with the media drives attached), on
the shared `proxy` bridge network with a fixed address, and is published by the reverse proxy at
`https://jellyfin.your-domain.com`. It keeps its own SQLite library database inside `./data/jellyfin/config`
— it does **not** use the central PostgreSQL server.

What it talks to:

- **The media drives**, mounted read-write into the container. Everything Jellyfin serves comes from
  bind mounts; nothing is copied into the container.
- **The single sign-on portal** at `https://auth.your-domain.com`, over OpenID Connect, through the
  SSO Authentication plugin. That is how a homelab account logs in to Jellyfin; the plugin maps the
  group claim from the portal onto Jellyfin administrator/user rights.
- **The TV, movie and music managers** on the same host. They do not push files to Jellyfin — they
  write into the same library folders and then call Jellyfin's API to say "rescan this folder", so a
  finished download shows up in the library within seconds instead of at the next scheduled scan.
  They authenticate with an API key you create in Step 8 below.

Unlike every other web service on this host, Jellyfin's route **bypasses** the single sign-on portal
at the proxy. TV apps, Chromecast and mobile clients speak Jellyfin's own auth protocol and cannot
complete a browser redirect to a login page, so a forward-auth middleware in front of Jellyfin would
lock out every non-browser client. Jellyfin authenticates its own users instead, and the SSO plugin
is what connects that to the homelab's identity provider.

## Before you start

**Docker is installed and your account can use it**

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

**The `./data` working directory exists**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in this guide is bind-mounted from here. Run all commands from `<deploy-dir>`
so the relative paths resolve.

**The shared `proxy` bridge network exists**

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows where
to send a request.

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

**The reverse proxy (Traefik) is running**

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

**The single sign-on portal (Authelia) is running**

Jellyfin's own route bypasses it, but the SSO plugin you install in Step 10 authenticates against
it, so it must be up and must already have an OpenID Connect client registered for Jellyfin.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy portal answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

Check that its discovery document is published and that it advertises the `groups` scope — the
plugin needs that claim to decide who is an administrator:

```bash
curl -s https://auth.your-domain.com/.well-known/openid-configuration | jq '.issuer, .scopes_supported'
```

You need the client identifier and client secret that the portal has registered for Jellyfin. The
portal stores the secret hashed, so it cannot be read back — if you do not have it, register a new
client there with redirect URI `https://jellyfin.your-domain.com/sso/OID/redirect/authelia` and keep
the generated secret.

**The service's DNS name resolves to this host**

```bash
dig +short jellyfin.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong machine
produces a 404 from the wrong proxy rather than an error you can read.

**The media drives are mounted**

```bash
findmnt -no TARGET,SOURCE,FSTYPE <movies-path> <tv-path> <music-path> <data-path>
ls -ld <tv-path>/Serije <data-path>/Slike <data-path>/Snimci <data-path>/Knjige
```

Every path must exist **before** the container starts. Docker creates a missing bind-mount source as
an empty root-owned directory, which does not fail loudly — you simply get an empty library and a
directory sitting on top of the mount point that later hides the real filesystem when it mounts.

**You know the numeric UID and GID that own the media**

```bash
stat -c '%u %g %n' <movies-path> <tv-path> <music-path>
```

Those two numbers are `<puid>` and `<pgid>` everywhere below. They must be the same numbers the
download client and the TV/movie/music managers run as, or Jellyfin will index files it cannot open.

## Setup

### Overview

1. Create the data directories.
2. Start the container.
3. Wait for it to answer its health endpoint.
4. Read the server's public info to see whether the setup wizard has already been run.
5. Set the startup configuration (name, language, metadata region).
6. Enable remote access.
7. Create the first administrator account.
8. Complete the setup wizard.
9. Create an API key for the other media services.
10. Install and configure the SSO Authentication plugin.

---

#### Step 1: Create the data directories

```bash
cd <deploy-dir>

mkdir -p ./data/jellyfin ./data/jellyfin/cache ./data/jellyfin/config
sudo chown <username>:<pgid> ./data/jellyfin ./data/jellyfin/cache
sudo chown <puid>:<pgid> ./data/jellyfin/config
sudo chmod 0755 ./data/jellyfin ./data/jellyfin/cache ./data/jellyfin/config
```

**Explanation**: the three directories are owned differently on purpose. `./data/jellyfin` and
`./data/jellyfin/cache` belong to your deploy account — the cache is throwaway transcode segments and
image thumbnails, and you want to be able to delete it by hand without `sudo`. `./data/jellyfin/config`
is chowned to the **numeric** UID/GID the container runs as, because Jellyfin writes its library
database, its user accounts and its plugin assemblies there as that user from the very first second
of the first start. Give it to your login account instead and the first start fails with permission
errors half-way through creating the database, leaving a corrupt `library.db` you then have to
delete. The numbers are used rather than a name because the container has its own `/etc/passwd` and
knows nothing about the names on the host — only UID and GID cross the boundary.

---

#### Step 2: Start the container

```bash
cd <deploy-dir>

docker run -d \
  --name jellyfin \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  -e PUID=<puid> \
  -e PGID=<pgid> \
  -e TZ=<timezone> \
  -e JELLYFIN_PublishedServerUrl=https://jellyfin.your-domain.com \
  -v "$(pwd)/data/jellyfin/config:/config" \
  -v "$(pwd)/data/jellyfin/cache:/cache" \
  -v "<data-path>/Knjige:/books" \
  -v "<music-path>:/music" \
  -v "<data-path>/Slike:/pictures" \
  -v "<data-path>/Snimci:/videos" \
  -v "<movies-path>:/movies" \
  -v "<tv-path>/Serije:/tv" \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.jellyfin.entrypoints=https' \
  --label 'traefik.http.routers.jellyfin.rule=Host(`jellyfin.your-domain.com`)' \
  --label 'traefik.http.routers.jellyfin.tls=true' \
  --label 'traefik.http.routers.jellyfin.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.jellyfin.loadbalancer.server.port=8096' \
  --health-cmd 'curl --fail http://localhost:8096/health || exit 1' \
  --health-interval 90s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  lscr.io/linuxserver/jellyfin:latest
```

**Explanation**: `PUID`/`PGID` are honoured by this image's init: it rewrites its internal service
account to those numbers and then drops to them before starting Jellyfin, so every file Jellyfin
creates in the library folders — `.nfo` sidecars, trickplay thumbnails, extracted subtitles — is
owned by the same user as the files the download client puts there. Get these wrong and Jellyfin
either cannot read the media at all or leaves behind files the managers cannot later rename.

`JELLYFIN_PublishedServerUrl` is the address Jellyfin hands out to clients that discover it on the
local network. Without it Jellyfin advertises its container address, which is meaningless outside the
bridge network, and Android/TV apps that auto-discover the server end up trying to stream from an
address they cannot route to. Setting it to the public name means discovery and manual entry both
land on the same URL that has a valid certificate.

The route carries `chain-no-auth@file`, not the authenticated chain. That chain still runs the
intrusion-prevention bouncer and the security headers, but it does not put the single sign-on portal
in front — Jellyfin authenticates its own clients (Step 10 wires that to the portal). Putting the
forward-auth chain here breaks every TV app, Chromecast and mobile client, because none of them can
follow a redirect to a browser login form.

The health check calls `/health`, which Jellyfin answers only once the library database is open and
the HTTP pipeline is serving. The 30-second start period exists because a first start migrates the
database schema and can take that long before the endpoint responds at all.

The media mounts are read-write. Jellyfin needs write access to store trickplay images, extracted
subtitles and metadata next to the media; mount them read-only and those features fail silently.

---

#### Step 3: Wait for it to answer its health endpoint

```bash
for i in $(seq 1 10); do
  curl -sf -o /dev/null https://jellyfin.your-domain.com/health && { echo "jellyfin: ready"; break; }
  echo "waiting for jellyfin..."; sleep 10
done

docker inspect --format '{{.State.Health.Status}}' jellyfin
```

**Explanation**: every step after this one is an HTTP call, so there is no point starting until the
server answers. Ten attempts ten seconds apart covers a cold first start, which has to create the
database and unpack the bundled web client. The container's own health status should read `healthy`
— if it says `starting` forever, read `docker logs jellyfin` before going on.

---

#### Step 4: Check whether the setup wizard has already run

```bash
curl -s https://jellyfin.your-domain.com/System/Info/Public | jq '{Version, StartupWizardCompleted}'
```

**Explanation**: `/System/Info/Public` is the only endpoint Jellyfin answers before anyone has logged
in, and `StartupWizardCompleted` is the flag that decides whether Steps 5 to 8 apply. If it is
already `true` — you are re-running this on an existing install — **skip to Step 9**. The wizard
endpoints stop accepting input once the wizard is complete, so running them again returns errors, and
attempting to recreate the administrator account would fail rather than reset a password.

---

#### Step 5: Set the startup configuration

```bash
curl -sf -X POST https://jellyfin.your-domain.com/Startup/Configuration \
  -H 'Content-Type: application/json' \
  -d '{
    "ServerName": "Jellyfin",
    "UICulture": "en-US",
    "MetadataCountryCode": "US",
    "PreferredMetadataLanguage": "en"
  }'
```

**Explanation**: this is the first page of the setup wizard, submitted over the API instead of in a
browser so the whole install is reproducible. `PreferredMetadataLanguage` and `MetadataCountryCode`
decide which language titles, descriptions and release dates are pulled from the metadata providers,
and they are set here rather than later because they become the defaults for every library you add
afterwards — changing them once libraries exist means re-fetching all metadata. The call returns
`204 No Content` on success.

---

#### Step 6: Enable remote access

```bash
curl -sf -X POST https://jellyfin.your-domain.com/Startup/RemoteAccess \
  -H 'Content-Type: application/json' \
  -d '{
    "EnableRemoteAccess": true,
    "EnableAutomaticPortMapping": false
  }'
```

**Explanation**: remote access must be on, because from Jellyfin's point of view every request
arrives from the reverse proxy's address on the bridge network, not from its own subnet — with
remote access disabled Jellyfin would refuse connections from outside what it considers local, which
is everything. Automatic port mapping is deliberately off: it is UPnP, it would ask the router to
open port 8096 straight to the container, and it would bypass TLS termination, the security headers
and the intrusion-prevention bouncer entirely. The only way in is through the reverse proxy on 443.

---

#### Step 7: Create the first administrator account

```bash
# the wizard pre-creates a placeholder user; wait for it to appear
for i in $(seq 1 12); do
  curl -s https://jellyfin.your-domain.com/Startup/User | jq -e '.Name != null' >/dev/null \
    && { echo "startup user: ready"; break; }
  sleep 5
done

curl -sf -X POST https://jellyfin.your-domain.com/Startup/User \
  -H 'Content-Type: application/json' \
  -d '{
    "Name": "<admin-user>",
    "Password": "<secret>"
  }'
```

**Explanation**: Jellyfin creates an empty user record as part of initialising the database, and the
wizard's user endpoint *renames and sets a password on that record* rather than inserting a new one.
Posting before the record exists returns an error that looks like a permission problem, which is why
the loop polls `GET /Startup/User` until it reports a name. This account is the local break-glass
administrator: once single sign-on is wired up in Step 10 you will normally log in through the portal,
but if the portal is down this is the only account that can still reach the server, so give it a real
password and keep it.

---

#### Step 8: Complete the setup wizard

```bash
curl -sf -X POST https://jellyfin.your-domain.com/Startup/Complete
```

**Explanation**: this flips `StartupWizardCompleted` to `true` and takes the server out of setup
mode. Until it is called, Jellyfin keeps every wizard endpoint open to unauthenticated callers — the
whole point of the flag is that anyone who can reach the server before it is set can claim the
administrator account. Call it immediately after Step 7, not later.

---

#### Step 9: Create an API key for the other media services

```bash
# authenticate as the administrator and capture the session token
TOKEN=$(curl -sf -X POST https://jellyfin.your-domain.com/Users/AuthenticateByName \
  -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' \
  -H 'Content-Type: application/json' \
  -d '{"Username":"<admin-user>","Pw":"<secret>"}' | jq -r .AccessToken)

# list existing keys — do not create a second one for the same app
curl -s https://jellyfin.your-domain.com/Auth/Keys -H "X-Emby-Token: $TOKEN" \
  | jq -r '.Items[] | "\(.AppName)\t\(.AccessToken)"'

# create one named "automation" if the list above does not already contain it
curl -sf -X POST "https://jellyfin.your-domain.com/Auth/Keys?app=automation" \
  -H "X-Emby-Token: $TOKEN"

# read it back — this value is what the other services use
curl -s https://jellyfin.your-domain.com/Auth/Keys -H "X-Emby-Token: $TOKEN" \
  | jq -r '.Items[] | select(.AppName=="automation") | .AccessToken'
```

**Explanation**: the authentication call needs the `X-Emby-Authorization` header even though the
credentials are in the body — Jellyfin refuses to issue a token to a client that does not identify
itself, and the four fields in that header (client, device, device id, version) are what shows up in
the server's active-devices list. The token it returns is a **session** token: it expires and it is
tied to that device entry, so it is fine for the next two calls and useless as a permanent
credential.

`POST /Auth/Keys` therefore creates a proper **API key**, which does not expire and is not tied to a
session. That is the value the TV, movie and music managers put in their Jellyfin connection so they
can trigger a library rescan the moment a download finishes. Note that the create call returns `204`
with an empty body — the key itself is only obtainable by listing the keys again afterwards, which is
why the read-back is a separate command. Copy it now; you will need it in the next section and when
configuring the other services.

Check for an existing key before creating one. Nothing stops Jellyfin from holding a dozen keys with
the same app name, and then you cannot tell which of them the other services are actually using.

---

#### Step 10: Install and configure the SSO Authentication plugin

First write the plugin's configuration, before the plugin exists:

```bash
cd <deploy-dir>
sudo mkdir -p ./data/jellyfin/config/plugins/configurations
sudo chown <puid>:<pgid> ./data/jellyfin/config/plugins/configurations
sudo chmod 0755 ./data/jellyfin/config/plugins/configurations

sudo tee ./data/jellyfin/config/plugins/configurations/SSO-Auth.xml >/dev/null <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SamlConfigs />
  <OidConfigs>
    <item>
      <key>
        <string>authelia</string>
      </key>
      <value>
        <PluginConfiguration>
          <OidEndpoint>https://auth.your-domain.com</OidEndpoint>
          <OidClientId>REPLACE_WITH_OIDC_CLIENT_ID</OidClientId>
          <OidSecret>REPLACE_WITH_OIDC_CLIENT_SECRET</OidSecret>
          <Enabled>true</Enabled>
          <EnableAuthorization>true</EnableAuthorization>
          <EnableAllFolders>true</EnableAllFolders>
          <AdminRoles>
            <string>admins</string>
          </AdminRoles>
          <Roles>
            <string>admins</string>
            <string>dev</string>
          </Roles>
          <RoleClaim>groups</RoleClaim>
          <OidScopes>
            <string>groups</string>
          </OidScopes>
          <DisableHttps>false</DisableHttps>
          <DoNotValidateEndpoints>false</DoNotValidateEndpoints>
          <DoNotValidateIssuerName>false</DoNotValidateIssuerName>
        </PluginConfiguration>
      </value>
    </item>
  </OidConfigs>
</PluginConfiguration>
EOF

# put the real values in place of the two REPLACE_WITH_ markers
sudo sed -i "s|REPLACE_WITH_OIDC_CLIENT_ID|<oidc-client-id>|; s|REPLACE_WITH_OIDC_CLIENT_SECRET|<secret>|" \
  ./data/jellyfin/config/plugins/configurations/SSO-Auth.xml

sudo chown <puid>:<pgid> ./data/jellyfin/config/plugins/configurations/SSO-Auth.xml
sudo chmod 0644 ./data/jellyfin/config/plugins/configurations/SSO-Auth.xml
```

Then install the plugin and restart:

```bash
KEY='<secret>'   # the API key from Step 9

# is it already installed?
curl -s https://jellyfin.your-domain.com/Plugins -H "X-Emby-Token: $KEY" \
  | jq -r '.[] | .Name'

# find the package in the catalogue and note its GUID and newest version
curl -s https://jellyfin.your-domain.com/Packages -H "X-Emby-Token: $KEY" \
  | jq -r '.[] | select(.name=="SSO Authentication" or .name=="SSO-Auth")
           | {name, guid, version: .versions[0].versionNumber}'

# install it, using the name, GUID and version from the previous command
curl -sf -X POST \
  "https://jellyfin.your-domain.com/Packages/Installed/SSO%20Authentication?assemblyGuid=<plugin-guid>&version=<plugin-version>" \
  -H "X-Emby-Token: $KEY"

docker restart jellyfin

for i in $(seq 1 10); do
  curl -sf -o /dev/null https://jellyfin.your-domain.com/health && { echo "jellyfin: ready"; break; }
  sleep 10
done
```

**Explanation**: the configuration file is written **before** the plugin is installed because
Jellyfin loads plugin configuration at assembly load time. Install first and the plugin writes a
default, empty configuration file on its first load; your file then either loses the race or gets
overwritten, and you end up entering the client secret by hand in the web UI. Writing the file first
means the plugin finds a complete configuration the moment it loads and single sign-on works on the
first restart.

The file must be owned by the container's numeric UID: the plugin rewrites it whenever anyone touches
its settings page, and a root-owned file makes the settings page fail to save with no visible error.

`RoleClaim` is `groups` and `groups` is also requested as a scope. The portal only puts the group
list in the token when that scope is asked for, so omitting the scope produces a login that succeeds
and then grants nobody anything — every user lands with no libraries and no admin rights.
`AdminRoles` promotes members of the admin group to Jellyfin administrators; `Roles` is the allow-list
of groups permitted to log in at all, so a portal account that is in neither group is rejected by
Jellyfin even though the portal itself authenticated it. `EnableAllFolders` gives SSO-provisioned
users access to every library — turn it off and each new user starts with an empty home screen until
an administrator grants folders by hand.

`DisableHttps`, `DoNotValidateEndpoints` and `DoNotValidateIssuerName` are all left at the safe
setting. They exist to work around self-signed or mismatched issuer setups; enabling any of them lets
the plugin accept tokens it has not properly verified.

The install call takes the package name in the URL path and the assembly GUID plus version as query
parameters — the catalogue lookup in the previous command is what gives you those two values, and
they change with every plugin release, so do not hard-code them. It answers `204` and stages the
plugin on disk.

The restart is not optional. Jellyfin loads plugin assemblies only at process start; until the
container restarts, the plugin is on disk and completely inert, and the login page shows no SSO
button.

## Library layout

Jellyfin sees these paths inside the container. Add each one as a library from
**Dashboard → Libraries → Add Media Library**, choosing the matching content type:

| Container path | Host path | Library type |
| --- | --- | --- |
| `/movies` | `<movies-path>` | Movies |
| `/tv` | `<tv-path>/Serije` | Shows |
| `/music` | `<music-path>` | Music |
| `/books` | `<data-path>/Knjige` | Books |
| `/pictures` | `<data-path>/Slike` | Photos |
| `/videos` | `<data-path>/Snimci` | Home videos and photos |
| `/config` | `./data/jellyfin/config` | Library database, users, plugins, logs — not a library |
| `/cache` | `./data/jellyfin/cache` | Transcode segments and image cache — safe to delete when stopped |

Always add libraries by the **container** path (`/movies`), never the host path. Jellyfin stores the
path it was given in the database, and a host path it cannot see produces a library that scans zero
items and cannot be fixed except by removing and re-adding it.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory; all relative paths hang off it | Steps 1, 2, 10 |
| `<username>` | Owner of the deploy directories | The account you administer this host with | Step 1 |
| `<puid>` / `<pgid>` | Numeric UID and GID the container runs as | Must equal the owner of the media directories — `stat -c '%u %g' <movies-path>` — and must match the download client and the media managers | Steps 1, 2, 10 |
| `<docker-ip>` | Fixed address on the shared bridge network | An address inside the bridge subnet but outside the auto-allocation pool | Step 2 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Bridge network addressing | Any private range that does not collide with your LAN | Before you start |
| `<timezone>` | IANA timezone name | The host's, so scheduled tasks and "added on" timestamps read correctly | Step 2 |
| `<movies-path>` / `<tv-path>` / `<music-path>` / `<data-path>` | Mount points of the media drives on the host | Where the drives are actually mounted; check with `findmnt` | Before you start, Step 2 |
| `<admin-user>` | Local Jellyfin administrator's username | Anything; it is the break-glass account used when the portal is down | Steps 7, 9 |
| `<secret>` (admin password) | Password for that account | Generate one: `openssl rand -base64 24` | Steps 7, 9 |
| `<secret>` (API key) | Permanent key for the other media services | Produced by Jellyfin in Step 9; you do not choose it | Steps 9, 10, Verification |
| `<oidc-client-id>` | Identifier the single sign-on portal registered for Jellyfin | Whatever you registered there; conventionally `jellyfin` | Step 10 |
| `<secret>` (OIDC client secret) | Shared secret for that client | Generated when the client was registered with the portal; it cannot be read back afterwards | Step 10 |
| `<plugin-guid>` / `<plugin-version>` | Assembly identity of the SSO plugin release | Read from the catalogue in Step 10; they change every release | Step 10 |

## Verification

```bash
# container is up and healthy
docker ps --filter 'name=^jellyfin$'
docker inspect --format '{{.State.Health.Status}}' jellyfin

# it is serving, and the wizard is finished
curl -s https://jellyfin.your-domain.com/System/Info/Public | jq '{ServerName, Version, StartupWizardCompleted}'

# the API key works
curl -s https://jellyfin.your-domain.com/System/Info -H 'X-Emby-Token: <secret>' | jq '{ServerName, Version, OperatingSystem}'

# the SSO plugin is loaded (not merely on disk)
curl -s https://jellyfin.your-domain.com/Plugins -H 'X-Emby-Token: <secret>' \
  | jq -r '.[] | "\(.Name)\t\(.Version)\t\(.Status)"'

# libraries exist and have items in them
curl -s https://jellyfin.your-domain.com/Library/VirtualFolders -H 'X-Emby-Token: <secret>' \
  | jq -r '.[] | "\(.Name)\t\(.CollectionType)\t\(.Locations | join(","))"'

# media is actually readable by the container's user
docker exec jellyfin ls -l /movies /tv /music | head -20

# the login page offers the single sign-on button
curl -s https://jellyfin.your-domain.com/sso/OID/start/authelia -o /dev/null -w '%{http_code}\n'
```

The plugin's `Status` must read `Active`. `Restart` means it is staged but the process has not
reloaded it — restart the container. The SSO start URL should answer `302` (a redirect to the
portal); a `404` means the plugin is not loaded, and a `500` means its configuration file is missing
or malformed.

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull lscr.io/linuxserver/jellyfin:latest
docker rm -f jellyfin
# re-run the docker run command from Step 2 verbatim
```

Configuration, users, the library database and installed plugins all live in
`./data/jellyfin/config`, so recreating the container loses nothing. Back that directory up before a
major version jump — Jellyfin migrates the database schema on first start and there is no downgrade
path.

**Logs:**

```bash
docker logs -f --tail 100 jellyfin
ls -lt ./data/jellyfin/config/log/
tail -f ./data/jellyfin/config/log/log_*.log
```

`docker logs` shows the image's init and startup; the files under `config/log/` are Jellyfin's own
rolling logs and are where playback, transcode and metadata errors actually appear.

**Clear the transcode/image cache** (safe, it is rebuilt on demand):

```bash
docker stop jellyfin
sudo rm -rf ./data/jellyfin/cache/*
docker start jellyfin
```

**Trigger a library scan by hand:**

```bash
curl -sf -X POST https://jellyfin.your-domain.com/Library/Refresh -H 'X-Emby-Token: <secret>'
```

**Routine chores:** check `Dashboard → Scheduled Tasks` occasionally — the metadata refresh and the
trickplay image generation are the two that consume real CPU, and on a low-power host they should be
scheduled outside viewing hours. Watch the size of `./data/jellyfin/config/metadata` and
`./data/jellyfin/cache`; both grow steadily with library size.

## Rollback / Uninstall

```bash
cd <deploy-dir>

docker rm -f jellyfin

# configuration, users, library database, plugins
sudo rm -rf ./data/jellyfin

docker image rm lscr.io/linuxserver/jellyfin:latest
```

Media files are untouched — everything under `<movies-path>`, `<tv-path>`, `<music-path>` and
`<data-path>` is bind-mounted and stays exactly as it was. Only Jellyfin's own state is removed.

If you also want the other media services to stop calling Jellyfin, remove their Jellyfin connection
in each of their settings, and revoke the API key first if you are keeping the server:

```bash
curl -sf -X DELETE 'https://jellyfin.your-domain.com/Auth/Keys/<secret>' -H 'X-Emby-Token: <secret>'
```

Finally, remove the OpenID Connect client registration for Jellyfin from the single sign-on portal so
a dangling client identifier does not sit there indefinitely.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Every library scans zero items | The bind-mount source did not exist when the container started, so Docker created an empty directory. Stop the container, `ls -ld` the host path, remove the empty directory if it is not the real mount point, remount the drive, and start again. |
| Libraries were added by the host path and find nothing | Jellyfin stores the path it was given and only sees container paths. Remove the library and re-add it as `/movies`, `/tv`, `/music`. |
| `Access to the path is denied` in the logs | `PUID`/`PGID` do not match the owner of the media. `stat -c '%u %g' <movies-path>` and `docker exec jellyfin id` must agree. |
| First start fails and `library.db` is corrupt | `./data/jellyfin/config` was not owned by `<puid>:<pgid>` before the first start. Stop the container, delete the directory, recreate it with the right ownership, and start again. |
| TV app or Chromecast cannot connect but the browser works | The route was given the authenticated middleware chain instead of `chain-no-auth@file`. Non-browser clients cannot follow the login redirect. Recreate the container with the label from Step 2. |
| Apps discover the server but cannot stream | `JELLYFIN_PublishedServerUrl` is unset, so clients are being handed the container's bridge address. Set it to the public URL and recreate. |
| No SSO button on the login page | The plugin is staged but not loaded — `docker restart jellyfin`. If it is still missing, `curl .../Plugins` and check `Status`. |
| SSO login succeeds but the user sees nothing and is not an admin | The `groups` scope is not being returned by the portal, so `RoleClaim` matches nothing. Confirm `scopes_supported` on the discovery document and that the Jellyfin client registration requests `groups`. |
| SSO login is rejected with "user is not in a permitted role" | The account's group is not listed in `Roles` in `SSO-Auth.xml`. Add it and restart the container. |
| Plugin settings page will not save | `SSO-Auth.xml` is not writable by the container user. `sudo chown <puid>:<pgid>` it. |
| The other media services report "unable to update Jellyfin library" | The API key was revoked or a second key with the same app name is in use. List the keys, pick one, and update the connection in each service. |
| Transcoding is constant and the host is pinned | Clients are being handed a format they cannot direct-play. Check `Dashboard → Playback` for hardware acceleration and confirm the client's supported codecs; on a host with no GPU passthrough, transcoding 4K is not viable and the library should hold client-compatible formats. |
| Disk fills up unexpectedly | `./data/jellyfin/cache` and `config/metadata` grow without limit. Stop the container and clear the cache; reduce artwork and trickplay settings for large libraries. |
| Health check flaps between `healthy` and `unhealthy` | A scheduled task (usually a full metadata refresh) is starving the host. Reschedule it and consider raising the health check interval. |
