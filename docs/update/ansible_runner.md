# Role: ansible_runner

## Purpose

Builds the `ansible-runner:latest` Docker image used as an **ephemeral sandbox** for running `ansible-playbook` itself — i.e. this repository's own `client/` and `update/` playbooks — on behalf of Kestra flows (via its `io.kestra.plugin.ansible.cli.AnsibleCLI` task, which takes this image as `containerImage`). Like its sibling `claude_runner`, this role deploys no long-lived container: it only (1) builds the image, (2) prepares the host-path directories Kestra's Docker task runner mounts into each sandbox run, and (3) reuses the `sandbox` bridge network created by the `claude_runner` role.

The design intent: a Kestra flow (e.g. "redeploy `nas` on a schedule" or "run a playbook on demand from a webhook") talks to the host Docker daemon through the filtered `socket_proxy`, and launches a brand-new `ansible-runner` container per run. The container clones/updates this repo into a shared workspace, runs `ansible-playbook` against the production inventory over SSH, and disappears. There is no standing Ansible control node to compromise, and infrastructure-wide SSH access (the deploy key + vault password) is confined to a root-only directory that only the automation host's Docker daemon — invoked only by Kestra behind Authelia 2FA — can mount.

## Prerequisites

- `common` role must have run (Docker Engine installed).
- `claude_runner` role must have run first — it creates the `sandbox` bridge network this role's containers attach to. `ansible_runner` itself does not create that network.
- `socket_proxy` role should exist alongside this one — it's what lets Kestra *invoke* the image this role builds; `ansible_runner` itself doesn't depend on it to build.
- Consumed by: Kestra flows, whose `AnsibleCLI` / Docker task runner tasks reference `ansible-runner:latest` (`containerImage`) and the `sandbox` network (`networkMode`) by name.
- The target hosts (`primary_nas`, `primary_server`, `primary_monitor`, etc.) must already trust the deploy SSH key referenced by their inventory's `ansible_private_key_file` — this role does not distribute that key, it only provides a place to mount it.
- A deploy SSH private key and the `pass.file` Ansible Vault password must be copied into `./data/ansible-runner/secrets` **manually** (e.g. via `scp`) — never through git, never through an Ansible task. See Step 2.
- A one-time `git clone` of this repository into the shared workspace must be performed manually after the image is built — see Step 4 — before any flow can run a playbook.
- Variables: `ansible_runner.*`, `claude_runner.network` (reused — the runner attaches to the same isolated network the Claude Code sandbox uses), `claude_runner.uid` (reused — the workspace directory is owned by the same in-container uid the Claude Code sandbox uses, so file permissions line up across the two roles' bind mounts), `user.name` / `user.group` (owns the build directory).

## Manual Execution Guide

### Overview

1. Create the workspace, secrets, and image build directories.
2. Manually copy in the deploy SSH key and vault `pass.file` (outside Ansible).
3. Copy the Dockerfile and build the `ansible-runner:latest` image (Python + `ansible-core` + collections, non-root-capable via SSH).
4. Clone this repository into the shared workspace (one-time).
5. (Reference only, executed by Kestra at flow run time, not by this role) launch an ephemeral playbook run.

### Step-by-Step Instructions

#### Step 1: Create data directories

**Purpose**: `/workspace` is where the runner checks out this Git repository and runs `ansible-playbook` from — it must persist across ephemeral container runs (so the repo isn't re-cloned every time) and is bind-mounted from the host. `secrets` holds the deploy SSH private key and the vault password file; it is kept root-only on the host and mounted read-only, one file at a time, into each task container. `build` holds the Dockerfile used to build the image.

**Commands**:
```bash
sudo mkdir -p ./data/ansible-runner ./data/ansible-runner/workspace
sudo chown -R 1000:docker ./data/ansible-runner ./data/ansible-runner/workspace
sudo chmod 0755 ./data/ansible-runner ./data/ansible-runner/workspace

sudo mkdir -p ./data/ansible-runner/secrets
sudo chown root:root ./data/ansible-runner/secrets
sudo chmod 0700 ./data/ansible-runner/secrets

sudo mkdir -p ./data/ansible-runner/build
sudo chown deploy:docker ./data/ansible-runner/build
sudo chmod 0755 ./data/ansible-runner/build
```

**Explanation**: Ownership uid `1000` on `workspace` matches `claude_runner.uid` — the same uid the `claude_runner` role uses for its own shared data directories — so files the runner writes are readable/writable across containers that share the mount. `secrets` is deliberately `root:root 0700`: nothing inside a regular container process (even one running as root *inside* its own namespace) can read it unless the host's Docker daemon is explicitly told to mount an individual file, and only a caller with access to the Docker socket (i.e. `socket-proxy`, gated to Kestra behind Authelia) can issue that `docker run`.

---

#### Step 2: Manually place secrets (outside Ansible)

**Purpose**: The runner needs an SSH private key to authenticate to every managed host as `ansible_private_key_file` in the inventory expects, plus the Ansible Vault password to decrypt any vaulted variables. Because these grant infrastructure-wide SSH access, this role deliberately does **not** template, copy, or otherwise manage them — you place them by hand, once, directly on the automation host.

**Commands** (run from your workstation, not through Ansible):
```bash
scp <key-name>.ppk deploy@<ip-address>:/tmp/<key-name>.ppk
scp pass.file deploy@<ip-address>:/tmp/pass.file

# On the automation host:
ssh deploy@<ip-address>
sudo mv /tmp/<key-name>.ppk /tmp/pass.file ./data/ansible-runner/secrets/
sudo chown root:root ./data/ansible-runner/secrets/<key-name>.ppk ./data/ansible-runner/secrets/pass.file
sudo chmod 0600 ./data/ansible-runner/secrets/<key-name>.ppk ./data/ansible-runner/secrets/pass.file
```

**Explanation**: `<key-name>.ppk` is the private key referenced by `ansible_private_key_file` in the production inventory for the hosts this runner will manage. `pass.file` is the same Ansible Vault password file used interactively (`--vault-password-file pass.file`) elsewhere in this repository's workflow. Both land in the root-only `secrets` directory created in Step 1 and are mounted read-only into individual task containers at run time (Step 5) — never baked into the image, never committed, never touched by a `copy`/`template` task.

---

#### Step 3: Build the runner image

**Purpose**: Produce an image with `ansible-core`, the Galaxy collections this repository's roles depend on (`community.docker`, `community.general`, `community.postgresql`, `community.crypto`, `ansible.posix`), and the OS-level tools (`git`, `openssh-client`, `rsync`, `sshpass`) needed to clone the repo and connect to managed hosts over SSH.

**Commands**:
```bash
sudo cp update/roles/ansible_runner/files/Dockerfile ./data/ansible-runner/build/Dockerfile
sudo docker build -t ansible-runner:latest ./data/ansible-runner/build
```

Dockerfile contents (for reference):
```dockerfile
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        rsync \
        sshpass \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible-core passlib

# Collections used across client/ and update/ playbooks.
RUN ansible-galaxy collection install \
    community.docker \
    community.general \
    community.postgresql \
    community.crypto \
    ansible.posix

# Ephemeral container — no persistent known_hosts.
ENV ANSIBLE_HOST_KEY_CHECKING=False

WORKDIR /workspace

CMD ["ansible-playbook", "--version"]
```

**Explanation**: `passlib` is installed alongside `ansible-core` because some roles in this repository (e.g. user-creation tasks) use Ansible's `password_hash` Jinja2 filter, which depends on it. The five Galaxy collections cover every non-builtin module this repository's roles use (Docker, generic community modules, PostgreSQL, TLS/crypto, POSIX ACLs/mounts). `ENV ANSIBLE_HOST_KEY_CHECKING=False` disables strict host-key checking — each container is thrown away after one run and never accumulates a `known_hosts` file, so there is nothing to persist a TOFU (trust-on-first-use) fingerprint into; this trades host-key pinning for the ephemeral-container model (see Troubleshooting for the risk this accepts). There is no `USER` directive — the container runs as root by default so it can read the mounted key file and manage remote hosts as `{{ user.name }}` over SSH, but it is still confined by `--security-opt no-new-privileges` and the isolated `sandbox` network at run time (Step 5).

---

#### Step 4: Clone the repository into the shared workspace (one-time)

**Purpose**: `ansible-playbook` needs a checked-out copy of this repository to run against. Doing the initial clone once (rather than on every ephemeral run) means later runs only need a fast `git pull`, and the checkout survives container removal because it lives on the bind-mounted `workspace` volume.

**Commands**:
```bash
sudo docker run --rm \
  --network sandbox \
  -v $(pwd)/data/ansible-runner/workspace:/workspace \
  -w /workspace \
  ansible-runner:latest \
  git clone <repo-url> ansible_scripts
```

**Explanation**: The clone lands at `./data/ansible-runner/workspace/ansible_scripts` on the host, which is why the reference invocation in Step 5 sets its working directory to `/workspace/ansible_scripts/update`. Subsequent updates (pulling in new roles/playbook changes before a run) are done the same way with `git -C ansible_scripts pull` in place of `git clone`.

---

#### Step 5: (Reference) how Kestra launches a playbook run

**Purpose**: This role builds the image and prepares the network/directories; it does **not** run playbooks itself. This is documented here for operators debugging or manually reproducing what a Kestra `AnsibleCLI` / Docker task runner task does at runtime, via the socket proxy (`tcp://socket-proxy:2375`).

**Commands**:
```bash
docker run --rm \
  --network sandbox \
  --security-opt no-new-privileges \
  -v <deploy-dir>/data/ansible-runner/workspace:/workspace \
  -v <deploy-dir>/data/ansible-runner/secrets/<key-name>.ppk:/root/<key-name>.ppk:ro \
  -v <deploy-dir>/data/ansible-runner/secrets/pass.file:/secrets/pass.file:ro \
  -w /workspace/ansible_scripts/update \
  ansible-runner:latest \
  ansible-playbook <host>.yml --vault-password-file /secrets/pass.file
```

**Explanation**:
- `--network sandbox` — the same isolated bridge network `claude_runner` creates. It gives the container outbound reach to every managed host over SSH (via the automation host's normal NAT egress — there is no route to `<ip-address>`-space that isn't also reachable from the host itself) while keeping it off the `proxy` network like the Claude Code sandbox.
- **Volume sources are host paths**, not the caller's paths — this only works because the call goes out through `socket-proxy`, which talks to the **host** Docker daemon; the daemon resolves `-v <deploy-dir>/...` against the host filesystem, not the Kestra container's filesystem. `<deploy-dir>` is the `update/` playbook's working directory on the automation host (e.g. `/home/deploy/update`).
- `-v .../secrets/<key-name>.ppk:/root/<key-name>.ppk:ro` — the key mounts specifically at `/root/<key-name>.ppk` because the production inventory's `ansible_private_key_file` points there; this path must match whatever the inventory declares.
- `-v .../secrets/pass.file:/secrets/pass.file:ro` — the Vault password file, mounted read-only and referenced with `--vault-password-file` exactly as it would be run interactively from a workstation.
- `-w /workspace/ansible_scripts/update` — matches `update/ansible.cfg`'s default inventory path (`inventories/production/hosts.yml`), so the playbook picks it up automatically, same as running it by hand from that directory.
- `<host>.yml` is whichever playbook the workflow targets (`nas.yml`, `server.yml`, `monitor.yml`, `postgres.yml`, `automation.yml`, etc.); `--limit`/`--tags` can be appended the same way they would be on the command line.
- No `--memory`/`--cpus`/`--pids-limit` ceilings are baked into this role's reference command (unlike `claude_runner`) — a workflow author invoking this image should still consider adding them, since a full playbook run against several hosts can be longer-lived than a single Claude Code task.

---

## Configuration Reference

### Default Variables

| Variable | Default Value | Description |
|----------|--------------|-------------|
| `ansible_runner.image` | `ansible-runner:latest` | Image name:tag built by this role and referenced by Kestra flows |
| `claude_runner.network` | `sandbox` | Name of the isolated bridge network (created by the `claude_runner` role; reused here, not owned by this role) |
| `claude_runner.uid` | `1000` | In-container uid; owns `./data/ansible-runner/workspace` |
| `user.name` / `user.group` | `deploy` / `docker` | Ownership for the build directory |

### Templates & Configuration Files

None. `files/Dockerfile` is a static file copied verbatim to `./data/ansible-runner/build/Dockerfile` (see Step 3) — there is no `templates/` directory for this role.

## Handlers & Service Management

This role defines no handlers and manages no long-lived service/container — there is nothing to "restart." Image rebuilds are driven by Ansible's `docker_image` `force_source` parameter, tied to the Dockerfile copy task (`ansible_runner_dockerfile.changed`) reporting a change (same pattern as `claude_runner`). After rebuilding the image, no running container needs to be recreated, since runs are always launched fresh from the current image tag by Kestra at flow-run time.

## Verification

```bash
sudo docker images ansible-runner:latest

# Confirm the shared sandbox network exists (created by claude_runner, not this role)
sudo docker network inspect sandbox --format '{{.IPAM.Config}}'

# Confirm the secrets directory is root-only
sudo stat -c '%a %U:%G' ./data/ansible-runner/secrets

# Confirm the repo checkout is present after Step 4
sudo ls ./data/ansible-runner/workspace/ansible_scripts

# Dry-run a playbook end-to-end using the same invocation Kestra would use
sudo docker run --rm \
  --network sandbox \
  --security-opt no-new-privileges \
  -v $(pwd)/data/ansible-runner/workspace:/workspace \
  -v $(pwd)/data/ansible-runner/secrets/<key-name>.ppk:/root/<key-name>.ppk:ro \
  -v $(pwd)/data/ansible-runner/secrets/pass.file:/secrets/pass.file:ro \
  -w /workspace/ansible_scripts/update \
  ansible-runner:latest \
  ansible-playbook <host>.yml --vault-password-file /secrets/pass.file --check
```

## Rollback / Uninstall

```bash
sudo docker rmi ansible-runner:latest
# Does NOT remove the sandbox network — owned by claude_runner; only remove it
# there if both roles are being torn down.

# Destroys the repo checkout and any files left in the shared workspace:
sudo rm -rf ./data/ansible-runner/workspace

# Destroys the deploy key and vault password copy — irreversible, re-copy from Step 2 if needed:
sudo rm -rf ./data/ansible-runner/secrets
```

**Warning**: Removing `./data/ansible-runner/secrets` deletes the only copy of the deploy SSH key and vault password held on the automation host — confirm you can re-`scp` them from a trusted source before doing this. Removing `./data/ansible-runner/workspace` just costs a re-clone (Step 4).

## Troubleshooting

**Task container fails with `Permission denied (publickey)`**
Confirm `./data/ansible-runner/secrets/<key-name>.ppk` exists, is `0600`, and matches the public key already authorized on the target host's `~/.ssh/authorized_keys` for `{{ user.name }}`. Confirm the `docker run` invocation mounts it at the exact path `ansible_private_key_file` expects in the inventory (typically `/root/<key-name>.ppk`).

**Task container fails with a Vault decryption error**
`--vault-password-file /secrets/pass.file` must point at the in-container mount path, not the host path — confirm the `-v .../pass.file:/secrets/pass.file:ro` mount is present and the file's content matches the password used elsewhere with `--vault-password-file pass.file`.

**`ansible-playbook: command not found` or module import errors**
The image wasn't rebuilt after a Dockerfile change, or the build failed partway through the `pip`/`ansible-galaxy` layers silently in CI. Re-run Step 3 and check `docker build` output for errors; verify with `docker run --rm ansible-runner:latest ansible-playbook --version` and `ansible-galaxy collection list`.

**Playbook can't find the inventory / uses the wrong hosts file**
Confirm `-w /workspace/ansible_scripts/update` is set — `update/ansible.cfg` only auto-selects `inventories/production/hosts.yml` when the working directory is `update/`. Running from the workspace root or from inside `ansible_scripts/` (without `/update`) will silently use Ansible's built-in defaults instead.

**No route to the managed host / SSH connection times out**
The `sandbox` network is a normal (non-`internal`) bridge with NAT egress, so this is almost always a host-level firewall or routing issue rather than a Docker networking one — compare against `claude_runner`'s Troubleshooting section, which documents the same network. Confirm the target host's UFW rules (see the `common` role) permit SSH from the automation host's egress IP.

**Known-host / MITM risk from `ANSIBLE_HOST_KEY_CHECKING=False`**
This is an accepted trade-off of the ephemeral-container model (no container lives long enough to build a trustworthy `known_hosts`), not a bug — the mitigating control is that the `sandbox` network only reaches hosts inside this project's own infrastructure over routes the automation host's egress already trusts. Do not "fix" this by baking a `known_hosts` file into the image; if stronger guarantees are needed, mount a pre-populated `known_hosts` from the `secrets` directory instead and set `ANSIBLE_HOST_KEY_CHECKING=True`.
