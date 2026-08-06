# Grafana

## What this is

Grafana OSS is the dashboarding and alerting front end of the homelab. It runs as a single Docker
container on the monitoring machine, listens on port `3000` inside the container, and is published
by the reverse proxy at `https://grafana.your-domain.com`.

It reads two data sources, both of them containers on the same machine and both reached by
container name over the shared `proxy` network:

- **Prometheus** at `http://prometheus:9090` — every metric every host pushes.
- **Loki** at `http://loki:3100` — every log line every host pushes.

Everything Grafana shows is put there from files on disk rather than clicked together in the UI:
data sources, the dashboard folder, the alert rules, the contact points and the notification
policy all live under `./data/grafana/provisioning` and are read at startup. Alerts fan out to a
Telegram chat and to a webhook on the automation machine.

Login is either the local admin account or single sign-on against Authelia over OpenID Connect —
Grafana keeps its own login page, so its route is **not** forward-authenticated by the proxy.

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

### The service's DNS name resolves to this host

```bash
dig +short grafana.your-domain.com
```

The name must resolve to this machine's address (directly on a LAN, or to the public address of the
host that fronts it). Traefik matches on the `Host()` rule, so a name that lands on the wrong
machine produces a 404 from the wrong proxy rather than an error you can read.

### Prometheus and Loki are running on this machine

Both are Grafana's data sources and both must answer on the `proxy` network before the provisioned
data sources are anything but red crosses in the UI.

```bash
docker ps --filter 'name=^prometheus$' --filter 'name=^loki$'
docker run --rm --network proxy curlimages/curl:latest -sf -o /dev/null -w 'prometheus %{http_code}\n' http://prometheus:9090/-/ready
docker run --rm --network proxy curlimages/curl:latest -sf -o /dev/null -w 'loki %{http_code}\n'       http://loki:3100/ready
```

Grafana starts happily without them — you simply get "No data" on every panel and every alert rule
in an error state, which is much harder to read than a failed check here.

### Authelia is running and has an OpenID Connect client for Grafana

Grafana's "Sign in with Authelia" button is an OpenID Connect flow against Authelia. Authelia must
be up, and it must already know a client whose identifier and secret are the ones you put into
Grafana's environment below, with `https://grafana.your-domain.com/login/generic_oauth` registered
as an allowed redirect URI. If the client is unknown, the button produces an
`invalid_client` error page instead of a login form.

```bash
docker ps --filter 'name=^authelia$'
curl -sf https://auth.your-domain.com/.well-known/openid-configuration | jq -r '.issuer, .authorization_endpoint, .token_endpoint'
```

The three endpoints printed here are exactly the three URLs Grafana is configured with. Local admin
login keeps working regardless, so a broken client does not lock you out.

---

## Setup

### Overview

1. Create the data and provisioning directories.
2. Write the data source definitions.
3. Write the dashboard provider and drop the dashboard JSON in.
4. Write the alert contact points.
5. Write the notification policy.
6. Write the alert rules.
7. Start the container.

---

#### Step 1: Create the directories

```bash
cd <deploy-dir>

sudo mkdir -p \
  ./data/grafana \
  ./data/grafana/lib \
  ./data/grafana/provisioning/datasources \
  ./data/grafana/provisioning/dashboards/json \
  ./data/grafana/provisioning/alerting

sudo chown -R <puid>:<pgid> ./data/grafana
sudo chmod -R 0755 ./data/grafana
```

**Explanation**: The container is started with an explicit `--user <puid>:<pgid>` instead of the
image's built-in `grafana` user, so that the SQLite database it writes into `/var/lib/grafana` is
owned by an account that exists on the host and can be backed up and edited without `sudo`. Because
the uid is forced from outside, the directory must already be owned by it — Grafana does not chown
anything at startup and dies with `failed to connect to database: unable to open database file` on a
root-owned directory. `./data/grafana` is bind-mounted read-write as the whole Grafana home
(database, plugins, PNG renders); `./data/grafana/provisioning` is mounted a second time read-only
so that a compromised Grafana cannot rewrite its own alert rules or data source credentials.

---

#### Step 2: Write the data source definitions

```bash
sudo tee ./data/grafana/provisioning/datasources/datasources.yaml >/dev/null <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      httpMethod: POST
      timeInterval: "15s"

  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki:3100
    editable: false
    jsonData:
      maxLines: 1000
EOF

sudo chown <puid>:<pgid> ./data/grafana/provisioning/datasources/datasources.yaml
sudo chmod 0644 ./data/grafana/provisioning/datasources/datasources.yaml
```

**Explanation**: The `uid` fields are fixed strings rather than the random ids Grafana would
generate, because every dashboard and every alert rule refers to its data source by uid. Pin them
and a dashboard exported on one machine imports unchanged on another; let Grafana generate them and
every panel comes back "Datasource `<random>` was not found". `access: proxy` means the browser
never talks to Prometheus or Loki directly — Grafana fetches on its behalf, which is why the URLs
are internal container names that resolve only on the `proxy` network. `editable: false` stops
someone from silently repointing a data source in the UI, where the change would survive until the
next restart and then vanish. `httpMethod: POST` lets long PromQL queries through that would exceed
a URL length limit as a GET, and `timeInterval: 15s` tells Grafana the scrape interval so
`$__rate_interval` computes a sane window.

