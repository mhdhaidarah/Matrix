#!/usr/bin/env bash
#==============================================================================
# Matrix Synapse + Synapse-Admin unattended installer for Ubuntu / Debian
# https://github.com/mhdhaidarah/Matrix
#
# One command, no questions, fully working Matrix homeserver:
#
#     curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Matrix/main/install-matrix.sh | sudo bash
#
# What it does, end to end:
#   - Installs PostgreSQL (with the C collation Synapse requires) and nginx
#   - Installs Synapse from PyPI into an isolated venv at /opt/synapse
#     (uses the cp310-abi3 wheels, so it works on Python 3.10 -> 3.14 and does
#      NOT depend on packages.matrix.org having a suite for your release)
#   - Generates homeserver.yaml with random secrets and a PostgreSQL backend
#   - Creates a systemd service (matrix-synapse)
#   - Creates an admin account with a random password
#   - Installs Synapse-Admin (the web admin UI) and wires it to this homeserver
#   - Installs Element Web (the chat client) on its own port, because Element
#     must NOT share an origin with the homeserver (XSS risk - upstream's
#     "Important Security Notes" say so explicitly)
#   - Generates a self-signed TLS cert and configures nginx
#   - Prints every generated credential at the end
#
# Optional environment overrides:
#   SERVER_NAME=matrix.example.com   Matrix server_name (default: primary IP)
#   ADMIN_USER=admin                 Admin localpart      (default: admin)
#   ADMIN_PASSWORD=...               Admin password       (default: random)
#   ENABLE_REGISTRATION=yes          Open public registration (default: no)
#   SYNAPSE_VERSION=1.157.1          Pin a Synapse version (default: latest)
#   ELEMENT_PORT=8443                Port for Element Web  (default: 8443)
#   SKIP_ELEMENT=yes                 Don't install Element Web (default: no)
#
# Run it as root:  sudo bash install-matrix.sh
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# 0. Pre-flight
#------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m!!  $*\033[0m"; }
die()  { echo -e "\033[1;31mXX  $*\033[0m" >&2; exit 1; }

[[ -f /etc/os-release ]] || die "Unsupported OS: /etc/os-release not found"
. /etc/os-release
case "${ID}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "This installer supports Debian/Ubuntu only (found: ${PRETTY_NAME:-$ID})" ;;
esac
log "Detected ${PRETTY_NAME}"

# Auto-detect primary IP (used for server_name, the TLS cert and nginx)
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
[[ -n "${SERVER_IP}" ]] || SERVER_IP="$(hostname -I | awk '{print $1}')"
[[ -n "${SERVER_IP}" ]] || die "Could not determine this machine's IP address"

# Matrix server_name. This becomes part of every user ID (@user:SERVER_NAME)
# and CANNOT be changed after install without wiping the database.
SERVER_NAME="${SERVER_NAME:-${SERVER_IP}}"
PUBLIC_BASEURL="https://${SERVER_NAME}/"

SYN_DIR="/opt/synapse"
SYN_CONF="${SYN_DIR}/homeserver.yaml"
SYN_DATA="${SYN_DIR}/data"
ADMIN_DIR="/opt/synapse-admin"
ELEMENT_DIR="/opt/element"
ELEMENT_PORT="${ELEMENT_PORT:-8443}"
CRED_FILE="/root/matrix-credentials.txt"

case "${SKIP_ELEMENT:-no}" in
  yes|true|1) INSTALL_ELEMENT=0 ;;
  *)          INSTALL_ELEMENT=1 ;;
esac

# --- Everything below is randomly generated fresh on every install -----------
rand() { openssl rand -base64 "$1" | tr -d '/+=\n' | cut -c1-"$2"; }
DB_PASSWORD="$(rand 32 24)"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(rand 24 20)}"
REGISTRATION_SHARED_SECRET="$(rand 48 40)"
MACAROON_SECRET_KEY="$(rand 48 40)"
FORM_SECRET="$(rand 48 40)"

ENABLE_REGISTRATION="${ENABLE_REGISTRATION:-no}"
case "${ENABLE_REGISTRATION,,}" in
  yes|true|1) REG_ENABLED="true" ;;
  *)          REG_ENABLED="false" ;;
