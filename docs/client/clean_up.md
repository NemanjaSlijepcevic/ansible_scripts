# Final Cleanup and Reboot

## What this is

The last thing done to a machine being set up. It installs a rotation policy for the system log, removes the package debris left behind by a long install session, and reboots the machine — but only if the system says a reboot is actually needed.

Nothing here changes what the machine does. It exists so that a freshly built host is handed over with its logs bounded, its disk not carrying hundreds of megabytes of cached package archives, and any kernel or `libc` update from earlier in the build genuinely in effect rather than merely installed.

## Before you start

- Root or `sudo` on the machine:

  ```bash
  sudo -v && echo "sudo ok"
  ```

- `logrotate` installed:

  ```bash
  command -v logrotate || sudo apt-get install -y logrotate
  ```

- Everything else you intended to install is already installed. The package cleanup here removes anything no longer depended on, and the reboot ends every session on the machine — run this at the end, not in the middle.
- If the machine is going to reboot, know how to reach it if it does not come back: hypervisor console, IPMI, or physical access. Confirm you can open that console *before* Step 4, not after.
- Check now whether a reboot is going to happen, so you are not surprised:

  ```bash
  [ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs || echo "no reboot needed"
  ```

## Setup

### Overview

1. Install rotation for the system log.
2. Clean the package cache and remove orphaned packages.
3. Check whether a reboot is required.
4. Reboot, if it is, and wait for the machine to come back.

---

#### Step 1: Rotate the system log

```bash
sudo tee /etc/logrotate.d/syslog >/dev/null <<'EOF'
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
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
sudo chown root:root /etc/logrotate.d/syslog
sudo chmod 0644 /etc/logrotate.d/syslog
```

**Explanation**: `/var/log/syslog` catches messages from nearly every service on the machine, so it is the file most likely to grow without anyone watching. On a host whose root filesystem is shared with container data, an unbounded syslog is one of the more common ways to run a machine out of disk.

| Option | Why |
|--------|-----|
| `size 50M` | Rotate on size, not on a calendar. A quiet machine never rotates and keeps long, readable history; a machine that suddenly starts logging heavily rotates as often as it needs to and cannot fill the disk between nightly runs. A `daily` policy fails at both ends. |
| `rotate 3` | Three generations kept — roughly 150 MB before compression. Enough to investigate something that happened yesterday, bounded enough to ignore. |
| `compress` / `delaycompress` | Old generations are gzipped. The most recent one is left alone for one cycle, because a process may still hold an open descriptor on it and compressing the file underneath it truncates the log. |
| `missingok` | Do not fail the whole nightly run because this one file does not exist — for example on a machine that logs only to the journal. |
| `notifempty` | Do not rotate an empty file and burn a generation of real history for nothing. |
| `create 0640 root adm` | Recreate the file immediately with the right owner and mode. Without it the replacement is created by whatever writes first, and syslog contents — which include hostnames, paths and occasionally credentials in error messages — could end up world-readable. Group `adm` is the distribution convention for accounts allowed to read logs. |
| `sharedscripts` / `postrotate` | Reload the logging daemon once, after all matching files have rotated. `rsyslog` keeps writing to the old inode until told otherwise, so without the reload the new file stays empty while the rotated one keeps growing — the failure looks like rotation working and logging having stopped. |

The reload is written as `> /dev/null 2>&1 \|\| true` so a machine running only `systemd-journald`, with no `rsyslog` installed, does not fail its nightly rotation on a service that was never there.

Debian and Ubuntu ship `/etc/logrotate.d/rsyslog`, which also lists `/var/log/syslog`. If both files exist, `logrotate` complains that the file appears twice and skips it entirely — see Troubleshooting.

---

#### Step 2: Clean up packages

```bash
sudo apt-get -y autoclean
sudo apt-get -y autoremove
```

**Explanation**: A full build downloads a lot of packages and pulls in a lot of transitive dependencies, and both leave residue.

