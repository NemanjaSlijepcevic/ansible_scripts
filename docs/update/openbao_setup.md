# OpenBao Setup (policies, accounts, machine credentials)

## What this is

A freshly deployed OpenBao vault is an empty box: once initialized and unsealed it has a root token
and nothing else — no secrets engine, no access policies, no human login and no machine credentials.
This guide is the sequence that turns that empty vault into the shape every consumer in this homelab
expects: a versioned key-value store, four access policies, a human administrator account, and one
machine credential per automated consumer.

Every command below runs against the vault directly on the machine it lives on — either `docker
exec`'d into the `openbao` container, or `curl`'d against `http://127.0.0.1:8200`, never through the
public domain. That is deliberate: the root token, the unseal shares, and every credential minted in
this guide must never leave this host in the clear.

This guide assumes the vault container is already running. If `docker ps --filter 'name=^openbao$'`
shows nothing, deploy it first — that is a separate, earlier procedure against the same machine.

## Before you start

**The vault is running and you know whether it has been initialized**

```bash
docker ps --filter 'name=^openbao$'
curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq '{initialized, sealed}'
```

If `initialized` is `false`, this is a brand-new vault and initializing it is a one-time act that
prints the credentials the rest of this guide depends on:

```bash
docker exec -it openbao bao operator init -address=http://127.0.0.1:8200
```

Write the five unseal key shares and the initial root token into a password manager immediately —
they are shown exactly once and there is no way to retrieve them again. Never write any of them to a
file on this host, paste them into a command's argument list, or leave them in a terminal scrollback
another session on this machine could read.

**`jq` is available**, to read the JSON API responses used throughout this guide:

```bash
jq --version
```

**You know which of two situations you are in**: a first bootstrap, where you have the root token and
no administrator account exists yet, or a routine run, where an administrator account already exists
and you have its password. The steps below cover both.

## Setup

### Overview

1. Unseal, if the vault is currently sealed.
2. Authenticate — the root token on a first bootstrap, the administrator account on every run after.
3. Enable the key-value v2 secrets engine.
4. Write the four access policies.
5. Enable the human and machine login methods, create the administrator account, retire the root
   token.
6. Issue one machine credential per automated consumer, and store it off the vault.

---

#### Step 1: Unseal, if sealed

```bash
curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq '.sealed'
```

If that printed `false`, skip to Step 2. Otherwise, submit three different shares, one call each:

```bash
read -rs SHARE; echo
curl -s --request PUT --data "{\"key\":\"$SHARE\"}" http://127.0.0.1:8200/v1/sys/unseal | jq '{sealed, progress, t}'
```

Repeat with two more distinct shares until `sealed` reads `false`.

**Explanation**: The vault seals itself — discards the in-memory key that makes its storage
readable — on every restart. That key is never stored whole anywhere; it only ever exists in memory,
reconstructed from a threshold number of independently-held shares. Submitting the same share twice
does not advance `progress` — if it stalls, you pasted a duplicate rather than a genuinely different
third share.

---

#### Step 2: Authenticate

On a first bootstrap, no administrator account exists yet, so use the root token:

```bash
read -rs BAO_TOKEN; echo
export BAO_TOKEN
curl -s http://127.0.0.1:8200/v1/auth/token/lookup-self -H "X-Vault-Token: $BAO_TOKEN" | jq '.data.policies'
```

On every run after Step 5 has created the administrator account, log in with it instead:

```bash
read -rs ADMIN_PASSWORD; echo
BAO_TOKEN=$(curl -s -X POST http://127.0.0.1:8200/v1/auth/userpass/login/<admin-user> \
  --data "{\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.auth.client_token')
export BAO_TOKEN
unset ADMIN_PASSWORD
```

**Explanation**: The token lives only in an exported shell variable, never as a command-line argument
— a value built into `--data` from a variable never appears in this shell's history file or in
another session's view of this process's arguments, both of which a literal token on the command line
would do. Every subsequent call in this guide carries `-H "X-Vault-Token: $BAO_TOKEN"`.

---

#### Step 3: Enable the key-value v2 secrets engine

```bash
curl -s http://127.0.0.1:8200/v1/sys/mounts -H "X-Vault-Token: $BAO_TOKEN" | jq 'keys'
```

If `"kv/"` is not in that list:

```bash
curl -s -X POST http://127.0.0.1:8200/v1/sys/mounts/kv \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"type":"kv","options":{"version":"2"}}'
```

**Explanation**: Version 2 of the key-value engine keeps every past value of a secret, not just the
current one, which is what lets a bad credential rotation be undone by reading an older version
instead of hoping someone wrote the old value down somewhere. Everything mounted here follows one
layout from now on: `kv/homelab/<host>/<service>`, one secret document per group of related
configuration values.

