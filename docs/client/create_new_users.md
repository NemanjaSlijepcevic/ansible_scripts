# Role: create_new_users

## Purpose

This role creates system user accounts on the target machine. It handles two distinct use cases:

1. **Pre-configured users** (`default_user` list in group_vars): These are users (both human and robot/service accounts) defined in the inventory. They are always created.
2. **Interactive new user** (optional): When the playbook is run with a non-empty `new_user` prompt, a brand-new user is created with a freshly generated ed25519 SSH key pair. The private key is saved locally on the Ansible control machine inside `client/roles/create_new_users/files/`.

Every user is:
- Created with a home directory and `/bin/bash` shell.
- Added to the `sudo` and `ssh` groups.
- Given a sudoers entry (with password for humans, passwordless for robot accounts).
- Provisioned with an `authorized_keys` file.
- Configured with `alias rm='rm -i'` in their `.bashrc` as a safety measure.

## Prerequisites

- `prepare_ssh` role must have run (provides the `ssh` group).
- `install_packages` role must have run (provides `sudo`).
- `/etc/sudoers.d/` must exist (created by this role if absent).
- For interactive new-user creation: `openssh-keygen` must be available on the **Ansible control machine**.

## Manual Execution Guide

### Overview

1. (Optional) Generate an ed25519 SSH key pair locally.
2. Hash the user's password using SHA-512.
3. Ensure `/etc/sudoers.d/` exists.
4. For each user: create the account, write the sudoers file, deploy the authorized SSH key, and set the `.bashrc` alias.
5. For each user: install Oh My Bash with the Pure theme.

---

### Step-by-Step Instructions

#### Step 1: (Optional) Generate a new SSH key pair

**Purpose**: When adding a new interactive user, generate a timestamped ed25519 key pair on the local machine. This step is only needed for brand-new users not already in the inventory.

```bash
# Run on the Ansible control machine (your laptop/workstation)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
NEW_USER="alice"   # replace with actual username
ssh-keygen -t ed25519 -f "client/roles/create_new_users/files/${NEW_USER}_${TIMESTAMP}" -N ""
```

This produces two files:
- `client/roles/create_new_users/files/alice_<timestamp>` — private key (keep this, give it to the user)
- `client/roles/create_new_users/files/alice_<timestamp>.pub` — public key (uploaded to the server)

---

#### Step 2: Hash the user password

**Purpose**: Linux stores passwords as hashed strings, not plain text. The SHA-512 crypt format is required.

```bash
# On any Linux machine with Python 3
python3 -c "import crypt; print(crypt.crypt('MyPlainPassword', crypt.mksalt(crypt.METHOD_SHA512)))"
```

Copy the output — it starts with `$6$` — and use it as the `password` value for the user entry.

---

#### Step 3: Ensure /etc/sudoers.d exists

**Purpose**: The sudoers drop-in directory may not exist on minimal installs.

```bash
sudo mkdir -p /etc/sudoers.d
sudo chown root:root /etc/sudoers.d
sudo chmod 0750 /etc/sudoers.d
```

---

#### Step 4: Create each user account

**Purpose**: Create the OS user with a home directory, correct shell, and group membership.

Replace `<username>` and `<hashed_password>` with real values:

```bash
sudo useradd \
  --create-home \
  --shell /bin/bash \
  --groups sudo,ssh \
  --password '<hashed_password>' \
  <username>
```

**Explanation**:
- `--create-home` creates `/home/<username>`.
- `--shell /bin/bash` sets the login shell.
- `--groups sudo,ssh` adds the user to both groups (membership in `ssh` allows SSHD access when `AllowGroups ssh` is set; membership in `sudo` allows privilege escalation).
- `--password` accepts the pre-hashed SHA-512 string from Step 2.

---

#### Step 5: Write the sudoers drop-in file

**Purpose**: Grant the user sudo privileges. Human users are required to enter their password; robot/service accounts get passwordless sudo.

For a **human user**:

```bash
echo '<username> ALL=(ALL) ALL' | sudo tee /etc/sudoers.d/<username>
sudo chmod 0440 /etc/sudoers.d/<username>
sudo chown root:root /etc/sudoers.d/<username>
```

For a **robot/service account**:

```bash
echo '<username> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/<username>
sudo chmod 0440 /etc/sudoers.d/<username>
sudo chown root:root /etc/sudoers.d/<username>
```

Validate the sudoers file immediately after writing:

```bash
sudo visudo -cf /etc/sudoers
```

---

#### Step 6: Deploy the SSH public key