---

#### Step 3: Write the dashboard provider and install the dashboards

```bash
sudo tee ./data/grafana/provisioning/dashboards/dashboards.yaml >/dev/null <<'EOF'
apiVersion: 1

providers:
  - name: homelab
    orgId: 1
    folder: Homelab
    folderUid: homelab
    type: file
    disableDeletion: false
    editable: true
    allowUiUpdates: true
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards/json
      foldersFromFilesStructure: false
EOF

sudo chown <puid>:<pgid> ./data/grafana/provisioning/dashboards/dashboards.yaml
sudo chmod 0644 ./data/grafana/provisioning/dashboards/dashboards.yaml
```

Every dashboard is a single JSON file dropped into
`./data/grafana/provisioning/dashboards/json/`. Copy each file in, fix its data source references,
and fix the ownership:

```bash
sudo cp <dashboard>.json ./data/grafana/provisioning/dashboards/json/

# dashboards are written with symbolic datasource markers; substitute the real uids
sudo sed -i -e 's/__PROMETHEUS_UID__/prometheus/g' \
            -e 's/__LOKI_UID__/loki/g' \
            ./data/grafana/provisioning/dashboards/json/<dashboard>.json

sudo chown <puid>:<pgid> ./data/grafana/provisioning/dashboards/json/*.json
sudo chmod 0644 ./data/grafana/provisioning/dashboards/json/*.json
```

Deleting a JSON file removes the dashboard from Grafana within 30 seconds — there is no separate
delete step, and no leftover copy in the database:

```bash
sudo rm ./data/grafana/provisioning/dashboards/json/<dashboard>.json
```

**Explanation**: `updateIntervalSeconds: 30` makes Grafana rescan that directory twice a minute, so
a dashboard edit lands without restarting the container. `allowUiUpdates: true` combined with
`editable: true` lets you tweak a panel in the browser and hit save; the change lives in the
database until the next rescan, so treat the UI as a scratchpad and copy the JSON back to disk with
*Dashboard settings → JSON Model* when you are happy. `disableDeletion: false` is what makes the
`rm` above actually remove the dashboard rather than orphan it. `foldersFromFilesStructure: false`
puts everything in one *Homelab* folder regardless of subdirectories, which keeps the folder uid
stable — alert rules are filed by folder, and a folder that changes uid orphans them. The
`__PROMETHEUS_UID__` / `__LOKI_UID__` markers exist so the same JSON can be dropped onto an
installation whose data source uids differ; substitute them before the file is ever read, because
Grafana treats an unknown uid as a hard panel error rather than falling back to the default data
source.

The dashboards that belong here, and what each one reads, are listed under
*Provisioned dashboards* below.

---

#### Step 4: Write the alert contact points

```bash
sudo tee ./data/grafana/provisioning/alerting/contact-points.yaml >/dev/null <<'EOF'
apiVersion: 1

contactPoints:
  - orgId: 1
    name: Kestra
    receivers:
      - uid: kestra-webhook
        type: webhook
        disableResolveMessage: false
        settings:
          url: "https://kestra.your-domain.com/api/v1/main/executions/webhook/automation/grafana-alert-triage/<webhook-key>"
          httpMethod: POST

  - orgId: 1
    name: Telegram
    receivers:
      - uid: telegram-default
        type: telegram
        disableResolveMessage: false
        settings:
          bottoken: "<telegram-bot-token>"
          chatid: "<telegram-chat-id>"
          parse_mode: HTML
          message: |
            {{ if eq .Status "firing" }}🔴 <b>FIRING</b>{{ else }}🟢 <b>RESOLVED</b>{{ end }}
            {{ range .Alerts }}
            <b>{{ .Labels.alertname }}</b>
            {{- if .Annotations.summary }}
            {{ .Annotations.summary }}
            {{- end }}
            {{- if .Labels.severity }}
            severity: <code>{{ .Labels.severity }}</code>
            {{- end }}
            {{- if .Labels.category }}
            category: <code>{{ .Labels.category }}</code>
            {{- end }}
            {{- if .Labels.node }}
            node: <code>{{ .Labels.node }}</code>
            {{- end }}
            {{- if .Labels.service }}
            service: <code>{{ .Labels.service }}</code>
            {{- end }}
            {{- if .Annotations.description }}

            <i>{{ .Annotations.description }}</i>
            {{- end }}
            {{- if .GeneratorURL }}

            <a href="{{ .GeneratorURL }}">→ open in Grafana</a>
            {{- end }}
            {{ end }}
EOF

sudo chown <puid>:<pgid> ./data/grafana/provisioning/alerting/contact-points.yaml
sudo chmod 0644 ./data/grafana/provisioning/alerting/contact-points.yaml
```

