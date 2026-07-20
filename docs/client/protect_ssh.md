# Role: protect_ssh

## Purpose

This role hardens the SSH daemon by deploying a drop-in configuration file that disables all password-based and root authentication methods. Only public-key authentication is permitted. It also sets up log rotation for `/var/log/auth.log` so SSH login events are retained but do not grow unbounded.

## Prerequisites

- `prepare_ssh` role must have run (creates `/etc/ssh/sshd_config.d/` and the `Include` directive).
- `create_new_users` role must have run (so that at least one user with a valid SSH key exists before password auth is disabled).
- `install_packages` role must have run (provides `logrotate`).
- The shared `logrotate.j2` template must exist at `client/templates/logrotate.j2`.

## Manual Execution Guide

### Overview

1. Deploy the SSH hardening drop-in config file.
2. Validate the SSHD configuration.
3. Restart SSHD.
4. Set up auth log rotation.

---

### Step-by-Step Instructions

#### Step 1: Deploy the SSHD hardening drop-in

**Purpose**: Override SSHD defaults to enforce key-only authentication and disable insecure features.

Create `/etc/ssh/sshd_config.d/10-default-sshd.conf` with the following content:

```bash
sudo nano /etc/ssh/sshd_config.d/10-default-sshd.conf
```

```
# Port configuration
Port 22

# Authentication rules
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# Security hardening
UsePAM yes
AllowTcpForwarding no
PrintMotd no

# Logging and banners (optional)
SyslogFacility AUTH
LogLevel VERBOSE
```

```bash
sudo chmod 0644 /etc/ssh/sshd_config.d/10-default-sshd.conf
sudo chown root:root /etc/ssh/sshd_config.d/10-default-sshd.conf
```

**Explanation of each directive**:

| Directive | Value | Effect |
|-----------|-------|--------|
| `Port` | `22` | SSH listens on port 22 (variable: `sshd_port`, default 22) |
| `PermitRootLogin` | `no` | Root cannot log in directly over SSH |
| `PasswordAuthentication` | `no` | Password logins are rejected; only key auth works |
| `PermitEmptyPasswords` | `no` | Accounts with no password set cannot log in |
| `ChallengeResponseAuthentication` | `no` | Disables keyboard-interactive auth (e.g., OTP via PAM) |
| `UsePAM` | `yes` | Enables PAM for session management (account/session modules still run) |
| `AllowTcpForwarding` | `no` | Disables SSH tunnelling to prevent proxy abuse |
| `PrintMotd` | `no` | Suppresses the `/etc/motd` banner on login |
| `SyslogFacility` | `AUTH` | Logs to the AUTH facility (appears in `/var/log/auth.log`) |
| `LogLevel` | `VERBOSE` | Logs more detail, including fingerprint of keys used for login |

> **Note**: If you need to change the SSH port, edit the `Port` line. The `sshd_port` variable in the inventory controls this when using Ansible.

---

#### Step 2: Validate and restart SSHD

**Purpose**: Never restart SSHD without validating the configuration first. A syntax error could lock you out.

```bash
sudo sshd -t -f /etc/ssh/sshd_config
```

If this command exits 0 (no errors), restart the daemon:

```bash
sudo systemctl restart ssh
```

---

#### Step 3: Configure auth log rotation

**Purpose**: Prevent `/var/log/auth.log` from growing indefinitely. The role uses the shared logrotate template.

Create `/etc/logrotate.d/ssh`:

```bash
sudo nano /etc/logrotate.d/ssh
```

```
/var/log/auth.log {
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
sudo chmod 0644 /etc/logrotate.d/ssh
sudo chown root:root /etc/logrotate.d/ssh
```

**Explanation of logrotate options**:

| Option | Meaning |
|--------|---------|
| `size 50M` | Rotate when the file exceeds 50 MB |
| `rotate 3` | Keep 3 rotated copies |
| `compress` | Compress rotated files with gzip |
| `delaycompress` | Do not compress the most-recent rotated file (rsyslog may still write to it) |
| `missingok` | Do not error if the log file does not exist |
| `notifempty` | Do not rotate empty log files |
| `create 0640 root adm` | Create a new empty log file with these permissions after rotation |
| `postrotate` | Reload rsyslog after rotation so it starts writing to the new file |

---

## Configuration Reference

### Default Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `sshd_port` | `22` | TCP port SSHD listens on (templated into the drop-in config) |

This variable is set in host_vars if non-standard. For example, the `primary_server` host uses port `9890`.

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Validate SSHD configuration` | Drop-in config file deployed | `sudo sshd -t -f /etc/ssh/sshd_config` |
| `Restart ssh` | Validation passes | `sudo systemctl restart ssh` |

---

## Verification

```bash
# Confirm the drop-in file is in place
cat /etc/ssh/sshd_config.d/10-default-sshd.conf

# Confirm password authentication is disabled (should print "no")
sudo sshd -T | grep passwordauthentication

# Confirm root login is disabled (should print "no")
sudo sshd -T | grep permitrootlogin

# Check SSHD is running
sudo systemctl status ssh

# Test key-based login (from another terminal, keep this session open!)
ssh -i /path/to/private_key <username>@<host>
```

---

## Rollback / Uninstall

To re-enable password authentication (emergency access):

```bash
sudo rm /etc/ssh/sshd_config.d/10-default-sshd.conf
sudo systemctl restart ssh
```

This reverts SSHD to the defaults in the main `sshd_config` file.

---

## Troubleshooting

**Locked out after applying this role**
Use console/IPMI access. The most common cause is that no user has an `authorized_keys` file — ensure `create_new_users` ran successfully before this role. Re-add `PasswordAuthentication yes` temporarily in `/etc/ssh/sshd_config`, restart, log in via password, fix the key, then remove the override.

**ChallengeResponseAuthentication deprecated warning on Ubuntu 22.04+**
On Ubuntu 22.04 and later, this directive was replaced by `KbdInteractiveAuthentication`. The warning is harmless. Update the directive if needed:
```
KbdInteractiveAuthentication no
```

**sshd -t fails with "Bad configuration option"**
An unsupported directive exists in one of the `.conf` files. The error message names the file and line number.
