# Family Trees

## What this is

A set of small, static genealogy websites — one nginx container per family, each serving a single
self-contained HTML export produced by genealogy software (the "narrated web site" style of export
that ships one big entry-point HTML file plus a folder of linked per-person pages). This host can
serve any number of them side by side; each gets its own container, its own domain and its own served
directory.

Before it is served, the raw export is edited in place: the inline `<style>` block the export tool
bakes into the page is stripped and replaced with a link to an external stylesheet, a mobile viewport
tag is added (the export tool does not produce one), and a small transliteration widget is inserted —
a round button that switches the tree between Cyrillic and Latin script, using a hand-written
dictionary for names that need a specific spelling and falling back to a plain character-by-character
transliteration for everything else.

Unlike the photo gallery and the blog on this same host, a family tree's router carries **no
bypass of its own** — it inherits the default authenticating chain like everything else on this host's
`https` entrypoint, so visitors are sent through single sign-on. If you want a tree to be reachable
without a login, you have to add that bypass yourself; nothing here does it for you.

The served files live under `/opt/<family-name>` on the host, **not** under the shared `./data`
directory the rest of this stack uses. That is a real difference from every other guide here — keep
it in mind when you go looking for the content afterwards.

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

### The shared `proxy` bridge network exists

Every container in this stack sits on one user-defined bridge network called `proxy`, with a fixed
address, so services can reach each other by container name and the reverse proxy always knows where
to send a request.

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
**outside** that pool so nothing is ever assigned an address you have reserved.

### The reverse proxy (Traefik) is running

```bash
docker ps --filter 'name=^traefik$'
docker exec traefik traefik healthcheck --ping
```

`healthcheck --ping` exits 0 only when Traefik's own ping endpoint answers, which means the static
configuration parsed and the entrypoints are bound. Confirm from outside that TLS terminates:

```bash
curl -sI https://proxy.your-domain.com | head -1
```

### Single sign-on (Authelia) is running, and this domain has a rule

Because a family tree's router carries no bypass, the `https` entrypoint's default chain sends every
request through Authelia's forward-auth first.

```bash
docker ps --filter 'name=^authelia$'
docker exec authelia wget -qO- http://localhost:9091/api/health
```

The tree's domain needs its own entry in Authelia's access-control rules — `default_policy: deny`
means a domain nobody wrote a rule for is refused outright, logged in or not:

```bash
docker exec authelia grep -n -A20 '^access_control' /config/configuration.yml
```

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
      - "tree-<family-name>.your-domain.com"
      policy: two_factor
```

`two_factor` is the right policy here — this is the opposite case from the gallery or the blog,
where the whole point is a public site; a family tree is meant to be seen only by people who can log
in.

### The site's DNS name resolves to this host

```bash
dig +short tree-<family-name>.your-domain.com
```

### The genealogy export already exists on this host

You need the export's entry-point HTML file and its matching support folder (the folder the export
tool generated alongside it, holding every page it links to — individual people, sources, media)
somewhere readable on this machine, e.g. staged under your home directory after transferring it here
however you like (`scp`, a USB drive, whatever got it onto the box). Confirm both pieces are present
before you start:

```bash
ls -la ~/family-export/<family-name>/<family-name>.html
ls ~/family-export/<family-name>/<family-name>.html.files | head
```

If the support folder is missing or incomplete, every internal link on the rendered site (photos,
individual pages, sources) will 404 — the entry-point file is not self-contained, it is a shell that
references hundreds of sibling files.

---

## Setup

### Overview

1. Create the directory the site will be served from.
2. Copy the export into it.
3. Strip the export's inline styles and add a mobile viewport tag and the external stylesheet link.
4. Add the Cyrillic/Latin transliteration widget.
5. Install the shared stylesheet, script and translation dictionary.
6. Rename the entry-point file to `index.html`.
7. Start the nginx container.
8. Repeat for every additional family.

---

#### Step 1: Create the served directory

```bash
sudo mkdir -p /opt/<family-name>
sudo chown <username>:docker /opt/<family-name>
sudo chmod 0755 /opt/<family-name>
```

**Explanation**: this directory is bind-mounted read-only into the container as its entire nginx
document root, so everything the site needs — the entry page, every linked person page, the
stylesheet, the script, the dictionary — has to live here flat, at the top level. There is no
`./data` involvement for this service; the container reads straight off this path.

---

#### Step 2: Copy the export in

```bash
rsync -a --chown=<username>:docker --chmod=755 --omit-dir-times \
  --exclude '<family-name>.html' \
  ~/family-export/<family-name>/ /opt/<family-name>/

