# Ansible Sandbox

## What this is

This is an **image**, not a running service, and it is the closest sibling to the Claude Code sandbox
image: `ansible-runner:latest` is a Docker image built once on the automation host, with `ansible-core`
and a fixed set of Galaxy collections installed on a slim Python base. It has no long-lived container. A
workflow orchestrator's Docker task runner starts a fresh container from this image whenever a flow needs
to run `ansible-playbook`, the container checks out a project and runs a playbook against your managed
hosts over SSH, and the container is removed the instant it exits.

The reasoning is the same as for the Claude Code sandbox, and worth restating because it changes what
"is this working" means: there is nothing to keep running, so there is nothing to restart, and a healthy
steady state looks like **no** `ansible-runner` container existing at all. The only things that persist
between runs are the image, a shared workspace directory (so a project does not have to be re-cloned on
every single run), and a directory holding the one thing this image is never allowed to bake in: your
infrastructure's own SSH credentials.

Why a purpose-built image instead of a stock one: an orchestrator's own Ansible plugin typically ships a
generic default image, which has `ansible-core` but not the specific collections a given automation
project's playbooks import (`community.docker`, `community.postgresql`, and so on). Building your own
image once, with exactly the collections your project needs, means every run gets a consistent, complete
environment instead of failing partway through on a missing module.

Runs on: the automation host, alongside the workflow orchestrator, its filtered Docker API gateway, and
the Claude Code sandbox image. Talks to: whatever hosts your Ansible project manages, over SSH — nothing
else, and nothing it wasn't explicitly handed a key for.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

**The isolated `sandbox` network already exists**

This image's containers attach to the same isolated bridge network the Claude Code sandbox uses, rather
than owning one of its own — one throwaway-container network is enough. Confirm it is there:

```bash
docker network inspect sandbox --format '{{.IPAM.Config}}'
```

If it is missing, create it the same way it is created for that sandbox — any private range not already
used by another Docker network on this host:

```bash
sudo docker network create --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway-ip> \
  sandbox
```

**You have a deploy SSH private key already authorized on every host you intend to manage**

This image never generates or distributes SSH keys — it only provides somewhere to mount one you already
have. The public half must already be in `~/.ssh/authorized_keys` for the account your playbooks connect
as, on every target host.

```bash
ssh -i <ssh-key-file> <username>@<ip-address> true && echo "key works: ok"
```

**You have a Vault password file**, if your automation project encrypts any of its variables — the file
that would otherwise be passed with `--vault-password-file` when running a playbook by hand.

## Setup

### Overview

1. Create the workspace, secrets and build directories.
2. Copy the SSH key, Vault password file and any secret-store credentials onto the host by hand — never
   through this image, never committed anywhere.
3. Write the Dockerfile and build the image.
4. Clone your automation project into the shared workspace, once.
5. Confirm a playbook run actually completes, the way the orchestrator will run it.

---

#### Step 1: Create the host directories

```bash
sudo mkdir -p ./data/ansible-runner/workspace
sudo chown -R <puid>:<pgid> ./data/ansible-runner ./data/ansible-runner/workspace
sudo chmod 0755 ./data/ansible-runner ./data/ansible-runner/workspace

sudo mkdir -p ./data/ansible-runner/secrets/approle
sudo chown -R root:root ./data/ansible-runner/secrets
sudo chmod 0700 ./data/ansible-runner/secrets ./data/ansible-runner/secrets/approle

sudo mkdir -p ./data/ansible-runner/build
sudo chown <username>:<pgid> ./data/ansible-runner/build
sudo chmod 0755 ./data/ansible-runner/build
```

**Explanation**: `workspace` holds the checked-out project this image runs playbooks from, and it is
bind-mounted so the checkout survives a task container being destroyed — the alternative, re-cloning on
every run, would be slow and would hammer whatever hosts the repository. `<puid>` matches the uid the
Claude Code sandbox's shared directories use, purely so that if the two images' bind mounts ever need to
interoperate on the same host, file ownership lines up instead of one image writing files the other
cannot read. `secrets` is deliberately `root:root 0700` and separate from `workspace` — nothing inside an
ordinary container process can read it unless the Docker Engine is explicitly told, by a specific
`docker run` invocation, to bind-mount one specific file out of it. The set of things that can even issue
that `docker run` is itself narrow (typically only the orchestrator, reached only through its own
authentication), so this directory has exactly one path in: someone with root on this host, doing it on
purpose. The `approle` subdirectory holds the small credential files that let a run log into your secret
store; it is separate from the files above only so the whole directory can be mounted at once, since a
playbook expects to find them side by side under one path.

