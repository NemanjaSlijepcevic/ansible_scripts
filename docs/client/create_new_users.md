# Creating User Accounts

## What this is

Creates the login accounts on a machine and gives each one everything it needs to be usable: a home directory, a Bash shell, membership of `sudo` and `ssh`, a sudo policy file, an SSH public key in `authorized_keys`, a shared set of shell aliases, and the Oh My Bash prompt framework.

Two kinds of account are created, and the only difference is the sudo policy:

- **Human accounts** — `sudo` asks for the account's own password.
- **Automation accounts** — `sudo` never asks. These are the accounts a remote deployment process logs in as; a password prompt in the middle of an unattended run just hangs forever.

This runs on every machine, and it must run *before* password logins are switched off. That ordering is the whole safety net: you create the account, you prove its key works, and only then do you remove the fallback.

## Before you start

- Root or `sudo` on the target machine. Confirm:

  ```bash
  sudo -v && echo "sudo ok"
  ```

- The `sudo` package installed, or nothing you write to `/etc/sudoers.d/` means anything:

  ```bash
  command -v sudo || sudo apt-get install -y sudo
  ```

- A group named `ssh` must exist, because every account is put into it as it is created. Adding a user to a missing group fails outright. Create it if it is not there:

  ```bash
  getent group ssh || sudo groupadd --system ssh
  ```

- Outbound HTTPS to `raw.githubusercontent.com` on the target machine, for the shell framework:

  ```bash
  curl -sfI https://raw.githubusercontent.com/ >/dev/null && echo "reachable"
  ```

- A shell on your own workstation with `ssh-keygen`, if you are generating a new key pair.
- Keep your current session open until the new account's key login is proven. Do not log out to "test it" — open a second terminal.

## Setup

### Overview

1. Generate an SSH key pair on your workstation for each new account.
2. Turn each account's password into a hash.
3. Create the sudo drop-in directory.
4. Create the account.
5. Write its sudo policy and validate it.
6. Install its SSH public key.
7. Install the shared shell aliases.
8. Install Oh My Bash and set the prompt theme.

Steps 4 to 8 are repeated once per account.

---

#### Step 1: Generate an SSH key pair

Run this on your **workstation**, not on the target machine:

```bash
NEW_USER=<username>
TIMESTAMP=$(date +%Y%m%d%H%M%S)
ssh-keygen -t ed25519 -N '' -C "${NEW_USER}" -f "${NEW_USER}_${TIMESTAMP}.pem"
chmod 0600 "${NEW_USER}_${TIMESTAMP}.pem"
```

This produces two files:

- `<username>_<timestamp>.pem` — the private key. Never leaves your workstation.
- `<username>_<timestamp>.pem.pub` — the public key. This is what gets installed on the machine in Step 6.

**Explanation**: Ed25519 rather than RSA — the keys are a fraction of the size, verification is faster, and there is no key-length parameter to get wrong. The timestamp in the filename means rotating a key is additive: generate a new pair, install it, confirm it works, then delete the old one, with both on disk and clearly ordered while you do it.

The private key gets `0600` immediately. `ssh` refuses to use a private key that is readable by anyone but its owner and simply skips it, which shows up as a confusing "Permission denied (publickey)" rather than an obvious permissions error.

The `.pem` extension is not cosmetic. Anywhere these files are stored alongside code, the ignore rules that keep secrets out of version control match on extension — a key saved without it is a key one `git add .` away from being published. Note that the *public* half is `.pem.pub`, and it is treated as sensitive too: its comment field carries a real username.

If the account already has a key you intend to keep using, skip this step and use the existing `.pub` file.

---

#### Step 2: Hash the account password

```bash
openssl passwd -6
```

Type the password twice when prompted. Copy the output — it starts with `$6$` — and keep it for Step 4.

**Explanation**: `/etc/shadow` stores a hash, never a password, so you must hand `useradd` a hash. `-6` selects SHA-512 crypt, which is the format Debian and Ubuntu use; handing over anything else produces an account that can never authenticate, and the failure is silent until someone tries to log in.

`openssl passwd` reads the password interactively rather than taking it as an argument. That matters: a password on a command line is visible in `ps` output to every user on the machine for the duration of the call, and is written verbatim into your shell history file.

The account still gets a password even though SSH logins will be key-only. The password is what `sudo` prompts for on human accounts, and what lets you in at the physical console when the network is down.

---

#### Step 3: Create the sudo drop-in directory

```bash
sudo mkdir -p /etc/sudoers.d
sudo chown root:root /etc/sudoers.d
sudo chmod 0750 /etc/sudoers.d
```

**Explanation**: Per-account policy files go here instead of into `/etc/sudoers` directly. A syntax error in `/etc/sudoers` breaks `sudo` for everybody on the machine at once, with no way to fix it except a root console; a broken drop-in only affects the one account, and the whole file can be deleted blind to recover.

