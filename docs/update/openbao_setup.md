# Role: openbao_setup

## Purpose

Configures everything **inside** a running OpenBao: unseals it, mounts KV v2, writes the ACL policies, enables the auth methods, creates the human admin account, and issues the AppRole credentials the control node, Kestra and `update/backup.yml` use.

Companion to the [`openbao`](openbao.md) role, which deploys the container itself. The split follows what OpenBao allows: the container, its `config.hcl` and the declarative audit device are host-level state (the `openbao` role); mounts, policies, auth methods and tokens are API state that needs a privileged token (this role).

Run by `update/openbao_setup.yml`, which prompts for every secret. **Nothing sensitive is stored in the inventory or on the host** — the root token and unseal shares exist only for the duration of the run, and issued credentials are written to `.secrets/` on the control node (gitignored, `0600`).

```bash
cd update && ansible-playbook openbao_setup.yml --vault-password-file ../pass.file
```

> Run it from `update/` — the inventory is set in `update/ansible.cfg`, so a run started from the repo root matches no hosts unless you pass `-i update/inventories/production/hosts.yml`. The `.secrets/` output path is resolved from `playbook_dir`, so it lands in the repo root either way.

The run authenticates as the **admin `userpass` account**, so the root token can stay revoked. It is needed only on a first bootstrap, before that account exists.

| Prompt | Silent | Leave empty to |
|--------|--------|----------------|
| Admin username | no | use the deploy user (`user.name`) |
| Root token | yes | authenticate as the admin account instead — the normal case |
| Unseal key 1–3 | yes | skip unsealing (fails if the node *is* sealed) |
| Admin password | yes | skip the bootstrap entirely and only unseal |

Supplying neither a password nor a root token makes the run unseal-only. Supplying the password also creates the admin account if it does not exist yet, which is what makes the first bootstrap → revoke-root → userpass-from-then-on sequence work.

Common runs:

```bash
# After a reboot — unseal only; paste the 3 shares, leave the rest empty
ansible-playbook update/openbao_setup.yml --vault-password-file pass.file --tags unseal

# First-time bootstrap of an already-unsealed node (root token at the prompt)
ansible-playbook update/openbao_setup.yml --vault-password-file pass.file --skip-tags unseal

# Every run after that: admin password only, root prompt left empty

# Mint a fresh SecretID and backup token (old ones stay valid until revoked)
ansible-playbook update/openbao_setup.yml --vault-password-file pass.file \
  -e openbao_setup_rotate_credentials=true
```

## Idempotence

Re-running is safe and reports no change once everything exists. Each step reads the live state first:

| Step | Skipped when |
|------|--------------|
| Unseal | already unsealed |
| Authentication | never skipped — userpass, or the root token on a first bootstrap |
| KV v2 mount | `kv/` present in `sys/mounts` |
| Policies | rendered template matches the live policy byte-for-byte |
| Auth methods | path present in `sys/auth` |
| Admin account | the user exists (an existing account is **never** overwritten — a re-run must not reset a working password) |
| AppRole definition | policies unchanged |
| RoleID / SecretID | both files already exist in `.secrets/` |


A drifted policy (edited by hand in the UI) shows up as a change and is rewritten from the template — the repo is the source of truth for policy text.

## Prerequisites

- OpenBao deployed (the [`openbao`](openbao.md) role) and **initialized** — `bao operator init` stays manual, it prints the shares and the root token.
- The API reachable on the host's `127.0.0.1:{{ openbao.port }}` (the container's localhost port bind). Nothing in this role goes through Traefik, so keys and tokens never leave the host.
- A token with `root`/`sudo` capability for the bootstrap part.

## Manual Execution Guide

Everything below is what the role automates, in order. `$BAO` = `http://127.0.0.1:8200`, and the token is passed through the environment so it never lands in `ps` or shell history:

```bash
read -rs BAO_TOKEN; export BAO_TOKEN
```

### Step 1: Unseal

```bash
curl -s --request PUT --data '{"key":"<unseal-share>"}' $BAO/v1/sys/unseal   # x3, different shares
curl -s $BAO/v1/sys/seal-status | jq '.sealed'    # false
```

### Step 2: KV v2

```bash
curl -s $BAO/v1/sys/mounts -H "X-Vault-Token: $BAO_TOKEN" | jq 'keys'
curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"type":"kv","options":{"version":"2"}}' $BAO/v1/sys/mounts/kv
```

### Step 3: Policies

```bash
curl -s -X PUT -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"policy\":\"$(sed 's/"/\\"/g;:a;N;$!ba;s/\n/\\n/g' policy-admin.hcl)\"}" \
  $BAO/v1/sys/policies/acl/admin
```

The four policies are rendered from `templates/policy-*.hcl.j2`:

| Policy | Grants |
|--------|--------|
| `admin` | full control of `kv/*`, `sys/*`, `auth/*`, `identity/*` — human operators |
| `ansible-read` | **read-only** on `kv/data/homelab/*` + `kv/metadata/homelab/*` — the control node cannot change a secret, only consume it |
| `backup` | `read` on `sys/storage/raft/snapshot` and nothing else |
| `kestra-read` | read-only on `kv/data/homelab/kestra/*` plus the two specific paths its flows need — deliberately narrower than `ansible-read`, since Kestra runs user-authored flows |

### Step 4: Auth methods and the admin account

```bash
curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" --data '{"type":"userpass"}' $BAO/v1/sys/auth/userpass
curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" --data '{"type":"approle"}'  $BAO/v1/sys/auth/approle

curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"password":"<secret>","token_policies":"admin"}' \
  $BAO/v1/auth/userpass/users/<username>
```

