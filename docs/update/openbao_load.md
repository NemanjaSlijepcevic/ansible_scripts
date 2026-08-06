# OpenBao Configuration Sync

## What this is

This is the operation that copies every value out of the configuration files you keep off this host
— one shared file and one file per machine, together holding every domain, credential and setting
this homelab runs on — into OpenBao's key-value store, so that a consumer which wants to fetch a
secret from the vault instead of holding a private copy of it can find one there.

It is **populate-only**. Your configuration files stay the single source of truth; nothing on any
machine has been switched over to reading from the vault at deploy time by this procedure alone, and
no deploy anywhere is blocked by the vault being unreachable — the vault only ever receives a copy, it
never feeds one back. Writing is also change-only: the current value under each path is read first and
compared to what would be written, and a write only happens when a value is missing or different, so a
value that has not changed since the last sync produces no write. Run this twice in a row with nothing
changed in the source files, and the second run writes nothing at all.

Path convention, one secret per top-level entry:

```
a key from the shared settings file    ->  kv/homelab/all/<key>
a key from one machine's settings file ->  kv/homelab/<machine-name>/<key>
```

A key-value v2 secret has to be a JSON object. A value that is already a mapping — several related
fields grouped together, like a set of named URLs — is written with its own fields intact. Anything
else — a plain string, a number, a list — is wrapped as `{"value": <the value>}` before it is sent.

Per-machine values are written **fully resolved**: if a setting for one machine embeds another
machine's address or a value from the shared file, what lands in the vault is the final, computed
value, not an unresolved reference to it — a consumer reading the vault gets something it can use
immediately, not something it would need your own configuration tooling to finish evaluating. The
shared file, by contrast, is written exactly as typed. Several machines override individual pieces of
the shared settings for themselves, and resolving the shared file through any one machine's context
would silently bake that one machine's override into the copy every other machine also reads from
`kv/homelab/all/`.

## Before you start

**The vault is running, unsealed, has its key-value store mounted, and you have an account able to
write to it**

```bash
curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq '{initialized, sealed}'
# expect initialized=true, sealed=false — if not, unseal it first (see the vault's own setup steps)

read -rs ADMIN_PASSWORD; echo
BAO_TOKEN=$(curl -s -X POST http://127.0.0.1:8200/v1/auth/userpass/login/<admin-user> \
  --data "{\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.auth.client_token')
export BAO_TOKEN
unset ADMIN_PASSWORD

curl -s http://127.0.0.1:8200/v1/sys/mounts -H "X-Vault-Token: $BAO_TOKEN" | jq 'keys'
# expect "kv/" in the list
```

If either check fails, the vault has not been through its own one-time setup yet — that has to happen
before there is anywhere for this sync to write to.

**`jq` is available**, to build and read the JSON payloads used throughout this guide:

```bash
jq --version
```

**You know where every configuration file currently lives**: one shared file, plus one file per
machine, kept somewhere off this host. Their contents are read and sent over the API; the files
themselves are never copied onto this machine as part of this process.

## Setup

### Overview

1. Authenticate and keep the token for the rest of the run.
2. For each entry in the shared file, compare the vault's current copy against the source and write
   it only if it differs.
3. For each machine, do the same against its own file, resolving any value that references another
   machine first.

---

#### Step 1: Authenticate

```bash
read -rs ADMIN_PASSWORD; echo
BAO_TOKEN=$(curl -s -X POST http://127.0.0.1:8200/v1/auth/userpass/login/<admin-user> \
  --data "{\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.auth.client_token')
export BAO_TOKEN
unset ADMIN_PASSWORD

curl -s http://127.0.0.1:8200/v1/auth/token/lookup-self -H "X-Vault-Token: $BAO_TOKEN" | jq '.data.policies'
```

**Explanation**: This sync ships the entire contents of every configuration file over the wire, so it
runs on the vault's own host, against its loopback address, and never through the public domain — none
of it should ever cross a network hop it does not have to. A root token is deliberately not an option
here: it should already be retired once an administrator account exists, and this operation only ever
needs the ability to write under `kv/data/*`, never full control of the vault.

---

#### Step 2: Write the shared settings

For each top-level entry in the shared configuration file:

```bash
KEY=<key>
VALUE_JSON='<the value from the shared file, as JSON — a mapping as-is, anything else wrapped as {"value": ...}>'

CURRENT=$(curl -s http://127.0.0.1:8200/v1/kv/data/homelab/all/$KEY -H "X-Vault-Token: $BAO_TOKEN")

if [ "$(echo "$CURRENT" | jq -c '.data.data // {}')" != "$(echo "$VALUE_JSON" | jq -c .)" ]; then
  curl -s -X POST http://127.0.0.1:8200/v1/kv/data/homelab/all/$KEY \
    -H "X-Vault-Token: $BAO_TOKEN" \
    --data "{\"data\":$VALUE_JSON}"
fi
```

**Explanation**: The read-and-compare before the write is what keeps this operation safe to run
repeatedly. Key-value v2 secrets are versioned — every write keeps the old value and adds a new one on
top of it — so writing unconditionally on every run would mean the version history behind every one of
these secrets grows forever, almost all of it identical copies of the same unchanged value. Reading
first and writing only on a genuine difference means a run in which nothing changed produces zero new
versions.

