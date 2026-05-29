#!/usr/bin/env bash
###############################################################################
# dograh cloud bootstrap — fresh Ubuntu VM, NO Docker.
#
# Brings up the whole self-hosted dograh stack on a brand-new Ubuntu 22.04/24.04
# cloud VM (EC2 / GCP / Hetzner / DigitalOcean / etc.) and makes a browser voice
# call work end-to-end. Idempotent: safe to re-run.
#
# Why this exists: dograh's setup_remote.sh is Docker-based. This is the native
# (no-Docker) path, automating exactly the steps that were proven by hand —
# Postgres+pgvector, Redis, MinIO, Python deps, migrations, api/.env with
# generated secrets, plus Caddy (auto-HTTPS) and the firewall, so WebRTC works
# with only ports 80/443 open (media is relayed via Cloudflare TURN over TCP).
#
# On a normal VM with a public IP there is NO Lightning-style UDP/IPv6 wall:
# Cloudflare TURN-over-TCP (the fix already in api/routes/turn_credentials.py)
# carries the media through 443, so you don't even open UDP.
#
# USAGE (run as a sudo-capable NON-root user, from the repo root):
#
#   DOMAIN=agent.example.com \
#   CLOUDFLARE_TURN_KEY_ID=xxxx \
#   CLOUDFLARE_TURN_API_TOKEN=yyyy \
#   bash scripts/cloud_bootstrap.sh
#
# A real DOMAIN pointing at this VM's public IP is REQUIRED — browsers only give
# microphone access over valid HTTPS, and Caddy needs the domain for a cert.
# Cloudflare TURN keys are strongly recommended (Realtime -> TURN -> create key).
#
# Secrets you don't supply are generated and written into api/.env (gitignored).
###############################################################################
set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Preconditions + config
# ----------------------------------------------------------------------------
if [[ "$EUID" -eq 0 ]]; then
    echo "Run as a normal sudo-capable user, not root (the app shouldn't run as root)." >&2
    exit 1
fi
command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
RUN_USER="$(id -un)"

DOMAIN="${DOMAIN:-}"
if [[ -z "$DOMAIN" ]]; then
    echo "ERROR: set DOMAIN=your.fqdn (must already point at this VM's public IP)." >&2
    echo "       Browsers require HTTPS for mic access; Caddy needs it for a cert." >&2
    exit 1
fi

# Datastore + app secrets (override via env; otherwise sensible defaults/generated).
DB_NAME="${DB_NAME:-dograh}"
DB_USER="${DB_USER:-dograh}"
DB_PASS="${DB_PASS:-dograh}"
REDIS_PASS="${REDIS_PASS:-$(openssl rand -hex 16)}"
MINIO_USER="${MINIO_USER:-minioadmin}"
MINIO_PASS="${MINIO_PASS:-$(openssl rand -hex 16)}"
MINIO_BUCKET="${MINIO_BUCKET:-voice-audio}"
OSS_JWT_SECRET="${OSS_JWT_SECRET:-$(openssl rand -hex 32)}"
CLOUDFLARE_TURN_KEY_ID="${CLOUDFLARE_TURN_KEY_ID:-}"
CLOUDFLARE_TURN_API_TOKEN="${CLOUDFLARE_TURN_API_TOKEN:-}"
PG_VER="${PG_VER:-16}"

echo "==> dograh cloud bootstrap"
echo "    repo:   $REPO_ROOT"
echo "    user:   $RUN_USER"
echo "    domain: $DOMAIN"
echo "    turn:   $([[ -n "$CLOUDFLARE_TURN_KEY_ID" ]] && echo "Cloudflare key set" || echo "NONE (WebRTC may fail behind NAT — set CLOUDFLARE_TURN_*)")"
echo

# ----------------------------------------------------------------------------
# 1. System packages
# ----------------------------------------------------------------------------
echo "==> [1/9] apt packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
    git curl ca-certificates build-essential pkg-config \
    python3 python3-venv python3-dev \
    postgresql "postgresql-${PG_VER}" "postgresql-${PG_VER}-pgvector" postgresql-contrib \
    redis-server \
    ffmpeg libsndfile1 \
    ufw

# Node 20 (for the Next.js UI) via NodeSource if node is missing/old.
if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')" -lt 18 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
sudo corepack enable 2>/dev/null || true

# Caddy (auto-HTTPS reverse proxy).
if ! command -v caddy >/dev/null; then
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y caddy
fi

