# Host Baseline (firewall, Docker daemon, shared network)

## What this is

The state every machine in this stack must be in before a single service container is started: a
firewall that denies everything inbound except the ports you named, a Docker daemon configured with
capped log files and a fixed DNS order, a systemd unit that repairs containers after a daemon
restart, a `./data` working directory, and the shared `proxy` bridge network that every service
attaches to.

This applies to all hosts — the NAS, the monitoring box, the public server, the database host, the
automation host. Nothing here talks to another machine; it is purely local groundwork. Once it is
done, every other service guide can assume Docker is up, `proxy` exists, and `./data` is writable.

Operating-system package upgrades and unattended-upgrades are **not** part of this. They belong to
the one-time machine bootstrap, not to a service deploy.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version

id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

**`ufw` and `jq` are installed**

```bash
sudo apt-get update
sudo apt-get install -y ufw jq
```

`jq` is used below to validate the Docker daemon configuration before restarting the daemon; an
invalid file there leaves you with a dead Docker and every container down.

**You know the working directory**

Pick (or confirm) the directory that will hold `./data` — referred to below as `<deploy-dir>`,
typically the deploy account's home directory. Run every command in this guide from there:

```bash
cd <deploy-dir>
pwd
```

**You have console access, not only SSH**

Step 1 enables a default-deny firewall. If you get the SSH rule wrong you are locked out. Have the
machine's console (Proxmox shell, IPMI, physical keyboard) reachable before you begin.

## Setup

### Overview

1. Add the firewall rules and enable default-deny.
2. Rotate the firewall log.
3. Create the `./data` working directory.
4. Install `fuse-overlayfs` — containerised hosts only.
5. Write `/etc/docker/daemon.json`.
6. Install and enable the `docker-sock-rebind` unit.
7. Validate the daemon configuration, restart Docker, wait for the socket.
8. Create the shared `proxy` bridge network.

---

#### Step 1: Add the firewall rules and enable default-deny

```bash
# look at what is already there before changing anything
sudo ufw status verbose

# defaults
sudo ufw default deny incoming
sudo ufw default allow outgoing

# the rules this stack needs; SSH first, always
sudo ufw allow proto tcp from any to any port 22 comment 'SSH'
sudo ufw allow proto tcp from any to any port 80 comment 'HTTP'
sudo ufw allow proto tcp from any to any port 443 comment 'HTTPS'

# a rule scoped to one source, for anything that must not be world-reachable
sudo ufw allow proto tcp from <ip-address> to any port 5432 comment 'PostgreSQL from LAN'

sudo ufw logging on
sudo ufw enable
sudo ufw status verbose
```

**Explanation**: Check the existing state first and add only what is missing — never
`ufw reset`. A reset drops every rule for the instant it takes to re-add them, and on a remote
machine that instant is enough to kill your own SSH session and leave you outside a default-deny
firewall. The SSH rule goes in before `ufw enable` for the same reason: enabling default-deny
without it locks you out immediately. Outbound stays `allow` because containers need to reach
package mirrors, ACME servers and upstream APIs, and pinning outbound rules per container is
unmanageable on a bridge network. Rules carry comments so `ufw status verbose` tells you *why* a
port is open a year from now, and a rule with a `from` address is the right shape for anything that
should only answer to the LAN. Logging is enabled because the intrusion-detection agent reads
`/var/log/ufw.log` as one of its inputs — with logging off it sees no dropped-packet events at all.

---

#### Step 2: Rotate the firewall log

```bash
sudo tee /etc/logrotate.d/ufw >/dev/null <<'EOF'
/var/log/ufw.log {
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 <username> <pgid>
}
EOF
sudo chown root:root /etc/logrotate.d/ufw
sudo chmod 0644 /etc/logrotate.d/ufw

# dry-run the rotation
sudo logrotate -d /etc/logrotate.d/ufw
```

**Explanation**: A default-deny firewall on a machine with a public address logs constantly, and an
unbounded `/var/log/ufw.log` will fill the root filesystem — which takes Docker down with it.
Rotation is by size rather than by day so a burst of scanning traffic cannot outrun a daily
schedule. `create` (rather than `copytruncate`) is correct here because rsyslog reopens the file on
rotation; the mode keeps the log readable by the deploy account and the log-shipping agent without
making it world-readable.

---

#### Step 3: Create the `./data` working directory

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

