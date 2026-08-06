# Base Packages and Automatic Security Updates

## What this is

The first thing done to a freshly installed Debian or Ubuntu machine. It brings the system fully up to date, installs the command-line tools every later step depends on (`sudo`, `ufw`, `logrotate`, `jq`, `curl`, `gnupg`, and a set of everyday utilities), adds the third-party repository for `eza`, and turns on unattended security upgrades so the machine keeps patching itself from then on.

Nothing here is network-facing and nothing here is host-specific — every machine gets exactly this same set.

## Before you start

- A fresh Debian or Ubuntu install that you can reach over SSH, or a console session on it.
- Root, or an account that can use `sudo`. Confirm:

  ```bash
  sudo -v && echo "sudo ok"
  ```

  On a minimal Debian install `sudo` may not be present at all. In that case log in as `root` and run every command below without the `sudo` prefix; `sudo` is installed in Step 2 and will be available for everything afterwards.

- Outbound HTTPS to the distribution mirrors, `raw.githubusercontent.com` and `deb.gierens.de`. Confirm:

  ```bash
  getent hosts deb.debian.org >/dev/null && echo "dns ok"
  curl -sfI https://deb.gierens.de/ >/dev/null && echo "reachable"
  ```

## Setup

### Overview

1. Update the package index and perform a full distribution upgrade.
2. Install the baseline package set.
3. Add the `eza` repository signing key and install `eza`.
4. Write the automatic-upgrade policy file.

---

#### Step 1: Full system upgrade

```bash
sudo apt-get update
sudo apt-get -y dist-upgrade
sudo apt-get -y autoclean
sudo apt-get -y autoremove
```

**Explanation**: Start from a fully patched baseline before adding anything, so later failures can never be blamed on stale libraries. `dist-upgrade` is used rather than plain `upgrade` because it is allowed to install and remove packages to satisfy changed dependencies — on Debian point releases and Ubuntu LTS updates, plain `upgrade` silently holds packages back and leaves the system half-upgraded. `autoclean` drops cached `.deb` files that no longer exist in any configured repository, and `autoremove` drops libraries that were pulled in as dependencies and are no longer required by anything installed. Doing both here rather than only at the end keeps the disk footprint of the upgrade from compounding across a long bootstrap.

If a kernel or `libc` was upgraded the machine is now flagged for a reboot. Do not reboot yet — that is the very last thing you do, once everything else is in place.

---

#### Step 2: Install the baseline package set

```bash
sudo apt-get install -y \
  sudo \
  acl \
  apt-transport-https \
  bat \
  btop \
  ca-certificates \
  curl \
  fd-find \
  git \
  gnupg \
  iputils-ping \
  jq \
  logrotate \
  mc \
  nano \
  ncdu \
  ripgrep \
  ufw \
  unattended-upgrades \
  wget
```

**Explanation**: This list is deliberately fixed and identical on every machine, so any host can be debugged with the same muscle memory. Roughly half of it is load-bearing for later steps and half is for the human at the keyboard:

| Package | Why it is here |
|---------|----------------|
| `sudo` | Privilege escalation for the non-root accounts created later |
| `acl` | Lets a privileged process drop to another user and still read files it just wrote — needed when running a command as a freshly created account |
| `apt-transport-https` | Fetch packages over HTTPS (needed by third-party repositories) |
| `bat` | Syntax-highlighting pager; the per-account shell aliases map `cat` and `less` onto it |
| `btop` | Interactive process/resource monitor |
| `ca-certificates` | Trusted roots, without which every HTTPS fetch below fails |
| `curl` | Fetches the Docker installer and is used for health checks |
| `fd-find` | Fast `find` replacement; aliased to `fd` |
| `git` | Cloning and inspecting repositories on the host |
| `gnupg` | De-armouring repository signing keys |
| `iputils-ping` | `ping`, the most basic connectivity test there is |
| `jq` | JSON validation — the Docker daemon config is checked with it before the daemon is restarted |
| `logrotate` | Later steps drop rotation policies into `/etc/logrotate.d/` |
| `mc` | Two-pane file manager, useful over a slow console |
| `nano` | Terminal text editor |
| `ncdu` | Interactive disk usage browser, for when a container fills the disk |
| `ripgrep` | Fast recursive grep; aliased to `grep` |
| `ufw` | The firewall configured later in the bootstrap |
| `unattended-upgrades` | The daemon that Step 4 switches on |
| `wget` | Second downloader, used where `curl` is inconvenient |

`bat`, `fd-find` and `ripgrep` install their binaries as `batcat`, `fdfind` and `rg` on Debian and Ubuntu, not as `bat`, `fd` and `grep`. The per-account shell aliases account for that.

---

#### Step 3: Install eza

```bash
sudo mkdir -p /etc/apt/keyrings
sudo chmod 0755 /etc/apt/keyrings

wget -O /tmp/eza-deb.asc https://raw.githubusercontent.com/eza-community/eza/main/deb.asc
sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg /tmp/eza-deb.asc
sudo chmod 0644 /etc/apt/keyrings/gierens.gpg

echo 'deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main' \
  | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null

sudo apt-get update
sudo apt-get install -y eza
```

**Explanation**: `eza` is a modern `ls` replacement and is not in the Debian or Ubuntu archives, so it comes from the maintainer's own repository. The key is downloaded to a file first and de-armoured in a separate command rather than piped straight from the network into `gpg` — that way you can inspect `/tmp/eza-deb.asc` before it is trusted, and a truncated download fails loudly instead of producing a half-written keyring.