Check the webhook before you trust it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  "https://kestra.your-domain.com/api/v1/main/executions/webhook/automation/grafana-alert-triage/<webhook-key>"
```

**Explanation**: The heredoc is quoted (`<<'EOF'`) so the shell leaves the `{{ … }}` alone — those
are Grafana's own alert-template directives, evaluated at notification time against the firing
alert, and a single unquoted heredoc would eat them all. The Telegram message is written by hand
rather than left at the default because the default dumps a wall of labels; this one leads with the
firing/resolved state, then the alert name, summary, the three labels that identify *where* the
problem is, and a link straight back to the panel. `disableResolveMessage: false` means you also get
the green "resolved" message, which is what lets you close an incident without going to look.

The Kestra receiver posts the same alert payload to a triage flow on the automation machine, where
an agent looks at the alert and writes a diagnosis back into the same Telegram chat as a follow-up
message. The last path segment of that URL is the flow's webhook trigger key and is the **only**
authentication on that endpoint — anyone who has the URL can start the flow, so treat the whole URL
as a secret and keep it out of anything world-readable. It must be character-for-character the key
the flow was created with; the `curl` above returns `200` when the key is accepted and `404` when it
is not, which is the difference between alerts being triaged and silently disappearing.

A `200` from that check also means you just started one triage execution — harmless, but expect the
Telegram follow-up.

---

#### Step 5: Write the notification policy

```bash
sudo tee ./data/grafana/provisioning/alerting/policies.yaml >/dev/null <<'EOF'
apiVersion: 1

policies:
  - orgId: 1
    receiver: Telegram
    group_by:
      - alertname
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: Telegram
        object_matchers:
          - ["severity", "=~", ".+"]
        continue: true
      - receiver: Kestra
        object_matchers:
          - ["severity", "=~", ".+"]
        repeat_interval: 24h
EOF

sudo chown <puid>:<pgid> ./data/grafana/provisioning/alerting/policies.yaml
sudo chmod 0644 ./data/grafana/provisioning/alerting/policies.yaml
```

**Explanation**: This is a deliberate fan-out. Every rule below carries a `severity` label, so both
child routes match everything; `continue: true` on the first one stops the policy tree from
short-circuiting after the Telegram match, and the alert goes on to the Kestra route as well. The
result is a raw alert in Telegram immediately, plus one triage run. The Kestra route overrides
`repeat_interval` to 24h rather than inheriting 4h, because a repeat means "still firing" and one
diagnosis per firing alert per day is plenty — re-running an agent every four hours on the same
alert costs money and tells you nothing new. The root receiver is Telegram so that Grafana's own
built-in alerts, which carry no `severity` label and match neither child route, still reach you.
`group_by: [alertname]` collapses the per-host copies of a rule into one message; `group_wait: 30s`
gives a host-down cascade half a minute to accumulate so you get one message rather than nine.

---

#### Step 6: Write the alert rules

Alert rules go in a single file. Each rule is a three-node chain — `A` runs the query, `B` reduces
the result series to one number each, `C` compares that number against a threshold — and `condition:
C` names the node that decides. Write the file header and the first group like this:

```bash
sudo tee ./data/grafana/provisioning/alerting/rules.yaml >/dev/null <<'EOF'
apiVersion: 1

deleteRules:
  - orgId: 1
    uid: hl-node-gap-<retired-host>
  - orgId: 1
    uid: hl-log-gap-<retired-host>

groups:
  - orgId: 1
    name: homelab-http-uptime
    folder: Homelab
    interval: 60s
    rules:

      - uid: hl-http-service-down
        title: HTTP Service Down
        condition: C
        noDataState: OK
        execErrState: Error
        for: "3m"
        isPaused: false
        annotations:
          summary: "{{ $labels.service }} on {{ $labels.host }} is DOWN ({{ $labels.via }})"
          description: "Blackbox probe_success=0 for service {{ $labels.service }} (host={{ $labels.host }}, via={{ $labels.via }})."
        labels:
          severity: critical
          category: http-uptime
        data:
          - refId: A
            datasourceUid: prometheus
            relativeTimeRange: { from: 300, to: 0 }
            model:
              refId: A
              datasource: { type: prometheus, uid: prometheus }
              expr: min by (service, host, via) (probe_success)
              instant: true
              range: false
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: B
            datasourceUid: __expr__
            relativeTimeRange: { from: 0, to: 0 }
            model:
              refId: B
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              reducer: last
              expression: A
          - refId: C
            datasourceUid: __expr__
            relativeTimeRange: { from: 0, to: 0 }
            model:
              refId: C
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: lt, params: [1] }
                  operator: { type: and }
                  query: { params: [] }
                  reducer: { type: last, params: [] }
                  type: query

      - uid: hl-node-gap-<host>
        title: "Node metrics gap (<host>)"
        condition: C
        noDataState: Alerting
        execErrState: Error
        for: "5m"
        isPaused: false
        annotations:
          summary: "Node <host> has no metrics"
          description: "No node_exporter samples in last 5m from host <host>. Host or agent likely down."
        labels:
          severity: critical
          category: node-health
          node: "<host>"
        data:
          - refId: A
            datasourceUid: prometheus
            relativeTimeRange: { from: 600, to: 0 }
            model:
              refId: A
              datasource: { type: prometheus, uid: prometheus }
              expr: count_over_time(node_time_seconds{host="<host>"}[5m])
              instant: true
              range: false
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: B
            datasourceUid: __expr__
            relativeTimeRange: { from: 0, to: 0 }
            model:
              refId: B
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              reducer: last
              expression: A
          - refId: C
            datasourceUid: __expr__
            relativeTimeRange: { from: 0, to: 0 }
            model:
              refId: C
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: lt, params: [1] }
                  operator: { type: and }
                  query: { params: [] }
                  reducer: { type: last, params: [] }
                  type: query
