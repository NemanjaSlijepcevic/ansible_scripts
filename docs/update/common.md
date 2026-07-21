# Role: common

## Purpose

This is the first role applied to every host in the `update/` playbook family. It ensures UFW firewall rules are current (without resetting existing rules), optionally installs `fuse-overlayfs` (for LXC hosts), configures the Docker daemon, creates the `proxy` Docker bridge network that all service containers share, and ensures Docker is running before any other role tries to launch containers.

> System package upgrades and `unattended-upgrades` are **not** part of this role — those live in the `client/install_packages` bootstrap role.

## Prerequisites

- Docker Engine must already be installed (done by the `client/` bootstrap roles).
- `ufw` must be installed.
- The `proxy` network may or may not already exist — the role handles both cases.
- Variables `docker.*`, `user.*`, and `ufw_rules` must be defined in the inventory. `docker_storage_driver` is optional.

## Manual Execution Guide

### Overview

1. Synchronise UFW rules (idempotent — checks current state, does not reset).
2. Create the `./data` working directory.
3. Optionally install `fuse-overlayfs` (only when `docker_storage_driver == "fuse-overlayfs"`).
4. Deploy `daemon.json`, restart Docker if it changed.
5. Create the `proxy` Docker network.

---

### Step-by-Step Instructions

#### Step 1: Synchronise UFW rules (idempotent)

Unlike the `client/prepare_firewall` role, this does not reset UFW. It checks current state and only modifies what has changed.

```bash
# Check current status
sudo ufw status verbose

# Set defaults only if not already set
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Apply rules (only adds if not already present)
sudo ufw allow proto tcp from any to any port 22 comment 'SSH'
sudo ufw allow proto tcp from any to any port 80 comment 'HTTP'
sudo ufw allow proto tcp from any to any port 443 comment 'HTTPS'

# Enable if not already active
sudo ufw enable
sudo ufw logging on
```

Configure UFW log rotation at `/etc/logrotate.d/uwf`:

```
/var/log/ufw.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 644
    sharedscripts
    postrotate
        systemctl reload rsyslog
    endscript
}
```

---

#### Step 2: Create `./data` and (optionally) install fuse-overlayfs

```bash
mkdir -p ./data
chown <username>:docker ./data
chmod 0755 ./data

# Only on LXC/unprivileged hosts that set docker_storage_driver: "fuse-overlayfs"
sudo apt-get install -y fuse-overlayfs
```

---

#### Step 3: Deploy Docker daemon.json

The `update/` roles use a templated version of `daemon.json` that includes the per-host DNS server. When `docker_storage_driver` is set (e.g. `fuse-overlayfs` on LXC), a `"storage-driver"` key is prepended.

Create `/etc/docker/daemon.json` with the following content (substituting actual values from `group_vars/all.yml` and `host_vars/`):

Values from inventory:

| Field | Variable | Example value |
|-------|----------|---------------|
| `storage-driver` (optional) | `docker_storage_driver` | `fuse-overlayfs` |
| `metrics-addr` | `docker.metrics_addr` | `<docker-bridge-ip>:9323` |
| `dns[0]` | `docker.dns` | `<local-dns-ip>` |

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
    "storage-driver": "fuse-overlayfs",
    "metrics-addr": "<docker-bridge-ip>:9323",
    "dns": ["<local-dns-ip>", "1.1.1.1", "8.8.8.8"],
    "dns-opts": ["timeout:2", "attempts:2"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    },
    "live-restore": true
}
```

```bash
sudo chmod 0644 /etc/docker/daemon.json
sudo chown root:root /etc/docker/daemon.json
```

Validate and restart:

```bash
sudo jq . /etc/docker/daemon.json && sudo systemctl restart docker && sudo systemctl enable docker
# Wait for the Docker socket
until [ -S /var/run/docker.sock ]; do sleep 1; done
echo "Docker socket ready"
```

**docker-sock-rebind unit**: `live-restore` keeps containers running across daemon restarts (e.g. unattended upgrades), but containers that file-bind `/var/run/docker.sock` (traefik, alloy, socket-proxy) are left holding a dead socket inode and silently break. The role installs `/etc/systemd/system/docker-sock-rebind.service` (from `files/docker-sock-rebind.service`), a oneshot tied to `docker.service` via `PartOf=` that stop+starts those containers ~15 s after every dockerd restart. It deliberately uses `docker stop` + `docker start` instead of `docker restart`: on fuse-overlayfs hosts a `restart` races the stale graphdriver state, the fresh `merged` rootfs mount vanishes from the host namespace, and the container stays permanently unhealthy (healthcheck exec fails with `setns /proc/self/fd` errors).

```bash
sudo cp docker-sock-rebind.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable docker-sock-rebind.service
```

---

#### Step 4: Create the proxy Docker network

**Purpose**: All service containers attach to this bridge network with static IPs in the `<docker-subnet>` subnet. Traefik routes traffic between containers on this network.

```bash
sudo docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