**Explanation**: Everything stateful on this host lives under `./data/<service>` and is bind-mounted
into the container that owns it. Keeping it in one directory relative to a known working directory
is what makes a backup, a migration or a `du -sh ./data/*` possible without hunting through
`/var/lib/docker`. Ownership is the deploy account with the Docker group, so both you and the
containers that run as that group can write; `0755` keeps it traversable by container users that run
as a different UID and only need to read.

---

#### Step 4: Install `fuse-overlayfs` — containerised hosts only

Skip this on a bare-metal or full-VM host.

```bash
sudo apt-get install -y fuse-overlayfs
```

**Explanation**: On an unprivileged LXC guest the kernel refuses the normal `overlay2` storage
driver, and Docker silently falls back to `vfs`, which copies the entire image on every layer — disk
usage explodes and container start takes minutes. `fuse-overlayfs` gives you overlay semantics in
userspace instead. Install the package here, before the daemon configuration in the next step names
it as the storage driver; naming a driver whose binary is absent leaves Docker unable to start.

---

#### Step 5: Write `/etc/docker/daemon.json`

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
    "metrics-addr": "<docker-bridge-ip>:9323",
    "experimental": true,
    "dns": ["<local-dns-ip>", "1.1.1.1", "8.8.8.8"],
    "dns-opts": ["timeout:2", "attempts:2"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    },
    "live-restore": true
}
EOF
sudo chown root:root /etc/docker/daemon.json
sudo chmod 0644 /etc/docker/daemon.json
```

On a containerised host, add the storage driver as the **first** key:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
    "storage-driver": "fuse-overlayfs",
    "metrics-addr": "<docker-bridge-ip>:9323",
    "experimental": true,
    "dns": ["<local-dns-ip>", "1.1.1.1", "8.8.8.8"],
    "dns-opts": ["timeout:2", "attempts:2"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    },
    "live-restore": true
}
EOF
sudo chown root:root /etc/docker/daemon.json
sudo chmod 0644 /etc/docker/daemon.json
```

**Explanation**: `metrics-addr` publishes the daemon's own Prometheus metrics on port 9323 bound to
the Docker bridge address, so the local monitoring agent can scrape engine-level numbers without the
port being reachable from the LAN; `experimental` is what enables that endpoint at all. The DNS list
puts your local resolver first so containers resolve internal names, with two public resolvers
behind it so a resolver reboot does not take every container's outbound name lookup with it — and
the short `timeout:2 attempts:2` is what makes that failover happen in seconds rather than the 5s ×
2 default. The log options are the difference between a bounded disk and an outage: without
`max-size`/`max-file` a single chatty container's JSON log grows until the root filesystem is full.
`live-restore` keeps running containers alive while the daemon itself is restarted or upgraded,
which is why the next step exists.

---

#### Step 6: Install and enable the `docker-sock-rebind` unit

```bash
sudo tee /etc/systemd/system/docker-sock-rebind.service >/dev/null <<'EOF'
[Unit]
Description=Restart containers with stale /var/run/docker.sock binds after dockerd restart
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 15
ExecStart=/bin/sh -c 'for c in traefik alloy socket-proxy; do docker ps -q --filter "name=^$c$" | grep -q . && { docker stop "$c"; docker start "$c"; } || true; done'

[Install]
WantedBy=docker.service
EOF
sudo chown root:root /etc/systemd/system/docker-sock-rebind.service
sudo chmod 0644 /etc/systemd/system/docker-sock-rebind.service

sudo systemctl daemon-reload
sudo systemctl enable docker-sock-rebind.service
```

**Explanation**: `live-restore` from the previous step keeps containers up across a daemon restart,
but any container that bind-mounts `/var/run/docker.sock` as a *file* is left holding a dead inode
once the daemon recreates the socket. The reverse proxy, the monitoring agent and the filtered
Docker API proxy all do this, and all three break silently: they keep running, report healthy, and
never see another Docker event. This unit is `PartOf=docker.service`, so systemd starts it every
time the daemon starts, and it stops and starts exactly those containers. Install and enable it
**before** the restart in the next step — otherwise the very restart that breaks the sockets happens
while the unit does not yet exist to catch it, and the monitoring agent sits on a dead socket until
the next daemon restart, whenever that happens to be. The `sleep 15` gives the daemon time to finish
reconciling live-restored containers before anything is touched. It uses `stop` followed by `start`
rather than `docker restart` deliberately: on a host using `fuse-overlayfs`, a restart races the
stale graph-driver state, the freshly created `merged` rootfs mount disappears from the host
namespace again, and the container is then permanently unhealthy with `setns /proc/self/fd` errors
on every health-check exec.