EOF

sudo chown <puid>:<pgid> ./data/grafana/provisioning/alerting/rules.yaml
sudo chmod 0644 ./data/grafana/provisioning/alerting/rules.yaml
```

Every other rule is that same block with four things changed: `uid`, `title`, the PromQL or LogQL in
`expr`, and the `evaluator` (`lt`/`gt` plus the threshold). The full set — all eleven groups and
their queries — is listed under *Provisioned alerting* below; append each group to the `groups:`
list in the same file.

**Explanation**: The three-node shape is not decoration. A Grafana alert query must return one
number per series, so `A` is run as an **instant** query (`instant: true`, `range: false`) that
returns the current value of each series, `B` reduces it with `last` so a range query pasted in by
mistake still collapses to a scalar, and `C` is the only node that produces the firing/not-firing
verdict. `relativeTimeRange.from` on `A` must be at least as long as the window inside the query —
a `[10m]` rate with a 300-second lookback silently returns nothing.

`for:` is the sustain time: the condition must hold continuously for that long before the alert
fires, which is what stops a single failed scrape from waking you up. `noDataState` is the
interesting one — most rules set it to `OK`, because "no data" for a CPU rule just means the series
does not exist and firing on it would be noise. The dead-man's-switch rules invert that and set
`noDataState: Alerting`: for a "node metrics gap" or a "log ingest gap" rule, no data is exactly the
failure being detected, so silence must be treated as an alarm. `execErrState: Error` puts the rule
itself into an error state if the query cannot run, rather than hiding a broken rule as healthy.

`deleteRules` at the top of the file exists because file provisioning only ever creates and updates.
Delete a rule from this file and Grafana keeps the copy it already stored, forever — a rule for a
machine you decommissioned goes on firing with nobody able to find where it is defined. Listing its
uid under `deleteRules` is the only way to remove it. Any per-host rule you drop (because the host is
gone, or because it has no traffic and its query returns empty frames) must have its uid moved here
in the same edit.

The `uid` of each rule is fixed by hand for the same reason: it is the identity Grafana keys on, so a
rule can be renamed or rewritten without producing a duplicate.

---

#### Step 7: Start the container

```bash
docker run -d \
  --name grafana \
  --restart always \
  --network proxy \
  --ip <docker-ip> \
  --user "<puid>:<pgid>" \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -e GF_LOG_FILTERS='expr:error,tsdb.loki:error' \
  -e GF_SERVER_ROOT_URL=https://grafana.your-domain.com \
  -e GF_SECURITY_ADMIN_USER='<admin-user>' \
  -e GF_SECURITY_ADMIN_PASSWORD='<secret>' \
  -e GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
  -e GF_AUTH_GENERIC_OAUTH_ENABLED=true \
  -e GF_AUTH_GENERIC_OAUTH_NAME=Authelia \
  -e GF_AUTH_GENERIC_OAUTH_ICON=signin \
  -e GF_AUTH_GENERIC_OAUTH_CLIENT_ID='<oidc-client-id>' \
  -e GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET='<oidc-client-secret>' \
  -e GF_AUTH_GENERIC_OAUTH_SCOPES='openid profile email groups' \
  -e GF_AUTH_GENERIC_OAUTH_EMPTY_SCOPES=false \
  -e GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.your-domain.com/api/oidc/authorization \
  -e GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://auth.your-domain.com/api/oidc/token \
  -e GF_AUTH_GENERIC_OAUTH_API_URL=https://auth.your-domain.com/api/oidc/userinfo \
  -e GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=preferred_username \
  -e GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH=groups \
  -e GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH=name \
  -e GF_AUTH_GENERIC_OAUTH_USE_PKCE=true \
  -e GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'admins') && 'Admin' || 'Viewer'" \
  -e GF_AUTH_GENERIC_OAUTH_AUTH_STYLE=InHeader \
  -v "$(pwd)/data/grafana:/var/lib/grafana" \
  -v "$(pwd)/data/grafana/provisioning:/etc/grafana/provisioning:ro" \
  --health-cmd 'wget --spider -q http://localhost:3000/api/health' \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --label traefik.enable=true \
  --label 'traefik.http.routers.grafana.entrypoints=https' \
  --label 'traefik.http.routers.grafana.rule=Host(`grafana.your-domain.com`)' \
  --label 'traefik.http.routers.grafana.tls=true' \
  --label 'traefik.http.routers.grafana.middlewares=chain-no-auth@file' \
  --label 'traefik.http.services.grafana.loadbalancer.server.port=3000' \
  grafana/grafana-oss:latest
