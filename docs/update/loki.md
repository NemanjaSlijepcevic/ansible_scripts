# Loki

## What this is

Loki is the central log store. Every machine in the homelab runs a log/metric agent that tails the
system journal, the Docker container logs and (on this machine) a syslog listener, then pushes those
lines here. Grafana queries them back with LogQL.

It runs as one container on the monitoring machine, in single-binary mode: ingester, distributor,
querier and query frontend are all the same process, and chunks and indexes are plain files under
`./data/loki`. There is no object storage and no cluster.

It is reachable three ways, and the distinction matters:

- `http://loki:3100` from other containers on the same machine — how Grafana queries it.
- `<ip-address>:3100` on the LAN — how agents on the **other** machines push their logs, because
  port 3100 is published on the host.
- `https://loki.your-domain.com` through the reverse proxy — a human-facing route, behind single
  sign-on.

Multi-tenancy is off (`auth_enabled: false`), so anything that can reach port 3100 can write logs
and read everybody's. Keep that port restricted to the LAN with the host firewall.

---

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
docker compose version 2>/dev/null || true

# your account must be in the docker group, or every command below needs sudo
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent, install it from Docker's own repository (the distro package is usually
too old for the compose plugin) and enable the service:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in these guides is bind-mounted from here. Run all commands from
`<deploy-dir>` so the relative paths resolve.

### The shared `proxy` bridge network exists

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows
where to send a request.

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if it is missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

The `--ip-range` is the pool Docker hands out automatically; keep fixed container addresses
**outside** that pool so nothing is ever assigned an address you have reserved. Confirm the
addressing:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

### The reverse proxy (Traefik) is running

Traefik terminates TLS, owns ports 80 and 443, and routes to this service by the labels you put on
its container. It must be up before the service is reachable from a browser.

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

`healthcheck --ping` exits 0 only when Traefik's own ping endpoint answers, which means the static
configuration parsed and the entrypoints are bound. If the container is missing or the ping fails,
nothing you publish below will be reachable.

Confirm from outside that TLS terminates and a certificate is in place:

```bash
curl -sI https://proxy.your-domain.com | head -1
```

### Authelia (single sign-on) is running

Any router that carries the `chain-auth@file` middleware is forward-authenticated by Authelia. If
Authelia is down, those routes return 500 rather than a login page. Loki's public route uses that
chain, because nobody should be able to read every host's logs without logging in.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

A healthy Authelia answers `{"status":"OK"}`. From outside:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://auth.your-domain.com/api/health
```

### The service's DNS name resolves to this host

```bash
dig +short loki.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### Grafana is running

Grafana is the only consumer of these logs, and the last step of this guide registers Loki as one of
its data sources. Confirm it answers first:

```bash
docker ps --filter 'name=^grafana$'
curl -sf -o /dev/null -w '%{http_code}\n' https://grafana.your-domain.com/api/health
```

You also need Grafana's local admin username and password for that step — the API call uses basic
auth, which single sign-on accounts cannot do.

### Port 3100 is free and firewalled to the LAN

```bash
sudo ss -lntp '( sport = :3100 )'
sudo ufw status | grep 3100 || true
```

Nothing else may hold the port. Because Loki has no authentication of its own, allow it only from
the addresses your other machines use:

```bash
sudo ufw allow from <docker-subnet> to any port 3100 proto tcp
```

---

## Setup

### Overview

1. Create the data directories owned by the container's uid.
2. Write the Loki configuration file.
3. Start the container.
4. Wait for readiness.
5. Register Loki as a Grafana data source.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

sudo mkdir -p \
  ./data/loki \
  ./data/loki/chunks \
  ./data/loki/rules \
  ./data/loki/tsdb-shipper-cache

