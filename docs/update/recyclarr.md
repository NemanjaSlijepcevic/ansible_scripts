# Recyclarr

## What this is

Recyclarr keeps Sonarr's and Radarr's quality settings in sync with the TRaSH Guides. It downloads
the published custom-format definitions and pushes them, together with a quality profile and a
scoring table, into both applications over their APIs. The result is that a release group's
reputation, a codec, a repack flag and a resolution all become numbers that Sonarr and Radarr use to
decide what to grab and what to upgrade to.

It runs as a single container on the NAS machine, next to Sonarr and Radarr. It has **no web UI and
no reverse-proxy route** — nothing ever connects *to* it. It sits on the shared container network for
one reason only: so it can reach `http://sonarr:8989` and `http://radarr:7878` by name. Inside the
container a cron job runs the sync once a night; the rest of the time the container idles.

## Before you start

### Docker is installed and your account can use it

```bash
docker --version
docker compose version 2>/dev/null || true

# your account must be in the docker group, or every command below needs sudo
id -nG | tr ' ' '\n' | grep -qx docker && echo "docker group: ok" || echo "docker group: MISSING"
```

If the group is missing, add yourself and start a new login session:

```bash
sudo usermod -aG docker <username>
newgrp docker
```

If Docker itself is absent, install it from Docker's own repository (the distro package is usually
too old for the compose plugin) and enable the service:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

### The `./data` working directory exists

```bash
cd <deploy-dir>
mkdir -p ./data
sudo chown <username>:<pgid> ./data
sudo chmod 0755 ./data
```

Every service keeps its configuration and state in `./data/<service>` under this directory, and
every container path in these guides is bind-mounted from here. Run all commands from
`<deploy-dir>` so the relative paths resolve.

### The shared `proxy` bridge network exists

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows
where to send a request.

```bash
docker network inspect proxy >/dev/null 2>&1 && echo "proxy network: ok" || echo "proxy network: MISSING"
```

Create it if it is missing:

```bash
docker network create \
  --driver bridge \
  --subnet <docker-subnet> \
  --gateway <docker-gateway> \
  --ip-range <docker-ip-range> \
  proxy
```

The `--ip-range` is the pool Docker hands out automatically; keep fixed container addresses
**outside** that pool so nothing is ever assigned an address you have reserved. Confirm the
addressing:

```bash
docker network inspect proxy | jq -r '.[0].IPAM.Config'
```

### Sonarr and Radarr are running and their API keys are at hand

Both must answer on the shared network before a sync can do anything.

```bash
docker ps --filter 'name=^sonarr$' --filter 'name=^radarr$'
docker exec sonarr curl -sf -o /dev/null -w 'sonarr %{http_code}\n' \
  -H 'X-Api-Key: <secret>' http://localhost:8989/api/v3/system/status
docker exec radarr curl -sf -o /dev/null -w 'radarr %{http_code}\n' \
  -H 'X-Api-Key: <secret>' http://localhost:7878/api/v3/system/status
```

A `200` from each means the application is up and the key is valid. Each key is visible in that
application's UI under **Settings → General → Security → API Key**.

### Outbound internet access

