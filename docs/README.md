# Documentation

One guide per service. Each guide is a **standalone manual tutorial**: someone with a shell on the host, who has never seen this repository, follows it top to bottom and ends up with the service running.

That independence is deliberate, and it shapes how the guides read:

- A guide never sends you to another guide. A dependency is stated as a fact about the host plus the command that proves it.
- Config files are printed in full, inline — never referenced as "the config file".
- Prerequisites are repeated in every guide that needs them. The repetition is the point.
- Every step explains *why*, not just what to type.

All examples use **placeholder values** — `<ip-address>`, `<username>`, `<docker-ip>`, `<secret>`, `<api-key>`, `<puid>`/`<pgid>`, `your-domain.com`. Never real data.

## Hosts

| Host | Address | What runs there |
|------|---------|-----------------|
| server | `<ip-address>` | Public-facing web applications and reverse proxy |
| nas | `<ip-address>` | Network-attached storage: media library, Samba, download and library management |
| monitor | `<ip-address>` | Metrics, logs, dashboards, home automation |
| postgres | `<ip-address>` | Central PostgreSQL database server |
| immich | `<ip-address>` | Photo-backup stack |
| netboot | `<ip-address>` | Network-boot server |
| automation | `<ip-address>` | Workflow orchestration and sandboxed task runners |
| openbao | `<ip-address>` | Secrets-management server |

## Baseline on every host

Five services run on every host before anything specific to it: the host baseline (firewall, Docker daemon, shared network), Traefik, Authelia, CrowdSec, and Grafana Alloy. Alloy is the single agent that ships both metrics and logs.

The data paths behind that:

- **Databases** — most services store their data in the central PostgreSQL server and connect over mutual TLS with a per-service client certificate. CrowdSec is the exception; it keeps its own embedded database.
- **Metrics** — every host's Alloy remote-writes to Prometheus, which is also the component that actively scrapes the Proxmox and pfSense exporters, since neither can push.
- **Logs** — every host's Alloy pushes to Loki.
- **Dashboards and alerts** — Grafana, reading from both Prometheus and Loki.

---

## Setting up a new machine

Follow these in order. Each one leaves the machine in a working state for the next.

| Guide | What it does |
|-------|--------------|
| [Base packages](client/install_packages.md) | Updates the package index, installs the baseline tool set, enables unattended security upgrades |
| [SSH service](client/prepare_ssh.md) | Enables the SSH daemon, creates the login group, sets up the drop-in config directory |
| [User accounts](client/create_new_users.md) | Creates accounts, installs SSH keys, configures sudo access |
| [SSH hardening](client/protect_ssh.md) | Disables root and password login, rotates the auth log |
| [Firewall](client/prepare_firewall.md) | Applies the firewall rule set and enables logging |
| [Docker](client/install_docker.md) | Installs Docker Engine, configures the daemon and log rotation |
| [Clean up](client/clean_up.md) | Configures syslog rotation, purges orphaned packages, reboots if required |

---

## Services

### Platform

| Guide | What it does |
|-------|--------------|
| [Host baseline](update/common.md) | Firewall sync, Docker daemon settings, the shared container network |
| [Traefik](update/traefik.md) | Reverse proxy with automatic HTTPS via a DNS-01 certificate challenge |
| [CrowdSec](update/crowdsec.md) | Intrusion detection, enforced as a Traefik middleware and at the CDN edge |
| [Authelia](update/authelia.md) | Single sign-on and two-factor authentication |
| [PostgreSQL (central)](update/postgres.md) | The shared database server, with mutual-TLS client certificates |
| [PostgreSQL (web host)](update/postgres_server.md) | A second, host-local database server for the public web applications |
| [Application databases](update/prepare_postgres.md) | Creates a database and login role per application |
| [pgAdmin](update/pgadmin.md) | Web administration UI for PostgreSQL |
| [MariaDB and Adminer](update/sql.md) | MariaDB instances and a lightweight database UI |
| [Samba](update/prepare_smb.md) | Windows-compatible file sharing |
| [Filebrowser](update/filebrowser.md) | Web file manager |

### Secrets

