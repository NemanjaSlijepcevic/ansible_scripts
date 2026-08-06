# Docker Socket Proxy

## What this is

A filtered gateway in front of the host's Docker Engine API. It runs as a container called
`socket-proxy` on the automation host, listens on port `2375` inside an isolated Docker network
called `docker-api`, and forwards only a fixed allow-list of Docker API endpoints down to
`/var/run/docker.sock`.

It exists for one reason: **the workflow orchestrator (Kestra) must never be handed the Docker
socket directly.** A container that can talk to `/var/run/docker.sock` is root on the host in every
way that matters — it can start a privileged container, bind-mount `/` from the host into it, load
kernel modules through it, and read every secret on the machine. The orchestrator legitimately needs
to launch and reap short-lived task containers, so instead of the socket it gets an HTTP endpoint
that permits exactly that lifecycle and answers `403` to everything else.

Nothing else on the machine talks to it. It is **not** on the shared `proxy` network, has **no**
reverse-proxy routing, **no** single sign-on in front of it, and publishes **no** port to the host.
Its only consumer is whatever container you explicitly attach to `docker-api`.

The container also patches its own HAProxy configuration at startup to remove a ten-minute server
timeout that would otherwise cut off long-running task containers. That is Step 3 below and it is
the single most easily lost piece of this deployment.

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

**The Docker socket exists and the daemon answers on it**

```bash
ls -l /var/run/docker.sock
sudo docker info --format '{{.ServerVersion}}'
```

The bind-mount path below is fixed at `/var/run/docker.sock`. If your daemon uses a different
socket path, the proxy has nothing to proxy and will start but answer nothing.

**You are not going to reuse the shared `proxy` network here**

This service deliberately does not join it. If a `proxy` network exists on this host for the other
services, leave it alone — nothing in this guide touches it.

**You know which container will consume the API**

Have the name of the workflow orchestrator container ready (referred to below as `<container>`).
Only containers you explicitly attach to `docker-api` can reach the proxy, and attaching one is a
grant of host-root-equivalent power over the Docker daemon. Treat that list as a security boundary.

## Setup

### Overview

1. Create the isolated, internal `docker-api` network.
2. Start the `socket-proxy` container with a narrow API allow-list and a startup command that
   removes the HAProxy server timeout.
3. Confirm the startup timeout patch is actually live in the running configuration.
4. Attach the consuming container to `docker-api`.

---

#### Step 1: Create the internal `docker-api` network

```bash
sudo docker network create --internal docker-api
sudo docker network inspect docker-api --format '{{.Internal}}'
# expect: true
```

**Explanation**: `--internal` is the whole point of this network. Docker does not install a default
route or NAT rule for an internal network, so containers attached to it cannot reach the outside
world *through it*, and nothing outside can route into it. The proxy therefore has exactly one
audience: containers you deliberately attach. Keep this network separate from the shared `proxy`
network that the reverse proxy and the public services live on — anything that can reach this
endpoint can create a privileged container on the host, so it must never be reachable from a
network that also carries internet-facing traffic. For the same reason the container below
publishes no port: an exposed `2375` on a host interface is a remote root shell for anyone on the
LAN.

---

#### Step 2: Start the socket proxy

```bash
sudo docker run -d \
  --name socket-proxy \
  --restart unless-stopped \
  --network docker-api \
  -e LOG_LEVEL=info \
  -e POST=1 \
  -e CONTAINERS=1 \
  -e IMAGES=1 \
  -e NETWORKS=1 \
  -e VOLUMES=1 \
  -e INFO=1 \
  -e PING=1 \
  -e VERSION=1 \
  -e EXEC=0 \
  -e BUILD=0 \
  -e COMMIT=0 \
  -e SWARM=0 \
  -e SERVICES=0 \
  -e TASKS=0 \
  -e NODES=0 \
  -e SECRETS=0 \
  -e CONFIGS=0 \
  -e PLUGINS=0 \
  -e SYSTEM=0 \
  -e SESSION=0 \
  -e DISTRIBUTION=0 \
  -e AUTH=0 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --health-cmd 'wget -q -O /dev/null http://127.0.0.1:2375/_ping' \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 10s \
  tecnativa/docker-socket-proxy:latest \
  /bin/sh -c "sed -i '/^backend dockerbackend\$/a\\    timeout server 0' /tmp/haproxy.cfg && exec haproxy -W -db -f /tmp/haproxy.cfg"
```

**Explanation**: The proxy needs the socket itself in order to translate HTTP calls into daemon
calls, and it is mounted read-only so the container cannot replace or write through the socket path
as a file — the proxy process still issues ordinary API calls over it, which is exactly the traffic
being filtered.