---

#### Step 4: Write the access policies

Four policies, one per audience. Each write is safe to repeat — running it again with the same text
changes nothing.

**`admin`** — full control, for human operators:

```bash
sudo tee /tmp/admin.hcl >/dev/null <<'EOF'
path "kv/*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch"]
}

path "sys/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF
curl -s -X PUT http://127.0.0.1:8200/v1/sys/policies/acl/admin \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"policy\":$(jq -Rs . < /tmp/admin.hcl)}"
```

**`deploy-read`** — the deploy machine, read-only:

```bash
sudo tee /tmp/deploy-read.hcl >/dev/null <<'EOF'
path "kv/data/homelab/*" {
  capabilities = ["read"]
}

path "kv/metadata/homelab/*" {
  capabilities = ["read", "list"]
}
EOF
curl -s -X PUT http://127.0.0.1:8200/v1/sys/policies/acl/deploy-read \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"policy\":$(jq -Rs . < /tmp/deploy-read.hcl)}"
```

**`backup`** — a scheduled snapshot job, and nothing else:

```bash
sudo tee /tmp/backup.hcl >/dev/null <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF
curl -s -X PUT http://127.0.0.1:8200/v1/sys/policies/acl/backup \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"policy\":$(jq -Rs . < /tmp/backup.hcl)}"
```

**`kestra-read`** — a workflow engine, only the paths its flows actually use:

```bash
sudo tee /tmp/kestra-read.hcl >/dev/null <<'EOF'
path "kv/data/homelab/kestra/*" {
  capabilities = ["read"]
}

path "kv/data/homelab/all/log_notification" {
  capabilities = ["read"]
}

path "kv/data/homelab/primary_server/ghost_sites" {
  capabilities = ["read"]
}

path "kv/metadata/homelab/kestra/*" {
  capabilities = ["read", "list"]
}
EOF
curl -s -X PUT http://127.0.0.1:8200/v1/sys/policies/acl/kestra-read \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"policy\":$(jq -Rs . < /tmp/kestra-read.hcl)}"

rm -f /tmp/admin.hcl /tmp/deploy-read.hcl /tmp/backup.hcl /tmp/kestra-read.hcl
```

**Explanation**: `deploy-read` grants no write capability anywhere on purpose — the deploy machine
consumes secrets, and if it could also change one, a compromised deploy run could rewrite the
credentials every other service in the homelab trusts. `kestra-read` is narrower again: scoped to only
the paths its workflows are actually known to reference, plus its own namespace, rather than the whole
tree `deploy-read` can see. Workflow definitions can be authored more casually than a deploy pipeline,
so this account gets exactly what it needs and nothing that would let a careless or malicious flow
walk the rest of the store. `backup` can read exactly one path — a Raft snapshot is a full copy of
every secret this vault holds, so a credential that can pull one is exactly as sensitive as the data
itself, and its policy grants it nothing beyond that single read.

Add a path to the `kestra-read` document (and re-run its `curl`) whenever a new workflow needs to read
a new secret; nothing else about this step changes.

---

#### Step 5: Enable login methods, create the administrator, retire the root token

```bash
curl -s -X POST http://127.0.0.1:8200/v1/sys/auth/userpass \
  -H "X-Vault-Token: $BAO_TOKEN" --data '{"type":"userpass"}'
curl -s -X POST http://127.0.0.1:8200/v1/sys/auth/approle \
  -H "X-Vault-Token: $BAO_TOKEN" --data '{"type":"approle"}'
```

Create your own account under the `admin` policy:

```bash
read -rs ADMIN_PASSWORD; echo
curl -s -X POST http://127.0.0.1:8200/v1/auth/userpass/users/<admin-user> \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data "{\"password\":\"$ADMIN_PASSWORD\",\"token_policies\":\"admin\"}"
unset ADMIN_PASSWORD
```

Log in with it once, using Step 2's second form, to confirm it works — then retire the root token:

```bash
docker exec -e BAO_TOKEN openbao bao token revoke -self
```

**Explanation**: The root token can do anything and does not expire on its own, which makes it the
single worst credential to leave sitting in a shell's environment for longer than it has to be there.
Retiring it the moment a lesser-privileged account exists and is proven to work is the entire reason
Step 2 has two authentication paths — root is only ever used for the handful of minutes between the
vault existing and an administrator account existing. It is not gone forever: `bao operator
generate-root` can mint a fresh one later, but only with a quorum of the original unseal shares, the
same break-glass barrier that protects everything else here.

An account created this way is never overwritten by re-running this step later — creating it again
once it already exists would risk silently resetting a password someone is actively using, so treat a
password change as a deliberate, separate act (see Updating & day-to-day).

