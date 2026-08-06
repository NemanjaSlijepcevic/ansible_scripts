# Installing Docker

## What this is

Installs Docker Engine on a machine and configures the daemon for long-running unattended service: capped per-container logs, fixed upstream DNS, a metrics endpoint bound to loopback, and containers that keep running across a daemon restart.

It also creates the `docker` group and puts the machine's accounts in it, installs the Python bindings that remote tooling uses to drive the daemon, adds a rotation policy for daemon-side log files, and finishes by running a throwaway container to prove the whole stack works end to end.

This is the last software installed during the bootstrap. Everything that runs on these machines afterwards runs as a container.

## Before you start

- Root or `sudo` on the machine:

  ```bash
  sudo -v && echo "sudo ok"
  ```

- The accounts that will use Docker must already exist. They are added to a group here, and adding a nonexistent user to a group fails:

  ```bash
  id <username>
  ```

- `curl`, `jq` and `ca-certificates` installed — the installer is fetched with `curl`, the daemon config is validated with `jq`, and neither works over HTTPS without the trust store:

  ```bash
  command -v curl jq || sudo apt-get install -y curl jq ca-certificates
  ```

- `logrotate` installed:

  ```bash
  command -v logrotate || sudo apt-get install -y logrotate
  ```

- Outbound HTTPS to `get.docker.com`, Docker's package repository and Docker Hub:

  ```bash
  curl -sfI https://get.docker.com >/dev/null && echo "reachable"
  ```

- Know the distribution — one step is Debian-only:

  ```bash
  . /etc/os-release && echo "$ID $VERSION_ID"
  ```

## Setup

### Overview

1. Create the `docker` group.
2. Add each account to it.
3. Install Docker Engine from the official installer.
4. Install the Python support packages.
5. On Debian only: clear the marker that blocks system-wide Python installs.
6. Install the Python Docker bindings.
7. Write the daemon configuration.
8. Validate it and restart the daemon.
9. Add rotation for the daemon log directory.
10. Prove it works with a throwaway container.

---

#### Step 1: Create the `docker` group

```bash
sudo groupadd --system docker
```

**Explanation**: The daemon listens on a Unix socket at `/var/run/docker.sock`, owned by `root:docker`. Group membership is the only thing that decides who can talk to it without `sudo`.

Create the group before installing the engine. The installer creates it too, but creating it first means Step 2 can run immediately and both orders end in the same state.

`--system` gives it a low GID from the system range, which matters when container UID and GID numbers are mapped against the host — a group that landed in the ordinary user range would be far easier to collide with.

If it already exists, `groupadd` exits non-zero saying so. That is the desired state; ignore it.

Be clear-eyed about what this group is: membership in `docker` is equivalent to root on the machine. Anyone who can reach that socket can start a container that mounts the host filesystem and read or write anything. Add accounts to it deliberately.

---

#### Step 2: Add accounts to the group

```bash
sudo usermod --append --groups docker <username>
```

Repeat for each account that needs it.

**Explanation**: `--append` is not optional. Without it, `usermod --groups` *replaces* every supplementary group the account has, so an account in `sudo` and `ssh` would be silently stripped of both and lose its escalation and, if the daemon is restricted by group, its ability to log in at all.

Group membership is established at login. An account that is already logged in does not gain Docker access until it opens a new session — `newgrp docker` picks it up for one shell in the meantime, and is the usual explanation for "it works for me but not for them".

---

#### Step 3: Install Docker Engine

```bash
curl -fsSL https://get.docker.com -o /tmp/docker.sh
chmod 0755 /tmp/docker.sh
sudo /tmp/docker.sh
rm -f /tmp/docker.sh
```

**Explanation**: The official convenience script detects the distribution and release, adds Docker's apt repository and signing key, and installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin`. Getting all of that right by hand is a dozen error-prone commands that change between releases.

It is downloaded to a file and then executed, never `curl … | sudo bash`. Piping into a shell means the shell begins executing while the rest is still arriving, so a connection that drops halfway leaves a partially applied install with no record of how far it got. On disk you can read it first, and re-run exactly the same thing if something fails.

Re-running the script on a machine that already has Docker is safe — it detects the existing install and upgrades through apt rather than reinstalling.

