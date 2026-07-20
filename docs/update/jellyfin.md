# Role: jellyfin

## Purpose

Deploys Jellyfin, the open-source media server, as a Docker container on the NAS host. Jellyfin serves music, pictures, videos, movies, and TV shows from the NAS storage drives. It is attached to the `proxy` network (for Traefik routing) and the `streamingMedia` macvlan network (for direct network access with a static IP on the LAN, enabling DLNA discovery and other broadcast-based protocols).

## Prerequisites

- `common` role must have run.
- `traefik` role must have run.
- The storage drives must be mounted at their configured paths (`data_drive`, `movie_drive`, `tv_drive`, `music_drive`).
- The `streamingMedia` Docker network must exist (macvlan network on the LAN).
- Variables: `jellyfin.*`, `puid`, `pgid`, `data_drive`, `movie_drive`, `tv_drive`, `music_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/jellyfin
chown <username>:docker ./data/jellyfin
chmod 0755 ./data/jellyfin
```

---

#### Step 2: Start the Jellyfin container

```bash
sudo docker run -d \
  --name jellyfin \
  --restart unless-stopped \
  --network proxy \
  --network streamingMedia \
  --ip-v4 <ip-address> \
  -e UID=998 \
  -e GID=100 \
  -e TZ=Europe/Belgrade \
  -v $(pwd)/data/jellyfin/config:/config \
  -v $(pwd)/data/jellyfin/cache:/cache \
  -v <music_drive>/Muzika:/music \
  -v <data_drive>/Slike:/pictures \
  -v <data_drive>/Snimci:/videos \
  -v <movie_drive>/Filmovi:/movies \
  -v <tv_drive>/Serije:/tv \
  --label traefik.enable=true \
  --label "traefik.http.routers.jellyfin.entrypoints=https" \
  --label "traefik.http.routers.jellyfin.rule=Host(\`jellyfin.your-domain.com\`)" \
  --label "traefik.http.routers.jellyfin.tls=true" \
  --label "traefik.http.services.jellyfin.loadbalancer.server.port=8096" \
  jellyfin/jellyfin:latest
```

Replace the UUID-based paths with actual values from `host_vars/primary_nas.yml` (`data_drive`, `movie_drive`, `tv_drive`, `music_drive`).

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `jellyfin.host` | `Host(\`jellyfin.your-domain.com\`)` | Traefik router rule |
| `jellyfin.port` | `8096` | Jellyfin web UI port |
| `jellyfin.ip` | `<ip-address>` | Static IP on the streamingMedia network |
| `puid` | `998` | UID Jellyfin runs as |
| `pgid` | `100` | GID Jellyfin runs as |
| `data_drive` | `/srv/dev-disk-by-uuid-...` | Drive containing Slike and Snimci |
| `movie_drive` | `/srv/dev-disk-by-uuid-...` | Drive containing Filmovi |
| `tv_drive` | `/srv/dev-disk-by-uuid-...` | Drive containing Serije |
| `music_drive` | `/srv/dev-disk-by-uuid-...` | Drive containing Muzika |

---

## Verification

```bash
sudo docker ps | grep jellyfin
curl -sk https://jellyfin.your-domain.com/health
sudo docker logs jellyfin --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop jellyfin && sudo docker rm jellyfin
rm -rf ./data/jellyfin
```

Media files are not deleted — only the container configuration is removed.