sudo cp ~/family-export/<family-name>/<family-name>.html /opt/<family-name>/<family-name>.html
sudo chown <username>:docker /opt/<family-name>/<family-name>.html
sudo chmod 0755 /opt/<family-name>/<family-name>.html
```

**Explanation**: the entry-point HTML is copied separately from the rest of the export, because the
next two steps edit it in place — keeping it out of the bulk `rsync` means a second sync (say, after
regenerating the tree from newer genealogy data) never silently overwrites your edits before you have
made them. The `--exclude` on the bulk sync is what keeps the two operations from racing each other.

---

#### Step 3: Strip inline styles, add the viewport tag and the stylesheet link

```bash
HTML="/opt/<family-name>/<family-name>.html"

sudo sed -i 's/<style[^>]*>.*<\/style>//g' "$HTML"

sudo sed -i '/<meta http-equiv="X-UA-Compatible" content="IE=9">/a\
<meta name="viewport" content="width=device-width, initial-scale=1.0">\
<link rel="stylesheet" href="styles.css">' "$HTML"
```

**Explanation**: the export bakes a large inline `<style>` block straight into the page, which fights
the external stylesheet on specificity and roughly doubles the page weight for no benefit once the
same rules are served as a separate, cacheable file — so it comes out. The export was never built to
be responsive either; without the viewport tag, mobile browsers render the page at desktop width and
then scale it down, which is unreadable on a phone. Both edits anchor on the `X-UA-Compatible` meta
tag that every export of this kind carries near the top of `<head>`, so the insertion point is stable
across different families' exports even though the rest of the page differs.

Note the `sed` here only strips a `<style>` block that lives on a single line, which is what this
export tool produces; if a future export ever wraps its inline styles across multiple lines, this
one-liner will leave them behind and you will need a multi-line-aware substitution instead.

---

#### Step 4: Add the transliteration widget

```bash
sudo sed -i 's|</script>|</script>\n<script>var reset = 0;</script>\n<script src="cyr_to_lat.js"></script>\n<button class="button-round" onclick="toggleCyrLat()"><b>Ср/En</b></button>|' "$HTML"
```

**Explanation**: this appends right after the export's own last `</script>` tag, giving visitors a
floating round button that swaps every visible name between Cyrillic and Latin script. `reset` is a
counter the script increments on each toggle; past the second click it forces a full page reload
rather than re-walking the DOM again, which is a deliberate shortcut around re-toggling text nodes
that have already been converted once.

---

#### Step 5: Install the shared stylesheet, script and dictionary

```bash
sudo tee /opt/<family-name>/styles.css >/dev/null <<'EOF'
/* Global Reset */
* {
    padding: 0;
    margin: 0;
    border: 0;
    box-sizing: border-box;
}

/* Modal Styles */
.modal {
    display: none;
    position: fixed;
    z-index: 1;
    padding-top: 2%;
    left: 0;
    top: 0;
    width: 100%;
    height: 100%;
    overflow: auto;
    background-color: rgba(0, 0, 0, 0.4); /* Black with 40% opacity */
}

.modal-content {
    background-color: #fefefe;
    margin: auto;
    padding: 10px;
    border: 1px solid #888;
    width: 70%;
    height: 87%;
}

/* Content within the modal */
#modalContent, .modal-frame {
    border: 0;
    width: 100%;
    height: 98%; /* Adjust to fit within modal */
}

/* Close, Back, Tree Buttons */
.close, .back, .tree {
    color: #aaaaaa;
    float: right;
    font-size: 28px;
    font-weight: bold;
    margin-right: 10px;
    cursor: pointer;
}

.close:hover, .close:focus, .back:hover, .back:focus, .tree:hover, .tree:focus {
    color: #000;
    text-decoration: none;
}

/* Round Button for Language Toggle */
.button-round {
    position: fixed;
    bottom: 20px;
    right: 20px;
    z-index: 1000; /* Ensure it appears above other content */
    width: 60px;
    height: 60px;
    background-color: rgba(255, 255, 255, 0.5); /* White with 50% transparency */
    border: none;
    border-radius: 50%;
    box-shadow: 0px 4px 6px rgba(0, 0, 0, 0.1); /* Subtle shadow */
    cursor: pointer;
    transition: background-color 0.3s ease, transform 0.3s ease;
}

