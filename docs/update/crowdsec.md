# CrowdSec

## What this is

CrowdSec is the intrusion detection and prevention agent on every host in this stack. It tails the
reverse proxy's access log, the single sign-on portal's log and the host's own system logs, matches
them against downloaded scenarios (credential stuffing, path scanning, known HTTP CVE probes,
WordPress attacks), and turns matches into *decisions* — bans on source addresses. It also
subscribes to the community blocklist, tens of thousands of addresses seen attacking other CrowdSec
installations.

Decisions are enforced by **bouncers**, and there are two:

- The **Traefik bouncer** is a plugin compiled into the reverse proxy process. There is no container
  for it. It pulls the whole decision list from the local agent every 60 seconds and holds it in
  memory, so every request is checked against it at no network cost. Every middleware chain on this
  host includes it, so it protects everything.
- The **Cloudflare bouncer** is a container, and only runs on the public-facing host. It pushes
  banned addresses into a Cloudflare IP list so they are challenged at the CDN edge and never reach
  this machine at all.

The agent runs on the NAS, the monitoring box, the database host, the automation host and the public
server. It talks to the local reverse proxy (which pulls decisions from it over the shared network),
to CrowdSec's hub and central API over the internet, and — on the public host only — to the
Cloudflare API. It publishes no route of its own; it is not reachable from outside the host.

State lives in a bundled SQLite database at `/var/lib/crowdsec/data/crowdsec.db`, mounted from
`./data/crowdsec/data`. That is deliberate: the image ignores the environment variables that would
point it at PostgreSQL, so switching engines would require a mounted agent configuration with a
database block, not environment variables.

## Before you start

**Docker is installed and your account can use it**

```bash
docker --version
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

**The `./data` working directory exists and you are in it**

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
```

All paths below are relative to `<deploy-dir>`.

**The shared `proxy` bridge network exists**

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

**The reverse proxy is running and writing logs**

CrowdSec reads its access log; without it the traffic scenarios have nothing to work on.

```bash
docker ps --filter 'name=^traefik$'
ls -l ./data/traefik/logs/
tail -1 ./data/traefik/logs/access.log | head -c 200
```

**The single sign-on portal is running and writing logs**

Its log is where repeated failed logins show up.

```bash
docker ps --filter 'name=^authelia$'
ls -l ./data/authelia/logs/authelia.log
```

If either service is not deployed on this host, create the directory anyway so the bind mount does
not fail:

```bash
mkdir -p ./data/traefik/logs ./data/authelia/logs
```

**Outbound HTTPS works from a container**

The agent downloads its scenario hub and the community blocklist on start.

```bash
docker run --rm curlimages/curl -sf -o /dev/null -w '%{http_code}\n' https://hub.crowdsec.net
```

**You have decided the Traefik bouncer's API key**

It is a shared secret between the agent and the proxy plugin. Generate one now if you do not have
one, and keep it — the same value must appear in the proxy's bouncer middleware:

```bash
openssl rand -hex 32
```

## Setup

### Overview

1. Create the directory layout.
2. Write the log acquisition configuration.
3. Create the host log files that will be mounted.
4. Start the agent.
5. Update and upgrade the scenario hub.
6. Register the Traefik bouncer's key.
7. Public-facing host only: the Cloudflare bouncer.
8. Prove the proxy is actually pulling decisions.

---

#### Step 1: Create the directory layout

```bash
cd <deploy-dir>
mkdir -p ./data/crowdsec/config ./data/crowdsec/data
sudo chown -R <username>:<pgid> ./data/crowdsec
sudo chmod 0755 ./data/crowdsec ./data/crowdsec/data
sudo chmod 0750 ./data/crowdsec/config
```

**Explanation**: `./data/crowdsec/data` is the SQLite database and the downloaded hub content — it
must survive the container being recreated, or every image pull resets your ban history and
re-downloads the whole community blocklist. `./data/crowdsec/config` is `0750` rather than `0755`
because on the public host it also holds the Cloudflare bouncer's credentials; only the deploy
account and the Docker group have any business reading it.

---

#### Step 2: Write the log acquisition configuration

