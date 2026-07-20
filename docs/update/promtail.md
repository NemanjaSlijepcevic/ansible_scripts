# Role: promtail

## Purpose

Deploys [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) as a Docker container — the log-shipping agent that runs on **every** host. Promtail tails Docker container logs (via the Docker socket), Traefik access logs, and host syslog files, then pushes them to the central Loki instance (on the `monitor` host). Each host tags its streams with a `node` label equal to `current_host`.

## Prerequisites

- `common` role must have run.
- `loki` role must be deployed and reachable (on the `monitor` host).
- `traefik` role (its logs at `./data/traefik/logs` are scraped).
- Variables: `user.*`, `loki_ingest_url`, `current_host`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the directories

```bash
mkdir -p ./data/promtail/state
chown -R <username>:docker ./data/promtail
chmod 0755 ./data/promtail
```

---

#### Step 2: Render the config

Generated from `promtail/templates/config.yml.j2`. It defines the Loki client endpoint and three scrape jobs (docker service discovery, Traefik file logs, host syslog files). Key values:

| Placeholder in template | Example | Description |
|-------------------------|---------|-------------|
| `loki_ingest_url` | `http://loki:3100/loki/api/v1/push` | Loki push endpoint (container name on proxy net) |
| `current_host` | `<hostname>` | Value of the `node` label on every stream |

Place the rendered file at `./data/promtail/config.yml` (mode `0644`).

---

#### Step 3: Start the Promtail container

```bash
sudo docker run -d \
  --name promtail \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/promtail/config.yml:/etc/promtail/config.yml:ro \
  -v $(pwd)/data/promtail/state:/data \
  -v /var/log:/var/log:ro \
  -v $(pwd)/data/traefik/logs:/srv/traefik-logs:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  grafana/promtail:latest \
  -config.file=/etc/promtail/config.yml
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `loki_ingest_url` | `http://loki:3100/loki/api/v1/push` | Where logs are shipped (usually a `group_vars` global) |
| `current_host` | `<hostname>` | Node label; set per playbook (`nas`/`server`/`monitor`/`postgres`) |
| `user.name` / `user.group` | `<username>` / `docker` | Owner of the data dirs |

> A container can opt out of shipping by setting the Docker label `loki_drop=true` (dropped in the relabel stage).

---

## Verification

```bash
sudo docker ps | grep promtail
sudo docker logs promtail --tail 20
# In Grafana → Explore → Loki: {node="<hostname>"} should return recent lines
```

---

## Rollback / Uninstall

```bash
sudo docker stop promtail && sudo docker rm promtail
rm -rf ./data/promtail
```

---

## Troubleshooting

**No logs arriving in Loki**
Check that `loki_ingest_url` resolves from inside the container (`docker exec promtail wget -qO- <loki>/ready`). Promtail buffers to `/data/positions.yaml`; a bad endpoint shows connection errors in `docker logs promtail`.

**Docker logs missing**
Promtail needs `/var/run/docker.sock` mounted (read-write here) for service discovery. Verify the socket mount and that the container was not dropped by a `loki_drop=true` label.
