# Kestra

## What this is

Kestra is the workflow orchestrator for this stack — a declarative, trigger-driven automation platform
that runs as one Docker container in "standalone" mode (UI, API, scheduler and worker all in the same
process). It sits behind the reverse proxy with single-sign-on forward-auth in front of the UI; webhook
trigger paths are the one exception, bypassed at both the proxy and inside Kestra's own login, because
they are called by external systems that cannot complete an interactive login.

Two design decisions shape almost everything else in this guide:

**Kestra never touches the host's raw Docker socket.** Its built-in Docker task runner — the mechanism a
flow uses to execute a script or a command inside its own throwaway container — is pointed at a filtered
Docker API endpoint instead. A container that can reach the real Docker socket is root on the host in
every way that matters: it can start a privileged container, mount the host filesystem into it, and read
every secret on the machine. Kestra legitimately needs to launch and reap short-lived task containers, so
it is instead given an HTTP endpoint that permits exactly that lifecycle — create, start, wait, read logs,
remove — and refuses everything else, including the calls that would grant an interactive shell inside a
container. That endpoint is a separate, narrowly-scoped service in its own right; this guide only covers
what Kestra itself needs from it.

**Kestra's repository and queue live in the central PostgreSQL server, reached over mutual TLS.** Flow
definitions, execution history, triggers and users are rows in that database, not files on this host —
which is also why there is no "flows" directory anywhere in this deployment: flows are authored in the
Kestra UI and their only home is that database.

One more thing worth knowing before you start: Kestra's own built-in plugin for calling an AI provider is
a single request/response chat completion — it sends a prompt, gets an answer, and that is the whole
interaction. It has no tool use, no file access, no ability to run commands or iterate. Any flow that
needs an actual agentic coding run — read a repository, make edits, run tests — cannot use that plugin at
all. Those flows instead launch a plain Docker task against a separate, purpose-built sandbox image that
runs the real Claude Code CLI inside a throwaway, unprivileged container; that image and its network are
built as their own thing, not by Kestra, and Kestra only needs to know its name. The same pattern is used
for flows that run Ansible playbooks: they call a dedicated task type with a purpose-built image supplied
as its container image, rather than whatever generic image that task type ships with by default.

Runs on: the automation host, alongside the filtered Docker API endpoint and the two sandbox images.
Talks to: the reverse proxy (inbound), the central PostgreSQL server (mutual TLS), the filtered Docker API
endpoint (task containers), an SMTP server (through flows, not directly), and — for flows that need
credentials at run time — OpenBao, over its HTTP API.

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

**The reverse proxy and the single sign-on portal are running on this host**

```bash
docker ps --filter 'name=^traefik$'
docker ps --filter 'name=^authelia$'
docker run --rm --network proxy curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  http://authelia:9091/api/authz/forward-auth
```

**A filtered Docker API endpoint answers on an isolated network**

Kestra's task runner talks to it, never to the host socket. Confirm it is up and reachable from the
network Kestra will join:

```bash
docker network inspect docker-api --format '{{.Internal}}'
# expect: true

docker run --rm --network docker-api curlimages/curl -sf http://socket-proxy:2375/_ping
# expect: OK
```

If this is missing, it needs to be stood up as its own deployment before Kestra can start — Kestra's
container creation will succeed even without it, but every task that launches a container will then fail
to reach the daemon.

**The central PostgreSQL server has a database and login role for Kestra**

Run on the database host:

```bash
docker exec -it postgres-db psql -U postgres -c '\l' | grep kestra
docker exec -it postgres-db psql -U postgres -c '\du' | grep kestra
```

**The PostgreSQL mutual-TLS client certificate is present on this host**

The database requires `clientcert=verify-full`, so a password alone is refused.

```bash
ls -l ./data/certs/
sudo openssl x509 -in ./data/certs/kestra.crt -noout -subject -dates
```

You need `./data/certs/kestra.crt`, `./data/certs/kestra.key`, and the issuing `./data/certs/ca.crt`.
They are signed centrally and copied here; Kestra never generates its own. The `-subject` output must
show `CN = <db-username>`, matching the database role above.

**`openssl` is available on this host**

Used below to convert the private key into the format the JDBC driver expects.

```bash
openssl version
```

**OpenBao is reachable, if flows will fetch their own secrets from it**