```bash
cd <deploy-dir>
tee ./data/crowdsec/config/acquis.yaml >/dev/null <<'EOF'
filenames:
  - /var/log/traefik/*.log
labels:
  type: traefik
---
filenames:
  - /var/log/authelia/authelia.log
labels:
  type: authelia
---
filenames:
  - /var/log/auth.log
  - /var/log/syslog
  - /var/log/kern.log
  - /var/log/ufw.log
  - /var/log/mail.log
labels:
  type: syslog
EOF
sudo chown <username>:<pgid> ./data/crowdsec/config/acquis.yaml
sudo chmod 0640 ./data/crowdsec/config/acquis.yaml
```

**Explanation**: Three documents in one file, separated by `---`, because each source needs a
different `type` label and the label is what selects the parser. `traefik` sends the proxy's JSON
access log through the HTTP parsers, which is where path scanning, CVE probing and brute-force
patterns are detected. `authelia` picks up failed-authentication events from the portal. `syslog`
covers SSH brute force in `auth.log`, firewall drops in `ufw.log`, and mail relay abuse — the
non-HTTP half of the attack surface, which the proxy log alone would never show. The proxy entry is
a glob so both the access log and the proxy's own error log are read; the others are named
individually because a glob over `/var/log` would pull in binary and rotated files.

---

#### Step 3: Create the host log files that will be mounted

```bash
sudo touch /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/ufw.log /var/log/mail.log
ls -l /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/ufw.log /var/log/mail.log
```

**Explanation**: This has to happen before the container is created. Docker creates a missing
bind-mount source as a **directory**, and a containerised guest very often has no `/var/log/kern.log`
and no `/var/log/mail.log` at all. Once Docker has turned one of those into a directory, CrowdSec
fails to read it, the host's log-shipping agent trips over it too, and the only fix is to stop
everything, remove the directory, touch the file and recreate the containers. Touching them first
costs nothing on hosts where they already exist.

---

#### Step 4: Start the agent

```bash
cd <deploy-dir>
docker run -d \
  --name crowdsec \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=<timezone> \
  -e GID=<pgid> \
  -e COLLECTIONS='crowdsecurity/traefik crowdsecurity/http-cve LePresidente/authelia crowdsecurity/wordpress' \
  -e USE_WAL=true \
  -v "$(pwd)/data/crowdsec/config/acquis.yaml:/etc/crowdsec/acquis.yaml:ro" \
  -v "$(pwd)/data/crowdsec/data:/var/lib/crowdsec/data" \
  -v "$(pwd)/data/traefik/logs:/var/log/traefik/:ro" \
  -v "$(pwd)/data/authelia/logs:/var/log/authelia/:ro" \
  -v /var/log/auth.log:/var/log/auth.log:ro \
  -v /var/log/syslog:/var/log/syslog:ro \
  -v /var/log/kern.log:/var/log/kern.log:ro \
  -v /var/log/ufw.log:/var/log/ufw.log:ro \
  -v /var/log/mail.log:/var/log/mail.log:ro \
  --health-cmd 'cscli lapi status' \
  --health-interval 1m30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 60s \
  --label 'traefik.enable=false' \
  crowdsecurity/crowdsec:latest

docker logs -f crowdsec | grep -iE 'local api|acquisition|error'
```

**Explanation**: Every log mount is read-only — the agent has no reason to write to any of them, and
a compromised detector that can rewrite the evidence is worse than none. `traefik.enable=false` keeps
the proxy from publishing it: the local decision API is an unauthenticated-by-design endpoint
protected only by being on an internal network, and exposing it would let anyone add or delete bans.
`USE_WAL=true` switches SQLite to write-ahead logging, which matters because the community blocklist
arrives as a bulk write of tens of thousands of rows; without it, readers block for the duration and
the proxy's decision pull times out every time the list refreshes. `GID` makes the agent run with
the same group that owns the mounted logs, so it can read files that are not world-readable. The
`COLLECTIONS` list bundles the parsers and scenarios for what this stack actually exposes — the
proxy's access log format, generic HTTP CVE probing, the single sign-on portal's failure events, and
WordPress probing (which every public site receives regardless of whether it runs WordPress). The
health check is the agent asking its own local API, which is what the bouncers depend on.

---

#### Step 5: Update and upgrade the scenario hub

```bash
docker exec crowdsec cscli hub update
docker exec crowdsec cscli hub upgrade
docker exec crowdsec cscli collections list
docker exec crowdsec cscli metrics
```

