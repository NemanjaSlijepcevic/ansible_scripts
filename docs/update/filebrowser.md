# Filebrowser

## What this is

Filebrowser is a web file manager — browse, upload, download, rename and delete files on the drives
you mount into it, from a browser, with no desktop client and no SMB/NFS mount needed on the visiting
machine.

It runs as a single container on the storage host, on the shared `proxy` bridge network with a fixed
address, and is published by the reverse proxy at `https://files.your-domain.com`. It has no database
server behind it — its own state (users, settings) lives in a small SQLite file it manages itself.

The one thing worth understanding before you start: Filebrowser never shows its own login form. It
runs in **proxy authentication mode**, which means it trusts a `Remote-User` header on every request
instead of checking a username and password itself. That header is set by the single sign-on portal,
applied through the `chain-auth@file` middleware on this service's route — Authelia authenticates the
person first, and only then does Traefik forward the request to Filebrowser with their username
already stamped on it. The account seeded inside Filebrowser at startup exists only so that username
has somewhere to attach permissions to; its password is a throwaway value that is never checked,
because proxy mode never asks for one. Anyone who reaches this container directly, bypassing the
proxy, walks in with whatever username they claim in that header — which is exactly why this
container's port must never be published on the host.

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

Every service keeps its configuration and state in `./data/<service>` under this directory, and every
container path in this guide is bind-mounted from here. Run all commands from `<deploy-dir>` so the
relative paths resolve.

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

**Authelia (single sign-on) is running and sets `Remote-User`**

This is not optional the way it is for most other services in this stack — Filebrowser has no login
form of its own to fall back on, so if the portal is down or the header is missing, every request
either fails outright or, worse, is treated as anonymous.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy portal answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

**The service's DNS name resolves to this host**

```bash
dig +short files.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong machine
produces a 404 from the wrong proxy rather than an error you can read.

**You know which drives to expose, and their UID/GID**

```bash
findmnt -no TARGET,SOURCE,FSTYPE <media-path>
stat -c '%u %g %n' <media-path>
```

The number from `stat` is `<puid>`/`<pgid>` for the rest of this guide — the container runs as this
user (not root), and every path you mount in read-write must already be owned by it, or every create
and upload in that folder answers `403 Forbidden`. Unlike the media managers, there is no init step
here that fixes ownership for you at container start; Filebrowser's image runs the application
directly as the user you pass in, so whatever owns the directory on the host is what decides whether
this container can write to it.

## Setup

### Overview

1. Create the configuration directory and the state database.
2. Create and own any locally-hosted drive to expose.
3. Start the container.
4. Confirm the seeded account and give it the permissions you want.

---

#### Step 1: Create the configuration directory and the database file

```bash
cd <deploy-dir>
mkdir -p ./data/filebrowser ./data/filebrowser/config
sudo chown <puid>:<pgid> ./data/filebrowser ./data/filebrowser/config
sudo chmod 0755 ./data/filebrowser ./data/filebrowser/config

touch ./data/filebrowser/database.db
sudo chown <puid>:<pgid> ./data/filebrowser/database.db
sudo chmod 0640 ./data/filebrowser/database.db
```

**Explanation**: the database file is created empty and owned by the container's user *before* the
container ever starts, because the container's own entrypoint runs `filebrowser config init` against
this exact path on every start — if the file does not exist yet with the right owner, the container
creates it as itself, but if it exists and is owned by someone else instead, initialisation fails
with a permission error before the web server ever comes up. `0640` is deliberately narrow: this file
holds password hashes for any account that keeps a local password, even though the seeded admin
account's own password is never actually checked in proxy mode.

---

#### Step 2: Create and own any locally-hosted drive to expose

Skip this step entirely for drives that are already mounted from elsewhere on the host (a network
share, another disk) — only create directories here for storage that lives directly under this
service's own `./data` tree.

```bash
mkdir -p ./data/filebrowser/<drive-name>
sudo chown <puid>:<pgid> ./data/filebrowser/<drive-name>
sudo chmod 0755 ./data/filebrowser/<drive-name>
```

**Explanation**: this is the ownership rule from "Before you start" applied concretely. The container
runs as `<puid>:<pgid>`, never as root, and Filebrowser's own internal `/srv` — what you get if you
mount nothing at all under it — is owned by root inside the image; without at least one directory
mounted in and chowned to the container's user, every create and upload anywhere in the interface
answers `403 Forbidden`, and it is easy to mistake that for a bug rather than a missing chown. Drives
that already exist elsewhere on the host (an existing NAS share, another disk) need this same
ownership already applied on the host side, but this repository does not create or touch those paths
for you — only the ones under this service's own directory tree.

---

#### Step 3: Start the container

The entrypoint below does four things in order, every time the container starts: initialise the
database if it does not already have a config in it, set proxy authentication mode, seed an admin
account if one with that username does not already exist, then serve `/srv`.

```bash
cd <deploy-dir>

