# OpenBao

## What this is

OpenBao is the central secrets store for this homelab — an open-source, community-governed fork of
HashiCorp Vault. One container, named `openbao`, runs on a dedicated machine alongside the same
baseline stack every other host carries (reverse proxy, single sign-on, intrusion detection, a
metrics/log agent). Its job is to be the one place credentials, API keys and tokens live, so that
other machines and automated jobs can fetch a secret at the moment they need it instead of holding a
permanent copy of it in a file.

Storage is OpenBao's **integrated Raft** backend — a self-contained, replicated log written straight
to disk under `./data/openbao/data`, with no external database behind it. That is also what makes a
consistent live backup possible: `bao operator raft snapshot save` takes a point-in-time copy without
stopping the server. Every request against the vault is additionally written to a file audit log
(`./data/openbao/audit/audit.log`), because a store whose entire purpose is holding secrets is also
the one place you most want a record of who asked for what.

The container sits on the shared `proxy` bridge network at a fixed address and is reachable from the
internet at `https://openbao.your-domain.com` through the reverse proxy — but, unlike most services
behind that proxy, it is **not** put behind the single sign-on portal's login page. OpenBao does its
own strong authentication (tokens, a human login method, machine credentials), and API/CLI clients
have no way to complete an SSO browser redirect, so its router uses the reverse proxy's no-auth
middleware chain instead — the same pattern used for any service that authenticates itself. The
container also publishes port `8200` bound to `127.0.0.1` only, so that operator commands run
directly on this host (unsealing, the very first login) never have to leave it, while everyone else
reaches the vault only through the TLS-terminating reverse proxy.

This guide covers deploying and unsealing the vault itself. Turning the empty vault into something
useful — enabling its key-value store, writing access policies, creating a human account and issuing
machine credentials — is a separate, later procedure against the same running container.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
docker compose version 2>/dev/null || true

id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

**The `./data` working directory exists and you are in it**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every path below is relative to `<deploy-dir>`.

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

Note the fixed address of the reverse proxy's own container on this network — you need it below to
tell OpenBao whose forwarded-for header to trust:

```bash
docker network inspect proxy | jq -r '.[0].Containers'
```

**The reverse proxy is already running, with its no-auth chain available**

```bash
docker ps --filter 'name=^traefik$'
test -f ./data/traefik/rules/chain-no-auth.yml && echo "no-auth chain: ok" || echo "no-auth chain: MISSING"
```

If the second check fails, the reverse proxy has not been deployed with that piece yet — OpenBao's
own router will exist but match no usable middleware chain, and every request to it will 404 or hang
depending on how the proxy is otherwise configured. Get that file in place before Step 4 below.

**DNS for the domain you intend to use already points at the reverse proxy.** You will confirm the
actual routing once the container exists (see Verification); nothing here checks it in advance.

## Setup

### Overview

1. Create the config, data and audit directories.
2. Write the server configuration file.
3. Install log rotation for the audit log.
4. Start the container.
5. Initialize the vault — once, ever.
6. Unseal it.

---

#### Step 1: Create the directories

```bash
mkdir -p ./data/openbao/config ./data/openbao/data ./data/openbao/audit
sudo chown <puid>:<pgid> ./data/openbao ./data/openbao/config ./data/openbao/data ./data/openbao/audit
sudo chmod 0750 ./data/openbao ./data/openbao/config ./data/openbao/data ./data/openbao/audit
```

**Explanation**: `<puid>:<pgid>` must be the account the container itself runs as (`--user` in Step
4), because the Raft store under `./data/openbao/data` is written directly by that process — a
mismatch here means the container starts and then fails the moment it tries to write its first log
entry. Mode `0750` keeps the directory, which will shortly hold both the server's configuration and
its complete secret store, unreadable to any other unprivileged account on this machine.

---

#### Step 2: Write the server configuration