```

**Explanation**: `GF_SERVER_ROOT_URL` must be the exact public URL, because it is what Grafana pastes
into alert notifications, share links and the OpenID Connect redirect it hands Authelia. Get it
wrong and every "open in Grafana" link in Telegram points at `localhost:3000`.

The router carries `chain-no-auth@file`, not the authenticating chain: Grafana has its own login
page and its own session, and putting a forward-auth in front of it breaks the OpenID Connect
callback (the callback is an unauthenticated request by definition, so it would be bounced back to
the login page in a loop). The chain still runs the intrusion-detection bouncer, so the route is not
unprotected — it is just not double-authenticated.

The OpenID Connect block maps Authelia's groups onto Grafana's permissions: anyone in the `admins`
group becomes a Grafana Admin, everyone else a Viewer, evaluated on every login, so revoking someone
in Authelia downgrades them here without any action in Grafana. `USE_PKCE=true` and
`AUTH_STYLE=InHeader` are what Authelia expects — with the client secret in the Authorization header
rather than the POST body, it never lands in a proxy access log.

`GF_LOG_FILTERS` raises the level of two specific loggers. Grafana's expression engine logs a
warning — "Ignoring data frame due to missing numeric fields" — on **every** evaluation of **every**
rule whose query returned an empty frame, which is the normal state for a service with no 5xx errors
or no recent requests. The rule still evaluates its numeric frames correctly, so the warning is
benign, but at one line per rule per minute it buries everything else in the log. Setting
`expr:error` keeps that logger's errors and drops its warnings. `tsdb.loki:error` does the same for
the per-query "Response received from loki" info lines. Set the variable to an empty string to get
full verbosity back while debugging.

Finally: Grafana reads the provisioning directory **only at startup**. Data sources, contact points,
policies and alert rules do not hot-reload — after editing any file under
`./data/grafana/provisioning` you must restart the container. Dashboards are the exception; the file
provider rescans them on its own.

---

## Provisioned dashboards

Each file in `./data/grafana/provisioning/dashboards/json/` becomes one dashboard in the *Homelab*
folder. The dashboard uid is fixed inside the JSON so links stay stable.

| File | Dashboard uid | Reads |
|------|---------------|-------|
| `node-overview.json` | `homelab-node-overview` | Prometheus — `node_*` host metrics, `container_*` from cadvisor, `docker_*` from the host-side container-state script; variables `$host`, `$container` |
| `http-uptime.json` | `homelab-http-uptime` | Prometheus — blackbox `probe_*`; one repeated row per `$host`, `$via` selects internal vs public probe |
| `traefik.json` | `homelab-traefik` | Prometheus — `traefik_*` from the proxy's metrics port, plus Loki for the log panels; variables `$host`, `$sampling`, `$service` |
| `postgres.json` | `homelab-postgres` | Prometheus — `pg_stat_database_*` from the PostgreSQL exporter; variables `$host`, `$db` |
| `pfsense.json` | `homelab-pfsense` | Prometheus — FreeBSD `node_*` scraped from the firewall |
| `proxmox.json` | `homelab-proxmox` | Prometheus — `pve_*`; guest name and node joined from `pve_guest_info`, restricted to running guests with `and on (id) (pve_up == 1)` |
| `loki-overview.json` | `homelab-loki-overview` | Loki; variables `$node`, `$container`, `$logstream`, `$level_regex` |
| `syslog.json` | `homelab-syslog` | Loki — syslog pushed by the firewall and the access point; variables `$device`, `$severity`, `$app`, `$search` |
| `crowdsec.json` | `homelab-crowdsec` | Prometheus — intrusion-detection engine metrics; variable `$host` |
| `homeassistant.json` | `homelab-homeassistant` | Prometheus — `hass_*` entity metrics; variable `$host` |
| `kestra.json` | `homelab-kestra` | Prometheus — `kestra_*` micrometer metrics from the automation machine, plus Loki for the log/level panels; variables `$namespace`, `$flow`, `$level`, `$search` |

Several panels differ from the upstream dashboards they started as, because no exporter here
produces the metric they wanted. Rather than leave a blank panel they were dropped or repurposed:

- **pfSense** — `PF Information` removed, and `Process Information` / `Active Users` replaced by
  `System Information` / `CPU Cores`: the FreeBSD node exporter publishes no packet-filter counters,
  no process states and no logged-in users.
- **Proxmox** — `Swap Total`, `Load Avg (1m)` and `I/O Wait` removed; the Proxmox exporter reports
  none of them (they would need a node exporter installed on the hypervisor itself). `LXC I/O Read` /
  `LXC I/O Write` were removed too and replaced by `LXC rootfs usage`
  (`pve_disk_usage_bytes / pve_disk_size_bytes`): Proxmox does not account container disk I/O, so the
  read/written counters sit at a few kilobytes for a container's entire lifetime and `rate()` is
  permanently zero. `Not backed up` and `Guests without backup` were added from
  `pve_not_backed_up_total` / `pve_not_backed_up_info`. Guest panels join
  `and on (id) (pve_up == 1)` so stopped guests do not draw flat-zero series while the
  running-count stats disagree; those stats count `pve_up == 1` directly and end in `or vector(0)`
  so an all-stopped node shows `0` instead of "No data".
- **Node overview** — the `Unhealthy` stat became `OOM-killed` (`docker_container_oom_killed`),
  because cadvisor exposes no healthcheck state. `Stopped Containers` lists exited and OOM-killed
  names only; exit code and restart count are not exported.
- **Kestra** — the duration panels show an **average** (`rate(_sum) / rate(_count)`), not a p95.
  Kestra's `*_duration_seconds` are plain timers exported as `_count` / `_sum` / `_max` with no
  histogram buckets, so `histogram_quantile()` returns an empty frame and Grafana logs "missing
  numeric fields" on every refresh. The `$namespace` / `$flow` / `$level` variables use
  `allValue: ".*"` rather than `".+"` so that a series which does not carry the label still matches
  when the variable is set to *All*.

---

## Provisioned alerting

Eleven groups, all filed in the *Homelab* folder, all evaluated every 60 seconds except the
certificate group, which is evaluated every 300 seconds. Every rule carries `severity` (`warning` or
`critical`) and `category` labels; the notification policy routes on `severity`.

| Group | Rule (uid) | Query | Fires when |
|-------|-----------|-------|-----------|
| `homelab-http-uptime` | `hl-http-service-down` | `min by (service, host, via) (probe_success)` | `< 1` for 3m |
| | `hl-http-slow-warn` | `max by (service, host) (avg_over_time(probe_duration_seconds{via="internal"}[5m]))` | `> 1.0` s for 5m |
| | `hl-http-slow-crit` | same query | `> 3.0` s for 5m |
| | `hl-node-gap-<host>` | `count_over_time(node_time_seconds{host="<host>"}[5m])` | `< 1` for 5m, **no data = firing** |
| `homelab-system` | `hl-system-high-cpu` | `100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle", host!="pfsense"}[10m])) * 100)` | `> 90` % for 10m |
| | `hl-system-high-mem` | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` | `> 90` % for 10m |
| | `hl-system-disk-full` | `max by (host, mountpoint) ((1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)`, excluding `tmpfs\|devtmpfs\|overlay\|squashfs\|aufs` | `> 90` % for 5m |
| `homelab-proxmox` | `hl-proxmox-cpu-high` | `avg_over_time(pve_cpu_usage_ratio{id=~"node/.+"}[10m]) * 100` | `> 85` % for 10m |
| | `hl-proxmox-mem-high` | `pve_memory_usage_bytes{id=~"node/.+"} / pve_memory_size_bytes{id=~"node/.+"} * 100` | `> 85` % for 10m |
| `homelab-traefik` | `hl-traefik-5xx-<host>` | `sum by (service) (rate(traefik_service_requests_total{host="<host>", code=~"5.."}[5m]))` | `> 5` req/s for 5m |
| | `hl-traefik-p95-<host>` | `histogram_quantile(0.95, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket{host="<host>"}[5m])))` | `> 2.0` s for 5m |
| `homelab-pfsense` | `hl-pfsense-cpu-high` | `100 - (avg (rate(node_cpu_seconds_total{host="pfsense", mode="idle"}[10m])) * 100)` | `> 80` % for 10m |
| | `hl-pfsense-mem-high` | `(node_memory_active_bytes + node_memory_wired_bytes) / node_memory_size_bytes * 100` | `> 85` % for 10m |
| | `hl-pfsense-wan-down` | `sum(rate(node_network_receive_bytes_total{host="pfsense", device="<wan-interface>"}[5m]))` | `< 1` for 5m, **no data = firing** |
| `homelab-postgres` | `hl-pg-gap` | `max(pg_up{host="postgres"})` | `< 1` for 3m, **no data = firing** |
| | `hl-pg-connections` | `sum(pg_stat_database_numbackends{host="postgres"})` | `> 80` backends for 5m (server default limit is 100) |
| | `hl-pg-deadlocks` | `sum by (datname) (increase(pg_stat_database_deadlocks{host="postgres"}[10m]))` | `> 0` for 5m |
| `homelab-containers` | `hl-ct-exited` | `max by (container_name, host) (docker_container_exited)` | `> 0` for 2m |
| | `hl-ct-oom` | `max by (container_name, host) (max_over_time(docker_container_oom_killed[10m]))` | `> 0` immediately |
| `homelab-logs` | `hl-log-gap-<host>` | LogQL `sum(count_over_time({node="<host>"} [15m]))` | `< 1` for 5m, **no data = firing** |
| `homelab-homeassistant` | `hl-ha-down` | `max(up{job="homeassistant"})` | `< 1` for 5m, **no data = firing** |
| | `hl-ha-leak` | `max by (entity, friendly_name) (hass_binary_sensor_state{entity=~".*water.*\|.*leak.*\|.*smoke.*\|.*gas.*"})` | `> 0` immediately |
| | `hl-ha-battery-low` | `min by (entity, friendly_name) (hass_sensor_battery_percent{entity!~"<phones-regex>"})` | `< 25` % for 1h |
| | `hl-ha-sensor-offline` | `max by (entity, friendly_name) (hass_entity_available{entity=~".*_temperature\|.*_humidity"})` | `< 1` for 20m |
| `homelab-certs` | `hl-cert-expiry-warn` | `min by (service, host) (((probe_ssl_earliest_cert_expiry - time()) / 86400) and (probe_ssl_earliest_cert_expiry > 0))` | `< 21` days for 15m |
| | `hl-cert-expiry-crit` | same query | `< 7` days for 15m |
| `homelab-node-extra` | `hl-node-rebooted` | `max by (host) (changes(node_boot_time_seconds[15m]))` | `> 0` immediately |
| | `hl-fs-readonly` | `max by (host, mountpoint) (node_filesystem_readonly{fstype=~"ext.*\|xfs\|btrfs\|zfs"})` | `> 0` for 2m |
| | `hl-hwtemp-high` | `max by (host) (node_hwmon_temp_celsius)` | `> 85` °C for 10m |
| `homelab-security` | `hl-crowdsec-down` | `max by (host) (up{job="crowdsec"})` | `< 1` for 5m |
| `homelab-kestra` | `hl-kestra-down` | `max(up{job="kestra"})` | `< 1` for 5m, **no data = firing** |
| | `hl-kestra-failed` | `sum by (namespace_id, flow_id, state) (increase(kestra_executor_execution_end_count_total{state=~"FAILED\|KILLED"}[15m]))` | `> 0` for 5m |
| | `hl-kestra-worker-backlog` | `sum(kestra_worker_job_pending)` | `> 20` for 10m |
| | `hl-kestra-log-errors` | LogQL `sum(count_over_time({node="automation", container="kestra", level="ERROR"} [15m]))` | `> 10` for 10m |

Notes that are easy to get wrong:

- The `hl-node-gap-<host>` and `hl-log-gap-<host>` rules are written once per monitored machine, with
  the machine's name substituted into the uid, the title, the `node` label and the query. Only write
  them for machines that are actually pushing — a rule for a machine that has never sent a metric
  fires forever and trains you to ignore the channel. When you retire a machine, remove its two rules
  **and** add both uids to `deleteRules`.
- The Traefik 5xx and p95 rules are likewise per-machine. Leave them off a machine that serves almost
  no HTTP: the queries return empty frames, Grafana puts the rule into an error state and floods the
  log with "missing numeric fields".
- `hl-ct-exited` works because long-lived services run with a restart policy, so a container sitting
  in `exited` means somebody stopped it by hand or Docker gave up on it. Short-lived task containers
  are removed seconds after they exit, so their gauge goes stale and clears on its own rather than
  alerting.
- `hl-ha-leak` has no sustain time at all. A water, leak, smoke or gas sensor that trips is not a
  trend to confirm — it fires on the first sample.
- `hl-ha-battery-low` excludes phones by entity-name pattern; a phone at 20 % is not an incident.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` | Account that owns `./data` | The unprivileged login on this machine | Before you start |
| `<puid>` / `<pgid>` | Numeric uid/gid Grafana runs as | `id -u <username>` / `id -g <username>`; must own `./data/grafana` | Steps 1–7 |
| `<docker-ip>` | Fixed address on the `proxy` network | Any free address in the network's subnet, outside the automatic pool | Step 7 |
| `<local-dns-ip>` | DNS server the container uses | Your LAN resolver, so internal names resolve inside the container | Step 7 |
| `<admin-user>` / `<secret>` | Local Grafana admin account | Set at first start; changing them later requires the CLI, not this variable | Step 7 |
| `<oidc-client-id>` / `<oidc-client-secret>` | Single sign-on client credentials | Must match the client registered in Authelia exactly | Step 7 |
| `<telegram-bot-token>` | Telegram bot API token | From `@BotFather`; the bot must be in the target chat | Step 4 |
| `<telegram-chat-id>` | Telegram chat that receives alerts | Numeric id of the group or user | Step 4 |
| `<webhook-key>` | Trigger key of the alert-triage flow | Copy from the flow's webhook trigger; it is the only auth on that URL | Step 4 |
| `<host>` | Name of a monitored machine | The label every agent stamps on its metrics and logs | Step 6 |
| `<retired-host>` | A machine whose rules must be deleted | Only needed while cleaning up | Step 6 |
| `<wan-interface>` | Firewall's WAN network device | As the firewall's exporter names it | Provisioned alerting |
| `<dashboard>` | Base name of a dashboard JSON file | One of the files listed above | Step 3 |
| `your-domain.com` | Base domain | Your own domain | Throughout |