Recyclarr fetches the TRaSH Guides metadata from GitHub on every sync. If this machine is behind a
restrictive egress firewall or a proxy, the sync fails before it ever contacts Sonarr or Radarr.

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://api.github.com
```

## Setup

### Overview

1. Create the configuration directory.
2. Write `recyclarr.yml`.
3. Start the container.
4. Run the first sync by hand and read its output.

---

#### Step 1: Create the configuration directory

```bash
cd <deploy-dir>
mkdir -p ./data/recyclarr
sudo chown <username>:<pgid> ./data/recyclarr
sudo chmod 0755 ./data/recyclarr
```

**Explanation**: This one directory holds the configuration you write below, the cache of downloaded
TRaSH metadata, and the sync logs. Keeping the cache out of the container image is what makes the
nightly run fast and what lets a sync still work when GitHub is briefly unreachable.

---

#### Step 2: Write the configuration

This is the whole file. Substitute the two API keys and adjust nothing else unless you mean to change
the library policy — the long hexadecimal strings are the **public TRaSH Guide custom-format
identifiers**, not secrets, and they are what ties a score to a format definition.

```bash
sudo tee ./data/recyclarr/recyclarr.yml >/dev/null <<'EOF'
---
sonarr:
  main:
    base_url: http://sonarr:8989
    api_key: <secret>

    quality_definition:
      type: series

    quality_profiles:
      - name: Efficient WEB 1080p
        reset_unmatched_scores:
          enabled: true

        upgrade:
          allowed: true
          until_quality: WEB 1080p
          until_score: 2500

        min_format_score: 0
        quality_sort: top

        qualities:
          - name: WEB 1080p
            qualities:
              - WEBDL-1080p
              - WEBRip-1080p

          - name: WEB 720p
            qualities:
              - WEBDL-720p
              - WEBRip-720p

          - name: HDTV-1080p
          - name: HDTV-720p

    custom_formats:
      # Reject garbage releases
      - trash_ids:
          - 32b367365729d530ca1c124a0b180c64 # Bad Dual Groups
          - 82d40da2bc6923f41e67d2b29e3d0b8d # No-RlsGroup
          - e1a997ddb54e3ecbfe06341ad323c458 # Obfuscated
          - 06d66ab09318acdf0fc4a7cf4f33b49e # Retags
          - 1b3994c551cbb92a2c781af061f4ab44 # Scene
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: -10000

      # Slight penalty for x264 (forces upgrade later)
      - trash_ids:
          - 47435ece6b99a0b477caf360e79ba0bb # x264
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: -200

      # Prefer x265 (HEVC)
      - trash_ids:
          - 9170d55c319f4fe40da8711ba9d8050d # x265
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: 1500

      # Repacks / Proper
      - trash_ids:
          - ec8fa7763d8f3f6f73e8dc22e0dcb63c
          - eb3d5cc0a2be0db205fb823640db6a3c
          - 44e7c9de10ae27034f75c3a97bffd813
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: 5

      # Balanced WEB tiers (reduced upgrade churn)
      - trash_ids:
          - e6819cba26f1be8a7ba5362c2535c7b7 # Tier 01
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: 900

      - trash_ids:
          - 58790d4e2fdcd9733aa7ae68ba2bb503 # Tier 02
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: 850

      - trash_ids:
          - d84935abd3f8556dcd51d4f27e22d0a6 # Tier 03
        assign_scores_to:
          - name: Efficient WEB 1080p
            score: 800


radarr:
  main:
    base_url: http://radarr:7878
    api_key: <secret>

    quality_definition:
      type: movie

    quality_profiles:
      - name: Efficient HD (1080p)
        reset_unmatched_scores:
          enabled: true

        upgrade:
          allowed: true
          until_quality: WEB 1080p
          until_score: 3000

        min_format_score: 0
        quality_sort: top

        qualities:
          - name: WEB 1080p
            qualities:
              - WEBDL-1080p
              - WEBRip-1080p

          - name: Bluray-1080p

          - name: WEB 720p
            qualities:
              - WEBDL-720p
              - WEBRip-720p

          - name: Bluray-720p

    custom_formats:
      # Reject bad / fake / wasteful
      - trash_ids:
          - ed38b889b31be83fda192888e2286d83 # BR-DISK
          - 90a6f9a284dff5103f6346090e6280c8 # LQ
          - b8cd450cbfa689c0259a01d9e29ba3d6 # LQ title
          - bfd9eb2f79a97e7de9f83b17cf22d08b # Upscaled
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: -10000

      # Hard block remux (huge files)
      - trash_ids:
          - ed27ebfef2f323e964fb1f61391bcb35
          - 3bc5f395426614e155e585a2f056cdf1
          - 9965a052eb87b0d10313b3d88c5e61af
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: -10000

      # Slight penalty for x264
      - trash_ids:
          - 47435ece6b99a0b477caf360e79ba0bb
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: -200

      # Prefer x265
      - trash_ids:
          - 9170d55c319f4fe40da8711ba9d8050d
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: 1500

      # Repacks
      - trash_ids:
          - e7718d7a3ce595f289bfee26adc178f5
          - ae43b294509409a6a13919dedd4764c4
          - 772bc4f4a8ea33a6d0b2cef4e9d06d39
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: 5

      # Balanced WEB tiers (reduced churn)
      - trash_ids:
          - c20f169ef63c5f40c2def54abaf4438e # Tier 01
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: 900

      - trash_ids:
          - 403816d65392400563d8ea4f77c58d70 # Tier 02
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: 850

      - trash_ids:
          - af94e0fe497124d1f9ce732069ec825f # Tier 03
        assign_scores_to:
          - name: Efficient HD (1080p)
            score: 800