```bash
sudo tee ./data/openbao/config/config.hcl >/dev/null <<'EOF'
ui = true

disable_mlock = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "<node-id>"
}

listener "tcp" {
  address                          = "0.0.0.0:8200"
  cluster_address                  = "0.0.0.0:8201"
  tls_disable                      = "true"
  x_forwarded_for_authorized_addrs = "<traefik-docker-ip>/32"

  telemetry {
    unauthenticated_metrics_access = true
  }
}

api_addr     = "https://openbao.your-domain.com"
cluster_addr = "http://<openbao-docker-ip>:8201"

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}

audit "file" "file" {
  description = "audit device"

  options {
    file_path = "/openbao/audit/audit.log"
  }
}
EOF
sudo chown <puid>:<pgid> ./data/openbao/config/config.hcl
sudo chmod 0640 ./data/openbao/config/config.hcl
```

**Explanation**: `disable_mlock = true` is the recommended setting for the Raft backend specifically
— Raft memory-maps its on-disk database, which is incompatible with locking the process's memory
against being swapped. `tls_disable = "true"` is safe here only because the reverse proxy terminates
TLS in front of this container and nothing reaches port `8200` except through that proxy or through
the loopback bind; `x_forwarded_for_authorized_addrs` then names the *one* address allowed to claim a
forwarded-for header, so a request that arrives any other way cannot spoof its way past that check.

`node_id` identifies this server within its own Raft log. Pick it once and never change or reuse it
while data exists — Raft treats the id as a peer identity, and changing it after the fact does not
rename the existing peer, it introduces what looks like a different one.

The audit device is declared here, in the configuration file, rather than turned on later with a
command against the running server. Current OpenBao releases refuse to enable a file or socket audit
device over the API at all (`400 … cannot enable audit device via API; use declarative, config-based
audit device management instead`) — a file device can be pointed at any path on the filesystem and a
socket device at any socket, which is operator-level power, not something a mere API token should be
able to grant itself. Declaring it here, in a file only an operator with shell access can edit, is the
supported way to enable it; it takes effect on every restart and can also be re-applied without a
restart by signalling the process (see Updating & day-to-day).

`api_addr` is the external HTTPS address exactly as clients dial it — it is embedded in redirects the
UI issues, so getting it wrong here manifests as a redirect loop rather than a connection failure.
`cluster_addr` is unrelated to the public address: it is where this node's own container-network
address expects other Raft peers to reach it for replication traffic. A single-node deployment still
requires the field to be set, even though nothing currently connects to it.

---

#### Step 3: Install log rotation for the audit log

```bash
sudo tee /etc/logrotate.d/openbao >/dev/null <<EOF
$(pwd)/data/openbao/audit/audit.log {
    size 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

**Explanation**: If every enabled audit device fails to write, OpenBao stops answering requests
entirely — that is intentional (an audited system that silently stopped recording would be worse than
one that stops serving), but it also means an audit log left to grow forever until the disk fills is a
self-inflicted outage waiting to happen. `copytruncate` is required rather than the usual rename-and-
reopen rotation: the file is open continuously inside the container for the life of the process, and
nothing inside the container is told to reopen it after a rotation, so truncating the same inode in
place is the only rotation strategy that does not eventually make the process write into a file that
no longer exists on disk.

---

#### Step 4: Start the container

```bash
docker run -d \
  --name openbao \
  --restart unless-stopped \
  --user <puid>:<pgid> \
  --stop-signal SIGTERM \
  --stop-timeout 30 \
  --network proxy \
  --ip <openbao-docker-ip> \
  --network-alias openbao \
  -p 127.0.0.1:8200:8200 \
  -e BAO_ADDR=http://127.0.0.1:8200 \
  -v "$(pwd)/data/openbao/config:/openbao/config:ro" \
  -v "$(pwd)/data/openbao/data:/openbao/data" \
  -v "$(pwd)/data/openbao/audit:/openbao/audit" \
  --health-cmd 'bao status -address=http://127.0.0.1:8200 >/dev/null 2>&1 || test $? -eq 2' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 20s \
  --label traefik.enable=true \
  --label "traefik.http.routers.openbao.entrypoints=https" \
  --label "traefik.http.routers.openbao.rule=Host(\`openbao.your-domain.com\`)" \
  --label "traefik.http.routers.openbao.tls=true" \
  --label "traefik.http.routers.openbao.middlewares=chain-no-auth@file" \
  --label "traefik.http.routers.openbao.service=openbao" \
  --label "traefik.http.services.openbao.loadbalancer.server.port=8200" \
  ghcr.io/openbao/openbao:latest \
  server -config=/openbao/config/config.hcl