Log in as that user, confirm it works, then stop using root:

```bash
docker exec -e BAO_TOKEN openbao bao token revoke -self
```

Recover it later with `bao operator generate-root` and a quorum of shares.

### Step 5: AppRoles (control node, Kestra)

```bash
curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"token_policies":"ansible-read","token_ttl":"20m","token_max_ttl":"1h","secret_id_ttl":"0"}' \
  $BAO/v1/auth/approle/role/ansible

curl -s -H "X-Vault-Token: $BAO_TOKEN" $BAO/v1/auth/approle/role/ansible/role-id | jq -r .data.role_id
curl -s -X POST -H "X-Vault-Token: $BAO_TOKEN" $BAO/v1/auth/approle/role/ansible/secret-id | jq -r .data.secret_id
```

Store them as `.secrets/bao_role_id` and `.secrets/bao_secret_id` (`0600`) on the control node.

Repeat for every entry of `openbao_setup_approles`. The second entry, `kestra`, carries the
narrower `kestra-read` policy and lands in `.secrets/kestra_role_id` / `.secrets/kestra_secret_id`;
the `kestra` role reads those at deploy time — see [kestra.md](kestra.md).

### Step 6: nothing — backups use an AppRole

`update/backup.yml` authenticates with the `backup` AppRole created in step 5, exchanging its RoleID/SecretID for a short-lived token on every run. There is no long-lived backup token to create, store or renew, and the inventory holds no OpenBao credential.

## Configuration Reference

### Variables

Documented with placeholders in `defaults/main.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `openbao_setup_addr` | `http://127.0.0.1:<port>` | API endpoint (host-local bind, never Traefik) |
| `openbao_setup_kv_path` | `kv` | KV v2 mount path |
| `openbao_setup_policies` | `[admin, ansible-read, backup, kestra-read]` | Policies rendered from `templates/policy-<name>.hcl.j2` |
| `openbao_setup_kestra_read_paths` | 3 paths | Paths `kestra-read` may read — extend when a flow needs a new secret |
| `openbao_setup_auth_methods` | `userpass`, `approle` | Auth methods to enable (`{path, type}`) |
| `openbao_setup_admin_user` | `{{ user.name }}` | userpass account name |
| `openbao_setup_admin_policies` | `[admin]` | Policies on that account |
| `openbao_setup_approles` | `ansible`, `kestra` | One entry per consumer: `{name, policies, role_id_file, secret_id_file}`, plus optional TTL overrides. Never shared — a leaked SecretID should not reach beyond its own consumer |
| `openbao_setup_approle_token_ttl` / `_max_ttl` | `20m` / `1h` | Default lifetime of issued tokens; overridable per entry |
| `openbao_setup_approle_secret_id_ttl` | `0` | `0` = SecretID never expires (issued tokens still do) |
| `openbao_setup_secrets_path` | `<repo>/.secrets` | Where issued credentials are written (gitignored, `0600`) |
| `openbao_setup_rotate_credentials` | `false` | Mint a new SecretID / backup token even if files exist |

### Prompt variables

| Variable | Used for |
|----------|----------|
| `bao_root_token` | every authenticated call; empty = unseal-only run |
| `bao_unseal_key_1..3` | the unseal shares |
| `bao_admin_password` | password of the userpass account, only on creation |

All are `private: true` (no echo) and can be supplied with `-e` for a non-interactive run — at the cost of putting them in shell history.

## Verification

```bash
ansible-playbook update/openbao.yml --vault-password-file pass.file --tags verify

read -rs BAO_TOKEN; export BAO_TOKEN
docker exec -e BAO_TOKEN openbao bao secrets list
docker exec -e BAO_TOKEN openbao bao policy list
docker exec -e BAO_TOKEN openbao bao auth list
ls -l .secrets/                     # bao_*, kestra_role_id, kestra_secret_id
```

Prove the AppRole is genuinely read-only:

```bash
BAO_ROLE_ID=$(cat .secrets/bao_role_id) BAO_SECRET_ID=$(cat .secrets/bao_secret_id)
# login → token → `bao kv put` must fail with 403, `bao kv get` must succeed
```

## Rollback / Uninstall

Nothing is installed on the host; the role only creates state inside OpenBao:

```bash
docker exec -e BAO_TOKEN openbao bao secrets disable kv          # DESTROYS every KV secret
docker exec -e BAO_TOKEN openbao bao auth disable approle
docker exec -e BAO_TOKEN openbao bao auth disable userpass
docker exec -e BAO_TOKEN openbao bao policy delete admin
rm -f .secrets/bao_role_id .secrets/bao_secret_id \
      .secrets/kestra_role_id .secrets/kestra_secret_id \
      .secrets/backup_role_id .secrets/backup_secret_id
```

Disabling the KV mount deletes every secret under it irreversibly — snapshot first.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Vault is sealed` (503) | The node sealed itself (restart/reboot). Re-run with the 3 shares, or `--tags unseal`. |
| `Still sealed after 3 share(s)` | Duplicate shares were pasted — they do not advance the counter. Use three *different* ones. |
| `permission denied` (403) on every bootstrap task | The supplied token is not root/`sudo`, or expired. `bao operator generate-root` with a quorum of shares. |
| Policy rewritten on every run | Someone edits it in the UI; the template is the source of truth. Fold the change into `templates/policy-*.hcl.j2`. |
| AppRole credentials not regenerated | The files already exist — that is by design. `-e openbao_setup_rotate_credentials=true`. |
| Backup play still 403s after a rotate | The new token was written to `.secrets/` but not copied into `host_vars/primary_openbao.yml`. |