esac

#------------------------------------------------------------------------------
# 1. System packages
#------------------------------------------------------------------------------
log "Installing system packages (PostgreSQL, nginx, build deps)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# build-essential/python3-dev/libpq-dev are insurance: Synapse itself ships
# abi3 wheels, but a brand-new Python (e.g. 3.14 on Ubuntu 26.04) may not have
# binary wheels for every transitive dependency yet, and pip then builds them.
apt-get install -y -qq --no-install-recommends \
  postgresql postgresql-contrib \
  nginx \
  python3 python3-venv python3-dev \
  build-essential pkg-config \
  libpq-dev libssl-dev libffi-dev libjpeg-dev libwebp-dev zlib1g-dev \
  libxml2-dev libxslt1-dev libicu-dev \
  curl ca-certificates openssl tar

systemctl enable --now postgresql

#------------------------------------------------------------------------------
# 2. PostgreSQL database
#
# Synapse REFUSES to start unless the database was created with C collation
# and C ctype, so template0 + explicit LC_* is mandatory here.
#------------------------------------------------------------------------------
log "Creating PostgreSQL role and database (C collation)"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'synapse') THEN
      CREATE ROLE synapse LOGIN PASSWORD '${DB_PASSWORD}';
   ELSE
      ALTER ROLE synapse PASSWORD '${DB_PASSWORD}';
   END IF;
END \$\$;
SELECT 'CREATE DATABASE synapse
          ENCODING ''UTF8''
          LC_COLLATE ''C''
          LC_CTYPE ''C''
          TEMPLATE template0
          OWNER synapse'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'synapse')\gexec
SQL

# Fail loudly now rather than with a cryptic Synapse error later.
COLLATE="$(sudo -u postgres psql -tAc "SELECT datcollate FROM pg_database WHERE datname='synapse'")"
[[ "${COLLATE}" == "C" ]] || die "Database 'synapse' has collation '${COLLATE}', expected 'C'. Drop it and re-run."

#------------------------------------------------------------------------------
# 3. Synapse into a venv
#------------------------------------------------------------------------------
log "Creating the synapse service account and virtualenv"
if ! id synapse &>/dev/null; then
  adduser --system --group --home "${SYN_DIR}" --no-create-home synapse
fi
mkdir -p "${SYN_DIR}" "${SYN_DATA}/media" "${SYN_DIR}/log"

python3 -m venv "${SYN_DIR}/venv"
"${SYN_DIR}/venv/bin/pip" install -q --upgrade pip wheel setuptools

log "Installing Synapse from PyPI (this is the slow part, a few minutes)"
if [[ -n "${SYNAPSE_VERSION:-}" ]]; then
  "${SYN_DIR}/venv/bin/pip" install -q "matrix-synapse==${SYNAPSE_VERSION}"
else
  "${SYN_DIR}/venv/bin/pip" install -q matrix-synapse
fi

# PostgreSQL driver: prefer the prebuilt binary wheel, fall back to building
# psycopg2 from source (libpq-dev is installed above) on very new Pythons.
if ! "${SYN_DIR}/venv/bin/pip" install -q psycopg2-binary 2>/dev/null; then
  warn "psycopg2-binary has no wheel for this Python, building psycopg2 from source"
  "${SYN_DIR}/venv/bin/pip" install -q psycopg2
fi

SYNAPSE_VER="$("${SYN_DIR}/venv/bin/python" -c 'import synapse; print(synapse.__version__)')"
log "Installed Synapse ${SYNAPSE_VER}"

#------------------------------------------------------------------------------
# 4. homeserver.yaml
#------------------------------------------------------------------------------
log "Generating homeserver.yaml for server_name '${SERVER_NAME}'"
if [[ ! -f "${SYN_CONF}" ]]; then
  "${SYN_DIR}/venv/bin/python" -m synapse.app.homeserver \
    --server-name "${SERVER_NAME}" \
    --config-path "${SYN_CONF}" \
    --generate-config \
    --report-stats=no \
    --data-directory "${SYN_DATA}" >/dev/null
fi

