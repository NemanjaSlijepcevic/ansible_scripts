# Samba file sharing

## What this is

Samba turns the NAS machine's storage into SMB/CIFS network shares — the drives that appear in
Windows Explorer under `\\<ip-address>\<share-name>`, in macOS Finder under `smb://<ip-address>/`, and
that a Linux client mounts with `mount -t cifs`.

This is **not** a container. It is a service package installed on the machine itself, running as
`smbd`, reading a single configuration file at `/etc/samba/smb.conf`, and serving the same
directories that the media containers read and write. That is the point of it: the shares are the
library, exposed to laptops and phones on the LAN without going through any of the web services.

It is a standalone server with its own user database. There is no domain controller, no Active
Directory and no guest access — every connection authenticates as a named user, and each share names
the users allowed onto it.

## Before you start

### You have root on the machine and it is Debian-based

```bash
sudo -v && echo "sudo: ok"
. /etc/os-release && echo "$ID $VERSION_ID"
```

The package names below (`samba`, `samba-common`, `smbclient`) and the paths
(`/etc/samba/smb.conf`, `/var/log/samba/`) are the Debian/Ubuntu layout.

### The storage the shares live on is mounted

Every directory you are about to share must already be on its real filesystem.

```bash
findmnt -T <media-path> || echo "<media-path> is NOT a mount point"
df -h <media-path>
```

If the array is not mounted when Samba starts, clients connect successfully to an empty directory on
the root filesystem, and anything they write lands on the system disk. That failure is silent from
the client's side, which is what makes it worth checking first.

### The SMB ports are reachable on the LAN

Samba listens on four ports. Only the machine's own firewall is in play here — SMB should never be
exposed to the internet, so do not forward these at the router.

```bash
sudo ufw allow from <docker-subnet> to any port 445 proto tcp comment 'samba'
sudo ufw status numbered | grep -E '445|139|137|138'
```

Replace `<docker-subnet>` with your LAN's address range. Port 445/tcp carries modern SMB and is the
only one strictly required. Ports 139/tcp, 137/udp and 138/udp are the legacy NetBIOS set, needed
only if you also want the server to announce itself by name for browsing; they are served by the
separate `nmbd` service.

### Decide the users and shares before you type anything

Write down, on paper, for each share: its name as clients will see it, its path on disk, whether it
is writable, and which users may use it. Write down each user's login name and password. The whole
configuration below is those two lists, and getting them straight first saves editing the
configuration file three times.

## Setup

### Overview

1. Install the Samba packages.
2. Enable and start the service.
3. Create a system account for each Samba user.
4. Create each user's entry in Samba's own password database.
5. Create the share directories.
6. Write `/etc/samba/smb.conf`.
7. Check the configuration and restart.

---

#### Step 1: Install the packages

```bash
sudo apt-get update
sudo apt-get install -y samba samba-common smbclient
```

**Explanation**: `samba` is the server itself (`smbd` and `nmbd`), `samba-common` the shared
configuration machinery, and `smbclient` the command-line client. The client is installed on the
server deliberately — it is how you test a share from the machine that serves it, which separates "the
share is broken" from "the network is broken" in one command.

Note that the package's own post-install step runs the configuration checker. If `/etc/samba/smb.conf`
is ever syntactically invalid, `apt` will fail to configure the package, and every later `apt`
operation on the machine fails with it until the file is fixed. Keep that in mind before editing the
file by hand.

---

#### Step 2: Enable and start the service

```bash
sudo systemctl enable smbd
sudo systemctl start smbd
systemctl is-enabled smbd; systemctl is-active smbd
```

**Explanation**: `enable` makes it come back after a reboot, `start` brings it up now; the two are
independent and doing only one of them is the usual reason a NAS loses its shares after a power cut.
If you also need NetBIOS browsing (older Windows clients discovering the server by name rather than
by address), do the same for `nmbd`.

---

#### Step 3: Create a system account for each Samba user

Samba authenticates against its own database, but each of its users must still map to a real account
on the machine, because file ownership on disk is a Unix uid.

For each user:

```bash
sudo useradd --no-create-home --shell /usr/sbin/nologin --groups <group-name> <username>
```

If the account already exists, `useradd` exits non-zero and changes nothing — that is fine and
expected on a re-run. Check first if you prefer:

```bash
getent passwd <username> >/dev/null && echo "exists" || echo "missing"
```

**Explanation**: `--shell /usr/sbin/nologin` and `--no-create-home` are what keep these from being
login accounts. A Samba user has no business getting an interactive shell or an SSH session on the
NAS; the account exists purely so the kernel has a uid to stamp on the files that user creates
through a share. Removing either flag turns a file-sharing password into a shell credential.