EOF
sudo chown <username>:<pgid> ./data/recyclarr/recyclarr.yml
sudo chmod 0644 ./data/recyclarr/recyclarr.yml
```

Replace the two `api_key: <secret>` lines with the Sonarr and Radarr keys respectively. The heredoc
is quoted (`<<'EOF'`), so nothing in the file is expanded by the shell — paste it as-is and edit
afterwards.

**Explanation**: `base_url` points at the container name rather than the public domain. Recyclarr
talks to Sonarr and Radarr over the internal network, where there is no TLS termination and no single
sign-on in the way; the public name would return an HTML login page instead of JSON and the sync
would fail with a parse error.

`reset_unmatched_scores` is the switch that makes this file authoritative: any custom format present
in the profile but not listed here is reset to zero rather than left at whatever it was. Without it,
a score you set by hand in the UI and later removed from this file lingers forever and quietly skews
every decision.

The scoring is deliberately asymmetrical. Anything at `-10000` is a hard rejection — the profile's
`min_format_score` of `0` means such a release can never be selected, which is how remuxes, upscales
and unnamed release groups are kept out entirely. `x265` at `+1500` against `x264` at `-200` makes
the more efficient codec win by a wide margin while still allowing an x264 release when nothing else
exists, and later triggering an upgrade when an x265 one appears. `until_score` caps the upgrade
chain so the applications stop re-downloading the same episode for a five-point improvement, which is
the usual cause of a download client churning all night.

The `quality_definition` block sets the size limits per runtime that TRaSH publishes, which is what
prevents a "1080p" release that is actually 40 GB from being accepted at all.

---

#### Step 3: Start the container

```bash
docker run -d \
  --name recyclarr \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -e CRON_SCHEDULE='0 3 * * *' \
  -v "$(pwd)/data/recyclarr:/config" \
  --health-cmd 'recyclarr --version' \
  --health-interval 1m \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 15s \
  ghcr.io/recyclarr/recyclarr:latest
```

**Explanation**: There are no reverse-proxy labels and no published ports because nothing connects to
Recyclarr — it is a scheduled outbound job. `CRON_SCHEDULE` runs it at 03:00 local time, deliberately
in the small hours: a sync rewrites quality profiles, and doing that while the applications are
actively grabbing releases can leave a search running against a profile that changed underneath it.
The timezone is what makes "03:00" mean 03:00 locally rather than in UTC.

The health check runs the binary's own version command. The process spends almost all of its life
asleep waiting for cron, so there is no port to probe and no log line to wait for; being able to
execute the binary at all is the only meaningful liveness signal.

---

#### Step 4: Run the first sync by hand

```bash
sleep 10
docker exec recyclarr recyclarr sync
```

**Explanation**: Waiting for 03:00 to find out whether the configuration parses is a bad trade. This
run does exactly what the nightly job does and prints the result, so a wrong API key, an unreachable
service, a profile name that does not exist in the target application, or a YAML indentation mistake
surfaces immediately. Read the output rather than only its exit code: a sync can succeed overall and
still report that it skipped a profile it could not find.

Successful output names each custom format it created or updated and ends with a summary per
instance. An empty summary means the file was parsed but matched nothing.

## What a sync actually changes

Inside Sonarr and Radarr, after a sync:

- **Settings → Profiles → Quality Profiles** gains (or has updated) `Efficient WEB 1080p` in Sonarr
  and `Efficient HD (1080p)` in Radarr, with the quality groups and the upgrade cut-off from the file.
- **Settings → Custom Formats** gains one entry per listed identifier, with the regular expressions
  TRaSH publishes for it.
- Each of those formats gets the score above assigned **inside that one profile only**. Other
  profiles are left alone.
- **Settings → Quality** definitions (the size limits per runtime) are replaced with the TRaSH values.

Nothing else is touched — indexers, download clients, root folders and existing library items are not
modified. Existing downloads are not re-evaluated retroactively; the new scores apply to searches and
upgrade checks from that point on.

## Values to fill in

| Placeholder | What it is | How to choose it |
| --- | --- | --- |
| `<deploy-dir>` | Working directory holding `./data` on this machine | Wherever you keep service state; every relative path here is relative to it |
| `<username>` | Account that owns `./data/recyclarr` | The login you deploy as; must be in the `docker` group |
| `<pgid>` | Group that owns the configuration directory | The Docker group id on this host, from `getent group docker` |
| `<docker-ip>` | Fixed address of the container on the shared network | Any free address in the network's subnet but outside its automatic pool |
| `<secret>` (Sonarr key) | Sonarr's API key | Copy from Sonarr's **Settings → General → Security**; used in `recyclarr.yml` |
| `<secret>` (Radarr key) | Radarr's API key | Copy from Radarr's **Settings → General → Security**; used in `recyclarr.yml` |

## Verification

```bash
docker ps --filter 'name=^recyclarr$'
docker inspect --format '{{.State.Health.Status}}' recyclarr
```

The configuration parses and both instances are reachable:

```bash
docker exec recyclarr recyclarr config list
docker exec recyclarr recyclarr sync
```

Confirm from the other side that the profiles really landed:

```bash
docker exec sonarr curl -s -H 'X-Api-Key: <secret>' \
  http://localhost:8989/api/v3/qualityprofile | jq -r '.[].name'