.button-round:hover {
    background-color: rgba(255, 255, 255, 0.8); /* Less transparent on hover */
    transform: scale(1.1); /* Slightly enlarge on hover */
}

.button-round:active {
    transform: scale(0.95); /* Slightly shrink on click */
}

/* Responsive Design Adjustments */
@media (max-width: 600px) {
    .modal-content {
        width: 90%; /* Increase width to nearly full screen */
        height: 80%; /* Adjust height to fit better on small screens */
        padding: 10px; /* Increase padding for better spacing */
    }

    #modalContent, .modal-frame {
        height: 90%; /* Adjust height to ensure no overflow */
    }

    .close, .back, .tree {
        font-size: 24px; /* Decrease font size for smaller screens */
    }
}

/* Ensure body and html take up the full height */
html, body {
    height: 100%;
    margin: 0;
    padding: 0;
    overflow-x: auto; /* Allows horizontal scrolling if needed */
    overflow-y: auto; /* Ensures vertical scrolling */
}
EOF

sudo tee /opt/<family-name>/cyr_to_lat.js >/dev/null <<'EOF'
async function loadDictionary() {
    const response = await fetch('dictionary.json');
    const dictionary = await response.json();
    return dictionary;
}

function cyrToLat(text) {
    const cyrillic = [
        'А', 'Б', 'В', 'Г', 'Д', 'Ђ', 'Е', 'Ж', 'З', 'И', 'Ј', 'К', 'Л', 'Љ', 'М', 'Н', 'Њ', 'О', 'П', 'Р', 'С', 'Т', 'Ћ', 'У', 'Ф', 'Х', 'Ц', 'Ч', 'Џ', 'Ш',
        'а', 'б', 'в', 'г', 'д', 'ђ', 'е', 'ж', 'з', 'и', 'ј', 'к', 'л', 'љ', 'м', 'н', 'њ', 'о', 'п', 'р', 'с', 'т', 'ћ', 'у', 'ф', 'х', 'ц', 'ч', 'џ', 'ш'
    ];
    const latin = [
        'A', 'B', 'V', 'G', 'D', 'Đ', 'E', 'Ž', 'Z', 'I', 'J', 'K', 'L', 'Lj', 'M', 'N', 'Nj', 'O', 'P', 'R', 'S', 'T', 'Ć', 'U', 'F', 'H', 'C', 'Č', 'Dž', 'Š',
        'a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r', 's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š'
    ];

    let newText = text;
    for (let i = 0; i < cyrillic.length; i++) {
        newText = newText.split(cyrillic[i]).join(latin[i]);
    }
    return newText;
}

async function toggleCyrLat() {
    console.log('Usao');
    let convertedText = '';
    const dictionary = await loadDictionary();
    console.log(dictionary);
    const textElements = document.querySelectorAll('text'); // Using 'text' as the selector

    textElements.forEach(element => {
        const currentText = element.textContent.trim(); // Trim to avoid leading/trailing whitespace issues
        // Check if the text is in the dictionary
        if (dictionary.hasOwnProperty(currentText)) {
            convertedText = dictionary[currentText]; // Return the translated text
        } else {
            convertedText = cyrToLat(currentText);
        }  
        element.textContent = convertedText;
    });

    reset = reset + 1;
    if (reset > 1) {
        location.reload();
    }
}
EOF

sudo tee /opt/<family-name>/dictionary.json >/dev/null <<'EOF'
{
  "<cyrillic-word>": "<latin-or-english-word>",
  "<cyrillic-word-2>": "<latin-or-english-word-2>"
}
EOF

sudo chown <username>:docker /opt/<family-name>/styles.css /opt/<family-name>/cyr_to_lat.js /opt/<family-name>/dictionary.json
sudo chmod 0755 /opt/<family-name>/styles.css /opt/<family-name>/cyr_to_lat.js /opt/<family-name>/dictionary.json
```

**Explanation**: `styles.css` and `cyr_to_lat.js` are identical for every family tree on this host —
copy the same two files into each served directory. `dictionary.json` is the one file that differs
per deployment: it is consulted first, before the generic character-by-character transliteration, so
put in it any name whose Latin spelling you want to be specific rather than phonetic (a name that is
conventionally spelled a particular way in Latin script, for instance). The widget's `querySelectorAll('text')`
selector is what genealogy exports built as inline SVG diagrams use for name labels — it will not find
anything to translate on an export that renders names as plain HTML text instead of SVG `<text>`
nodes.

---

#### Step 6: Rename to `index.html`

```bash
sudo rm -f /opt/<family-name>/index.html
sudo mv /opt/<family-name>/<family-name>.html /opt/<family-name>/index.html
```

**Explanation**: nginx serves `index.html` by default for a directory request, so this is what makes
`https://tree-<family-name>.your-domain.com/` resolve to the tree without a filename in the URL. The
`rm -f` first is what makes this step safe to repeat — re-running it after regenerating the export
would otherwise fail with "file exists" on the second pass.