`0750` keeps the directory listing away from ordinary users. Who has passwordless root on this machine is not information an unprivileged account needs, and `sudo` itself runs as root, so it does not care.

---

#### Step 4: Create the account

```bash
sudo useradd \
  --create-home \
  --shell /bin/bash \
  --groups sudo,ssh \
  --password '<password-hash>' \
  <username>
```

**Explanation**: Everything the account needs, in one call.

- `--create-home` makes `/home/<username>`, owned by the account, which every later step writes into.
- `--shell /bin/bash` — the aliases and prompt framework installed later are Bash-specific, and the default on Debian is `/bin/sh` for a new account.
- `--groups sudo,ssh` — `sudo` is what the distribution's stock sudo policy grants escalation to; `ssh` is the membership marker that lets the daemon be restricted to provisioned accounts with a single `AllowGroups ssh` line, instead of an account list that has to be edited every time someone joins.
- `--password` takes the SHA-512 hash from Step 2, in single quotes. Without the quotes the shell mangles the `$6$` — it expands `$6` as a positional parameter and you silently install a truncated, unusable hash.

For an account that already exists, adjust it instead:

```bash
sudo usermod --shell /bin/bash --append --groups sudo,ssh <username>
sudo chpasswd --encrypted <<<'<username>:<password-hash>'
```

Use `--append` when modifying an existing account. Without it, `usermod --groups` *replaces* every supplementary group the account has, which will quietly kick it out of `docker` or any other group it was relying on.

---

#### Step 5: Write the sudo policy

For a **human** account:

```bash
printf '%s ALL=(ALL) ALL' '<username>' | sudo tee /etc/sudoers.d/<username> >/dev/null
```

For an **automation** account:

```bash
printf '%s ALL=(ALL) NOPASSWD:ALL' '<username>' | sudo tee /etc/sudoers.d/<username> >/dev/null
```

Then, for either:

```bash
sudo chown root:root /etc/sudoers.d/<username>
sudo chmod 0440 /etc/sudoers.d/<username>
sudo visudo -cf /etc/sudoers && echo "sudoers ok"
```

**Explanation**: `ALL=(ALL) ALL` reads as "on any host, may run as any user, any command" — with a password prompt, because that is `sudo`'s default. `NOPASSWD:ALL` is the same grant with the prompt removed.

Passwordless escalation is reserved for accounts that are driven by software. A human at a keyboard walking away from an unlocked terminal is the exact case the password prompt defends against; an unattended deployment process has no one to type it, and would hang until it times out. It is a deliberate trade, made per account, not a convenience switched on globally.

`0440 root:root` is not optional — `sudo` refuses to read a policy file that is writable by anyone other than root, or that is group-writable, and ignores the file entirely. An ignored policy file looks exactly like a policy that was never written.

The validation command is the important half of this step. `visudo -cf /etc/sudoers` parses the main file *and* everything it includes from `/etc/sudoers.d/`, so a typo in what you just wrote is caught here rather than the next time somebody needs root. Run it while your current session still has working `sudo`; if it fails, delete the offending file immediately.

---

#### Step 6: Install the SSH public key

Copy the `.pem.pub` file from your workstation to the machine, then:

```bash
sudo mkdir -p /home/<username>/.ssh
sudo chmod 0700 /home/<username>/.ssh
sudo chown <username>:<username> /home/<username>/.ssh

sudo cp /path/to/<username>_<timestamp>.pem.pub /home/<username>/.ssh/authorized_keys
sudo chown <username>:<username> /home/<username>/.ssh/authorized_keys
sudo chmod 0644 /home/<username>/.ssh/authorized_keys
```

**Explanation**: The public key file *is* the `authorized_keys` file — same one-line format, so it is a copy and not an edit. Copying rather than appending makes the end state exact: whatever keys were there before are gone, and the only key that can open this account is the one you just installed. Appending is how forgotten keys from a decommissioned laptop survive for years.

The daemon checks ownership and permissions before it will trust the file, and refuses it silently if `.ssh` is writable by anyone but the owner — otherwise any user who could write into another's `.ssh` could grant themselves that account. Hence `0700` on the directory and ownership set to the account rather than to `root`, which is what `sudo cp` would otherwise leave behind. `0644` on `authorized_keys` itself is fine; the contents are public by definition.

If you need to add a second key rather than replace, append it as an extra line and keep the same ownership and mode.

---

#### Step 7: Install the shared shell aliases

