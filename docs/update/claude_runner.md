# Role: claude_runner

## Purpose

Builds the `claude-runner:latest` Docker image used as an **ephemeral sandbox** for running the Claude Code CLI on behalf of Kestra flows. This role deploys no long-lived container — it only (1) builds the image, (2) prepares the host-path directories Kestra's Docker task runner mounts into each sandbox run, and (3) creates a dedicated `sandbox` bridge network with its own subnet, isolated from every other Docker network in this project.

The design intent: Kestra's Docker task runner, talking to the host Docker daemon through the filtered `socket_proxy`, launches a brand-new `claude-runner` container per task, the container does its work in `/workspace`, and it disappears. There is no standing Claude Code process to compromise, and the sandbox network gives it outbound internet access (for the Anthropic API) without any route to Postgres, Traefik, Authelia, or any other internal service.

## Prerequisites

- `common` role must have run (Docker Engine installed).
- `socket_proxy` role should exist alongside this one — it's what actually lets Kestra *invoke* the image this role builds; `claude_runner` itself doesn't depend on it to build.
- Consumed by: Kestra flows, whose Docker task runner tasks reference `claude-runner:latest` (`containerImage`) and the `sandbox` network (`networkMode`) by name.
- A one-time interactive Claude Code login (subscription OAuth) must be performed manually after the image is built — see Step 3 — before any flow can successfully invoke `claude -p ...` unattended.
- Variables: `claude_runner.*` (including `claude_runner.uid`, the in-container `node` uid that owns the bind-mounted home/workspace).

## Manual Execution Guide

### Overview

1. Create the sandbox's home/workspace directories and the image build directory.
2. Copy the Dockerfile and build the `claude-runner:latest` image (Node.js base + Claude Code CLI, non-root).
3. Create the isolated `sandbox` bridge network with its own subnet/gateway.
4. Perform a one-time interactive login so the OAuth session persists in the `home` volume.
5. (Reference only, executed by Kestra at flow run time, not by this role) launch ephemeral task containers.

### Step-by-Step Instructions

#### Step 1: Create data directories

**Purpose**: `/home/node` inside the sandbox holds the Claude Code CLI's config and OAuth session token — it must persist across ephemeral container runs, so it's bind-mounted from the host. `/workspace` is where the CLI actually operates; flows can stage input files and collect output files there via bind mounts.

**Commands**:
```bash
sudo mkdir -p ./data/claude-runner/home ./data/claude-runner/workspace ./data/claude-runner/build
sudo chown -R 1000:docker ./data/claude-runner/home ./data/claude-runner/workspace
sudo chmod 0755 ./data/claude-runner/home ./data/claude-runner/workspace
sudo chown deploy:docker ./data/claude-runner/build
sudo chmod 0755 ./data/claude-runner/build
```

**Explanation**: Ownership uid `1000` (`claude_runner.uid`) matches the image's `node` user (see Step 2), so files the sandbox writes into the bind-mounted `home`/`workspace` directories stay readable/writable across runs.

---

#### Step 2: Build the sandbox image

**Purpose**: Produce a minimal, non-root image with just enough tooling (git, curl, jq, python3) plus the Claude Code CLI itself for the kinds of tasks workflows are expected to run (repo operations, API calls, light scripting).

**Commands**:
```bash
sudo cp update/roles/claude_runner/files/Dockerfile ./data/claude-runner/build/Dockerfile
sudo docker build -t claude-runner:latest ./data/claude-runner/build
```

Dockerfile contents (for reference):
```dockerfile
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Sandbox tasks run as the unprivileged node user (uid 1000); OAuth
# credentials persist in the /home/node volume mounted at runtime.
USER node
WORKDIR /workspace

ENTRYPOINT []
CMD ["claude", "--help"]
```

**Explanation**: `USER node` (uid `1000`, baked into the `node:22-bookworm-slim` base image) means every task container runs unprivileged from the start — combined with the runtime flags in Step 5 (`--cap-drop ALL`, `--security-opt no-new-privileges`), this is defense in depth: even if the Docker-level isolation were somehow bypassed, the process inside has no root and no elevatable capabilities. `ENTRYPOINT []` clears the base image's npm entrypoint so `docker run ... claude-runner:latest claude -p "..."` invokes the CLI directly rather than being wrapped.

