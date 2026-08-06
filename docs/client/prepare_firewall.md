# Setting Up the Firewall

## What this is

Configures the host firewall with UFW: everything inbound is denied, everything outbound is allowed, and a short explicit list of ports is opened. Logging is switched on and the resulting log file is given a rotation policy.

The rule set is wiped and rebuilt from scratch rather than adjusted in place, so the firewall on a machine is always exactly the list you have in front of you — no leftovers from an experiment six months ago. That makes one thing critical: **the list must contain a rule for SSH**, or the moment the firewall comes up you lose the machine.

Every machine gets this. The baseline is SSH plus whatever that machine actually serves.

## Before you start

- Root or `sudo` on the machine.
- `ufw` installed:

  ```bash
  command -v ufw || sudo apt-get install -y ufw
  ```

- **Know your SSH port.** Everything below hangs on getting this right:

  ```bash
  sudo sshd -T | grep '^port '
  ```

- Console or out-of-band access to the machine (hypervisor console, IPMI, physical keyboard), or at minimum the certainty that you can get it. This is the one procedure in the bootstrap that can cut your own connection mid-command.
- `logrotate` installed:

  ```bash
  command -v logrotate || sudo apt-get install -y logrotate
  ```

- Decide the full port list before you start, not while the firewall is down. Write it out — Step 1 is checking it.

## Setup

### Overview

1. Write out the rule list and confirm it contains SSH.
2. Reset the firewall to a clean state.
3. Set the default policies: deny inbound, allow outbound.
4. Add each allow rule.
5. Enable the firewall with logging.
6. Install rotation for the firewall log.

---

#### Step 1: Write out the rules and check for SSH

```bash
cat <<'EOF'
port   proto  comment
<ssh-port>  tcp    SSH
80          tcp    HTTP
443         tcp    HTTPS
EOF
```

Confirm the port you are about to allow is the port the daemon is really on:

```bash
sudo sshd -T | grep '^port '
sudo ss -tlnp | grep sshd
```

**Explanation**: This is not busywork — it is the check that makes the rest of the procedure survivable. The next step deletes every rule on the machine, and the step after that sets the default inbound policy to deny. If SSH is not in the list you are about to apply, the firewall comes up correct, complete, and completely closed to you.

The mistake is almost never "forgot SSH entirely". It is allowing 22 on a machine whose daemon was moved to another port, or the reverse. Read the port out of the running daemon rather than from memory.

The three rules above are the common baseline: SSH so you can administer the machine, and 80/443 for a machine that terminates HTTP. A machine that serves file shares, a database, or anything else adds its own entries to the same list — one line per port, each with a comment saying what it is for, so the next person reading `ufw status` does not have to guess.

---

#### Step 2: Reset to a clean state

```bash
sudo ufw --force reset
```

**Explanation**: Wipes every rule and disables the firewall, giving a known starting point. Rebuilding from empty is what makes the final state predictable: `ufw status` afterwards shows exactly the list from Step 1 and nothing else. Editing an existing rule set in place accumulates rules nobody remembers adding, and a stale `allow` is a hole that no audit of your intended list would ever reveal.

`--force` skips the interactive confirmation. Note the window this opens: from here until Step 5 the firewall is **off** and the machine is unfiltered. Do not stop halfway. Run Steps 2 through 5 back to back.

The old rules are saved as `.rules.<timestamp>` backups in `/etc/ufw/`, which is worth knowing if you need to see what was there before.

---

#### Step 3: Set the default policies

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

**Explanation**: Default-deny inbound is the entire point of the firewall. Anything not explicitly allowed in Step 4 is dropped, so a service that starts listening on an unexpected port — a container publishing to `0.0.0.0`, a package that enables a daemon on install — is not reachable from outside until someone deliberately opens it.

Outbound stays open. These machines pull container images, fetch package updates, push metrics and logs to a collector, and reach external APIs; enumerating all of that would be a large, brittle list that breaks on the first new service. The inbound direction is where the exposure is.

Established and related traffic is allowed back in regardless — UFW's default rule set is stateful, which is why "deny all inbound" does not break your outbound connections.

---

#### Step 4: Add the allow rules

```bash
sudo ufw allow proto tcp from any to any port <ssh-port> comment 'SSH'
sudo ufw allow proto tcp from any to any port 80 comment 'HTTP'
sudo ufw allow proto tcp from any to any port 443 comment 'HTTPS'
```

The pattern for any additional rule:

```bash
sudo ufw allow proto <tcp|udp> from any to any port <port> comment '<what it is for>'
```