**Explanation**: `hub update` refreshes the index of what is available; `hub upgrade` pulls new
versions of the parsers and scenarios you already have. Detection rules are only as good as their
last update — a scenario written before a CVE existed cannot match probes for it. Run both after
every image pull, since a new image ships a hub snapshot that is already older than what is
published. `cscli metrics` is the one command that tells you whether acquisition is working: it
shows lines read per source, and a source sitting at zero means the file is empty, the path is
wrong, or the mount became a directory.

---

#### Step 6: Register the Traefik bouncer's key

```bash
docker exec crowdsec cscli bouncers list -o json | jq -r '.[].name'

docker exec crowdsec cscli bouncers add traefik-bouncer --key '<secret>'

docker exec crowdsec cscli bouncers list
```

If an old standalone bouncer container is still around from a previous arrangement, remove it:

```bash
docker rm -f bouncer-traefik 2>/dev/null || true
```

**Explanation**: You supply the key rather than letting CrowdSec generate one, because the same value
has to be written into the proxy's bouncer middleware, and having one side generate it means copying
a secret out of a command's output into a configuration file — an extra step that goes wrong.
Registering is a one-time act: the key is stored in the agent's database, so re-running `add` with a
name that already exists fails, which is why the listing comes first. There is no bouncer container
to run — the enforcement code is a plugin inside the reverse proxy process, and this step exists only
to tell the agent that the key the proxy will present is legitimate. An unrecognised key is answered
with 403, and because the plugin runs in streaming mode it simply keeps an empty decision list and
blocks nothing, all while reporting itself as enabled. Nothing about the proxy looks broken in that
state, which is why Step 8 exists.

---

#### Step 7: Public-facing host only — the Cloudflare bouncer

Skip this entirely on an internal host.

```bash
cd <deploy-dir>
docker exec crowdsec cscli bouncers add cloudflare-bouncer --key '<secret>'

tee ./data/crowdsec/cfg.yaml >/dev/null <<'EOF'
crowdsec_lapi_url: http://crowdsec:8080/
crowdsec_lapi_key: <secret>
crowdsec_insecure_skip_verify: false
crowdsec_update_frequency: 60s
include_scenarios_containing: []
exclude_scenarios_containing: []
only_include_decisions_from: ["cscli", "crowdsec"]
cloudflare_config:
    accounts:
        - id: <cloudflare-account-id>
          zones:
            - zone_id: <cloudflare-zone-id>
              actions:
                - managed_challenge
            - zone_id: <cloudflare-zone-id>
              actions:
                - managed_challenge
            - zone_id: <cloudflare-zone-id>
              actions:
                - managed_challenge
          token: <secret>
          ip_list_prefix: crowdsec
          default_action: managed_challenge
          total_ip_list_capacity: 9000
    update_frequency: 60s
daemon: false
log_level: info
log_mode: stdout
log_dir: /var/log/
prometheus:
    enabled: true
    listen_addr: 127.0.0.1
    listen_port: "2112"
key_path: ""
cert_path: ""
ca_cert_path: ""
EOF
sudo chown <username>:<pgid> ./data/crowdsec/cfg.yaml
sudo chmod 0640 ./data/crowdsec/cfg.yaml

docker run -d \
  --name cloudflare-bouncer \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -v "$(pwd)/data/crowdsec/cfg.yaml:/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml" \
  --health-cmd 'pgrep -f crowdsec-cloudflare-bouncer' \
  --health-interval 60s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 15s \
  crowdsecurity/cloudflare-bouncer

docker logs -f cloudflare-bouncer
```

**Explanation**: `only_include_decisions_from: ["cscli", "crowdsec"]` is the setting that makes this
workable. Cloudflare's IP lists cap at roughly ten thousand entries outside an Enterprise plan, and
the community blocklist alone is nearly three times that — pushing everything would overflow the list
and rate-limit the API for no benefit, because the full blocklist is already enforced locally by the
in-proxy plugin, which has no size cap. So only *local* decisions go to the edge: addresses your own
scenarios banned and addresses you banned by hand, a small high-value set. Both update frequencies
are 60 seconds and must match each other; an earlier 10-second setting hammered the Cloudflare API
into `10040 "you have been ratelimited"`, and local bans gain nothing from being pushed to the edge
six times faster. `managed_challenge` rather than a hard block means a false positive gets a
challenge page instead of a closed door. The health check greps for the process because this bouncer
serves no HTTP endpoint at all — liveness here means the process has not died inside a container
that stayed up, and the image is Alpine-based so `pgrep` is present. One caution when you edit this
file: it is bind-mounted, and the bouncer reads it only at start, so changing its contents does
nothing until the container is **recreated** — a restart of the running container keeps the stale
in-memory configuration. Remove and recreate:

```bash
docker rm -f cloudflare-bouncer
# re-run the docker run command above
```

---

#### Step 8: Prove the proxy is actually pulling decisions

```bash
docker exec crowdsec cscli lapi status

docker exec crowdsec cscli bouncers list -o json \
  | jq -r '.[] | select(.name | startswith("traefik-bouncer")) | "\(.name)  \(.last_pull)  revoked=\(.revoked)"'
```

At least one row must exist and its `last_pull` must be within the last couple of minutes.

**Explanation**: The local API reporting itself healthy says nothing about whether the proxy can
reach it. If the proxy presents a key the agent does not know, the agent answers 403; the plugin,
running in streaming mode, simply keeps an empty decision list, blocks nothing, and still reports
itself enabled. A recent pull is the only evidence that the two are genuinely talking. Match on the
**prefix** and judge on the newest pull across every matching row, never on one exact name: the agent
automatically creates a `traefik-bouncer@<address>` entry per source address it sees, so the bare
`traefik-bouncer` row goes stale the moment the proxy container's address changes, while a differently
suffixed row is the one actually pulling. Ignore rows marked revoked. If nothing has ever pulled, the
key the proxy is using is not one the agent knows — go back to Step 6 and make the two values agree.

## How enforcement actually works

```
request → Traefik → [ chain: cloudflarewarp → geoblock → allow-list → crowdsec-bouncer → headers → rate-limit → auth ] → service
                                                             ↑
                                          in-process plugin, pulls decisions every 60s
                                                             ↓
                                                    CrowdSec agent (LAPI, :8080)
                                                     ↑                     ↓
                                            reads mounted logs      pushes local bans
                                                                           ↓
                                                            Cloudflare bouncer → CDN edge
```

Three things follow from this shape:

- **There is no bouncer container for the proxy.** If you are looking for one, you will not find it.
  The enforcement code is a plugin declared in the proxy's static configuration and configured by a
  middleware file in the proxy's rules directory.
- **The middleware must be in every chain** to protect everything. A route whose chain omits it is
  not protected, no matter how many decisions the agent holds.
- **Decisions are pulled, not pushed.** A ban takes up to 60 seconds to take effect at the proxy, and
  up to another 60 to reach the CDN edge on the public host.

Useful day-one commands:

```bash
# what is currently banned
docker exec crowdsec cscli decisions list

# ban and unban by hand
docker exec crowdsec cscli decisions add --ip <ip-address> --duration 4h --reason 'manual'
docker exec crowdsec cscli decisions delete --ip <ip-address>

# what fired, and how often
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli alerts inspect <alert-id> -d
```

## Path layout

| Path | Contents |
| --- | --- |
| `./data/crowdsec/config/acquis.yaml` | Which logs to read and how to label them; mounted read-only |
| `./data/crowdsec/data/` | SQLite database, downloaded hub content, community blocklist — the state you must not lose |
| `./data/crowdsec/cfg.yaml` | Cloudflare bouncer credentials and zone list; public host only, `0640` |
| `./data/traefik/logs/` | Read-only input: the proxy's access and error logs |
| `./data/authelia/logs/` | Read-only input: authentication failures |
| `/var/log/{auth,syslog,kern,ufw,mail}.log` | Read-only input: the host's own logs |

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–7 |
| `<username>` / `<pgid>` | Owner and group of the data directory | The deploy account and the `docker` group; the group is also passed to the agent so it can read the mounted logs | Steps 1, 4 |
| `<docker-ip>` | Fixed address on the shared network | An address in the shared subnet outside the auto-allocation pool; a different one for each of the two containers | Steps 4, 7 |
| `<timezone>` | IANA timezone name | The host's, so ban windows and alert timestamps read correctly | Step 4 |
| `<secret>` (Traefik bouncer key) | Shared secret between agent and proxy plugin | `openssl rand -hex 32`; the identical value must appear in the proxy's bouncer middleware | Steps 6, and the proxy's configuration |
| `<secret>` (Cloudflare bouncer key) | Shared secret between agent and the Cloudflare bouncer | A second, different `openssl rand -hex 32` | Step 7 |
| `<secret>` (Cloudflare API token) | Token allowed to manage IP lists and firewall rules | Create it in the Cloudflare dashboard with account-level filter-list and zone firewall permissions | Step 7 |
| `<cloudflare-account-id>` | Your Cloudflare account identifier | Visible in the dashboard URL | Step 7 |
| `<cloudflare-zone-id>` | One per zone you want protected at the edge | Zone overview page; list only the zones this host serves | Step 7 |
| `<ip-address>` | A source address you are banning or unbanning by hand | — | "How enforcement actually works" |

