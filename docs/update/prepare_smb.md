# Role: prepare_smb

## Purpose

This role sets up Samba file sharing on the NAS host. It installs the Samba packages, ensures the service is running, creates OS-level system users for each Samba user, creates Samba-specific user accounts (with Samba's separate password database), ensures share directories exist, and deploys the `smb.conf` from a template. The role is idempotent — it only creates users and shares that do not already exist.

## Prerequisites

- The target host is the NAS (`primary_nas`).
- Root or sudo access.
- The `samba.*` variable structure must be defined in `host_vars/primary_nas.yml`.
- Share directories (e.g., `/<data-mount>/<share-name>`) must be on mounted filesystems before this role runs.

## Manual Execution Guide

### Overview

1. Install Samba packages.
2. Start and enable the Samba service.
3. Create system users for each Samba user.
4. Create Samba password database entries.
5. Ensure share directories exist.
6. Deploy `smb.conf`.
7. Restart Samba.

---

### Step-by-Step Instructions

#### Step 1: Install Samba

```bash
sudo apt-get update
sudo apt-get install -y samba samba-common smbclient
```

---

#### Step 2: Start and enable Samba

```bash
sudo systemctl enable smbd
sudo systemctl start smbd
```

---

#### Step 3: Create system users

Samba users need corresponding OS system accounts. These accounts are created without a home directory and with a no-login shell (they exist only for Samba):

```bash
# For each user in samba.users (from host_vars/primary_nas.yml):
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups sambashare <username1>
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups sambashare <username2>
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups sambashare <guest-username>
```

**Explanation**: The `sambashare` group is used by some Samba configurations to limit which users can authenticate. If a user already exists, `useradd` will exit with a non-zero code — this is harmless and can be ignored.

---

#### Step 4: Create Samba users

Samba maintains its own password database (`/etc/samba/smbpasswd` or TDB) separate from `/etc/shadow`. Use `smbpasswd` to create entries:

```bash
# For each user — provide the password twice via stdin
echo -e '<password1>\n<password1>' | sudo smbpasswd -s -a <username1>
echo -e '<password2>\n<password2>' | sudo smbpasswd -s -a <username2>
echo -e '<password3>\n<password3>' | sudo smbpasswd -s -a <guest-username>
```

**Explanation**:
- `-s` reads password from stdin (non-interactive).
- `-a` adds a new Samba user.

To check if a user already exists in the Samba database:

```bash
sudo pdbedit -L <username1> && echo "exists" || echo "not found"
```

---

#### Step 5: Ensure share directories exist

Create the directories if they are not already present (they should exist as they are on mounted storage), one per entry in `samba.shares`:

```bash
sudo mkdir -p /<data-mount>/<share-name-1>
sudo mkdir -p /<data-mount>/<share-name-2>
sudo chmod 0755 /<data-mount>/<share-name-1>
sudo chmod 0755 /<data-mount>/<share-name-2>
```

---

#### Step 6: Deploy smb.conf

The configuration file is generated from `prepare_smb/templates/smb.conf.j2`. The rendered output for the NAS host is:

```bash
sudo nano /etc/samba/smb.conf
```

```ini
[global]
   workgroup = WORKGROUP
   server string = <server-name>
   security = user
   map to guest = never
   log file = /var/log/samba/log.%m
   max log size = 1000
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   # required alongside unix password sync since samba 4.15.13-0ubuntu1.12 —
   # testparm hard-errors without it and the samba package fails to configure
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .

# One [section] per entry in samba.shares:

[<share-name-1>]
path = /<data-mount>/<share-name-1>
browseable = Yes
writable = Yes
guest ok = Yes
valid users = <username1> <username2>

[<share-name-2>]
path = /<data-mount>/<share-name-2>
browseable = Yes
writable = Yes
guest ok = Yes
valid users = <username1> <username2>
```

```bash
sudo chmod 0644 /etc/samba/smb.conf
sudo chown root:root /etc/samba/smb.conf
```

---

#### Step 7: Restart Samba

```bash
sudo systemctl restart smbd
```

---

## Configuration Reference

### Variables (from `host_vars/primary_nas.yml`)

```yaml
samba:
  workgroup: "WORKGROUP"
  name: <server-name>
  defaults:
    browseable: "Yes"
    writable: "Yes"
    guest_ok: "Yes"
    valid_users: ["<username1>", "<username2>"]
  shares:
    - { name: "<share-name-1>", path: "/<data-mount>/<share-name-1>" }
    - { name: "<share-name-2>", path: "/<data-mount>/<share-name-2>" }
  users:
    - user: "<username1>"
      password: "<secret>"
      groups: ["sambashare"]
    - user: "<username2>"
      password: "<secret>"
      groups: ["sambashare"]
    - user: "<guest-username>"
      password: "<secret>"
      groups: ["sambashare"]
```

| Variable | Description |
|----------|-------------|
| `samba.workgroup` | Windows workgroup name |
| `samba.name` | Server string displayed to clients |
| `samba.defaults.*` | Default browseable/writable/guest settings applied to shares that don't override them |
| `samba.shares` | List of share definitions; each gets a `[section]` in smb.conf |
| `samba.users` | List of user definitions; each gets a system account and Samba password entry |

### Templates & Configuration Files

| File | Destination | Purpose |
|------|------------|---------|
| `smb.conf.j2` | `/etc/samba/smb.conf` | Samba server and share configuration |

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Restart Samba` | `smb.conf` changed | `sudo systemctl restart smbd` |

---

## Verification

```bash
# Samba running
sudo systemctl status smbd

# Validate smb.conf
sudo testparm -s

# List Samba users
sudo pdbedit -L

# Test connection from Windows / Linux client
smbclient -L //<ip-address> -U <username1>

# Mount a share (Linux)
sudo mount -t cifs //<ip-address>/<share-name-1> /mnt/<share-name-1> -o username=<username1>,password=<password>
```

---

## Rollback / Uninstall

```bash
sudo systemctl stop smbd
sudo apt-get purge -y samba samba-common smbclient
sudo rm -rf /etc/samba /var/lib/samba
```

To remove Samba users from the password database without removing the OS accounts:

```bash
sudo smbpasswd -x <username1>
sudo smbpasswd -x <username2>
sudo smbpasswd -x <guest-username>
```

---

## Troubleshooting

**"NT_STATUS_LOGON_FAILURE" when connecting**
The Samba password is wrong or the user does not exist in `pdbedit -L`. Reset the password: `sudo smbpasswd <username>`.

**"NT_STATUS_ACCESS_DENIED" for a share**
Check that the `valid users` list in `smb.conf` includes the connecting user, and that the underlying directory has appropriate OS permissions.

**Shares not visible on the network**
Check that UDP ports 137 and 138, and TCP ports 139 and 445 are open in UFW. Also verify `nmbd` is running if NetBIOS name resolution is needed.

**testparm shows warnings**
Run `sudo testparm -s 2>&1 | grep -i warn` to see specific warnings. Most are informational and do not prevent Samba from working.
