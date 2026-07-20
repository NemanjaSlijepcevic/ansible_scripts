# Role: install_docker

## Purpose

This role installs Docker Engine using the official Docker convenience script, configures the Docker daemon with sensible defaults (DNS, log limits, metrics endpoint, live-restore), adds the configured system users to the `docker` group, and sets up log rotation for Docker container logs.

## Prerequisites

- `install_packages` role must have run (provides `curl`, `jq`, `ca-certificates`).
- `create_new_users` role must have run (users must exist before they can be added to the `docker` group).
- Internet access from the target machine (to download the Docker install script and packages).
- The shared `logrotate.j2` template must exist at `client/templates/logrotate.j2`.

## Manual Execution Guide

### Overview

1. Create the `docker` group.
2. Add users to the `docker` group.
3. Download and run the official Docker install script.
4. Install Python packages needed for Ansible Docker modules.
5. (Debian 12 only) Remove the `EXTERNALLY-MANAGED` marker.
6. Install the Python docker package.
7. Deploy `daemon.json`.
8. Validate and restart Docker.
9. Configure Docker log rotation.
10. Run a hello-world container to verify Docker is functional, then remove the container and image.

---

### Step-by-Step Instructions

#### Step 1: Create the docker group

**Purpose**: The `docker` group allows non-root users to interact with the Docker socket.

```bash
sudo groupadd --system docker
```

---

#### Step 2: Add users to the docker group

**Purpose**: Users in the `docker` group can run `docker` commands without `sudo`.

For each user defined in `default_user`:

```bash
sudo usermod -aG docker <username>
```

**Note**: Group changes take effect on the next login. Existing sessions must be re-opened.

---

#### Step 3: Install Docker Engine

**Purpose**: Install Docker using the official convenience script, which handles repository setup, GPG keys, and package installation automatically.

```bash
curl -fsSL https://get.docker.com -o /tmp/docker.sh
chmod 0755 /tmp/docker.sh
sudo /tmp/docker.sh
```

**Explanation**: The script at `https://get.docker.com` detects the OS and installs `docker-ce`, `docker-ce-cli`, `containerd.io`, and related packages from Docker's official repository. It is idempotent — running it on an already-installed system performs an upgrade.

---

#### Step 4: Install Python support packages

**Purpose**: Ansible's Docker modules (`community.docker`) require the `docker` Python library.

```bash
sudo apt-get install -y \
  software-properties-common \
  python3-pip \
  virtualenv \
  python3-setuptools \
  python3-docker
```

---

#### Step 5: (Debian 12 only) Remove EXTERNALLY-MANAGED

**Purpose**: Debian 12 marks the system Python as externally managed, blocking `pip install` for system-wide packages. The Ansible `pip` module needs to install the `docker` Python package at the system level.

```bash
# Only run this on Debian 12
sudo rm -f /usr/lib/python3.11/EXTERNALLY-MANAGED
```

**Explanation**: This file is a PEP 668 marker that prevents pip from installing packages outside of virtual environments. Removing it allows system-wide pip installs. Only do this if you understand the implications — on Debian 12 specifically.

---

#### Step 6: Install the Python docker package

**Purpose**: The `docker` Python package is the actual library Ansible's modules call.

```bash
sudo pip3 install docker
```

---

#### Step 7: Deploy daemon.json

**Purpose**: Configure the Docker daemon with production-appropriate defaults.

Create `/etc/docker/daemon.json`:

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
    "metrics-addr": "127.0.0.1:9323",
    "dns": ["1.1.1.1", "8.8.8.8"],
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

**Explanation of each setting**:

| Setting | Value | Meaning |
|---------|-------|---------|
| `metrics-addr` | `127.0.0.1:9323` | Exposes Docker engine Prometheus metrics on localhost port 9323 |
| `dns` | Cloudflare + Google | Override DNS for all containers (avoids split-horizon issues) |
| `dns-opts` | timeout/attempts | DNS query timeout and retry settings |
| `log-driver` | `json-file` | Store container logs as JSON files |
| `log-opts.max-size` | `50m` | Each container's log file is capped at 50 MB |
| `log-opts.max-file` | `5` | Keep up to 5 rotated log files per container |
| `live-restore` | `true` | Containers continue running if the Docker daemon crashes or restarts |

---

#### Step 8: Validate and restart Docker

Validate the JSON syntax first:

```bash
sudo jq . /etc/docker/daemon.json
```

If `jq` exits 0, restart Docker:

```bash
sudo systemctl restart docker
sudo systemctl enable docker
```

---

#### Step 9: Configure Docker log rotation

**Purpose**: Set up logrotate for Docker container logs stored in `/var/log/docker/`.

Create `/etc/logrotate.d/docker`:

```bash
sudo nano /etc/logrotate.d/docker
```

```
/var/log/docker/*.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog
    endscript
}
```

```bash
sudo chmod 0644 /etc/logrotate.d/docker
```

---

#### Step 10: Verify Docker with a test container

**Purpose**: Confirm that the Docker daemon is fully functional after installation and configuration by running the official `hello-world` image, then clean up the container and image so no residue is left on the system.

```bash
# Pull and run the hello-world container
sudo docker run --name hello-world-test hello-world
```

**Explanation**: Docker pulls the `hello-world` image from Docker Hub, creates a container named `hello-world-test`, runs it (it prints a success message and exits), and leaves the stopped container on disk. The two cleanup commands below remove it.

```bash
# Remove the stopped container
sudo docker rm hello-world-test

# Remove the hello-world image
sudo docker rmi hello-world
```

**What to expect**: The `docker run` command should print output that begins with "Hello from Docker!". If it does, Docker is correctly installed, the daemon is running, and the host has outbound internet access to Docker Hub.

---

## Configuration Reference

### Default Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `default_user` | `group_vars/all.yml` | List of user objects; each user is added to the `docker` group |

The `daemon.json` file is a static file in `client/roles/install_docker/files/daemon.json` and does not use template variables. The `update/roles/common` role uses a templated version (`daemon.json.j2`) with additional per-host DNS settings.

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Validate and Restart Docker` (listen) — Step 1: Validate | `daemon.json` changed | `sudo jq . /etc/docker/daemon.json` |
| `Validate and Restart Docker` (listen) — Step 2: Restart | Validation passes | `sudo systemctl restart docker` |

The two handler steps share the `listen: "Validate and Restart Docker"` key, meaning they both respond to the same notification.

---

## Verification

```bash
# Check Docker is installed and running
sudo docker version
sudo systemctl status docker

# Check daemon.json is valid and applied
sudo docker info | grep -i "logging driver"
sudo docker info | grep -i "live restore"

# Verify metrics endpoint
curl http://127.0.0.1:9323/metrics | head -5

# Confirm users are in the docker group
groups <username>

# Run a test container
sudo docker run --rm hello-world
```

---

## Rollback / Uninstall

To fully remove Docker:

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /etc/docker
sudo groupdel docker
```

**Warning**: This deletes all Docker images, containers, volumes, and networks on the machine.

---

## Troubleshooting

**Docker fails to start after daemon.json change**
Check the JSON is valid: `sudo jq . /etc/docker/daemon.json`. Check Docker startup logs: `sudo journalctl -u docker --no-pager -n 50`.

**users cannot run docker without sudo**
The user must log out and back in for the group change to take effect. Verify: `groups <username>` should show `docker`.

**dns: [...] is not valid JSON**
Make sure quotes and braces are correct. The `jq` validator will point to the exact line.

**live-restore: containers still stop when Docker restarts**
This setting only applies if the containers were started after `live-restore: true` was configured. Containers started before the setting was applied will not benefit from it until recreated.