---

## Verification

```bash
docker ps --filter 'name=^grafana$'
docker inspect --format '{{.State.Health.Status}}' grafana

# the API answers and reports its version
curl -sf https://grafana.your-domain.com/api/health | jq .

# both data sources exist with the pinned uids
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/datasources \
  | jq -r '.[] | "\(.uid)\t\(.name)\t\(.url)"'

# and they actually answer
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/datasources/uid/prometheus/health | jq .
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/datasources/uid/loki/health | jq .

# dashboards landed in the Homelab folder
curl -sf -u '<admin-user>:<secret>' 'https://grafana.your-domain.com/api/search?type=dash-db' \
  | jq -r '.[] | "\(.uid)\t\(.title)"'

# alert rules were provisioned, grouped by folder
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/v1/provisioning/alert-rules \
  | jq -r '.[] | "\(.uid)\t\(.title)"' | sort

# contact points and the notification policy
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/v1/provisioning/contact-points | jq -r '.[].name'
curl -sf -u '<admin-user>:<secret>' https://grafana.your-domain.com/api/v1/provisioning/policies | jq .
```

Send a real test message to prove the Telegram side end to end:

```bash
curl -sf -u '<admin-user>:<secret>' -X POST \
  -H 'Content-Type: application/json' \
  https://grafana.your-domain.com/api/alertmanager/grafana/config/api/v1/receivers/test \
  -d '{"receivers":[{"name":"Telegram"}]}'
```