```bash
sudo tee /home/<username>/.bash_aliases >/dev/null <<'EOF'
OSH_THEME="pure"
# ── Safe file operations
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -pv'

# ── Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# ── Modern CLI replacements
alias ls='eza'
alias ll='eza -lah --git'
alias la='eza -lah'
alias tree='eza --tree'

alias cat='bat --paging=never --style=plain'
alias less='bat --paging=always --style=plain'

alias fd='fdfind'
alias grep='rg'

# ── System
alias df='df -h'
alias free='free -h'
alias ports='ss -tulpen'
alias myip='curl ifconfig.me'

# ── Package management
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias remove='sudo apt remove'

# ── Shell
alias reload='source ~/.bashrc'
EOF
sudo chown <username>:<username> /home/<username>/.bash_aliases
sudo chmod 0644 /home/<username>/.bash_aliases
```

**Explanation**: The stock `.bashrc` on Debian and Ubuntu already sources `~/.bash_aliases` if it exists, so dropping this file in is enough — no edit to `.bashrc` is needed and nothing has to be merged.

The first block is the reason the file exists at all. `cp -i`, `mv -i` and `rm -i` make destructive commands ask first. On a machine hosting other people's data, the cost of a stray `rm -rf` is not recoverable and the cost of one extra keystroke is nothing. When you genuinely mean it, prefix with a backslash — `\rm -rf ./build` — which bypasses the alias for that one invocation.

`fd` and `grep` are aliased onto `fdfind` and `rg` because Debian and Ubuntu ship those tools under different binary names to avoid clashing with existing packages. The `cat`/`less` aliases point at `bat` with paging explicitly forced off and on respectively, so `cat` stays non-interactive and safe to use in a pipeline while `less` behaves like a pager.

These aliases assume `eza`, `bat`, `fd-find` and `ripgrep` are installed. If they are not, `ls` and `cat` are broken for that account until they are — check with `command -v eza batcat fdfind rg`.

The `OSH_THEME` line at the top is picked up by the prompt framework installed in the next step.

---

#### Step 8: Install Oh My Bash

```bash
sudo curl -fsSL -o /home/<username>/.oh-my-bash-install.sh \
  https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh
sudo chown <username>:<username> /home/<username>/.oh-my-bash-install.sh
sudo chmod 0755 /home/<username>/.oh-my-bash-install.sh

# Only if it is not already installed
[ -d /home/<username>/.oh-my-bash ] || \
  sudo -u <username> bash /home/<username>/.oh-my-bash-install.sh --unattended

sudo rm -f /home/<username>/.oh-my-bash-install.sh

sudo -u <username> sed -i 's/^OSH_THEME=.*/OSH_THEME="pure"/' /home/<username>/.bashrc
```

**Explanation**: The installer is downloaded to a file, inspected if you care to, and *then* executed — never `curl … | bash`. Piping a script straight from the network into a shell means the shell starts executing lines while the rest is still in flight, so a connection that dies halfway leaves a partially executed script with no way to know how far it got, and nothing on disk to review afterwards.

It runs as the target account, not as root. The installer writes into `$HOME` and rewrites `.bashrc`; running it as root would leave root-owned files in a user's home directory that the user cannot then modify. That drop from root to another account needs filesystem ACL support present on the machine, which is why the `acl` package belongs in the base install.

The `[ -d … ] ||` guard makes the step repeatable. Re-running the installer over an existing `~/.oh-my-bash` re-clones and clobbers local customisation.

The installer rewrites `.bashrc` from its own copy, which is why the theme is set *after* it runs. Setting it first would be overwritten. The `sed` targets the line the installer writes, so it is an in-place edit rather than an append — running it twice changes nothing.

The installer is removed once it has done its job. A world-executable script sitting in a home directory is a small liability and it is stale the moment upstream changes.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|-------------|-----------|------------------|
| `<username>` | The login name of the account | Lowercase, no spaces. One per human; one per automated process. Used in every step from 4 onwards. |
| `<password-hash>` | SHA-512 crypt hash of the account password | Produced by `openssl passwd -6` in Step 2. Starts with `$6$`. Always single-quote it. Used in Step 4. |
| `<timestamp>` | The `YYYYMMDDHHMMSS` stamp in the key filename | Generated in Step 1. Only needs to be unique per key rotation. |
| Human or automation | Which sudo policy the account gets | A person logging in interactively is human (password prompt). An account used only by unattended tooling is automation (`NOPASSWD`). Decides which command you run in Step 5. |
| `/path/to/<username>_<timestamp>.pem.pub` | Where you copied the public key on the target machine | Anywhere readable by root; it is copied into place and can be deleted after. Used in Step 6. |

## Verification