---

#### Step 3: Create the isolated sandbox network

**Purpose**: Give sandbox containers outbound internet access (needed to reach `api.anthropic.com`) while keeping them off the `proxy` network — no sandbox container can ever reach Traefik, Postgres, Authelia, or any other internal service by design, because it's simply never attached to those networks.

**Commands**:
```bash
sudo docker network create --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway-ip> \
  sandbox
```

**Explanation**: Unlike `docker-api` (the `socket_proxy` role's network), `sandbox` is **not** `--internal` — it needs the normal bridge NAT path to the internet. Isolation here comes from simply never connecting it to `proxy` or `docker-api`, not from blocking egress. If you need to further restrict egress (e.g. allow-list only `api.anthropic.com`), that has to be done with host firewall rules against this network's subnet — nothing in this role does that.

---

#### Step 4: One-time interactive login

**Purpose**: The Claude Code CLI in `claude-runner` authenticates via subscription OAuth. That login flow requires an interactive terminal, so it can't happen inside an unattended `docker run --rm` invocation from a workflow — do it once, by hand, and the resulting session token persists in the `home` volume for every future ephemeral run to reuse.

**Commands**:
```bash
sudo docker run -it --rm \
  --network sandbox \
  -v $(pwd)/data/claude-runner/home:/home/node \
  claude-runner:latest claude
```

**Explanation**: Follow the interactive login prompt (device-code / browser flow). Once complete, the CLI writes its credentials under `/home/node` — which is the bind-mounted host directory `./data/claude-runner/home` — so it survives container removal (`--rm`). No `-v .../workspace` mount is needed for login since no task is being run.

---

#### Step 5: (Reference) how Kestra launches a sandboxed task

**Purpose**: This role builds the image and prepares the network/directories; it does **not** run task containers itself. This is documented here for operators debugging or manually reproducing what a Kestra Docker task runner task does at runtime, via the socket proxy (`tcp://socket-proxy:2375`).

**Commands**:
```bash
docker run --rm \
  --network sandbox \
  --memory 2g \
  --cpus 1.5 \
  --pids-limit 512 \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v <deploy-dir>/data/claude-runner/home:/home/node \
  -v <deploy-dir>/data/claude-runner/workspace:/workspace \
  -w /workspace \
  claude-runner:latest claude -p "<task>" --output-format json \
  --dangerously-skip-permissions
```

**Explanation**:
- `--memory`/`--cpus`/`--pids-limit` come from `claude_runner.memory`/`claude_runner.cpus`/`claude_runner.pids_limit` and bound resource usage per task so a runaway or malicious flow can't starve the host.
- `--security-opt no-new-privileges --cap-drop ALL` — the container gets no Linux capabilities beyond the unprivileged default and can never regain privileges via setuid binaries.
- **Volume sources are host paths**, not the caller's paths — this only works because the task runner's Docker API calls go out through `socket-proxy`, which talks to the **host** Docker daemon; the daemon resolves `-v <deploy-dir>/...` against the host filesystem, not the Kestra container's filesystem. `<deploy-dir>` is the same path used throughout this manual (the `update/` playbook's working directory on the automation host, e.g. `/home/deploy/update`).
- `-p "<task>"` is the natural-language/task prompt; `--output-format json` makes the result machine-parseable for the flow to consume.
- `--dangerously-skip-permissions` is **required** for unattended runs — headless containers have no TTY on which the CLI could ask for tool-use approval, so without this flag any task needing file edits or shell commands stalls/fails. The flag is acceptable *only inside this sandbox*: the container is unprivileged (`--cap-drop ALL`, `no-new-privileges`), resource-capped, sees nothing but the mounted `home`/`workspace` host paths, and sits on a network with no route to internal services. Never use this flag for a `claude` process running directly on a host.

---

## Configuration Reference

### Default Variables

