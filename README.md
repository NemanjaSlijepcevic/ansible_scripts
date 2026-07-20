# ansible_scripts Repository

Centralized Ansible automation for my homelab: bootstrapping new machines and
deploying/updating Docker-based services across a NAS, monitor, central
PostgreSQL, public server, and more.

Playbooks use the
[Alternative Directory Layout](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html#alternative-directory-layout):
each top-level directory carries its own inventory (`inventories/production/`)
with `hosts.yml`, `group_vars/all.yml`, and per-host `host_vars/`.

## Security stack (every host): Traefik (reverse proxy, TLS via Cloudflare DNS
challenge) → Authelia (SSO/2FA) → CrowdSec (IDS/bouncer) → services.

## Repository Structure

- **`client/`** — Bootstraps new machines: packages, users, SSH hardening,
  firewall, Docker.
- **`update/`** — Deploys/updates Docker services on existing hosts.
- **`docs/`** — Markdown manual for every role, with a manual-execution guide
  (indexed by `docs/README.md`).

## Client Playbook

`client/new.yml` provisions a fresh machine. It prompts for a username and
password, then runs the bootstrap roles in order:

`install_packages` → `prepare_ssh` → `create_new_users` → `protect_ssh` →
`prepare_firewall` → `install_docker` → `clean_up`

```bash
ansible-playbook client/new.yml --vault-password-file pass.file
```

## Update Playbooks

Every host first runs the baseline stack (`common`, `traefik`, `authelia`,
`crowdsec`, `telegraf`, `promtail`); host-specific services follow.

| Playbook | Host | Highlights |
| --- | --- | --- |
| `nas.yml` | NAS | `prepare_smb`, `prepare_postgres`, media stack (`jellyfin`, `transmission`, `*arr`, `seerr`, `recyclarr`), `filebrowser` |
| `monitor.yml` | Monitor | `influxdb`, `loki`, `grafana`, `homeassistant`, `public_ip_tracker`, `log_notification` |
| `postgres.yml` | PostgreSQL | `postgres`, `pgadmin` (+ `prepare_postgres` on client hosts) |
| `server.yml` | Server | `postgres_server`, `sql`, web apps (`ghost`, `bibliography`, `family_trees`, `kaleidoscope`), `filebrowser`, `public_ip_whitelist_updater` |
| `immich.yml` | Immich | `immich` photo stack + `prepare_postgres` |
| `netboot.yml` | Netboot | `netboot` + `prepare_postgres` |
| `automation.yml` | Automation | `kestra` (workflow orchestration, repo-managed flows: scheduled/on-merge infra updates, Ghost newsletter, Claude alert triage → Telegram), `socket_proxy` (filtered Docker API), `claude_runner` + `ansible_runner` (ephemeral sandbox images) |

```bash
ansible-playbook update/nas.yml     --vault-password-file pass.file
ansible-playbook update/monitor.yml --vault-password-file pass.file
ansible-playbook update/postgres.yml --vault-password-file pass.file
ansible-playbook update/server.yml  --vault-password-file pass.file
ansible-playbook update/automation.yml --vault-password-file pass.file
```

`update/ansible.cfg` sets the default inventory, so playbooks run from the
`update/` directory pick it up automatically.

### Common flags

```bash
# Only specific roles / hosts
ansible-playbook update/nas.yml --vault-password-file pass.file --tags jellyfin
ansible-playbook update/nas.yml --vault-password-file pass.file --limit primary_nas

# Dry run
ansible-playbook update/nas.yml --vault-password-file pass.file --check
```

Most roles in a playbook are commented out by default — uncomment a role to
include it in a run.

## Inventory & Secrets

- `group_vars/all.yml` — shared config.
- `host_vars/primary_*.yml` — per-host service configs .
- Sensitive values are stored in these files and meant to be **Ansible
  Vault**-encrypted; `pass.file` is gitignored and passed via
  `--vault-password-file`.
- Each role carries a `defaults/main.yml` with placeholder values that mirror
  the inventory shape it consumes — readable schema for the (encrypted) vars.

`.gitignore` protects generated key material by file type (`*.key`, `*.crt`,
`*.csr`, `*.pem`, `*.pub`, `*.sqlite*`, `*.db`). SSH private keys use the
`.pem` extension so they are caught; no keys are committed — `.pub` files are
gitignored too (their comments carry real usernames/emails).

## Requirements

- **Ansible** with the `community.docker` collection.
- **Ansible Vault** password file for decrypting inventory secrets.
