# Ansible Scripts Documentation

This directory contains hand-written Markdown manuals for every Ansible role in this repository. Each manual explains what the role does, the exact shell commands to replicate its work manually, the variables it consumes, and how to verify, troubleshoot, and reverse the changes.

All examples use **placeholder values** (e.g. `<ip-address>`, `<username>`, `<secret>`, `your-domain.com`, `<docker-ip>`) — never real inventory data — matching the `defaults/main.yml` convention.

## Repository Structure

The repository is split into two playbook families:

- **`client/`** — Bootstraps a brand-new Linux machine (user accounts, SSH hardening, firewall, Docker).
- **`update/`** — Deploys and keeps up-to-date a set of Docker-based self-hosted services across four hosts: **server**, **nas**, **monitor**, and **postgres**.

## Hosts

| Alias | IP | Role |
|-------|----|------|
| `primary_server` | `<ip-address>` | Public-facing server (web apps, reverse proxy) |
| `primary_nas` | `<ip-address>` | Network-attached storage (media, Samba, arr stack) |
| `primary_monitor` | `<ip-address>` | Monitoring/home-automation host |
| `primary_postgres` | `<ip-address>` | Dedicated PostgreSQL database server |
| `primary_immich` | `<ip-address>` | Immich photo-backup host |
| `primary_netboot` | `<ip-address>` | netboot.xyz network-boot host |
| `primary_automation` | `<ip-address>` | Kestra workflow orchestration + Claude Code sandbox host |
| `primary_openbao` | `<ip-address>` | OpenBao secrets-management server (Raft storage) |

## Baseline stack (every `update/` host)

