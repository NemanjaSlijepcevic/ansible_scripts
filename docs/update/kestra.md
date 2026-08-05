# Role: kestra

## Purpose

Deploys [Kestra](https://kestra.io/) (open-source edition), a declarative workflow-orchestration platform, as a Docker container on the automation host. It replaces the earlier n8n deployment.

Unlike n8n, **no custom image is built**: Kestra's built-in Docker task runner speaks the Docker API natively, and the role points it at the filtered `socket-proxy:2375` endpoint (the `socket_proxy` role) via global plugin defaults — Kestra never sees `/var/run/docker.sock`. Flow tasks (Ansible runs, Claude Code sandbox runs, any script task) execute in **ephemeral containers** spawned through that proxy:

- The `ansible_runner` image is consumed by Kestra's `io.kestra.plugin.ansible.cli.AnsibleCLI` task as its `containerImage` (the plugin's default `cytopia/ansible` image lacks this repo's collections).
- The `claude_runner` image is launched via a plain Docker task runner task — Kestra's Anthropic plugin (`io.kestra.plugin.anthropic.ChatCompletion`) is API-key chat only and is *not* a replacement for agentic Claude Code runs.

Kestra sits behind Traefik with Authelia forward-auth protecting the UI; webhook trigger paths (`/api/v1/main/executions/webhook/…`) are bypassed both in Authelia and in Kestra's own basic auth (`open-urls`). Its repository/queue live in the shared PostgreSQL server, reached over mutual TLS via JDBC.

## Prerequisites

- `common`, `traefik`, `authelia` roles must have run on the automation host.
- `socket_proxy` role must have run — Kestra joins the `docker-api` network and expects a reachable `socket-proxy:2375` endpoint.
- `claude_runner` / `ansible_runner` roles must have run if flows reference those images — they build `claude-runner:latest` / `ansible-runner:latest` and the `sandbox` network task containers attach to.
- Central PostgreSQL server (`update/postgres.yml`) must have a `postgres_tls_clients` entry named `kestra`, which generates and distributes the client certificate/key to `./data/certs/{ca.crt,kestra.crt,kestra.key}` on the automation host.
- `update/postgres.yml`'s "Prepare PostgreSQL for Automation" play (the `prepare_postgres` role with `current_host: automation`) must have run — it creates the `kestra` database and database user.
- `openssl` on the automation host (used to convert the client key for JDBC).
- Variables: `kestra.*`, `kestra_db.*`, `postgres.ip`/`postgres.port`, `log_notification.chat_id`/`log_notification.telegram_bot`, `default.dns`, shared `user.*`.

## Manual Execution Guide

### Overview

1. Create the Kestra data/storage directories.
2. Render the `application.yml` configuration (Postgres backend, socket-proxy task runner defaults, basic auth, encryption key).
3. Convert the PostgreSQL client key to PKCS#8 DER (the JDBC driver cannot read PEM keys) and fix ownership.
4. Start the container on both the `proxy` network (static IP, Traefik-routed) and the `docker-api` network (to reach `socket-proxy`).

### Step-by-Step Instructions

#### Step 1: Create data directories

**Purpose**: Kestra's local storage backend (execution artifacts, namespace files) needs a directory owned by the in-container `kestra` user (uid `1000` — see `kestra.uid`).

**Commands**:
```bash
sudo mkdir -p ./data/kestra/storage
sudo chown -R 1000:docker ./data/kestra
sudo chmod 0755 ./data/kestra ./data/kestra/storage
```

**Explanation**: `./data/kestra/storage` maps to `/app/storage` inside the container. Workflow definitions, users, and execution state live in PostgreSQL, not here — this holds only internal storage objects (task outputs, namespace files).

---

#### Step 2: Render the configuration file

**Purpose**: Kestra takes a single YAML config file; the role templates it from `application.yml.j2` with the Postgres JDBC URL (mTLS), basic auth, encryption key, and Docker task runner defaults pointing at the socket proxy.

**Commands**:
```bash
sudo tee ./data/kestra/application.yml > /dev/null <<'EOF'
datasources:
  postgres:
    url: "jdbc:postgresql://<postgres-host>:5432/kestra?ssl=true&sslmode=verify-ca&sslrootcert=/app/certs/ca.crt&sslcert=/app/certs/kestra.crt&sslkey=/app/certs/kestra.key.pk8"
    driverClassName: org.postgresql.Driver
    username: <db-user>
    password: <secret>

kestra:
  repository:
    type: postgres
  queue:
    type: postgres
  storage:
    type: local
    local:
      base-path: /app/storage
  url: "https://kestra.your-domain.com/"
  encryption:
    secret-key: <secret>          # base64 of 32 random bytes: openssl rand -base64 32
  anonymous-usage-report:
    enabled: false
  server:
    basic-auth:
      username: admin@your-domain.com   # must be an email address
      password: <secret>
      open-urls:
        - "/api/v1/main/executions/webhook/"
  plugins:
    configurations:
      - type: io.kestra.plugin.scripts.runner.docker.Docker
        values:
          volume-enabled: true
    defaults:
      - type: io.kestra.plugin.scripts.runner.docker.Docker
        values:
          host: "tcp://socket-proxy:2375"
          fileHandlingStrategy: VOLUME
EOF
sudo chown 1000:docker ./data/kestra/application.yml
sudo chmod 0600 ./data/kestra/application.yml
```

**Explanation**:
- `plugins.defaults` makes **every** Docker task runner go through the filtered socket proxy — flows don't need to repeat `host:`.
- `fileHandlingStrategy: VOLUME` exchanges task files through named Docker volumes, so no shared host tmp-dir mount is needed even though the daemon behind the proxy is the host's.
- `volume-enabled: true` additionally lets flows declare explicit bind mounts; those paths are **host** paths (the proxy talks to the host daemon), e.g. `<deploy-dir>/data/claude-runner/workspace`. The key is **kebab-case**; `volumeEnabled` is accepted by the YAML parser but never read, and flows then run with every declared bind silently missing.
- `encryption.secret-key` encrypts `SECRET`-typed inputs/outputs at rest; changing it makes previously stored values unreadable.

---

#### Step 3: Convert the PostgreSQL client key for JDBC

**Purpose**: `update/postgres.yml` drops `./data/certs/kestra.{crt,key}` (PEM) on this host, but the PostgreSQL **JDBC** driver only reads private keys in PKCS#8 **DER** format.

**Commands**:
```bash
sudo openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
  -in ./data/certs/kestra.key -out ./data/certs/kestra.key.pk8
sudo chown 1000:docker ./data/certs/kestra.crt ./data/certs/kestra.key ./data/certs/kestra.key.pk8
sudo chmod 0600 ./data/certs/kestra.crt ./data/certs/kestra.key ./data/certs/kestra.key.pk8
```

**Explanation**: Re-run the conversion whenever the client cert is rotated by `update/postgres.yml` (the role does this automatically on every run — DER output is deterministic, so it is idempotent).

---

#### Step 4: Start the Kestra container

**Purpose**: Launch Kestra (`server standalone`) with its Postgres backend, Traefik routing, Authelia forward-auth, and both the `proxy` and `docker-api` networks.

**Commands**:
```bash
sudo docker run -d \
  --name kestra \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <local-dns-ip> \
  -e TZ=Europe/Belgrade \
  -e SECRET_TELEGRAM_BOT_TOKEN="$(echo -n '<secret>' | base64 -w0)" \
  -e SECRET_TELEGRAM_CHAT_ID="$(echo -n '<secret>' | base64 -w0)" \
  -v $(pwd)/data/kestra/application.yml:/etc/config/application.yaml:ro \
  -v $(pwd)/data/kestra/storage:/app/storage \
  -v $(pwd)/data/certs/ca.crt:/app/certs/ca.crt:ro \
  -v $(pwd)/data/certs/kestra.crt:/app/certs/kestra.crt:ro \
  -v $(pwd)/data/certs/kestra.key.pk8:/app/certs/kestra.key.pk8:ro \
  --label 'traefik.enable=true' \
  --label 'traefik.docker.network=proxy' \
  --label 'traefik.http.routers.kestra.entrypoints=https' \
  --label 'traefik.http.routers.kestra.rule=Host(`kestra.your-domain.com`)' \
  --label 'traefik.http.routers.kestra.tls=true' \
  --label 'traefik.http.routers.kestra.middlewares=chain-auth@file' \
  --label 'traefik.http.services.kestra.loadbalancer.server.port=8080' \
  kestra/kestra:latest server standalone --config /etc/config/application.yaml

sudo docker network connect docker-api kestra
```

**Note**: the `--config` flag is required — a bind-mounted config file is *not* auto-detected, and without it the server exits at startup with `Server configuration requires the 'kestra.repository.type' property`.

**Explanation**:
- Two networks: `proxy` (static IP, Traefik-routable) and `docker-api` (reaches `socket-proxy` and nothing else). `docker run --network` accepts one network at creation, hence the follow-up `docker network connect`.
- `SECRET_*` env vars are Kestra OSS's secrets backend: **base64-encoded** values readable in flows via `{{ secret('TELEGRAM_BOT_TOKEN') }}` — same Telegram bot as the `log_notification` role.
- The UI/API listen on `8080`; the Micronaut management endpoints listen on `8081` (unauthenticated, reachable only from inside the Docker network — *not* routed by Traefik). Alloy uses both: `/health` for its blackbox probe and `/prometheus` for the metrics scrape.
- No `--user` override and no docker socket mount: the container runs as the image's unprivileged `kestra` user, and all Docker access goes through the socket proxy configured in `application.yml`.

---

## Configuration Reference

### Default Variables

| Variable | Default Value | Description |
|----------|--------------|-------------|
| `kestra.domain` | `kestra.example.com` | Bare domain, used in Authelia's access-control rules |
| `kestra.host` | `` Host(`kestra.example.com`) `` | Traefik router rule |
| `kestra.url` | `https://kestra.example.com` | Base URL (webhook/link generation) |
| `kestra.port` | `8080` | Internal UI/API port |
| `ip.kestra` | `172.20.0.13` | Static IP on the `proxy` network (read from the host's `ip` dict, not from a `kestra.*` key) |
| `kestra.encryption_key` | `changeme` | Base64 of 32 random bytes; encrypts SECRET values at rest |
| `kestra.admin_user` | `admin@example.com` | Kestra basic-auth login (must be an email) |
| `kestra.admin_password` | `changeme` | Kestra basic-auth password |
| `kestra.uid` | `1000` | In-container `kestra` user; owns storage + Postgres client key |
| `kestra_db.user` | `kestra` | PostgreSQL user (provisioned by `prepare_postgres`) |
| `kestra_db.password` | `changeme` | PostgreSQL user password |
| `postgres.ip` | `192.0.2.10` | Central PostgreSQL server address |
| `postgres.port` | `5432` | PostgreSQL port |
| `log_notification.chat_id` | `changeme` | Telegram chat ID exposed to flows as a Kestra secret |
| `log_notification.telegram_bot` | `changeme` | Telegram bot token exposed to flows as a Kestra secret |
| `default.dns` | `192.0.2.1` | DNS server handed to the container |
| `user.name` / `user.group` | `deploy` / `docker` | Ownership for role-managed files not owned by the container uid |

### Templates & Configuration Files

| Template | Destination | Purpose |
|----------|-------------|---------|
| `application.yml.j2` | `./data/kestra/application.yml` (mode 0600, `kestra.uid`:docker) | Full Kestra config: Postgres JDBC mTLS, basic auth, encryption, socket-proxy task runner defaults |

## Flows are not in this repo

The role deploys the **platform** — container, config, secrets, sandbox images, the socket-proxy task-runner defaults. It deploys **no flow YAML**: there is no `templates/flows/`, no `/flows` bind mount, and no `flow namespace update` step. Flows are authored in the Kestra UI and live in the central Postgres `kestra` database.

That is a deliberate choice, not an omission. There is no render step, no delimiter juggling between Ansible's Jinja and Kestra's Pebble, and no deploy that can silently overwrite something edited in the UI.

Consequences to respect:

- **Backups cover flows.** Flow source, revisions, executions and users are rows in the `kestra` Postgres database, dumped by `update/backup.yml` along with every other database. Restoring that database restores every flow at its last revision.
- **Re-running `automation.yml` never touches a flow.** Editing in the UI is safe; nothing overwrites it on the next deploy.

### Webhook keys live in OpenBao, not in the flow

A Webhook trigger's `key` is the **only** authentication on its URL — the webhook path bypasses both Traefik/Authelia and Kestra's basic auth, so the key is effectively a password for whatever the flow does.

`key` **is a dynamic property**, so it never holds a literal:

```yaml
triggers:
  - id: github_webhook
    type: io.kestra.plugin.core.trigger.Webhook
    key: "{{ secret('WH_<NAMESPACE>_<FLOW_ID>') }}"
```

The chain: `kv/homelab/kestra/webhooks` holds one field per webhook flow, named `<namespace>_<flow_id>` → the role reads the whole path in `environment.yml` and hands each field to the container as `SECRET_WH_<NAME|upper>` (base64) → the flow reads it back with `secret()`. Adding a webhook flow means adding one KV field and re-running `automation.yml --tags kestra`; nothing in this repo lists the flows.

Verified behaviour, since the docs do not state it plainly: a flow whose key rendered to `abcdef` answers on `…/webhook/<ns>/<flow>/abcdef` (HTTP 200) and the unrendered literal 404s/500s. Non-dynamic properties are the ones the plugin docs explicitly label *Non-dynamic*; `key` carries no such label.

### Exporting flows by hand

To take a copy outside the database backup — one ZIP per namespace, written inside the container, then copied out:

```bash
# on the automation host
sudo docker exec kestra sh /app/kestra flow export \
  --namespace <namespace> \
  --server http://localhost:8080 \
  --user <admin-user>:<admin-password> \
  /tmp
sudo docker cp kestra:/tmp/flows.zip ./flows-<namespace>.zip
```

Two things that bite:

- The launcher is a self-executing JAR with a batch header — `docker exec kestra /app/kestra …` fails with `exec format error`. Always invoke it through a shell: **`sh /app/kestra`**.
- `--user` puts the admin password in the container's argv, visible to anything that can read `/proc` on the automation host. Acceptable only because reading it needs root there — and root on that host already holds every secret on it.

The export carries no credentials — webhook keys are `secret()` expressions and every other secret is fetched at runtime — but it does map every flow, trigger and target, so keep it out of the repo anyway.

### Live flows

Five namespaces, authored in the UI — `homestation` for the homelab itself, `shared` for cross-site subflows, and one per site/client (`<org-a>`, `<org-b>`, `<org-c>` below). Webhook URLs follow `https://<kestra-domain>/api/v1/main/executions/webhook/<namespace>/<flow-id>/<webhook-key>`.

| Namespace / flow | Trigger | What it does |
|---|---|---|
| `homestation.run_ansible` | — (subflow) | Clones this repo and runs one playbook in the `ansible-runner` sandbox. Inputs: `playbook`, `tags`, `limit`, `branch`, `extra_args`. The single copy of the clone + `AnsibleCLI` body every deploy flow used to duplicate |
| `homestation.clone_update_ansible_scripts` | Schedule (weekly) + Webhook | `site.yml` via `run_ansible` |
| `homestation.backup_dbs` | Schedule (weekly) | `backup.yml` via `run_ansible` |
| `homestation.update_public_ip_tracker` | Webhook (GitHub push) | `monitor.yml --tags public_ip_tracker` via `run_ansible` |
| `homestation.update_public_ip_whitelist_updater` | Webhook (GitHub push) | `server.yml --tags public_ip_whitelist_updater` via `run_ansible` |
| `<org-a>.update_bibliography` | Webhook (GitHub push) | `server.yml --tags bibliography` via `run_ansible` |
| `<org-a>.update_kaleidoscope` | Webhook (GitHub push) | `server.yml --tags kaleidoscope` via `run_ansible` |
| `shared.ghost_subscriber_email` | — (subflow) | On a Ghost "post published" payload, mails every subscribed member one message each over Gmail SMTP. Inputs: `body`, `site_url`, `ghost_kv_path`, `mail_site_name`, `sender_email`, `sender_name`, optional `brand_name` / `send_delay_seconds` |
| `<org-a>.ghost_cms_subscriber_email` | Webhook (Ghost) | Per-site values → `shared.ghost_subscriber_email` |
| `<org-b>.ghost_cms_subscriber_email` | Webhook (Ghost) | Per-site values → `shared.ghost_subscriber_email` |
| `homestation.telegram_claude_bridge` | Webhook (Telegram bot) | Relays a Telegram message to a Claude Code run in the `claude-runner` sandbox and answers in the chat |
| `homestation.weekly_rsync_data` | Schedule (weekly) | `rsync` between directories on a remote host over SSH (`ssh.Command`, key from OpenBao) |
| `<org-c>.zoho_desk_caller`, `<org-c>.zoho_ticket_ack` | Webhook (Zoho Desk) | Zoho Desk ticket automation |

**Subflow pattern.** The deploy and Ghost-mail flows are thin callers: a trigger plus one `io.kestra.plugin.core.flow.Subflow` task with `wait: true` and `transmitFailed: true`. The caller owns its webhook key (one URL per producer, so no shared key can fire every deploy) and its `finally:` Telegram notification (the message names the flow that actually ran, not the shared worker). The subflow owns the logic and has **no triggers at all**.

A subflow cannot read `trigger.body`, so a webhook caller forwards the payload as an input:

```yaml
tasks:
  - id: mail_subscribers
    type: io.kestra.plugin.core.flow.Subflow
    namespace: shared
    flowId: ghost_subscriber_email
    wait: true
    transmitFailed: true
    inputs:
      body: "{{ trigger.body | toJson }}"
      site_url: "https://your-domain.com"
      ghost_kv_path: "homelab/kestra/<site>"
      mail_site_name: "<ghost_sites entry name>"
      sender_email: "<address>"
      sender_name: "<display name>"
```

### Wiring a producer to a webhook flow

**GitHub** (deploy on push): repo → Settings → Webhooks → Add webhook. Payload URL `https://<kestra-domain>/api/v1/main/executions/webhook/<namespace>/<flow-id>/<webhook-key>`, content type `application/json`, just the push event. Needs the Kestra domain reachable **from GitHub**.

**Ghost** (mail subscribers on publish): Ghost admin → Settings → Integrations → Add custom integration → Add webhook, event **Post published**, same URL shape. Ghost POSTs `{ "post": { "current": {…}, "previous": {…} } }`; the flow mails only when `current.status == published` and `previous.status != published`, so an edit to an already-published post sends nothing.

Both need their site's Ghost Admin API key in OpenBao (see [KV paths the flows use](#kv-paths-the-flows-use)) — the flow mints a short-lived JWT from it and reads the member list over the Admin API. Gmail's sending limits apply (~500 recipients/day on a normal account).

To read a key back for rebuilding a URL, open the flow in the UI — the `key:` is in its source. Rotating one means editing the flow and re-registering the URL with the producer.

## Using the sandbox images from flows

**Ansible run** (uses the `ansible_runner` image — the repo's collections are baked in):

```yaml
tasks:
  - id: playbook
    type: io.kestra.plugin.ansible.cli.AnsibleCLI
    containerImage: ansible-runner:latest
    taskRunner:
      type: io.kestra.plugin.scripts.runner.docker.Docker
      networkMode: sandbox
      volumes:
        - <deploy-dir>/data/ansible-runner/workspace:/workspace
        - <deploy-dir>/data/ansible-runner/secrets/<key>.ppk:/root/.ssh/<key>.ppk:ro
        - <deploy-dir>/data/ansible-runner/secrets/pass.file:/secrets/pass.file:ro
    commands:
      - cd /workspace/ansible_scripts/update && ansible-playbook nas.yml --vault-password-file /secrets/pass.file
```

**Claude Code run** (uses the `claude_runner` image; OAuth persists in the home volume):

```yaml
tasks:
  - id: claude
    type: io.kestra.plugin.scripts.shell.Commands
    containerImage: claude-runner:latest
    taskRunner:
      type: io.kestra.plugin.scripts.runner.docker.Docker
      networkMode: sandbox
      memory:
        memory: 2g
      volumes:
        - <deploy-dir>/data/claude-runner/home:/home/node
        - <deploy-dir>/data/claude-runner/workspace:/workspace
    commands:
      - cd /workspace && claude -p "<task>" --output-format json --dangerously-skip-permissions
```

Volume sources are **host** paths — the socket proxy forwards to the host daemon. `host: tcp://socket-proxy:2375` and `fileHandlingStrategy: VOLUME` come from the global plugin defaults, so tasks don't repeat them.

## Monitoring (metrics & logs)

Kestra needs **no configuration** to expose metrics. It is a Micronaut application, and the stock `endpoints.all.port: 8081` / `enabled: true` puts a micrometer Prometheus endpoint at `/prometheus` on the management port — the role's `application.yml.j2` contains nothing about metrics, deliberately.

Two collectors pick it up, both from the `alloy` role on the same host:

| Signal | How | Where it lands |
|--------|-----|----------------|
| Metrics | `prometheus.scrape "kestra"` → `kestra:8081/prometheus`, `job="kestra"`, gated on `current_host == 'automation'` | remote-written to Prometheus on the monitor host |
| Liveness | blackbox probe of `http://kestra:8081/health` (`alloy.http_checks`) | `probe_success{service="kestra"}` |
| Logs | generic Docker discovery, plus a kestra-specific `stage.match` block in `loki.process "drop_noise"` | Loki, as `{node="automation", container="kestra"}` |

The log block exists because Kestra is a JVM/logback service: `stage.replace` strips the ANSI colour codes wrapping the level/thread/logger fields, `stage.multiline` joins stack-trace continuation lines into one entry, `stage.regex` + `stage.labels` promote the log level to a **`level`** label, and the 8KB `stage.drop` is scoped to `{container!="kestra"}` so joined traces are not discarded.

The line format is **time-only** — `HH:mm:ss.SSS`, no date — so the multiline `firstline` anchors on that, not on an ISO timestamp. A stripped line looks like:

```
22:55:09.961 INFO  scheduled-executor-thread-1 i.k.jdbc.runner.JdbcQueueCleaner Purged 0 records from queues
```

Level (`%5p`) and thread are space-padded, hence the `\s+` separators in the regex.

**Gotcha, learned the hard way:** Alloy's `stage.replace` substitutes **capture groups**, not the whole match. The ANSI regex must therefore be wrapped in a group — `"(\x1b\[[0-9;]*m)"`, not `"\x1b\[[0-9;]*m"`. A group-less regex is a silent no-op: the stage reports healthy, nothing is logged, the escapes stay in the line, and the level regex downstream then fails to match, so no `level` label ever appears.

Verify the parsing after a deploy:

```bash
# One entry per stack trace, and a level label present
sudo docker logs kestra --tail 20
# In Grafana Explore (Loki): {container="kestra"} | level="ERROR"
```

Metric families exported (`kestra_` prefix): `kestra_executor_*` (executions, task runs, durations), `kestra_worker_*` (running/pending/thread counts, queue wait), `kestra_scheduler_*` (loop + trigger evaluation), `kestra_queue_*` (poll size, produce/receive throughput), `kestra_jdbc_query_duration_seconds_*`, `kestra_indexer_*`, plus the standard `jvm_*`, `process_*` and `hikaricp_*` series. Metric tags are snake_case: `namespace_id`, `flow_id`, `state`, `task_type`, `tenant_id` on the execution/worker metrics; `queue_type` / `class_name` on the queue metrics; `trigger_type` on the scheduler ones.

Two traps when writing a query against these, both hit while building the dashboard:

- There is **no** `kestra_queue_message_lag_count` on this build, despite what the upstream metric reference implies — per-queue backlog is `kestra_queue_poll_size{queue_type=...}`.
- `kestra_scheduler_loop_count_total` counts scheduler *starts* over the process lifetime (it sits at `3`), so `rate()` of it is permanently 0. The per-tick counter is `kestra_scheduler_evaluation_loop_duration_seconds_count`.

Dump the live endpoint to confirm names against the running image before editing dashboards or alerts:

```bash
sudo docker run --rm --network proxy curlimages/curl -sf \
  http://kestra:8081/prometheus | grep -E '^kestra_' | sort -u
```

Visualised by the `Homelab — Kestra` dashboard (`grafana/files/kestra.json`, uid `homelab-kestra`) and alerted on by the `homelab-kestra` rule group (`hl-kestra-down`, `-failed`, `-worker-backlog`, `-log-errors`), whose thresholds live in the `alerts` dict of the grafana role's `defaults/main.yml`.

## Secrets in flows (OpenBao)

Flows hold no credentials. Kestra OSS has no Vault/OpenBao plugin — external secret managers are an EE feature — so secrets arrive by one of two routes, chosen by *where the value is consumed*:

| Route | Used when | Exposure |
|-------|-----------|----------|
| **Fetched from OpenBao inside the script** | the value is used by Python/shell task code | none — the secret stays in the task process |
| **`{{ secret('NAME') }}`** | the value is a *plugin property* (`TelegramSend.token`, `ssh.Command.privateKey`) | masked by Kestra in logs and UI |

The split exists because a plugin property only accepts an expression, and an expression must come from a preceding task whose **output Kestra persists** — the secret would land in the execution record and the UI. So plugin properties use the masked `secret()` backend instead.

### Runtime reads

Script tasks carry three env entries and a small helper:

```yaml
env:
  BAO_URL: "{{ envs.openbao_url }}"        # from ENV_OPENBAO_URL
  BAO_ROLE_ID: "{{ secret('OPENBAO_ROLE_ID') }}"
  BAO_SECRET_ID: "{{ secret('OPENBAO_SECRET_ID') }}"
script: |
  import os
  # ... helper _bao(path) : AppRole login -> GET kv/data/<path> -> dict
  api_key = _bao("homelab/kestra/<service>")["api_key"]
```

Only **`ENV_`**-prefixed container variables reach flows: the prefix is stripped and the remainder lowercased, so `ENV_OPENBAO_URL` is read as `{{ envs.openbao_url }}`. The prefix is `kestra.variables.env-vars-prefix` (default `ENV_`), left at its default here.

A `KESTRA_` prefix does **not** work — Micronaut consumes those as configuration overrides (`KESTRA_OPENBAO_URL` → config property `kestra.openbao.url`), so the variable never appears in `envs` and every flow reading it dies with `Unable to find 'openbao_url' used in the expression '{{ envs.openbao_url }}'`.

Access is the dedicated **`kestra` AppRole** with the **`kestra-read`** policy — read-only, and only on the paths in `openbao_setup_kestra_read_paths`. It deliberately does *not* get `ansible-read`, which can read the whole homelab tree including `vault_password`. Adding a secret to a flow means adding its path to that list and re-running `openbao_setup.yml`.

### KV paths the flows use

| Path | Keys | Source |
|------|------|--------|
| `kv/homelab/kestra/ghost_kgb` | `admin_api_key` | flow-only, written by hand |
| `kv/homelab/kestra/ghost_skup` | `admin_api_key` | flow-only, written by hand |
| `kv/homelab/kestra/amitylink_caller` | `api_key` | flow-only, written by hand |
| `kv/homelab/kestra/ssh_bridge` | `private_key`, optional `passphrase` | flow-only, written by hand |
| `kv/homelab/kestra/webhooks` | one field per webhook flow, named `<namespace>_<flow_id>` | written by hand; read at **deploy** time → `SECRET_WH_<NAME>` |
| `kv/homelab/primary_server/ghost_sites` | `value[]` → `mail_user`, `mail_pass` | mirrored from the inventory by [`openbao_load`](openbao_load.md) |

The Ghost SMTP credentials are read from the mirrored inventory entry and selected by site name, so they stay defined in exactly one place.

### One-time bootstrap

Write the flow-only secrets with an admin token (never on the command line):

```bash
read -rs BAO_TOKEN; export BAO_TOKEN

docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/ghost_kgb        admin_api_key=<key>
docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/ghost_skup       admin_api_key=<key>
docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/amitylink_caller api_key=<key>

# multi-line values come from a file rather than the shell
docker exec -i -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/ssh_bridge private_key=- < bridge_key.pem

unset BAO_TOKEN
```

The bridge bot token goes in too — it is read at *deploy* time, not runtime, but OpenBao is still its only home:

```bash
docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/telegram_bridge bot_token='<token>'
```

The webhook keys are one path holding every key — all fields in a single `put`, since `kv put` replaces the whole secret:

```bash
docker exec -e BAO_TOKEN openbao bao kv put kv/homelab/kestra/webhooks \
  homestation_update_public_ip_tracker='<key>' \
  klub_gacana_update_bibliography='<key>' \
  ...
```

Generate a key with `openssl rand -base64 48 | tr -d '/+=' | cut -c1-64`. To add one later, re-`put` the full set (read the current one first with `bao kv get`) or use `bao kv patch`.

Nothing else goes on disk. `.secrets/kestra_role_id` and `.secrets/kestra_secret_id` are written by `openbao_setup.yml` and are the only files this role needs — "secret zero", the one credential that cannot live inside the store it unlocks. The role asserts both exist before deploying.

### Deploy-time reads

Some values are consumed as plugin properties and so cannot be fetched at runtime — the task producing them would land in the execution record. Ansible reads them from OpenBao during the deploy and passes them as masked `SECRET_*` env:

| Env | KV path | Key |
|-----|---------|-----|
| `SECRET_TELEGRAM_BRIDGE_BOT_TOKEN` | `kv/homelab/kestra/telegram_bridge` | `bot_token` |
| `SECRET_RSYNC_SSH_KEY` | `kv/homelab/kestra/ssh_bridge` | `private_key` |
| `SECRET_WH_<NAMESPACE>_<FLOW_ID>` | `kv/homelab/kestra/webhooks` | every field, one per webhook flow |

That read uses the **ansible** AppRole (`.secrets/bao_role_id`), needs `pipx inject ansible hvac` (or `pip install hvac` if Ansible is not pipx-installed — a pipx venv is isolated from user site-packages), and is the one thing that makes this role require an unsealed OpenBao at deploy time. Nothing else in the repo gains that dependency.

### Rotation

A secret fetched at runtime is picked up on the next flow execution — no redeploy. The `secret()`-backed values are baked into the container env, so rotating one means updating it in OpenBao and re-running `automation.yml --tags kestra`.

Rotating a **webhook key** is that plus one more step: the producer holds the old URL. Update the field in `kv/homelab/kestra/webhooks`, re-run the role, then re-register the new URL in GitHub / Ghost / whatever calls it. The flow itself never changes.

## Handlers & Service Management

No handlers. `community.docker.docker_container` recreates the container when its comparable parameters (image id after `pull: true`, env, labels, volumes) change. Config-file changes alone do **not** restart the container (the file is bind-mounted); restart manually after editing:

```bash
sudo docker restart kestra
```

## Verification

```bash
sudo docker ps --filter name=kestra
sudo docker inspect kestra --format '{{json .NetworkSettings.Networks}}' | jq
# Expect both "proxy" and "docker-api" present.

# Health endpoint (management port, from inside the proxy network)
sudo docker run --rm --network proxy curlimages/curl -sf http://kestra:8081/health

sudo docker logs kestra --tail 50 | grep -i -E 'error|ssl|postgres|started'

# Confirm the socket-proxy path is wired up: run any flow with a Docker
# task runner task, or from the host:
sudo docker run --rm --network docker-api curlimages/curl -sf http://socket-proxy:2375/_ping
```

## Rollback / Uninstall

```bash
sudo docker stop kestra && sudo docker rm kestra
# Flow definitions, users, executions live in the central Postgres "kestra"
# database — drop it there if you want a true wipe.
sudo rm -rf ./data/kestra
```

## Troubleshooting

**`SSL error: …` / `FATAL: connection requires a valid client certificate` at startup**
The JDBC driver needs the PKCS#8 DER key — confirm `./data/certs/kestra.key.pk8` exists, is readable by uid `1000`, and was regenerated after the last cert rotation (Step 3). `sslmode=verify-ca` validates the server chain against `/app/certs/ca.crt`.

**Webhook calls return an Authelia login redirect**
The Authelia bypass rule on the automation host matches `^/api/v1/main/executions/webhook/.*` only. Kestra's own basic auth also whitelists that path via `open-urls`. A webhook URL outside that pattern is challenged by both layers.

**Task containers can't reach each other / a task hangs pulling an image**
Task containers run on the network named in the flow's `networkMode` (e.g. `sandbox`), spawned via `socket-proxy`. Check `docker ps --filter name=socket-proxy`, and that the image referenced by `containerImage` exists locally (`ansible-runner`/`claude-runner` are built by their roles, never pulled).

**Flow declares `volumes:` but the files are missing inside the task container**
There is no config error and no warning — an unrecognised or absent `volume-enabled` makes the runner drop every bind, so the task fails downstream instead (e.g. `ansible-playbook` reporting `the vault password file /secrets/pass.file was not found`). Check the key really is kebab-case `volume-enabled: true` in `application.yml` under `plugins.configurations`, and that the paths exist on the **host**. To confirm what was actually mounted, catch the short-lived container while it runs:

```bash
# on the automation host, in one shell, then trigger the flow in another
while :; do id=$(docker ps -aq --filter ancestor=<runner-image> | head -1); \
  [ -n "$id" ] && { docker inspect "$id" --format '{{json .HostConfig.Binds}}'; break; }; sleep 0.1; done
```

`null` means the mounts were dropped; a JSON array means Docker got them and the fault is elsewhere.

**`ansible-playbook` reports `no such identity: <path>: No such file or directory`**
The SSH key mount target must equal `user.private_key_path` **as it is committed in the branch the runner clones**, not the path a workstation uses — the flow runs against the checkout, so a local-only edit to that var silently desyncs the two. It must also stay absolute (`/root/.ssh/<key>.ppk`); Docker rejects a `~/...` mount target outright, so the flow would fail to start the container at all.