---

#### Step 7: Start the container

```bash
PROBE=$(basename "$(ls /opt/<family-name>/<family-name>.html.files/*.html | head -1)")

docker run -d \
  --name <container> \
  --restart unless-stopped \
  --network proxy \
  --ip <docker-ip> \
  -e TZ=Europe/Belgrade \
  -v /opt/<family-name>:/usr/share/nginx/html:ro \
  --label 'traefik.enable=true' \
  --label "traefik.http.routers.<container>.entrypoints=https" \
  --label "traefik.http.routers.<container>.rule=Host(\`tree-<family-name>.your-domain.com\`)" \
  --label "traefik.http.routers.<container>.tls=true" \
  --label "traefik.http.services.<container>.loadbalancer.server.port=80" \
  --health-cmd "curl -fsS -o /dev/null http://localhost/<family-name>.html.files/${PROBE}" \
  --health-interval 30s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 10s \
  nginx:latest
```

**Explanation**: the mount is read-only — this container only ever serves files, it never writes to
`/opt/<family-name>`, so a read-only bind is both correct and a small safety net against anything
inside the container trying to modify the site. The router carries no auth-bypass label, so it falls
back to the entrypoint's default chain and single sign-on applies, per *Before you start*.

The health check probes one of the export's own per-person pages rather than the front page, on the
theory that a broken export (missing the support folder from Step 2) would still serve the front page
with a 200 while every link on it 404s — probing a linked page catches that. It has to be **a page
that actually exists in your export**, which is why it is discovered with `ls` rather than
hard-coded: different genealogy databases produce different person-page filenames, and a probe path
copied from another family's setup will report this container unhealthy forever even though it is
serving correctly. Also confirm `curl` is actually present in the image you are running before relying
on this — the official `nginx` image does not always ship it; see *Troubleshooting* if the health
check never goes green.

---

#### Step 8: Repeat for each additional family

Every family tree is fully independent: its own directory, its own container, its own address, its
own domain, its own Authelia rule.

```bash
sudo mkdir -p /opt/<family-name-2>
sudo chown <username>:docker /opt/<family-name-2>
# then repeat Steps 2–7 for the second family
```

**Explanation**: nothing is shared between trees except the two static support files copied fresh
into each directory in Step 5 — there is no multi-tenant mode, no shared state, and no reason two
trees on this host would ever conflict, other than picking the same container name, router name or
fixed address twice.

---

## Path layout

| Host path | Container path | What it is |
| --- | --- | --- |
| `/opt/<family-name>/index.html` | `/usr/share/nginx/html/index.html` | the edited entry page |
| `/opt/<family-name>/<family-name>.html.files/` | same, under `/usr/share/nginx/html/` | every page the entry links to |
| `/opt/<family-name>/styles.css` | same | shared stylesheet |
| `/opt/<family-name>/cyr_to_lat.js` | same | transliteration script |
| `/opt/<family-name>/dictionary.json` | same | this family's name dictionary |

Back up the whole `/opt/<family-name>` directory together — the entry page references every other
file in it by relative path.

---

## Values to fill in

| Placeholder | What it is | How to choose it | Used in |
| --- | --- | --- | --- |
| `<username>` | account that owns `/opt/<family-name>` | the unprivileged deploy account, group `docker` | Steps 1, 2, 5, 8 |
| `<family-name>` | the export's base filename and the served directory's name | matches the genealogy export exactly (`<family-name>.html`, `<family-name>.html.files/`) | Steps 1–8 |
| `<container>` | container, router and service name | usually `tree-<family-name>`; must be unique across the host | Step 7 |
| `<docker-ip>` | the container's fixed address on `proxy` | a free address in `<docker-subnet>`, outside the auto pool | Before you start, Step 7 |
| `<docker-subnet>` / `<docker-gateway>` / `<docker-ip-range>` | the `proxy` network's addressing | must match the existing network | Before you start |
| `tree-<family-name>.your-domain.com` | the tree's public domain | DNS record pointing at this host or at Cloudflare | Before you start, Step 7 |
| `<cyrillic-word>` / `<latin-or-english-word>` | one dictionary entry | any name you want spelled a specific way rather than transliterated phonetically | Step 5 |
| `<backup-mount>` | directory backups are written to | any path with room for the whole `/opt/<family-name>` tree | Updating & day-to-day |