The `curl` flags matter: `-f` makes HTTP errors fail instead of writing an error page into the file you are about to execute as root, `-sS` stays quiet but still shows real errors, and `-L` follows the redirect that `get.docker.com` issues.

---

#### Step 4: Install the Python support packages

```bash
sudo apt-get install -y \
  python3-pip \
  virtualenv \
  python3-setuptools \
  python3-docker
```

**Explanation**: Remote management tooling drives the daemon through its HTTP API using the `docker` Python library rather than by shelling out to the `docker` binary, so the library has to be present on the machine being managed. `python3-docker` is the distribution's packaged version of it; `python3-pip` and `python3-setuptools` are there so the next steps can install or upgrade it from the Python package index when the packaged one is too old, and `virtualenv` for when something needs an isolated environment.

---

#### Step 5: Debian only — clear the externally-managed marker

Skip this entirely on Ubuntu.

```bash
. /etc/os-release
if [ "$ID" = "debian" ]; then
  sudo find /usr/lib -type f -name EXTERNALLY-MANAGED -print -delete
fi
```

**Explanation**: Debian ships a file named `EXTERNALLY-MANAGED` inside its Python installation directories. It is a marker that makes `pip` refuse to install anything system-wide, on the reasoning that `apt` owns those files and pip-installed packages would fight with it.

That protection is correct in general and inconvenient here: Step 6 installs the Docker bindings system-wide so that tooling connecting to the machine finds them on the default interpreter, without having to know about a virtual environment path.

The `find` is recursive because the file's location moves with the Python minor version (`/usr/lib/python3.11/`, `/usr/lib/python3.13/`, and so on), and there can be more than one interpreter installed. Removing them all is why this is a `find … -delete` rather than a single `rm`.

Understand the trade you are making: from here, a system-wide `pip install` can overwrite files that `apt` believes it owns, and a later `apt` upgrade can overwrite them back. On a machine that exists to run containers this is acceptable. On a general-purpose workstation it would not be.

---

#### Step 6: Install the Python Docker bindings

```bash
sudo pip3 install docker
```

**Explanation**: Ensures the library is present and reasonably current regardless of what the distribution packaged. On Ubuntu, where Step 5 was skipped, this may report that the requirement is already satisfied by `python3-docker` — that is fine and nothing further is needed.

---

#### Step 7: Write the daemon configuration

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
    "metrics-addr": "127.0.0.1:9323",
    "dns": ["1.1.1.1", "8.8.8.8"],
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

**Explanation**: The stock daemon defaults are tuned for a laptop. These are the four changes that matter on a machine expected to run for months without attention.

| Setting | Value | Why |
|---------|-------|-----|
| `metrics-addr` | `127.0.0.1:9323` | Exposes the daemon's own metrics for a local collector to scrape. Bound to loopback deliberately — this endpoint has no authentication whatsoever, and on `0.0.0.0` it is an unauthenticated listing of everything running on the machine, readable by anyone who can reach the port. |
| `dns` | two public resolvers | Containers otherwise inherit the host's resolver. On a host pointed at a split-horizon or local DNS server, a container resolving an internal name gets the internal address and then cannot route to it, producing intermittent failures that look like network flakiness. Pinning public resolvers makes container DNS predictable and identical on every machine. |
| `dns-opts` | `timeout:2`, `attempts:2` | The default resolver behaviour is 5 seconds per attempt with up to 2 attempts, so a dead resolver stalls a container's startup for ten seconds or more. Two seconds and two attempts fails over to the second resolver quickly enough that a health check does not trip. |
| `log-driver` | `json-file` | The default, stated explicitly so the `log-opts` below are unambiguous — several drivers ignore them silently. |
| `log-opts.max-size` | `50m` | **The single most important line in this file.** Without it, container logs are unbounded, and one chatty container will fill the root filesystem and take down every other container on the machine with it. |
| `log-opts.max-file` | `5` | Five rotations per container, so roughly 250 MB worst case per container. Enough history to debug yesterday's incident, bounded. |
| `live-restore` | `true` | Containers keep running while the daemon itself is restarted or upgraded. Without it, every container on the machine stops for the duration of a daemon upgrade — including the reverse proxy, which means the outage is total rather than momentary. |

The log settings apply to containers created *after* this file is in place. Containers that already exist keep the limits they were created with, so anything predating this configuration needs to be recreated, not just restarted.