# Patch the generated config: swap SQLite for PostgreSQL, pin our secrets and
# make the listener behave correctly behind the nginx reverse proxy.
SYN_CONF="${SYN_CONF}" \
SERVER_NAME="${SERVER_NAME}" \
PUBLIC_BASEURL="${PUBLIC_BASEURL}" \
SYN_DATA="${SYN_DATA}" \
DB_PASSWORD="${DB_PASSWORD}" \
REGISTRATION_SHARED_SECRET="${REGISTRATION_SHARED_SECRET}" \
MACAROON_SECRET_KEY="${MACAROON_SECRET_KEY}" \
FORM_SECRET="${FORM_SECRET}" \
REG_ENABLED="${REG_ENABLED}" \
"${SYN_DIR}/venv/bin/python" - <<'PYPATCH'
import os, yaml

path = os.environ["SYN_CONF"]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}

cfg["server_name"]     = os.environ["SERVER_NAME"]
cfg["public_baseurl"]  = os.environ["PUBLIC_BASEURL"]
cfg["pid_file"]        = "/opt/synapse/homeserver.pid"
cfg["signing_key_path"]= "/opt/synapse/%s.signing.key" % os.environ["SERVER_NAME"]

# PostgreSQL instead of the generated SQLite block
cfg["database"] = {
    "name": "psycopg2",
    "txn_limit": 10000,
    "args": {
        "user": "synapse",
        "password": os.environ["DB_PASSWORD"],
        "database": "synapse",
        "host": "127.0.0.1",
        "port": 5432,
        "cp_min": 5,
        "cp_max": 10,
    },
}

# Single client+federation listener on loopback; nginx terminates TLS.
cfg["listeners"] = [{
    "port": 8008,
    "tls": False,
    "type": "http",
    "x_forwarded": True,          # trust nginx's X-Forwarded-For
    "bind_addresses": ["127.0.0.1"],
    "resources": [{"names": ["client", "federation"], "compress": False}],
}]

cfg["media_store_path"]  = os.path.join(os.environ["SYN_DATA"], "media")
cfg["max_upload_size"]   = "100M"
cfg["enable_registration"] = os.environ["REG_ENABLED"] == "true"
if cfg["enable_registration"]:
    # Required by Synapse when registration is open without email/captcha
    cfg["enable_registration_without_verification"] = True
cfg["registration_shared_secret"] = os.environ["REGISTRATION_SHARED_SECRET"]
cfg["macaroon_secret_key"]        = os.environ["MACAROON_SECRET_KEY"]
cfg["form_secret"]                = os.environ["FORM_SECRET"]
cfg["report_stats"]               = False
cfg["suppress_key_server_warning"] = True
cfg["log_config"] = "/opt/synapse/log.config"

# Sensible defaults for a self-hosted server
cfg["url_preview_enabled"] = False
cfg["password_config"] = {"enabled": True}

with open(path, "w") as f:
    f.write("# Generated by install-matrix.sh - https://github.com/mhdhaidarah/Matrix\n")
    f.write("# Full reference: https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html\n")
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("homeserver.yaml patched")
PYPATCH

# Logging config (Synapse needs an explicit one when log_config is set)
cat > "${SYN_DIR}/log.config" <<'LOGCONF'
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: /opt/synapse/log/homeserver.log
    when: midnight
    backupCount: 7
    encoding: utf8
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.SQL:
    level: INFO
root:
  level: INFO
  handlers: [file, console]
disable_existing_loggers: false
LOGCONF

chown -R synapse:synapse "${SYN_DIR}"
chmod 640 "${SYN_CONF}"

#------------------------------------------------------------------------------
# 5. systemd service
#------------------------------------------------------------------------------
log "Installing the matrix-synapse systemd service"
cat > /etc/systemd/system/matrix-synapse.service <<UNIT
[Unit]
Description=Matrix Synapse homeserver
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
User=synapse
Group=synapse
WorkingDirectory=${SYN_DIR}
ExecStart=${SYN_DIR}/venv/bin/python -m synapse.app.homeserver --config-path=${SYN_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
SyslogIdentifier=matrix-synapse
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SYN_DIR}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now matrix-synapse