**Explanation**: Each rule is written in the long form on purpose. `ufw allow 80` guesses at the protocol and records nothing about why; the explicit form pins the protocol and attaches a comment that shows up in `ufw status` forever. When you come back to a machine with fifteen rules on it, the comment is the difference between confidently removing one and leaving it there because you are not sure.

`from any to any` keeps the rule address-agnostic. Narrow the source when a port genuinely only serves one network — for example a database or file-share port that should never be reachable from outside the LAN:

```bash
sudo ufw allow proto tcp from <docker-subnet> to any port <port> comment '<service> (internal only)'
```

A machine serving SMB file shares, for instance, adds UDP 137 and 138 and TCP 139 and 445, and those belong scoped to the local network rather than open to the world.

Rules are applied while the firewall is still disabled. That is deliberate: the entire set is in place before anything starts enforcing, so there is no moment where a partial rule set is live.

---

#### Step 5: Enable, with logging

```bash
sudo ufw --force enable
sudo ufw logging on
sudo ufw status verbose
```

**Explanation**: This is the moment enforcement starts. Because the rules were loaded first, an SSH session on an allowed port stays up across the transition.

`--force` suppresses the *"Command may disrupt existing ssh connections. Proceed with operation (y|n)?"* prompt. If you would rather see the prompt and answer it yourself, drop the flag — but do not run it non-interactively without having done the Step 1 check.

Logging on means blocked packets are recorded in `/var/log/ufw.log`. The default level logs blocked traffic and rate-limits repeats; it is what turns "the service is not reachable" into a two-second answer, because you can see the packet arriving and being dropped instead of guessing between a firewall problem, a routing problem and a dead daemon.

**Verify from a second terminal right now**, before doing anything else:

```bash
ssh -p <ssh-port> <username>@<ip-address> 'echo still-here'
```

---

#### Step 6: Rotate the firewall log

```bash
sudo tee /etc/logrotate.d/uwf >/dev/null <<'EOF'
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
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
sudo chown root:root /etc/logrotate.d/uwf
sudo chmod 0644 /etc/logrotate.d/uwf
```

**Explanation**: A machine reachable from the internet gets scanned continuously, and every dropped packet is a line. Unbounded, `/var/log/ufw.log` is one of the more reliable ways to fill a root filesystem on an otherwise idle host.

| Option | Why |
|--------|-----|
| `size 50M` | Rotate on size, not on a calendar. A quiet machine keeps long history; a machine under a scan flood rotates as often as it needs to and cannot fill the disk between nightly runs. |
| `rotate 3` | Three generations, bounded at roughly 150 MB before compression — enough to look back at a recent incident. |
| `compress` / `delaycompress` | Old generations are gzipped; the newest is left uncompressed for a cycle because the logging daemon may still hold a descriptor on it. |
| `missingok` | With logging freshly enabled the file may not exist yet; do not fail the nightly run over it. |
| `notifempty` | Do not burn a generation rotating an empty file. |
| `create 0640 root adm` | Recreate immediately with the right mode. The log contains source addresses and port scan patterns and should not be world-readable. `adm` is the distribution's group for log readers. |
| `sharedscripts` / `postrotate` | Reload the logging daemon once, after rotation, so it releases the old inode and starts writing to the new file. Without it the new log stays empty while the rotated one keeps growing. |

The reload is written as `> /dev/null 2>&1 \|\| true` so a machine running only `systemd-journald`, with no `rsyslog` installed, does not fail its nightly rotation on a service that was never there.

The filename is `uwf`, not `ufw`. That is a transposition that has been carried in this setup for a while; `logrotate` does not care what the file is called, only what is inside it. If you go looking for `/etc/logrotate.d/ufw` and find nothing, this is why.

Note that Debian and Ubuntu also ship `/etc/logrotate.d/ufw` with the package. If both exist and both list `/var/log/ufw.log`, `logrotate` complains that the file appears twice and skips it — see Troubleshooting.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|-------------|-----------|------------------|
| `<ssh-port>` | Port the SSH daemon listens on | Read it from the running daemon with `sudo sshd -T \| grep '^port '`. Never from memory. Used in Steps 1 and 4. |
| `<port>` | Any additional port to open | One rule per port the machine actually serves. If nothing listens on it, do not open it. Used in Step 4. |
| `<tcp\|udp>` | Protocol for the rule | Match what the service uses. `sudo ss -tulnp` shows what is listening and on which protocol. |
| `<what it is for>` | Rule comment | A short service name. It is displayed in `ufw status` and is what makes future cleanup possible. |
| `<docker-subnet>` | A source network, when a rule should not be world-open | CIDR of the network allowed to reach the port, e.g. the container bridge or the LAN. Used in the scoped form in Step 4. |
| `<username>` / `<ip-address>` | Login and address for the post-enable check | Used in Step 5 only. |