docker run -d \
  --name filebrowser \
  --restart unless-stopped \
  --network proxy --ip <docker-ip> \
  --user "<puid>:<pgid>" \
  -v "$(pwd)/data/filebrowser/config:/config" \
  -v "$(pwd)/data/filebrowser/database.db:/database/filebrowser.db" \
  -v "$(pwd)/data/filebrowser/<drive-name>:/srv/<drive-name>" \
  -v "<media-path>:/srv/<mount-name>:ro" \
  --entrypoint /bin/sh \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.filebrowser.entrypoints=https' \
  --label 'traefik.http.routers.filebrowser.rule=Host(`files.your-domain.com`)' \
  --label 'traefik.http.routers.filebrowser.tls=true' \
  --label 'traefik.http.routers.filebrowser.middlewares=chain-auth@file' \
  --label 'traefik.http.services.filebrowser.loadbalancer.server.port=80' \
  --health-cmd 'wget --quiet --spider http://localhost:80/health || exit 1' \
  --health-interval 90s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  filebrowser/filebrowser:latest \
  -c 'filebrowser config init -d /database/filebrowser.db 2>/dev/null || true && \
      filebrowser config set -d /database/filebrowser.db --auth.method=proxy --auth.header=Remote-User --address 0.0.0.0 && \
      filebrowser users add <admin-user> placeholder --perm.admin -d /database/filebrowser.db 2>/dev/null || true && \
      filebrowser -r /srv -d /database/filebrowser.db -p 80'
```

**Explanation**: `--user "<puid>:<pgid>"` is what actually drops the container's privileges — this
image has no `PUID`/`PGID` environment-variable init the way the `linuxserver.io` images do, so the
user has to be set at the Docker level instead. Every volume you mount in read-write must already be
owned by that same pair, which is why Steps 1 and 2 chown everything before this step ever runs.

`--auth.method=proxy --auth.header=Remote-User` is the setting that removes Filebrowser's own login
form entirely and makes it trust the header instead — this only belongs on a route that is guaranteed
to sit behind `chain-auth@file`, because without the proxy in front of it, anyone who can reach the
container directly can set that header themselves and become any user they like. This is also why the
container's port (80 here) must never be published to the host: on the shared bridge, only the proxy
can reach it, and the proxy always attaches a header Authelia has already verified.

`filebrowser users add <admin-user> placeholder --perm.admin` creates the account the header maps
onto; `placeholder` is never actually usable as a password because proxy mode never presents a
password prompt to check it against. `2>/dev/null || true` is there because this command fails loudly
if the user already exists — the entrypoint runs this same line on every container restart, and this
turns "user already exists" from a startup failure into a no-op. `<admin-user>` must exactly match the
username Authelia sends in `Remote-User` for the person you want to land as an administrator; every
other username that shows up in that header and has no matching account is created by Filebrowser on
first login with whatever the application's default permissions are, so anyone who authenticates
through the portal for the first time gets an account automatically, not necessarily one with the
access you intended.

`-r /srv -p 80` sets the served root and the port; every `-v ...:/srv/<name>` mount becomes a
subdirectory under it, and each is what shows up as a top-level folder in the interface. Mount drives
you never want edited as `:ro` — Filebrowser has no distinction between "this account can read this
folder" and "this account can read this folder", so a read-only bind mount is the only hard guarantee
against an accidental delete.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–3 |
| `<username>` | Owner of the deploy directories | The account you administer this host with | Before you start |
| `<puid>` / `<pgid>` | Numeric UID and GID the container runs as | Must equal the owner of every read-write mounted drive | Steps 1–3, Before you start |
| `<docker-ip>` | Fixed address on the shared bridge network | Inside the bridge subnet, outside the auto-allocation pool | Step 3 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Bridge network addressing | Any private range that does not collide with your LAN | Before you start |
| `<media-path>` | Host path of an externally-mounted drive to expose | Where that drive is actually mounted; check with `findmnt` | Step 3 |
| `<drive-name>` / `<mount-name>` | Subfolder names under `/srv` | Whatever you want the top-level folder in the interface to be called | Steps 2, 3 |
| `<admin-user>` | The username seeded as administrator | Must exactly match the username Authelia sends in the `Remote-User` header for that person | Step 3 |

## Verification

```bash
docker ps --filter 'name=^filebrowser$'
docker inspect --format '{{.State.Health.Status}}' filebrowser
docker logs filebrowser --tail 20
```

Confirm the route is behind single sign-on, not answering directly:

```bash
curl -sI https://files.your-domain.com | head -1   # expect a redirect to the portal, not a 200
```

Confirm the seeded account exists inside the database:

```bash
docker exec filebrowser filebrowser users ls -d /database/filebrowser.db
```

Confirm the container can actually write into every read-write mounted drive — the check that catches
the 403-on-upload problem before a user does:

```bash
docker exec filebrowser sh -c 'touch /srv/<drive-name>/.write-test && rm /srv/<drive-name>/.write-test' \
  && echo "<drive-name>: writable" || echo "<drive-name>: NOT writable — check ownership"
