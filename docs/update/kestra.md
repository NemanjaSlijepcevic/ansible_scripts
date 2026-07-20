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

**Purpose**: Kestra's local storage backend (flow files, execution artifacts) needs a directory owned by the in-container `kestra` user (uid `1000` — see `kestra.uid`).

**Commands**:
```bash
sudo mkdir -p ./data/kestra/storage ./data/kestra/flows
sudo chown -R 1000:docker ./data/kestra
sudo chmod 0755 ./data/kestra ./data/kestra/storage ./data/kestra/flows
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
          volumeEnabled: true
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
- `volumeEnabled: true` additionally lets flows declare explicit bind mounts; those paths are **host** paths (the proxy talks to the host daemon), e.g. `<deploy-dir>/data/claude-runner/workspace`.
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
- The UI/API listen on `8080`; the management/health endpoint listens on `8081` (unauthenticated, probed by Telegraf from inside the Docker network — it is *not* routed by Traefik).
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
| `kestra.static` | `172.20.0.13` | Static IP on the `proxy` network |
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
| `flows/*.yml.j2` | `./data/kestra/flows/*.yml` (mode 0644) | Repo-managed flow definitions, pushed into the `automation` namespace on every role run |

## Repo-managed flows

Flow YAML lives in the role at `templates/flows/*.yml.j2` and is deployed by the role itself — no manual UI work:

1. `environment.yml` renders each template into `./data/kestra/flows/` using **custom Jinja delimiters** (`[[ var ]]` / `[% block %]`) so Kestra's own `{{ ... }}` expressions pass through to the server unrendered. Inventory values (image names, sandbox network, deploy-dir host paths, key filename) are resolved at render time.
2. The container mounts that directory read-only at `/flows`.
3. After the container starts, the role runs Kestra's bundled CLI against the local API (retried until the server is up):

```bash
sudo docker exec kestra /app/kestra flow namespace update automation /flows \
  --no-delete --server http://localhost:8080 --user admin@your-domain.com:<secret>
```

`--no-delete` preserves flows created only in the UI; a flow whose `id` matches a repo file is **overwritten** (the server only bumps a revision when the source actually changed, so re-runs are idempotent). Treat repo flows as code: edit them in `templates/flows/`, not in the UI. Drop `--no-delete` if the repo should be the single source of truth for the namespace.

Shipped starter flows:

| Flow id | Purpose |
|---------|---------|
| `ansible-deploy` | Pulls this repo in the shared workspace, then runs a chosen `update/` playbook via `AnsibleCLI` in the `ansible-runner` image (SELECT input for the playbook, BOOLEAN input for `--check` dry run, defaults to dry run) |
| `claude-task` | Runs a Claude Code prompt (STRING input, passed via env var to avoid shell injection) in the `claude-runner` sandbox, JSON output |
| `ghost-new-article` | Webhook-triggered by Ghost on post publish; mails the subscriber list (bcc, from `kestra.ghost_subscribers`) via the same Gmail SMTP account Authelia uses (`SMTP_USERNAME`/`SMTP_PASSWORD` Kestra secrets) |
| `ansible-update-all` | Cron-scheduled (`kestra.update_schedule`, default Sunday 05:00): syncs the repo, then runs each playbook in `kestra.update_playbooks` sequentially (`ForEach`, `concurrencyLimit: 1`). Per-playbook failures are `allowFailure` → execution ends WARNING and the rest still run; hard failures (e.g. repo sync) mail the admin via the `errors` block. **`automation.yml` is deliberately excluded** — it can recreate the Kestra container mid-run and kill its own orchestrating execution; update the automation host via `ansible-deploy` or a workstation |
| `ansible-on-merge` | Webhook-triggered by a GitHub **push** hook on this repo (key `kestra.github_webhook_key`); an `If` task acts only on `refs/heads/main` (a merged PR lands as a push to main), then calls `ansible-update-all` as a `Subflow` (`wait` + `transmitFailed`) so the playbook loop is defined in exactly one place. GitHub wiring: repo → Settings → Webhooks → Add webhook, payload URL `https://<kestra-domain>/api/v1/main/executions/webhook/automation/ansible-on-merge/<github_webhook_key>`, content type `application/json`, just the push event. Requires the Kestra domain to be reachable **from GitHub** (public exposure) |
| `claude-telegram` | Worker subflow: takes a `prompt` input, runs Claude Code in the `claude-runner` sandbox with the ansible repo mounted read-only at `/repo` (full infra context), posts the answer to Telegram via the bot API (`SECRET_TELEGRAM_*`). If Claude fails, a stub message is sent and the task still succeeds |
| `grafana-alert-triage` | Webhook-triggered by Grafana's "Kestra" contact point (key `kestra.grafana_webhook_key`); on `status == firing` builds a diagnosis prompt from the alert payload (`trigger.body \| toJson`) and calls `claude-telegram`. Telegram thus gets the raw alert (direct from Grafana) plus a Claude diagnosis as follow-up |
| `kestra-failure-triage` | `Flow` trigger on any `FAILED` execution in the `automation` namespace; asks Claude to read the failed flow's source under `/repo` and explain likely causes → Telegram. Loop guard: ignores failures of itself and of `claude-telegram` (else an Anthropic outage would retrigger forever) |

### Wiring Ghost to `ghost-new-article` (one-time, in Ghost admin)

1. Ghost admin → **Settings → Integrations → Add custom integration** (name it e.g. `kestra`).
2. In the integration, **Add webhook**: event **Post published**, target URL:

```
https://kestra.your-domain.com/api/v1/main/executions/webhook/automation/ghost-new-article/<ghost_webhook_key>
```

3. Publish a post — Ghost POSTs `{ "post": { "current": { title, url, excerpt, ... } } }` and the flow mails every address in `kestra.ghost_subscribers` (recipients are in **bcc**; the `to` field is the sender itself).

Notes:
- The webhook path bypasses Authelia and Kestra's basic auth, so the random `<ghost_webhook_key>` in the URL is the **only** auth — treat it like a password (it lives in `host_vars` as `kestra.ghost_webhook_key`).
- Subscriber list changes = edit `kestra.ghost_subscribers` in `host_vars` and re-run the role (flows are redeployed idempotently).
- Gmail sending limits apply (~500 recipients/day for a normal account) — fine for a small blog list; move to a transactional provider if the list grows.

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
        - <deploy-dir>/data/ansible-runner/secrets/<key>.ppk:/root/<key>.ppk:ro
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

**Flow declares `volumes:` and fails with a config error**
Bind mounts on the Docker task runner require `volumeEnabled: true` (set in `application.yml` under `plugins.configurations`) — and remember the paths must exist on the **host**.
