#!/usr/bin/env bash
# Run ONCE after `podman compose up garage` to initialize the cluster,
# create the artifacts bucket, and provision a claude-worker access key.
#
# Usage: bash garage/init.sh
#
# After it runs, copy the printed key ID and secret into your .env:
#   GARAGE_ACCESS_KEY_ID=...
#   GARAGE_SECRET_ACCESS_KEY=...

set -euo pipefail

CONTAINER=garage

echo "==> Waiting for Garage to be ready..."
until podman exec "$CONTAINER" /garage status &>/dev/null; do
  sleep 2
done

echo "==> Getting node ID..."
NODE_ID=$(podman exec "$CONTAINER" /garage status 2>/dev/null \
  | grep -E 'NO ROLE|NO_ROLE|[0-9a-f]{15,}' \
  | awk '{print $1}' | head -1)

if [ -z "$NODE_ID" ]; then
  echo "ERROR: Could not get node ID. Is the container running?"
  exit 1
fi

echo "    Node ID: $NODE_ID"

echo "==> Assigning layout (100G capacity, zone garage1)..."
podman exec "$CONTAINER" /garage layout assign -z garage1 -c 100G "$NODE_ID"

echo "==> Applying layout..."
podman exec "$CONTAINER" /garage layout apply --version 1

echo "==> Creating 'artifacts' bucket..."
podman exec "$CONTAINER" /garage bucket create artifacts || echo "    (bucket may already exist)"

echo "==> Creating 'claude-worker' access key..."
podman exec "$CONTAINER" /garage key create claude-worker

echo "==> Granting read/write access on 'artifacts'..."
KEY_ID=$(podman exec "$CONTAINER" /garage key list 2>/dev/null \
  | grep claude-worker | awk '{print $1}')
podman exec "$CONTAINER" /garage bucket allow --read --write --owner artifacts --key "$KEY_ID"

echo ""
echo "==> Done. Paste these into your .env:"
podman exec "$CONTAINER" /garage key info "$KEY_ID" \
  | grep -E 'Key ID|Secret key' \
  | sed 's/Key ID:         /GARAGE_ACCESS_KEY_ID=/' \
  | sed 's/Secret key:     /GARAGE_SECRET_ACCESS_KEY=/'