---

#### Step 7: Validate, restart Docker, wait for the socket

```bash
# never restart on an unvalidated file
sudo jq . /etc/docker/daemon.json

sudo systemctl restart docker
sudo systemctl enable docker

# wait for the socket before doing anything else
timeout 30 sh -c 'until [ -S /var/run/docker.sock ]; do sleep 1; done' \
  && echo "docker socket ready" || echo "TIMED OUT waiting for /var/run/docker.sock"

docker info | grep -E 'Storage Driver|Logging Driver|Live Restore'
```

**Explanation**: `jq` parsing the file is the whole safety net — Docker refuses to start on a
malformed daemon configuration, and if you find that out by restarting, every container on the host
is already down and the daemon will not come back until you fix the JSON blind. Waiting for the
socket to reappear matters because the next step talks to the daemon: issuing `docker network
create` a second after `systemctl restart` returns gets you "cannot connect to the Docker daemon"
even though the restart succeeded.

---

#### Step 8: Create the shared `proxy` bridge network

```bash
docker network inspect proxy >/dev/null 2>&1 || docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy

docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

**Explanation**: Every service container on this host attaches to `proxy` and gets a fixed address
on it, which is what lets the reverse proxy and the services address each other by container name
over a network that is not the default bridge and not reachable from the LAN. The subnet is declared
explicitly rather than left to Docker so the same addresses mean the same things after a daemon
reinstall — the fixed addresses that other configuration files hard-code would otherwise land in a
different subnet. `--ip-range` is the narrower pool Docker allocates from automatically; keep every
fixed container address **outside** that range or Docker will eventually hand one of them to an
unrelated container and the two will collide. Creating the network is guarded by an `inspect`
because a second `create` fails with "network with name proxy already exists", which is noise rather
than a problem.

## Values to fill in

| Placeholder | What it is | How to choose it |
| --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory; every relative path in the service guides is relative to it |
| `<username>` | Account that owns `./data` | The unprivileged account you deploy as; must be in the `docker` group |
| `<pgid>` | Group that owns `./data` | The `docker` group, so containers running as that group can write |
| `<docker-subnet>` | CIDR of the `proxy` network | A private range not used anywhere else on your LAN, e.g. a `/24` out of `172.16.0.0/12` |
| `<docker-gateway>` | Gateway address inside that subnet | Conventionally the first usable address of `<docker-subnet>` |
| `<docker-ip-range>` | Auto-allocation pool inside the subnet | A strict sub-range of `<docker-subnet>`; keep every fixed container address outside it |
| `<docker-bridge-ip>` | Address the daemon binds its metrics port to | The host's address on the default `docker0` bridge |
| `<local-dns-ip>` | Primary resolver for containers | Your LAN's DNS server, so containers resolve internal names |
| `<ip-address>` | A LAN source address or CIDR | Used in scoped firewall rules for ports that must not be world-reachable |

Also decide whether this host needs `"storage-driver": "fuse-overlayfs"` — set it on unprivileged
containerised guests, leave it out everywhere else.

## Verification

```bash
# firewall active, default-deny inbound, rules present with their comments
sudo ufw status verbose

# daemon up and reading your configuration
sudo systemctl is-active docker
docker info | grep -E 'Storage Driver|Logging Driver|Live Restore|Experimental'

# the rebind unit is enabled and tied to the daemon
systemctl is-enabled docker-sock-rebind.service
systemctl show docker-sock-rebind.service -p PartOf

# the shared network exists with the addressing you intended
docker network inspect proxy | jq -r '.[0].IPAM.Config'

# the working directory is writable by the deploy account
ls -ld ./data

# daemon metrics answer on the bridge address
curl -s http://<docker-bridge-ip>:9323/metrics | head -3