---

#### Step 6: Issue a machine credential per automated consumer

Three separate identities — `deploy`, `kestra`, `backup` — never shared between consumers:

```bash
curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/deploy \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"token_policies":"deploy-read","token_ttl":"20m","token_max_ttl":"1h","secret_id_ttl":"0"}'

curl -s http://127.0.0.1:8200/v1/auth/approle/role/deploy/role-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.role_id > <secrets-dir>/bao_role_id

curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/deploy/secret-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.secret_id > <secrets-dir>/bao_secret_id

chmod 0600 <secrets-dir>/bao_role_id <secrets-dir>/bao_secret_id
```

```bash
curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/kestra \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"token_policies":"kestra-read","token_ttl":"20m","token_max_ttl":"1h","secret_id_ttl":"0"}'

curl -s http://127.0.0.1:8200/v1/auth/approle/role/kestra/role-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.role_id > <secrets-dir>/kestra_role_id

curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/kestra/secret-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.secret_id > <secrets-dir>/kestra_secret_id

chmod 0600 <secrets-dir>/kestra_role_id <secrets-dir>/kestra_secret_id
```

```bash
curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/backup \
  -H "X-Vault-Token: $BAO_TOKEN" \
  --data '{"token_policies":"backup","token_ttl":"20m","token_max_ttl":"1h","secret_id_ttl":"0"}'

curl -s http://127.0.0.1:8200/v1/auth/approle/role/backup/role-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.role_id > <secrets-dir>/backup_role_id

curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/backup/secret-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.secret_id > <secrets-dir>/backup_secret_id

chmod 0600 <secrets-dir>/backup_role_id <secrets-dir>/backup_secret_id
```

**Explanation**: This is the one deliberate exception to "every secret lives in the vault." A RoleID
and SecretID pair is the credential a consumer uses to get *into* the vault in the first place, so it
cannot itself be stored inside the thing it unlocks — call it secret zero. It has to sit somewhere the
consumer can read at the moment it authenticates, which is why it lands on disk here, in a directory
you keep out of version control, mode `0600`. Every other secret any of these three consumers ever
needs is fetched from the vault at the moment it is needed instead of being handed out up front.

The three names — `deploy`, `kestra`, `backup` — are yours to choose, and nothing outside the vault
depends on them: each consumer reads only the two credential *files* you write here, never the name
of the login role behind them. An existing vault you did not set up yourself may well use different
names, so read `bao auth list` and `bao policy list` on it rather than assuming these; the file paths
are the part that has to match.

Three separate credentials rather than one shared one is what bounds the damage of a single leak: a
stolen `kestra` SecretID can only ever mint tokens carrying `kestra-read`; it can never reach
`deploy-read` or `backup`. `secret_id_ttl` of `0` means the SecretID itself never expires on its
own — only the short-lived tokens it is exchanged for do (twenty minutes, one hour maximum) — so a
consumer authenticates once per run rather than needing a refresh cycle of its own, while any single
compromise is still bounded by how long that run's token can live.

Repeat this step for one consumer only when you deliberately want to rotate its credential: mint a
fresh SecretID (the RoleID is stable and does not change), overwrite that consumer's file, and revoke
the old SecretID once everywhere that reads the old file has picked up the new one:

```bash
curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/role/deploy/secret-id \
  -H "X-Vault-Token: $BAO_TOKEN" | jq -r .data.secret_id > <secrets-dir>/bao_secret_id
```

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<admin-user>` | The human administrator's login name | Any name not already a `userpass` account | Steps 2, 5 |
| `<secrets-dir>` | A directory on this host that holds machine credentials | Somewhere outside version control, readable only by whoever/whatever needs the credential | Step 6 |
| `<unseal-key>` | One of the vault's five unseal shares | Printed once at initialization; three different ones are needed each time | Step 1 |
| `<root-token>` | The vault's initial root token | Printed once at initialization; used only until the administrator account exists | Step 2 |

## Verification

```bash
docker exec -e BAO_TOKEN openbao bao secrets list
docker exec -e BAO_TOKEN openbao bao policy list
docker exec -e BAO_TOKEN openbao bao auth list
ls -l <secrets-dir>/
```

Confirm the root token really is gone:

```bash
curl -s http://127.0.0.1:8200/v1/auth/token/lookup-self -H "X-Vault-Token: <root-token>"
# expect: 403 — the token no longer exists
```

Prove a machine credential is genuinely read-only. Exchange it for a token, then confirm a write is
refused and a read is not:

```bash
BAO_ROLE_ID=$(cat <secrets-dir>/bao_role_id)
BAO_SECRET_ID=$(cat <secrets-dir>/bao_secret_id)
BAO_TOKEN=$(curl -s -X POST http://127.0.0.1:8200/v1/auth/approle/login \
  --data "{\"role_id\":\"$BAO_ROLE_ID\",\"secret_id\":\"$BAO_SECRET_ID\"}" | jq -r .auth.client_token)

curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8200/v1/kv/data/homelab/all/test \
  -H "X-Vault-Token: $BAO_TOKEN" --data '{"data":{"value":"x"}}'
# expect: 403

curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8200/v1/kv/data/homelab/all/base_domain \
  -H "X-Vault-Token: $BAO_TOKEN"
# expect: 200 (or 404 if that path was never written — either way, not 403)
```

## Updating & day-to-day

**Unsealing after a reboot is the routine operation here.** The vault seals itself every time the
container restarts — a host reboot, an image update, a crash, all of it. Nothing else in this guide
needs repeating after that: the secrets engine, the four policies, the login methods, the
administrator account and every machine credential all live inside the vault's own storage and survive
a restart intact. Only the in-memory encryption key needs reconstructing. Repeat Step 1 exactly:

```bash
curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq '.sealed'
# if true:
read -rs SHARE; echo
curl -s --request PUT --data "{\"key\":\"$SHARE\"}" http://127.0.0.1:8200/v1/sys/unseal | jq '{sealed, progress, t}'
# repeat with two more different shares
```

There is no automated unseal configured here, so budget for a human with the shares to be reachable
after any restart, or accept that everything depending on this vault stays down until someone runs
those commands.

**Changing the administrator's password:**

```bash
read -rs NEW_PASSWORD; echo
curl -s -X POST http://127.0.0.1:8200/v1/auth/userpass/users/<admin-user> \
  -H "X-Vault-Token: $BAO_TOKEN" --data "{\"password\":\"$NEW_PASSWORD\"}"
unset NEW_PASSWORD
```

**Rotating a machine credential**: the last block of Step 6, repeated for the one consumer whose
SecretID you want to replace.

**Adding a new automated consumer**: pick a name for it, write a policy for exactly what it needs
(Step 4's pattern), then run Step 6's block once with that name in place of `deploy`/`kestra`/
`backup`.

## Rollback / Uninstall

Nothing is installed on this host besides the credential files under `<secrets-dir>` — everything else
this guide creates lives inside the vault. Take a Raft snapshot first if there is anything worth
keeping; disabling the secrets engine below deletes every secret under it beyond recovery.

```bash
docker exec -e BAO_TOKEN openbao bao secrets disable kv
docker exec -e BAO_TOKEN openbao bao auth disable approle
docker exec -e BAO_TOKEN openbao bao auth disable userpass
docker exec -e BAO_TOKEN openbao bao policy delete admin
docker exec -e BAO_TOKEN openbao bao policy delete deploy-read
docker exec -e BAO_TOKEN openbao bao policy delete backup
docker exec -e BAO_TOKEN openbao bao policy delete kestra-read

rm -f <secrets-dir>/bao_role_id <secrets-dir>/bao_secret_id \
      <secrets-dir>/kestra_role_id <secrets-dir>/kestra_secret_id \
      <secrets-dir>/backup_role_id <secrets-dir>/backup_secret_id
```

## Troubleshooting

**`Vault is sealed` (503) on every call**
The container restarted since the last unseal. Repeat Step 1.

**`Still sealed after N share(s)` and the count will not advance**
A share was pasted twice. The threshold only advances on genuinely distinct shares — get a third,
different one.

**`permission denied` (403) on every bootstrap call**
The token in `$BAO_TOKEN` is not the root token or an `admin`-policy token, or it expired. If it was
the root token and it is now missing, regenerate one with `bao operator generate-root` and a quorum of
unseal shares.

**A policy you rewrote here does not match what is actually enforced**
Someone changed it directly against the running vault since you last wrote it here (by hand, or from a
different copy of this guide). Decide which text is correct and rewrite it with Step 4's `curl` — the
vault always enforces whatever was written to it last, there is no separate source of truth it falls
back to.

**`400` on a `userpass` login, "invalid username or password"**
Either value is wrong, or repeated failed attempts tripped the vault's built-in lockout for that
account — wait it out rather than retrying immediately.

**A machine credential's login fails with "invalid role or secret ID"**
The SecretID was revoked or the role itself was deleted. Re-issue it with Step 6.

**A scheduled job using the `backup` credential starts getting `403` on `sys/storage/raft/snapshot`**
Either the `backup` policy drifted from what Step 4 wrote, or that credential's SecretID was revoked.
Rewrite the policy and reissue the credential.