Each environment variable turns one group of API paths on (`1`) or off (`0`), and a request to a
path that is off gets `403` before it ever reaches the daemon:

- `POST=1` — without this the proxy is read-only and nothing can be created or started. This is the
  single most dangerous flag here, and it is the reason every destructive group below is off.
- `CONTAINERS=1` — the create / start / inspect / wait / logs / remove lifecycle. This is what lets
  the orchestrator run an ephemeral task container and collect its output.
- `IMAGES=1` — pull and inspect images, so a task can reference an image tag that is not yet local.
- `NETWORKS=1`, `VOLUMES=1` — list and attach networks and volumes, needed to place a task container
  on its sandbox network and mount its scratch space.
- `INFO=1`, `PING=1`, `VERSION=1` — harmless daemon metadata used for connectivity and health
  checks, including the container's own healthcheck below.
- `EXEC=0` — blocks the top-level `/exec/<id>/start` and `/exec/<id>/resize` paths, which are the
  calls that actually *run* a command inside a container. Be precise about what this does and does
  not stop: the allow rule behind `CONTAINERS=1` matches the whole `/containers` path prefix, so
  `POST /containers/<id>/exec` — the call that *creates* an exec instance — is permitted and reaches
  the daemon. It is the start call that is refused with `403`, so a client can create an exec
  instance and never get to use it, and no shell is ever obtained. With `EXEC=1` that second half
  opens and anyone who reached the proxy would have an interactive shell inside any container on the
  host, including privileged ones. This split is how the image's rule set has always behaved; it is
  unrelated to the startup patch below.
- `BUILD=0`, `COMMIT=0` — no image builds and no snapshotting a running container into an image
  through this endpoint. Images are built directly on the host by an operator, not by a workflow.
- `SWARM=0`, `SERVICES=0`, `TASKS=0`, `NODES=0`, `SECRETS=0`, `CONFIGS=0`, `PLUGINS=0` — the entire
  Swarm surface is denied. Swarm secrets and configs are readable through those endpoints, and
  plugin installation is arbitrary code execution on the daemon.
- `SYSTEM=0` — no daemon-wide calls such as prune or system events; a workflow bug should not be
  able to delete every unused volume on the machine.
- `SESSION=0`, `DISTRIBUTION=0`, `AUTH=0` — no registry authentication relay, so registry
  credentials held by the daemon cannot be exercised through the proxy.

Treat this list as code, not configuration. Every `0` you turn into a `1` widens what an arbitrary
workflow — including one that a compromised task container writes — can do to the host.

The healthcheck hits `/_ping` on the loopback interface inside the container, which is the cheapest
endpoint that proves HAProxy parsed its configuration and bound its listener. It is also why
`PING=1` must stay on.

The trailing `/bin/sh -c ...` is a deliberate override of the image's command; Step 3 explains what
it does and why. Note the escaping in the shell above: `\$` keeps the shell from expanding the
anchor in the `sed` address, and `\\    ` produces the literal `\` plus indentation that `sed`'s
append command expects.

---

#### Step 3: Confirm the startup timeout patch is live

```bash
sudo docker cp socket-proxy:/tmp/haproxy.cfg /tmp/h.cfg
sed -n '/^backend dockerbackend$/,/^$/p' /tmp/h.cfg
# expect a `timeout server 0` line inside the stanza
rm -f /tmp/h.cfg
```

**Explanation**: The image ships an HAProxy configuration whose `defaults` block sets
`timeout client 10m` and `timeout server 10m`. Only the image's `docker-events` backend overrides
that with `timeout server 0`. The `dockerbackend` backend — the one that serves
`/containers/<id>/wait` and `/containers/<id>/logs?follow=true` — inherits the ten-minute limit.

The consequence is precise and nasty. Any task container that runs longer than ten minutes has its
wait call and its log stream severed by the proxy. The orchestrator sees the connection drop,
concludes the container is gone, and kills a container that is still working. The observed symptom
is task containers failing at 10:01–10:03 every single time, with the proxy's own access log showing
a `600049ms` duration and HAProxy termination flag `sD` — a server-side timeout during the data
phase — on the `/wait` call, while 116 KB of task output had already streamed through perfectly
fine. Nothing in the orchestrator's logs points at the proxy; it looks like a flaky task.

There is no environment variable for this. The timeouts are hardcoded in the skeleton configuration
baked into the image, and the entrypoint substitutes only `${BIND_CONFIG}` into it. What the
entrypoint does give you is a window: it writes the finished configuration to `/tmp/haproxy.cfg`
and *then* execs the container command. Overriding the command therefore lets you edit the
configuration after it has been generated but before HAProxy ever reads it, which is what the `sed`
in Step 2 does — it appends `timeout server 0` immediately after the `backend dockerbackend` line,
disabling the server-side timeout for that backend only.

`-W -db` has to be passed by hand. The entrypoint adds those flags only when the container command
is literally `haproxy`, and here the command is `/bin/sh`, so the entrypoint's own argument handling
never fires. `-W` runs HAProxy in master-worker mode (the same mode the image normally uses) and
`-db` keeps it in the foreground; without `-db` HAProxy daemonises, the shell's `exec` target exits
immediately, and the container dies in a restart loop.

The indentation of the inserted line is purely cosmetic. HAProxy ignores leading whitespace and
delimits sections by the `global` / `defaults` / `frontend` / `backend` keywords at the start of a
line, so the appended directive belongs to `dockerbackend` regardless of how it is indented.

There is deliberately **no** guard that aborts startup when the `sed` pattern fails to match. A
pattern that stops matching after an image update would then crash-loop the proxy and take the whole
orchestrator down with it, which is strictly worse than degraded timeouts. `sed` silently changes
nothing instead — and the check at the top of this step is the only thing that catches that silent
no-op, which is why it is a step and not an afterthought.

---

#### Step 4: Attach the consuming container to `docker-api`

```bash
sudo docker network connect docker-api <container>
sudo docker inspect <container> --format '{{json .NetworkSettings.Networks}}'
```

The consumer reaches the API at `tcp://socket-proxy:2375` — by container name, resolved by Docker's
embedded DNS on the `docker-api` network.