`common` → `traefik` → `authelia` → `crowdsec` → `alloy` run on every host before any host-specific services. `alloy` is the single agent that ships both metrics and logs. See the individual manuals and `../CLAUDE.md` ("Per-Machine Baseline Stack") for the data-store topology (Postgres over mutual TLS, Alloy→Prometheus for metrics, Alloy→Loki for logs, plus Prometheus's own scrapes of the Proxmox and pfSense exporters, which cannot push).

---

## Client Roles (machine bootstrapping)

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `install_packages` | [install_packages.md](client/install_packages.md) | Updates apt, installs baseline packages, enables unattended upgrades |
| `prepare_ssh` | [prepare_ssh.md](client/prepare_ssh.md) | Enables SSH, creates an `ssh` group, and sets up drop-in config directory |
| `create_new_users` | [create_new_users.md](client/create_new_users.md) | Creates system users, deploys SSH keys, configures sudoers |
| `protect_ssh` | [protect_ssh.md](client/protect_ssh.md) | Hardens SSHD (no root, no password auth) and sets up auth log rotation |
| `prepare_firewall` | [prepare_firewall.md](client/prepare_firewall.md) | Resets and applies UFW rules from inventory, enables logging |
| `install_docker` | [install_docker.md](client/install_docker.md) | Installs Docker Engine, configures daemon.json, sets up log rotation |
| `clean_up` | [clean_up.md](client/clean_up.md) | Configures syslog rotation, purges orphan packages, reboots if required |

---

## Update Roles (Docker service deployment)

### Infrastructure / Platform

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `common` | [update/common.md](update/common.md) | UFW sync, Docker daemon config, `proxy` network creation |
| `traefik` | [update/traefik.md](update/traefik.md) | Deploys Traefik reverse proxy with Cloudflare DNS-01 TLS |
| `crowdsec` | [update/crowdsec.md](update/crowdsec.md) | Deploys CrowdSec IDS with Traefik and Cloudflare bouncers |
| `authelia` | [update/authelia.md](update/authelia.md) | Deploys Authelia SSO/2FA authentication portal |
| `postgres` | [update/postgres.md](update/postgres.md) | Deploys the central PostgreSQL server as a Docker container (`pgvector/pgvector:pg18`) with mutual-TLS client certs |
| `postgres_server` | [update/postgres_server.md](update/postgres_server.md) | Deploys a second, host-local PostgreSQL server as a Docker container on `server` (mutual TLS enforced, no published port/alias) |
| `prepare_postgres` | [update/prepare_postgres.md](update/prepare_postgres.md) | Creates PostgreSQL databases and users for applications |
| `pgadmin` | [update/pgadmin.md](update/pgadmin.md) | Deploys pgAdmin 4 web UI for the central PostgreSQL server |
| `prepare_smb` | [update/prepare_smb.md](update/prepare_smb.md) | Installs and configures Samba file sharing |
| `filebrowser` | [update/filebrowser.md](update/filebrowser.md) | Deploys the Filebrowser web file manager (Authelia proxy auth) |

### Monitoring & Observability

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `alloy` | [update/alloy.md](update/alloy.md) | Deploys Grafana Alloy: ships logs to Loki and metrics to Prometheus (runs on every host) |
| `prometheus` | [update/prometheus.md](update/prometheus.md) | Deploys Prometheus: remote-write receiver for every host's Alloy, plus scrapes of Proxmox and pfSense exporters |
| `pve_exporter` | [update/pve_exporter.md](update/pve_exporter.md) | Deploys `prometheus-pve-exporter`, bridging the Proxmox VE API to Prometheus's scrape model |
| `grafana` | [update/grafana.md](update/grafana.md) | Deploys Grafana dashboarding + alerting (Prometheus + Loki datasources, OIDC via Authelia) |
| `loki` | [update/loki.md](update/loki.md) | Deploys Loki log aggregation and registers it in Grafana |
| `kuma` | [update/kuma.md](update/kuma.md) | Deploys Uptime Kuma availability monitor |
| `public_ip_tracker` | [update/public_ip_tracker.md](update/public_ip_tracker.md) | Tracks and exposes the host's current public IP |
| `public_ip_whitelist_updater` | [update/public_ip_whitelist_updater.md](update/public_ip_whitelist_updater.md) | Keeps Traefik's IP whitelist updated with the current public IP |
| `log_notification` | [update/log_notification.md](update/log_notification.md) | Sends Telegram alerts on log pattern matches |

### Media Stack

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `jellyfin` | [update/jellyfin.md](update/jellyfin.md) | Deploys Jellyfin media server |
| `seerr` | [update/seerr.md](update/seerr.md) | Deploys Seerr media-request manager (Postgres mTLS, Authelia OIDC) |
| `sonarr` | [update/sonarr.md](update/sonarr.md) | Deploys Sonarr TV show manager with Transmission and Prowlarr integration |
| `radarr` | [update/radarr.md](update/radarr.md) | Deploys Radarr movie manager with Transmission and Prowlarr integration |
| `lidarr` | [update/lidarr.md](update/lidarr.md) | Deploys Lidarr music manager with Transmission and Prowlarr integration |
| `bazarr` | [update/bazarr.md](update/bazarr.md) | Deploys Bazarr subtitle manager |
| `prowlarr` | [update/prowlarr.md](update/prowlarr.md) | Deploys Prowlarr indexer manager |
| `recyclarr` | [update/recyclarr.md](update/recyclarr.md) | Syncs TRaSH-Guide profiles/formats into Sonarr and Radarr |
| `transmission` | [update/transmission.md](update/transmission.md) | Deploys Transmission BitTorrent client |
| `netboot` | [update/netboot.md](update/netboot.md) | Deploys netboot.xyz network boot server |
| `openbao` | [update/openbao.md](update/openbao.md) | Deploys OpenBao secrets-management server (Raft storage) |

### Web Applications

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `ghost` | [update/ghost.md](update/ghost.md) | Deploys one or more Ghost blogging sites backed by MySQL/MariaDB |
| `immich` | [update/immich.md](update/immich.md) | Deploys the Immich photo-backup stack (server, ML, Postgres, Redis) |
| `homeassistant` | [update/homeassistant.md](update/homeassistant.md) | Deploys Home Assistant with Mosquitto MQTT broker |
| `family_trees` | [update/family_trees.md](update/family_trees.md) | Generates and serves static family-tree websites via nginx |
| `bibliography` | [update/bibliography.md](update/bibliography.md) | Deploys the custom Bibliography web app (SQLite-backed) |
| `kaleidoscope` | [update/kaleidoscope.md](update/kaleidoscope.md) | Deploys the Kaleidoscope custom Django photo application |
| `sql` | [update/sql.md](update/sql.md) | Deploys MySQL/MariaDB containers and Adminer database UI |

### Automation

| Role | Documentation | One-line description |
|------|--------------|----------------------|
| `socket_proxy` | [update/socket_proxy.md](update/socket_proxy.md) | Filtered Docker API proxy (tecnativa/docker-socket-proxy) gating Kestra's access to the host Docker daemon |
| `kestra` | [update/kestra.md](update/kestra.md) | Deploys Kestra workflow orchestration (stock image, Postgres mTLS via JDBC), drives task containers through socket-proxy |
| `claude_runner` | [update/claude_runner.md](update/claude_runner.md) | Builds the ephemeral Claude Code CLI sandbox image + isolated network launched by Kestra's Docker task runner |
| `ansible_runner` | [update/ansible_runner.md](update/ansible_runner.md) | Builds the ephemeral `ansible-playbook` sandbox image (reuses claude_runner's `sandbox` network) used by Kestra's AnsibleCLI tasks |

---

## Session Logs

Chronological change logs for larger working sessions live in `sessions/`:

| Date | Log | Scope |
|------|-----|-------|
| 2026-07-11 | [sessions/2026-07-11-kestra-migration.md](sessions/2026-07-11-kestra-migration.md) | n8n → Kestra migration, repo-managed flows, Grafana alert audit + new rules, Claude/Telegram alert triage |

---

## Common Patterns

- All `update/` service roles deploy Docker containers on the `proxy` Docker network with static IPs in the `<docker-subnet>` subnet.
- Traefik labels are applied to every container for automatic HTTPS routing via Cloudflare DNS-01.
- SSO is enforced by Traefik middleware chains: `chain-auth@file` forces Authelia login; `chain-no-auth@file` is used by services that handle their own auth (Immich, Seerr, pgAdmin).
- Services that use the central PostgreSQL connect over **mutual TLS** with per-service client certificates (`./data/certs/<service>.{crt,key}` + `ca.crt`).
- Log rotation is configured via a shared `logrotate.j2` template for any service that writes logs to a file.
- Health checks are defined on every container.
