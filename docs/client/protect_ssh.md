# Hardening the SSH Server

## What this is

Locks down the SSH daemon on a machine: key-only authentication, no root login, no empty passwords, no TCP forwarding, and verbose authentication logging. It also installs a rotation policy for `/var/log/auth.log`, because turning the log level up makes that file grow considerably faster.

All of the daemon settings go into a single drop-in file, `/etc/ssh/sshd_config.d/10-default-sshd.conf`. The distribution's `/etc/ssh/sshd_config` is not touched, so an OS upgrade cannot present a merge conflict over it and cannot silently revert the hardening.

This is the step that removes your fallback. Everything it disables — passwords, root — is what you would otherwise use to recover. Do it only once a normal account with a working key exists on the machine.

## Before you start

- Root or `sudo` on the machine.
- **At least one non-root account with a working SSH key, proven right now.** From another terminal:

  ```bash
  ssh -i <path-to-private-key> <username>@<ip-address> 'id'
  ```

  That must print the account's `uid`/`gid` without prompting for anything. If it prompts for a password, the key is not working and this procedure will lock you out of the machine.

- That same account must be able to escalate:

  ```bash
  ssh -i <path-to-private-key> <username>@<ip-address> 'sudo -n true || echo needs-password'
  ```

  Either result is fine — what matters is that the account has sudo at all. Confirm with `sudo -l -U <username>` on the machine.

- The drop-in directory must exist and must actually be read by the daemon. Confirm and create if needed:

  ```bash
  grep -q '^Include /etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config && echo "include present"
  sudo mkdir -p /etc/ssh/sshd_config.d && sudo chmod 0755 /etc/ssh/sshd_config.d
  ```

  If the include is missing, add it as the first line of the main config — a drop-in in a directory nobody reads does nothing, and you would believe passwords were off when they were not:

  ```bash
  sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  ```

- `logrotate` installed:

  ```bash
  command -v logrotate || sudo apt-get install -y logrotate
  ```

- **Keep your current session open for the entire procedure**, and do the verification from a second terminal. If something goes wrong, that open session is the only thing standing between you and a trip to the console.

- If you are changing the listening port, open the new port in the firewall **before** restarting the daemon. See Step 1.

## Setup

### Overview

1. Write the hardening drop-in file.
2. Validate the configuration, then restart the daemon.
3. Install rotation for the authentication log.

---

#### Step 1: Write the hardening drop-in

Substitute `<ssh-port>` with the port the daemon should listen on — `22` unless you have a reason otherwise:

```bash
sudo tee /etc/ssh/sshd_config.d/10-default-sshd.conf >/dev/null <<'EOF'
# Port configuration
Port <ssh-port>

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
EOF
sudo chown root:root /etc/ssh/sshd_config.d/10-default-sshd.conf
sudo chmod 0644 /etc/ssh/sshd_config.d/10-default-sshd.conf
```

**Explanation**: One file, every deviation from the distribution default in it, so "what did we change on this machine" is answered by a single `cat`.

The `10-` prefix matters. Drop-ins load in lexical order, and in SSH configuration **the first occurrence of a keyword wins** — later ones are ignored, which is the opposite of most config systems. A low number therefore means these settings take precedence over anything added later, and the main config file is included at the very top so the whole directory is parsed before the distribution's own defaults.

Directive by directive:

| Directive | Value | Why |
|-----------|-------|-----|
| `Port` | `<ssh-port>` | Where the daemon listens. Moving it off 22 does not stop a targeted attacker but removes the constant background noise of untargeted scanners from your logs, which makes a real attempt visible. |
| `PermitRootLogin` | `no` | Root is the one account name that exists on every Linux machine, so it is the one an attacker can guess for free. Forcing a login as a named account and then `sudo` also means the auth log names the human behind each privileged action. |
| `PasswordAuthentication` | `no` | The single most valuable line here. It ends password guessing as an attack category outright — no rate limiting, no strength policy, no lockout heuristics needed. |
| `PermitEmptyPasswords` | `no` | Belt and braces. A system account created with a blank password by a careless package install cannot become a login. |
| `ChallengeResponseAuthentication` | `no` | Closes the keyboard-interactive path, which on a stock PAM stack is another way to end up at a password prompt after you thought you had disabled passwords. |
| `UsePAM` | `yes` | Session setup still goes through PAM, so account expiry, `nologin`, resource limits and session logging keep working. Disabling it would break those, not harden anything. |
| `AllowTcpForwarding` | `no` | An account with SSH access could otherwise forward arbitrary ports and use the machine as a pivot into the internal network. These accounts exist to administer this host, not to tunnel through it. |
| `PrintMotd` | `no` | Suppresses the banner. It is noise in every automated session's output, and the distribution's dynamic MOTD scripts run on each login for no benefit here. |
| `SyslogFacility` | `AUTH` | Routes daemon logging to the `auth` facility, which is what puts it in `/var/log/auth.log` where intrusion tooling expects to find it. |
| `LogLevel` | `VERBOSE` | Records the fingerprint of the key used for each successful login. Without it you know *that* an account logged in; with it you know *which key*, which is the difference between noticing a stolen key and not. This is also what makes the rotation policy in Step 3 necessary. |