The `--groups` argument is optional and adds the account to a supplementary group. Use it when a
share's files should be group-owned by something the media containers also belong to, so that a file
dropped in over SMB is readable by the applications and vice versa.

---

#### Step 4: Create each user's Samba password

```bash
printf '%s\n%s\n' '<secret>' '<secret>' | sudo smbpasswd -s -a <username>
```

Confirm the entry exists:

```bash
sudo pdbedit -L
sudo pdbedit -L <username> && echo "exists" || echo "not found"
```

**Explanation**: Samba keeps its own password database, separate from `/etc/shadow`, because the SMB
protocol needs a password hash in a form Unix does not store. That is why creating the system account
in Step 3 is not enough on its own — a user that exists in `/etc/passwd` but not in `pdbedit -L`
cannot connect at all, and the error the client shows is an unhelpful "logon failure".

`-a` adds a new entry, `-s` reads the password from standard input twice instead of prompting, which
is what makes this scriptable. Piping the password in means it never appears in the process list the
way a command-line argument would; it does land in your shell history, so clear that afterwards or
prefix the command with a space if your shell is configured to skip those.

To change a password later, use the same command without `-a`. To remove a user from the Samba
database while leaving the system account alone, use `sudo smbpasswd -x <username>`.

---

#### Step 5: Create the share directories

For each share:

```bash
sudo mkdir -p <media-path>/<share-name>
sudo chmod 0755 <media-path>/<share-name>
```

**Explanation**: `0755` gives the owner full control and everyone else read and traverse. It is the
mode that lets the media containers, which run as their own uid, read what SMB clients drop in.
Write access from a client is not decided by this mode alone — it is the intersection of the Unix
permissions here and the `writable` and `valid users` settings in the configuration below, and the
stricter of the two always wins. A share marked writable on a directory the connecting user's uid
cannot write to produces "access denied" on the client with nothing in the log to explain it.

Ownership is left as-is on purpose. These directories usually sit on a large existing array where a
recursive change of owner would take hours and could break the applications that already use them.

---

#### Step 6: Write the configuration

This is the whole file. There is one `[global]` section and one section per share.

```bash
sudo tee /etc/samba/smb.conf >/dev/null <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = <org-name> NAS
   security = user
   map to guest = never
   log file = /var/log/samba/log.%m
   max log size = 1000
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .

[<share-name-1>]
path = <media-path>/<share-name-1>
browseable = Yes
writable = Yes
guest ok = No
valid users = <username-1> <username-2>

[<share-name-2>]
path = <media-path>/<share-name-2>
browseable = Yes
writable = Yes
guest ok = No
valid users = <username-1> <username-2>
EOF
sudo chown root:root /etc/samba/smb.conf
sudo chmod 0644 /etc/samba/smb.conf
```

Add one more `[<share-name>]` block per share. Every share needs all five settings — there is no
inheritance between sections, so a block that omits `valid users` is open to every authenticated
user on the server.

**Explanation of each global setting**:

- `workgroup` is the NetBIOS workgroup name clients group the server under. `WORKGROUP` is the
  Windows default and works everywhere; changing it only matters if the rest of the LAN uses
  something else.
- `server string` is the description clients show next to the server name. Cosmetic.
- `security = user` is the whole authentication model: every connection must present a username and
  password that exist in Samba's database, and the share's `valid users` list is then checked against
  that name.
- `map to guest = never` closes the usual hole. Without it, a failed login is silently downgraded to
  the guest account instead of being rejected, which turns a wrong password into anonymous access to
  anything marked `guest ok`. With it, a bad password is a bad password.
- `log file = /var/log/samba/log.%m` gives each connecting machine its own log file, which is what
  makes "one laptop cannot connect" diagnosable — you read that laptop's file instead of one merged
  stream. `max log size = 1000` caps each at 1000 KB so a chatty client cannot fill the disk.
- `server role = standalone server` states there is no domain controller and no Active Directory:
  this machine is the sole authority for its own users.
- `obey pam restrictions = yes` makes account restrictions from the system (a locked or expired
  account) apply to SMB logins too, so disabling an account in one place disables it in both.
- `unix password sync = yes` updates the Unix password when a user changes their SMB password, and
  `passwd program` plus `passwd chat` are what carry that out — the chat string is the literal
  scripted conversation Samba has with the `passwd` command. These last two are not optional
  decoration: since Samba 4.15.13-0ubuntu1.12 the configuration checker hard-errors when
  `unix password sync` is enabled without a `passwd program`, and because the package's post-install
  step runs that checker, the `samba` package itself fails to configure and takes the rest of `apt`
  down with it.