```

**Explanation**: `-p 127.0.0.1:8200:8200` is deliberately narrow — it puts the API on this host's
loopback interface only, reachable by an operator with a shell on this machine, and unreachable from
the rest of the LAN even though the port is technically "published". Every other client, on this
machine's own network or elsewhere, reaches the vault at `https://openbao.your-domain.com` through the
reverse proxy instead.

The health check treats two outcomes as healthy: `bao status` exits `0` when the vault is unsealed and
answering normally, and exits `2` when it is sealed — which, immediately after every single restart,
is the *expected* state, not a failure. Only a genuine error (a crashed process, a corrupted
configuration) produces anything else, which is the only case that should actually flip the
container's health state and trigger alerting.

The router's `middlewares` label points at the reverse proxy's no-auth chain instead of the usual
forward-authentication chain — see "Before you start" for why: OpenBao authenticates its own clients,
and putting a browser-based single-sign-on login in front of an API endpoint would break every
non-browser client that talks to it.

`./data/openbao/config` is mounted read-only: the running server never needs to write its own
configuration, and a read-only mount means a compromised process inside the container cannot rewrite
the policy that governs it. The other two volumes are read-write because the server owns that data
directly.

---

#### Step 5: Initialize the vault — once, ever

Skip this step if the vault has already been initialized on this host before (see Verification for
how to check).

```bash
docker exec -it openbao bao operator init -address=http://127.0.0.1:8200
```

This prints **five unseal key shares** and an **initial root token**. Any **three of the five** shares
are enough to unseal the vault later; the full five are never all required at once.

**Explanation**: Write every one of these six values down in a password manager immediately — they are
shown exactly once, OpenBao does not store them anywhere retrievable, and there is no "forgot my
key" recovery path. Losing enough shares that you can no longer reach the three-of-five threshold
makes every secret in this vault permanently unrecoverable — not merely locked, gone. Losing only the
root token is, by contrast, recoverable later with a quorum of the unseal shares (`bao operator
generate-root`), which is exactly why the shares are the ones that must never be lost.

Never paste any of these six values into a file on this host, into a command's argument list, or into
a chat window — a value on the command line lands in shell history and in this host's process table
for anyone else with a session here to read. Every command in this guide and the ones that follow it
reads a secret from an interactive prompt for that reason.

---

#### Step 6: Unseal

```bash
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200
```

Run that command three times, pasting a **different** share each time when prompted. Then confirm:

```bash
docker exec openbao bao status -address=http://127.0.0.1:8200
# Sealed   false
```

**Explanation**: OpenBao seals itself — discards the in-memory key that makes its storage readable —
on every single restart, by design. The key that protects everything in the Raft store is never held
whole anywhere; it is reconstructed only in memory, only when enough independently-held shares are
combined, which is exactly what makes a single leaked share harmless and a stolen disk on its own
useless. Submitting the same share twice does not advance the count toward the threshold — if the
reported progress stalls, you pasted a duplicate rather than a third distinct share.

## Restoring

The dumps to restore from here are Raft snapshots — either one you take by hand below, or one
produced by a separate scheduled job that pulls a snapshot from this vault using a credential scoped
to read nothing but `sys/storage/raft/snapshot`.

**Take a snapshot** while the vault is unsealed and you hold an authenticated token:

```bash
read -rs BAO_TOKEN; echo
docker exec -e BAO_TOKEN openbao bao operator raft snapshot save /openbao/data/backup.snap
docker cp openbao:/openbao/data/backup.snap ./openbao-$(date +%F).snap
docker exec openbao rm /openbao/data/backup.snap
```

**Restore a snapshot into the running vault.** Nothing needs to be stopped first — the restore happens
through the API against a live, unsealed server — but every existing token and lease is invalidated
the moment it completes, so every client of this vault will need to re-authenticate afterward:

```bash
read -rs BAO_TOKEN; echo
docker cp ./openbao-<date>.snap openbao:/tmp/restore.snap
docker exec -e BAO_TOKEN openbao bao operator raft snapshot restore /tmp/restore.snap
```

**Restore into a vault that lost its host or its data directory entirely.** This one is subtler,
because a snapshot restore needs an authenticated connection to *something*, and an empty data
directory has nothing running in it yet:

```bash
docker stop openbao && docker rm openbao
sudo rm -rf ./data/openbao/data/*
# start the container again, exactly as in Step 4
docker exec -it openbao bao operator init -address=http://127.0.0.1:8200
```

That `init` is a throwaway — its only purpose is to get the empty vault answering API calls at all, so
unseal it with the shares it just printed and log in with the root token it just printed:

```bash
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200   # x3, the fresh shares
read -rs BAO_TOKEN; echo   # the root token this init just printed
```

Now restore the real snapshot over that empty storage:

```bash
docker cp ./openbao-<date>.snap openbao:/tmp/restore.snap
docker exec -e BAO_TOKEN openbao bao operator raft snapshot restore /tmp/restore.snap
docker restart openbao
```

**Explanation**: A restore replaces the entire Raft store — including the encryption keyring — with
the one captured in the snapshot. That is why the throwaway unseal keys and root token from the
just-run `init` stop working the instant the restore completes: after the restart, the server is
sealed with the *original* vault's keyring, the one that produced the snapshot, not the one it was
just handed. Unseal it again, this time with the **original** vault's shares — the ones saved when
that vault was first initialized, kept safely outside this host the whole time. The keys from the
throwaway `init` can be discarded; they never protected anything real.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The account's home directory; every path is relative to it | Before you start |
| `<username>` | Account that owns `./data` | Your unprivileged administrative account on this host | Before you start |
| `<puid>` / `<pgid>` | uid:gid the container runs as | Any dedicated pair not shared with another service's data; owns `./data/openbao` | Steps 1, 2, 4 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | Addressing of the `proxy` network | From `docker network inspect proxy` if it already exists | Before you start |
| `<traefik-docker-ip>` | The reverse proxy's fixed address on `proxy` | From `docker network inspect proxy` | Step 2 (trusted forwarded-for source) |
| `<openbao-docker-ip>` | This container's own fixed address on `proxy` | Any free address inside `<docker-subnet>`, outside the auto-assign range | Steps 2, 4 |
| `<node-id>` | This vault's Raft peer identity | A short stable label, e.g. `openbao-1`; never reused or changed | Step 2 |
| `your-domain.com` | The domain this vault answers on | Whatever DNS record you point at the reverse proxy | Steps 2, 4 |
| `<unseal-key>` | One of the five shares printed at initialization | Printed once by `bao operator init`; kept in a password manager, never in a file on this host | Steps 5, 6, Restoring |
| `<root-token>` | The initial root token | Printed once by `bao operator init`; used only until a lesser-privileged account exists | Step 5, Restoring |
| `<date>` | A snapshot's capture date | Whatever `date +%F` produced when you took it | Restoring |

## Verification

```bash
docker ps --filter 'name=^openbao$'
docker inspect --format '{{.State.Health.Status}}' openbao
```

Seal and initialization state:

```bash
docker exec openbao bao status -address=http://127.0.0.1:8200
```

Reachable through the reverse proxy, without authentication in front of it:

```bash
curl -s https://openbao.your-domain.com/v1/sys/health?standbyok=true\&sealedcode=200\&uninitcode=200
```

The audit device is enabled and actually writing:

```bash
docker exec -e BAO_TOKEN openbao bao audit list -detailed
ls -l ./data/openbao/audit/audit.log
```

Metrics are being produced (unauthenticated by design, reachable only from inside the container
network):

```bash
docker exec openbao wget -qO- http://127.0.0.1:8200/v1/sys/metrics?format=prometheus | head
```