Kestra's open-source edition has no live secrets-manager integration — that is a paid-tier feature — so
every value a flow reads through its secrets function has to already be sitting in this container's own
environment when it starts. A handful of those values, though, are fetched by *flows themselves* at run
time by calling OpenBao's own HTTP API directly from inside a script task, using a set of
API credentials Kestra is handed once at start time and never sees expire on its own. If you plan to use
that pattern (Step 4 below), you need:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://openbao.your-domain.com/v1/sys/health
```

If you don't have anything like that, skip Step 4 and pass whatever flow secrets you need directly as
`SECRET_*` values in Step 6 instead — the mechanism works the same either way, only the source of the
value differs.

**You have decided the sandbox images and their network exist, if flows will use them**

Only needed if any flow you plan to write launches a Claude Code or Ansible sandbox task:

```bash
docker images claude-runner:latest --format '{{.Repository}}:{{.Tag}}'
docker images ansible-runner:latest --format '{{.Repository}}:{{.Tag}}'
docker network inspect sandbox --format '{{.IPAM.Config}}'
```

**You have SMTP credentials**, if any flow will send mail directly (rather than through a task written to
call a mail API on its own) — an application password for the sending mailbox.

**DNS for Kestra's domain resolves to this host**

```bash
dig +short kestra.your-domain.com
```

## Setup

### Overview

1. Create the storage directory.
2. Confirm the PostgreSQL client certificate and convert its key for the JDBC driver.
3. Decide the values only you can choose: the encryption key, the admin login, the time zone.
4. Fetch or prepare the secrets flows will need, as base64-encoded environment values.
5. Write `application.yml`.
6. Start the container on both networks.
7. Confirm it came up clean.

---

#### Step 1: Create the storage directory

```bash
cd <deploy-dir>
sudo mkdir -p ./data/kestra/storage
sudo chown -R <puid>:<pgid> ./data/kestra
sudo chmod 0755 ./data/kestra ./data/kestra/storage
```

**Explanation**: `./data/kestra/storage` is mounted at `/app/storage` inside the container and holds
Kestra's internal storage objects — task outputs, staged files, namespace files. Flow definitions, users
and execution history are **not** here; those live entirely in PostgreSQL, reached in Step 5. `<puid>` is
the in-container `kestra` user Kestra's own image runs as; get it wrong and the container starts but
cannot write its own storage.

---

#### Step 2: Confirm the client certificate and convert the key

```bash
cd <deploy-dir>
sudo openssl x509 -in ./data/certs/kestra.crt -noout -subject
sudo openssl x509 -in ./data/certs/ca.crt -noout -subject -dates

sudo openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
  -in ./data/certs/kestra.key -out ./data/certs/kestra.key.pk8

sudo chown <puid>:<pgid> ./data/certs/kestra.crt ./data/certs/kestra.key ./data/certs/kestra.key.pk8
sudo chmod 0600 ./data/certs/kestra.crt ./data/certs/kestra.key ./data/certs/kestra.key.pk8
```

**Explanation**: The certificate and key you already have are PEM, which is what most TLS tooling expects
— but the PostgreSQL **JDBC** driver Kestra uses only reads private keys in PKCS#8 **DER** format, so the
PEM key has to be converted before it is usable. This conversion is deterministic, so re-running it after
a certificate rotation is always safe and always produces the same output for the same input key —
re-run it whenever the certificate is reissued, since the `.pk8` file does not update itself.

---

#### Step 3: Decide the values only you can choose

```bash
openssl rand -base64 32          # kestra.encryption.secret-key
```

Pick an admin login (must be an email address — Kestra's basic-auth validates the format), a password for
it, and confirm the host's time zone, which controls when schedule triggers fire:

```bash
timedatectl show --property=Timezone --value
```

**Explanation**: The encryption key encrypts values typed as `SECRET` at rest inside stored executions —
losing it or changing it makes every previously stored secret-typed value unreadable, so generate it once
and keep a copy somewhere durable. The admin login is HTTP basic auth in front of the whole UI and API,
in addition to whatever the reverse proxy's own single sign-on already requires in front of it — it exists
so the API remains usable by something (a flow, a script) that cannot complete an interactive login.

---

#### Step 4: Fetch or prepare the secrets flows will need

Skip this step entirely if you decided in "Before you start" not to use OpenBao, and instead pick
your own values for the `SECRET_*` flags directly in Step 6.

Two credentials let Kestra hand OpenBao access to flows *without* Kestra itself holding a
standing integration: an identity issued once, ahead of time, scoped to read only what flows are allowed
to read. Have that identity's role and secret IDs ready:

```bash
KESTRA_ROLE_ID=<secret>
KESTRA_SECRET_ID=<secret>
```

A handful of other values, though, cannot be fetched by a flow at run time at all, and have to be baked
into the container's own environment instead — anywhere a value is consumed as a fixed property of a task
(a message-sending task's token, a remote-command task's private key) rather than by a script you write
yourself, that property only accepts a literal or an expression resolved when the flow is parsed, never
the output of a preceding task. Feeding it from a preceding task would mean the secret gets written into
the stored execution record in plaintext — exactly what a masked, environment-backed secret exists to
avoid. Fetch those few values now, using a **separate**, more broadly scoped identity you use only for
this one-time read — never the identity you just prepared for Kestra above:

```bash
READ_ROLE_ID=<secret>
READ_SECRET_ID=<secret>

