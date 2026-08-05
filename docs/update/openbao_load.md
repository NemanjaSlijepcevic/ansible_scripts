# Role: openbao_load

## Purpose

Mirrors the **whole Ansible inventory** into OpenBao's KV v2 store: every top-level variable of `group_vars/all.yml` and of each `host_vars/<host>.yml` becomes one KV secret under `kv/homelab/`.

This is **populate-only**. The inventory stays the source of truth, every role keeps reading `host_vars`, and nothing in a deploy path depends on OpenBao being reachable — a sealed OpenBao must never block a deploy, least of all the deploy of OpenBao itself. Wiring roles to read from KV at runtime (via `community.hashi_vault` lookups) is a separate, incremental step.

Companion to [`openbao`](openbao.md) (deploys the container) and [`openbao_setup`](openbao_setup.md) (mounts KV, writes policies, creates accounts). Run this one last.

```bash
cd update && ansible-playbook openbao_load.yml --vault-password-file ../pass.file
```

> Run it from `update/` — the inventory is set in `update/ansible.cfg`, so a run started from the repo root matches no hosts.

Prompts:

| Prompt | Notes |
|--------|-------|
| Admin username | echoes; empty = the deploy user (`user.name`) |
| Admin password | silent; the `userpass` account created by `openbao_setup` |

The root token is not used — it is revoked by design once the admin account works.

## Path layout

One secret per top-level variable:

```
group_vars/all.yml : <key>      ->  kv/homelab/all/<key>
host_vars/<host>.yml : <key>    ->  kv/homelab/<host>/<key>
```

KV v2 secrets must be JSON objects, so:

- a variable whose value is a **mapping** is stored as-is — `traefik_links` lands as `kv/homelab/<host>/traefik_links` with its own keys intact;
- a **scalar or list** is wrapped — `base_domain` lands as `{"value": "your-domain.com"}`.

Read one back:

```bash
docker exec -e BAO_TOKEN openbao bao kv get kv/homelab/<host>/<key>
docker exec -e BAO_TOKEN openbao bao kv list kv/homelab/
```

## Rendered vs raw

**Host variables are stored rendered.** `Host(`svc.{{ base_domain }}`)` is written resolved, and the `_service` composition anchors are resolved too, so a consumer reading KV gets the final value — not a template it cannot evaluate.

**Group variables are stored as written.** `group_vars/all.yml` is the base layer; rendering it through a host would silently capture that host's overrides (`ufw_rules`, `prometheus`, `influxdb`, `log_notification` are all overridden somewhere) and write the wrong value under the shared `all` scope. The file is therefore read with the `file` lookup rather than `include_vars` — lookup results are marked unsafe, so nothing in them is ever templated. (`include_vars` does not render at load time either; it defers templating to first *use*, which is exactly when the wrong context would be applied.) The lookup decrypts a vaulted file just as `include_vars` does.

This is why the playbook has **two plays**. A variable whose value references another host — for example `owner: "{{ hostvars['primary_automation'].kestra.uid }}"` in the postgres TLS client list — cannot be resolved from a different host's play context; `map('extract', hostvars[other])` fails with `'hostvars' is undefined`. Each host must therefore render its own variables, which is what `vars` (the current host's variable dict) gives. No host is actually connected to: facts are off and every API call is `delegate_to` the OpenBao host.

## Idempotence

Each secret is read before it is written, and written only when it is missing (404) or its data differs. This matters more than usual: KV v2 is versioned, so a blind write would cut a new version on every run and inflate the store forever. A no-op run reports `changed=0`.

Preview without writing anything:

```bash
ansible-playbook openbao_load.yml --vault-password-file ../pass.file -e openbao_load_dry_run=true
```

The `uri` module has no usable check mode for `POST`, so `openbao_load_dry_run` is the preview switch rather than `--check`. It still performs the reads, so the reported paths are exactly what a real run would write.

## Prerequisites

- OpenBao deployed, **unsealed**, and bootstrapped by [`openbao_setup`](openbao_setup.md) — the run asserts both the seal status and that `kv/` is mounted.
- A `userpass` account whose policy allows `create`/`update` on `kv/data/*` (the `admin` policy does).
- The vault password file, since the vaulted `host_vars` are decrypted on the control node to be read.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `openbao_load_group` | `openbaos` | inventory group holding the OpenBao host |
| `openbao_load_delegate` | first host of that group | every API call is delegated here |
| `openbao_load_addr` | `http://127.0.0.1:{{ openbao.port }}` | container's localhost bind; never Traefik — this role ships the entire inventory over the wire |
| `openbao_load_kv_path` | `kv` | KV v2 mount |
| `openbao_load_prefix` | `homelab` | path prefix under the mount |
| `openbao_load_exclude_keys` | `[]` | top-level variable names never written |
| `openbao_load_admin_user` | `{{ user.name }}` | overridden by the username prompt |
| `openbao_load_dry_run` | `false` | report changes, write nothing |

