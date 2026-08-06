# Preparing the SSH Server

## What this is

Puts the SSH daemon into a known, extensible state before anything is hardened. It makes sure `sshd` is running and enabled at boot, creates a system group named `ssh` that account creation will use as a membership marker, creates the drop-in directory `/etc/ssh/sshd_config.d/`, and makes sure the main `/etc/ssh/sshd_config` actually pulls that directory in.

That last part is the whole point. Every later SSH change on this machine is a small file dropped into `/etc/ssh/sshd_config.d/` — never an edit to the distribution's `sshd_config`. Editing the shipped file means every OS upgrade offers you a three-way merge conflict; a drop-in survives untouched. But a drop-in is inert unless the main file includes the directory, so that inclusion is established first, on its own, while you still have a working login.

This runs on every machine, and it runs before any account exists and before password logins are switched off.

## Before you start

- Root or `sudo` on the machine, over SSH or on the console. Confirm:

  ```bash
  sudo -v && echo "sudo ok"
  ```

- `openssh-server` installed. Most server images have it; confirm and install it if not:

  ```bash
  command -v sshd || sudo apt-get install -y openssh-server
  ```

- Keep a second, already-authenticated shell open on this machine for the whole procedure. Every step here touches the daemon you are connected through. If you only have one session and you break the config, you need console or out-of-band access to recover.

## Setup

### Overview

1. Start the SSH daemon and enable it at boot.
2. Create the `ssh` system group.
3. Create the drop-in directory `/etc/ssh/sshd_config.d/`.
4. Make sure the main config includes that directory.
5. Validate the configuration, then restart the daemon.

---

#### Step 1: Enable and start the SSH daemon

```bash
sudo systemctl enable ssh
sudo systemctl start ssh
```

**Explanation**: On Debian and Ubuntu the unit is called `ssh` (with `sshd.service` as an alias). `enable` writes the boot-time symlink and `start` brings it up now; running both means the daemon is up regardless of whether the image shipped it stopped, disabled, or socket-activated. Doing this first guarantees you still have a way back into the machine before the remaining steps start modifying its configuration.

---

#### Step 2: Create the `ssh` group

```bash
sudo groupadd --system ssh
```

**Explanation**: This group is a membership marker, not a privilege. Every account created on this machine is put into it, so `AllowGroups ssh` can be added to the daemon config at any point and immediately mean "the accounts we provisioned, and nothing else" — including future system accounts created by package installs, which land outside the group and are therefore excluded by default.

It is created as a system group (`--system`, low GID) because no human owns it and it must never collide with a per-user group.

Create it *now*, before any account exists. Adding a user to a group that does not exist fails; creating the group afterwards means going back and fixing every account by hand.

If the group already exists `groupadd` exits non-zero with `group 'ssh' already exists`. That is the desired end state, so ignore it.

---

#### Step 3: Create the drop-in directory

```bash
sudo mkdir -p /etc/ssh/sshd_config.d
sudo chown root:root /etc/ssh/sshd_config.d
sudo chmod 0755 /etc/ssh/sshd_config.d
```

**Explanation**: `sshd` refuses to load a configuration file that is group- or world-writable, and it checks the whole path. `0755 root:root` is the loosest ownership it will accept: readable by anyone (so `sshd -T` works for diagnosis without escalation), writable only by root.

---

#### Step 4: Include the drop-in directory from the main config

Check whether the include is already there:

```bash
grep -n '^Include /etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config
```

If that prints nothing, insert it as the very first line:

```bash
sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
```

**Explanation**: Without this line, files in `/etc/ssh/sshd_config.d/` are read by nobody and silently do nothing — the most dangerous failure mode on this machine, because you would believe password logins were disabled when they were not.

It goes at the *top* of the file, and the reason is a quirk of how `sshd` parses its config: **the first occurrence of a keyword wins**, later ones are ignored. So an include at the top lets the drop-ins override the distribution defaults further down. An include at the bottom would be shadowed by every setting the shipped file already sets, and your hardening would quietly have no effect.

Recent Debian and Ubuntu images ship this line already. In that case the `grep` finds it and you skip the `sed` — running it anyway would give you two includes and the same file parsed twice.