**Explanation of each share setting**:

- `path` is the directory on disk. It must exist before a client connects.
- `browseable = Yes` makes the share appear in the network browse list. Setting it to `No` hides the
  name but does **not** protect it — a client that knows the name can still connect. Hiding is not
  access control.
- `writable = Yes` permits writes at the Samba layer; the Unix permissions on `path` still have to
  allow them as well.
- `guest ok = No` requires authentication for this share. Combined with `map to guest = never` above,
  there is no anonymous path in at all.
- `valid users` is the access control list: only these names may connect, whatever their password is.
  Names are separated by spaces. A group can be given by prefixing it with `@`, for example
  `@<group-name>`.

---

#### Step 7: Check the configuration, then restart

```bash
sudo testparm -s
```

Only when that prints the parsed configuration without an error:

```bash
sudo systemctl restart smbd
systemctl is-active smbd
```

**Explanation**: `testparm` parses the file exactly the way the daemon does and prints back its
interpretation, including the defaults it filled in for anything you left out. Running it *before* the
restart is what keeps a typo from taking the shares down: a restart with an invalid file leaves
`smbd` dead, and a machine that is otherwise fine looks like a network failure from every client at
once. `-s` skips the "press enter to see the dump" prompt so it can be used non-interactively.

A restart drops every open connection. Clients with a file open mid-copy will report an error rather
than resume, so do this when nothing is transferring.

## The user and permission model

Three separate layers decide whether a person can read or write a file. All three must agree.

| Layer | Where it lives | What it decides |
| --- | --- | --- |
| Samba account | `pdbedit -L`, created with `smbpasswd -a` | Whether the username and password are accepted at all |
| Share access | `valid users` in the share's section | Whether that authenticated name may connect to this particular share |
| Filesystem | Unix owner, group and mode on `path` | What that user's uid may actually do to the files |

A connection is refused at the first layer that says no, and the error the client shows is roughly the
same in all three cases. Diagnose in that order: is the user in `pdbedit -L`, is the name in
`valid users`, and can the uid write the directory.

The system account created in Step 3 is what gives the third layer a uid. Files created over a share
are owned by that uid, which is why the supplementary group matters when containers on the same
machine need to read them.

Nothing here is anonymous: `map to guest = never` plus `guest ok = No` on every share means an
unauthenticated client gets rejected rather than downgraded. If you ever want a genuinely public
share, that is a deliberate change to both settings, and it should be a share with no private data
under it.

## Values to fill in

| Placeholder | What it is | How to choose it |
| --- | --- | --- |
| `<media-path>` | Mount point of the storage the shares live on | The array or disk holding the library; used in Steps 5 and 6 |
| `<share-name-1>`, `<share-name-2>` | Share names as clients see them | Short, no spaces; each becomes a `[section]` in the configuration and the last element of `\\<ip-address>\<name>` |
| `<username>` | A Samba user's login name | One per person or device; created as a system account in Step 3 and a Samba entry in Step 4 |
| `<secret>` | That user's Samba password | Generated, not reused from anywhere else; set in Step 4 |
| `<group-name>` | Supplementary group for the Samba accounts | An existing group whose id the media applications also use, so files are shared both ways |
| `<org-name>` | Text shown as the server description | Cosmetic; appears in `server string` |
| `<ip-address>` | This machine's LAN address | Used by clients to reach the shares |
| `<docker-subnet>` | Address range allowed through the firewall | Your LAN's range — never the whole internet |

## Verification

The service is up and the configuration parses:

```bash
systemctl status smbd --no-pager
sudo testparm -s
```

The users exist in Samba's database:

```bash
sudo pdbedit -L
```

The shares are advertised — this asks the server about itself:

```bash
smbclient -L //localhost -U <username>
```

Connect to a share and list it, from the server:

```bash
smbclient //localhost/<share-name-1> -U <username> -c 'ls'
```

From another Linux machine on the LAN:

```bash
smbclient -L //<ip-address> -U <username>
sudo mount -t cifs //<ip-address>/<share-name-1> /mnt/<share-name-1> \
  -o username=<username>,uid=$(id -u),gid=$(id -g)
ls /mnt/<share-name-1>
sudo umount /mnt/<share-name-1>
```

Leaving the password off the `mount` command makes it prompt, which keeps the credential out of the
process list and out of `/etc/mtab`.

