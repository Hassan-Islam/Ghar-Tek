#!/usr/bin/env bash
# Creates a DigitalOcean droplet for the GharTek backend using doctl.
# Requires: doctl installed and authenticated (doctl auth init).
#
# Usage:
#   ./deploy/provision_droplet.sh
# Optional env:
#   DROPLET_NAME (default: ghartek-backend)
#   REGION       (default: blr1  = Bangalore, closest to Pakistan)
#   SIZE         (default: s-1vcpu-2gb)
#   IMAGE        (default: ubuntu-24-04-x64)
#   SSH_KEY_NAME (name of an SSH key already uploaded to DigitalOcean)
set -euo pipefail

DROPLET_NAME="${DROPLET_NAME:-ghartek-backend}"
REGION="${REGION:-blr1}"
SIZE="${SIZE:-s-1vcpu-2gb}"
IMAGE="${IMAGE:-ubuntu-24-04-x64}"

if ! command -v doctl >/dev/null 2>&1; then
  echo "doctl not found. Install with: sudo snap install doctl" >&2
  exit 1
fi

# Reuse existing droplet if it exists.
EXISTING_IP="$(doctl compute droplet list --format Name,PublicIPv4 --no-header 2>/dev/null \
  | awk -v n="$DROPLET_NAME" '$1==n {print $2}')"
if [[ -n "$EXISTING_IP" ]]; then
  echo "[provision] Droplet '$DROPLET_NAME' already exists at $EXISTING_IP"
  echo "$EXISTING_IP"
  exit 0
fi

# Determine SSH key id(s) to inject.
if [[ -n "${SSH_KEY_NAME:-}" ]]; then
  SSH_KEY_ID="$(doctl compute ssh-key list --format Name,ID --no-header \
    | awk -v n="$SSH_KEY_NAME" '$1==n {print $2}')"
else
  SSH_KEY_ID="$(doctl compute ssh-key list --format ID --no-header | head -1)"
fi

if [[ -z "${SSH_KEY_ID:-}" ]]; then
  echo "No SSH key found in your DigitalOcean account." >&2
  echo "Add one first:  doctl compute ssh-key import mykey --public-key-file ~/.ssh/id_ed25519.pub" >&2
  exit 1
fi

echo "[provision] Creating droplet '$DROPLET_NAME' ($SIZE, $REGION, $IMAGE)..."
doctl compute droplet create "$DROPLET_NAME" \
  --region "$REGION" \
  --size "$SIZE" \
  --image "$IMAGE" \
  --ssh-keys "$SSH_KEY_ID" \
  --wait \
  --format Name,PublicIPv4 --no-header

IP="$(doctl compute droplet list --format Name,PublicIPv4 --no-header \
  | awk -v n="$DROPLET_NAME" '$1==n {print $2}')"
echo "[provision] Droplet ready at IP: $IP"
echo "$IP"
