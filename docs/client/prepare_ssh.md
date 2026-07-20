# Role: prepare_ssh

## Purpose

This role ensures the SSH daemon is running and lays the groundwork for the drop-in configuration approach used by the `protect_ssh` role that follows it. It creates a dedicated `ssh` group (used to restrict who may log in via SSH), creates the `/etc/ssh/sshd_config.d/` directory, and patches the main `sshd_config` to include that directory — which is the standard modular configuration pattern on modern Debian/Ubuntu.

## Prerequisites

- The `install_packages` role must have run (provides `openssh-server`, which is installed as part of most server images, and `ufw`).
- Root or sudo access on the target machine.

## Manual Execution Guide

### Overview

1. Start and enable the SSH daemon.
2. Create the `ssh` system group.
3. Create `/etc/ssh/sshd_config.d/` if it does not exist.
4. Add an `Include` directive to the top of `/etc/ssh/sshd_config` so any `.conf` files inside the directory are loaded automatically.
5. Validate the SSHD configuration and restart if the directory was newly created.

---

### Step-by-Step Instructions

#### Step 1: Enable and start SSH

**Purpose**: Guarantee the SSH service is active and will survive reboots.

```bash
sudo systemctl enable ssh
sudo systemctl start ssh
```

**Explanation**: On Debian, the service is named `ssh`; on Ubuntu it is the same. `enable` creates the systemd symlink so it starts on boot; `start` brings it up immediately if it is not already running.

---

#### Step 2: Create the `ssh` group

**Purpose**: This group is referenced in the SSHD configuration (via `AllowGroups ssh`) to restrict SSH access to only users who are members of it.

```bash
sudo groupadd --system ssh
```

**Explanation**: `groupadd` creates the group. If the group already exists, `groupadd` exits with a non-zero code — this is harmless and can be ignored.

---

#### Step 3: Create the sshd_config.d directory

**Purpose**: The drop-in directory allows SSH configuration to be split into separate files per role, making it easier to manage and audit individual settings.

```bash
sudo mkdir -p /etc/ssh/sshd_config.d
sudo chown root:root /etc/ssh/sshd_config.d
sudo chmod 0755 /etc/ssh/sshd_config.d
```

---

#### Step 4: Add the Include directive to sshd_config

**Purpose**: Without this directive, files placed in `sshd_config.d/` are ignored. This step is only needed if the directory was just created (i.e., it did not previously exist).

Check whether the Include line already exists:

```bash
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config
```

If the command exits non-zero (line not present), add it at the top of the file:

```bash
sudo sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' /etc/ssh/sshd_config
```

**Explanation**: `sed -i '1s|^|...\n|'` inserts the `Include` directive as the very first line. SSHD processes the main file in order; putting the include at the top ensures drop-in files are loaded first and can establish base settings that the rest of the file may override.

---

#### Step 5: Validate and restart SSHD

**Purpose**: Always validate SSHD configuration before restarting to avoid locking yourself out.

```bash
sudo sshd -t -f /etc/ssh/sshd_config
```

If the command exits 0 (no output or no errors), restart:

```bash
sudo systemctl restart ssh
```

---

## Configuration Reference

### Default Variables

| Variable | Default Value | Description |
|----------|--------------|-------------|
| (none) | — | This role uses no Ansible variables. All settings are hard-coded. |

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Validate SSHD configuration` | `Include` line added | `sudo sshd -t -f /etc/ssh/sshd_config` |
| `Restart ssh` | Validation passes | `sudo systemctl restart ssh` |

The handler chain is: configuration change → validate → restart. SSHD is never restarted without a passing validation check.

---

## Verification

```bash
# Confirm SSH is running and enabled
sudo systemctl status ssh

# Confirm the drop-in directory exists
ls -la /etc/ssh/sshd_config.d/

# Confirm the Include line is at the top of sshd_config
head -5 /etc/ssh/sshd_config

# Confirm the ssh group exists
getent group ssh

# Test configuration is valid
sudo sshd -t
```

---

## Rollback / Uninstall

To remove the Include directive (reverting to a monolithic sshd_config):

```bash
sudo sed -i '/^Include \/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

To remove the directory:

```bash
sudo rm -rf /etc/ssh/sshd_config.d
```

**Warning**: If any `*.conf` files are in the directory when you remove the `Include` line, their settings will silently stop applying — verify all active settings are still present in the main `sshd_config` before restarting.

---

## Troubleshooting

**SSH fails to start after adding Include**
Run `sudo sshd -t` and read the error. Common issues: a malformed `.conf` file in `sshd_config.d/` or a directive that conflicts with a setting in the main file.

**ssh group already exists**
This is harmless. `groupadd` exits with code 9 if the group already exists. Simply ignore the error and continue.

**Cannot SSH in after restart**
If you lose SSH access, use console or out-of-band access (IPMI/VNC). Check `sudo journalctl -u ssh` for the actual error.
