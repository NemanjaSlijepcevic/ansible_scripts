# Claude Code Sandbox

## What this is

This is an **image**, not a running service. `claude-runner:latest` is a Docker image built once on the
automation host: a slim Node.js base with the Claude Code CLI installed and nothing else standing. It
has no long-lived container and no port. A workflow orchestrator's Docker task runner is what actually
uses it — every time a flow needs to run an agentic Claude Code task, the orchestrator asks the host's
Docker Engine to start a brand-new container from this image, the CLI does one piece of work inside
`/workspace`, and the container is removed the instant it exits.

That shape is deliberate, not incidental, and it changes how you think about the whole guide:

- **There is nothing to restart.** "Is the service up" is the wrong question — there is no daemon to be
  up or down. The only things that persist are the image itself and one directory holding a login
  session.
- **There is nothing to check with `docker ps` in steady state.** A container only exists for the
  seconds or minutes a task takes to run. If you see one, a task is in flight.
- **Isolation is the whole security model.** Each task gets a throwaway, unprivileged, resource-capped
  container on a network that can reach the open internet (for the Anthropic API) and nothing on your
  internal network. There is no standing process to compromise, only a brief window per task.

This is why the Claude Code CLI is not driven directly by the orchestrator's own built-in chat plugin: a
built-in "call the Anthropic API and get a chat completion" plugin is exactly that — one request, one
response, no tool use, no file edits, no shell commands. Agentic work — reading a repository, editing
files, running commands, iterating — needs the real CLI running with tool permissions, which only makes
sense inside a container you can throw away afterward. Hence this image, launched as a plain command
inside a Docker task rather than through any AI-specific plugin.

Runs on: the automation host, alongside the workflow orchestrator and its filtered Docker API gateway.
Talks to: the Anthropic API over the open internet — and nothing else, by network design, not by
configuration you have to get right.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

**Outbound HTTPS works from a container**

The CLI needs to reach the Anthropic API, both for the one-time login and for every task afterward.

```bash
docker run --rm curlimages/curl -sf -o /dev/null -w '%{http_code}\n' https://api.anthropic.com
```

**You have a Claude account you can log into interactively, once**

The image authenticates by OAuth (the same device/browser login flow the CLI uses anywhere else). That
flow needs a terminal, so budget five minutes at a keyboard for Step 4 below — it cannot be scripted or
delegated to an orchestrator.

**You have decided the sandbox network's address range**

Pick a subnet that is not used anywhere else on this host — not the shared bridge network the rest of
your services sit on, and not any other isolated network you may already have created for a similar
purpose. Any private range works; there is nothing else on it to collide with.

## Setup

### Overview

1. Create the host directories the sandbox mounts at runtime.
2. Write the Dockerfile and build the image.
3. Create the isolated `sandbox` network.
4. Log in once, interactively, so the OAuth session persists.
5. Confirm a task container can actually run unattended, the way the orchestrator will run it.

---

#### Step 1: Create the host directories

```bash
sudo mkdir -p ./data/claude-runner/home ./data/claude-runner/workspace ./data/claude-runner/build
sudo chown -R <puid>:<pgid> ./data/claude-runner/home ./data/claude-runner/workspace
sudo chmod 0755 ./data/claude-runner/home ./data/claude-runner/workspace
sudo chown <username>:<pgid> ./data/claude-runner/build
sudo chmod 0755 ./data/claude-runner/build
```

**Explanation**: `home` and `workspace` are bind-mounted into every task container at `/home/node` and
`/workspace`. `home` is what makes the OAuth login from Step 4 durable — the CLI writes its session
token under the home directory of whichever user runs it, and since every task container is destroyed on
exit, that token has to live on the host instead, or every single task would demand a fresh interactive
login. `workspace` is where a task's input files land and where the CLI does its work; a flow stages
files there before the container starts and collects them after it exits. `<puid>` is `1000`, fixed by
the Dockerfile's base image (Step 2) — it is not a value you choose, it must match the `node` user the
image runs as, or the container cannot write into either directory it was just handed.

---

#### Step 2: Write the Dockerfile and build the image

```bash
sudo tee ./data/claude-runner/build/Dockerfile >/dev/null <<'EOF'
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

USER node
WORKDIR /workspace

ENTRYPOINT []
CMD ["claude", "--help"]
EOF

sudo docker build -t claude-runner:latest ./data/claude-runner/build
```

