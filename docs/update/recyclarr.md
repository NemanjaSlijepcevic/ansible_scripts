# Role: recyclarr

## Purpose

Deploys [Recyclarr](https://recyclarr.dev/) as a Docker container — it syncs [TRaSH Guides](https://trash-guides.info/) quality profiles, custom formats, and scoring into Sonarr and Radarr. The container runs a nightly cron sync; the role also triggers an immediate `recyclarr sync` after deployment.

## Prerequisites

- `common` role must have run.
- `sonarr` and `radarr` roles deployed and reachable (their API keys are consumed).
- Variables: `user.*`, `radarr.api_key`, `radarr.port`, `sonarr.api_key`, `sonarr.port`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the config directory

```bash
mkdir -p ./data/recyclarr
chown <username>:docker ./data/recyclarr
chmod 0755 ./data/recyclarr
```

---

#### Step 2: Render `recyclarr.yml`

Generated from `recyclarr/templates/recyclarr.yml.j2`. It defines `sonarr:` and `radarr:` instances pointing at the sibling services by container name, plus the TRaSH custom-format and quality-profile selections. Key values:

| Placeholder | Example | Description |
|-------------|---------|-------------|
| Sonarr base URL | `http://sonarr:8989` | Sibling service (container name) |
| `sonarr.api_key` | `<secret>` | Sonarr API key |
| Radarr base URL | `http://radarr:7878` | Sibling service |
| `radarr.api_key` | `<secret>` | Radarr API key |

Place the rendered file at `./data/recyclarr/recyclarr.yml`.

> The long hex strings in the template (e.g. `47435ece...`) are **public TRaSH-Guide custom-format IDs**, not secrets.

---

#### Step 3: Start the container and run an initial sync

```bash
sudo docker run -d \
  --name recyclarr \
  --restart unless-stopped \
  --network proxy \
  -e TZ=Europe/Belgrade \
  -e CRON_SCHEDULE='0 3 * * *' \
  -v $(pwd)/data/recyclarr:/config \
  ghcr.io/recyclarr/recyclarr:latest

# Trigger an immediate sync
sudo docker exec recyclarr recyclarr sync
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `radarr.api_key` / `radarr.port` | `<secret>` / `7878` | Radarr connection |
| `sonarr.api_key` / `sonarr.port` | `<secret>` / `8989` | Sonarr connection |
| `user.name` / `user.group` | `<username>` / `docker` | Owner of the config dir |

> Recyclarr has no web UI and no Traefik labels — it is a background sync job only.

---

## Verification

```bash
sudo docker ps | grep recyclarr
sudo docker exec recyclarr recyclarr sync   # should print applied formats/profiles
sudo docker logs recyclarr --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop recyclarr && sudo docker rm recyclarr
rm -rf ./data/recyclarr
```

---

## Troubleshooting

**`sync` fails with 401 / connection refused**
The API key or base URL for Sonarr/Radarr is wrong. Recyclarr reaches them by container name on the `proxy` network (`http://sonarr:8989`), so all three must be on that network and the target services healthy.

**Changes not visible in Sonarr/Radarr**
A sync only applies the profiles/formats referenced in `recyclarr.yml`. Confirm the quality profile names in the template match those configured in the target app.