BAO_TOKEN=$(curl -sf -X POST https://openbao.your-domain.com/v1/auth/approle/login \
  -d "{\"role_id\":\"$READ_ROLE_ID\",\"secret_id\":\"$READ_SECRET_ID\"}" | jq -r '.auth.client_token')

BRIDGE_BOT_TOKEN=$(curl -sf -H "X-Vault-Token: $BAO_TOKEN" \
  https://openbao.your-domain.com/v1/<kv-mount>/data/kestra/telegram-bridge \
  | jq -r '.data.data.bot_token')

RSYNC_SSH_KEY=$(curl -sf -H "X-Vault-Token: $BAO_TOKEN" \
  https://openbao.your-domain.com/v1/<kv-mount>/data/kestra/ssh-bridge \
  | jq -r '.data.data.private_key')
```

If any flow has a webhook trigger, its key is the **only** authentication on that trigger's URL — the
webhook path bypasses the reverse proxy's login and Kestra's own basic auth, since it exists to be called
by systems that cannot log in. Generate one key per webhook flow, store them together, and pull the whole
set back as one set of environment flags:

```bash
openssl rand -base64 48 | tr -d '/+=' | cut -c1-64   # one per webhook flow, store under the same path

WEBHOOK_ENV_ARGS=()
while IFS=$'\t' read -r name value; do
  var="SECRET_WH_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  WEBHOOK_ENV_ARGS+=(-e "${var}=$(printf '%s' "$value" | base64 -w0)")
done < <(curl -sf -H "X-Vault-Token: $BAO_TOKEN" \
  "https://openbao.your-domain.com/v1/<kv-mount>/data/kestra/webhooks" | jq -r '.data.data | to_entries[] | "\(.key)\t\(.value)"')