---

#### Step 8: Validate and restart the daemon

```bash
sudo jq . /etc/docker/daemon.json && echo "json ok"
```

Only if that succeeds:

```bash
sudo systemctl restart docker
sudo systemctl enable docker
systemctl is-active docker
```

**Explanation**: The daemon refuses to start on malformed JSON, and it does so *after* stopping the old one. A trailing comma therefore takes every container on the machine offline until someone notices and fixes the file. `jq` parses it in a second and costs nothing, so validation always comes first and is chained with `&&`.

`enable` makes the daemon come back after a reboot. With `live-restore: true`, containers with a restart policy come back with it.

---

#### Step 9: Rotate the daemon log directory

```bash
sudo tee /etc/logrotate.d/docker >/dev/null <<'EOF'
/var/log/docker/*.log {
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
sudo chown root:root /etc/logrotate.d/docker
sudo chmod 0644 /etc/logrotate.d/docker
```

**Explanation**: This covers anything written into `/var/log/docker/` — daemon-side or service log files that land there — and is separate from, not a replacement for, the `log-opts` in Step 7. Container stdout is captured by the daemon into `/var/lib/docker/containers/*/`, and only the `max-size` and `max-file` settings bound those. Both mechanisms are needed and neither covers the other's files.

`missingok` earns its place here: on a machine where nothing writes to `/var/log/docker/` the glob matches nothing, and without it the whole nightly rotation run would fail on this one policy.

The rest of the options do the same job as in any of the other rotation policies on the machine: rotate on size rather than a calendar so a quiet machine keeps history and a noisy one cannot fill the disk, keep three compressed generations, leave the newest uncompressed for a cycle in case a process still holds a descriptor on it, and recreate the file `0640 root adm` so log contents are not world-readable. The `postrotate` reload is written to swallow its own failure so a machine with no `rsyslog` installed does not fail the run.

---

#### Step 10: Prove it works

```bash
sudo docker run --name hello-world-test hello-world
sudo docker rm hello-world-test
sudo docker rmi hello-world
```

**Explanation**: One command exercises the entire chain: the daemon is up and accepting API calls, DNS resolves, the machine can reach Docker Hub, an image can be pulled and unpacked, a container namespace can be created, and the process runs and exits cleanly. If it prints `Hello from Docker!`, the install is genuinely finished — as opposed to `systemctl is-active docker` saying `active` while image pulls fail on a DNS or proxy problem you discover a week later.

The container is run named rather than with `--rm` so that its exit status and logs survive the run and can be inspected if it fails. Both the container and the image are then removed, because the point was the test and leaving a stopped container behind is exactly the sort of residue that makes `docker ps -a` unreadable a year on.

If you get `Cannot connect to the Docker daemon`, the daemon is not running — go back to Step 8 and read `sudo journalctl -u docker -n 50`.

---

## Values to fill in

| Placeholder | What it is | How to choose it |
|-------------|-----------|------------------|
| `<username>` | An account that should be able to run `docker` without `sudo` | Every account that administers containers on this machine. Remember this grants effective root. Used in Step 2. |
| `metrics-addr` port | Where the daemon exposes its own metrics | `127.0.0.1:9323` unless something else on the machine already has that port. Keep it on loopback; the endpoint is unauthenticated. Used in Step 7. |
| `dns` entries | Upstream resolvers for containers | Two public resolvers, or your own if you have one that is reachable from container networks and not split-horizon. Used in Step 7. |
| `log-opts.max-size` / `max-file` | Per-container log cap | `50m` × `5` is roughly 250 MB per container worst case. Lower them on a small disk with many containers. Used in Step 7. |

## Verification

```bash
# Engine installed and daemon reachable
sudo docker version
systemctl is-active docker
systemctl is-enabled docker

# The configuration actually took effect
sudo docker info | grep -i 'logging driver'
sudo docker info | grep -i 'live restore'

# Metrics endpoint answers, on loopback only
curl -sf http://127.0.0.1:9323/metrics | head -3
sudo ss -tlnp | grep 9323          # must show 127.0.0.1, never 0.0.0.0

# Python bindings importable
python3 -c 'import docker; print(docker.__version__)'

# Group membership
getent group docker
id <username>

# Rotation policy parses
sudo logrotate --debug /etc/logrotate.d/docker

# A container really runs
sudo docker run --rm hello-world
```

