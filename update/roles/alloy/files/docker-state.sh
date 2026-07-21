#!/bin/sh
# Emit docker image + container-state metrics in Prometheus textfile format.
#
# Runs on the HOST via docker-state.timer; the output file is bind-mounted into
# Alloy and picked up by prometheus.exporter.unix's textfile collector.
# Replaces the old telegraf inputs.exec docker-images.sh (InfluxDB line
# protocol). Adds per-container exited/oom gauges — cadvisor cannot see stopped
# containers, so the hl-ct-exited / hl-ct-oom alerts depend on this script.
set -eu

OUT="/var/lib/alloy/textfiles/docker.prom"
TMP="${OUT}.$$"
SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
API="http://localhost/v1.43"

# Bound every image API call. --max-time makes a slow endpoint fail fast so the
# affected metric falls back to 0 instead of hanging the whole run.
CURL="curl -s --connect-timeout 2 --max-time 4 --unix-socket $SOCKET"

count_ids() {
  $CURL "$1" 2>/dev/null | tr ',' '\n' | grep -c '"Id"[[:space:]]*:' || true
}

total=$(count_ids "$API/images/json?all=true")
dangling=$(count_ids "$API/images/json?all=true&filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D")

# /system/df walks every layer through the FUSE mount on fuse-overlayfs hosts
# (minutes, pins CPU, aborting the client curl does not stop the server walk).
# SKIP_SYSTEM_DF=true forces reclaimable_bytes=0 there.
if [ "${SKIP_SYSTEM_DF:-false}" = "true" ]; then
  df_json=""
else
  df_json=$($CURL "$API/system/df" 2>/dev/null || echo "")
fi
reclaimable=$(printf '%s' "$df_json" \
  | awk 'BEGIN { RS="{"; sum=0 }
         /"Containers"[[:space:]]*:[[:space:]]*-1/ || /"Containers"[[:space:]]*:[[:space:]]*0/ {
           if (match($0, /"Size"[[:space:]]*:[[:space:]]*[0-9]+/)) {
             s=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); sum+=s
           }
         }
         END { printf "%d", sum }' 2>/dev/null || echo 0)

{
  echo '# HELP docker_images_total Total docker images (all).'
  echo '# TYPE docker_images_total gauge'
  echo "docker_images_total ${total:-0}"
  echo '# HELP docker_images_dangling Dangling docker images.'
  echo '# TYPE docker_images_dangling gauge'
  echo "docker_images_dangling ${dangling:-0}"
  echo '# HELP docker_images_reclaimable_bytes Reclaimable image bytes (0 on fuse-overlayfs hosts).'
  echo '# TYPE docker_images_reclaimable_bytes gauge'
  echo "docker_images_reclaimable_bytes ${reclaimable:-0}"

  echo '# HELP docker_container_exited Container currently in the exited state.'
  echo '# TYPE docker_container_exited gauge'
  docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null \
    | while IFS= read -r name; do
        [ -n "$name" ] && printf 'docker_container_exited{container_name="%s"} 1\n' "$name"
      done

  echo '# HELP docker_container_oom_killed Container was OOM-killed.'
  echo '# TYPE docker_container_oom_killed gauge'
  docker ps -aq 2>/dev/null | while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ "$(docker inspect --format '{{.State.OOMKilled}}' "$id" 2>/dev/null || echo false)" = "true" ]; then
      name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
      printf 'docker_container_oom_killed{container_name="%s"} 1\n' "$name"
    fi
  done
} > "$TMP"

mv -f "$TMP" "$OUT"
