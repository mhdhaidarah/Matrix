# Matrix — one-command Synapse + Synapse-Admin installer

Installs a **complete, working Matrix homeserver** on a fresh Ubuntu/Debian box with a single
command: [Synapse](https://github.com/element-hq/synapse) on PostgreSQL, behind nginx with TLS,
plus the [Synapse-Admin](https://github.com/Awesome-Technologies/synapse-admin) web UI already
wired to it.

```bash
curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Matrix/main/install-matrix.sh | sudo bash
```

No questions asked. When it finishes it prints every credential it generated — all of them
randomised fresh for each install.

---

## What you get

| Piece | Where |
|---|---|
| **Synapse-Admin UI** | `https://<server-ip>/` |
| **Matrix client API** | `https://<server-ip>/_matrix` |
| **Synapse admin API** | `https://<server-ip>/_synapse/admin` |
| **Federation** | port `8448` (+ `/.well-known/matrix/server`) |
| **Admin account** | `@admin:<server-name>`, random password, printed at the end |

Synapse-Admin is served at the **same origin** as the Matrix API, so there is no CORS
configuration to get wrong and only **one** self-signed certificate for your browser to trust.
The UI's homeserver field is pre-pinned to this server via `restrictBaseUrl`.

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