---

#### Step 2: Place the SSH key, Vault password and secret-store credentials by hand

Do this from your own workstation, outside any automation — it is the one step in this whole guide that
must never be scripted, because scripting it would mean the credential passed through some log or
history along the way.

```bash
scp <ssh-key-file> <username>@<ip-address>:/tmp/<ssh-key-file>
scp <vault-password-file> <username>@<ip-address>:/tmp/<vault-password-file>

ssh <username>@<ip-address>
sudo mv /tmp/<ssh-key-file> /tmp/<vault-password-file> ./data/ansible-runner/secrets/
sudo chown root:root ./data/ansible-runner/secrets/<ssh-key-file> ./data/ansible-runner/secrets/<vault-password-file>
sudo chmod 0600 ./data/ansible-runner/secrets/<ssh-key-file> ./data/ansible-runner/secrets/<vault-password-file>
```

If any playbook you intend to run reads values out of a secret store at deploy time, its login
credentials — a pair of short identifier files per identity — go into the `approle` subdirectory the same
way:

```bash
scp <approle-file> <username>@<ip-address>:/tmp/<approle-file>

ssh <username>@<ip-address>
sudo mv /tmp/<approle-file> ./data/ansible-runner/secrets/approle/
sudo chown root:root ./data/ansible-runner/secrets/approle/<approle-file>
sudo chmod 0600 ./data/ansible-runner/secrets/approle/<approle-file>
```

**Explanation**: These files together grant whoever holds them the ability to log into and
reconfigure every host your project manages. That is exactly why this image does not generate, copy or
otherwise manage them the way it manages everything else — a credential with that much reach should have
exactly one deliberate placement, done once by a person, not a repeatable automated step that could be
re-triggered by mistake or read a stale copy from somewhere. They land in the root-only directory from
Step 1 and are mounted read-only into individual task containers at run time; they are never baked into
the image itself, so rotating one is just replacing the file on the host — no rebuild.

The secret-store credentials need this treatment for a second, more mundane reason: a project keeps its
own copy of them outside version control, so a container that gets the project by cloning it never
receives them. Whatever path the project normally looks in does not exist in a fresh checkout, which is
why the run below both mounts this directory and tells the playbook to look there instead (Step 5). Copy
every identity the playbooks you run will need — a run that reaches the store on behalf of two different
identities needs both pairs present, and a missing file surfaces as a run that stops before it changes
anything.

---

#### Step 3: Write the Dockerfile and build the image

```bash
sudo tee ./data/ansible-runner/build/Dockerfile >/dev/null <<'EOF'
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        rsync \
        sshpass \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible-core passlib hvac

RUN ansible-galaxy collection install \
    community.docker \
    community.general \
    community.postgresql \
    community.crypto \
    community.hashi_vault \
    ansible.posix

ENV ANSIBLE_HOST_KEY_CHECKING=False

WORKDIR /workspace

CMD ["ansible-playbook", "--version"]
EOF

sudo docker build -t ansible-runner:latest ./data/ansible-runner/build
```

**Explanation**: `passlib` sits alongside `ansible-core` because password-hashing filters in common use
(for creating system user accounts, for instance) depend on it — without it, any playbook that hashes a
password fails on a missing dependency instead of a missing feature. `hvac` is the Python client for the
secret store, and it must be in the image rather than installed at run time: a playbook that reads a
value out of the store does so from the machine running the playbook — this container — and the lookup
that does it fails with a bare import error if the client is absent. The six collections cover Docker,
general-purpose community modules, PostgreSQL, TLS/crypto operations, secret-store lookups and
POSIX-specific modules (permissions, mounts) — adjust this list to whatever modules your own project's
playbooks actually import; this set is a reasonable starting point, not a universal one. `ANSIBLE_HOST_KEY_CHECKING=False`
is a direct consequence of every container being thrown away after one run: strict host-key checking
exists to catch a host's key changing unexpectedly (a sign of a man-in-the-middle), but that protection
depends on a `known_hosts` file built up over repeated connections, and a container that never has a
second run never builds one. Disabling the check trades that protection for the ephemeral-container
model; the accepted mitigation is that this image only ever talks to hosts already reachable over routes
this host's own network already trusts — see Troubleshooting if that trade-off is not acceptable to you,
along with the alternative of mounting a pre-populated `known_hosts` file instead. There is no `USER`
directive, so the container runs as root by default — it needs to be able to read the mounted private key
and act as whatever account your project connects as; the containment here comes from `--cap-drop` and
`--security-opt no-new-privileges` at run time (Step 5) and the isolated network, not from an unprivileged
process inside the container.