Then check the log is quiet — if `GF_LOG_FILTERS` is doing its job you should see startup lines and
little else:

```bash
docker logs grafana --tail 50
```

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull grafana/grafana-oss:latest
docker stop grafana && docker rm grafana
# re-run the docker run from Step 7
```

Nothing is lost: the database, dashboards, users and alert state all live in `./data/grafana`.

**After editing any provisioning file** — data sources, contact points, policies, rules — restart the
container, because those are read only at startup:

```bash
docker restart grafana
```

**After adding, editing or removing a dashboard JSON**, do nothing; the file provider picks it up
within 30 seconds.

**Logs:**

```bash
docker logs -f grafana
```

Grafana logs to stdout only; there is no log file inside the container to rotate.

**Back up** the whole `./data/grafana` directory, or at minimum
`./data/grafana/grafana.db`, which holds users, API tokens, alert state and any dashboard someone
saved in the UI but never copied back to disk.

**Rotating the admin password:** `GF_SECURITY_ADMIN_PASSWORD` only applies on the very first start,
when the account is created. Afterwards:

```bash
docker exec -it grafana grafana cli admin reset-admin-password '<secret>'
```

---

## Rollback / Uninstall

```bash
docker stop grafana && docker rm grafana
```

That leaves everything on disk, so re-running Step 7 brings the same installation back. To remove it
completely:

```bash
sudo rm -rf ./data/grafana
docker rmi grafana/grafana-oss:latest
```

Removing the directory destroys all dashboards, users, API tokens and alert history. Take a copy
first if there is any chance you want it back:

```bash
sudo tar czf ~/grafana-$(date +%F).tar.gz ./data/grafana
```

---

## Troubleshooting

**Container exits immediately, log says `failed to connect to database: unable to open database
file`**
`./data/grafana` is not owned by the uid the container runs as. Re-run the `chown` from Step 1 with
the same `<puid>:<pgid>` you pass to `--user`.

**Every panel says "Datasource `<something>` was not found"**
The dashboard JSON still contains `__PROMETHEUS_UID__` / `__LOKI_UID__`, or a uid from another
installation. Re-run the `sed` from Step 3 and wait 30 seconds.

**Panels are empty but the data source health check passes**
The data exists but not for the time range or the label you are filtering on. Open *Explore*, pick
the same data source, and run the bare metric name — if that is empty too, the exporter is not
pushing and the problem is upstream of Grafana.

**A data source health check fails with `dial tcp: lookup prometheus: no such host`**
Grafana is not on the `proxy` network, or the target container is not. Both must be:
`docker network inspect proxy | jq -r '.[0].Containers[].Name'`.

**Alert rules do not appear**
`rules.yaml` failed to parse and Grafana logged it once at startup: `docker logs grafana | grep -i
provisioning`. YAML indentation inside the `data:` blocks is the usual cause. Nothing partial is
applied — a single bad rule rejects the whole file.

**A rule you deleted keeps firing**
File provisioning never deletes. Add its uid to `deleteRules` at the top of `rules.yaml` and restart.

**Alerts fire but no Telegram message arrives**
Test the contact point from *Alerting → Contact points → Test*. A bot that has never been added to
the target chat, or a chat id with the wrong sign for a group, both fail silently from Grafana's
point of view. `docker logs grafana | grep -i telegram` shows the API response.

**The Telegram message arrives but the triage follow-up never does**
The webhook key is wrong. Run the `curl` from Step 4; `404` means the key does not match the flow's
trigger.

**"Sign in with Authelia" ends on `invalid_client` or `redirect_uri_mismatch`**
The client identifier, the secret, or the registered redirect URI in Authelia does not match what
Grafana sends. The redirect URI Grafana uses is
`https://grafana.your-domain.com/login/generic_oauth`, derived from `GF_SERVER_ROOT_URL` — a wrong
root URL breaks it even when the client is correct.

**Single sign-on works but everyone lands as Viewer**
Authelia is not returning a `groups` claim, or the group is not named `admins`. Check the token
Grafana received: `docker logs grafana | grep -i oauth`.

**Log floods with "Ignoring data frame due to missing numeric fields"**
`GF_LOG_FILTERS` is unset or does not contain `expr:error`. This is noise from alert rules whose
query returned an empty frame, not a failure — but if a specific rule is *always* empty, it is
probably a per-host rule for a machine with no such metric, and it should be deleted rather than
silenced.

**Link in an alert notification points at `localhost:3000`**
`GF_SERVER_ROOT_URL` is wrong or missing. It must be the full public HTTPS URL.

**A dashboard edit made in the browser disappeared**
The file provider overwrote it at the next rescan. Export the JSON from *Dashboard settings → JSON
Model* and write it to the file in `./data/grafana/provisioning/dashboards/json/` before it is
rescanned.