### On `vault_password`

`group_vars/all.yml` holds a `vault_password` key. By default this role mirrors the inventory as-is and writes it, which means the KV store then contains the key that decrypts the inventory seeding it. To keep it out:

```yaml
openbao_load_exclude_keys:
  - "vault_password"
```

### Orphaned `host_vars`

A `host_vars/<name>.yml` with no matching host in `hosts.yml` is still written, but **raw** — with no host to render against, its Jinja references cannot be resolved. It is read with the same `file` lookup as the group scope, so no resolution is attempted at all. Loading it with `include_vars` instead fails outright: a self-reference such as `url: "{{ immich.url }}/api/server/ping"` looks for a top-level `immich` variable, and inside a namespaced dict there is none.

The run prints a warning naming the file. Treat it as an inventory cleanup hint: nothing reads those variables at deploy time either.

## Manual execution guide

The equivalent by hand, for one variable. Never put the token on the command line:

```bash
read -rs BAO_TOKEN; export BAO_TOKEN     # a userpass token with the admin policy

# read the current value (404 = not there yet)
docker exec -e BAO_TOKEN openbao \
  bao kv get -format=json kv/homelab/<host>/<key>

# write a mapping-valued variable
docker exec -i -e BAO_TOKEN openbao \
  bao kv put kv/homelab/<host>/traefik_links - <<'JSON'
{"name": {"url": "svc.your-domain.com"}}
JSON

# write a scalar (wrapped, to match what the role writes)
docker exec -e BAO_TOKEN openbao \
  bao kv put kv/homelab/<host>/base_domain value=your-domain.com

unset BAO_TOKEN
```

## Verification

```bash
# 1. everything landed
docker exec -e BAO_TOKEN openbao bao kv list kv/homelab/
docker exec -e BAO_TOKEN openbao bao kv list kv/homelab/<host>/

# 2. a rendered value really is resolved (no {{ … }} left)
docker exec -e BAO_TOKEN openbao bao kv get kv/homelab/<host>/traefik_links

# 3. no version churn — re-run and expect changed=0
ansible-playbook openbao_load.yml --vault-password-file ../pass.file

# 4. version count stays at 1 for an untouched secret
docker exec -e BAO_TOKEN openbao bao kv metadata get kv/homelab/<host>/base_domain
```

## Rollback

Nothing on any host changes — the only effect is inside KV. To undo a scope:

```bash
docker exec -e BAO_TOKEN openbao bao kv metadata delete kv/homelab/<host>/<key>
```

`kv metadata delete` removes the secret and all its versions; `kv delete` only soft-deletes the latest one. A [Raft snapshot](db_backup.md) taken before the run restores the whole store.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `OpenBao … is sealed or uninitialized` | node sealed after a reboot | `ansible-playbook openbao_setup.yml --vault-password-file ../pass.file --tags unseal` |
| `No secrets engine mounted at kv/` | bootstrap never ran | run [`openbao_setup`](openbao_setup.md) first |
| 400 on login | wrong username — it defaults to `user.name`, not the account you may have created by hand | pass the right name at the prompt |
| 403 on the write tasks | the account's policy has no `create`/`update` on `kv/data/*` | log in with an `admin`-policy account |
| `'hostvars' is undefined` | a task was moved out of the per-host play; cross-host references only resolve in their own host's context | keep the per-host writes in the second play |
| `'<service>' is undefined` on an orphan scope | the orphan file was loaded with `include_vars`, so its self-references were templated | read orphans with the `file` lookup — see "Orphaned `host_vars`" |
| Every run reports changes | a value is genuinely drifting (a timestamp or a generated secret in the inventory), or a type changed (`"8200"` vs `8200`) | compare with `bao kv get -format=json` and fix the inventory |
| Run reports changes on `all/*` after a host deploy | a `group_vars` key is overridden per host and you edited the override | expected — the `all` scope tracks `group_vars/all.yml` only |
