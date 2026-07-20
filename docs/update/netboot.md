# Role: netboot

## Purpose

This role deploys **netboot.xyz** — a network boot server that allows booting operating system installers, live environments, and utilities over the local network (PXE/iPXE). It exposes a TFTP server on UDP port 69 (for PXE boot), an HTTP server on port 80 (for serving boot assets), and a web management UI on port 8080.

This enables any machine on the local network with PXE boot capability to boot directly into OS installers (Ubuntu, Debian, Windows PE, etc.) without needing a physical USB drive.

## Prerequisites

- `common` and `traefik` roles must have run.
- The `netboot.*` variable block must be defined in the relevant host_vars file.
- Ports 69/UDP (TFTP) must be open at the firewall level — this is typically a host-level rule, not handled by UFW container rules.
- The `proxy` and `streamingMedia` Docker networks must exist.

## Manual Execution Guide

### Overview

1. Create the data directory for netboot configuration and assets.
2. Start the netboot.xyz container with TFTP and HTTP ports published.

---

### Step-by-Step Instructions

#### Step 1: Create the data directory

**Purpose**: netboot.xyz uses a config directory to store custom menu entries and an assets directory to cache downloaded boot images locally (avoiding repeated downloads from the internet).

```bash
sudo mkdir -p ./data/netboot
sudo chown <user>:<group> ./data/netboot
sudo chmod 0755 ./data/netboot
```

Replace `<user>` and `<group>` with the values from `user.name` and `user.group` in the inventory (e.g., `<username>:docker`).

The subdirectories (`config/` and `assets/`) are created automatically by the container on first run.

---

#### Step 2: Start the netboot.xyz container

**Purpose**: Run the netboot.xyz server. Port 69/UDP serves TFTP boot files to PXE clients. Port 8080 (mapped from internal port 80) serves the web management UI where you can customize boot menus.

```bash
sudo docker run -d \
  --name netbootxyz \
  --restart unless-stopped \
  --network proxy \
  --network streamingMedia \
  --ip <netboot-streaming-ip> \
  -e MENU_VERSION=2.0.59 \
  -v ./data/netboot/config:/config \
  -v ./data/netboot/assets:/assets \
  -p 69:69/udp \
  -p 8080:80 \
  --label traefik.enable=true \
  --label "traefik.http.routers.netbootxyz.entrypoints=https" \
  --label "traefik.http.routers.netbootxyz.rule=<netboot-host-rule>" \
  --label "traefik.http.routers.netbootxyz.tls=true" \
  --label "traefik.http.services.netbootxyz.loadbalancer.server.port=<netboot-port>" \
  ghcr.io/netbootxyz/netbootxyz
```

**Explanation of ports**:

| Published port | Protocol | Purpose |
|----------------|----------|---------|
| `69` | UDP | TFTP — serves the initial iPXE boot file to PXE clients |
| `8080` → `80` | TCP | netboot.xyz web management UI |

**Explanation of `MENU_VERSION`**: Pins the netboot.xyz menu version to `2.0.59`. Without this, the container may use a rolling `latest` menu version, which can change OS options and menu layout unexpectedly. Setting a specific version provides stable, reproducible boot menus.

> **Note on dual networks**: In Ansible, the `docker_container` module attaches to both `proxy` and `streamingMedia` networks. The static IP applies to the `streamingMedia` network. In Docker CLI, specify `--network proxy` at creation and then connect to `streamingMedia` separately:

```bash
sudo docker network connect --ip <netboot-streaming-ip> streamingMedia netbootxyz
```

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `netboot.host` | `Host(\`netboot.example.com\`)` | Traefik routing rule for the web UI |
| `netboot.port` | `80` | Internal web UI port (Traefik load balancer target) |
| `netboot.ip` | `<streaming-static-ip>` | Static IP on the streamingMedia network |

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `MENU_VERSION` | `2.0.59` | Pins the netboot.xyz menu to a specific release version |

### Volumes

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `./data/netboot/config` | `/config` | Custom menu entries and configuration overrides |
| `./data/netboot/assets` | `/assets` | Cached boot images (ISOs, kernels) for local serving |

---

## Handlers & Service Management

This role has no Ansible handlers. The container manages itself via Docker's `unless-stopped` restart policy.

```bash
# Restart
sudo docker restart netbootxyz

# View logs
sudo docker logs netbootxyz --tail 100
```

---

## Verification

```bash
# Confirm the container is running
sudo docker ps | grep netbootxyz

# Verify TFTP port is listening (from the host)
ss -ulnp | grep :69

# Access the web UI
curl -sk https://<netboot-domain>/ | head -5

# Test TFTP from another machine on the network
tftp <host-ip> -c get netboot.xyz.kpxe
```

**PXE boot test**: Configure a test machine or VM to PXE boot from this server's IP. The machine should receive an iPXE script via TFTP and display the netboot.xyz OS selection menu.

---

## Rollback / Uninstall

```bash
sudo docker stop netbootxyz
sudo docker rm netbootxyz
sudo rm -rf ./data/netboot
```

Removing `./data/netboot` deletes any custom menu configurations and cached assets. Cached ISOs may be several gigabytes — confirm disk usage with `du -sh ./data/netboot/assets` before removing.

---

## Troubleshooting

**PXE clients cannot find the boot server**
Verify that:
1. Port 69/UDP is published on the host (`sudo docker port netbootxyz` or `ss -ulnp | grep 69`).
2. Your DHCP server is configured to point PXE clients to this host as the next-server/boot server. Most consumer routers do not support DHCP option 66/67 — you may need a dedicated DHCP server (dnsmasq, ISC DHCP) or a router running dd-wrt/OpenWrt.

**Web UI is not accessible via Traefik**
The Traefik label `loadbalancer.server.port` should point to the internal container port 80 (or whatever `netboot.port` is set to). Verify: `sudo docker exec netbootxyz ss -tlnp | grep 80`.

**Asset downloads are slow or fail**
netboot.xyz downloads OS images from the internet when a user selects them during PXE boot. If the assets directory is populated (by pre-caching images via the web UI), the container serves them locally, avoiding internet downloads at boot time. Use the web UI's "Local Assets" feature to pre-cache commonly used images.

**`MENU_VERSION` mismatch warnings**
If the running container's menu version differs from what is configured, restart the container to apply the pinned version.
