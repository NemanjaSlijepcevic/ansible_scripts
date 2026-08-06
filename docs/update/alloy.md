# Alloy

## What this is

Alloy is Grafana's unified telemetry agent, and in this stack it is the **one and only** thing
deployed on every machine, without exception — the NAS, the public web server, the monitoring box
itself, the central database, the automation host, the secrets server, the photo-backup host and
the network-boot host all run the same container. It has two jobs, running side by side in one
process:

- **Logs**: it tails every Docker container's stdout/stderr on the local machine, the reverse
  proxy's access log files, and a handful of host system log files, then pushes matching lines to
  Loki.
- **Metrics**: it runs a small set of embedded exporters — a host/OS exporter, a per-container
  exporter, and an HTTP blackbox prober — scrapes them itself, and remote-writes the result to
  Prometheus. On a few machines it also scrapes one extra local service (PostgreSQL, Home
  Assistant, Kestra, OpenBao) that only exists there.

Both destinations live on the monitoring machine, so on every machine that is *not* the monitoring
machine, Alloy is pushing across the network. That crossing has to happen without a human present
to click through a login, which shapes both paths:

- **Logs** go straight to Loki's raw ingest port over the LAN — not through the reverse proxy at
  all. Loki's own public route is behind single sign-on, and an unattended agent cannot complete an
  interactive login, so it bypasses that route entirely and talks to the published port instead.
- **Metrics** go to Prometheus over HTTPS through the reverse proxy, because unlike Loki,
  Prometheus's container publishes no raw port on the host — the only path in is through the proxy.
  That router is deliberately left off the authenticating middleware chain (it still runs the
  intrusion-detection bouncer, rate limiting and the IP allow-list, just not the forced sign-in),
  for exactly the same reason: a remote-write push has no session to present.

On the monitoring machine itself, both destinations are reachable directly by container name on the
shared network, so there is no reason to leave it — the URLs are simply configured differently on
that one machine.

Alloy also drives a small piece that lives entirely outside Docker: a systemd timer on the host that
writes a Prometheus text file of per-container exited/OOM-killed state once a minute. The reason it
exists at all is that Alloy's per-container exporter (cAdvisor) can only report on containers that
are currently running — a container that crash-looped and is sitting in `exited`, or one the kernel
OOM-killed, is invisible to it. Without this file, the alerts built on top of it would simply never
fire.

Alloy publishes no route of its own. There is nothing to browse; its only output is the two pushes
described above.

---

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

All paths in this guide are relative to `<deploy-dir>`.

### The shared `proxy` bridge network exists

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

### systemd is available

The container-state helper described above is a host-level unit, not something that lives inside a
container.

```bash
systemctl --version | head -1
```

### Loki is already running and accepting pushes

If this machine **is** the monitoring machine, Loki is a local container and the check is local:

```bash
docker ps --filter 'name=^loki$'
curl -sf http://127.0.0.1:3100/ready && echo
```

If this machine is **not** the monitoring machine, Loki must already be reachable on the LAN on its
published port — Alloy is about to push to it directly, bypassing the proxy entirely:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' http://<monitor-ip>:3100/ready
```

### Prometheus is already running and accepting remote-write pushes

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://prometheus.your-domain.com/-/ready

# confirm the receiver flag that makes remote-write pushes possible is actually on
curl -sf https://prometheus.your-domain.com/api/v1/status/flags \
  | jq -r '.data["web.enable-remote-write-receiver"]'
```

The second command must print `true`. Without that flag, Prometheus's HTTP API accepts scrapes but
rejects every push with `404 page not found`, and every machine's Alloy would silently queue up
retries forever.

### The reverse proxy (Traefik) is running

Needed because the metrics path for every non-monitoring machine runs through it, and so does the
"public" half of any HTTP check Alloy is configured to run.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

### On the database machine only: the PostgreSQL client certificate has already been distributed

The metrics scrape of PostgreSQL authenticates with a client certificate, not a password. That
certificate is issued centrally and copied out to every machine that needs one — it is not generated
here.

```bash
ls -l ./data/certs/postgres_admin.crt ./data/certs/postgres_admin.key ./data/certs/ca.crt
```

If those files are not present, the certificate has not been distributed to this machine yet, and
the PostgreSQL scrape block in Step 3 below will fail to connect.

---

## Setup

### Overview

1. Create the container and host-side directories.
2. Install the host-side container-state helper (script, systemd service, systemd timer).
3. Write the Alloy configuration file.
4. Start the container.
5. Confirm both destinations are actually receiving data.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

mkdir -p ./data/alloy ./data/alloy/data
sudo chown -R <username>:<pgid> ./data/alloy
sudo chmod -R 0755 ./data/alloy

