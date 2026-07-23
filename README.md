# Matrix — one-command Synapse + Synapse-Admin installer

Installs a **complete, working Matrix homeserver** on a fresh Ubuntu/Debian box with a single
command: [Synapse](https://github.com/element-hq/synapse) on PostgreSQL, behind nginx with TLS,
plus the [Synapse-Admin](https://github.com/Awesome-Technologies/synapse-admin) web UI and the
[Element Web](https://github.com/element-hq/element-web) chat client — all wired together.

```bash
curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Matrix/main/install-matrix.sh | sudo bash
```

No questions asked. When it finishes it prints every credential it generated — all of them
randomised fresh for each install.

---

## What you get

| Piece | Where |
|---|---|
| **Element Web** (chat client) | `https://<server-ip>:8443/` |
| **Synapse-Admin UI** | `https://<server-ip>/` |
| **Matrix client API** | `https://<server-ip>/_matrix` |
| **Synapse admin API** | `https://<server-ip>/_synapse/admin` |
| **Federation** | port `8448` (+ `/.well-known/matrix/server`) |
| **Admin account** | `@admin:<server-name>`, random password, printed at the end |

Both web apps are pinned to this homeserver, so nobody has to type a server URL: Element via
`default_server_config` + `disable_custom_urls`, Synapse-Admin via `restrictBaseUrl`.

### Why Element is on a separate port

Element Web's [Important Security Notes](https://github.com/element-hq/element-web/blob/develop/apps/web/README.md#important-security-notes)
are explicit:

> We do not recommend running Element from the same domain name as your Matrix homeserver. The
> reason is the risk of XSS (cross-site-scripting) vulnerabilities that could occur if someone
> caused Element to load and render malicious user generated content from a Matrix API which then
> had trusted access to Element (or other apps) due to sharing the same domain.

A different port is a different web origin, so Element gets its own `localStorage`/DOM sandbox
rather than sharing one with the homeserver. Change it with `ELEMENT_PORT`, or skip Element
entirely with `SKIP_ELEMENT=yes`.

Synapse-Admin *is* served on the homeserver's origin (that's what keeps its admin-API calls
CORS-free). For an internet-facing deployment, put all three on separate hostnames with real
certificates.

### First run with the self-signed certificate

Element and the homeserver are two different origins, and browsers store certificate exceptions
per host **and port**. Visit both once and accept the warning on each, otherwise Element will
report that it cannot reach the homeserver:

1. `https://<server-ip>/` — homeserver + admin UI
2. `https://<server-ip>:8443/` — Element

This goes away entirely once you use a real certificate.

## Requirements

- Ubuntu **22.04 / 24.04 / 26.04** or Debian **11 / 12 / 13**
- Root access, ~2 GB RAM, ~5 GB disk
- Outbound internet access

### Tested

| Platform | Python | nginx | PostgreSQL | Result |
|---|---|---|---|---|
| Ubuntu 24.04.4 LTS | 3.12 | 1.24 | 16 | ✅ 9/9 self-tests |
| Ubuntu 26.04 LTS | 3.14 | 1.28 | 18 | ✅ 9/9 self-tests, survives reboot |

Verified on both: admin login, authenticated Synapse admin API, room creation, sending and
reading back a message over HTTPS, federation endpoint on `8448`, and a real browser login to
the Synapse-Admin UI.

Synapse is installed from PyPI into an isolated virtualenv at `/opt/synapse`, using the
`cp310-abi3` wheels. That means it works on **Python 3.10 through 3.14** and does **not** depend on
`packages.matrix.org` publishing an apt suite for your release — which is why this works on
Ubuntu 26.04, where the official Matrix apt repo has no `resolute` suite.

## Options

Everything is optional; the defaults produce a working server.

```bash
# Use a real hostname instead of the machine's IP (affects every user ID, cannot
# be changed later without wiping the database)
curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Matrix/main/install-matrix.sh \
  | sudo SERVER_NAME=matrix.example.com bash

# Open public registration (closed by default)
... | sudo ENABLE_REGISTRATION=yes bash

# Choose the admin name / password, or pin a Synapse version
... | sudo ADMIN_USER=root ADMIN_PASSWORD='hunter2' SYNAPSE_VERSION=1.157.1 bash
```

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_NAME` | primary IP | Matrix `server_name` — the part after the `:` in user IDs |
| `ADMIN_USER` | `admin` | Admin account localpart |
| `ADMIN_PASSWORD` | random | Admin password |
| `ENABLE_REGISTRATION` | `no` | Allow anyone to sign up |
| `SYNAPSE_VERSION` | latest | Pin a specific Synapse release |
| `ELEMENT_PORT` | `8443` | Port Element Web listens on |
| `SKIP_ELEMENT` | `no` | Set to `yes` to not install the chat client |

## What the installer does

1. Installs PostgreSQL, nginx and build dependencies
2. Creates the `synapse` database with the **`C` collation Synapse requires**
3. Creates a venv at `/opt/synapse` and installs Synapse + a PostgreSQL driver from PyPI
4. Generates `homeserver.yaml` with random `registration_shared_secret`, `macaroon_secret_key`
   and `form_secret`, pointed at PostgreSQL, listening on `127.0.0.1:8008` with `x_forwarded`
5. Installs and starts the `matrix-synapse` systemd service
6. Registers the admin account with a random password
7. Downloads the latest Synapse-Admin release and pins it to this homeserver
8. Issues a self-signed cert and configures nginx (UI at `/`, Matrix at `/_matrix`)
9. **Self-tests**: service health, HTTPS API, UI load, real admin login, and a real authenticated
   call to the admin API — then prints the credentials

If any self-test fails the script exits non-zero and tells you which one.

## Connecting clients

### The homeserver URL

Every client asks for a **homeserver URL**. It is:

```
https://<server-ip>
```

**Not** `https://<server-ip>:8443`. Port 8443 only hosts the *web copy* of Element — it's a static
site, not a homeserver. This is a nasty trap: `https://<server-ip>:8443/_matrix/client/versions`
returns **HTTP 200 with Element's HTML** (the single-page-app catch-all), so a client sees a 200,
finds no valid Matrix API, and reports *"Homeserver URL does not appear to be a valid Matrix
homeserver"*. If you see that error, check the port first.

### Browser

Just open `https://<server-ip>:8443/` and accept the certificate warning. Visit
`https://<server-ip>/` once and accept it there too, or the client can't reach the homeserver.

### Element Desktop

Element Desktop is Electron. Unlike a browser it offers **no "proceed anyway" button** for an
untrusted certificate — it just reports the server as invalid.

**Quit Element completely first.** It is a single-instance app that hides in the system tray, so
launching it again with a flag simply re-focuses the running copy and the flag is ignored. Quit
from the tray icon, and check for a leftover process (Task Manager / `pkill element`).

Then, for testing:

```bash
# Linux
element-desktop --ignore-certificate-errors

# macOS
/Applications/Element.app/Contents/MacOS/Element --ignore-certificate-errors
```

```powershell
# Windows (PowerShell)
& "$env:LOCALAPPDATA\element-desktop\Element.exe" --ignore-certificate-errors
```

Better, and permanent — trust the certificate instead. Export it from the server:

```bash
openssl s_client -connect <server-ip>:443 </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > matrix.crt
```

The installer marks the certificate `basicConstraints CA:TRUE`, which Chromium/Electron requires
before it will accept an imported root, so this works:

```powershell
# Windows, as Administrator
Import-Certificate -FilePath matrix.crt -CertStoreLocation Cert:\LocalMachine\Root
```

```bash
# Linux
sudo cp matrix.crt /usr/local/share/ca-certificates/matrix.crt && sudo update-ca-certificates
```

macOS: open **Keychain Access** → System → drag in `matrix.crt` → set it to **Always Trust**.

### Mobile

**Android.** Element Android shows its own "unrecognised certificate" dialog with a SHA-256
fingerprint and a **TRUST** button — accept it there. Do *not* bother installing the certificate
into Android's system credential store: Element Android
[does not read the user certificate store](https://github.com/vector-im/element-android/issues/4253).
Compare the fingerprint it shows against the server's:

```bash
openssl s_client -connect <server-ip>:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

Be aware of a long-standing bug where trusting the certificate can
[loop forever](https://github.com/element-hq/element-android/issues/7259), and that changing the
server's certificate later can strand clients on
["unknown fingerprint"](https://github.com/element-hq/element-android/issues/3867) until you log
out with "clear data" and back in.

**iOS.** Install the certificate as a configuration profile (mail it to yourself or serve it over
HTTP), then **Settings → General → About → Certificate Trust Settings** and enable full trust for
it. The second step is easy to miss and nothing works without it.

**For mobile, a real certificate is genuinely the path of least pain.** Self-signed certificates
on phones are fragile in a way they aren't on desktop. Install with a real `SERVER_NAME` and run
`certbot --nginx -d matrix.example.com`. Remember `SERVER_NAME` is baked into every user ID and
cannot be changed later without wiping the database, so decide before you install.

## After installing

Credentials are printed at the end and also saved to `/root/matrix-credentials.txt` (mode `600`).

```bash
systemctl status matrix-synapse nginx     # status
journalctl -u matrix-synapse -f           # logs
/opt/synapse/homeserver.yaml              # config

# add another user
/opt/synapse/venv/bin/register_new_matrix_user \
  -c /opt/synapse/homeserver.yaml http://127.0.0.1:8008
```

Point any Matrix client (Element, FluffyChat, …) at `https://<server-name>`.

### Going to production

The defaults are built for a private/LAN server. For a public homeserver you should:

- Set `SERVER_NAME` to a real domain **at install time** (it cannot be changed afterwards)
- Replace the self-signed certificate with a real one, e.g.
  `certbot --nginx -d matrix.example.com` — federation with other homeservers requires a
  publicly trusted certificate
- Open ports `443` and `8448`

## Uninstall

```bash
systemctl disable --now matrix-synapse
rm -rf /opt/synapse /opt/synapse-admin /etc/systemd/system/matrix-synapse.service
rm -f /etc/nginx/sites-enabled/matrix /etc/nginx/sites-available/matrix
sudo -u postgres psql -c 'DROP DATABASE synapse' -c 'DROP ROLE synapse'
systemctl daemon-reload && systemctl reload nginx
```

## Credits

- [Synapse](https://github.com/element-hq/synapse) — Element / Matrix.org
- [Synapse-Admin](https://github.com/Awesome-Technologies/synapse-admin) — Awesome Technologies
  Innovationslabor GmbH
