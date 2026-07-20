# Role: transmission

## Purpose

Deploys Transmission (BitTorrent client) as a Docker container on the NAS host. Transmission handles all torrent downloads queued by Sonarr, Radarr, and Lidarr. Ports 51413 (TCP and UDP) are published directly on the host for peer-to-peer seeding. RPC authentication is disabled (`TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false`) because the container is only accessible through Traefik's authenticated middleware chain.

## Prerequisites

- `common`, `traefik` roles must have run.
- The download drive must be mounted at `download_drive`.
- UFW must allow port 51413 (not in the default rules — add manually if needed for seeding).
- Variables: `transmission.*`, `puid`, `pgid`, `download_drive`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/transmission
chown <username>:docker ./data/transmission
chmod 0755 ./data/transmission
```

---

#### Step 2: Start the Transmission container

```bash
sudo docker run -d \
  --name transmission \
  --restart unless-stopped \
  --network proxy \
  -e PUID=998 \
  -e PGID=100 \
  -e TZ=Europe/Belgrade \
  -e TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false \
  -v $(pwd)/data/transmission/config:/config \
  -v <download_drive>/Download:/downloads \
  -v <download_drive>/Download/Watch:/watch \
  -p 51413:51413 \
  -p 51413:51413/udp \
  --label traefik.enable=true \
  --label "traefik.http.routers.transmission.entrypoints=https" \
  --label "traefik.http.routers.transmission.rule=Host(\`transmission.your-domain.com\`)" \
  --label "traefik.http.routers.transmission.tls=true" \
  --label "traefik.http.services.transmission.loadbalancer.server.port=9091" \
  ghcr.io/linuxserver/transmission:latest
```

The `Watch` directory is a drop folder — any `.torrent` file placed there is automatically added to the queue.

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `transmission.host` | `Host(\`transmission.your-domain.com\`)` | Traefik router rule |
| `transmission.port` | `9091` | Transmission RPC/web UI port |
| `transmission.user` | `<username>` | RPC username (used by Sonarr/Radarr/Lidarr) |
| `transmission.password` | (secret) | RPC password |
| `download_drive` | `/srv/dev-disk-by-uuid-...` | Path to download storage |

Note: `TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false` means Transmission itself does not require credentials. The `transmission.user` and `transmission.password` variables are only used by Sonarr/Radarr/Lidarr when registering Transmission as their download client.

---

## Verification

```bash
sudo docker ps | grep transmission
curl http://localhost:9091/transmission/web/
sudo docker logs transmission --tail 20
```

---

## Rollback / Uninstall

```bash
sudo docker stop transmission && sudo docker rm transmission
rm -rf ./data/transmission
```

Downloaded files in `<download_drive>/Download` are not removed.

---

## Troubleshooting

**Seeding speeds are poor**
Ensure port 51413 (TCP and UDP) is open in UFW and is correctly forwarded in the router if the NAS is behind NAT.

**Sonarr/Radarr cannot connect to Transmission**
They connect by container name (`transmission`) on the proxy Docker network. Ensure all containers are on the same `proxy` network. Test: `sudo docker exec sonarr curl http://transmission:9091/transmission/rpc`.