| Guide | What it does |
|-------|--------------|
| [OpenBao](update/openbao.md) | The secrets-management server, on Raft storage |
| [OpenBao setup](update/openbao_setup.md) | Unsealing, the key-value store, access policies, login methods, issued credentials |
| [Loading secrets](update/openbao_load.md) | Mirrors your source-of-truth configuration into the key-value store |

### Backups

Databases are dumped on each host, staged on an intermediate machine, then archived on the NAS with checksum verification.

| Guide | What it does |
|-------|--------------|
| [Database backups](update/db_backup.md) | Dumps PostgreSQL, MariaDB, SQLite and Raft snapshots, checksums them, stages them |
| [Backup archiving](update/db_backup_sync.md) | Pushes the staged dumps to the archive, verifies them, prunes old ones |

### Monitoring

| Guide | What it does |
|-------|--------------|
| [Alloy](update/alloy.md) | The per-host agent that ships logs and metrics |
| [Prometheus](update/prometheus.md) | Metrics store: receives from every host's agent, scrapes the hypervisor and firewall exporters |
| [Proxmox exporter](update/pve_exporter.md) | Bridges the hypervisor API into a scrapeable metrics endpoint |
| [Loki](update/loki.md) | Log aggregation |
| [Grafana](update/grafana.md) | Dashboards and alerting over both metrics and logs |
| [Uptime Kuma](update/kuma.md) | Availability monitoring |
| [Public IP tracker](update/public_ip_tracker.md) | Tracks and publishes the host's current public address |
| [Public IP allow-list](update/public_ip_whitelist_updater.md) | Keeps the proxy's IP allow-list pointed at the current public address |
| [Log notifications](update/log_notification.md) | Sends a chat alert when a log line matches a watched pattern |

### Media

| Guide | What it does |
|-------|--------------|
| [Jellyfin](update/jellyfin.md) | Media server |
| [Seerr](update/seerr.md) | Media request portal |
| [Sonarr](update/sonarr.md) | TV series management |
| [Radarr](update/radarr.md) | Film management |
| [Lidarr](update/lidarr.md) | Music management |
| [Bazarr](update/bazarr.md) | Subtitle management |
| [Prowlarr](update/prowlarr.md) | Indexer management |
| [Recyclarr](update/recyclarr.md) | Syncs community quality profiles into the library managers |
| [Transmission](update/transmission.md) | BitTorrent client |

### Web applications

| Guide | What it does |
|-------|--------------|
| [Ghost](update/ghost.md) | One or more blogging sites on MariaDB |
| [Immich](update/immich.md) | Photo and video backup stack |
| [Home Assistant](update/homeassistant.md) | Home automation with an MQTT broker |
| [Family trees](update/family_trees.md) | Generates and serves static genealogy sites |
| [Bibliography](update/bibliography.md) | Custom reading-list application |
| [Kaleidoscope](update/kaleidoscope.md) | Custom photo application |
| [Netboot](update/netboot.md) | Network-boot server |

### Automation

| Guide | What it does |
|-------|--------------|
| [Docker socket proxy](update/socket_proxy.md) | Filtered, read-mostly gateway to the host Docker API |
| [Kestra](update/kestra.md) | Workflow orchestration, driving task containers through the filtered gateway |
| [Claude Code sandbox](update/claude_runner.md) | Builds the throwaway image used for agentic runs |
| [Ansible sandbox](update/ansible_runner.md) | Builds the throwaway image used for playbook runs |

---

## Patterns you will see repeated

These hold across nearly every service guide, which is why the same paragraphs turn up in many of them:

- Containers sit on a shared bridge network with fixed addresses, and reach each other by container name rather than by address and port.
- Traefik routes to them by hostname, using labels set on the container itself, and terminates HTTPS with certificates obtained through a DNS-01 challenge.
- Access control is a proxy middleware chain: one chain forces a single-sign-on login, another passes traffic straight through for services that authenticate their own users.
- Services backed by the central database connect over mutual TLS, presenting a per-service client certificate stored alongside the shared authority certificate.
- Anything that writes its own log file also gets a rotation rule.
- Every container declares a health check, so a container that is up but broken is visible as such.