sudo chown -R 10001:10001 ./data/loki
sudo chmod -R 0755 ./data/loki
```

**Explanation**: The Loki image runs as uid/gid `10001` — a fixed, unprivileged account baked into
the image, not one that exists on your host. The bind-mounted directories must be owned by that
numeric id or Loki cannot create a single chunk file and crash-loops with
`mkdir /loki/chunks: permission denied`. Use the numbers directly; there is deliberately no matching
host user to look up. `chunks` holds the compressed log blocks, `rules` is where recording and
alerting rules would go (empty here — the alerting lives in Grafana instead), and
`tsdb-shipper-cache` is scratch space for the index.

---

#### Step 2: Write the configuration file

```bash
sudo tee ./data/loki/loki-config.yml >/dev/null <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: false

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
EOF

sudo chown 10001:10001 ./data/loki/loki-config.yml
sudo chmod 0644 ./data/loki/loki-config.yml
```

**Explanation**: `auth_enabled: false` means Loki does not require the tenant header on every
request and files everything under a single tenant — the right choice for one household, and the
reason port 3100 must not be exposed beyond the LAN. `replication_factor: 1` with an `inmemory` ring
and `instance_addr: 127.0.0.1` is what makes this a single process rather than a cluster: there is
no second copy of anything, so a lost disk is lost logs.

The schema entry is dated in the past on purpose. Loki applies schema periods by date, so an entry
`from` a date already behind you covers all existing data; you never edit that block, you append a
new one with a future date when migrating schema versions. `tsdb` with `schema: v13` is the current
index format and the only combination that supports the query patterns Grafana's dashboards use.

`reject_old_samples` with a 168-hour cut-off protects the index: log lines older than a week are
refused rather than accepted out of order, which is what happens when an agent that has been offline
for a month reconnects and tries to flush its backlog. Without it those writes land in old index
periods and make every subsequent query slower.

`allow_structured_metadata: false` keeps the push format to labels plus line only. The agents here do
not attach per-line metadata, and leaving it on costs index size for a feature nothing uses.

`log_level: info` is left at Loki's default even though Loki logs one stats line per query, tagged
`caller=metrics.go`. Those lines are genuinely useful when a dashboard is slow, and the log-overview
dashboard filters them out at query time with a `!= "query_hash"` line filter rather than throwing
them away at the source. Lower this to `warn` only if you want them gone permanently.

The embedded results cache is 100 MB of in-process memory that stops Grafana re-querying the same
time range on every dashboard refresh. It is not persisted; a restart empties it.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name loki \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -p 3100:3100 \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/loki:/loki" \
  -v "$(pwd)/data/loki/loki-config.yml:/etc/loki/loki-config.yml:ro" \
  --health-cmd 'loki --version' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 30s \
  --label traefik.enable=true \
  --label 'traefik.http.routers.loki.entrypoints=https' \
  --label 'traefik.http.routers.loki.rule=Host(`loki.your-domain.com`)' \
  --label 'traefik.http.routers.loki.tls=true' \
  --label 'traefik.http.routers.loki.middlewares=chain-auth@file' \
  --label 'traefik.http.services.loki.loadbalancer.server.port=3100' \
  grafana/loki:latest \
  -config.file=/etc/loki/loki-config.yml
```

**Explanation**: The `-config.file` argument at the end is not optional. The image's entrypoint
defaults to a bundled sample configuration, and a bind-mounted file is never picked up on its own —
without the flag Loki starts with local defaults, ignores everything you wrote in Step 2, and stores
chunks somewhere inside the container that vanishes on the next recreate.

The configuration file is mounted a second time, read-only, on top of the data directory mount, so
that Loki cannot rewrite its own configuration and so that the file's ownership requirements are
independent of the data.

Port 3100 is published to the host because the agents on the *other* machines push their logs
straight to it over the LAN. They cannot use the `https://loki.your-domain.com` route: that router
carries the authenticating middleware chain, and an agent has no session to present — every push
would come back as a redirect to the login page. Publishing the port is what makes cross-host
ingestion work, and the firewall rule from *Before you start* is what keeps it from being open to
the world.

The health check runs `loki --version`, which only proves the binary in the container is executable.
Loki's real readiness endpoint needs the ingester to have joined its own ring, which takes longer
than a health check's patience on a cold start; the readiness check in the next step is the one that
actually means something.