| Variable | Default Value | Description |
|----------|--------------|-------------|
| `claude_runner.image` | `claude-runner:latest` | Image name:tag built by this role and referenced by Kestra flows |
| `claude_runner.network` | `sandbox` | Name of the isolated bridge network |
| `claude_runner.subnet` | `172.20.1.0/24` | Subnet for the sandbox network (placeholder — see `<docker-subnet>` above) |
| `claude_runner.gateway` | `172.20.1.1` | Gateway for the sandbox network |
| `claude_runner.memory` | `2g` | Per-task container memory limit |
| `claude_runner.cpus` | `1.5` | Per-task container CPU limit |
| `claude_runner.pids_limit` | `512` | Per-task container process-count limit (guards against fork bombs) |
| `claude_runner.uid` | `1000` | In-container `node` user; owns `./data/claude-runner/{home,workspace}` |
| `user.name` / `user.group` | `deploy` / `docker` | Ownership for the build directory |

### Templates & Configuration Files

None. `files/Dockerfile` is a static file copied verbatim to `./data/claude-runner/build/Dockerfile` (see Step 2) — there is no `templates/` directory for this role.

## Handlers & Service Management

This role defines no handlers and manages no long-lived service/container — there is nothing to "restart." Image rebuilds are driven by Ansible's `docker_image` `force_source` parameter, tied to the Dockerfile copy task reporting a change. After rebuilding the image, no running container needs to be recreated, since task containers are always launched fresh from the current image tag by Kestra at flow-run time.

## Verification

```bash
sudo docker images claude-runner:latest
sudo docker network inspect sandbox --format '{{.IPAM.Config}}'
# Confirm it is NOT flagged internal and is NOT the "proxy" network.

# Confirm the OAuth session persisted after Step 4
sudo ls -la ./data/claude-runner/home
sudo docker run --rm --network sandbox \
  -v $(pwd)/data/claude-runner/home:/home/node \
  claude-runner:latest claude -p "say hello" --output-format json \
  --dangerously-skip-permissions

# Confirm sandbox containers cannot reach internal services (should fail/timeout)
sudo docker run --rm --network sandbox curlimages/curl -m 3 -s -o /dev/null -w '%{http_code}\n' http://socket-proxy:2375/version
```

## Rollback / Uninstall

```bash
sudo docker rmi claude-runner:latest
sudo docker network rm sandbox
# Destroys the persisted OAuth session and any files left in the shared workspace:
sudo rm -rf ./data/claude-runner
```

**Warning**: Removing `./data/claude-runner/home` destroys the OAuth login — Step 4 must be repeated after recreating it. Removing `./data/claude-runner/workspace` destroys any staged flow files on that shared host path.

## Troubleshooting

**Task containers fail with an authentication/login error**
The OAuth session in `./data/claude-runner/home` is missing, expired, or wasn't mounted. Re-run Step 4. Confirm the `-v .../home:/home/node` mount is present in the `docker run` invocation the workflow used.

**Task container has no internet access**
Confirm `sandbox` was created **without** `--internal` (Step 3) and that the host's outbound firewall/NAT rules aren't blocking the subnet. Compare against `docker-api` (the `socket_proxy` role's network), which is intentionally `--internal` — do not copy that flag here.

**Task container CAN reach an internal service it shouldn't**
It should only ever be attached to `sandbox`. If a task container shows up attached to `proxy` or `docker-api`, that's a bug in whatever invoked `docker run` (a workflow manually specifying the wrong `--network`) — the role's own network creation is correct by construction, but nothing stops a workflow author from overriding `--network` at call time; treat `--network sandbox` as a workflow-authoring convention to audit for, not an enforced boundary from the platform side.

**`docker: Error response from daemon: pull access denied` or image not found**
The image is built locally (`claude-runner:latest`) and is not pulled from a registry — confirm Step 2 completed and `docker images` on the automation host lists it. There is no `pull: true` semantic for this role's image.

**OOM-killed or `pids-limit` errors on legitimate tasks**
Increase `claude_runner.memory`/`claude_runner.cpus`/`claude_runner.pids_limit` in host_vars and re-run the role — these are per-task ceilings, not global daemon limits, so raising them only affects future sandbox invocations.
