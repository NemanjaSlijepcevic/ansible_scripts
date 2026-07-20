#!/bin/sh
# Emit docker image stats as InfluxDB line protocol.
# Talks to docker daemon over /var/run/docker.sock via curl --unix-socket.
# No jq dependency; counts "Id" occurrences in the JSON response.
set -eu

SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
API="http://localhost/v1.43"

# Bound every call. telegraf kills this exec at 10s; an unbounded curl to a
# slow endpoint (notably /system/df, which walks every layer/volume on
# overlay/fuse-overlayfs and can take >10s) would hang the whole run and
# spam "command timed out". --max-time makes a slow call fail fast → the
# affected metric falls back to 0 instead of taking telegraf down with it.
CURL="curl -s --connect-timeout 2 --max-time 4 --unix-socket $SOCKET"

count_ids() {
  $CURL "$1" 2>/dev/null \
    | tr ',' '\n' \
    | grep -c '"Id"[[:space:]]*:' \
    || true
}

total=$(count_ids "$API/images/json?all=true")
dangling=$(count_ids "$API/images/json?all=true&filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D")

# Reclaimable size from /system/df. Sum image sizes that have no containers.
# Use awk to extract numbers between "Containers": and "Size" tokens. Best-effort.
# On fuse-overlayfs hosts /system/df must be skipped entirely (SKIP_SYSTEM_DF=true):
# dockerd sizes layers by walking the FS through the FUSE mount — takes minutes,
# and aborting the client curl does NOT stop the server-side walk. A new walk
# every interval piles up in dockerd (GBs of RSS, fuse-overlayfs pinned at 100%).
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

printf 'docker_images total=%si,dangling=%si,reclaimable_bytes=%si\n' \
  "$total" "$dangling" "$reclaimable"
