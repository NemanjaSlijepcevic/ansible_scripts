# Role: clean_up

## Purpose

This is the final role in the machine bootstrap sequence. It configures syslog log rotation, removes orphaned apt packages and cached downloads, and reboots the machine if the system signals that a reboot is required (for example, after a kernel update).

## Prerequisites

- All other bootstrap roles must have run first.
- `install_packages` role must have run (provides `logrotate`).
- The shared `logrotate.j2` template must exist at `client/templates/logrotate.j2`.

## Manual Execution Guide

### Overview

1. Set up syslog log rotation.
2. Clean up orphaned apt packages and cached files.
3. Check if a reboot is required.
4. Reboot if needed (waits up to 10 minutes for the machine to come back).

---

### Step-by-Step Instructions

#### Step 1: Configure syslog log rotation

**Purpose**: Prevent `/var/log/syslog` from growing unboundedly. Syslog collects messages from most system services.

Create `/etc/logrotate.d/syslog`:

```bash
sudo nano /etc/logrotate.d/syslog
```

```
/var/log/syslog {
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
sudo chmod 0644 /etc/logrotate.d/syslog
sudo chown root:root /etc/logrotate.d/syslog
```

---

#### Step 2: Clean orphaned packages and apt cache

**Purpose**: After the full upgrade run by `install_packages`, some packages may have become orphaned (installed as dependencies of removed packages). Cleaning them frees disk space.

```bash
sudo apt-get autoclean -y
sudo apt-get autoremove -y
```

**Explanation**:
- `autoclean` removes `.deb` files from the apt cache that are no longer available in the configured repositories.
- `autoremove` removes packages that were installed automatically as dependencies but are no longer required by any installed package.

---

#### Step 3: Check if a reboot is required

**Purpose**: Kernel updates, glibc updates, and certain library updates require a reboot to fully take effect. The file `/var/run/reboot-required` is created by `update-notifier-common` (or directly by `dpkg`) when such a package is installed.

```bash
if [ -f /var/run/reboot-required ]; then
  echo "Reboot required."
  cat /var/run/reboot-required.pkgs
else
  echo "No reboot required."
fi
```

---

#### Step 4: Reboot if required

**Purpose**: Apply kernel updates or other changes that require a fresh boot. The Ansible task waits up to 600 seconds (10 minutes) for the machine to come back online.

```bash
# Only run this if /var/run/reboot-required exists
sudo reboot
```

After issuing the reboot, wait for the machine to come back up before continuing any further configuration. You can poll with:

```bash
# Wait for SSH to become available again
until ssh -o ConnectTimeout=5 <username>@<host> echo ok; do
  echo "Waiting for reboot..."
  sleep 10
done
```

---

## Configuration Reference

### Default Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `log_path` | `/var/log/syslog` | Path of the log file to rotate (set inline in the task, not a role variable) |
| `max_size` | `50M` | Rotation threshold (from `logrotate.j2` template default) |
| `rotate_count` | `3` | Number of rotated copies to keep (from `logrotate.j2` template default) |
| `log_permissions` | `0640 root adm` | Permissions for newly created log file (from `logrotate.j2` template default) |

---

## Handlers & Service Management

This role has no handlers. The reboot is performed directly as a task, not through a handler.

---

## Verification

```bash
# Confirm logrotate config exists
cat /etc/logrotate.d/syslog

# Manually test logrotate (dry run)
sudo logrotate --debug /etc/logrotate.d/syslog

# Check if a reboot was actually needed
ls -la /var/run/reboot-required

# After reboot: check uptime to confirm a fresh boot
uptime
```

---

## Rollback / Uninstall

There is nothing to uninstall from this role. The logrotate config can be removed if desired:

```bash
sudo rm /etc/logrotate.d/syslog
```

A reboot cannot be undone, but it is harmless.

---

## Troubleshooting

**Machine does not come back after reboot**
Check the hypervisor/IPMI console. Common causes: boot loader misconfiguration after a kernel update, filesystem errors caught by fsck at boot.

**autoremove wants to remove important packages**
Review the list carefully before confirming. Packages like `linux-image-*` entries from older kernels are safe to remove. If uncertain, run `sudo apt-get autoremove --dry-run` first.

**Logrotate does not rotate**
Check: `sudo logrotate -vf /etc/logrotate.d/syslog` to force rotation and see debug output. A common issue is that the file is smaller than the `size` threshold — logrotate's `size` directive only rotates when the file exceeds that size (not daily like `daily` would).