`ChallengeResponseAuthentication` was renamed to `KbdInteractiveAuthentication` in OpenSSH 8.7. Recent releases still accept the old spelling as a deprecated alias and log a warning; if your version rejects it outright, replace that line with `KbdInteractiveAuthentication no`.

**If you changed the port**, open it in the firewall before you go any further, or the restart in Step 2 will strand you:

```bash
sudo ufw allow proto tcp from any to any port <ssh-port> comment 'SSH'
sudo ufw status | grep <ssh-port>
```

---

#### Step 2: Validate, then restart

```bash
sudo sshd -t -f /etc/ssh/sshd_config && echo "config ok"
```

Only if that prints `config ok`:

```bash
sudo systemctl restart ssh
systemctl is-active ssh
```

**Explanation**: `sshd -t` parses the configuration exactly as the daemon would — following the include, applying keyword precedence, checking file ownership and modes — and exits non-zero with a file and line number on any problem. It is chained with `&&` rather than run as a separate hopeful command because restarting an SSH daemon with a broken config leaves you with no daemon and, once your current session ends, no way in.

The restart does not drop existing sessions: they are served by forked child processes that survive the parent being replaced. Your open shell keeps working even if the new configuration is wrong — which is exactly why you keep it open until the verification passes.

A `reload` would be gentler, but a `Port` change needs the listening socket rebound, so restart is the honest choice.

---

#### Step 3: Rotate the authentication log

```bash
sudo tee /etc/logrotate.d/ssh >/dev/null <<'EOF'
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
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
sudo chown root:root /etc/logrotate.d/ssh
sudo chmod 0644 /etc/logrotate.d/ssh
```

**Explanation**: `LogLevel VERBOSE` plus an internet-facing daemon produces a lot of lines — every connection attempt, every offered key. On a machine whose root filesystem is shared with container data, an unbounded `auth.log` is a real way to run out of disk.

| Option | Why |
|--------|-----|
| `size 50M` | Rotate on size, not on a calendar. A quiet machine never rotates and keeps readable history; a machine under attack rotates as often as it needs to and cannot fill the disk between daily runs. |
| `rotate 3` | Three generations kept — enough to investigate a recent incident, bounded at roughly 150 MB before compression. |
| `compress` / `delaycompress` | Old generations are gzipped, but the most recent one is left alone for a cycle, because the daemon may still hold a descriptor on it and compressing underneath it truncates the file. |
| `missingok` | Do not fail the whole nightly run just because this file has not been created yet. |
| `notifempty` | Do not rotate an empty file and burn a generation of real history for nothing. |
| `create 0640 root adm` | The replacement file is created immediately with the right owner and mode. Without it the file is recreated by whatever writes first, and `auth.log` — which contains usernames and source addresses — could end up world-readable. Group `adm` is the distribution convention for accounts allowed to read logs. |
| `sharedscripts` / `postrotate` | Run the reload once, after all matching files have rotated. `rsyslog` keeps writing to the old inode until told otherwise, so without the reload the "new" log stays empty and the rotated file keeps growing. |

The reload is written as `> /dev/null 2>&1 \|\| true` so that a machine using `systemd-journald` alone, with no `rsyslog` installed, does not fail its nightly rotation on a service that was never there.

Debian and Ubuntu ship their own `/etc/logrotate.d/rsyslog`, which usually also lists `/var/log/auth.log`. Two policies for one file makes `logrotate` complain that the file appears twice and skip it. If Step 3's verification shows that error, remove `auth.log` from the distribution's file and leave this one in charge.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|-------------|-----------|------------------|
| `<ssh-port>` | TCP port the daemon listens on | `22` unless you want scanner noise off your logs. A high, unprivileged port is fine. Must match the firewall rule and every client that connects. Used in Step 1. |
| `<username>` | An account with a working key and sudo | The account you proved before starting. Used in the checks only. |
| `<ip-address>` | Address of the machine | Used in the checks only. |
| `<path-to-private-key>` | Private key file on your workstation | The half you never copied to the machine. Used in the checks only. |

## Verification

On the machine:

```bash
# The file is in place and correctly owned
ls -l /etc/ssh/sshd_config.d/10-default-sshd.conf
cat /etc/ssh/sshd_config.d/10-default-sshd.conf

# What the daemon is ACTUALLY applying, drop-ins merged
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|permitemptypasswords|allowtcpforwarding|usepam|loglevel|syslogfacility) '

# Listening on the expected port
sudo ss -tlnp | grep sshd

# Rotation policy parses, without actually rotating
sudo logrotate --debug /etc/logrotate.d/ssh
```

