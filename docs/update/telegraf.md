# Role: telegraf

## Purpose

Deploys the Telegraf metrics collection agent as a Docker container. Telegraf collects system metrics (CPU, memory, disk, network, Docker stats) from the host and ships them to InfluxDB. The container runs as the `telegraf` user combined with the host's `pgid` group and has access to the `video` group for GPU metrics. The host filesystem is mounted read-only so Telegraf can access `/proc`, `/sys`, and other virtual filesystems.

## Prerequisites

- `common` role must have run.
- `influxdb` role must have run and been configured (API token, org, bucket).
- Variables: `telegraf.*`, `pgid`, `influxdb.*`.

## Manual Execution Guide

### Step-by-Step Instructions

#### Step 1: Create the data directory

```bash
mkdir -p ./data/telegraf
chown <username>:docker ./data/telegraf
chmod 0755 ./data/telegraf
```

---

#### Step 2: Generate telegraf.conf

The configuration is generated from `telegraf/templates/telegraf.conf.j2`. It defines input plugins (cpu, mem, disk, diskio, net, docker, etc.) and an InfluxDB v2 output. The actual template content determines which plugins are enabled; the key variables are:

| Variable | Example | Description |
|----------|---------|-------------|
| `influxdb.url` | `https://influxdb.your-domain.com` | InfluxDB endpoint |
| `influxdb.api_token` | `<secret>` | InfluxDB write token |
| `influxdb.organization` | `<org-name>` | InfluxDB organization |
| `influxdb.bucket` | `<bucket-name>` | InfluxDB bucket |

Place the rendered config at `./data/telegraf/telegraf.conf`.

---

#### Step 3: Start the Telegraf container

```bash
# Get the pgid value from host_vars (e.g., 100 for NAS, 1002 for monitor)
PGID=100

sudo docker run -d \
  --name telegraf \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  --user "telegraf:${PGID}" \
  --group-add video \
  -e TZ=Europe/Belgrade \
  -e HOST_ETC=/hostfs/etc \
  -e HOST_PROC=/hostfs/proc \
  -e HOST_SYS=/hostfs/sys \
  -e HOST_VAR=/hostfs/var \
  -e HOST_RUN=/hostfs/run \
  -e HOST_MOUNT_PREFIX=/hostfs \
  -v /:/hostfs:ro \
  -v /etc:/hostfs/etc:ro \
  -v /proc:/hostfs/proc:ro \
  -v /sys:/hostfs/sys:ro \
  -v /var/run/utmp:/var/run/utmp:ro \
  -v $(pwd)/data/telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  telegraf:latest
```

Static IPs per host:
- Monitor: `<docker-ip>` (see `host_vars/primary_monitor.yml`)

---

## Configuration Reference

### Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `telegraf.static` | `<docker-ip>` | Static IP on proxy network |
| `telegraf_agent_interval` | `10s` (default) / `30s` | Gather+flush interval. Raise on hosts where docker uses fuse-overlayfs — per-gather file access is amplified through FUSE and pins the fuse-overlayfs process CPU at 10s |
| `docker_storage_driver` | `""` / `fuse-overlayfs` | Read from the common role's var. When `fuse-overlayfs`, the container gets `SKIP_SYSTEM_DF=true` so `docker-images.sh` never calls `/system/df` — that endpoint makes dockerd walk layers through the FUSE mount, the walk survives the client timeout, and stacked walks pin fuse-overlayfs at 100% CPU and balloon dockerd memory. `reclaimable_bytes` reports 0 on such hosts |
| `pgid` | `100` (NAS) / `1002` (monitor) | GID telegraf container runs with |
| `influxdb.*` | see influxdb.md | InfluxDB connection settings |

---

## Verification

```bash
sudo docker ps | grep telegraf
sudo docker logs telegraf --tail 20
# Check InfluxDB has received data
curl -H "Authorization: Token <secret>" \
  "https://influxdb.your-domain.com/api/v2/query?org=<org-name>" \
  -H "Content-Type: application/vnd.flux" \
  --data 'from(bucket:"<bucket-name>") |> range(start:-5m) |> limit(n:1)'
```

---

## Rollback / Uninstall

```bash
sudo docker stop telegraf && sudo docker rm telegraf
rm -rf ./data/telegraf
```

---

## Troubleshooting

**"permission denied reading /proc"**
Telegraf needs `pid_mode: host` or appropriate group permissions. The `HOST_PROC` environment variable redirects Telegraf to `/hostfs/proc` which is the bind-mounted host `/proc`. If still failing, check that the `/hostfs:ro` mount propagation is correct.

**No data in InfluxDB**
Check Telegraf logs for output plugin errors: `sudo docker logs telegraf | grep -i error`. Verify the InfluxDB token is valid and has write permissions to the `telegraf` bucket.

**`[inputs.exec] command timed out for command ".../docker-images.sh"`**
Not the socket — the script's `/system/df` call (reclaimable-bytes) walks every image layer/volume and on LXC over overlay/fuse-overlayfs could exceed the exec timeout, which telegraf then kills (`Error terminating process: os: process already finished` is the kill race). Restarting telegraf does **not** help. The script bounds each curl with `--connect-timeout 2 --max-time 4`, so a slow `df` returns `reclaimable_bytes=0` instead of hanging the run; the exec `timeout` is set to `30s` because the three bounded curls can still sum past 10s under load. Confirm which call is slow:
```bash
docker exec telegraf sh -c 'time curl -s --unix-socket /var/run/docker.sock http://localhost/v1.43/system/df -o /dev/null'
docker exec telegraf sh -c 'time curl -s --unix-socket /var/run/docker.sock "http://localhost/v1.43/images/json?all=true" -o /dev/null'
```
Then redeploy: `ansible-playbook update/<host>.yml --tags telegraf` (the script is bind-mounted, so a plain `docker restart telegraf` also picks up the new file).

**`[inputs.diskio] Unable to gather disk name for "sdX": no such file or directory`**
Cosmetic on LXC guests — the guest sees the Proxmox host's block devices in `/proc/diskstats` but has no matching `/dev` nodes, so name resolution fails. Metrics are still collected under the raw kernel names. Two role knobs control the plugin. **The plugin is OFF by default** — LXC guests own no real block device, so filesystem usage is left to `[[inputs.disk]]` and diskio is disabled everywhere unless a host opts in:

- `telegraf_diskio_enabled: true` — turn the plugin on for a host with real disks. Currently only `primary_nas` (media drives).
- `telegraf_diskio_devices: ["sda", "sdb"]` — allow-list the host's real devices to drop host-disk noise. Get the names with `lsblk -dno NAME` or `ls /dev | grep -E 'sd|nvme|vd|mmc'` on that host.

Redeploy with `--tags telegraf` after changing either.