---

## Verification

```bash
# container up and health check green
docker ps --filter 'name=^<container>$'
docker inspect --format '{{ .State.Health.Status }}' <container>

# the site answers through Traefik with a real certificate
curl -sI https://tree-<family-name>.your-domain.com | head -3

# a linked person page resolves, proving the support folder made it across
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://tree-<family-name>.your-domain.com/<family-name>.html.files/${PROBE}"

# the transliteration assets are actually served
curl -s -o /dev/null -w '%{http_code}\n' https://tree-<family-name>.your-domain.com/styles.css
curl -s -o /dev/null -w '%{http_code}\n' https://tree-<family-name>.your-domain.com/dictionary.json

# single sign-on is in front of it, as expected for this service
curl -sI https://tree-<family-name>.your-domain.com/ | grep -i '^location'
```

The last command should show a redirect toward `auth.your-domain.com`. If it does not — a plain 200
instead — the domain ended up with a `bypass` policy somewhere, or the router picked up a
`chain-no-auth@file` label it should not have.

---

## Updating & day-to-day

**Refresh a tree from a newer export**: repeat Steps 2 through 6 with the new export, then do
nothing else — the container mounts the directory read-only and serves whatever is on disk, so an
updated file is live immediately with no restart.

```bash
docker exec <container> nginx -s reload  # only needed if you also change nginx's own config, which this setup never does
```

**Pull a new nginx image periodically:**

```bash
docker pull nginx:latest
docker stop <container> && docker rm <container>
# re-run the docker run command from Step 7 unchanged
```

**Back up a tree:**

```bash
tar czf <backup-mount>/<family-name>-$(date +%F).tar.gz -C /opt <family-name>
```

**Logs:**

```bash
docker logs --tail 100 -f <container>
```

The official nginx image symlinks its access and error logs to stdout/stderr, so `docker logs` is the
whole story — nothing inside the container needs rotating.

---

## Rollback / Uninstall

Stop one tree but keep its files:

```bash
docker stop <container> && docker rm <container>
```

Remove one tree completely:

```bash
docker stop <container> && docker rm <container>
sudo rm -rf /opt/<family-name>
```

Then remove its rule from Authelia's access-control list and delete the DNS record. Take the backup
above first.

---

## Troubleshooting

**Health check never goes green, site works fine in a browser.**
The probe filename does not exist in this family's export, or the `curl` binary is missing from the
`nginx:latest` image you pulled (the Debian-based official image does not always ship it). Check
both:
```bash
docker exec <container> sh -c 'command -v curl || command -v wget || echo "neither present"'
docker exec <container> ls /usr/share/nginx/html/<family-name>.html.files | head
```
If neither `curl` nor `wget` is present, replace `--health-cmd` with a plain TCP probe instead
(`nc -z localhost 80`), or use `wget -q --spider` if that binary is present.

**Every page 404s except the front page.**
The `.html.files` support folder was not copied, or was excluded by the same pattern that is meant to
exclude only the entry-point HTML. Re-check Step 2 and confirm the folder exists on the host at
`/opt/<family-name>/<family-name>.html.files/`.

**Page loads unstyled.**
`styles.css` is missing or the `<link>` insertion in Step 3 did not match — confirm the export
actually contains the `X-UA-Compatible` meta tag the `sed` anchors on; some export tool versions omit
it, in which case insert the link and viewport tag by hand instead.

**The language toggle button does nothing.**
`dictionary.json` failed to load — check `docker exec <container> cat /usr/share/nginx/html/dictionary.json`
for valid JSON, and check the browser console for a fetch error. A trailing comma or an unescaped
quote in a name breaks the whole file.

**Visitors reach the tree without logging in.**
The domain picked up a `bypass` policy in Authelia, or a router-level `chain-no-auth@file` label got
copied from another service's setup. Neither belongs here; remove them.

**Visitors are refused outright, even after logging in successfully elsewhere.**
The domain has no rule in Authelia's access-control list at all, so `default_policy: deny` applies
regardless of authentication state. Add the `two_factor` rule shown in *Before you start*.

**A second tree's route disappeared from Traefik.**
Two containers used the same `<container>` value in their router labels. Router names are global in
Traefik's dynamic configuration; the last one to register wins. Rename and recreate.