---

#### Step 4: Clone your automation project into the shared workspace

```bash
sudo docker run --rm \
  --network sandbox \
  -v "$(pwd)/data/ansible-runner/workspace:/workspace" \
  -w /workspace \
  ansible-runner:latest \
  git clone <automation-repo-url> project
```

**Explanation**: This lands the checkout at `./data/ansible-runner/workspace/project` on the host, which
is why every later invocation sets its working directory inside that checkout. Doing the clone once,
rather than on every task run, means every future run is a fast `git pull` instead of a full clone; update
it the same way:

```bash
sudo docker run --rm \
  --network sandbox \
  -v "$(pwd)/data/ansible-runner/workspace:/workspace" \
  -w /workspace/project \
  ansible-runner:latest \
  git pull
```

---

#### Step 5: Confirm a playbook run actually completes

```bash
docker run --rm \
  --network sandbox \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v "$(pwd)/data/ansible-runner/workspace:/workspace" \
  -v "$(pwd)/data/ansible-runner/secrets/<ssh-key-file>:/root/.ssh/<ssh-key-file>:ro" \
  -v "$(pwd)/data/ansible-runner/secrets/<vault-password-file>:/secrets/<vault-password-file>:ro" \
  -v "$(pwd)/data/ansible-runner/secrets/approle:/secrets/approle:ro" \
  -e ANSIBLE_SECRETS_DIR=/secrets/approle \
  -w /workspace/project \
  ansible-runner:latest \
  ansible-playbook <playbook>.yml --vault-password-file /secrets/<vault-password-file>
```

**Explanation**: `--network sandbox` gives the container outbound reach to whatever this host's own
network already reaches over SSH, while keeping it off the network your other services live on — the same
isolation the Claude Code sandbox uses, for the same reason. Volume sources are host paths, not paths
relative to wherever an orchestrator's own container filesystem lives: if the orchestrator reaches the
Docker Engine through a filtered API gateway rather than a socket mounted into itself, that gateway
forwards to the **host's** daemon, and the host daemon always resolves a bind-mount source against the
**host** filesystem. The private key is mounted at the exact path your project's own configuration
expects a key to be found at — whatever that path is, it must match here, or the connection fails with a
missing-identity error before it ever tries a password or asks the target host anything. The
secret-store credentials are handled differently from the key and the password file — a whole directory
rather than one file each, plus an environment variable naming it — because the playbook that needs them
resolves their location from that variable and falls back to a path inside the project that only exists
on a workstation, never in a checkout. Setting it here is what makes a cloned project behave the same as
a hand-maintained one. The working
directory matters for the same reason many Ansible projects pick up their default settings automatically
from wherever you run the command — if your project defines its own configuration file for that, running
from inside the checkout the way this command does reproduces exactly what running it by hand would do.
No CPU, memory or process-count ceiling is set here, unlike the Claude Code sandbox — a full run against
several hosts can legitimately run far longer than a single coding task, so size any limits you do add to
the largest run you expect, not a fixed default.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<puid>` / `<pgid>` | Owner of the workspace directory | The same uid the Claude Code sandbox's shared directories use (`1000` by convention), and the `docker` group | Step 1 |
| `<username>` | Account used to copy files onto the host, and the account your playbooks connect as | The deploy account for this infrastructure | Steps 1, 2, Before you start |
| `<docker-subnet>` / `<docker-gateway-ip>` | Address range for the isolated `sandbox` network, only if it does not already exist | Any private range not already used by another Docker network on this host | Before you start |
| `<ssh-key-file>` | The private key this image connects to managed hosts with | Whatever key is already authorized on every target host | Steps 2, 5 |
| `<vault-password-file>` | The password file that decrypts any encrypted variables your project uses | The same file used interactively with `--vault-password-file` elsewhere | Steps 2, 5 |
| `<approle-file>` | One of the small credential files a playbook logs into the secret store with | Whatever your secret store issued for each identity; copy every file the playbooks you run will need | Steps 2, 5 |
| `<automation-repo-url>` | Where the project is cloned from | The repository holding your playbooks | Step 4, "Updating & day-to-day" |
| `<project-subdirectory>` | Directory inside the checkout a playbook is run from | Wherever your project keeps its own settings file | "Updating & day-to-day" |
| `<service>` / `<this-service>` | The service a host-side deploy script targets, and the tag that selects it | The one service that cannot be deployed by a job running inside it | "Updating & day-to-day" |
| `<schedule>` | When the out-of-band deploy runs | A systemd calendar expression (e.g. `Thu *-*-* 10:00:00`), placed after your backups and after your regular deploy | "Updating & day-to-day" |
| `<ip-address>` | A target host's address | Whichever host you are testing connectivity to or managing | Before you start |
| `<automation-repo-url>` | Where your Ansible project lives | A Git URL you can clone from this host | Step 4 |
| `<playbook>.yml` | The playbook to run | Whatever your project calls the playbook you want this run to execute | Step 5 |

## Verification

```bash
# the image exists
docker images ansible-runner:latest