# ----------------------------------------------------------------------------
# 2. Postgres: role + db + pgvector  (idempotent)
# ----------------------------------------------------------------------------
echo "==> [2/9] Postgres"
sudo systemctl enable --now postgresql
sudo -u postgres psql <<SQL
DO \$\$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
    ALTER ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  END IF;
END \$\$;
SQL
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
    || sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS vector;"

# ----------------------------------------------------------------------------
# 3. Redis: require a password (idempotent)
# ----------------------------------------------------------------------------
echo "==> [3/9] Redis"
sudo systemctl enable --now redis-server
sudo sed -i "s/^# *requirepass .*/requirepass ${REDIS_PASS}/; s/^requirepass .*/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
grep -q "^requirepass ${REDIS_PASS}" /etc/redis/redis.conf || echo "requirepass ${REDIS_PASS}" | sudo tee -a /etc/redis/redis.conf >/dev/null
sudo systemctl restart redis-server

# ----------------------------------------------------------------------------
# 4. MinIO: binary + systemd + bucket  (idempotent)
# ----------------------------------------------------------------------------
echo "==> [4/9] MinIO"
if ! command -v minio >/dev/null; then
    sudo curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
    sudo chmod +x /usr/local/bin/minio
fi
if ! command -v mc >/dev/null; then
    sudo curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
    sudo chmod +x /usr/local/bin/mc
fi
sudo mkdir -p /var/lib/minio
sudo tee /etc/systemd/system/minio.service >/dev/null <<UNIT
[Unit]
Description=MinIO
After=network-online.target
Wants=network-online.target
[Service]
Environment=MINIO_ROOT_USER=${MINIO_USER}
Environment=MINIO_ROOT_PASSWORD=${MINIO_PASS}
ExecStart=/usr/local/bin/minio server /var/lib/minio --address 127.0.0.1:9000 --console-address 127.0.0.1:9001
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now minio
for i in $(seq 1 20); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/minio/health/live)" == "200" ]] && break
    sleep 1
done
mc alias set dlocal http://127.0.0.1:9000 "${MINIO_USER}" "${MINIO_PASS}" >/dev/null 2>&1 || true
mc mb -p "dlocal/${MINIO_BUCKET}" >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 5. Python venv + dograh deps + migrations
# ----------------------------------------------------------------------------
echo "==> [5/9] Python deps (venv at $REPO_ROOT/venv — auto-activated by start_services*.sh)"
git submodule update --init --recursive
if [[ ! -d venv ]]; then python3 -m venv venv; fi
# shellcheck disable=SC1091
source venv/bin/activate
python -m pip install --upgrade pip wheel
# Reuse dograh's own dependency installer (api + pipecat submodule).
if [[ -f scripts/setup_requirements.sh ]]; then
    bash scripts/setup_requirements.sh
else
    pip install -e ./api || pip install -r api/requirements.txt
    [[ -d pipecat ]] && pip install -e ./pipecat || true
fi

# ----------------------------------------------------------------------------
# 6. api/.env  (the values proven to work; secrets generated above)
# ----------------------------------------------------------------------------
echo "==> [6/9] api/.env"
cat > api/.env <<ENV
ENVIRONMENT=local
DATABASE_URL=postgresql+asyncpg://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
REDIS_URL=redis://:${REDIS_PASS}@localhost:6379
MINIO_ENDPOINT=localhost:9000
MINIO_PUBLIC_ENDPOINT=https://${DOMAIN}
MINIO_ACCESS_KEY=${MINIO_USER}
MINIO_SECRET_KEY=${MINIO_PASS}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_SECURE=false
OSS_JWT_SECRET=${OSS_JWT_SECRET}
BACKEND_API_ENDPOINT=https://${DOMAIN}
UI_APP_URL=https://${DOMAIN}
CORS_ALLOWED_ORIGINS=https://${DOMAIN},http://localhost:3000
TURN_HOST=localhost
TURN_SECRET=ignored-but-not-empty
CLOUDFLARE_TURN_KEY_ID=${CLOUDFLARE_TURN_KEY_ID}
CLOUDFLARE_TURN_API_TOKEN=${CLOUDFLARE_TURN_API_TOKEN}
# Add provider keys when wiring STT/LLM/TTS:
# DEEPGRAM_API_KEY=
# OPENAI_API_KEY=
# GROQ_API_KEY=
ENV