Confirm a write actually lands with the ownership you expect:

```bash
smbclient //localhost/<share-name-1> -U <username> -c 'put /etc/hostname test.txt'
ls -l <media-path>/<share-name-1>/test.txt
rm <media-path>/<share-name-1>/test.txt
```

## Updating & day-to-day

Package updates come with the system:

```bash
sudo apt-get update && sudo apt-get install --only-upgrade samba samba-common smbclient
sudo testparm -s && sudo systemctl restart smbd
```

Always re-run `testparm` after an upgrade — new versions occasionally start rejecting settings that
older ones tolerated, and finding that out during the package's own post-install step is worse.

Logs, one file per connecting client:

```bash
ls -lt /var/log/samba/
sudo tail -f /var/log/samba/log.<client-name>
sudo journalctl -u smbd -f
```

Routine chores:

- See who is connected right now, and which files are open:
  ```bash
  sudo smbstatus
  ```
- Add a user later: repeat Steps 3 and 4, then add the name to the relevant `valid users` lines and
  restart.
- Change a password: `sudo smbpasswd <username>` (no `-a`). No restart needed.
- Add a share later: create the directory, append a section to the configuration, `testparm`, restart.
- After any edit to `/etc/samba/smb.conf`, `testparm` first. Every time.

## Rollback / Uninstall

Remove a single user without touching anything else:

```bash
sudo smbpasswd -x <username>      # remove from Samba's database
sudo userdel <username>           # remove the system account (files keep the numeric uid)
```

Remove a share: delete its section from `/etc/samba/smb.conf`, run `testparm -s`, restart `smbd`. The
directory and its contents are untouched.

Remove Samba entirely:

```bash
sudo systemctl stop smbd
sudo systemctl disable smbd
sudo apt-get purge -y samba samba-common smbclient
sudo rm -rf /etc/samba /var/lib/samba /var/log/samba
sudo ufw delete allow 445/tcp
```

`/var/lib/samba` holds the password database, so removing it destroys every user entry. The shared
directories and all their data survive all of the above — nothing here deletes files from the array.

## Troubleshooting

**`NT_STATUS_LOGON_FAILURE`**
The password is wrong, or the user exists on the system but not in Samba's database. Check
`sudo pdbedit -L` for the name; if it is missing, run Step 4. If it is present, reset the password
with `sudo smbpasswd <username>`.

**`NT_STATUS_ACCESS_DENIED` after a successful login**
Authentication worked but authorisation did not. Either the name is not in that share's `valid users`
list, or the user's uid cannot write the directory. Check both:
```bash
sudo testparm -s | grep -A5 '\[<share-name-1>\]'
ls -ld <media-path>/<share-name-1>
```

**`NT_STATUS_BAD_NETWORK_NAME`**
The share name does not exist in the configuration, or the `path` it points at is missing. `testparm`
lists every share it parsed; compare against what the client asked for, remembering that a section
whose directory is absent is still advertised.

**The server does not appear when browsing the network**
Browsing needs NetBIOS, served by `nmbd`, which is a separate unit from `smbd`. Start and enable it,
and open 137/udp, 138/udp and 139/tcp. Connecting by address (`\\<ip-address>\<share-name>`) works
without any of that and is the better test of whether the shares themselves are fine.

**`apt` fails on any package with an error mentioning samba**
The package's post-install step runs the configuration checker and `/etc/samba/smb.conf` is invalid.
Fix the file, confirm with `sudo testparm -s`, then `sudo dpkg --configure -a`. The most common cause
is `unix password sync = yes` without the accompanying `passwd program` line.

**`smbd` will not start after an edit**
```bash
sudo testparm -s
sudo journalctl -u smbd -n 50 --no-pager
```
The parse error names the line. Until it is fixed the service stays dead and every client sees a
connection refused.

**Windows connects as the wrong user and will not prompt again**
Windows caches SMB credentials per server. Clear them and retry:
```
net use \\<ip-address> /delete
```

**Files written over SMB are invisible to the media applications**
The uid that owns the new file has no group in common with the application's uid. Add the Samba
account to a shared group (Step 3) and set the group on the directory so new files inherit it:
```bash
sudo chgrp <group-name> <media-path>/<share-name-1>
sudo chmod g+s <media-path>/<share-name-1>
```

**A copy stalls or drops halfway**
Check `sudo smbstatus` for the session and the machine's own log file under `/var/log/samba/`. A
restart of `smbd` during the transfer, a full filesystem, or the array unmounting under the share all
present this way; `df -h <media-path>` rules out the second.