# the shared sandbox network exists
docker network inspect sandbox --format '{{.IPAM.Config}}'

# the secrets directory is root-only
sudo stat -c '%a %U:%G' ./data/ansible-runner/secrets ./data/ansible-runner/secrets/approle

# the image carries the secret-store client and collection
docker run --rm ansible-runner:latest python -c "import hvac; print(hvac.__version__)"
docker run --rm ansible-runner:latest ansible-galaxy collection list community.hashi_vault

# the checkout is present after Step 4
sudo ls ./data/ansible-runner/workspace/project

# a full run completes end to end, the same way the orchestrator would invoke it
docker run --rm \
  --network sandbox \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v "$(pwd)/data/ansible-runner/workspace:/workspace" \
  -v "$(pwd)/data/ansible-runner/secrets/<ssh-key-file>:/root/.ssh/<ssh-key-file>:ro" \
  -v "$(pwd)/data/ansible-runner/secrets/<vault-password-file>:/secrets/<vault-password-file>:ro" \
  -v "$(pwd)/data/ansible-runner/secrets/approle:/secrets/approle:ro" \
  -e ANSIBLE_SECRETS_DIR=/secrets/approle \
  -w /workspace/project \
  ansible-runner:latest \
  ansible-playbook <playbook>.yml --vault-password-file /secrets/<vault-password-file> --syntax-check