`autoclean` deletes `.deb` files from `/var/cache/apt/archives` that can no longer be downloaded from any configured repository — superseded versions, in other words. It is deliberately the conservative option: `clean` would empty the cache entirely, including the currently installed versions, which are worth keeping for an offline reinstall or downgrade.

`autoremove` removes packages that were installed automatically to satisfy a dependency and are no longer required by anything. On a machine that has been upgraded, that typically includes old kernel images, which are the single biggest recoverable item on a small `/boot`.

Read the list before confirming on a machine you did not build yourself. If a package was installed as a dependency and you have since started relying on it directly, `apt` does not know that and will remove it. Mark it first:

```bash
sudo apt-mark manual <package>
```

To see what would go without doing it:

```bash
sudo apt-get --dry-run autoremove
```

---

#### Step 3: Check whether a reboot is required

```bash
if [ -f /var/run/reboot-required ]; then
  echo "REBOOT REQUIRED"
  cat /var/run/reboot-required.pkgs
else
  echo "No reboot required"
fi
```

**Explanation**: `/var/run/reboot-required` is written by the package tooling when a package is installed that cannot take effect in a running system — a kernel, `libc`, `systemd`, `dbus`. The companion `.pkgs` file lists which packages asked for it, which is how you tell a kernel update apart from something less pressing.

Checking rather than rebooting unconditionally matters for the same reason it matters everywhere else: a reboot is the most disruptive thing you can do to a host, and on a machine that has not earned one it is pure downtime. Most runs of this procedure end here with nothing to do.

The marker lives in `/var/run`, which is a `tmpfs`. It is cleared by the reboot itself, which is what makes it self-resetting and safe to test.

---

#### Step 4: Reboot, and wait for it to come back

Only if Step 3 said a reboot is required:

```bash
sudo reboot
```

From your workstation, wait for it:

```bash
until ssh -o ConnectTimeout=5 -o BatchMode=yes -p <ssh-port> <username>@<ip-address> 'uptime'; do
  echo "waiting for the machine to come back..."
  sleep 10
done
```

**Explanation**: Everything installed earlier is on disk, but a kernel that is installed and a kernel that is running are different things. Until the reboot, the machine is running the old one and any vulnerability the update fixed is still live. Doing it here, at the end of a build, is also the cheapest moment it will ever be — there is no traffic on the machine yet and nothing depends on it.

The wait loop retries rather than sleeping a fixed interval, because boot time varies with filesystem checks, container restarts and how much the machine has to replay. `ConnectTimeout=5` keeps each failed attempt short instead of hanging on a machine that is not answering yet, and `BatchMode=yes` makes a failed attempt fail immediately rather than sitting at a password prompt inside a loop.

Ten minutes is a reasonable ceiling. Past that, stop waiting and open the console — a machine that has not come back in ten minutes is usually stuck at a boot loader prompt or a filesystem check, and neither resolves on its own.

Once it answers, confirm it really rebooted rather than never having gone down:

```bash
uptime -p
uname -r
```

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|-------------|-----------|------------------|
| `<ssh-port>` | Port the SSH daemon listens on | Whatever this machine was configured with. Read it with `sudo sshd -T \| grep '^port '` before you reboot. Used in Step 4. |
| `<username>` | An account on the machine with a working key | The account you have been using. Used in Step 4. |
| `<ip-address>` | Address of the machine | Used in Step 4. |
| `<package>` | A package `autoremove` wants to remove but you need | Only if the dry run shows something you rely on. Used in Step 2. |

## Verification

```bash
# The rotation policy is in place and parses
cat /etc/logrotate.d/syslog
sudo logrotate --debug /etc/logrotate.d/syslog

# Force one rotation to prove it end to end
sudo logrotate -vf /etc/logrotate.d/syslog
ls -l /var/log/syslog*

# Nothing left to clean
sudo apt-get --dry-run autoremove | tail -3
du -sh /var/cache/apt/archives

# Disk state
df -h /

# After a reboot: it really is a fresh boot, on the new kernel
uptime -p
uname -r
[ -f /var/run/reboot-required ] && echo "STILL flagged" || echo "clear"
```