**Purpose**: Allow the user to log in with their private key instead of a password.

```bash
sudo mkdir -p /home/<username>/.ssh
sudo chmod 0700 /home/<username>/.ssh
sudo chown <username>:<username> /home/<username>/.ssh

sudo cp /path/to/<username>.pub /home/<username>/.ssh/authorized_keys
sudo chmod 0644 /home/<username>/.ssh/authorized_keys
sudo chown <username>:<username> /home/<username>/.ssh/authorized_keys
```

**Explanation**: `authorized_keys` must be owned by the user and not be world-writable, or SSHD will refuse to use it.

---

#### Step 7: Add the rm safety alias

**Purpose**: Prevent accidental recursive deletions by making `rm` prompt for confirmation.

```bash
sudo bash -c "echo \"alias rm='rm -i'\" >> /home/<username>/.bashrc"
sudo chown <username>:<username> /home/<username>/.bashrc
```

---

#### Step 8: Install Oh My Bash

**Purpose**: Give each user the Oh My Bash shell framework with the Pure theme. The installer is downloaded to a file first, executed as the target user, then removed — the script is never piped from the network straight into a shell.

```bash
# Download the installer into the user's home
sudo wget -O /home/<username>/.oh-my-bash-install.sh \
  https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh
sudo chown <username>:<username> /home/<username>/.oh-my-bash-install.sh
sudo chmod 0755 /home/<username>/.oh-my-bash-install.sh

# Run it as the target user (skips if ~/.oh-my-bash already exists)
sudo -u <username> bash /home/<username>/.oh-my-bash-install.sh --unattended

# Remove the installer
sudo rm /home/<username>/.oh-my-bash-install.sh

# Set the Pure theme
sudo -u <username> sed -i 's/^OSH_THEME=.*/OSH_THEME="pure"/' /home/<username>/.bashrc
```

**Explanation**:
- `--unattended` prevents the installer from switching the current shell or prompting.
- The role uses `creates: /home/<username>/.oh-my-bash` so the install only runs once per user.

---

## Configuration Reference

### Variables (from `client/inventories/production/group_vars/all.yml`)

| Variable | Example | Description |
|----------|---------|-------------|
| `default_user` | See below | List of user objects to always create |
| `new_user` | `"alice"` | Username for the interactive new-user prompt (empty string = skip) |
| `user_password` | prompt | Plain-text password for the new interactive user |
| `user_password_confirm` | prompt | Confirmation of the above (must match) |

**`default_user` list structure**:

```yaml
default_user:
  - name: "<robot-username>"     # system robot account
    password: "$6$..."           # SHA-512 hashed password
    key_path: "<robot-username>.pub"  # relative path inside roles/create_new_users/files/
    robot: true                  # passwordless sudo
  - name: "<username>"
    password: "$6$..."
    key_path: "<username>.pub"
    robot: false                 # requires password for sudo
```

---

## Handlers & Service Management

| Handler | Trigger | Manual equivalent |
|---------|---------|-------------------|
| `Validate sudoers` | sudoers file written | `sudo visudo -cf /etc/sudoers` |

No services are restarted by this role.

---

## Verification

```bash
# Confirm user exists
id <username>

# Confirm group memberships
groups <username>

# Confirm sudoers entry
sudo cat /etc/sudoers.d/<username>

# Confirm authorized_keys
cat /home/<username>/.ssh/authorized_keys

# Test SSH login from control machine
ssh -i client/roles/create_new_users/files/<username>_<timestamp> <username>@<host>
```

---

## Rollback / Uninstall

```bash
# Remove the user and home directory
sudo userdel -r <username>

# Remove the sudoers drop-in
sudo rm /etc/sudoers.d/<username>
```

---

## Troubleshooting

**SSH key login fails**
Check permissions: `~/.ssh` must be `0700`, `authorized_keys` must be `0644` or `0600`, both owned by the user. Check `/var/log/auth.log` for SSHD rejection reasons.

**visudo validation fails**
There is a syntax error in a sudoers file. Run `sudo visudo -cf /etc/sudoers.d/<username>` to identify it. Do not modify `/etc/sudoers.d/` files directly while the validation is failing.

**Passwords do not match error**
The interactive `new_user` flow compares `user_password` and `user_password_confirm`. If they differ the playbook stops. Re-run and type the same password both times.

**User not in ssh group**
The SSHD `AllowGroups ssh` directive (set by `protect_ssh`) will deny logins from users not in the `ssh` group. Add manually: `sudo usermod -aG ssh <username>`.