**Explanation**: Attaching a container to this network is the entire access-control mechanism; there
is no authentication on the proxy. Attach only the orchestrator. The consuming container keeps its
other networks — a container can sit on `docker-api` for API access and on the shared `proxy`
network for its own web interface at the same time — but the proxy itself must stay on `docker-api`
alone. If your orchestrator is normally created with an explicit network list, add `docker-api` to
that list rather than connecting it by hand, otherwise the attachment is lost the next time the
container is recreated.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<username>` | The account on the host that runs Docker commands | The existing deploy/admin account; it must be in the `docker` group | Before you start |
| `<container>` | Name of the workflow orchestrator container that consumes the Docker API | Whatever that container is named on this host | Step 4, Verification |
| `<container-id>` | Any container id string | Any value works — the probe is refused by the proxy before the daemon is consulted, so the id need not exist | Verification |

There is nothing else to choose. The endpoint allow-list, the network name, the container name and
the socket path are all fixed on purpose — this deployment has no tunables, because every tunable
would be a way to quietly widen host access.

## Verification

Container is up and healthy:

```bash
sudo docker ps --filter 'name=^socket-proxy$'
sudo docker inspect socket-proxy --format '{{.State.Running}} {{.State.Health.Status}}'
# expect: true healthy
```

The network is internal and the proxy is on it *only*:

```bash
sudo docker network inspect docker-api --format '{{.Internal}}'
# expect: true

sudo docker inspect socket-proxy --format '{{json .NetworkSettings.Networks}}'
# expect exactly one key: "docker-api" — never "proxy", and never a published port
```

The startup timeout patch is really live in the running configuration:

```bash
sudo docker cp socket-proxy:/tmp/haproxy.cfg /tmp/h.cfg
sed -n '/^backend dockerbackend$/,/^$/p' /tmp/h.cfg
# expect a `timeout server 0` line inside the stanza
rm -f /tmp/h.cfg
```

If that line is absent, the proxy is running with the image's default `timeout server 10m` and every
task longer than ten minutes will be killed mid-flight. Fix it before going further.

The API answers from inside the network (it is unreachable from the host directly, by design):

```bash
sudo docker run --rm --network docker-api curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://socket-proxy:2375/_ping
# expect: 200

sudo docker run --rm --network docker-api curlimages/curl:latest \
  -s http://socket-proxy:2375/version
```

A denied endpoint is actually denied. Probe the exec **start** path, not the exec create path:

```bash
sudo docker run --rm --network docker-api curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' \
  http://socket-proxy:2375/exec/<container-id>/start
# expect: 403

sudo docker run --rm --network docker-api curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' \
  http://socket-proxy:2375/secrets