log "Waiting for Synapse to become healthy"
for i in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:8008/health >/dev/null 2>&1; then
    echo "Synapse is up (after ${i}s)"; break
  fi
  if [[ $i -eq 60 ]]; then
    journalctl -u matrix-synapse -n 60 --no-pager || true
    die "Synapse did not start within 60s - see the log above"
  fi
  sleep 1
done

#------------------------------------------------------------------------------
# 6. Admin account
#------------------------------------------------------------------------------
log "Creating the admin account '@${ADMIN_USER}:${SERVER_NAME}'"
"${SYN_DIR}/venv/bin/register_new_matrix_user" \
  -u "${ADMIN_USER}" \
  -p "${ADMIN_PASSWORD}" \
  -a \
  -c "${SYN_CONF}" \
  http://127.0.0.1:8008 || warn "Admin user may already exist - keeping the existing one"

#------------------------------------------------------------------------------
# 7. Synapse-Admin web UI
#------------------------------------------------------------------------------
log "Installing Synapse-Admin"
SA_TAG="$(curl -fsSL https://api.github.com/repos/Awesome-Technologies/synapse-admin/releases/latest \
          | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)"
[[ -n "${SA_TAG}" ]] || SA_TAG="0.11.4"
SA_URL="https://github.com/Awesome-Technologies/synapse-admin/releases/download/${SA_TAG}/synapse-admin-${SA_TAG}.tar.gz"

rm -rf "${ADMIN_DIR}" /tmp/synapse-admin-dl
mkdir -p /tmp/synapse-admin-dl
curl -fsSL "${SA_URL}" -o /tmp/synapse-admin-dl/sa.tar.gz \
  || die "Could not download Synapse-Admin ${SA_TAG} from ${SA_URL}"
tar xzf /tmp/synapse-admin-dl/sa.tar.gz -C /tmp/synapse-admin-dl
mv "/tmp/synapse-admin-dl/synapse-admin-${SA_TAG}" "${ADMIN_DIR}"
rm -rf /tmp/synapse-admin-dl

# Pin the UI to THIS homeserver so the login form has nothing to get wrong.
cat > "${ADMIN_DIR}/config.json" <<SACONF
{
  "restrictBaseUrl": "https://${SERVER_NAME}"
}
SACONF
chown -R www-data:www-data "${ADMIN_DIR}"
log "Installed Synapse-Admin ${SA_TAG}"

#------------------------------------------------------------------------------
# 7b. Element Web (chat client)
#
# Served on its own port, NOT on the homeserver's origin. Upstream is explicit:
# "We do not recommend running Element from the same domain name as your Matrix
# homeserver ... risk of XSS vulnerabilities". A different port is a different
# web origin, which gives Element its own localStorage/DOM sandbox.
#------------------------------------------------------------------------------
ELEMENT_TAG=""
if [[ ${INSTALL_ELEMENT} -eq 1 ]]; then
  log "Installing Element Web (chat client)"
  ELEMENT_TAG="$(curl -fsSL https://api.github.com/repos/element-hq/element-web/releases/latest \
                 | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)"
  [[ -n "${ELEMENT_TAG}" ]] || ELEMENT_TAG="v1.12.24"
  EL_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_TAG}.tar.gz"

  rm -rf /tmp/element-dl
  mkdir -p /tmp/element-dl
  if curl -fsSL "${EL_URL}" -o /tmp/element-dl/el.tar.gz; then
    rm -rf "${ELEMENT_DIR}"
    tar xzf /tmp/element-dl/el.tar.gz -C /tmp/element-dl
    mv "/tmp/element-dl/element-${ELEMENT_TAG}" "${ELEMENT_DIR}"
    rm -rf /tmp/element-dl

    # Pin Element to THIS homeserver so users never type a server URL.
    cat > "${ELEMENT_DIR}/config.json" <<ELCONF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${SERVER_NAME}",
      "server_name": "${SERVER_NAME}"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "Element",
  "default_theme": "light",
  "room_directory": { "servers": ["${SERVER_NAME}"] },
  "show_labs_settings": true,
  "default_country_code": "US"
}
ELCONF
    chown -R www-data:www-data "${ELEMENT_DIR}"
    log "Installed Element Web ${ELEMENT_TAG}"
  else
    warn "Could not download Element Web ${ELEMENT_TAG} - skipping the chat client"
    INSTALL_ELEMENT=0
    ELEMENT_TAG=""
  fi