As `<username>`, in a **fresh** session (group membership only applies to new logins):

```bash
docker ps
```

That must work without `sudo`.

## Updating & day-to-day

- Upgrade the engine like any other package — Docker's repository was added by the installer:

  ```bash
  sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  ```

  With `live-restore: true`, running containers survive the daemon restart this causes.

- Daemon logs:

  ```bash
  sudo journalctl -u docker -f
  ```

- Container logs (bounded by the settings in Step 7):

  ```bash
  docker logs -f --tail 100 <container>
  ```

- Reclaim disk from stopped containers, dangling images and unused networks:

  ```bash
  docker system df
  docker system prune -f
  ```

  `docker system prune -a --volumes` also removes unused images *and volumes* — volumes are where container data lives, so never run it without knowing what is unused.

- After changing `/etc/docker/daemon.json`: `sudo jq . /etc/docker/daemon.json && sudo systemctl restart docker`, in that order, always.
- Log limit changes only apply to containers created afterwards. Recreate long-lived containers to pick them up.
- Docker publishes container ports by writing directly into `iptables`, below the layer the host firewall manages. A published port is reachable from the network even when the firewall does not list it. Bind to `127.0.0.1` for anything that should be local only.

## Rollback / Uninstall

Remove the engine and everything it stored:

```bash
sudo systemctl stop docker
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
sudo rm -f /etc/logrotate.d/docker
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo groupdel docker
```

**This deletes every image, container, volume and network on the machine.** `/var/lib/docker` is where container data lives; back up any volume you care about first:

```bash
docker volume ls
sudo tar czf /root/docker-volumes-backup.tar.gz -C /var/lib/docker volumes
```

To back out only the daemon configuration and keep Docker:

```bash
sudo rm /etc/docker/daemon.json
sudo systemctl restart docker
```

Note that this removes the log size caps, so container logs become unbounded again.

To remove one account's access without touching the install:

```bash
sudo gpasswd --delete <username> docker
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Daemon will not start after editing the configuration | Almost always malformed JSON. `sudo jq . /etc/docker/daemon.json` names the line; `sudo journalctl -u docker -n 50 --no-pager` gives the daemon's own complaint. |
| `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` | The daemon is down (`systemctl is-active docker`), or you are not in the `docker` group and not using `sudo`. |
| An account is in the `docker` group but still gets permission denied | Group membership applies at login. Open a new session, or `newgrp docker` for the current shell. Confirm with `id <username>`. |
| Containers cannot resolve hostnames | Check the `dns` entries in the configuration are reachable *from the container's network*: `docker run --rm alpine nslookup example.com`. A resolver on a network the container cannot route to fails exactly like this. |
| Disk full, `/var/lib/docker` enormous | Either images and stopped containers piled up (`docker system df`, then `docker system prune`), or a container predating the log settings has an unbounded log. Find it: `sudo du -sh /var/lib/docker/containers/* \| sort -h \| tail`. Recreating the container applies the caps. |
| Log caps do not seem to apply | The container was created before the configuration was written. `docker inspect <container> \| jq '.[0].HostConfig.LogConfig'` shows what it actually has. Recreate it — restarting is not enough. |
| Containers all stop during a daemon upgrade | `live-restore` was not in effect. Confirm with `sudo docker info \| grep -i 'live restore'`. It also does not apply to containers in swarm mode. |
| `pip3 install docker` fails with `externally-managed-environment` | The Debian marker is still present. Re-run the `find … -delete` from Step 5. |
| `python3 -c 'import docker'` fails after installing | Two interpreters on the machine and the library landed under the other one. Check `python3 -V` and `pip3 -V` agree on the version. |
| The metrics endpoint is reachable from other machines | `metrics-addr` was set to `0.0.0.0:9323`. It is unauthenticated; put it back on `127.0.0.1` and restart the daemon. |
| The convenience script refuses to run | It does not support every distribution and release. Read its output — it names what it detected — and install from Docker's repository manually for that release. |
| A published container port is open despite the firewall | Expected: Docker inserts its own `iptables` rules below the firewall's. Publish as `127.0.0.1:<port>:<port>`, or put the container behind a reverse proxy. |