`sshd -T` is the authoritative answer — it prints the merged, effective configuration. Reading the drop-in file only tells you what you *wrote*. Expect `passwordauthentication no`, `permitrootlogin no`, `allowtcpforwarding no`, `loglevel VERBOSE`.

From a **second terminal**, with your existing session still open:

```bash
# Key login must work
ssh -p <ssh-port> -i <path-to-private-key> <username>@<ip-address> 'id'

# Password login must be refused before it can even prompt
ssh -p <ssh-port> -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    <username>@<ip-address>

# Root must be refused
ssh -p <ssh-port> root@<ip-address>
```

The second and third commands are expected to fail with `Permission denied (publickey)`. If either one gives you a password prompt, the drop-in is not being read — stop and check the include line before you log out.

Confirm the login was recorded with its key fingerprint:

```bash
sudo grep 'Accepted publickey' /var/log/auth.log | tail -3
```

## Updating & day-to-day

- Change a setting by editing `/etc/ssh/sshd_config.d/10-default-sshd.conf`, then always: `sudo sshd -t && sudo systemctl restart ssh`, with a second session open.
- Add a setting that is not about hardening in a separate, higher-numbered file so this one stays a readable statement of the security posture.
- Restrict logins to provisioned accounts by adding `AllowGroups ssh` to this file. Every account created on these machines is put into that group, so nothing else — including system accounts added later by package installs — can log in. Confirm the group membership of everyone who needs access first: `getent group ssh`.
- Watch authentication activity:

  ```bash
  sudo tail -f /var/log/auth.log
  sudo journalctl -u ssh -f
  sudo grep -c 'Failed' /var/log/auth.log
  ```

- After an OS upgrade, re-run `sudo sshd -T | grep passwordauthentication`. A `dpkg` prompt about `sshd_config` answered with "install the maintainer's version" removes the include line and takes every drop-in on the machine offline at once.
- If you rotate a key, install and prove the new one before removing the old — with passwords off, the key is the only way in.

## Rollback / Uninstall

Revert the daemon to distribution defaults:

```bash
sudo rm /etc/ssh/sshd_config.d/10-default-sshd.conf
sudo sshd -t && sudo systemctl restart ssh
```

Remove the rotation policy:

```bash
sudo rm /etc/logrotate.d/ssh
```

**Emergency: re-enable password login when you have console access but no key.** From the console:

```bash
sudo tee /etc/ssh/sshd_config.d/00-emergency.conf >/dev/null <<'EOF'
PasswordAuthentication yes
EOF
sudo sshd -t && sudo systemctl restart ssh
```

The `00-` prefix puts it ahead of the hardening file, and first occurrence wins, so it overrides without editing anything. Log in, fix the key, then delete `00-emergency.conf` and restart again. Do not leave it in place — check for it afterwards with `ls /etc/ssh/sshd_config.d/`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Locked out immediately after the restart | No account had a working key. Use the console and apply the emergency drop-in above. This is what proving a key login beforehand prevents. |
| Password prompt still appears | The drop-in is not being read. Check `grep '^Include' /etc/ssh/sshd_config`, and check `sudo sshd -T \| grep passwordauthentication` — that is the only answer that counts. |
| Connection refused after changing the port | The firewall still only allows the old port. From the console: `sudo ufw allow proto tcp from any to any port <ssh-port> comment 'SSH'`. Remember to remove the old rule afterwards. |
| `sshd -t` says `Bad configuration option: ChallengeResponseAuthentication` | Your OpenSSH is new enough to have dropped the alias. Replace that line with `KbdInteractiveAuthentication no`. |
| `sshd -t` says `bad ownership or modes` | A config file or a directory on its path is group- or world-writable. `sudo chown root:root` and `chmod 0644` the file, `0755` the directory. |
| `ssh -L` / `-R` port forwarding stopped working | Intentional — `AllowTcpForwarding no`. If a specific account genuinely needs it, add a `Match User <username>` block with `AllowTcpForwarding yes` rather than switching it back on globally. |
| Daemon will not start | `sudo journalctl -u ssh -n 50 --no-pager`. A common cause after a port change is another process already bound to the port: `sudo ss -tlnp \| grep <ssh-port>`. |
| `auth.log` growing very fast | Expected under scanning with `LogLevel VERBOSE`. Confirm the rotation policy is active with `sudo logrotate --debug /etc/logrotate.d/ssh`, and consider moving off port 22. |
| `logrotate` reports `/var/log/auth.log` appears twice | The distribution's `/etc/logrotate.d/rsyslog` also lists it. Remove the entry there and leave this policy in charge. |
| Rotation happens but the new log stays empty | `rsyslog` still holds the old file descriptor. The `postrotate` reload is what fixes that — check the block is present and that `rsyslog` is actually running. |