---

#### Step 4: Wait until Loki is ready

```bash
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ready)
  echo "attempt $i: $code"
  [ "$code" = "200" ] && break
  sleep 10
done
```

**Explanation**: `/ready` returns 503 with a body explaining what it is still waiting for
(usually `Ingester not ready: waiting for 15s after being ready`) until the ingester has joined the
ring and served its first flush cycle. Registering the data source in Grafana before that point
produces a data source that tests green and then returns errors for the first minute, so wait here
rather than there. On a first start this takes about half a minute; if it is still 503 after two
minutes, read `docker logs loki`.

---

#### Step 5: Register Loki as a Grafana data source

```bash
# is a data source called "Loki" already there?
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/datasources \
  | jq -r '.[] | select(.name == "Loki") | "\(.uid)\t\(.url)"'
```

If that prints nothing, create it:

```bash
curl -sf -u '<admin-user>:<secret>' -X POST \
  -H 'Content-Type: application/json' \
  https://grafana.your-domain.com/api/datasources \
  -d '{
        "name": "Loki",
        "type": "loki",
        "access": "proxy",
        "url": "http://loki:3100",
        "jsonData": { "tlsSkipVerify": true }
      }'
```

Confirm it answers:

```bash
curl -sf -u '<admin-user>:<secret>' \
  https://grafana.your-domain.com/api/datasources/name/Loki | jq -r '.uid, .url'
```

**Explanation**: The URL Grafana is given is the internal container name, not the public hostname.
`access: proxy` means Grafana's own process makes the query, and it sits on the same bridge network,
so `http://loki:3100` resolves and skips TLS, the proxy and single sign-on entirely — a browser
never talks to Loki directly. Pointing it at the public URL instead would send every panel query
through the authenticating chain with no session and fail.

Creating it is conditional because Grafana may already define this data source from a file it reads
at startup, in which case a POST fails with `data source with the same name already exists` and the
file version is authoritative anyway. Check first, create only if absent.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data` and its group | The unprivileged login on this machine | Before you start |
| `<docker-ip>` | Loki's fixed address on the `proxy` network | Any free address in the network's subnet, outside the automatic pool | Step 3 |
| `<docker-subnet>` | The bridge network's CIDR | As created; also the source allowed to reach port 3100 | Before you start |
| `<ip-address>` | This machine's LAN address | What the other machines' agents push to, on port 3100 | What this is |
| `<admin-user>` / `<secret>` | Grafana's **local** admin account | Not a single sign-on account — basic auth only works for the local one | Step 5 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

Two values are fixed and must not be changed: the container uid/gid `10001`, and the HTTP port
`3100` (it appears in the configuration file, the published port, the proxy label and every agent's
push URL).

---

## Verification

```bash
docker ps --filter 'name=^loki$'
docker inspect --format '{{.State.Health.Status}}' loki

# ready, and its own metrics endpoint answers
curl -sf http://127.0.0.1:3100/ready && echo
curl -sf http://127.0.0.1:3100/metrics | head -5

# which machines have pushed logs recently — one line per host label
curl -sG http://127.0.0.1:3100/loki/api/v1/label/node/values | jq -r '.data[]'

# and which containers
curl -sG http://127.0.0.1:3100/loki/api/v1/label/container/values | jq -r '.data[]'

# pull the last few lines from one machine
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={node="<host>"}' \
  --data-urlencode 'limit=5' | jq -r '.data.result[].values[][1]'
```

Chunks are being written if the directory grows:

```bash
sudo du -sh ./data/loki/chunks
sudo find ./data/loki/chunks -type f -newermt '-5 minutes' | head
```

From Grafana, open *Explore*, choose the Loki data source, and run `{node="<host>"}` — that proves
the whole path, agent to store to dashboard.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull grafana/loki:latest
docker stop loki && docker rm loki
# re-run the docker run from Step 3, then the readiness loop from Step 4
```