Repeat this for every entry in the shared file. A value that is already a mapping is sent with its own
fields intact; anything else — a string, a number, a list — is wrapped in `{"value": ...}` first, since
the key-value engine only ever stores JSON objects, never a bare scalar.

---

#### Step 3: Write each machine's settings

Repeat Step 2's read-compare-write once per machine, targeting `kv/homelab/<machine-name>/<key>`
instead of `kv/homelab/all/<key>`, reading from that machine's own configuration file as the source.
Resolve every value fully before building `VALUE_JSON` — if a value embeds another machine's address
or a shared setting, substitute the real value in before sending it, rather than sending the reference
unresolved.

**Explanation**: This has to run once per machine, and any value that references another machine has
to be resolved from the *referenced* machine's own context, not from wherever this sync happens to be
running — "the workflow engine's own address on the database server" only means something once you
know which machine's perspective it is being read from. That is also why the shared file in Step 2 is
handled differently: it has no single owning machine, several machines override pieces of it for
themselves, and resolving it through any one machine's context would capture that one machine's
override under a name every other machine also reads.

A configuration file for a machine that no longer exists can still be written — under its own file
name as the scope — but it has no machine to resolve a cross-reference *from*, so send it exactly as
written, unresolved. Treat its continued presence as a cleanup reminder: nothing reads it at deploy
time either.

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<admin-user>` | The administrator account to authenticate as | The account created during the vault's own one-time setup | Before you start, Step 1 |
| `<key>` | A top-level entry name in a configuration file | Whatever the entry is called in the source file | Steps 2, 3 |
| `<machine-name>` | A machine's own scope name under `kv/homelab/` | The name that file is kept under in your configuration | Step 3 |

## Verification

Everything landed:

```bash
docker exec -e BAO_TOKEN openbao bao kv list kv/homelab/
docker exec -e BAO_TOKEN openbao bao kv list kv/homelab/<machine-name>/
```

A resolved per-machine value really is resolved — no unresolved reference left inside it:

```bash
docker exec -e BAO_TOKEN openbao bao kv get kv/homelab/<machine-name>/<key>
```

Running the sync twice writes nothing the second time — check a version count before and after an
unchanged run:

```bash
docker exec -e BAO_TOKEN openbao bao kv metadata get kv/homelab/<machine-name>/<key>
# note "current_version", re-run the whole sync, check again — it should be unchanged
```

## Updating & day-to-day

**Re-run after any configuration file changes.** Only the entries that actually changed get a new
version; everything else is a no-op read.

**Never sync the one value that decrypts your configuration files themselves**, if you keep one. Skip
it explicitly in Step 2 rather than sending it. Writing it into the vault creates a circular
dependency: the value that protects your source-of-truth configuration would then be readable by
anyone who can read the vault it seeded, which defeats the reason it was kept separate in the first
place.

**Preview without writing anything**: run Steps 2 and 3 with the `curl -X POST` write calls removed or
commented out — the read-and-compare half alone tells you exactly which paths would change, without
sending anything.

## Rollback

Nothing on any machine changes — the only effect of this sync is inside the vault's key-value store.
To undo one scope:

```bash
docker exec -e BAO_TOKEN openbao bao kv metadata delete kv/homelab/<machine-name>/<key>
```

`kv metadata delete` removes the secret and every one of its past versions outright; `kv delete` on its
own only soft-deletes the latest version and leaves the history recoverable. A Raft snapshot of this
vault taken before the run restores the whole store, including everything this sync ever wrote.

## Troubleshooting

**`sys/seal-status` shows `sealed: true`, or `initialized: false`**
The vault restarted since it was last unsealed, or has never been through its own setup. Unseal it (or
run its one-time setup) before this sync can write anything.

**`No secrets engine mounted at kv/`**
The vault's key-value engine was never enabled. That is part of the vault's own one-time setup, not
this sync — do that first.

**`400` on login, "invalid username or password"**
The username is wrong more often than the password — it has no default derived from anything in this
guide, it is whatever account you created for the vault. Double-check it.

**`403` on the write calls**
The account's policy has no `create`/`update` capability on `kv/data/*`. Log in with an account that
has full control instead, or grant that capability to the one you are using.

**A value read back from the vault still contains an unresolved reference to another machine**
A per-machine value was written without resolving it first (Step 3), or the machine has no match in
your current configuration, in which case it is written unresolved on purpose — see the note at the
end of Step 3.

**Every re-run reports changes even though nothing was meant to change**
Either a value genuinely drifts on its own (a timestamp, a freshly generated secret in the source
file), or its JSON type changed between runs — a string `"8200"` one time and a bare number `8200` the
next look identical to a human and different to the comparison. Pull the current value with `bao kv
get -format=json` and compare it byte-for-byte against what the source file actually contains.

**Values under `kv/homelab/all/` change right after syncing one machine's file**
That should not happen — the shared scope only ever tracks the shared file. If it does, check that the
write in Step 2 is actually targeting `kv/homelab/all/`, not the machine's own scope, for that entry.
