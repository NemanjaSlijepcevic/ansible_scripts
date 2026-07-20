# Session log — 2026-07-11: n8n → Kestra migration, flows, alerting

Everything changed in this session, in order, with the reasoning and the manual follow-ups. Secrets are shown as `<secret>` — real values live in `host_vars`/`group_vars` as usual.

---

## 1. n8n replaced by Kestra (`update/automation.yml`)

**Question answered first:** do Kestra's plugins make our runner images obsolete?

- **Ansible plugin** (`io.kestra.plugin.ansible.cli.AnsibleCLI`) runs ansible in a container via the Docker task runner, but its default image (`cytopia/ansible`) lacks this repo's collections (`community.docker`, `community.postgresql`, …). → **`ansible_runner` role kept**; flows pass `containerImage: ansible-runner:latest`.
- **Anthropic plugin** (`io.kestra.plugin.anthropic.ChatCompletion`) is API-key chat only — no tools, no workspace, not Claude Code. → **`claude_runner` role kept**; agentic runs launch the sandbox image via the Docker task runner.

**New `kestra` role** (`update/roles/kestra/`):

- Stock `kestra/kestra:latest`, `server standalone`, **no custom image** — the Docker task runner speaks to `socket-proxy:2375` natively (set globally in `kestra.plugins.defaults`, with `fileHandlingStrategy: VOLUME` so no shared tmp-dir is needed; `volumeEnabled: true` allows explicit host-path bind mounts in flows).
- Postgres backend over **JDBC mTLS**: pgjdbc cannot read PEM keys, so the role converts the client key to PKCS#8 DER (`openssl pkcs8 … -outform DER`) on every run (idempotent, survives cert rotation).
- Basic auth (username must be an email) behind Authelia; webhook paths open in both layers.
- OSS secrets = `SECRET_*` env vars, base64: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `SMTP_USERNAME`, `SMTP_PASSWORD` (same Gmail account Authelia's notifier uses).
- Static IP `.13` on the proxy network — `.12` stays with the old n8n container until it is removed by hand.

**Ripple changes:** `prepare_postgres` provisions a `kestra` DB (replacing `n8n`); `postgres_tls_clients` entry `kestra`; `kestra_db` in group_vars; Authelia automation template bypasses `^/api/v1(/main)?/executions/webhook/.*`; telegraf http-check hits `http://kestra:8081/health`; `n8n.uid` → `claude_runner.uid` in the runner roles (hash_behaviour=replace: lives in the host_vars `claude_runner` dict); n8n role + doc deleted; CLAUDE.md, docs/README.md updated.

**Manual n8n teardown (on the server):**

```bash
docker stop n8n && docker rm n8n && docker rmi n8n-docker:latest
crontab -l -u root | grep -v n8n-backup.sh | crontab -u root -
rm /usr/local/bin/n8n-backup.sh
rm -rf ./data/n8n          # back up first — holds workflow git history
# optional: drop the n8n DB/role on postgres; rm ./data/certs/n8n.{crt,key}
```

---

## 2. Repo-managed flows

Flows are code in `update/roles/kestra/templates/flows/*.yml.j2`:

1. Rendered with **custom Jinja delimiters** (`[[ var ]]` / `[% block %]`) so Kestra's own `{{ … }}` expressions pass through unrendered. (Never put literal `[[` in a template comment — Jinja parses it.)
2. Mounted read-only at `/flows` in the container.
3. Pushed after startup via the bundled CLI (retried until the API is up):
   `docker exec kestra /app/kestra flow namespace update automation /flows --no-delete --server http://localhost:8080 --user <email>:<secret>`
4. `--no-delete` preserves UI-only flows; matching ids are overwritten. Workflow: edit template → `ansible-playbook update/automation.yml --tags kestra`.

YAML gotcha found: a pebble ternary (`? :`) inside a command needs the whole scalar quoted.

---

## 3. Flows shipped (namespace `automation`)

| Flow | Trigger | What it does |
|------|---------|--------------|
| `ansible-deploy` | manual | git pull the workspace, run a chosen `update/` playbook via AnsibleCLI (SELECT input; `--check` defaults **true**) |
| `claude-task` | manual | STRING prompt → Claude Code in the sandbox, JSON output (prompt passed via env var, injection-safe) |
| `ghost-new-article` | Ghost `post.published` webhook | mails `kestra.ghost_subscribers` (bcc) via Gmail SMTP; title/excerpt/link from the payload. Ghost admin: custom integration → webhook → `…/webhook/automation/ghost-new-article/<key>` |
| `ansible-update-all` | cron `kestra.update_schedule` (Sun 05:00) | repo sync, then `ForEach` over `kestra.update_playbooks` sequentially; per-playbook `allowFailure` (one broken host doesn't block the rest → WARNING); hard failures mail the admin; `concurrency: limit 1, QUEUE`. **`automation.yml` deliberately excluded** — it can recreate the Kestra container mid-run |
| `ansible-on-merge` | GitHub push webhook | `If ref == refs/heads/main` (merged PR = push to main) → `Subflow ansible-update-all`. GitHub: repo → Settings → Webhooks → `…/webhook/automation/ansible-on-merge/<key>`, push event, `application/json`. Requires Kestra reachable from GitHub |
| `claude-telegram` | subflow (input `prompt`) | worker: Claude Code in sandbox with the ansible repo mounted **ro at `/repo`** (infra context), answer → Telegram bot API; stub message if Claude fails |
| `grafana-alert-triage` | Grafana "Kestra" contact point webhook | on `status == firing`, build prompt with alert JSON (`trigger.body \| toJson`) → `claude-telegram` |
| `kestra-failure-triage` | `Flow` trigger: FAILED in namespace | Claude reads the failed flow's source under `/repo`, explains causes → Telegram. **Loop guard**: ignores itself and `claude-telegram` |

---

## 4. Grafana alert audit

**Covered before:** HTTP service down/slow, per-host telegraf gap (dead-man), host CPU/mem/disk-space, Proxmox CPU/mem, Traefik 5xx/p95, pfSense CPU/mem/WAN/PF-states. Single Telegram contact point.

**Gaps found (ranked):** ① PostgreSQL — metrics collected, zero rules; ② container state — exited/OOM invisible, promtail can die silently; ③ monitoring SPOF — everything alert-related lives on the monitor host, `kuma` role exists but is deployed nowhere, no dead-man's switch to an external service; ④ TLS cert expiry unmonitored (silent Traefik renewal failure); ⑤ no SMART/disk-health (NAS drives, RPi4 SD card); ⑥ CrowdSec metrics scraped but unalerted; ⑦ Proxmox storage + push-gap; ⑧ Loki unused for alerting; ⑨ Kestra `:8081` metrics unscraped; ⑩ `telegraf-immich` in the bucket list fires forever if that host is dormant — verify.

**Implemented this session (① + ②), 12 new rules:**

- `homelab-postgres`: metrics gap (`noDataState: Alerting`), connections > `pg_conn_warn` (80, vs default `max_connections` 100), deadlock increase per DB.
- `homelab-containers`: container persisting in `exited` ≥ `container_exited_min` samples/10m (ephemeral Kestra task containers stay below), OOM-killed container (immediate).
- `homelab-logs`: per-host log ingest gap — zero Loki lines with `node=<host>` in 15m (`noDataState: Alerting`) — the promtail watchdog; first rules on the Loki datasource.

Still open (by priority): ③ deploy kuma on a non-monitor host + external heartbeat, ④ `x509_cert` expiry checks, ⑤ SMART, ⑥ CrowdSec rules.

---

## 5. Grafana × Kestra × Claude × Telegram integration

Notification policy now **fans out** (both routes match the `severity` label all rules carry):

- **Telegram** — raw alert, immediate, repeat 4h (unchanged).
- **Kestra** webhook contact point (`grafana_alert_webhook` in monitor host_vars; key mirrored as `kestra.grafana_webhook_key` in automation host_vars — keep in sync) — repeat 24h, so each firing alert gets roughly one Claude diagnosis, arriving in the same Telegram chat as a follow-up.

Failed Kestra executions go through the same worker via `kestra-failure-triage`.

---

## 6. Deploy order & remaining manual steps

```bash
ansible-playbook update/postgres.yml   --vault-password-file pass.file   # kestra DB + client certs
ansible-playbook update/automation.yml --vault-password-file pass.file   # kestra + flows
ansible-playbook update/monitor.yml    --vault-password-file pass.file --tags grafana  # rules + contact point
```

Manual checklist:

- [ ] DNS record for the kestra domain (wildcard cert already covers TLS)
- [ ] Kill n8n on the server (commands in §1)
- [ ] One-time `git clone` of this repo into `./data/ansible-runner/workspace` (feeds `ansible-deploy`, `ansible-update-all`, and Claude's `/repo` context)
- [ ] Verify claude-runner OAuth still present in `./data/claude-runner/home` (carries over from n8n era)
- [ ] Ghost admin: webhook for `ghost-new-article` (§3)
- [ ] GitHub: push webhook for `ansible-on-merge`; check "Recent Deliveries" after first push
- [ ] First Kestra boot: `docker logs kestra` for config/SSL complaints (config was verified against docs, never test-booted)
- [ ] If the immich host is dormant: prune `telegraf-immich` from `telegraf_buckets` (grafana defaults) to stop permanent gap alerts

Known caveats: Gmail ~500 recipients/day cap on the newsletter flow; Ghost re-fires `post.published` on unpublish→republish; scheduled + on-merge updates queue (never overlap) via flow concurrency.