## Verification

```bash
# the agent is up and its local API answers
docker inspect crowdsec | jq -r '.[0].State.Health.Status'
docker exec crowdsec cscli lapi status

# acquisition is reading every source — no line should sit at zero
docker exec crowdsec cscli metrics

# the collections installed and parsed cleanly
docker exec crowdsec cscli collections list
docker exec crowdsec cscli parsers list | head -20
docker exec crowdsec cscli hub list | grep -i 'tainted\|error' || echo "hub clean"

# the community blocklist arrived
docker exec crowdsec cscli decisions list -a | wc -l

# the proxy is genuinely pulling — the single most important check
docker exec crowdsec cscli bouncers list -o json \
  | jq -r '.[] | select(.name | startswith("traefik-bouncer")) | "\(.name)  \(.last_pull)"'

# the middleware exists where the proxy watches for it, and names the same key
ls -l ./data/traefik/rules/crowdsec-bouncer.yml
grep -c crowdsecLapiKey ./data/traefik/rules/crowdsec-bouncer.yml

# a ban actually takes effect (allow up to 60s for the pull)
docker exec crowdsec cscli decisions add --ip <ip-address> --duration 2m --reason 'verification'
sleep 65
curl -sI https://<service>.your-domain.com    # expect 403 from that source
docker exec crowdsec cscli decisions delete --ip <ip-address>
```

Public-facing host only:

```bash
docker inspect cloudflare-bouncer | jq -r '.[0].State.Health.Status'
docker logs cloudflare-bouncer --tail 30 | grep -iE 'added|removed|error|ratelimit'
```

Then confirm in the Cloudflare dashboard that a list named with the `crowdsec` prefix exists and has
entries.

## Updating & day-to-day

**Pull a new image.** The database and hub content are on a bind mount, so nothing is lost.

```bash
cd <deploy-dir>
docker pull crowdsecurity/crowdsec:latest
docker stop crowdsec && docker rm crowdsec
# re-run the docker run command from Step 4
docker exec crowdsec cscli hub update && docker exec crowdsec cscli hub upgrade
```

Bouncer registrations live in the database and survive this. The proxy will re-pull within 60
seconds; confirm with the bouncer listing.

**Refresh detection rules** without touching the container — worth doing weekly:

```bash
docker exec crowdsec cscli hub update && docker exec crowdsec cscli hub upgrade
```

**Add a collection** for a new kind of service on this host:

```bash
docker exec crowdsec cscli collections install crowdsecurity/<name>
docker restart crowdsec
```

Add it to the `COLLECTIONS` environment variable too, or the next recreated container will not have
it.

**Whitelist an address permanently** rather than deleting its ban over and over. Deleting a decision
only removes the current one; the next matching request re-bans it. Put the address in the proxy
bouncer middleware's `clientTrustedIPs` so it is never enforced against, and add a parser whitelist
under the agent's configuration if you also want to stop the alerts.

**Watch what is happening.**

```bash
docker exec crowdsec cscli alerts list --since 24h
docker exec crowdsec cscli metrics
docker logs crowdsec --tail 50
```

**Where the logs are.** `docker logs crowdsec` for the agent, `docker logs cloudflare-bouncer` for
the edge pusher. The agent's inputs are the mounted files listed in the path layout above.

**Back up** `./data/crowdsec/data/` if you care about ban history and alert records; everything else
is reconstructible from the hub and this guide.

## Rollback / Uninstall

Stop enforcing first, then remove — in that order, so you are never in a state where the proxy is
pointing at a bouncer key that no longer exists:

```bash
# 1. take the bouncer middleware out of the proxy's chains, or the routes it guards
#    will keep pointing at an agent that is about to disappear
cd <deploy-dir>
<editor> ./data/traefik/rules/chain-auth.yml       # remove the "- crowdsec-bouncer" line
<editor> ./data/traefik/rules/chain-no-auth.yml
<editor> ./data/traefik/rules/chain-basic-auth.yml
<editor> ./data/traefik/rules/chain-tunnel.yml
# the proxy watches that directory and reloads within seconds

# 2. remove the containers
docker rm -f cloudflare-bouncer 2>/dev/null || true
docker rm -f crowdsec

# 3. remove the state
rm -rf ./data/crowdsec
```

On the public host, also delete the `crowdsec`-prefixed IP list and its firewall rule in the
Cloudflare dashboard — removing the container stops updates but leaves the last-pushed bans in place
at the edge indefinitely.

To keep the agent but stop enforcement, leave everything running and just remove the middleware from
the chains: detection and alerting continue, nothing is blocked.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `cscli bouncers list` shows the Traefik bouncer but `last_pull` is empty or hours old | The proxy is presenting a key the agent does not know, so it is answered 403 and — in streaming mode — quietly enforces an empty list. Compare the key in `./data/traefik/rules/crowdsec-bouncer.yml` with what was registered, re-register with `cscli bouncers add`, and restart the proxy. |
| A `traefik-bouncer` row looks stale but attacks are still being blocked | The agent creates a `traefik-bouncer@<address>` row per source address; the bare row went stale when the proxy container's address changed. Judge on the newest `last_pull` across every row whose name starts with `traefik-bouncer`, ignoring revoked ones. |
| `cscli metrics` shows a log source with zero lines read | The file is empty, the path is wrong, or Docker turned the missing mount source into a directory. `ls -l /var/log/kern.log` — if it is a directory, stop the container, remove it, `touch` the file, and recreate. |
| Nothing is ever detected even though the log is filling | The `type` label does not match a parser, or the log format changed. `docker exec crowdsec cscli explain --file /var/log/traefik/access.log --type traefik` replays real lines through the parsers and shows where they fall out. |
| Bans exist but requests still get through | The bouncer middleware is missing from the chain that route uses, or the route uses a chain you forgot to edit. Check every `chain-*.yml` in the proxy's rules directory. |
| Everything is slow, or decision pulls time out, right after a blocklist refresh | Write-ahead logging is off, so the bulk write blocks readers. Confirm `USE_WAL=true` is on the container and recreate it. |
| A legitimate address gets banned repeatedly | Deleting the decision is not enough — the scenario re-fires. Add the address to the proxy bouncer middleware's `clientTrustedIPs` so it is never enforced against, and add a parser whitelist if you also want the alerts to stop. |
| Cloudflare bouncer logs `10040 "you have been ratelimited"` | Update frequency too aggressive, or too many decisions being pushed. Both frequency settings must be `60s` and must match, and `only_include_decisions_from` must exclude community decisions. |
| Cloudflare bouncer keeps running the old settings after you edited its configuration | The file is bind-mounted and read only at start. `docker rm -f cloudflare-bouncer` and recreate — restarting the existing container is not enough. |
| Cloudflare list is full / entries stop being added | The list hit its capacity. Confirm `total_ip_list_capacity` and that community decisions are excluded; the community blocklist alone is several times the non-Enterprise limit and belongs on the in-proxy plugin, not at the edge. |
| Hub update fails | No outbound HTTPS from the container. `docker exec crowdsec wget -qO- https://hub.crowdsec.net \| head -3`, then check the host's outbound rules and the daemon's DNS settings. |
| Agent will not start, log mentions the acquisition file | A YAML error in `acquis.yaml` — most often a missing `---` between the three documents. `docker run --rm -v "$(pwd)/data/crowdsec/config/acquis.yaml:/a.yaml" mikefarah/yq -e '.' /a.yaml` or just re-paste the file from Step 2. |
| The database grows without bound | Old alerts. `docker exec crowdsec cscli alerts delete --until 720h` prunes anything older than 30 days. |
| Ban history disappeared after an image pull | The data directory was not mounted, so the SQLite database lived inside the container. Confirm the `./data/crowdsec/data` mount is present in the run command. |
