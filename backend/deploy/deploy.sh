#!/usr/bin/env bash
# Deploys the GharTek backend to a DigitalOcean droplet.
#
# Usage:
#   DROPLET_IP=203.0.113.9 ./deploy/deploy.sh
# Optional:
#   SSH_USER (default: root)
#   SSH_KEY  (path to private key; default: ssh-agent / ~/.ssh/id_*)
#   POSTGRES_PASSWORD (generated if not set on first deploy)
#
# Run this from the backend/ directory on your local machine.
set -euo pipefail

DROPLET_IP="${DROPLET_IP:?Set DROPLET_IP=<your droplet ipv4>}"
SSH_USER="${SSH_USER:-root}"
REMOTE_DIR="/opt/ghartek-backend"
SITE_ADDRESS="${SITE_ADDRESS:-${DROPLET_IP//./-}.sslip.io}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY:-}" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[deploy] Target:  $SSH_USER@$DROPLET_IP"
echo "[deploy] Host:    $SITE_ADDRESS  (HTTPS via Let's Encrypt)"
echo "[deploy] Remote:  $REMOTE_DIR"

echo "[deploy] 1/5 Installing Docker on droplet (idempotent)..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$DROPLET_IP" 'bash -s' < "$SCRIPT_DIR/remote_bootstrap.sh"

echo "[deploy] 2/5 Syncing backend source..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$DROPLET_IP" "mkdir -p $REMOTE_DIR"
RSYNC_SSH="ssh ${SSH_OPTS[*]}"
rsync -az --delete \
  --exclude node_modules \
  --exclude '.env' \
  --exclude '*.log' \
  -e "$RSYNC_SSH" \
  "$BACKEND_DIR/src" \
  "$BACKEND_DIR/scripts" \
  "$BACKEND_DIR/sql" \
  "$BACKEND_DIR/data" \
  "$BACKEND_DIR/package.json" \
  "$BACKEND_DIR/package-lock.json" \
  "$BACKEND_DIR/Dockerfile" \
  "$BACKEND_DIR/.dockerignore" \
  "$BACKEND_DIR/docker-compose.prod.yml" \
  "$BACKEND_DIR/Caddyfile" \
  "$SSH_USER@$DROPLET_IP:$REMOTE_DIR/"

# Sync optional secrets dir if present locally.
if [[ -d "$BACKEND_DIR/secrets" ]]; then
  rsync -az -e "$RSYNC_SSH" "$BACKEND_DIR/secrets" "$SSH_USER@$DROPLET_IP:$REMOTE_DIR/"
fi

echo "[deploy] 3/5 Writing .env on droplet (preserving existing password)..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$DROPLET_IP" \
  "SITE_ADDRESS='$SITE_ADDRESS' NEW_PW='${POSTGRES_PASSWORD:-}' FB_PID='${FIREBASE_PROJECT_ID:-pak-delivers}' \
   SPACES_KEY='${SPACES_KEY:-}' SPACES_SECRET='${SPACES_SECRET:-}' \
   SPACES_REGION='${SPACES_REGION:-sfo3}' SPACES_BUCKET='${SPACES_BUCKET:-ghartek-media}' \
   SPACES_ENDPOINT='${SPACES_ENDPOINT:-}' bash -s" <<'REMOTE'
set -euo pipefail
cd /opt/ghartek-backend
if [[ -f .env ]] && grep -q '^POSTGRES_PASSWORD=' .env; then
  PW="$(grep '^POSTGRES_PASSWORD=' .env | head -1 | cut -d= -f2-)"
else
  PW="${NEW_PW:-$(openssl rand -hex 24)}"
fi
CRED_LINE="GOOGLE_APPLICATION_CREDENTIALS="
if [[ -f secrets/serviceAccountKey.json ]]; then
  CRED_LINE="GOOGLE_APPLICATION_CREDENTIALS=./secrets/serviceAccountKey.json"
fi
# Preserve previously-saved Spaces creds if this deploy didn't pass new ones.
prev() { [[ -f .env ]] && grep "^$1=" .env | head -1 | cut -d= -f2- || true; }
SP_KEY="${SPACES_KEY:-$(prev SPACES_KEY)}"
SP_SECRET="${SPACES_SECRET:-$(prev SPACES_SECRET)}"
SP_REGION="${SPACES_REGION:-sfo3}"
SP_BUCKET="${SPACES_BUCKET:-ghartek-media}"
SP_ENDPOINT="${SPACES_ENDPOINT:-}"
cat > .env <<EOF
SITE_ADDRESS=${SITE_ADDRESS}
POSTGRES_USER=ghartek
POSTGRES_PASSWORD=${PW}
POSTGRES_DB=ghartek
FIREBASE_PROJECT_ID=${FB_PID}
${CRED_LINE}
AUTH_DISABLED=0
SPACES_REGION=${SP_REGION}
SPACES_BUCKET=${SP_BUCKET}
SPACES_ENDPOINT=${SP_ENDPOINT}
SPACES_KEY=${SP_KEY}
SPACES_SECRET=${SP_SECRET}
EOF
echo "[deploy] .env ready (SITE_ADDRESS=${SITE_ADDRESS}, spaces_key_set=$([[ -n "$SP_KEY" ]] && echo yes || echo no))"
REMOTE

echo "[deploy] 4/5 Building & starting containers..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$DROPLET_IP" \
  "cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml up -d --build"

echo "[deploy] 5/5 Waiting for HTTPS health check..."
sleep 8
for i in $(seq 1 20); do
  if curl -fsS "https://$SITE_ADDRESS/health" >/dev/null 2>&1; then
    echo "[deploy] ✅ Live: https://$SITE_ADDRESS/health"
    curl -s "https://$SITE_ADDRESS/health"; echo
    echo
    echo "Set the app API base to: https://$SITE_ADDRESS"
    exit 0
  fi
  echo "  ...waiting for TLS cert / boot ($i/20)"
  sleep 6
done

echo "[deploy] ⚠️  HTTPS not ready yet. Check logs on the droplet:"
echo "   ssh $SSH_USER@$DROPLET_IP 'cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml logs --tail=80 caddy backend'"
exit 1
