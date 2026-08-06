# Proxmox exporter

## What this is

`prometheus-pve-exporter` is a small bridge with one job: the Proxmox hypervisor exposes a
management API, not a metrics endpoint, and it cannot push anything anywhere on its own — so this
container polls that API on Prometheus's behalf and translates the answer into Prometheus's
exposition format. It runs on the monitoring machine, next to Prometheus itself.

It holds no state and serves no route of its own. Nothing bind-mounts into it, nothing bind-mounts
out of it, and there is no reverse-proxy entry for it — the only thing that ever talks to it is
Prometheus, over the shared container network, and it in turn only ever talks to the Proxmox API.

The scrape shape is the thing worth understanding before you touch this container: Prometheus does
not ask *this* container "what are your metrics" the normal way. It asks it to go poll a specific
Proxmox host, passed as a query parameter (`?target=<pve-api-host>`), and the exporter fetches that
target's cluster and node status right then, synchronously, and hands back a fresh answer. One
exporter container can in principle front several Proxmox hosts this way; here there is one.

Authentication against Proxmox is a single API token — not the exporter's own login, not a shared
root password, a token scoped to exactly the read access this needs and nothing more.

---

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
```

This exporter does not write anything under `./data` itself — there is no configuration file and no
persisted state for this container — but the directory is still expected to exist as the working
directory you run every command in this guide from.

### The shared `proxy` bridge network exists

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

### Prometheus is already running on this machine

This exporter has nothing to talk to Prometheus's remote-write receiver about — it is scraped, not
pushed to — but Prometheus's own configuration file has to already list a `pve` scrape job pointed at
this container's name before a deploy of this exporter does anything useful.

```bash
docker ps --filter 'name=^prometheus$'
curl -sf https://prometheus.your-domain.com/-/ready && echo
```

### You have created a scoped Proxmox API token

Do this on the Proxmox host itself (over SSH, or through its own web UI under *Datacenter →
Permissions*). Create a dedicated user for this purpose rather than reusing an interactive login,
and give it read-only auditor rights at the root of the resource tree — that is enough to read every
node, VM and container's status and is not enough to change anything:

```bash
pveum user add <api-user>@pve --comment "Prometheus metrics scraping"
pveum aclmod / -user <api-user>@pve -role PVEAuditor
pveum user token add <api-user>@pve <token-name> --privsep=0
```

The token value is printed exactly once, at creation time, and Proxmox does not store it anywhere
you can retrieve it again afterwards — copy it immediately into wherever you keep secrets for this
deploy.

**Explanation**: `PVEAuditor` is Proxmox's own built-in read-only role — it can list and inspect
every node, VM, container, storage pool and their current status, and it cannot start, stop, create,
delete or reconfigure anything. That is the entire read surface this exporter needs; there is no
metric it exposes that requires more. Granting it at the root of the tree (`/`) rather than on
individual VMs means new guests are automatically visible without a second grant every time one is
created. A dedicated `@pve` user rather than reusing `root@pam` or an admin account means this
credential can be revoked or rotated without touching anything a human logs in with, and means
`pveum user token list <api-user>@pve` gives you a clean audit trail of exactly what this integration
holds. `--privsep=0` makes the token inherit the user's own ACL directly rather than needing a
second, separate ACL grant just for the token — with only one consumer of this user account, that
separation buys nothing and just doubles the places a permission has to be kept in sync.

---

## Setup

### Overview

1. Start the container with the API token as environment variables.
2. Confirm the exporter can actually reach and authenticate against Proxmox.

---

#### Step 1: Start the container

```bash
docker run -d \
  --name pve-exporter \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e PVE_USER='<api-user>@pve' \
  -e PVE_TOKEN_NAME='<token-name>' \
  -e PVE_TOKEN_VALUE='<token-value>' \
  -e PVE_VERIFY_SSL=false \
  --health-cmd 'wget --spider -q "http://localhost:9221/pve?target=<pve-api-host>"' \
  --health-interval 1m \
  --health-timeout 15s \
  --health-retries 3 \
  --health-start-period 30s \
  prompve/prometheus-pve-exporter:latest
```

**Explanation**: There is no configuration file for this container and nothing to mount, so the
token is handed to it directly as environment variables at container-creation time rather than
written to a file on disk first. That keeps the number of places this credential lives to a minimum
— one `docker run` invocation, not a file that also then needs its own ownership and permission
bits set and kept correct across every redeploy. The trade-off is that anything with permission to
run `docker inspect pve-exporter` on this host can read the token back out in plain text; that is an
accepted risk here because that same permission already implies the ability to read every other
container's environment on the machine, including ones that do keep their credentials in mounted
files.

`PVE_VERIFY_SSL=false` matters if the Proxmox host presents a self-signed certificate, which is the
default on a fresh Proxmox install unless you have gone out of your way to put a real certificate on
its management interface — with verification on and a self-signed cert, every scrape fails with a
TLS trust error. If this Proxmox host's management interface does have a certificate this host
already trusts, set it to `true` instead; there is no reason to leave verification off if it is not
needed.

The health check is a real functional probe, not just a liveness check — it asks the exporter to
actually perform one scrape of the configured Proxmox host and only reports healthy if that round
trip (reach Proxmox, authenticate with the token, get a response) succeeds. A wrong token, a wrong
`<pve-api-host>`, or an unreachable Proxmox host all show up as an unhealthy container, not a silently
empty metric.

---

#### Step 2: Confirm the exporter can reach and authenticate against Proxmox

```bash
docker inspect --format '{{.State.Health.Status}}' pve-exporter