unset BAO_TOKEN
```

**Explanation**: Kestra decodes any container environment variable named `SECRET_<NAME>` from base64 once
at start, keeps it in memory, and masks it wherever it would otherwise appear in a log or the UI — a flow
reads it back with a secrets-lookup expression naming `<NAME>`. That is the entire secrets mechanism this
edition has; there is no live backend a flow calls into automatically. `WEBHOOK_ENV_ARGS` is built as a
shell array precisely so Step 6 can splice in one `-e` flag per webhook flow without hand-editing the
`docker run` command every time a webhook flow is added — add a field to the stored set, rerun this step
and Step 6, and the new flag appears automatically. Naming a field `<namespace>_<flow-id>` when you store
it, and reading it back as `SECRET_WH_<NAMESPACE>_<FLOW-ID>` inside that flow's own webhook trigger
definition, keeps the mapping obvious later; nothing enforces that convention, so pick one and stay
consistent.

---

#### Step 5: Write `application.yml`

```bash
cd <deploy-dir>
sudo tee ./data/kestra/application.yml >/dev/null <<'EOF'
datasources:
  postgres:
    url: "jdbc:postgresql://<postgres-ip>:<postgres-port>/kestra?ssl=true&sslmode=verify-ca&sslrootcert=/app/certs/ca.crt&sslcert=/app/certs/kestra.crt&sslkey=/app/certs/kestra.key.pk8"
    driverClassName: org.postgresql.Driver
    username: <db-username>
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
    secret-key: <secret>
  anonymous-usage-report:
    enabled: false
  server:
    basic-auth:
      username: <admin-user>
      password: <secret>
      open-urls:
        - "/api/v1/main/executions/webhook/"
        - "/api/v1/executions/webhook/"
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
sudo chown <puid>:<pgid> ./data/kestra/application.yml
sudo chmod 0600 ./data/kestra/application.yml
```

**Explanation**: This file carries only what a container environment variable cannot express — the
database connection with its mutual-TLS material, and the Docker task runner's plugin-level defaults.
Everything else that can be an environment variable is one, set in Step 6, so this file stays small and
does not need to be rewritten for values that change per deployment. `sslmode=verify-ca` validates the
database server's own certificate chain against the mounted CA, not just that a certificate was
presented. `plugins.defaults` for the Docker task runner is what makes **every** Docker task in every flow
go through the filtered endpoint without that flow ever mentioning it — a flow author never writes
`host:` themselves and so can never accidentally point a task at the raw socket even if they wanted to.
`fileHandlingStrategy: VOLUME` exchanges a task's input and output files through named Docker volumes
rather than a shared host temp directory, which matters because the daemon behind the filtered endpoint
is the **host's** daemon — a bind-mounted host tmp-dir would need to already exist there and be
predictable, whereas a named volume the daemon creates and cleans up on its own needs neither.
`volume-enabled: true` is a separate, additional switch: it lets a flow declare its own explicit bind
mounts on top of that (host paths, again, because the task runner talks to the host daemon) — leave it
off and any flow's `volumes:` list under a Docker task runner is silently ignored, with no error, and
whatever the task expected to find mounted simply is not there. That key is **kebab-case**
(`volume-enabled`); the camelCase spelling parses as valid YAML but is never read by the runner, so a
flow relying on a mount fails downstream with a missing-file error that gives no hint the mount itself was
the problem. The webhook `open-urls` entries must match, character for character, whatever bypass rule
you configure at the reverse proxy for the same path — Kestra's own basic auth and the proxy's login are
two independent layers, and a webhook URL only actually bypasses authentication if both agree.

---

#### Step 6: Start the container

```bash
cd <deploy-dir>
sudo docker run -d \
  --name kestra \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --dns <internal-dns-ip> \
  -e TZ=<timezone> \
  -e SECRET_TELEGRAM_BOT_TOKEN="$(printf '%s' '<secret>' | base64 -w0)" \
  -e SECRET_TELEGRAM_CHAT_ID="$(printf '%s' '<secret>' | base64 -w0)" \
  -e SECRET_SMTP_USERNAME="$(printf '%s' '<secret>' | base64 -w0)" \
  -e SECRET_SMTP_PASSWORD="$(printf '%s' '<secret>' | base64 -w0)" \
  -e SECRET_OPENBAO_ROLE_ID="$(printf '%s' "$KESTRA_ROLE_ID" | base64 -w0)" \
  -e SECRET_OPENBAO_SECRET_ID="$(printf '%s' "$KESTRA_SECRET_ID" | base64 -w0)" \
  -e SECRET_TELEGRAM_BRIDGE_BOT_TOKEN="$(printf '%s' "$BRIDGE_BOT_TOKEN" | base64 -w0)" \
  -e SECRET_RSYNC_SSH_KEY="$(printf '%s' "$RSYNC_SSH_KEY" | base64 -w0)" \
  -e ENV_OPENBAO_URL="https://openbao.your-domain.com" \
  "${WEBHOOK_ENV_ARGS[@]}" \
  -v "$(pwd)/data/kestra/application.yml:/etc/config/application.yaml:ro" \
  -v "$(pwd)/data/kestra/storage:/app/storage" \
  -v "$(pwd)/data/certs/ca.crt:/app/certs/ca.crt:ro" \
  -v "$(pwd)/data/certs/kestra.crt:/app/certs/kestra.crt:ro" \
  -v "$(pwd)/data/certs/kestra.key.pk8:/app/certs/kestra.key.pk8:ro" \
  --health-cmd 'curl -fsS -o /dev/null http://127.0.0.1:8081/health' \
  --health-interval 30s \
  --health-timeout 6s \
  --health-retries 4 \
  --health-start-period 120s \
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