# expect: 403
```

`/containers/<container-id>/exec` is **not** a useful probe: it falls under the permitted
`/containers` prefix and reaches the daemon, so it answers `404` for a container id that does not
exist. Seeing that `404` means the allow-list is working as designed, not that the proxy is broken.
The refusal that matters happens on the start call above.

The consumer can reach it:

```bash
sudo docker exec <container> sh -c 'wget -qO- http://socket-proxy:2375/_ping'
# expect: OK
```

## Updating & day-to-day

Pull a newer image and recreate the container:

```bash
sudo docker pull tecnativa/docker-socket-proxy:latest
sudo docker stop socket-proxy && sudo docker rm socket-proxy
# re-run the docker run command from Step 2, unchanged
```

**After every image update, re-run the Step 3 check.** The startup patch targets a stanza name
inside the image's own configuration; an upstream rename turns it into a silent no-op and the
ten-minute failures come back without any error anywhere.

Logs:

```bash
sudo docker logs -f socket-proxy
```

At `LOG_LEVEL=info` the proxy emits an HAProxy access line per request. The two fields worth knowing
are the total duration in milliseconds and the two-character termination flag at the end — `sD`
means the server side timed out during data transfer, `cD` the client side, `--` a clean close.

To change what the proxy permits, edit the environment variables and recreate the container; there
is no reload. Recreating the proxy briefly breaks any in-flight task the orchestrator is waiting on,
so do it when nothing is running.

Nothing is written to disk by this service — no data directory, no configuration file on the host.
The whole state is the container and the network.

## Rollback / Uninstall

```bash
sudo docker stop socket-proxy && sudo docker rm socket-proxy
sudo docker network disconnect docker-api <container>
sudo docker network rm docker-api
```

**Warning**: removing this breaks the workflow orchestrator's Docker task runner outright.
`tcp://socket-proxy:2375` stops resolving and every task that launches a container fails
immediately. Decommission or reconfigure the orchestrator first if you are retiring the sandbox
feature; do not "temporarily" replace the proxy by mounting `/var/run/docker.sock` into the
orchestrator, because that hands it root on the host permanently.

## Troubleshooting

**Tasks fail at exactly ten minutes**
The startup timeout patch did not apply, so `dockerbackend` is running with the image's inherited
`timeout server 10m` and the `/wait` and `/logs` streams are being cut. The most likely cause is a
newer image that renamed the `backend dockerbackend` stanza, which makes the `sed` a silent no-op.
Dump the running configuration and look at what the backends are actually called:

```bash
sudo docker cp socket-proxy:/tmp/haproxy.cfg /tmp/h.cfg
grep -n '^backend\|timeout' /tmp/h.cfg
```

Re-target the `sed` address in the startup command at the new stanza name and recreate the
container, then confirm with the Step 3 check. The proxy's own log will corroborate the diagnosis:
look for a `/wait` request with a duration near `600000` ms and the termination flag `sD`.

**The orchestrator logs a connection error to `socket-proxy` when a task starts**
Either the consuming container is not attached to `docker-api`, or the proxy is down. Check both:

```bash
sudo docker inspect <container> --format '{{json .NetworkSettings.Networks}}'
sudo docker ps -a --filter 'name=^socket-proxy$'
```

An attachment made with `docker network connect` is lost whenever the consumer is recreated.

**`403 Forbidden` for an operation you expect to work**
The matching environment variable is `0`. That is intentional for `EXEC`, `BUILD`, `COMMIT` and the
whole Swarm / system / secrets set. Do not flip one to `1` to unblock a workflow — decide first
whether every workflow that will ever run should hold that capability over the host, because they
all will.

**A denied-endpoint probe returns `404` instead of `403`**
You probed `/containers/<id>/exec`. That path sits under the permitted `/containers` prefix, so it
is forwarded to the daemon and the daemon answers `404` because the container id does not exist. The
proxy is fine. Probe `/exec/<id>/start` or `/secrets` instead — those are refused with `403` by the
proxy itself, before the daemon ever sees them.

**The proxy container restarts in a loop**
HAProxy failed to parse its configuration, or the startup command exited. Read the logs:

```bash
sudo docker logs socket-proxy
```

A parse error names the offending line. If the logs are empty and the container exits with status
`0`, the `-db` flag is missing from the startup command — HAProxy daemonised, the foreground process
ended, and Docker considers the container finished.

**Permission denied on `/var/run/docker.sock`**
The Docker daemon is not running, or the socket is at a different path on this host. Confirm with
`ls -l /var/run/docker.sock` and `sudo systemctl status docker`. The mount path in Step 2 is fixed;
there is no setting to relocate it.

**The proxy is reachable from another machine**
It never should be. Look for a `-p 2375:2375` on the container or an attachment to the shared
`proxy` network:

```bash
sudo docker inspect socket-proxy --format '{{json .NetworkSettings.Ports}} {{json .NetworkSettings.Networks}}'
```

Both are configuration errors that grant host-root-equivalent access to anyone who can reach that
address. Remove the port publish, disconnect the extra network, and recreate the container from
Step 2.