## Verification

```bash
# Full rule set with defaults and logging state
sudo ufw status verbose

# Numbered form, for deleting a specific rule later
sudo ufw status numbered

# Confirm the defaults specifically
sudo ufw status verbose | grep Default    # deny (incoming), allow (outgoing)

# Confirm it survives a reboot
systemctl is-enabled ufw

# Rotation policy parses
sudo logrotate --debug /etc/logrotate.d/uwf

# Something is actually being logged
sudo tail -20 /var/log/ufw.log
```

From another machine, prove the policy in both directions:

```bash
# Allowed port answers
nc -z -w3 <ip-address> <ssh-port> && echo "open"

# A port you did not allow does not
nc -z -w3 <ip-address> 12345 || echo "closed as expected"
```

Cross-check that every listening socket is either firewalled or deliberately allowed:

```bash
sudo ss -tulnp
```

Anything bound to `0.0.0.0` or `::` that is not in your rule list is only protected by the firewall — which is fine, as long as you know it.

## Updating & day-to-day

- Add a port:

  ```bash
  sudo ufw allow proto tcp from any to any port <port> comment '<what it is for>'
  ```

- Remove one:

  ```bash
  sudo ufw status numbered
  sudo ufw delete <number>
  ```

  Delete from the highest number downwards — removing a rule renumbers everything below it.

- Keep the written rule list in sync with the machine. The next rebuild starts from a reset, and a rule that only ever existed as a one-off `ufw allow` will not survive it.
- Watch what is being dropped:

  ```bash
  sudo tail -f /var/log/ufw.log
  sudo grep -c 'BLOCK' /var/log/ufw.log
  ```

- Docker publishes container ports by writing directly into `iptables`, below the layer UFW manages. A container started with `-p 8080:80` is reachable from the network **even though `ufw status` does not list it**. Do not assume `ufw status` is the complete picture of what is exposed — `sudo ss -tulnp` is. Bind container ports to `127.0.0.1` when they are only meant to be local.

## Rollback / Uninstall

Turn the firewall off, leaving the rules stored:

```bash
sudo ufw disable
```

Wipe every rule and start over:

```bash
sudo ufw --force reset
```

Remove it entirely:

```bash
sudo ufw disable
sudo apt-get purge -y ufw
sudo rm -f /etc/logrotate.d/uwf
```

**Emergency, from the console, when you have locked yourself out**:

```bash
sudo ufw disable
sudo ufw allow proto tcp from any to any port <ssh-port> comment 'SSH'
sudo ufw --force enable
```

Disabling first gets you back in; then fix the rule and re-enable. Do not leave the firewall disabled on a machine reachable from outside.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| SSH dropped the instant the firewall was enabled | The allowed port is not the port the daemon listens on. From the console: `sudo ufw disable`, check `sudo sshd -T \| grep '^port '`, add the correct rule, re-enable. |
| A service is unreachable but the daemon is running | Check the rule exists and matches the protocol: `sudo ufw status verbose`. Then check the drop is really happening: `sudo tail -f /var/log/ufw.log` while you retry the connection. |
| A container port is reachable although UFW does not list it | Docker writes its own `iptables` rules below UFW. Publish to `127.0.0.1:<port>:<port>` instead of `<port>:<port>`, or put the container behind a reverse proxy. |
| `/var/log/ufw.log` is empty | Logging is off (`sudo ufw status verbose \| grep Logging`), or `rsyslog` is not running (`systemctl status rsyslog`). On a journald-only machine the traffic is in `sudo journalctl -k \| grep UFW` instead. |
| `logrotate` reports `/var/log/ufw.log` appears twice | Both this policy and the distribution's `/etc/logrotate.d/ufw` list the file. Keep one; remove the entry from the other. |
| Rules come back after a reboot that you had deleted | You deleted them from a running firewall but the change was not persisted, or the machine was rebuilt from the written list. Re-check `sudo ufw status numbered`. |
| The firewall is not active after a reboot | `sudo systemctl enable ufw`. `ufw enable` normally handles this, but a manually disabled unit stays disabled. |
| Rules seem to be evaluated in the wrong order | UFW matches in listed order and the first match wins. `sudo ufw status numbered` shows the real order; use `sudo ufw insert <number> allow …` to place a rule ahead of another. |
| `ufw reset` hangs waiting for input | It is asking for confirmation. Use `sudo ufw --force reset`. |