**Explanation**: The `--config` flag is not optional — a bind-mounted configuration file is not
auto-detected, and without it the server exits immediately at start with a missing-property error. Two
networks are needed and a plain container start only accepts one at creation, hence the separate
`docker network connect` afterward: `proxy` gives Kestra its static, Traefik-routable address, and the
isolated Docker API network is what lets its task runner reach the filtered endpoint by name.
`SECRET_*` values are base64-encoded on the command line rather than written in plain text, because that
is the literal format Kestra decodes them from; `printf` rather than `echo` avoids a trailing newline
becoming part of the decoded secret. `ENV_OPENBAO_URL` follows a different convention on purpose: only
container variables prefixed `ENV_` are exposed to a flow (as a lower-cased, unprefixed field), which
matters for a value like this one that a flow's own script needs to read back but that is not itself
secret. Do **not** reach for a `KESTRA_`-prefixed name to expose something to flows — Kestra's own
configuration system claims that entire prefix for itself, silently treats the variable as a configuration
override instead of application data, and the flow that tries to read it back fails with an
unable-to-find-variable error that gives no hint the prefix was the problem. The `--dns` flag points the
container at your internal DNS resolver rather than whatever the Docker daemon would otherwise hand it, so
that names under `your-domain.com` this container needs to reach — like OpenBao's own domain —
resolve consistently regardless of how the host itself is configured. The health check probes the
management port (`8081`), not the UI/API port (`8080`) that Traefik routes to — Kestra is a JVM
application built on a framework that exposes operational endpoints on a separate port by convention, and
`/health` is the cheapest one that proves the process actually finished starting up, including its
database migrations, which is also why the start period is a full two minutes rather than the usual few
seconds.

---

#### Step 7: Confirm it came up clean

```bash
sudo docker logs -f kestra | grep -iE 'listening|migrat|error'
```

Watch for a line confirming the database schema migrated and the server is listening, then stop
following. Confirm the health check itself is passing:

```bash
sudo docker inspect kestra --format '{{.State.Health.Status}}'
```

**Explanation**: The first start of a new Kestra deployment always runs its database schema migrations,
and that is the single most likely place for a mutual-TLS misconfiguration to surface — a certificate
issue fails the connection before any migration can run, and the container exits rather than starting
degraded. Watching this now, rather than discovering it later, is the entire reason this step exists on
its own instead of folding into general verification below.

## Where flows get their secrets

Flows hold no credentials of their own, by design. A value reaches a flow one of two ways, chosen by
**where the value is consumed**:

| Route | Used when | Exposure |
| --- | --- | --- |
| Fetched from OpenBao inside the flow's own script | the value is used by code you write yourself (Python, shell) | Never leaves the task process |
| Read back with a secrets-lookup expression | the value is a fixed property of a plugin task (a token, a private key field) | Masked wherever Kestra would otherwise log or display it |

The split exists because a plugin's property field only accepts a literal or an expression resolved when
the flow is parsed — never the output of a task that ran before it, since that output is written into the
stored execution record. A script task has no such restriction: code you write can call an HTTP API
directly and keep whatever it fetches entirely inside its own process, using the two credentials
(`SECRET_OPENBAO_ROLE_ID` / `SECRET_OPENBAO_SECRET_ID`) and the URL (`ENV_OPENBAO_URL`) that Step 6 handed
the container specifically so flows can do exactly that, without ever going through Kestra's own control
plane.

Rotating a value fetched inside a script takes effect on the very next execution — nothing to redeploy.
Rotating a value baked in as `SECRET_*` means updating it wherever it is stored, then repeating Step 4 and
Step 6 to restart the container with the new value. Rotating a webhook key is that plus one more step:
whatever external system calls it still has the old URL, so update the field, restart the container, then
re-register the new URL with that system.

## Using the sandbox images from flows

A flow that needs to run a real agentic Claude Code task, rather than a single chat completion, launches
a plain script task against the Claude Code sandbox image on the isolated sandbox network:

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

A flow that needs to run an Ansible playbook uses the dedicated playbook-running task type, with the
purpose-built image supplied explicitly so it carries the collections your project needs instead of
whatever the plugin's own default image ships with:

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
        - <deploy-dir>/data/ansible-runner/secrets/<ssh-key-file>:/root/.ssh/<ssh-key-file>:ro
        - <deploy-dir>/data/ansible-runner/secrets/<vault-password-file>:/secrets/<vault-password-file>:ro
    commands:
      - cd /workspace/project && ansible-playbook <playbook>.yml --vault-password-file /secrets/<vault-password-file>