`--debug` is a dry run and tells you what `logrotate` *would* do; `-vf` actually rotates. Use `--debug` for a routine check and `-vf` once, here, to confirm the `postrotate` reload works.

After a successful reboot the machine should report an uptime of minutes, and `/var/run/reboot-required` should be gone.

## Updating & day-to-day

- Check for a pending reboot on any machine at any time:

  ```bash
  [ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
  ```

  Automatic security updates install kernel packages but never reboot on their own, so this file reappears on its own schedule and someone has to act on it.

- Reclaim disk when a machine gets tight:

  ```bash
  sudo apt-get autoclean
  sudo apt-get autoremove
  sudo journalctl --vacuum-size=200M
  ncdu /var
  ```

- Confirm rotation is running across the machine:

  ```bash
  sudo logrotate --debug /etc/logrotate.conf
  cat /var/lib/logrotate/status
  ```

  That status file records when each path was last rotated and is the fastest way to spot a policy that has silently never fired.

- The nightly rotation is driven by a systemd timer:

  ```bash
  systemctl status logrotate.timer
  ```

## Rollback / Uninstall

Remove the rotation policy:

```bash
sudo rm /etc/logrotate.d/syslog
```

The system log then rotates only under whatever the distribution's own policy says, which on some images is nothing at all — check `/etc/logrotate.d/rsyslog` before leaving it that way.

The package cleanup cannot be undone selectively, but nothing it removed was needed. To reinstall something `autoremove` took:

```bash
sudo apt-get install -y <package>
sudo apt-mark manual <package>
```

The `apt-mark manual` is the part that stops it being removed again on the next cleanup.

A reboot cannot be rolled back. If the new kernel is the problem, pick the previous one from the boot loader's advanced options menu at the console, then pin or remove the bad one.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| The machine does not come back after the reboot | Open the console. Usual causes: the boot loader was not updated after a kernel install, a filesystem check is running and waiting for input, or `/etc/fstab` references a device that is not present. None of these resolve by waiting. |
| `logrotate` reports `/var/log/syslog` appears twice | The distribution's `/etc/logrotate.d/rsyslog` also lists it. Remove the entry from one of the two files; keeping both means neither runs. |
| Rotation happens but the new log stays empty | `rsyslog` still holds the old file descriptor. That is what the `postrotate` reload prevents — check the block is present and that `rsyslog` is running (`systemctl status rsyslog`). |
| The log never rotates | `size 50M` means it only rotates once the file exceeds 50 MB, which on a quiet machine may be never. That is intended. Confirm the policy is valid with `sudo logrotate --debug /etc/logrotate.d/syslog`. |
| `logrotate` skips the file with a permissions complaint | The file or its directory is writable by someone other than root. `sudo chown root:adm /var/log/syslog` and `sudo chmod 0640` it. |
| `autoremove` wants to remove something that looks important | It was installed as a dependency and nothing depends on it now. Old `linux-image-*` entries are safe. If you use something directly, `sudo apt-mark manual <package>` first, then re-run. |
| `/boot` is full and a kernel update fails | Old kernels accumulated. `sudo apt-get autoremove --purge` clears the ones nothing needs. Never remove the kernel you are currently running — check with `uname -r`. |
| `/var/run/reboot-required` is still there after rebooting | The machine did not actually reboot, or a package re-created the marker on boot. Check `uptime -p`; if it shows days, the reboot never happened. |
| Disk still full after cleaning | Package cache is rarely the real culprit. `sudo ncdu /var` finds it — usually the journal (`sudo journalctl --vacuum-size=200M`) or container data. |