sudo mkdir -p /var/lib/alloy/textfiles /usr/local/lib/alloy
sudo chown root:root /var/lib/alloy/textfiles /usr/local/lib/alloy
sudo chmod 0755 /var/lib/alloy/textfiles /usr/local/lib/alloy
```

**Explanation**: `./data/alloy/data` is Alloy's own working storage — mainly the position files it
keeps for every log file and container stream it tails, so that a restart resumes tailing from where
it left off rather than re-shipping (or skipping) lines. Losing this directory does not lose data
that already reached Loki; the worst case is a batch of duplicate lines around the restart, not a
gap. `/var/lib/alloy/textfiles` and `/usr/local/lib/alloy` are **host** paths, not under `./data` —
they are owned by `root` because the script and its systemd unit run on the host as root, outside
Docker's ownership model entirely.

---

#### Step 2: Install the host-side container-state helper

This is the piece that makes crashed and OOM-killed containers visible. cAdvisor, the exporter
Alloy embeds for per-container metrics, only reports on containers Docker still lists as running —
once a container exits, cAdvisor has nothing left to scrape. A container that crash-loops, or one
the kernel killed for using too much memory, would otherwise vanish from every dashboard and every
alert the moment it stopped, which is exactly the moment you most want to know about it. The fix
is a script that reads the *complete* container list (`docker ps -a`), including the dead ones, and
turns that into a metrics file a different exporter can read.

Install the script:

```bash
sudo tee /usr/local/lib/alloy/docker-state.sh >/dev/null <<'SCRIPT'
#!/bin/sh
OUT="/var/lib/alloy/textfiles/docker.prom"
TMP="${OUT}.$$"
SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
API="http://localhost/v1.43"

CURL="curl -s --connect-timeout 2 --max-time 4 --unix-socket $SOCKET"

count_ids() {
  $CURL "$1" 2>/dev/null | tr ',' '\n' | grep -c '"Id"[[:space:]]*:' || true
}

total=$(count_ids "$API/images/json?all=true")
dangling=$(count_ids "$API/images/json?all=true&filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D")

if [ "${SKIP_SYSTEM_DF:-false}" = "true" ]; then
  df_json=""
else
  df_json=$($CURL "$API/system/df" 2>/dev/null || echo "")
fi
reclaimable=$(printf '%s' "$df_json" \
  | awk 'BEGIN { RS="{"; sum=0 }
         /"Containers"[[:space:]]*:[[:space:]]*-1/ || /"Containers"[[:space:]]*:[[:space:]]*0/ {
           if (match($0, /"Size"[[:space:]]*:[[:space:]]*[0-9]+/)) {
             s=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); sum+=s
           }
         }
         END { printf "%d", sum }' 2>/dev/null || echo 0)

{
  echo '# HELP docker_images_total Total docker images (all).'
  echo '# TYPE docker_images_total gauge'
  echo "docker_images_total ${total:-0}"
  echo '# HELP docker_images_dangling Dangling docker images.'
  echo '# TYPE docker_images_dangling gauge'
  echo "docker_images_dangling ${dangling:-0}"
  echo '# HELP docker_images_reclaimable_bytes Reclaimable image bytes (0 on fuse-overlayfs hosts).'
  echo '# TYPE docker_images_reclaimable_bytes gauge'
  echo "docker_images_reclaimable_bytes ${reclaimable:-0}"

  echo '# HELP docker_container_exited Container currently in the exited state.'
  echo '# TYPE docker_container_exited gauge'
  docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null \
    | while IFS= read -r name; do
        [ -n "$name" ] && printf 'docker_container_exited{container_name="%s"} 1\n' "$name"
      done

  echo '# HELP docker_container_oom_killed Container was OOM-killed.'
  echo '# TYPE docker_container_oom_killed gauge'
  docker ps -aq 2>/dev/null | while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ "$(docker inspect --format '{{.State.OOMKilled}}' "$id" 2>/dev/null || echo false)" = "true" ]; then
      name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
      printf 'docker_container_oom_killed{container_name="%s"} 1\n' "$name"
    fi
  done
} > "$TMP"