```

## Updating & day-to-day

**Rebuild the image** after changing the Dockerfile, or to pick up a newer `ansible-core` release or an
additional collection:

```bash
sudo docker build --pull --no-cache -t ansible-runner:latest ./data/ansible-runner/build
```

As with the Claude Code sandbox, nothing needs recreating afterward — the very next run uses whatever the
tag currently points at.

**Keep the checkout current.** Either `git pull` inside it by hand (Step 4's second command) before a
run, or have whatever triggers a run do a pull as its first step, so a stale checkout never silently runs
an old playbook.

**Rotating the SSH key, Vault password or secret-store credentials.** Replace the file under
`./data/ansible-runner/secrets` (or its `approle` subdirectory) and set its permissions back to `0600` —
nothing needs rebuilding, since none of these files is ever baked into the image. Reissuing a
secret-store credential invalidates the copy here, so re-copy it in the same sitting: the next run fails
at its first store lookup otherwise.

```bash
sudo cp <new-key> ./data/ansible-runner/secrets/<ssh-key-file>
sudo chown root:root ./data/ansible-runner/secrets/<ssh-key-file>
sudo chmod 0600 ./data/ansible-runner/secrets/<ssh-key-file>
```

**Running a deploy the orchestrator cannot run itself.** Deploying the orchestrator means recreating its
container, and that container is what runs its own jobs — a job that does it kills itself partway
through. The way out is to run that one deploy from the host instead, doing by hand exactly what a job
would have done: fresh clone, same image, same mounts, no orchestrator involved. Install this as
`/usr/local/sbin/<service>-update`, `root:root 0750`:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-<automation-repo-url>}"
BRANCH="${BRANCH:-main}"
PLAYBOOK="${PLAYBOOK:-<playbook>.yml}"
TAGS="${TAGS:-<this-service>}"
IMAGE="${IMAGE:-ansible-runner:latest}"
DEPLOY_DIR="${DEPLOY_DIR:-<deploy-dir>}"

KEY="<ssh-key-file>"
VAULT_PASS="<vault-password-file>"
SECRETS="${DEPLOY_DIR}/data/ansible-runner/secrets"
LOG_DIR="${DEPLOY_DIR}/data/ansible-runner/logs"
LOG="${LOG_DIR}/<service>-update-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name '<service>-update-*.log' -mtime +14 -delete

exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "=== $(date -Is) <service>-update FAILED rc=$rc"' EXIT

echo "=== $(date -Is) branch=${BRANCH} playbook=${PLAYBOOK} tags=${TAGS} check=${CHECK:-0}"

for f in "${SECRETS}/${KEY}" "${SECRETS}/${VAULT_PASS}" "${SECRETS}"/approle/*; do
    [ -r "$f" ] || { echo "unreadable or missing: $f"; exit 1; }
done

docker run --rm \
    --network sandbox \
    -v "${SECRETS}/${KEY}:/root/${KEY}:ro" \
    -v "${SECRETS}/${KEY}:/root/.ssh/${KEY}:ro" \
    -v "${SECRETS}/${VAULT_PASS}:/secrets/${VAULT_PASS}:ro" \
    -v "${SECRETS}/approle:/secrets/approle:ro" \
    -e ANSIBLE_HOST_KEY_CHECKING=false \
    -e ANSIBLE_SECRETS_DIR=/secrets/approle \
    "$IMAGE" \
    sh -c "git clone --depth 1 --branch '${BRANCH}' '${REPO_URL}' /tmp/repo \
           && cd /tmp/repo/<project-subdirectory> \
           && ansible-playbook '${PLAYBOOK}' --tags '${TAGS}' \
              --vault-password-file /secrets/${VAULT_PASS} ${CHECK:+--check}"

echo "=== $(date -Is) <service>-update done rc=0"
```

Run it as `sudo <service>-update`, or `sudo CHECK=1 <service>-update` first — the dry run exercises the
clone, every mount and every credential without changing anything, which is the whole point of having a
rehearsal for the one deploy nobody is supervising. It clones rather than reusing the shared workspace so
that what it deploys is exactly what the repository says and nothing a previous run left behind;
`BRANCH`, `TAGS` and `PLAYBOOK` are overridable for the same reason a hand-run playbook takes flags. Note
that a clone deploys **pushed** work only — an unpushed local fix is invisible to this script, and the
run will quietly deploy the older code that is on the branch. Output is teed to a dated log because a run
nobody is watching still has to be explainable afterwards; logs older than two weeks are removed at the
start of each run. The credential check runs *after* logging starts, not before, so a missing file is
recorded in the log rather than only appearing on a terminal nobody is attached to; the exit trap prints
one greppable failure line for the same reason — whatever collects this host's system log is then also
your alert for a deploy that did not work.

Nothing here is host-specific except the values at the top, so keep the script generated rather than
hand-written if you have a mechanism for that: the key's filename in particular should come from wherever
your infrastructure already records it, so rotating to a differently-named key does not leave a stale
literal in a script nobody thinks to open.

**Put it on a schedule.** Two unit files, `root:root 0644`, in `/etc/systemd/system`:

```ini
# <service>-update.service
[Unit]
Description=Deploy the <service> container out of band (it cannot deploy itself)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/<service>-update
TimeoutStartSec=30min
```

```ini
# <service>-update.timer
[Unit]
Description=Scheduled out-of-band deploy of the <service> container

[Timer]
OnCalendar=<schedule>
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now <service>-update.timer
systemctl list-timers <service>-update.timer
```