docker exec radarr curl -s -H 'X-Api-Key: <secret>' \
  http://localhost:7878/api/v3/qualityprofile | jq -r '.[].name'
```

And that the custom formats exist:

```bash
docker exec sonarr curl -s -H 'X-Api-Key: <secret>' \
  http://localhost:8989/api/v3/customformat | jq 'length'
```

## Updating & day-to-day

```bash
docker pull ghcr.io/recyclarr/recyclarr:latest
docker stop recyclarr && docker rm recyclarr
# re-run the docker run command from Step 3
docker exec recyclarr recyclarr sync
```

Logs — both the container's stdout and the per-run files it keeps:

```bash
docker logs recyclarr --tail 100
ls -lt ./data/recyclarr/logs/ | head
```

Routine chores:

- After editing `recyclarr.yml`, apply it immediately instead of waiting for the nightly run:
  ```bash
  docker exec recyclarr recyclarr sync
  ```
- Preview what a change would do before committing to it:
  ```bash
  docker exec recyclarr recyclarr sync --preview
  ```
- When an API key is rotated in Sonarr or Radarr, edit the corresponding `api_key` line here as well;
  the sync fails with a 401 until you do.
- The TRaSH Guides change over time. A sync always fetches the current definitions, so an unchanged
  configuration file can still alter scores from one night to the next — check the logs after a run
  that suddenly changes what gets grabbed.

## Rollback / Uninstall

```bash
docker stop recyclarr && docker rm recyclarr
rm -rf ./data/recyclarr
```

Removing the container does **not** undo anything it wrote. The quality profiles, custom formats and
quality definitions stay in Sonarr and Radarr exactly as the last sync left them. To undo those, in
each application delete the profile under **Settings → Profiles** and the entries under **Settings →
Custom Formats** by hand, and reset **Settings → Quality** to its defaults.

## Troubleshooting

**`sync` exits with 401 Unauthorized**
The `api_key` in the file does not match the application's current key. Re-copy it from the
application's **Settings → General → Security** page.

**`Connection refused` or `Name or service not known`**
Recyclarr resolves `sonarr` and `radarr` by container name on the shared network. Check all three are
attached to it:
```bash
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' recyclarr sonarr radarr
docker exec recyclarr getent hosts sonarr radarr
```

**`Quality profile does not exist` / formats applied but scores are not**
`assign_scores_to` names a profile that is not present in the target application, and profile names
are matched literally including capitalisation and the parentheses in `Efficient HD (1080p)`. Either
create the profile in the application first or let this file create it via the `quality_profiles`
block.

**The sync fails while downloading metadata**
The TRaSH Guides are fetched from the internet on every run. Test egress with
`docker exec recyclarr wget -qO- -T5 https://api.github.com >/dev/null && echo ok`. A rate-limited or
blocked run leaves the previous cache in place, so the *next* sync may succeed with stale data.

**Scores keep reverting after you edit them in the UI**
That is `reset_unmatched_scores` doing its job — this file is authoritative and the nightly run
overwrites manual edits. Make the change here instead.

**Nothing happens at 03:00**
The cron expression is read at container start. Confirm it is set and that the clock is right:
```bash
docker exec recyclarr printenv CRON_SCHEDULE
docker exec recyclarr date
```

**Downloads got worse after the first sync**
`min_format_score: 0` combined with the `-10000` rejections means releases that used to be accepted
are now refused outright. If a library depends on one of those categories (remux, for example), raise
its score or drop that block from the file and sync again.
