# Log Notification

## What this is

A small container that tails one log file and sends a Telegram message whenever a new line contains
one of a list of patterns. It is the "shout at me" end of two background services that otherwise fail
silently.

It runs on two machines, watching a different file with different patterns on each:

| Machine | File it watches | Patterns it reacts to |
|---|---|---|
| The public-facing server | `./data/public_ip_whitelist_updater/app.log` | `WARNING`, `EXCEPTION`, `ERROR`, `INFO` |
| The monitoring machine | `./data/public_ip_tracker/app.log` | `WARNING`, `EXCEPTION`, `ERROR`, `IP has changed` |

The two are the same container image with different settings. On the monitoring machine the extra
`IP has changed` pattern is the point of the whole thing: the tracker writes that line when the
household's public address changes, and this container turns it into a phone notification within
seconds — which is what tells you the firewall's allow-lists elsewhere are about to be stale.

It has no web interface, no port and no configuration file. Everything it needs is in four
environment variables and one bind-mounted file. It only makes outbound connections, to Telegram's
API.

---

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

### The log file you are going to watch already exists

This is the one prerequisite that will bite you. Docker creates a **directory** at a bind-mount
source that does not exist, and then the container tails a directory and reports nothing forever.

On the monitoring machine:

```bash
ls -l ./data/public_ip_tracker/app.log
tail -3 ./data/public_ip_tracker/app.log
```

On the public-facing server:

```bash
ls -l ./data/public_ip_whitelist_updater/app.log
tail -3 ./data/public_ip_whitelist_updater/app.log
```

The file is written by the address-tracking service on that machine, which must be running first:

```bash
docker ps --filter 'name=public_ip'
```

If the file genuinely does not exist yet but the service is running and simply has not logged, create
it empty rather than letting Docker invent a directory:

```bash
sudo touch ./data/public_ip_tracker/app.log
```

### The Telegram bot exists and can talk to the target chat

```bash
curl -sf "https://api.telegram.org/bot<telegram-bot-token>/getMe" | jq -r '.result.username'
curl -sf "https://api.telegram.org/bot<telegram-bot-token>/sendMessage" \
  -d chat_id='<telegram-chat-id>' -d text='log_notification setup test' | jq -r '.ok'
```

`getMe` proves the token; `sendMessage` proves the bot is actually a member of that chat and the id
is right. A bot that has never been added to a group can hold a perfectly valid token and still fail
every send, and the container has no way to tell you that — it will report success to itself and you
will simply never hear from it. Group chat ids are negative numbers; leaving off the minus sign is
the most common mistake.

### Outbound HTTPS is allowed

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://api.telegram.org
```

The container makes no inbound connections at all, so nothing needs opening in the firewall — but
egress to `api.telegram.org` on 443 must work from this machine.

---

## Setup

### Overview

1. Create the service's data directory.
2. Start the container with the settings for this machine.
3. Prove a matching line produces a message.

---

#### Step 1: Create the data directory

```bash
cd <deploy-dir>
sudo mkdir -p ./data/log_notification
sudo chmod 0744 ./data/log_notification
```

**Explanation**: The container keeps no state of its own — it does not remember which lines it has
already sent, and it starts reading at the end of the file, so a restart never replays history. This
directory is here for consistency with every other service on the machine and as somewhere to put
notes or a wrapper script; nothing is mounted from it.

---

#### Step 2: Start the container

**On the monitoring machine** — watches the public-address tracker:

```bash
docker run -d \
  --name log_notification \
  --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN='<telegram-bot-token>' \
  -e TELEGRAM_CHAT_ID='<telegram-chat-id>' \
  -e NOTIFICATION_PATTERNS='WARNING, EXCEPTION, ERROR, IP has changed' \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/public_ip_tracker/app.log:/app/logs/public_ip.log" \
  <dockerhub-user>/log_notification:latest
```

**On the public-facing server** — watches the allow-list updater:

```bash
docker run -d \
  --name log_notification \
  --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN='<telegram-bot-token>' \
  -e TELEGRAM_CHAT_ID='<telegram-chat-id>' \
  -e NOTIFICATION_PATTERNS='WARNING, EXCEPTION, ERROR, INFO' \
  -e TZ=Europe/Belgrade \
  -v "$(pwd)/data/public_ip_whitelist_updater/app.log:/app/logs/whitelist.log" \
  <dockerhub-user>/log_notification:latest
