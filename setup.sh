#!/bin/bash
# setup.sh — Build image, start container, configure SSH access.
#
# Usage: bash setup.sh
# Run from inside the mini-deploy repo directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="mini-deploy"
IMAGE_NAME="${PROJECT}-dev"
CONTAINER_NAME="${PROJECT}-dev"
SSH_KEY="${HOME}/.ssh/${PROJECT}"
SSH_PORT=2222

echo ""
echo "=== ${PROJECT} setup ==="
echo ""

# ── Generate project SSH keypair ─────────────────────────────────────────────
if [ ! -f "${SSH_KEY}" ]; then
    echo "Generating SSH keypair at ${SSH_KEY}..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "${PROJECT}-dev"
else
    echo "SSH key already exists at ${SSH_KEY}, reusing."
fi

# ── Build image ──────────────────────────────────────────────────────────────
echo "Building image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

# ── Start container ──────────────────────────────────────────────────────────
echo "Starting container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${SSH_PORT}:22" \
    -v "${HOME}/.ssh:/home/appuser/.ssh-host:ro" \
    -v "${SSH_KEY}.pub:/tmp/authorized_keys:ro" \
    "${IMAGE_NAME}"

# ── Write SSH config entry ───────────────────────────────────────────────────
SSH_CONFIG="${HOME}/.ssh/config"
if ! grep -q "Host ${PROJECT}" "${SSH_CONFIG}" 2>/dev/null; then
    echo "Writing SSH config entry..."
    cat >> "${SSH_CONFIG}" <<EOF

Host ${PROJECT}
  HostName localhost
  Port ${SSH_PORT}
  User appuser
  IdentityFile ${SSH_KEY}
  StrictHostKeyChecking no
EOF
    chmod 600 "${SSH_CONFIG}"
fi

echo ""
echo "=== Done ==="
echo "Connect with: ssh ${PROJECT}"
echo ""