```bash
# Account exists, with the expected groups
id <username>
getent passwd <username>          # shell must be /bin/bash, home /home/<username>

# Sudo policy is in place, correctly owned, and parses
sudo cat /etc/sudoers.d/<username>
ls -l /etc/sudoers.d/<username>   # -r--r----- root root
sudo visudo -cf /etc/sudoers && echo "sudoers ok"

# What sudo will actually allow this account to do
sudo -l -U <username>

# Key file layout
sudo ls -la /home/<username>/.ssh/
sudo -u <username> ssh-keygen -lf /home/<username>/.ssh/authorized_keys

# Shell environment
sudo ls -l /home/<username>/.bash_aliases
sudo ls -d /home/<username>/.oh-my-bash
sudo grep '^OSH_THEME=' /home/<username>/.bashrc
```

From your workstation, in a **second terminal**, with the current session left open:

```bash
ssh -i <username>_<timestamp>.pem <username>@<ip-address>
```

Once in, confirm escalation works — a human account should prompt for the password, an automation account should not:

```bash
sudo id
```

Do not proceed to disabling password authentication on this machine until that login and that `sudo` have both succeeded.

## Updating & day-to-day

- **Rotate a key**: generate a new pair (Step 1), append the new public key to `authorized_keys`, confirm you can log in with it, then remove the old line. Both keys work during the overlap, so there is no window where you are locked out.
- **Change a password**: `sudo passwd <username>`, or regenerate a hash and apply it with `sudo chpasswd --encrypted <<<'<username>:<password-hash>'`.
- **Add a group**: always `sudo usermod --append --groups <group> <username>`. Omitting `--append` drops every other supplementary group.
- **Promote or demote sudo rights**: rewrite the file in `/etc/sudoers.d/<username>` and re-run `sudo visudo -cf /etc/sudoers`.
- **Lock an account without deleting it**: `sudo usermod --lock --expiredate 1 <username>` and remove its `authorized_keys`. Locking the password alone does not stop a key login.
- Failed and successful logins are recorded in `/var/log/auth.log`.

## Rollback / Uninstall

Remove one account entirely, home directory included:

```bash
sudo rm -f /etc/sudoers.d/<username>
sudo userdel --remove <username>
sudo visudo -cf /etc/sudoers && echo "sudoers ok"
```

Remove the sudo grant but keep the account:

```bash
sudo rm -f /etc/sudoers.d/<username>
sudo gpasswd --delete <username> sudo
```

Remove SSH access but keep the account:

```bash
sudo rm -f /home/<username>/.ssh/authorized_keys
sudo gpasswd --delete <username> ssh
```

Remove just the shell customisations:

```bash
sudo rm -rf /home/<username>/.oh-my-bash /home/<username>/.bash_aliases
```

`userdel` refuses while the account has running processes. Check with `ps -u <username>`, and use `sudo pkill -u <username>` before retrying. Never remove the last account with working sudo unless you have a root console.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Permission denied (publickey)` | Check ownership and modes: `/home/<username>/.ssh` must be `0700` and owned by the account, `authorized_keys` `0644` or stricter and owned by the account. `sudo tail -20 /var/log/auth.log` gives the daemon's actual reason. |
| Login prompts for a password when a key was installed | The daemon never got to the key. Usually the public key was pasted with a line break in the middle, or the wrong private key is being offered — `ssh -v` shows which keys the client tries. |
| `sudo: /etc/sudoers.d/<username> is mode 0644, should be 0440` | The file is too permissive and is being ignored. `sudo chmod 0440` it. |
| `<username> is not in the sudoers file` | The drop-in is missing, misnamed, or contains a typo in the account name. `sudo -l -U <username>` shows what is actually in effect. |
| `visudo -cf` fails and `sudo` is now broken | Recover from a root console, or from a still-open session that already has sudo cached, and delete the offending file in `/etc/sudoers.d/`. This is exactly why the validation runs before you log out. |
| `useradd: group 'ssh' does not exist` | Create it first: `sudo groupadd --system ssh`, then re-run. |
| Password hash rejected, or the account cannot log in at the console | The `$6$` hash was passed unquoted and the shell ate part of it. Regenerate with `openssl passwd -6` and re-apply inside single quotes. |
| Aliases missing after login | `.bash_aliases` is only sourced by an interactive login shell. Confirm the file exists and is owned by the account, and that the account's shell is `/bin/bash`. |
| `ls` or `cat` fails with "command not found" for a user | The aliases point at `eza` and `bat`, which are not installed. Install them, or remove those alias lines. |
| Oh My Bash installer exits immediately | `~/.oh-my-bash` already exists — nothing to do. To reinstall, remove the directory first. |
| Automation account still prompts for a sudo password | The policy file says `ALL=(ALL) ALL` rather than `ALL=(ALL) NOPASSWD:ALL`, or it is being overridden by a later file in `/etc/sudoers.d/` — the last matching rule wins. `sudo -l -U <username>` shows the effective one. |