**Explanation**: The package list is deliberately narrow — `git`, `curl`, `jq`, `python3` and `procps`
cover the kinds of tasks a coding agent is actually asked to do (repository operations, calling an API,
light scripting, reading process state), not a general-purpose toolbox. `USER node` switches to the
image's built-in unprivileged user (uid `1000`) for every instruction after it, so nothing the CLI does
inside a task container ever runs as root — this is the first of several independent layers of
containment; Step 5 adds the rest at the point where a task container is actually launched.
`ENTRYPOINT []` clears the base image's own npm entrypoint wrapper, so a plain
`docker run claude-runner:latest claude -p "..."` invokes the CLI directly instead of being wrapped by
something that changes how its arguments are parsed. The default `CMD` is harmless on its own — running
the image with no arguments just prints help text — which matters because it means an accidental bare
`docker run claude-runner:latest` does nothing destructive.

---

#### Step 3: Create the isolated sandbox network

```bash
sudo docker network create --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway-ip> \
  sandbox
```

**Explanation**: This network is a normal bridge with the usual NAT path to the internet — unlike a
Docker API gateway's network, it is **not** created `--internal`, because a task container genuinely
needs to reach `api.anthropic.com`. Isolation here comes entirely from what this network is *not*
connected to: it is never attached to the bridge network your other services live on, so a task container
has literally no route to anything internal — not because a firewall rule blocks it, but because there is
no network path to be blocked. If you later want to restrict egress further (for instance, allowing only
the Anthropic API's addresses out), that has to be done with host firewall rules against this subnet;
nothing here does it for you.

---

#### Step 4: Log in once, interactively

```bash
sudo docker run -it --rm \
  --network sandbox \
  -v "$(pwd)/data/claude-runner/home:/home/node" \
  claude-runner:latest claude
```

Follow the login prompt — it will give you a URL or a device code to complete in a browser. Once it
reports success, exit the CLI.

**Explanation**: `-it` gives the container a real terminal, which is the one thing an unattended task
container will never have, and which is exactly why this step cannot be folded into an automated
deployment — the moment this container exits, its filesystem is gone (`--rm`), but the token the CLI just
wrote lives on the bind-mounted `home` directory, so every future task container that mounts the same
path inherits the login without repeating it. No `workspace` mount is needed here; nothing is being
worked on, only authenticated.

---

#### Step 5: Confirm a task container runs the way the orchestrator will run it

```bash
docker run --rm \
  --network sandbox \
  --memory <memory-limit> \
  --cpus <cpu-limit> \
  --pids-limit <pids-limit> \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v "$(pwd)/data/claude-runner/home:/home/node" \
  -v "$(pwd)/data/claude-runner/workspace:/workspace" \
  -w /workspace \
  claude-runner:latest claude -p "say hello" --output-format json \
  --dangerously-skip-permissions
```

**Explanation**: `--memory`, `--cpus` and `--pids-limit` bound what one task can consume, so a runaway or
malicious flow cannot starve the host — the orchestrator applies limits like these to every task
container it spawns from this image. `--security-opt no-new-privileges --cap-drop ALL` removes every
Linux capability beyond the unprivileged default and blocks any path back to privilege through a setuid
binary; combined with the non-root `USER node` baked into the image, a task container that were somehow
broken out of would still have nothing to escalate with. `--dangerously-skip-permissions` is required for
any unattended run: the CLI's normal behaviour is to pause and ask a human before editing a file or
running a shell command, and a headless container has no terminal to ask through, so without this flag
every task simply hangs. That flag is acceptable **only** inside a sandbox shaped exactly like this one —
unprivileged, capability-dropped, resource-capped, and on a network with no route to anything internal.
Never pass it to a `claude` process running directly on a host, or in any container that still has a path
to a real service. Volume sources here are host paths (`$(pwd)/data/...`), which matters once this is
launched by an orchestrator rather than by hand: if the orchestrator reaches the Docker Engine through a
filtered API gateway rather than a socket mounted into its own container, that gateway forwards to the
**host's** daemon, and the host daemon resolves bind-mount sources against the **host** filesystem, not
the orchestrator's own container filesystem — so the path an orchestrator's task definition gives here is
always a host path, never a path relative to wherever the flow definition itself lives.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<username>` / `<pgid>` | Owner of the build directory | The deploy account and the `docker` group | Step 1 |
| `<puid>` | Owner of `home`/`workspace` | Fixed at `1000` by the base image's built-in `node` user — not a free choice | Step 1 |
| `<docker-subnet>` / `<docker-gateway-ip>` | Address range for the isolated `sandbox` network | Any private range not already used by another Docker network on this host | Step 3 |
| `<memory-limit>` / `<cpu-limit>` / `<pids-limit>` | Per-task resource ceiling | Size to the largest task you expect; `2g` / `1.5` / `512` are reasonable starting points | Step 5 |

## Verification

```bash
# the image exists
docker images claude-runner:latest

# the sandbox network exists, is not internal, and is not the same network as your other services
docker network inspect sandbox --format '{{.IPAM.Config}}'

# the OAuth session persisted after Step 4
sudo ls -la ./data/claude-runner/home

# a headless task actually completes
docker run --rm --network sandbox \
  -v "$(pwd)/data/claude-runner/home:/home/node" \
  claude-runner:latest claude -p "say hello" --output-format json \
  --dangerously-skip-permissions

# the sandbox genuinely has no route to an internal service (expect a timeout or connection refused,
# never a response) — substitute a container name and port that exist on your internal network
docker run --rm --network sandbox curlimages/curl -m 3 -s -o /dev/null -w '%{http_code}\n' \
  http://<container>:<port>
```

## Updating & day-to-day

**Rebuild the image** after changing the Dockerfile, or to pick up a newer Claude Code CLI release:

```bash
sudo docker build --pull --no-cache -t claude-runner:latest ./data/claude-runner/build
```

Nothing needs to be "recreated" the way a long-lived container does — every future task launches fresh
from whatever the `claude-runner:latest` tag currently points at, so a rebuild takes effect on the very
next task with no further action.

**Reading a task's output after the fact.** A task container removes itself (`--rm`) the moment it exits,
so there is no `docker logs` to go back to once it is gone. If you need to inspect a failure, rerun the
same command without `--rm` and pull the logs before removing it by hand:

```bash
docker run --network sandbox ... claude-runner:latest claude -p "<task>" ...
docker logs <container-id>
docker rm <container-id>
```

**The workspace is shared, not per-task.** Every task container mounts the same host `workspace`
directory, so files one task leaves behind are visible to the next. Clear it between unrelated tasks if
that matters to you:

```bash
sudo rm -rf ./data/claude-runner/workspace/*
```

**Rotating the login.** There is no expiry to plan around beyond whatever the CLI's own OAuth session
lifetime is; if a task starts failing with an authentication error, repeat Step 4.

## Rollback / Uninstall

```bash
sudo docker rmi claude-runner:latest
sudo docker network rm sandbox
sudo rm -rf ./data/claude-runner
```

**Warning**: removing `./data/claude-runner/home` destroys the OAuth login — Step 4 has to be repeated
after recreating it. Removing `./data/claude-runner/workspace` destroys any files a flow left staged
there. Only remove the `sandbox` network if nothing else still uses it — an Ansible sandbox image built
alongside this one typically shares the same network.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Task fails with an authentication or login error | The OAuth session in `./data/claude-runner/home` is missing, expired, or the volume was not mounted. Repeat Step 4 and confirm the `-v .../home:/home/node` mount is present in whatever invocation the task used. |
| Task container has no internet access | Confirm `sandbox` was created without `--internal` (Step 3), and that the host's outbound firewall/NAT rules do not block the subnet. |
| Task container can reach something it shouldn't be able to | It should only ever be attached to `sandbox`. If it shows up on any other network, whatever launched it overrode `--network` — that is a mistake in the caller, not something this image or network permits by default. |
| `pull access denied` or "image not found" | This image is built locally and never pulled from a registry. Confirm Step 2 completed and `docker images claude-runner:latest` lists it on this host — pulling it from anywhere else will not work. |
| Task is killed with an out-of-memory or process-limit error on a legitimate task | The per-task ceilings in Step 5 are too tight for what you are asking it to do. Raise `<memory-limit>` / `<cpu-limit>` / `<pids-limit>` for future tasks; these are per-container limits, not a host-wide setting. |
| Task hangs forever and never completes | Almost always a missing `--dangerously-skip-permissions` — the CLI is waiting on a terminal that does not exist in a headless container. Confirm the flag is present in the invocation. |