```

Every volume source above is a **host** path, not a path inside Kestra's own container — the task runner's
calls go out through the filtered Docker API endpoint, which forwards to the host's daemon, and the host
daemon always resolves a bind-mount source against the host filesystem. `host: tcp://socket-proxy:2375`
and `fileHandlingStrategy: VOLUME` do not need repeating in either task — they come from the plugin
defaults written in Step 5.

## Monitoring what is running

Kestra needs no extra configuration to expose metrics: it is built on a framework that puts a
Prometheus-format endpoint on its management port by default, at `http://kestra:8081/prometheus`, and its
UI/API log lines go to the container's own stdout as usual — point whatever already scrapes metrics and
collects logs on this host at both. Two naming quirks are worth knowing before you build a dashboard or an
alert against this endpoint, since they contradict what the metric names alone suggest: the total
scheduler-loop counter measures scheduler *starts* over the life of the process, not evaluation ticks, so
a rate of it sits at zero forever — the per-tick counter has a different, longer name — and there is no
queue-lag metric despite one existing in some documentation for this software; per-queue backlog is a
poll-size gauge instead. Confirm names against the running container before trusting either:

```bash
sudo docker run --rm --network proxy curlimages/curl -sf http://kestra:8081/prometheus | grep -E '^kestra_' | sort -u
```

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` | The deploy account's home directory | Steps 1–6 |
| `<username>` / `<pgid>` | Owner of the working directory | The deploy account and the `docker` group | Before you start |
| `<puid>` | In-container `kestra` user | Fixed by the image; owns storage and the Postgres client key | Steps 1, 2, 5 |
| `<docker-ip>` | Kestra's fixed address on the shared network | Any address in the shared subnet outside the auto-allocation pool | Step 6 |
| `<internal-dns-ip>` | DNS resolver handed to the container | Your internal resolver's address, so internal domains resolve consistently | Step 6 |
| `<timezone>` | IANA time zone name | The host's own, so schedule triggers fire when expected | Step 3, 6 |
| `<db-username>` | Database login role | Must equal the Common Name on `./data/certs/kestra.crt` | Steps 5, 6 |
| `<postgres-ip>` / `<postgres-port>` | Central PostgreSQL server address | Also used as the TLS server identity | Step 5 |
| `<admin-user>` | Kestra's own basic-auth login | Must be an email address | Steps 3, 5 |
| `<secret>` (encryption key) | Encrypts SECRET-typed values at rest | `openssl rand -base64 32`; back it up, it cannot be recovered | Steps 3, 5 |
| `<secret>` (various) | Admin password, database password, static Telegram/SMTP values | Whatever your own accounts use | Steps 5, 6 |
| `openbao.your-domain.com` | Where flows fetch their own secrets from | Wherever OpenBao is reachable | Steps 4, 6 |
| `<kv-mount>` | OpenBao's key-value mount name | Whatever you configured when setting OpenBao up | Step 4 |
| `your-domain.com` | Base domain | Kestra's own login domain and webhook base URL | Steps 5, 6 |
| `<ssh-key-file>` / `<vault-password-file>` | Credentials mounted into an Ansible sandbox task | Whatever files you placed for that image | "Using the sandbox images" |
| `<playbook>.yml` | Playbook an Ansible sandbox task runs | Whatever your project calls it | "Using the sandbox images" |
| `<task>` | Prompt given to a Claude Code sandbox task | Whatever the flow needs done | "Using the sandbox images" |

## Verification

```bash
sudo docker ps --filter name=kestra
sudo docker inspect kestra --format '{{json .NetworkSettings.Networks}}' | jq
# expect both "proxy" and "docker-api"

sudo docker inspect kestra --format '{{.State.Health.Status}}'
# expect: healthy

sudo docker run --rm --network proxy curlimages/curl -sf http://kestra:8081/health

sudo docker logs kestra --tail 50 | grep -i -E 'error|ssl|postgres|started'

# through the reverse proxy from outside
curl -sf -o /dev/null -w '%{http_code}\n' https://kestra.your-domain.com