fi

#------------------------------------------------------------------------------
# 8. TLS certificate + nginx
#
# Synapse-Admin is served at / and the Matrix API at /_matrix on the SAME
# origin, so the browser makes same-origin requests: no CORS, and only one
# self-signed certificate for the user to accept.
#------------------------------------------------------------------------------
log "Generating a self-signed certificate for ${SERVER_NAME}"
SAN="DNS:${SERVER_NAME},IP:${SERVER_IP}"
[[ "${SERVER_NAME}" == "${SERVER_IP}" ]] && SAN="IP:${SERVER_IP}"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/matrix.key \
  -out /etc/ssl/certs/matrix.crt \
  -subj "/CN=${SERVER_NAME}" \
  -addext "subjectAltName = ${SAN}" 2>/dev/null
chmod 640 /etc/ssl/private/matrix.key

log "Configuring nginx"
# "http2 on;" only exists from nginx 1.25.1. Ubuntu 24.04 ships 1.24, where the
# directive is a config error, so pick the right form for the installed version.
NGINX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ -n "${NGINX_VER}" ]] && \
   [[ "$(printf '%s\n1.25.1\n' "${NGINX_VER}" | sort -V | head -1)" == "1.25.1" ]]; then
  HTTP2_DIRECTIVE="http2 on;"
else
  HTTP2_DIRECTIVE="# http2 not supported by nginx ${NGINX_VER:-unknown}"
fi