# log rotation parses
sudo logrotate -d /etc/logrotate.d/ufw
```

The end-to-end proof that the rebind unit works: restart the daemon and confirm the containers came
back rather than merely staying up.

```bash
sudo systemctl restart docker
sleep 30
systemctl status docker-sock-rebind.service --no-pager
docker ps --filter 'name=^traefik$'
```

## Updating & day-to-day

**Opening a new port.** Add the rule and re-check; never reset.

```bash
sudo ufw allow proto tcp from <ip-address> to any port <port> comment '<service>'
sudo ufw status verbose
```

**Closing one.** Delete by rule, then confirm nothing else depended on it.

```bash
sudo ufw status numbered
sudo ufw delete <number>
```

**Changing the daemon configuration.** Edit, validate, restart — in that order. Expect every
container that bind-mounts the Docker socket to be stopped and started ~15 seconds later by the
rebind unit.

```bash
sudoedit /etc/docker/daemon.json
sudo jq . /etc/docker/daemon.json && sudo systemctl restart docker
```

**Watching disk.** Container logs are capped at 50 MB × 5 per container, but images and volumes are
not.

```bash
docker system df
du -sh ./data/* | sort -h | tail
docker image prune -f
```

**Where the logs are.** Daemon: `journalctl -u docker`. Rebind unit:
`journalctl -u docker-sock-rebind`. Firewall drops: `/var/log/ufw.log`. Per-container:
`docker logs <container>`.

## Rollback / Uninstall

Remove the shared network — every attached container must be stopped first:

```bash
docker network inspect proxy | jq -r '.[0].Containers | to_entries[].value.Name'
docker stop $(docker ps -q)
docker network rm proxy
```

Remove the rebind unit:

```bash
sudo systemctl disable --now docker-sock-rebind.service
sudo rm /etc/systemd/system/docker-sock-rebind.service
sudo systemctl daemon-reload
```

Return the daemon to stock configuration:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{}
EOF
sudo jq . /etc/docker/daemon.json && sudo systemctl restart docker
```

Disable the firewall (this leaves the host open — only do it on a machine that is behind another
firewall):

```bash
sudo ufw disable
sudo rm -f /etc/logrotate.d/ufw
```

`./data` is deliberately not removed here — it holds every service's state.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `docker network create` fails with "network with name proxy already exists" | Not a problem — the network is already there. Guard the command with `docker network inspect proxy >/dev/null 2>&1 \|\|` as shown in Step 8. |
| Docker will not start after editing the daemon configuration | Malformed JSON or an option this daemon version rejects. `sudo jq . /etc/docker/daemon.json`, then `sudo journalctl -u docker -n 40 --no-pager`. Restore `{}` to get the daemon back, then reapply keys one at a time. |
| Docker starts but every image pull is enormous and slow, `docker info` shows `Storage Driver: vfs` | An unprivileged containerised guest that fell back from `overlay2`. Install `fuse-overlayfs` and set `"storage-driver": "fuse-overlayfs"` as the first key of the daemon configuration, then restart. |
| The reverse proxy or the monitoring agent stops seeing containers after a Docker restart, but reports healthy | The stale `/var/run/docker.sock` inode. Confirm with `systemctl is-enabled docker-sock-rebind.service`; if it is not enabled, install it per Step 6. As an immediate fix: `docker stop traefik && docker start traefik`. |
| A container is permanently unhealthy with `setns /proc/self/fd` errors after a restart | A `docker restart` raced the stale graph-driver state on a `fuse-overlayfs` host. Use `docker stop` followed by `docker start` — never `docker restart` — on these hosts. |
| Containers can reach IP addresses but cannot resolve names | The first entry of the daemon's `dns` list is unreachable. Check it from the host with `dig @<local-dns-ip> your-domain.com`; the `timeout:2 attempts:2` options mean failover to the public resolvers should take ~4s, so persistent failure means all three are wrong. |
| A container cannot reach the internet even though the host can | The firewall's `FORWARD` policy versus Docker's own rules. Do not add restrictions to `FORWARD` — put them in the `DOCKER-USER` chain, which is evaluated before Docker's rules and survives a daemon restart. |
| Root filesystem full | Usually container logs or unused images. `docker system df`, then `docker image prune -f` and `du -sh ./data/*`. If a single container's log is huge, its log options were not applied — log settings only take effect for containers created *after* the daemon restart, so recreate it. |
| Two containers get the same address on `proxy` | A fixed address was assigned inside `--ip-range`. Move the auto-allocation pool or the fixed address so they do not overlap, then recreate the affected containers. |
| Locked out by SSH after enabling the firewall | Use the machine's console. `sudo ufw status numbered`, add the SSH rule, or `sudo ufw disable` to get back in and start over. |