Read Loki's changelog before a major version jump — schema and configuration keys do get renamed
between versions, and a rejected configuration key stops the process at startup rather than warning.

**After editing `loki-config.yml`:**

```bash
docker restart loki
```

There is no config reload endpoint enabled; a restart is the reload.

**Logs:**

```bash
docker logs -f loki
```

Loki logs to stdout. One stats line per query is normal and expected — see Step 2.

**Disk is the chore.** This configuration has no compactor and no retention period, so chunks
accumulate for as long as the disk allows. Watch it:

```bash
sudo du -sh ./data/loki/chunks ./data/loki/tsdb-shipper-cache
df -h .
```

When it gets uncomfortable, either add a `compactor` block with `retention_enabled: true` and a
`limits_config.retention_period`, restart, and let Loki delete by policy — or stop the container and
delete whole index periods by hand. Never delete files from `./data/loki/chunks` while Loki is
running; the index will still reference them and queries return `object not found` for weeks.

**Back up** `./data/loki` only if old logs matter to you. It is generally treated as expendable — the
data is a copy of what was already written elsewhere, and it is by far the largest directory on the
machine.

---

## Rollback / Uninstall

```bash
docker stop loki && docker rm loki
```

The stored logs survive, so re-running Step 3 brings everything back. To remove completely:

```bash
sudo rm -rf ./data/loki
docker rmi grafana/loki:latest
sudo ufw delete allow from <docker-subnet> to any port 3100 proto tcp
```

Then delete the data source in Grafana, or it stays in the list and every log panel shows a
connection error:

```bash
curl -sf -u '<admin-user>:<secret>' -X DELETE \
  https://grafana.your-domain.com/api/datasources/name/Loki
```

Point the agents on the other machines somewhere else, or stop them — otherwise they retry the push
forever and fill their own logs with connection errors.

---

## Troubleshooting

**Container restarts in a loop, log says `permission denied` on `/loki/...`**
The data directory is not owned by `10001:10001`. Re-run the `chown` from Step 1. This happens most
often after restoring a backup as root.

**Container starts but the configuration you wrote is ignored**
The `-config.file=/etc/loki/loki-config.yml` argument is missing from the `docker run`. Confirm with
`docker inspect --format '{{.Config.Cmd}}' loki`.

**`/ready` returns 503 forever**
Read the body: `curl -s http://127.0.0.1:3100/ready`. `waiting for 15s after being ready` clears on
its own. Anything mentioning the ring means the ingester cannot register — with an `inmemory` ring
that means the process is unhealthy, so check `docker logs loki` for a config parse error.

**Agents report `429 Too Many Requests` or `entry too far behind`**
That is `reject_old_samples` refusing a backlog older than 168 hours, usually from an agent that has
been offline for a long time. The old lines are lost; the agent recovers as soon as it reaches
recent data.

**Agents on other machines cannot push**
They must reach `<ip-address>:3100` directly, not the `https://loki.your-domain.com` route — that
route is behind single sign-on and will bounce an agent's push. Check the firewall rule, then test
from the other machine: `curl -sf -o /dev/null -w '%{http_code}\n' http://<ip-address>:3100/ready`.

**Grafana panels show `dial tcp: lookup loki: no such host`**
Grafana and Loki are not on the same bridge network. `docker network inspect proxy | jq -r
'.[0].Containers[].Name'` must list both.

**Queries return nothing but `du` shows chunks growing**
Almost always a label mismatch, not a data loss. List what actually exists:
`curl -sG http://127.0.0.1:3100/loki/api/v1/labels | jq -r '.data[]'`, then the values of the label
you are filtering on. A stream selector that matches no label returns an empty result with no error.

**Queries are slow and the log is full of `caller=metrics.go` lines**
Those lines are the query stats, not errors. If queries really are slow, narrow the time range —
this is a single process reading files, and a two-week `{node=~".+"}` query reads every chunk on
disk.

**Disk full**
See *Updating & day-to-day*. There is no retention configured by default; this will happen
eventually if nobody looks.