cat > /etc/nginx/sites-available/matrix <<NGINX
# Matrix Synapse + Synapse-Admin
# Generated by install-matrix.sh

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    # Federation port, same vhost so remote servers reach /_matrix too
    listen 8448 ssl default_server;
    listen [::]:8448 ssl default_server;
    ${HTTP2_DIRECTIVE}

    server_name ${SERVER_NAME};

    ssl_certificate     /etc/ssl/certs/matrix.crt;
    ssl_certificate_key /etc/ssl/private/matrix.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Matrix spec: clients may upload large files
    client_max_body_size 100M;

    # ---- Matrix client & federation API -> Synapse -----------------------
    location ~ ^(/_matrix|/_synapse/client|/_synapse/admin) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
        proxy_buffering off;
    }

    # ---- Delegation: tells clients/servers where this homeserver lives ---
    location = /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server": "${SERVER_NAME}:8448"}';
    }
    location = /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver": {"base_url": "https://${SERVER_NAME}"}}';
    }

    # ---- Synapse-Admin web UI at the root --------------------------------
    root ${ADMIN_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

if [[ ${INSTALL_ELEMENT} -eq 1 ]]; then
  # Element gets its own origin (different port => different origin).
  # The `map` sets the Cache-Control values upstream requires: index.html,
  # /version, /i18n and config*.json must never be cached, everything else
  # (content-hashed bundles) can be cached forever.
  cat > /etc/nginx/sites-available/element <<NGINXEL
# Element Web - generated by install-matrix.sh
map \$uri \$element_cache {
    default              "public, max-age=31536000, immutable";
    "/"                  "no-cache";
    "/index.html"        "no-cache";
    "/version"           "no-cache";
    ~^/i18n              "no-cache";
    ~^/config.*\.json\$   "no-cache";
}

server {
    listen ${ELEMENT_PORT} ssl;
    listen [::]:${ELEMENT_PORT} ssl;
    ${HTTP2_DIRECTIVE}

    server_name ${SERVER_NAME};

    ssl_certificate     /etc/ssl/certs/matrix.crt;
    ssl_certificate_key /etc/ssl/private/matrix.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root ${ELEMENT_DIR};
    index index.html;

    # Upstream's recommended hardening for Element Web
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header Cache-Control \$element_cache;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINXEL
  ln -sf /etc/nginx/sites-available/element /etc/nginx/sites-enabled/element
else
  rm -f /etc/nginx/sites-enabled/element
fi

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
nginx -t
systemctl enable --now nginx
systemctl reload nginx

#------------------------------------------------------------------------------
# 9. Self-test
#------------------------------------------------------------------------------
log "Running post-install self-tests"
FAILED=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [ OK ] ${desc}"
  else
    echo "  [FAIL] ${desc}"; FAILED=1
  fi
}
check "Synapse service is active"      systemctl is-active --quiet matrix-synapse
check "nginx service is active"        systemctl is-active --quiet nginx
check "Synapse /health"                curl -fsS --max-time 5 http://127.0.0.1:8008/health
check "Matrix API via HTTPS"           curl -fsSk --max-time 5 "https://${SERVER_IP}/_matrix/client/versions"
check "Synapse-Admin UI loads"         curl -fsSk --max-time 5 "https://${SERVER_IP}/"
check "Synapse-Admin config.json"      curl -fsSk --max-time 5 "https://${SERVER_IP}/config.json"
check ".well-known client"             curl -fsSk --max-time 5 "https://${SERVER_IP}/.well-known/matrix/client"
if [[ ${INSTALL_ELEMENT} -eq 1 ]]; then
  check "Element Web loads"            curl -fsSk --max-time 8 "https://${SERVER_IP}:${ELEMENT_PORT}/"
  check "Element config.json"          curl -fsSk --max-time 8 "https://${SERVER_IP}:${ELEMENT_PORT}/config.json"
  check "Element version file"         curl -fsSk --max-time 8 "https://${SERVER_IP}:${ELEMENT_PORT}/version"
  # The config must point at this homeserver or the client cannot log in
  if curl -fsSk --max-time 8 "https://${SERVER_IP}:${ELEMENT_PORT}/config.json" \
       | grep -q "https://${SERVER_NAME}"; then
    echo "  [ OK ] Element is pinned to this homeserver"
  else
    echo "  [FAIL] Element homeserver pinning"; FAILED=1
  fi
fi

# Prove the admin account really can log in and really is an admin
LOGIN_JSON="$(curl -fsSk --max-time 10 -X POST "https://${SERVER_IP}/_matrix/client/v3/login" \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_USER}\"},\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null || true)"
TOKEN="$(printf '%s' "${LOGIN_JSON}" | grep -oP '"access_token":\s*"\K[^"]+' || true)"
if [[ -n "${TOKEN}" ]]; then
  echo "  [ OK ] Admin login works"
  if curl -fsSk --max-time 10 -H "Authorization: Bearer ${TOKEN}" \
      "https://${SERVER_IP}/_synapse/admin/v2/users?from=0&limit=1" >/dev/null 2>&1; then
    echo "  [ OK ] Admin API access works (Synapse-Admin will work)"
  else
    echo "  [FAIL] Admin API access"; FAILED=1
  fi
else
  echo "  [FAIL] Admin login"; FAILED=1
fi

#------------------------------------------------------------------------------
# 10. Summary
#------------------------------------------------------------------------------
if [[ ${INSTALL_ELEMENT} -eq 1 ]]; then
  ELEMENT_LINE="  Element chat client: https://${SERVER_IP}:${ELEMENT_PORT}/"
  ELEMENT_NOTE="$(cat <<EONOTE

  ---- FIRST TIME USING ELEMENT ----
  The certificate is self-signed, and Element runs on a different port from
  the homeserver, so the browser treats them as two separate sites. Visit
  BOTH of these once and accept the warning on each, or Element will say it
  cannot reach the homeserver:
      1) https://${SERVER_IP}/            (homeserver + admin UI)
      2) https://${SERVER_IP}:${ELEMENT_PORT}/       (Element)
  Then log in to Element with the same ${ADMIN_USER} account below.
EONOTE
)"
else
  ELEMENT_LINE="  Element chat client: not installed"
  ELEMENT_NOTE=""
fi

SUMMARY="$(cat <<SUMMARY

======================================================================
  Matrix Synapse installation complete
======================================================================
  Synapse-Admin UI:   https://${SERVER_IP}/