echo "    running migrations..."
set -a; . api/.env; set +a
alembic -c api/alembic.ini upgrade head

# ----------------------------------------------------------------------------
# 7. ui/.env + build  (same-origin: UI proxies /api -> backend server-side)
# ----------------------------------------------------------------------------
echo "==> [7/9] UI build"
cat > ui/.env <<UIENV
BACKEND_URL=http://localhost:8000
NEXT_PUBLIC_BACKEND_URL=https://${DOMAIN}
NEXT_PUBLIC_NODE_ENV=production
UIENV
( cd ui && (corepack pnpm install --frozen-lockfile 2>/dev/null || npm install) && (corepack pnpm build 2>/dev/null || npm run build) )

# ----------------------------------------------------------------------------
# 8. systemd units (backend uvicorn + arq worker + UI) — reboot-safe
# ----------------------------------------------------------------------------
echo "==> [8/9] systemd services"
PYBIN="$REPO_ROOT/venv/bin/python"
NPMBIN="$(command -v npm)"

sudo tee /etc/systemd/system/dograh-backend.service >/dev/null <<UNIT
[Unit]
Description=dograh API (uvicorn) + WebRTC signaling
After=network-online.target postgresql.service redis-server.service minio.service
Wants=network-online.target
[Service]
User=${RUN_USER}
WorkingDirectory=${REPO_ROOT}
Environment=PYTHONPATH=${REPO_ROOT}
EnvironmentFile=${REPO_ROOT}/api/.env
ExecStart=${PYBIN} -m uvicorn api.app:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/dograh-arq.service >/dev/null <<UNIT
[Unit]
Description=dograh background worker (arq)
After=network-online.target redis-server.service
Wants=network-online.target
[Service]
User=${RUN_USER}
WorkingDirectory=${REPO_ROOT}
Environment=PYTHONPATH=${REPO_ROOT}
EnvironmentFile=${REPO_ROOT}/api/.env
ExecStart=${PYBIN} -m arq api.tasks.arq.WorkerSettings
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/dograh-ui.service >/dev/null <<UNIT
[Unit]
Description=dograh UI (Next.js)
After=network-online.target
Wants=network-online.target
[Service]
User=${RUN_USER}
WorkingDirectory=${REPO_ROOT}/ui
Environment=PORT=3000
ExecStart=${NPMBIN} run start
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now dograh-backend dograh-arq dograh-ui

# Caddy: terminate TLS for DOMAIN, reverse-proxy to the UI (which proxies /api).
sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
${DOMAIN} {
    reverse_proxy 127.0.0.1:3000
}
CADDY
sudo systemctl enable --now caddy
sudo systemctl reload caddy || sudo systemctl restart caddy

# ----------------------------------------------------------------------------
# 9. Firewall — only 80/443 needed; WebRTC media rides Cloudflare TURN over TCP
# ----------------------------------------------------------------------------
echo "==> [9/9] firewall"
sudo ufw allow OpenSSH >/dev/null 2>&1 || sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# ----------------------------------------------------------------------------
# Summary + verification
# ----------------------------------------------------------------------------
echo
echo "================================================================"
echo " dograh is up.  Open:  https://${DOMAIN}"
echo "================================================================"
echo " Verify:"
echo "   systemctl status dograh-backend dograh-ui caddy --no-pager | grep Active"
echo "   curl -s localhost:8000/api/v1/health    # backend health"
echo "   redis-cli -a '${REDIS_PASS}' ping        # PONG"
echo
echo " First use: browse to https://${DOMAIN}/auth/signup and create an account."
echo " TTS: in a workflow add Local Models (Speaches) -> Base URL of your TTS"
echo "      worker (e.g. https://<host>:8006/v1 for maya1, :8007 for orpheus_gguf)."
echo
if [[ -z "$CLOUDFLARE_TURN_KEY_ID" ]]; then
  echo " WARNING: no Cloudflare TURN key set. Direct WebRTC may still work on a"
  echo " public-IP VM, but for reliable connectivity behind NATs set"
  echo " CLOUDFLARE_TURN_KEY_ID / CLOUDFLARE_TURN_API_TOKEN in api/.env and"
  echo " 'sudo systemctl restart dograh-backend'."
fi
echo " Secrets written to api/.env (gitignored). Generated Redis/MinIO/JWT"
echo " secrets are unique to this box."