If the network already exists, Docker will print an error. To check:

```bash
sudo docker network ls | grep proxy
sudo docker network inspect proxy
```

---

#### Step 5: Create the data working directory

**Purpose**: Service data is stored under `./data/` relative to the directory where the playbook is run (typically the user's home directory).

```bash
mkdir -p ./data
chown <username>:docker ./data
chmod 0755 ./data
```

Replace `<username>:docker` with the values of `user.name` and `user.group` from `group_vars/all.yml`.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `user.name` | `<username>` | Owner of created directories |
| `user.group` | `docker` | Group owner of created directories |
| `docker.subnet` | `<docker-subnet>` | Subnet for the proxy Docker network |
| `docker.gateway` | `<docker-gateway>` | Gateway for the proxy network |
| `docker.net_range` | `<docker-ip-range>` | Assignable IP range within the subnet |
| `docker.metrics_addr` | `<docker-bridge-ip>:9323` | Docker engine metrics bind address |
| `docker.dns` | `<local-dns-ip>` | Primary DNS for containers |
| `docker_storage_driver` | `fuse-overlayfs` (optional) | Forces a Docker storage driver + installs `fuse-overlayfs`; empty/undefined = auto |
| `ufw_rules` | list | Firewall rules to synchronise (must include SSH) |

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Validate and Restart Docker` — Validate | `daemon.json` changed | `sudo jq . /etc/docker/daemon.json` |
| `Validate and Restart Docker` — Restart | Validation passes | `sudo systemctl restart docker && sudo systemctl enable docker` |
| `Validate and Restart Docker` — Wait | Restart completes | Wait for `/var/run/docker.sock` to appear (timeout 30s) |

The `ansible.builtin.meta: flush_handlers` task forces these handlers to run immediately after `daemon.json` is deployed, before the network creation task — ensuring Docker is up when `docker network create` runs.

---

## Verification

```bash
# Docker running
sudo systemctl status docker

# proxy network exists
sudo docker network inspect proxy | grep -E 'Subnet|Gateway'

# UFW rules active
sudo ufw status verbose

# daemon.json applied
sudo docker info | grep -E 'Logging Driver|Live Restore'
```

---

## Rollback / Uninstall

```bash
# Remove the proxy network (only if no containers are attached)
sudo docker network rm proxy
```

```bash
# Revert daemon.json to minimal config
sudo nano /etc/docker/daemon.json
```

```json
{}
```

```bash
sudo systemctl restart docker
```

---

## Troubleshooting

**docker network create fails with "network with name proxy already exists"**
This is expected if the role has been run before. The Ansible module is idempotent; the manual equivalent is to skip the create step.

**Docker fails to start after daemon.json change**
Run `sudo journalctl -u docker -n 30` and check for JSON parse errors or invalid configuration options. Run `sudo jq . /etc/docker/daemon.json` to validate the JSON.

**UFW blocks Docker container traffic**
UFW manages `iptables` but Docker also inserts its own rules. If you see containers unable to reach external networks, check that Docker's `FORWARD` chain rules are not being overridden. The `DOCKER-USER` chain is the safe place to add restrictions.