```

Once logged in through the portal, the interface should show your own username in its account menu
with no login prompt in between — that is the proxy-auth header working end to end.

## Updating & day-to-day

**Pull a new image and recreate:**

```bash
cd <deploy-dir>
docker pull filebrowser/filebrowser:latest
docker rm -f filebrowser
# re-run the docker run command from Step 3 verbatim
```

All state — accounts, settings, share links — is in `./data/filebrowser/database.db`, so nothing is
lost by recreating the container.

**Logs:**

```bash
docker logs -f --tail 100 filebrowser
```

Filebrowser does not keep a separate file log; everything of interest is on stdout, which is what
`docker logs` shows.

**Routine chores:**

```bash
# list every account and its role
docker exec filebrowser filebrowser users ls -d /database/filebrowser.db

# remove an account that should no longer have access
docker exec filebrowser filebrowser users rm <username> -d /database/filebrowser.db

# add a new drive later: stop, add a -v mount, start again
docker stop filebrowser
# edit the docker run command to add another -v host-path:/srv/<name> line
docker rm filebrowser
# re-run the edited command
```

Because every account besides the seeded one is created automatically on first login through the
header, "routine chores" here is mostly pruning accounts for people who no longer need access — there
is no separate deprovisioning step in the portal that removes them from Filebrowser.

## Rollback / Uninstall

```bash
cd <deploy-dir>

docker rm -f filebrowser
sudo rm -rf ./data/filebrowser
docker image rm filebrowser/filebrowser:latest
```

Any drives mounted in from elsewhere on the host are untouched — they are bind mounts, and nothing in
this uninstall reads or writes their contents, only Filebrowser's own configuration and account
database.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Redirected to the portal in an endless loop | `chain-auth@file` is not actually applied to the route, or Authelia is not setting `Remote-User`. Confirm the label on the container and that Authelia answers `{"status":"OK"}`. |
| The interface shows its own username/password form | `--auth.method=proxy` was not applied — check `docker exec filebrowser filebrowser config get -d /database/filebrowser.db`. If it does not say `proxy`, the entrypoint's `config set` step failed; check `docker logs filebrowser` from the last start. |
| `403 Forbidden` creating or uploading into a folder | That folder's host directory is not owned by `<puid>:<pgid>`. `docker exec filebrowser id` and `stat -c '%u %g' <path>`, then chown the host directory to match. |
| A folder is visible but every write fails | It was mounted with `:ro`. Remove the flag and recreate the container if you actually want it writable. |
| Container fails to start with a database error | `./data/filebrowser/database.db` does not exist yet or is owned by the wrong user. `ls -l ./data/filebrowser/database.db`, fix ownership, recreate. |
| A person logs in and lands with no permissions, or the wrong ones | Their username was auto-created by Filebrowser on first login rather than seeded in Step 3 with the permissions you intended. Adjust it directly: `docker exec filebrowser filebrowser users update <username> --perm.admin -d /database/filebrowser.db`. |
| A drive you added is missing from the interface | The container needs a restart to pick up a new `-v` mount — editing the running container's volumes is not possible in Docker; stop, edit the command, remove, and start again. |
