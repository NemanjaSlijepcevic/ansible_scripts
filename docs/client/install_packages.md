# Role: install_packages

## Purpose

This role prepares a fresh Debian/Ubuntu machine with all baseline system packages required by the rest of the bootstrap process. It also configures the system to automatically apply security patches every night so the machine stays up-to-date without manual intervention.

## Prerequisites

- A fresh Debian or Ubuntu installation reachable over SSH.
- The controlling user must have `sudo` or root access.
- Internet access from the target machine (to reach apt mirrors).

## Manual Execution Guide

### Overview

1. Update the apt package index and upgrade all installed packages.
2. Install a fixed set of utility packages.
3. Write the `unattended-upgrades` policy file to enable nightly automatic security updates.
4. Install `eza` (modern `ls` replacement) from its third-party apt repository.

---

### Step-by-Step Instructions

#### Step 1: Full system upgrade

**Purpose**: Ensure the machine starts from a fully patched baseline before any new software is added.

```bash
sudo apt-get update
sudo apt-get dist-upgrade -y
sudo apt-get autoclean -y
sudo apt-get autoremove -y
```

**Explanation**:
- `apt-get update` refreshes the package index from all configured mirrors.
- `dist-upgrade` upgrades all installed packages, resolving dependency changes (safer than `upgrade` alone on Debian).
- `autoclean` removes cached `.deb` files for packages that are no longer in the repository.
- `autoremove` removes packages that were installed as dependencies but are no longer needed.

---

#### Step 2: Install required packages

**Purpose**: Install tools needed by later bootstrap roles and general system management.

```bash
sudo apt-get install -y \
  sudo \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common \
  gnupg \
  wget \
  nano \
  iputils-ping \
  ufw \
  unattended-upgrades \
  logrotate \
  jq
```

**Explanation** of each package:

| Package | Why it is needed |
|---------|-----------------|
| `sudo` | Allows non-root users to run privileged commands |
| `apt-transport-https` | Enables apt to fetch packages over HTTPS |
| `ca-certificates` | Provides trusted root certificates for TLS verification |
| `curl` | HTTP client used by Docker install scripts and health checks |
| `software-properties-common` | Provides `add-apt-repository` |
| `gnupg` | GPG key management for third-party apt repositories |
| `wget` | Alternative HTTP downloader |
| `nano` | Simple terminal text editor |
| `iputils-ping` | Provides the `ping` command for connectivity tests |
| `ufw` | Uncomplicated Firewall — used by the `prepare_firewall` role |
| `unattended-upgrades` | Daemon for automatic security updates |
| `logrotate` | Manages log file rotation |
| `jq` | JSON processor used to validate Docker `daemon.json` |

---

#### Step 3: Configure automatic upgrades

**Purpose**: Enable nightly unattended security updates so the machine patches itself without manual intervention.

Create the file `/etc/apt/apt.conf.d/20auto-upgrades` with the following content:

```bash
sudo nano /etc/apt/apt.conf.d/20auto-upgrades
```

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade::InstallOnShutdown "0";
```

```bash
sudo chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades
sudo chown root:root /etc/apt/apt.conf.d/20auto-upgrades
```

**Explanation of each directive**:

| Directive | Value | Meaning |
|-----------|-------|---------|
| `Update-Package-Lists` | `"1"` | Refresh the package index daily |
| `Unattended-Upgrade` | `"1"` | Run the upgrade daemon daily |
| `AutocleanInterval` | `"7"` | Clean the download cache every 7 days |
| `InstallOnShutdown` | `"0"` | Do not hold upgrades until shutdown |

---

#### Step 4: Install eza

**Purpose**: Install `eza`, a modern replacement for `ls`, from the gierens.de apt repository. The repository is signed with its own GPG key, which must be downloaded and de-armored into the apt keyring first.

```bash
# Ensure the keyrings directory exists
sudo mkdir -p /etc/apt/keyrings
sudo chmod 0755 /etc/apt/keyrings

# Download the eza GPG key, then convert it to binary keyring format
wget -O /tmp/eza-deb.asc https://raw.githubusercontent.com/eza-community/eza/main/deb.asc
sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg /tmp/eza-deb.asc
sudo chmod 0644 /etc/apt/keyrings/gierens.gpg

# Add the apt repository
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list

# Install
sudo apt-get update
sudo apt-get install -y eza
```

**Explanation**:
- The key is downloaded to a temporary file first (not piped straight into `gpg`), matching the role's two-step `get_url` + `gpg --dearmor` tasks.
- `gpg --dearmor` skips the conversion if `/etc/apt/keyrings/gierens.gpg` already exists (the role uses `creates:` for idempotence).

---

## Configuration Reference

### Default Variables

This role has no Ansible defaults file. All packages are hard-coded in the task.

---

## Handlers & Service Management

This role has no handlers. No services are restarted.

---

## Verification

```bash
# Confirm all expected packages are installed
dpkg -l sudo apt-transport-https ca-certificates curl software-properties-common gnupg wget nano ufw unattended-upgrades logrotate jq

# Confirm eza is installed and its repository key is in place
eza --version
ls -l /etc/apt/keyrings/gierens.gpg

# Check the auto-upgrade config
cat /etc/apt/apt.conf.d/20auto-upgrades

# Run a manual upgrade dry-run
sudo unattended-upgrade --dry-run --debug
```

---

## Rollback / Uninstall

To remove the auto-upgrade configuration:

```bash
sudo rm /etc/apt/apt.conf.d/20auto-upgrades
```

Individual packages can be removed with `sudo apt-get remove <package>`. Removing `sudo` while logged in as a non-root user will lock you out of privilege escalation, so do not remove it unless you have direct root access.

---

## Troubleshooting

**apt-get update fails with GPG error**
Run `sudo apt-get update 2>&1 | grep -i error` to see which repository key is missing. Import the missing key with `sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys <KEY_ID>`.

**unattended-upgrades not running**
Check the systemd timer: `systemctl status apt-daily.timer apt-daily-upgrade.timer`. Check logs at `/var/log/unattended-upgrades/unattended-upgrades.log`.

**dist-upgrade holds back packages**
Some packages require manual resolution. Run `sudo apt-get dist-upgrade` interactively to review and accept dependency changes.