${ELEMENT_LINE}
  Matrix server_name: ${SERVER_NAME}
  Homeserver URL:     https://${SERVER_NAME}/
  (self-signed certificate - your browser will warn once, accept it)
${ELEMENT_NOTE}

  ---- LOG IN TO SYNAPSE-ADMIN (AND ELEMENT) WITH ----
  Username:           ${ADMIN_USER}
  Password:           ${ADMIN_PASSWORD}
  Full Matrix ID:     @${ADMIN_USER}:${SERVER_NAME}
  Homeserver field:   https://${SERVER_NAME}   (pre-filled)

  ---- POSTGRESQL ----
  Database:           synapse
  DB user:            synapse
  DB password:        ${DB_PASSWORD}

  ---- SYNAPSE SECRETS (in ${SYN_CONF}) ----
  registration_shared_secret: ${REGISTRATION_SHARED_SECRET}
  macaroon_secret_key:        ${MACAROON_SECRET_KEY}
  form_secret:                ${FORM_SECRET}

  ---- VERSIONS ----
  Synapse:            ${SYNAPSE_VER}
  Synapse-Admin:      ${SA_TAG}
  Element Web:        ${ELEMENT_TAG:-not installed}
  Public registration: ${ENABLE_REGISTRATION}

  ---- USEFUL COMMANDS ----
  Status:        systemctl status matrix-synapse nginx
  Logs:          journalctl -u matrix-synapse -f
  Config:        ${SYN_CONF}
  Add a user:    ${SYN_DIR}/venv/bin/register_new_matrix_user \\
                   -c ${SYN_CONF} http://127.0.0.1:8008

  ---- CONNECTING OTHER CLIENTS (Element Desktop / Android / iOS) ----
  Homeserver URL to enter:  https://${SERVER_NAME}
  NOT https://${SERVER_NAME}:${ELEMENT_PORT} - that is only the web copy of
  Element. Pointing a client at it gives "Homeserver URL does not appear to
  be a valid Matrix homeserver".

  This server uses a SELF-SIGNED certificate. Desktop and mobile apps are
  stricter than browsers about that:

  * Element Desktop - quit it COMPLETELY first (it hides in the tray and is
    single-instance, so a relaunch with flags is otherwise ignored), then:
        Linux    element-desktop --ignore-certificate-errors
        macOS    /Applications/Element.app/Contents/MacOS/Element --ignore-certificate-errors
        Windows  & "\$env:LOCALAPPDATA\\element-desktop\\Element.exe" --ignore-certificate-errors
    Permanent fix - trust the certificate (it is marked CA:TRUE for this):
        openssl s_client -connect ${SERVER_IP}:443 </dev/null 2>/dev/null \\
          | openssl x509 -outform PEM > matrix.crt
        Windows  Import-Certificate -FilePath matrix.crt -CertStoreLocation Cert:\\LocalMachine\\Root
        Linux    sudo cp matrix.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
        macOS    Keychain Access > System > drag it in > Always Trust

  * Element Android - accept its own "unrecognised certificate" dialog.
    Installing the cert into Android's store does NOT help; Element Android
    ignores the user certificate store. Verify the fingerprint matches:
        openssl s_client -connect ${SERVER_IP}:443 </dev/null 2>/dev/null \\
          | openssl x509 -noout -fingerprint -sha256

  * Element iOS - install the cert as a profile, THEN enable it under
    Settings > General > About > Certificate Trust Settings.

  For phones, a real certificate is far less painful: reinstall with a real
  SERVER_NAME and run  certbot --nginx -d your.domain
  (SERVER_NAME is baked into every user ID and cannot be changed later.)

======================================================================
  SAVE THESE CREDENTIALS NOW - the passwords were randomly generated
  for this install and exist nowhere else.
  A copy was written to ${CRED_FILE} (root-only).
======================================================================
SUMMARY
)"

printf '%s\n' "${SUMMARY}"
printf '%s\n' "${SUMMARY}" > "${CRED_FILE}"
chmod 600 "${CRED_FILE}"

if [[ ${FAILED} -ne 0 ]]; then
  warn "One or more self-tests FAILED - see the [FAIL] lines above."
  exit 1
fi