mv -f "$TMP" "$OUT"
SCRIPT
sudo chmod 0755 /usr/local/lib/alloy/docker-state.sh
```

Install the systemd service — set `SKIP_SYSTEM_DF=true` only if this machine's Docker daemon uses
the `fuse-overlayfs` storage driver, `false` otherwise:

```bash
sudo tee /etc/systemd/system/docker-state.service >/dev/null <<EOF
[Unit]
Description=Emit docker image/container-state metrics for Alloy textfile collector
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=SKIP_SYSTEM_DF=<true-or-false>
ExecStart=/usr/local/lib/alloy/docker-state.sh
EOF
```

Install the timer and start it:

```bash
sudo tee /etc/systemd/system/docker-state.timer >/dev/null <<'EOF'
[Unit]
Description=Periodically emit docker image/container-state metrics for Alloy

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now docker-state.timer
systemctl status docker-state.timer --no-pager
```

**Explanation**: The script calls the Docker Engine API directly over its Unix socket rather than
shelling out to `docker` for the image counts, so it has no dependency beyond `curl`; it does use the
`docker` CLI for the container list and inspect calls, which is fine since this runs on the host
where the CLI is already installed alongside the daemon. Every API call is time-bounded
(`--connect-timeout 2 --max-time 4`) so a slow or wedged daemon makes one metric fall back to zero
for one cycle instead of hanging the timer indefinitely. `SKIP_SYSTEM_DF` exists because of a real
failure mode on hosts running Docker's `fuse-overlayfs` storage driver (typically an LXC-hosted
Docker install, where the kernel overlay filesystem is unavailable): the `/system/df` endpoint has
to walk every image layer through the FUSE shim to compute reclaimable space, which can take minutes
and pins a CPU core for the duration — and aborting the client-side `curl` does not stop that walk on
the server side, so a one-minute timer would pile up concurrent walks. Setting `SKIP_SYSTEM_DF=true`
skips the call entirely and reports `reclaimable_bytes=0` instead, which is a fair trade on those
hosts. The `mv -f "$TMP" "$OUT"` at the end is a rename onto the final filename, which is what makes
the write atomic — the textfile collector inside Alloy would otherwise have a real chance of reading
a half-written file mid-update.

---

#### Step 3: Write the Alloy configuration file

This is the baseline that every machine gets. It ships every container's logs, the reverse proxy's
access log, a handful of host log files, a host/OS metrics exporter, a per-container metrics
exporter, and an HTTP blackbox prober — then forwards everything to Loki and Prometheus.

```bash
cd <deploy-dir>
sudo tee ./data/alloy/config.alloy >/dev/null <<'EOF'
// ============================== LOGS ==============================

discovery.docker "containers" {
  host             = "unix:///var/run/docker.sock"
  refresh_interval = "5s"
}

// Docker log discovery relabel_configs.
discovery.relabel "docker_logs" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/alloy"
    action        = "drop"
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_docker_container_log_stream"]
    target_label  = "logstream"
  }
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label  = "service"
  }
  rule {
    source_labels = ["__meta_docker_container_label_loki_drop"]
    regex         = "true"
    action        = "drop"
  }
}

loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.relabel.docker_logs.output
  relabel_rules = discovery.relabel.docker_logs.rules
  forward_to    = [loki.process.drop_noise.receiver]
}

// Traefik access-log files job.
local.file_match "traefik" {
  path_targets = [{
    __path__ = "/srv/traefik-logs/*.log",
    job      = "traefik",
  }]
}
loki.source.file "traefik" {
  targets    = local.file_match.traefik.targets
  forward_to = [loki.process.drop_noise.receiver]
}

// Host /var/log files job.
local.file_match "varlog" {
  path_targets = [{
    __path__ = "/var/log/{syslog,auth.log,kern.log,dpkg.log,unattended-upgrades/unattended-upgrades*.log}",
    job      = "varlog",
  }]
}
loki.source.file "varlog" {
  targets    = local.file_match.varlog.targets
  forward_to = [loki.process.drop_noise.receiver]
}

// Pipeline stages: drop blank lines and anything over 8KB.
loki.process "drop_noise" {
  stage.match {
    selector = "{container=\"kestra\"}"

    stage.replace {
      expression = "(\\x1b\\[[0-9;]*m)"
      replace    = ""
    }
    stage.multiline {
      firstline     = "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3}"
      max_wait_time = "3s"
    }
    stage.regex {
      expression = "^(?P<ts>\\d{2}:\\d{2}:\\d{2}\\.\\d{3})\\s+(?P<level>TRACE|DEBUG|INFO|WARN|ERROR)\\s+(?P<thread>\\S+)\\s+(?P<logger>\\S+)"
    }
    stage.labels {
      values = {
        level = "",
      }
    }
  }

  stage.match {
    selector = "{container!=\"kestra\"}"

    stage.drop {
      longer_than = "8KB"
    }
  }
  stage.drop {
    expression = "^\\s*$"
  }
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "<loki-ingest-url>"
  }
  external_labels = {
    node = "<host-label>",
  }
}