---

#### Step 5: Validate, then restart

```bash
sudo sshd -t -f /etc/ssh/sshd_config && echo "config ok"
```

Only if that prints `config ok`:

```bash
sudo systemctl restart ssh
```

**Explanation**: `sshd -t` parses the config exactly as the daemon would — following the include, checking file permissions, resolving keywords — and exits non-zero with a file and line number on any problem. Restarting an SSH daemon with a broken config leaves you with a dead daemon and no remote way in, so the validation is chained with `&&` rather than run as a separate hopeful command.

Restarting `ssh` does not drop existing connections: established sessions are handled by forked child processes that survive the parent being replaced. The restart only affects logins made after it.

---

## Values to fill in

Nothing to fill in — every path, group name and permission here is fixed.

## Verification

```bash
# Daemon running and enabled at boot
systemctl is-active ssh
systemctl is-enabled ssh

# The group exists
getent group ssh

# Drop-in directory exists with acceptable ownership
ls -ld /etc/ssh/sshd_config.d

# The include is present, and exactly once, at the top
grep -c '^Include /etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config
head -3 /etc/ssh/sshd_config

# The daemon agrees the configuration parses
sudo sshd -t && echo "config ok"

# What the daemon will actually apply, drop-ins merged in
sudo sshd -T | head -20
```

`sshd -T` is the authoritative answer to "what is in effect" — it prints the fully merged configuration, so it is the only way to confirm a drop-in is really being read.

## Updating & day-to-day

- Never edit `/etc/ssh/sshd_config` again. Add a numbered file to `/etc/ssh/sshd_config.d/` instead; the numeric prefix decides load order, and lower numbers win on conflicting keywords.
- After any change: `sudo sshd -t && sudo systemctl restart ssh`, in that order, with a second session open.
- Login events land in `/var/log/auth.log`. Follow them live with `sudo tail -f /var/log/auth.log` or `sudo journalctl -u ssh -f`.
- After an OS upgrade, check that the include survived: a `dpkg` prompt about a modified `sshd_config` answered with "install the package maintainer's version" removes it, and every drop-in on the machine goes dark at once.

## Rollback / Uninstall

Remove the include, returning to a single monolithic config:

```bash
sudo sed -i '/^Include \/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh
```

**Before you do that**, list what you are switching off:

```bash
ls -l /etc/ssh/sshd_config.d/
```

Every setting in those files stops applying the moment the include goes. If one of them disables password authentication or root login, removing the include re-enables whatever the main file says — which on a stock image is usually far more permissive. Copy anything you need into `/etc/ssh/sshd_config` first.

To remove the directory as well:

```bash
sudo rm -rf /etc/ssh/sshd_config.d
```

The `ssh` group can be removed with `sudo groupdel ssh`, but only once nothing references it — check with `sudo grep -r AllowGroups /etc/ssh/`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `groupadd: group 'ssh' already exists` | Already in the desired state. Ignore it. |
| A drop-in file has no effect | Either the include is missing (`grep '^Include' /etc/ssh/sshd_config`) or the same keyword is set earlier in the main file — first occurrence wins. `sudo sshd -T \| grep <keyword>` shows what is actually in effect. |
| `sshd -t` says `Bad configuration option` | An unsupported or misspelled keyword. The message names the file and line. Directives also get retired between releases, so a file copied from an older machine can fail here. |
| `sshd -t` says `bad ownership or modes` | A config file or a directory on its path is group- or world-writable. Fix with `sudo chown root:root` and `sudo chmod 0755` on the directory, `0644` on files. |
| Daemon will not start after a restart | `sudo journalctl -u ssh -n 50 --no-pager` gives the real reason. Until it starts, you need console or out-of-band access — existing sessions keep working but no new one can be opened. |
| `systemctl restart ssh` fails with `Unit ssh.service not found` | `openssh-server` is not installed, only the client. `sudo apt-get install -y openssh-server`. |
| Include line present twice | An earlier attempt inserted it into a file that already had it. Delete one of them; a doubled include parses the whole directory twice and doubles any keyword-collision confusion. |
