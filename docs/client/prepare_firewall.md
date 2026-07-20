# Role: prepare_firewall

## Purpose

This role configures the host firewall using UFW (Uncomplicated Firewall). It enforces a default-deny inbound policy, explicitly allows only the ports declared in the `ufw_rules` inventory variable, enables UFW logging, and sets up log rotation for UFW log files. A safety assertion runs first to confirm that an SSH rule exists so you cannot accidentally lock yourself out.

## Prerequisites

- `install_packages` role must have run (provides `ufw`).
- The `ufw_rules` variable must be defined in the inventory and must contain at least one rule with `comment: "SSH"`.
- Root or sudo access on the target machine.

## Manual Execution Guide

### Overview

1. Assert that an SSH rule is defined (safety check).
2. Reset UFW to factory defaults.
3. Set default inbound policy to deny.
4. Set default outbound policy to allow.
5. Apply all rules from `ufw_rules`.
6. Enable UFW with logging.
7. Configure log rotation for `/var/log/ufw.log`.

---

### Step-by-Step Instructions

#### Step 1: Safety check — confirm SSH rule exists

**Purpose**: Prevent a situation where UFW is enabled with no SSH rule, cutting off remote access.

Before making any changes, verify your rule list contains an SSH entry:

```bash
# Review the rules you are about to apply
cat <<'EOF'
ufw_rules:
  - { port: "22", protocol: "tcp", comment: "SSH" }
  - { port: "80", protocol: "tcp", comment: "HTTP" }
  - { port: "443", protocol: "tcp", comment: "HTTPS" }
EOF
```

If there is no SSH rule, add one before proceeding.

---

#### Step 2: Reset UFW to defaults

**Purpose**: Wipe any previously applied rules to ensure a clean, predictable state.

```bash
sudo ufw reset
```

**Warning**: This disables UFW and removes all rules. You will be prompted to confirm. Ensure you have console access or the SSH session will not drop (UFW is disabled after reset, so traffic flows freely until re-enabled).

---

#### Step 3: Set default policies

**Purpose**: All traffic not explicitly permitted should be blocked inbound; all outbound traffic is allowed.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

---

#### Step 4: Apply UFW rules from inventory

**Purpose**: Open exactly the ports declared in the `ufw_rules` inventory variable.

For the default client inventory (`client/inventories/production/group_vars/all.yml`), the rules are:

```bash
sudo ufw allow proto tcp from any to any port 22 comment 'SSH'
sudo ufw allow proto tcp from any to any port 80 comment 'HTTP'
sudo ufw allow proto tcp from any to any port 443 comment 'HTTPS'
```

The general pattern for each rule is:

```bash
sudo ufw allow proto <protocol> from any to any port <port> comment '<comment>'
```

---

#### Step 5: Enable UFW with logging

**Purpose**: Activate the firewall and turn on logging so blocked packets are recorded.

```bash
sudo ufw enable
sudo ufw logging on
```

When prompted "Command may disrupt existing ssh connections. Proceed with operation (y|n)?", type `y`.

---

#### Step 6: Configure UFW log rotation

**Purpose**: Prevent `/var/log/ufw.log` from growing indefinitely.

Create `/etc/logrotate.d/uwf`:

```bash
sudo nano /etc/logrotate.d/uwf
```

```
/var/log/ufw.log {
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
sudo chmod 0644 /etc/logrotate.d/uwf
sudo chown root:root /etc/logrotate.d/uwf
```

> **Note**: The file is named `uwf` (not `ufw`) — this is the spelling used in the playbook.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `ufw_rules` | See below | List of firewall rules to apply |

**`ufw_rules` structure** (from `client/inventories/production/group_vars/all.yml`):

```yaml
ufw_rules:
  - { port: "22", protocol: "tcp", comment: "SSH" }
  - { port: "80", protocol: "tcp", comment: "HTTP" }
  - { port: "443", protocol: "tcp", comment: "HTTPS" }
```

Each entry must have `port`, `protocol`, and `comment`. At least one entry must have `comment: "SSH"` or the role will fail the safety assertion.

**NAS-specific additional rules** (from `update/inventories/production/host_vars/primary_nas.yml`):

```yaml
ufw_rules:
  - { port: "137", protocol: "udp", comment: "Samba NetBIOS Name Service" }
  - { port: "138", protocol: "udp", comment: "Samba NetBIOS Datagram" }
  - { port: "139", protocol: "tcp", comment: "Samba NetBIOS Session" }
  - { port: "445", protocol: "tcp", comment: "Samba SMB over TCP" }
```

---

## Handlers & Service Management

This role has no Ansible handlers. UFW is enabled directly in the task, not through a handler.

---

## Verification

```bash
# Check UFW status and all rules
sudo ufw status verbose

# Check default policies
sudo ufw status verbose | grep Default

# Confirm SSH is reachable (from another machine)
ssh <username>@<host>

# Check logs
sudo tail -20 /var/log/ufw.log
```

---

## Rollback / Uninstall

To disable UFW entirely (open firewall — emergency access):

```bash
sudo ufw disable
```

To remove specific rules:

```bash
sudo ufw delete allow 80/tcp
```

To fully reset:

```bash
sudo ufw reset
```

---

## Troubleshooting

**SSH connection dropped after ufw enable**
This should not happen if the SSH rule was applied before enabling UFW. If it does, use console access to run `sudo ufw allow 22/tcp` and `sudo ufw enable`.

**ufw reset asks for confirmation but script is non-interactive**
In Ansible, the `community.general.ufw` module with `state: reset` handles this without a prompt. Manually, confirm with `y`.

**Rules not applying in expected order**
UFW processes rules in the order they were added. After `ufw reset`, rules are applied fresh from the list. Use `sudo ufw status numbered` to see the current order.

**Blocked traffic not appearing in /var/log/ufw.log**
Check that `logging on` was set: `sudo ufw status verbose | grep Logging`. Also check rsyslog is running: `sudo systemctl status rsyslog`.