// ============================= METRICS =============================
prometheus.exporter.unix "node" {
  rootfs_path = "/rootfs"
  procfs_path = "/rootfs/proc"
  sysfs_path  = "/rootfs/sys"

  filesystem {
    fs_types_exclude = "^(tmpfs|devtmpfs|devfs|iso9660|overlay|aufs|squashfs)$"
    mount_timeout    = "5s"
  }

  textfile {
    directory = "/textfiles"
  }
}

// Per-container CPU/mem/net via cadvisor.
prometheus.exporter.cadvisor "docker" {
  docker_host      = "unix:///var/run/docker.sock"
  docker_only      = true
  storage_duration = "5m"
  store_container_labels = false
}

prometheus.exporter.blackbox "http" {
  config = "{ modules: { http_2xx: { prober: http, timeout: 5s }, http_2xx_or_redirect: { prober: http, timeout: 5s, http: { valid_status_codes: [200, 301, 302, 401], follow_redirects: false } }, http_2xx_authed: { prober: http, timeout: 5s, http: { headers: { Authorization: \"Bearer <api-token>\" } } } } }"

  target {
    name    = "<service>-internal"
    address = "http://<container>:<port>/health"
    module  = "http_2xx"
    labels  = {
      service = "<service>",
      via     = "internal",
    }
  }
  target {
    name    = "<service>-domain"
    address = "https://<service>.your-domain.com"
    module  = "http_2xx_or_redirect"
    labels  = {
      service = "<service>",
      via     = "domain",
    }
  }
}

// Scrape the embedded exporters and forward to remote_write.
prometheus.scrape "exporters" {
  targets = array.concat(
    prometheus.exporter.unix.node.targets,
    prometheus.exporter.cadvisor.docker.targets,
    prometheus.exporter.blackbox.http.targets,
  )
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}

prometheus.scrape "statics" {
  targets = [
    { "__address__" = "crowdsec:6060", "job" = "crowdsec" },
    { "__address__" = "<docker-gateway>:9323", "job" = "docker_daemon" },
    { "__address__" = "traefik:8082", "job" = "traefik" },
  ]
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}

prometheus.remote_write "default" {
  endpoint {
    url = "<prometheus-remote-write-url>"
  }
  external_labels = {
    host = "<host-label>",
  }
}
EOF

sudo chown <username>:<pgid> ./data/alloy/config.alloy
sudo chmod 0644 ./data/alloy/config.alloy
```

If this machine has anything host-specific to add — the syslog receiver, the PostgreSQL scrape, or
one of the single-service scrapes — add it now, before starting the container. Each is a self
contained block; see *Per-host additions* right after this step for the exact text and where it
goes.

**Explanation**: The two halves of the file are independent pipelines that happen to share one
process — nothing in the logs half depends on anything in the metrics half. `discovery.docker`
watches the Docker socket for the container list and feeds `loki.source.docker`, which is what tails
every container's stdout/stderr; the relabel step drops Alloy's own logs (an agent shipping its own
noise about itself is a very easy way to create a feedback loop) and promotes a few Docker labels
into first-class log labels (`container`, `service`, `logstream`) so Grafana can filter on them
without parsing the log line itself. `loki_drop=true` is an opt-out a container can carry as a Docker
label for services whose logs are pure noise.

The `stage.match` block for `container="kestra"` exists because Kestra's log lines are the one format
in this stack that does not arrive as a single clean line: they carry ANSI colour codes that make
them unreadable in a plain-text panel, and a single logical entry (a stack trace, say) can span
several physical lines. The `stage.replace` strips the colour codes, `stage.multiline` re-joins
continuation lines onto the line that started them using the timestamp prefix as the boundary, and
the following `stage.regex` / `stage.labels` pull the log level out into its own label so a dashboard
can filter by `level="ERROR"` without a text search. Every other container's logs skip straight to
`stage.drop { longer_than = "8KB" }`, which exists to stop one runaway line (a base64 blob, a stack
dump with no line breaks) from bloating a single chunk; `stage.drop` on blank lines exists because
several images (notably ones based on `nginx`) emit interleaved blank lines that add nothing but
noise to a log panel.

On the metrics side, `prometheus.exporter.unix` reads `/rootfs`, `/rootfs/proc` and `/rootfs/sys`
rather than the container's own `/proc` and `/sys` — those always describe the container's own
tiny cgroup, not the host, so without the `/rootfs` bind mount and matching path overrides every
node metric would describe Alloy's own sandbox instead of the machine it is running on.
`prometheus.exporter.cadvisor` is told `docker_only = true` so it does not also try to account for
Alloy's own process tree the way a bare cAdvisor instance would. The blackbox exporter's three
modules cover the shapes of check this stack actually needs: a bare 200 for an internal health
endpoint, tolerance for a redirect or a 401 for a public site (a public login-gated page correctly
returns 401 or bounces to a login page, and that is a "the site is up" result, not a failure), and an
authenticated variant for the one or two internal endpoints that require a bearer token to answer at
all. Each check is defined twice — once against the container's internal address, once against the
public domain — specifically so that a failure on the `via="domain"` probe with the `via="internal"`
probe still green tells you the problem is in the proxy or DNS, not the service itself.

The `docker_daemon` static target scrapes the Docker daemon's own metrics endpoint, which is
published on the bridge network's gateway address rather than `localhost` — that gateway address is
what the daemon's `metrics-addr` setting is configured to (a setting made once, on every host, by
the shared Docker daemon configuration), and it is the one address every container on the `proxy`
network can actually reach that endpoint through, since the daemon does not listen on the container
network's own interfaces.

`node` and `host` are deliberately two different label names for what is otherwise the same idea:
the label attached to every log line is `node`, and the one attached to every metric series is
`host`. Log lines from the syslog receiver (see *Per-host additions*) already carry their own
`hostname` label taken from the sender, and calling the top-level label something else avoids the
two colliding; on the metrics side there is no such clash, and `host` matches how the dashboards and
alert rules already refer to a machine.

---

### Per-host additions

None of these are needed on a plain machine that only runs the baseline above. Add the ones that
apply to this machine into `config.alloy` before starting the container.

**If this machine receives syslog from network devices that cannot run an agent** (typically only
the monitoring machine, for the firewall and the wireless access point) — insert this in the LOGS
section, after the `varlog` block and before `loki.process "drop_noise"`:

```
loki.relabel "syslog" {
  forward_to = []
  rule {
    source_labels = ["__syslog_message_hostname"]
    target_label  = "hostname"
  }
  rule {
    source_labels = ["__syslog_message_severity"]
    target_label  = "severity"
  }
  rule {
    source_labels = ["__syslog_message_app_name"]
    target_label  = "app"
  }
}