**Explanation**: `Type=oneshot` matches a job that runs to completion rather than staying resident, and
`TimeoutStartSec` has to comfortably exceed a full deploy — a clone, an image pull and a container
recreate — or systemd kills the run halfway and leaves the service in whatever state it had reached.
`Persistent=true` runs a missed schedule once the host is back, which is what you want for a machine that
is occasionally off; `RandomizedDelaySec` keeps it from starting at the same instant as everything else
scheduled on the hour. Place `<schedule>` **after** whatever dumps your databases and after whatever
deploys the rest of your infrastructure: this pulls the newest image, a major version jump migrates the
schema irreversibly, and the only thing standing between that and a bad afternoon is a backup taken
earlier the same week. Triggering it by hand stays available — `sudo systemctl start
<service>-update.service` — which is the one-button version of the whole procedure.

**Reading a run's output after the fact.** A task container removes itself on exit, so capture output
before that happens if you need to debug a failure — drop `--rm` temporarily:

```bash
docker run --network sandbox ... ansible-runner:latest ansible-playbook <playbook>.yml ...
docker logs <container-id>
docker rm <container-id>
```

## Rollback / Uninstall

```bash
sudo docker rmi ansible-runner:latest

sudo rm -rf ./data/ansible-runner/workspace

sudo rm -rf ./data/ansible-runner/secrets
```

Do not remove the `sandbox` network here unless you are also retiring the Claude Code sandbox — it is
shared, not owned by this image.

**Warning**: removing `./data/ansible-runner/secrets` deletes the only copy of the SSH key, Vault
password and secret-store credentials held on this host. Confirm you can re-copy them from a trusted source before doing this.
Removing `./data/ansible-runner/workspace` only costs a re-clone (Step 4).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Permission denied (publickey)` | Confirm `./data/ansible-runner/secrets/<ssh-key-file>` exists, is `0600`, and its public half is authorized on the target host for the account you are connecting as. Confirm the mount target matches exactly what your project's own connection settings expect. |
| A Vault decryption error | `--vault-password-file` must point at the mount path **inside the container** (`/secrets/<vault-password-file>` above), not the host path — confirm the mount is present and the file's content matches what you use interactively elsewhere. |
| `ansible-playbook: command not found`, or a module import error | The image was not rebuilt after a Dockerfile change, or a `pip`/`ansible-galaxy` step failed silently during a build. Rerun Step 3, watch the build output for errors, then confirm with `docker run --rm ansible-runner:latest ansible-playbook --version` and `ansible-galaxy collection list`. |
| The run stops early saying credential files are missing, naming paths inside the checkout | The playbook is looking where a workstation keeps them, because `ANSIBLE_SECRETS_DIR` was not set on the run — add both the `approle` mount and the variable (Step 5). If they are set, confirm every file the playbook names is actually present in `./data/ansible-runner/secrets/approle`. |
| A store lookup fails with an import error, or "sealed", or an unknown path | In that order: the image predates `hvac` being added to it (rebuild, Step 3); the store is locked and needs unlocking by its own procedure; or the value the playbook asks for was never written. The store must also be reachable from the `sandbox` network — check with `docker run --rm --network sandbox curlimages/curl -sf -o /dev/null -w '%{http_code}\n' https://<store-host>/v1/sys/health`. |
| The playbook runs but does not pick up the project's own settings | Confirm the working directory (`-w`) is set to inside the checkout, at the same depth your project expects when run by hand — many Ansible projects only auto-load their own configuration from a specific directory. |
| No route to a target host / SSH connection times out | The `sandbox` network is a normal bridge with NAT egress, so this is almost always a host firewall or routing issue rather than a Docker networking one. Confirm the target host's firewall permits SSH from this host's outbound address. |
| Worried about the man-in-the-middle risk from disabled host-key checking | This is an accepted trade-off of the ephemeral-container model, not an oversight — no container lives long enough to build a trustworthy `known_hosts`. Do not "fix" it by baking a `known_hosts` file into the image (Step 3); if you need the guarantee back, mount a pre-populated `known_hosts` file from the `secrets` directory at run time instead and set `ANSIBLE_HOST_KEY_CHECKING=True`. |