# the task runner can actually reach the filtered Docker API endpoint
sudo docker exec kestra wget -qO- http://socket-proxy:2375/_ping 2>/dev/null \
  || docker run --rm --network docker-api curlimages/curl -sf http://socket-proxy:2375/_ping
```

## Updating & day-to-day

**Pull a new image.** The database and storage are on bind mounts and in PostgreSQL, so nothing is lost.

```bash
cd <deploy-dir>
sudo docker pull kestra/kestra:latest
sudo docker stop kestra && sudo docker rm kestra
# re-run the docker run command from Step 6, then reconnect docker-api
sudo docker logs -f kestra | grep -iE 'listening|migrat|error'
```

Schema migrations run automatically on first start of a new version and are not reversible — take a
database dump before a major version jump.

**Change `application.yml`.** It is read once at start, not watched — edit it, then recreate the
container:

```bash
sudo docker stop kestra && sudo docker start kestra
```

**Add a webhook flow.** Generate a new key, add it to wherever you store the webhook set, repeat Step 4
to rebuild the environment flags, and repeat Step 6 to restart with them included. Nothing about the
running container picks up a new webhook key without a restart.

**Export a namespace's flows** as a point-in-time copy, outside of a database backup:

```bash
sudo docker exec kestra sh /app/kestra flow export \
  --namespace <namespace> \
  --server http://localhost:8080 \
  --user <admin-user>:<secret> \
  /tmp
sudo docker cp kestra:/tmp/flows.zip ./flows-<namespace>.zip
```

The launcher is a self-executing archive with a shell-script header — invoking it directly
(`docker exec kestra /app/kestra ...`) fails with an exec-format error; always go through a shell
(`sh /app/kestra ...`). The `--user` flag puts the admin password in the container's own process
arguments, readable by anything with root on this host — acceptable only because reading it already
requires root here, and root already holds every other secret on the machine too.

**Where the logs are.** `docker logs kestra` for everything — start-up, migrations, task-runner activity,
and (once parsed and labelled by whatever collects logs on this host) individual flow execution lines.

**Back up**, in rough order of how badly you would miss it: the `kestra` PostgreSQL database (every flow,
execution and user), the encryption key (without it, every value stored with type `SECRET` is
unreadable), and `application.yml`.

## Rollback / Uninstall

```bash
sudo docker stop kestra && sudo docker rm kestra
sudo rm -rf ./data/kestra
```

Flow definitions, users and execution history live in the central PostgreSQL `kestra` database — drop it
there if you want a true wipe, and understand that doing so is not reversible.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `SSL error` or a client-certificate error at start | The JDBC driver needs the PKCS#8 DER key. Confirm `./data/certs/kestra.key.pk8` exists, is readable by the in-container uid, and was regenerated after the last certificate rotation (Step 2). |
| Container exits immediately with a missing-property error | The `--config /etc/config/application.yaml` flag was dropped from the start command — a bind-mounted config file is never auto-detected. |
| Webhook calls redirect to a login page | The reverse proxy's bypass rule and Kestra's own `open-urls` entry must match the webhook path exactly; a mismatch in either means one layer still demands a login the caller cannot complete. |
| A flow's `volumes:` entries are silently missing inside its task container | `volume-enabled: true` under `plugins.configurations` in `application.yml` is missing, misspelled, or written in camelCase. There is no error — the task just runs without the file it expected and fails downstream with whatever error that absence causes. Confirm the key is exactly `volume-enabled` and re-check the paths exist on the **host**, not inside any container. |
| A flow reading a secret gets an unable-to-find-variable error | Either the value was passed with a `KESTRA_` prefix (claimed by Kestra's own configuration system, never reaches flows) instead of `ENV_` or `SECRET_`, or the container was never restarted after the value was added. |
| Task containers can't reach each other, or a task hangs pulling an image | Confirm the filtered Docker API endpoint is up, and that the image a task references was actually built locally rather than expected to be pulled — the sandbox images in this stack are never pulled from a registry. |
| Basic-auth login fails with a validation error on the username | The admin login must be a well-formed email address; anything else is rejected before the password is even checked. |
| Health check never goes healthy, container keeps restarting | If this happens during the very first start, migrations can legitimately take longer than the default start period on a slow disk — watch `docker logs kestra` for migration progress rather than assuming failure immediately. If it happens on every start, the database connection itself is failing; check the certificate and JDBC URL first. |
