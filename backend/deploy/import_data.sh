#!/usr/bin/env bash
# Imports Firebase RTDB JSON exports into the droplet's Postgres.
# Put your Console exports at backend/data/main.json (and optionally
# backend/data/ratings.json) BEFORE running deploy.sh, then run this.
#
# Usage:
#   DROPLET_IP=203.0.113.9 ./deploy/import_data.sh
set -euo pipefail

DROPLET_IP="${DROPLET_IP:?Set DROPLET_IP=<your droplet ipv4>}"
SSH_USER="${SSH_USER:-root}"
REMOTE_DIR="/opt/ghartek-backend"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY:-}" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

echo "[import] Running import inside the backend container on the droplet..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$DROPLET_IP" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/ghartek-backend
if [[ ! -f data/main.json ]]; then
  echo "No data/main.json on droplet. Sync it first (re-run deploy.sh after placing the file locally)."
  exit 1
fi
docker compose -f docker-compose.prod.yml exec -T backend \
  node scripts/import_firebase_json.js --truncate
echo "[import] Done."
REMOTE