```

**Explanation**: `NOTIFICATION_PATTERNS` is a comma-separated list of substrings, matched against
each new line as it arrives. They are plain text, not regular expressions, which is why
`IP has changed` can contain spaces and be written literally. Order does not matter and a line that
matches more than one pattern still produces one message.

The two machines watch for different things on purpose. The allow-list updater on the public server
logs its successful updates at `INFO`, and those are worth seeing — a silent allow-list is
indistinguishable from a broken one. The tracker on the monitoring machine logs far more routine
`INFO` chatter, so it watches for the specific event instead: the line saying the household's public
address changed. Adding `INFO` there would notify you every polling cycle and you would mute the
chat within a day.

The mount is a **single file**, and that is a bind by inode. If the address-tracking service ever
recreates its log rather than appending to it — a rotation that moves the file aside and opens a new
one — the container keeps its grip on the old, now-deleted inode and goes quiet without erroring.
That is why the services on the other side of this mount rotate their logs in place (copy the
contents out, truncate the original) instead of renaming. If you ever rotate one of these files by
hand, recreate this container afterwards.

There is no `--network` flag: the container joins Docker's default bridge rather than the shared
service network, because it never talks to another container. Its only peer is Telegram's API on the
internet, and keeping it off the service network means a compromise of this container cannot reach
anything internal.

The bot token is passed as an environment variable, which means it is visible to anyone who can run
`docker inspect` on this machine. That is acceptable for a notification-only bot that can send
messages to one chat and nothing else — but it is a reason not to reuse a token that has any other
privilege.

The container is mounted read-write on that file even though it only reads. Give it a `:ro` suffix
if you want to be strict:
`-v "$(pwd)/data/public_ip_tracker/app.log:/app/logs/public_ip.log:ro"`.

---

#### Step 3: Prove it works end to end

```bash
echo "$(date -Iseconds) TEST WARNING log_notification wiring check" \
  | sudo tee -a ./data/public_ip_tracker/app.log >/dev/null
```

A Telegram message should arrive within a few seconds. Watch the container's own output while you do
it:

```bash
docker logs -f log_notification
```

**Explanation**: Appending with `tee -a` is important — `>` would truncate the file, which the
tracking service has open, and you would lose whatever was in it. This test also confirms the mount
is the right way round: if you append to the host file and the container sees nothing, the mount
resolved to a path other than the one the service writes to.

Remove the test line afterwards if the file is short enough for that to matter; otherwise leave it,
it is harmless.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
|---|---|---|---|
| `<deploy-dir>` | Working directory holding `./data` | The directory you deploy everything from | All steps |
| `<username>` / `<pgid>` | Account that owns `./data` and its group | The unprivileged login on this machine | Before you start |
| `<telegram-bot-token>` | Telegram bot API token | From `@BotFather`; the bot must already be in the chat | Step 2 |
| `<telegram-chat-id>` | Chat that receives the messages | Numeric; **negative** for a group | Step 2 |
| `<dockerhub-user>` | Registry account the image is published under | The account that built `log_notification` | Step 2 |

---

## Verification

```bash
docker ps --filter 'name=^log_notification$'

# the mount points at a FILE, not a directory Docker invented
docker inspect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' log_notification
docker exec log_notification ls -l /app/logs/

# the container sees the same content the host does
docker exec log_notification tail -3 /app/logs/public_ip.log
tail -3 ./data/public_ip_tracker/app.log

# settings actually took effect
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' log_notification | grep -E 'PATTERNS|CHAT_ID'

docker logs log_notification --tail 20
```

If `docker exec ... ls -l /app/logs/` shows a directory where the log file should be, the host path
did not exist when the container was created. Remove the directory Docker made, create the file, and
recreate the container.

---

## Updating & day-to-day

**Pull a new image and restart:**

```bash
docker pull <dockerhub-user>/log_notification:latest
docker stop log_notification && docker rm log_notification
# re-run the docker run for this machine from Step 2
```

**Change the patterns** — there is no configuration file, so the container has to be recreated:

```bash
docker stop log_notification && docker rm log_notification
# re-run Step 2 with a different NOTIFICATION_PATTERNS
```

**Logs:**

```bash
docker logs -f log_notification
```

This is where a failed Telegram send shows up. The container writes nothing to disk.

**Routine sanity check:** silence from this container is ambiguous — it means either nothing has gone
wrong or the container has stopped watching. Once in a while, append a `TEST WARNING` line as in
Step 3 and confirm the message still arrives. Do it after every rotation, move or recreation of the
watched log file.

**When you rotate the watched log**, recreate this container afterwards; see the inode note in
Step 2.

---

## Rollback / Uninstall

```bash
docker stop log_notification && docker rm log_notification
sudo rm -rf ./data/log_notification
docker rmi <dockerhub-user>/log_notification:latest
```

Nothing else is affected — the watched log file belongs to another service and is untouched by any of
this. Removing the container simply means nobody is told when a matching line is written.

---

## Troubleshooting

**No messages ever arrive, container is running and healthy-looking**
Test the bot directly with the two `curl` calls in *Before you start*. A valid token plus a bot that
was never added to the group is the usual cause, and it fails silently.

**Messages stopped after working for weeks**
The watched log file was rotated or replaced, and the single-file bind mount still points at the old
inode. Confirm with `docker exec log_notification ls -li /app/logs/` against `ls -li` on the host —
different inode numbers mean the mount is stale. Recreate the container.

**The container tails a directory**
The host path did not exist when the container was created, so Docker created a directory there.
Remove it, `touch` the file, recreate the container.

**Far too many messages**
`INFO` is in the pattern list for a log that is chatty. Recreate the container with a narrower list —
on the monitoring machine, watch for the specific address-change line rather than for `INFO`.

**Messages arrive with the wrong timestamps**
`TZ` is unset or wrong. It only affects how the container renders time; the log file's own timestamps
come from the service that wrote them.

**`chat not found` or `Forbidden: bot was blocked by the user` in `docker logs`**
The chat id is wrong (a group id must be negative), the bot was removed from the group, or a private
recipient blocked it. Re-add the bot and send it `/start` from the target chat.

**Nothing in `docker logs` at all and the container keeps restarting**
Check that the mount source is a file and that the image name is right:
`docker inspect log_notification | jq '.[0].Config.Image, .[0].Mounts'`.