A metrics agent on this host normally scrapes that same endpoint continuously; expect it to report
this target **down** while the vault is sealed (the endpoint answers `503` until the first unseal
after a restart) and up again the moment you unseal it — that is expected behaviour, not a fault to
chase.

## Updating & day-to-day

**Pull a newer image and recreate the container.** The Raft store lives outside the container, so a
minor-version pull is a routine stop/rm/run:

```bash
docker pull ghcr.io/openbao/openbao:latest
docker stop openbao && docker rm openbao
# re-run the docker run command from Step 4, unchanged
```

The vault comes back **sealed** every time — see the next item.

**Unseal after every restart.** This is the single most common thing you will do to this vault: a
reboot of the host, an image update, a crash, anything that stops and starts the container, seals it
again. Repeat Step 6:

```bash
docker exec openbao bao status -address=http://127.0.0.1:8200   # Sealed true?
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200   # x3, different shares
```

There is no automated unseal configured here (that requires an external key-management service acting
as an auto-unseal backend, which this deployment does not use) — budget for a human with the shares to
be reachable, or accept that anything depending on this vault stays down until someone runs the
commands above.

**Editing `config.hcl`.** Rewrite it in place with `sudo tee` (Step 2), the same way `pg_hba.conf` is
handled for the database server — replacing the file with an editor or `mv` detaches the container's
bind mount from a new inode and the running server keeps the old configuration regardless of what is
on disk now. Some settings (the listener, the storage backend) only take effect on a full restart;
recreate the container for those. A change to the audit device alone can be picked up without dropping
existing connections by signalling the process instead:

```bash
docker kill -s HUP openbao
```

**Logs**: `docker logs -f openbao`. Seal/unseal events, listener errors and audit-device failures all
land there.

**The audit log**: rotated nightly by the `logrotate` entry from Step 3. Confirm it is actually being
picked up:

```bash
sudo logrotate -d /etc/logrotate.d/openbao
```

## Rollback / Uninstall

```bash
docker stop openbao
docker rm openbao
```

The data survives in `./data/openbao/data`; re-running Step 4 brings the same vault back, still
sealed.

To remove it completely — **this destroys every secret this vault ever held, irreversibly**:

```bash
docker rm -f openbao
sudo rm -rf ./data/openbao
```

Take a Raft snapshot first (see Restoring) if there is anything worth keeping.

## Troubleshooting

**Sealed after a reboot**
Expected — see Updating & day-to-day. Unseal with three shares.

**`missing client token` / `permission denied` on every command**
You are not authenticated. `docker exec openbao bao login` needs a token; the root token from
initialization works for the very first session, everything after that should use a lesser-privileged
account.

**Redirect loop, or the UI keeps switching between `http://` and `https://`**
`api_addr` in `config.hcl` does not match the external URL exactly, or the reverse proxy is not
forwarding `X-Forwarded-Proto: https`. Confirm `<traefik-docker-ip>` in the listener's
`x_forwarded_for_authorized_addrs` really is the reverse proxy's current address — it changes if that
container is ever recreated with a different fixed address.

**`failed to lock memory` on startup**
`disable_mlock = true` is missing from `config.hcl`. It must be present for the Raft backend, which
memory-maps its database and is incompatible with memory locking.

**Permission denied writing to `/openbao/data`**
`./data/openbao/data` is not owned by the uid:gid the container runs as. Re-run Step 1's `chown`.

**Every request returns 500, log shows no audit devices could be reached**
The audit device cannot write — disk full, `./data/openbao/audit` not owned by the container's uid,
or the volume mount missing. This is deliberate fail-closed behaviour: a vault that cannot record what
it did refuses to do anything. Fix the directory, then `docker kill -s HUP openbao` to reload the
device without a full restart.

**A newly issued client certificate or token stops working right after a snapshot restore**
Expected — see the "Explanation" under Restoring. The restore replaced the keyring; anything
authenticated against the pre-restore state is now invalid and must re-authenticate.

**A scheduled snapshot job starts failing with `403` on `sys/storage/raft/snapshot`**
The credential that job uses lost its read permission on that one path, or was revoked. Re-issue it
against the policy that grants exactly that path.