The key goes in `/etc/apt/keyrings/` and is bound to this one repository with `signed-by=` rather than added to the global trusted set. A key in the global set can sign *any* package from *any* repository; scoping it means a compromise of this third-party repository cannot be used to forge a `libc` update.

`gpg --dearmor` refuses to overwrite an existing output file, so if you are re-running this, delete `/etc/apt/keyrings/gierens.gpg` first or skip that command.

---

#### Step 4: Enable automatic upgrades

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade::InstallOnShutdown "0";
EOF
sudo chown root:root /etc/apt/apt.conf.d/20auto-upgrades
sudo chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades
```

**Explanation**: The `unattended-upgrades` package is inert until a policy file switches it on. Each value is a period in days, where `"1"` means "on every run of the daily timer" and `"0"` means "never":

| Directive | Value | Meaning |
|-----------|-------|---------|
| `Update-Package-Lists` | `"1"` | Refresh the package index daily |
| `Unattended-Upgrade` | `"1"` | Apply eligible upgrades daily |
| `AutocleanInterval` | `"7"` | Prune the download cache weekly |
| `Unattended-Upgrade::InstallOnShutdown` | `"0"` | Install during the timer window, not at shutdown |

`InstallOnShutdown` is explicitly disabled because these machines run services other machines depend on: an upgrade that runs at shutdown stretches an already-disruptive reboot into an unpredictable one, and a power loss mid-install leaves `dpkg` half-configured. Applying upgrades while the machine is up means a failure is visible in the logs and recoverable over SSH.

What actually gets upgraded is decided by `/etc/apt/apt.conf.d/50unattended-upgrades`, which ships with the package and defaults to the security pocket only. This step does not touch that file, so the machine takes security patches automatically and leaves everything else to you.

---

## Values to fill in

Nothing to fill in — the package list and the upgrade policy are identical on every machine.

## Verification

```bash
# Every baseline package present and installed
dpkg -l sudo acl apt-transport-https bat btop ca-certificates curl fd-find git \
        gnupg iputils-ping jq logrotate mc nano ncdu ripgrep ufw \
        unattended-upgrades wget | grep -c '^ii'

# eza installed, and from the third-party repository
eza --version
apt-cache policy eza

# The signing key is scoped to that one repository
ls -l /etc/apt/keyrings/gierens.gpg
cat /etc/apt/sources.list.d/gierens.list

# Automatic upgrades configured and the timers active
cat /etc/apt/apt.conf.d/20auto-upgrades
systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager

# Dry-run the unattended upgrade to see what it would take
sudo unattended-upgrade --dry-run --debug
```

The `dpkg -l | grep -c '^ii'` count should equal the number of packages listed.

## Updating & day-to-day

- Security patches land on their own via the daily timers. Read what was applied with:

  ```bash
  sudo tail -50 /var/log/unattended-upgrades/unattended-upgrades.log
  ```

- Everything else stays a manual decision:

  ```bash
  sudo apt-get update && sudo apt-get dist-upgrade
  ```

- Check whether an automatic upgrade left the machine wanting a reboot:

  ```bash
  [ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
  ```

- Adding a package to the baseline means adding it on every machine, otherwise the fleet drifts and a command that works on one host is missing on the next.

## Rollback / Uninstall

Turn off automatic upgrades:

```bash
sudo rm /etc/apt/apt.conf.d/20auto-upgrades
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
```

Remove the third-party repository and its key:

```bash
sudo apt-get purge -y eza
sudo rm -f /etc/apt/sources.list.d/gierens.list /etc/apt/keyrings/gierens.gpg
sudo apt-get update
```

Individual baseline packages come off with `sudo apt-get remove <package>`. Do not remove `sudo` unless you have a working root login on the console — you will have no way to escalate afterwards. Do not remove `ufw` while the firewall is active; disable it first.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `apt-get update` reports `NO_PUBKEY` or an expired key for `deb.gierens.de` | The signing key was rotated, or the de-armour was skipped. Delete `/etc/apt/keyrings/gierens.gpg`, re-download `deb.asc`, re-run `gpg --dearmor`. |
| `gpg: cannot open '/etc/apt/keyrings/gierens.gpg': File exists` | The keyring is already there from an earlier run. Leave it, or `sudo rm` it and re-run the de-armour. |
| `dist-upgrade` holds packages back | Something needs a decision it will not make unattended. Run `sudo apt-get dist-upgrade` interactively and read the dependency changes before accepting. |
| Automatic upgrades never run | Check `systemctl status apt-daily.timer apt-daily-upgrade.timer`. On a machine powered off during the timer window the run is skipped; `sudo systemctl start apt-daily-upgrade.service` forces it. |
| `bat`, `fd` or `grep` behave unexpectedly for a user | Those names are aliases onto `batcat`, `fdfind` and `rg`. Prefix with a backslash (`\grep`) to get the original binary. |
| `E: Unable to locate package eza` | The repository line was written but the index was not refreshed. Run `sudo apt-get update` again and check `apt-cache policy eza` lists `deb.gierens.de`. |
| Disk fills up during the upgrade | `/var/cache/apt/archives` holds every downloaded `.deb`. `sudo apt-get clean` empties it entirely. |