docker run --rm --network proxy curlimages/curl:latest -s \
  "http://pve-exporter:9221/pve?target=<pve-api-host>" | head -30
```

**Explanation**: A working response is plain-text Prometheus exposition format, starting with `#
HELP` / `# TYPE` lines and metric names like `pve_up`, `pve_cpu_usage_ratio`, `pve_memory_usage_bytes`.
An authentication failure comes back as an HTTP error with a body naming the problem (an invalid
token, or a user/token pair that does not exist), and a network failure times out — both are far
easier to read straight from this container than by waiting for Prometheus's own scrape state to
reflect it.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory | The directory you deploy everything from | Before you start |
| `<username>` | Account that runs Docker commands on this machine | The unprivileged login on this machine | Before you start |
| `<docker-ip>` | The exporter's fixed address on the `proxy` network | Any free address outside the automatic pool | Step 1 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | The bridge network's addressing | As created | Before you start |
| `<api-user>` | The dedicated Proxmox user created for this token | Any name; `<api-user>@pve` is the full login | Before you start, Step 1 |
| `<token-name>` | The token's identifier under that user | Any name; visible (not secret) alongside the value | Before you start, Step 1 |
| `<token-value>` | The token's secret value | Printed once at creation time by `pveum`, never retrievable again | Step 1 |
| `<pve-api-host>` | The Proxmox management API's address and port | Typically `<ip-address>:8006`; must match the value Prometheus's own `pve` scrape job is configured with | Step 1, Step 2 |
| `your-domain.com` | Base domain | Your own domain | Before you start |

Port `9221` is fixed by the image and should not be changed — Prometheus's own `pve` scrape job is
configured to reach the exporter on that exact port.

---

## Verification

```bash
docker ps --filter 'name=^pve-exporter$'
docker inspect --format '{{.State.Health.Status}}' pve-exporter

docker run --rm --network proxy curlimages/curl:latest -sf \
  "http://pve-exporter:9221/pve?target=<pve-api-host>" | grep -c '^pve_'
```

That count should be well over a hundred for even a small cluster — one series per metric per guest
per node. Then confirm Prometheus itself sees the target as healthy, which proves the whole path
end to end:

```bash
curl -sf https://prometheus.your-domain.com/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.labels.job=="pve") | "\(.health)\t\(.lastError)"'
```

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull prompve/prometheus-pve-exporter:latest
docker stop pve-exporter && docker rm pve-exporter
# re-run the docker run from Step 1
```

This container is stateless, so a plain stop/remove/recreate is fine here — unlike Prometheus,
Loki or Alloy, there is no bind-mounted single file to lose across a recreate, which is why this is
the one guide in the monitoring set that does not need the CLI stop/start-only pattern.

**Logs:**

```bash
docker logs -f pve-exporter
```

**Rotate the token periodically.** Because the value is only ever visible once, rotation means
creating a new token, updating the environment variables in Step 1, recreating the container, then
revoking the old token on the Proxmox side:

```bash
pveum user token remove <api-user>@pve <old-token-name>
```

Do the recreate first and confirm Step 2 succeeds with the new token before revoking the old one, so
a mistake in the new value does not leave this exporter unable to scrape anything.

---

## Rollback / Uninstall

```bash
docker stop pve-exporter && docker rm pve-exporter
docker rmi prompve/prometheus-pve-exporter:latest
```

There is no data directory to clean up. Also remove the `pve` scrape job from Prometheus's
configuration and restart it, or that job sits at `down` in the target list indefinitely, and revoke
the token on the Proxmox side so it is not left valid with nothing using it:

```bash
pveum user token remove <api-user>@pve <token-name>
pveum user delete <api-user>@pve
```

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container unhealthy immediately after start | Wrong `<pve-api-host>`, or Proxmox is unreachable from this machine's network — confirm with `curl -sk https://<pve-api-host>/api2/json/version` from the Docker host. |
| Health check fails with an authentication error | `PVE_USER`, `PVE_TOKEN_NAME` or `PVE_TOKEN_VALUE` is wrong, or the token was revoked. Recreate the token with `pveum user token add` and update the container. |
| Health check fails with a TLS/certificate error | `PVE_VERIFY_SSL` is `true` against a Proxmox host with a self-signed certificate. Set it to `false`, or install a certificate this host trusts on the Proxmox side. |
| Exporter responds, but Prometheus shows the `pve` target as `down` | `<pve-api-host>` differs between this container's health check and Prometheus's own `pve` scrape job configuration — they must match exactly, including the port. |
| Response comes back but with far fewer `pve_*` series than expected | The token's role does not have `PVEAuditor` (or broader) at the root of the tree, so it cannot see guests outside whatever narrower scope it was granted. Re-check `pveum aclmod`. |
| Response is empty or a bare error page, not Prometheus exposition format | The exporter reached something on that address and port, but it was not the Proxmox API — check `<pve-api-host>` for a typo, especially the port. |
| Token value was lost before it could be recorded | Proxmox never shows it again. Delete the token with `pveum user token remove` and create a new one — there is no way to recover the old value. |
