# Role: socket_proxy

## Purpose

Deploys `tecnativa/docker-socket-proxy` as a filtered, read-only-ish gateway onto the host's Docker Engine API. It exists so that **Kestra never touches `/var/run/docker.sock` directly**. Instead, Kestra's Docker task runner talks to this proxy over an internal-only Docker network (`docker-api`), and the proxy re-exposes only the specific Docker API endpoints Kestra needs to launch and clean up sandboxed task containers (`claude-runner`, `ansible-runner`, script tasks).

This exists because giving any container direct access to the Docker socket is equivalent to giving it root on the host — a container with socket access can mount `/` from the host, create privileged containers, escape confinement, etc. The socket proxy narrows that blast radius to "can create/start/list/remove containers, pull images, inspect networks/volumes" and explicitly denies exec-into-container, image build, Swarm, secrets, and daemon-level system calls.

## Prerequisites

- `common` role must have run (Docker Engine installed and running).
- No Traefik/Authelia dependency — this role deploys no public-facing service and carries no Traefik labels.
- Variables: only the shared `user` dict (`user.name`, `user.group`) from `group_vars/all.yml`. The role intentionally takes **no** other configuration — the API scope is hard-coded in `tasks/main.yml` so it cannot be silently widened by inventory changes.
- Consumers: the `kestra` role sets `host: tcp://socket-proxy:2375` in its Docker task runner plugin defaults and joins the same `docker-api` network; the `claude_runner`/`ansible_runner` roles build the images that end up run *through* this proxy.

## Manual Execution Guide

### Overview

1. Create an **internal** Docker network (`docker-api`) that has no route to the outside world and is not the shared `proxy` network.
2. Start the `docker-socket-proxy` container on that network only, with a narrow API scope, bind-mounting the host socket read-only.

### Step-by-Step Instructions

#### Step 1: Create the internal `docker-api` network

**Purpose**: Isolate the proxy so only containers explicitly attached to `docker-api` (i.e. `kestra`) can reach it. `internal: true` means Docker does not add a default route out of this network — containers on it get no external connectivity through this network alone.

**Commands**:
```bash
sudo docker network create --internal docker-api
```

**Explanation**: `--internal` is the critical flag. Without it, this network behaves like any other bridge network with NAT to the internet, which would defeat the purpose of isolating the proxy. This network is deliberately **separate from `proxy`** (the shared Traefik network) — the socket proxy must never be reachable from the internet-facing service network.

---

#### Step 2: Start the docker-socket-proxy container

**Purpose**: Run the filtered API gateway with only the permissions Kestra's sandbox orchestration needs.

**Commands**:
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
  tecnativa/docker-socket-proxy:latest
```

**Explanation**:
- `-v /var/run/docker.sock:/var/run/docker.sock:ro` — the proxy itself needs socket access to translate HTTP calls into Docker API calls; it is mounted **read-only** at the bind-mount level (the proxy process still issues normal Docker API calls over it, `:ro` just stops the container from writing arbitrary files onto the socket path).
- `POST=1` plus `CONTAINERS=1`/`IMAGES=1`/`NETWORKS=1`/`VOLUMES=1` — allows the create/start/wait/logs/remove/pull lifecycle needed for `docker run --rm ...` style ephemeral containers, and lets clients list networks/volumes (needed to attach the sandbox network).
- `INFO=1`, `PING=1`, `VERSION=1` — harmless read-only daemon metadata endpoints used for health/connectivity checks.
- Everything set to `0` is explicitly denied: `EXEC` (no shelling into a running container), `BUILD`/`COMMIT` (no building or snapshotting images through the proxy — image builds happen locally via `community.docker.docker_image` on the host, not through this proxy), `SWARM`/`SERVICES`/`TASKS`/`NODES`/`SECRETS`/`CONFIGS`/`PLUGINS` (no Swarm surface at all), `SYSTEM` (no daemon-wide config/prune calls), `SESSION`/`DISTRIBUTION`/`AUTH` (no registry auth relay).
- No `-p`/port publish and no Traefik labels — the proxy is reachable **only** by its container DNS name (`socket-proxy`) from containers on the `docker-api` network. It has no business being reachable from the LAN or internet.

---

## Configuration Reference

### Default Variables

| Variable | Default Value | Description |
|----------|--------------|-------------|
| `user.name` | `deploy` | Owner used for any role-managed files (none currently written to disk by this role) |
| `user.group` | `docker` | Group used for any role-managed files |

No service-specific variables exist for this role — the API scope (which endpoints are `1`/`0`) is fixed directly in `tasks/main.yml` by design. Widening it widens what Kestra flows can do to the host Docker daemon, so it is treated as code, not inventory-tunable configuration.

### Templates & Configuration Files

None. This role has no `templates/` directory — the container is configured entirely through environment variables passed at `docker run` time.

## Handlers & Service Management

This role defines no handlers. The container runs with `restart_policy: unless-stopped` (Ansible) / `--restart unless-stopped` (manual), so it survives host reboots and Docker daemon restarts without any operator action. To pick up a scope change, recreate the container:

```bash
sudo docker stop socket-proxy && sudo docker rm socket-proxy
# re-run the docker run command from Step 2 with the updated env vars
```

## Verification

```bash
# Container is up and on the right (and only the right) network
sudo docker ps --filter name=socket-proxy
sudo docker inspect socket-proxy --format '{{json .NetworkSettings.Networks}}' | jq
# Expect only "docker-api" listed — never "proxy".

# Confirm the network is internal
sudo docker network inspect docker-api --format '{{.Internal}}'
# Expect: true

# Exercise the proxy from inside its own network (it is unreachable from the host directly)
sudo docker run --rm --network docker-api curlimages/curl -s http://socket-proxy:2375/version

# Confirm a denied endpoint is actually denied (expect HTTP 403)
sudo docker run --rm --network docker-api curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  http://socket-proxy:2375/containers/<container-id>/exec
```

## Rollback / Uninstall

```bash
sudo docker stop socket-proxy && sudo docker rm socket-proxy
sudo docker network rm docker-api
```

**Warning**: Removing this role breaks the `kestra` role's Docker task runner → sandbox flow (`tcp://socket-proxy:2375` will fail to resolve). Remove/adjust the `kestra`, `claude_runner`, and `ansible_runner` roles first if decommissioning the automation host's sandbox feature entirely.

## Troubleshooting

**Kestra logs a connection error to `socket-proxy` when a task starts**
The `kestra` container is not attached to the `docker-api` network, or the proxy container is down. Check `docker inspect kestra` for its networks and `docker ps` for the proxy's state.

**`403 Forbidden` from the proxy for an operation you expect to work**
The corresponding env var is set to `0`. Check the list in Step 2 — this is intentional for `EXEC`, `BUILD`, `COMMIT`, and all Swarm/system/secret endpoints. Do not flip these to `1` without understanding the security implication (see Purpose above); if a flow genuinely needs a currently-denied capability, treat that as a design review, not a quick config edit.

**Proxy container can be reached from outside the automation host**
It should never be publishable — there are no `-p` flags and no Traefik labels in this role. If you see it exposed, check for a manual `docker run` that added `-p 2375:2375` or attached it to the `proxy` network; both are configuration errors that grant host-root-equivalent access to anyone who can reach that port.

**Socket proxy container itself can't start / permission denied on `/var/run/docker.sock`**
Confirm the Docker daemon is running and `/var/run/docker.sock` exists on the host (`common` role prerequisite). The bind mount path is fixed; there is no variable to relocate it.