loki.source.syslog "dev_<device-name>" {
  listener {
    address       = "0.0.0.0:<syslog-port>"
    protocol      = "udp"
    syslog_format = "rfc3164"
    labels        = { job = "syslog", device = "<device-name>" }
  }
  relabel_rules = loki.relabel.syslog.rules
  forward_to    = [loki.process.drop_noise.receiver]
}
```

Repeat the `loki.source.syslog` block once per device, with a different label name and port. Publish
each port on the container in Step 4, and open it on the host firewall from that device's address
only:

```bash
sudo ufw allow from <device-address> to any port <syslog-port> proto udp
```

Why the relabelling stays best-effort: the `device` label from the listener block is the one you can
trust absolutely, because it comes from which port the packet arrived on, not from anything the
sender claims about itself. `hostname`, `severity` and `app` come from parsing the syslog message
itself, and a misconfigured or unusual sender can send a message that simply doesn't have one of
those fields — the rule then produces an empty label rather than an error, which is why `device` and
not `hostname` is what dashboards filter on to pick a specific device.

---

**If this machine is the database machine** — add the PostgreSQL exporter block just above
`prometheus.scrape "exporters"`, and add `prometheus.exporter.postgres.pg.targets` as a fourth entry
inside that block's `array.concat(...)` call:

```
// Postgres metrics over mTLS via the postgres exporter.
prometheus.exporter.postgres "pg" {
  data_source_names = ["postgresql://<admin-user>:<secret>@postgres:5432/postgres?sslmode=verify-ca&sslrootcert=/postgres-certs/ca.crt&sslcert=/postgres-certs/postgres_admin.crt&sslkey=/postgres-certs/postgres_admin.key"]
}
```

Mount the certificate directory read-only in Step 4 on this machine only:
`./data/certs:/postgres-certs:ro`.

**Explanation**: The `<secret>` in the connection string looks like a second authentication factor
alongside the certificate, but on this network it is not checked at all — PostgreSQL's access rule
for the shared bridge network authenticates on the client certificate alone
(`clientcert=verify-full`, no password method), so the exporter's certificate is what actually gets
it in, and the password field is populated only because the connection string syntax requires
something there. The certificate's Common Name has to equal the superuser name for the same rule to
accept it, which is why the certificate is named `postgres_admin.crt` and not something generic — a
mismatch there fails authentication regardless of whether the password field is right or wrong.
Because Alloy's container runs as the image's own default user rather than a fixed unprivileged
uid (see Step 4), it can read the mounted certificate files without needing their ownership adjusted
first, unlike some of the other services that also mount this directory.

---

**If this machine is the monitoring machine and Home Assistant publishes a Prometheus token** — add:

```
prometheus.scrape "homeassistant" {
  targets = [
    { "__address__" = "homeassistant:<homeassistant-port>", "job" = "homeassistant" },
  ]
  metrics_path    = "/api/prometheus"
  bearer_token    = "<homeassistant-prometheus-token>"
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

**If this machine is the automation machine** — add:

```
prometheus.scrape "kestra" {
  targets = [
    { "__address__" = "kestra:<kestra-metrics-port>", "job" = "kestra" },
  ]
  metrics_path    = "/prometheus"
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

**If this machine is the secrets machine** — add:

```
prometheus.scrape "openbao" {
  targets = [
    { "__address__" = "openbao:<openbao-port>", "job" = "openbao" },
  ]
  metrics_path    = "/v1/sys/metrics"
  params          = { format = ["prometheus"] }
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

Each of these three is a self-contained `prometheus.scrape` block, listed anywhere in the METRICS
section, forwarding to the same `prometheus.remote_write.default.receiver` as everything else — none
of them touch the `array.concat(...)` in `prometheus.scrape "exporters"`, because that call is
reserved for the exporters embedded in this same process (node, cadvisor, blackbox); these three are
separate services being scraped over the network, one job per service, so a failure in any one of
them shows up as its own `job` label rather than being folded into an unrelated exporter's metrics.

---

#### Step 4: Start the container

```bash
cd <deploy-dir>
docker run -d \
  --name alloy \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  -v "$(pwd)/data/alloy/data:/var/lib/alloy/data" \
  -v /:/rootfs:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker:/var/lib/docker:ro \
  -v /var/log:/var/log:ro \
  -v "$(pwd)/data/traefik/logs:/srv/traefik-logs:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /var/lib/alloy/textfiles:/textfiles:ro \
  -v /run/containerd/containerd.sock:/run/containerd/containerd.sock:ro \
  -v /dev/disk:/dev/disk:ro \
  --health-cmd 'alloy --version' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  grafana/alloy:latest \
  run \
  --server.http.listen-addr=0.0.0.0:12345 \
  --storage.path=/var/lib/alloy/data \
  /etc/alloy/config.alloy
```

Only on the database machine, add the certificate mount before the command:

```bash
  -v "$(pwd)/data/certs:/postgres-certs:ro" \
```

Only on a machine with a syslog receiver block, publish each port:

```bash
  -p <syslog-port>:<syslog-port>/udp \
```

**Explanation**: No `--user` is set, which is deliberate and different from every other container in
this stack — Loki, Prometheus and Grafana all drop to a fixed unprivileged uid because they only ever
touch their own data directory. Alloy cannot do that: it reads `/rootfs`, `/sys`, `/var/lib/docker`
and the Docker socket, all of which require the visibility the image's default user (root inside the
container) has. `--security-opt no-new-privileges:true` is the mitigation for that — it stops any
process inside the container from gaining privileges beyond what it started with, which matters more
here than almost anywhere else in the stack precisely because the container starts as root.

Every one of those host mounts is read-only, and each exists for exactly one collector: `/rootfs` and
`/sys` (paired with the path overrides inside the config file) are what let the node exporter
describe the host instead of the container's own sandbox; `/var/lib/docker` and the Docker socket are
what cAdvisor and the Docker log source need to enumerate and read containers; `/run/containerd/
containerd.sock` is mounted alongside the Docker socket because cAdvisor falls back to talking to
containerd directly for some per-container filesystem statistics that the Docker API alone does not
expose; `/dev/disk` lets the node exporter resolve a block device's stable by-id name so a disk's
metrics survive it being renumbered across a reboot; `/var/log` is the source for the host log files
tailed in the LOGS section; and `/textfiles` is the read side of the host-level container-state
helper installed in Step 2 — Alloy never writes there, only reads what the timer produced.

The health check runs `alloy --version`, which only proves the binary in the image is executable, not
that either pipeline is actually flowing — Step 5 is what actually proves that. Alloy's own HTTP
server, configured by `--server.http.listen-addr`, is not published to the host; it exists for local
debugging (its component graph, its own `/metrics`, and a `/-/reload` endpoint that can trigger a
config reload without a restart) and is reached with `docker exec`, not from outside the container.

---

#### Step 5: Confirm both destinations are actually receiving data

```bash
docker ps --filter 'name=^alloy$'
docker inspect --format '{{.State.Health.Status}}' alloy

docker exec alloy wget -qO- http://127.0.0.1:12345/-/ready && echo
```

Logs — from the monitoring machine, or through the API on any machine:

```bash
curl -sG http://<monitor-ip>:3100/loki/api/v1/query_range \
  --data-urlencode 'query={node="<host-label>"}' \
  --data-urlencode 'limit=5' | jq -r '.data.result[].values[][1]'
```

Metrics — query Prometheus for this machine's node exporter series:

```bash
curl -sG -u '<admin-user>:<secret>' https://prometheus.your-domain.com/api/v1/query \
  --data-urlencode 'query=up{host="<host-label>"}' | jq .
```

The container-state textfile is being refreshed:

```bash
systemctl status docker-state.timer --no-pager
sudo find /var/lib/alloy/textfiles/docker.prom -newermt '-2 minutes'
```

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data/alloy` | The unprivileged login on this machine | Steps 1, 3 |
| `<docker-ip>` | Alloy's fixed address on the `proxy` network | Any free address outside the automatic pool | Step 4 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | The bridge network's addressing | As created; `<docker-gateway>` also appears in the config file as the Docker daemon metrics target | Before you start, Step 3 |
| `<host-label>` | Short identifier for this machine | Consistent across the fleet — e.g. `nas`, `monitor`, `postgres`, `server`, `automation`, `openbao`, `immich`, `netboot` | Step 3 |
| `<loki-ingest-url>` | Where this machine pushes logs | On the monitoring machine: `http://loki:3100/loki/api/v1/push`. Everywhere else: `http://<monitor-ip>:3100/loki/api/v1/push` | Step 3 |
| `<monitor-ip>` | LAN address of the monitoring machine | Only needed on machines other than the monitoring one | Before you start, Step 3 |
| `<prometheus-remote-write-url>` | Where this machine pushes metrics | `https://prometheus.your-domain.com/api/v1/write` on every machine, including the monitoring one | Step 3 |
| `<service>` / `<container>` / `<port>` | An HTTP check target | Any internal service worth an uptime probe | Step 3 |
| `<api-token>` | Bearer token for an internal endpoint that requires one | Shared token used by that specific service; only needed if a check uses the authenticated blackbox module | Step 3 |
| `<device-name>` / `<syslog-port>` / `<device-address>` | A network device sending syslog | One block per device; the port must be free and is opened only to that device's address | Per-host additions |
| `<admin-user>` / `<secret>` (PostgreSQL) | Superuser name / password field | Must equal the Common Name baked into `postgres_admin.crt`; the password itself is not checked on this connection | Per-host additions |
| `<homeassistant-port>` / `<homeassistant-prometheus-token>` | Home Assistant's local port and its long-lived Prometheus token | From Home Assistant's own configuration | Per-host additions |
| `<kestra-metrics-port>` | Kestra's metrics port | As configured on the automation machine | Per-host additions |
| `<openbao-port>` | OpenBao's listener port | As configured on the secrets machine | Per-host additions |
| `<admin-user>` / `<secret>` (Prometheus) | Basic-auth credentials for querying Prometheus, if it has any in front of it | Only needed for the verification query in Step 5 | Step 5 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

Two things are fixed and should not be changed: the mounted socket paths, and Alloy's internal HTTP
port `12345` (unpublished, used only for local debugging).

---

## Verification

```bash
docker ps --filter 'name=^alloy$'
docker inspect --format '{{.State.Health.Status}}' alloy
docker exec alloy wget -qO- http://127.0.0.1:12345/-/ready && echo
```

Logs are arriving for this machine:

```bash
curl -sG http://<monitor-ip>:3100/loki/api/v1/label/node/values | jq -r '.data[]'
curl -sG http://<monitor-ip>:3100/loki/api/v1/query_range \
  --data-urlencode 'query={node="<host-label>"}' \
  --data-urlencode 'limit=5' | jq -r '.data.result[].values[][1]'
```

Metrics are arriving for this machine:

```bash
curl -sG -u '<admin-user>:<secret>' https://prometheus.your-domain.com/api/v1/query \
  --data-urlencode 'query=up{host="<host-label>"}' | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"'
```

The container-state textfile is fresh, and its two gauges show up once something is actually
exited or OOM-killed:

```bash
systemctl status docker-state.timer --no-pager
sudo find /var/lib/alloy/textfiles/docker.prom -newermt '-2 minutes'
curl -sG -u '<admin-user>:<secret>' https://prometheus.your-domain.com/api/v1/query \
  --data-urlencode 'query=docker_container_exited{host="<host-label>"}' | jq .
```

If a per-host addition was configured, confirm its own job specifically:

```bash
# database machine
curl -sG -u '<admin-user>:<secret>' https://prometheus.your-domain.com/api/v1/query \
  --data-urlencode 'query=pg_up{host="<host-label>"}' | jq .

# monitoring machine, syslog device
curl -sG http://127.0.0.1:3100/loki/api/v1/label/device/values | jq -r '.data[]'
```

From Grafana, open a dashboard filtered to this machine's `$host` / `$node` variable and confirm
both a metric panel and a log panel render — that proves the whole path end to end, on both
pipelines at once.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
cd <deploy-dir>
docker pull grafana/alloy:latest
docker stop alloy && docker start alloy
```

Use `docker stop` then `docker start`, never `docker restart` and never a bare recreate. `docker
restart` can race the graphdriver on a host using `fuse-overlayfs` and fail to pick up a config file
that was replaced (rather than edited in place) on disk, and a plain recreate against a sparse
specification would drop every one of the mounts in Step 4 back to the image's defaults, silently
losing host visibility. A separate stop, then start, avoids both.

**After editing `config.alloy`**, the same stop/start is the supported way to apply it. Alloy does
expose a `/-/reload` endpoint on its internal port that can pick up a changed file without a restart,
but it is not published outside the container in this deployment, so the practical path is the
container restart above.

**Logs:**

```bash
docker logs -f alloy
```

Startup logs list every component that loaded; a component that failed to start (a bad blackbox
target, a typo in a scrape block) is logged once at startup and does not stop the rest of the file
from running.

**The container-state timer** runs independently of the container:

```bash
systemctl status docker-state.timer --no-pager
sudo journalctl -u docker-state.service --since '10 min ago'
```

**Back up** `./data/alloy/data` only if avoiding a handful of duplicate log lines around a restart
matters to you; it holds no data that is not already in Loki and Prometheus.

---

## Rollback / Uninstall

```bash
docker stop alloy && docker rm alloy
```

To remove completely, including the host-level pieces from Step 2:

```bash
sudo rm -rf ./data/alloy
sudo systemctl disable --now docker-state.timer
sudo rm -f /etc/systemd/system/docker-state.timer /etc/systemd/system/docker-state.service \
  /usr/local/lib/alloy/docker-state.sh
sudo systemctl daemon-reload
sudo rm -rf /var/lib/alloy
docker rmi grafana/alloy:latest
```

On a machine with syslog ports open, also close them:

```bash
sudo ufw delete allow from <device-address> to any port <syslog-port> proto udp
```

This machine stops appearing in Grafana's `$host` / `$node` dashboard variables and every dashboard
and dead-man's-switch alert rule written for it starts firing as "no data" — remove its per-machine
rules from Grafana's alert provisioning if it is being retired rather than temporarily taken down.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container healthy, but no log lines from this machine ever appear in Loki | `<loki-ingest-url>` is wrong, or the destination's port 3100 is not reachable/firewalled from this machine. `docker logs alloy \| grep -i loki` shows the push errors. |
| Container healthy, but no metrics from this machine ever appear in Prometheus | `<prometheus-remote-write-url>` is wrong, the reverse proxy is down, or Prometheus's remote-write receiver flag is off — see *Before you start*. `docker logs alloy \| grep -i remote_write`. |
| Node metrics describe a tiny filesystem and a handful of processes, not the real host | The `/rootfs`, `/sys` mounts or their matching `rootfs_path`/`procfs_path`/`sysfs_path` overrides in `config.alloy` are missing — the exporter fell back to the container's own view. |
| Per-container metrics missing for one or two containers, present for the rest | Normal for a container that has exited — cAdvisor cannot see it. That is exactly the gap the container-state textfile fills; check `docker_container_exited` in Prometheus instead. |
| `docker_container_exited` / `docker_container_oom_killed` never show up at all | `docker-state.timer` is not running, or `/var/lib/alloy/textfiles` is not mounted into the container as `/textfiles`. `systemctl status docker-state.timer`. |
| `docker-state.service` runs but pins a CPU core for minutes at a time | This machine uses `fuse-overlayfs` and `SKIP_SYSTEM_DF` is not set to `true` in the unit file. |
| Syslog device's messages never arrive | Wrong protocol/port, or the firewall rule only allows a different source address than the device actually sends from. Confirm with `sudo tcpdump -ni any udp port <syslog-port>` on the host. |
| A domain (public) HTTP check fails while the matching internal check passes | DNS or a hairpin-NAT problem between this machine and its own public hostname, not a problem with the service. Consider pinning the check's hostname to the proxy's address directly rather than relying on public DNS from inside the network. |
| PostgreSQL scrape reports connection or authentication errors | The certificate files are missing, or their Common Name does not equal the connection's username. Re-check *Before you start* and the exporter block's explanation. |
| Config file rejected at startup, container keeps restarting | A syntax error in `config.alloy`. `docker logs alloy` prints the exact line and component that failed to load. |
| A machine's dashboards suddenly show "no data" everywhere | The container is down, or its `<host-label>` does not match what dashboards and alert rules expect — labels are exact-match strings, not free text. |
