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
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "${PROJECT}-dev"
fi

# ── Find and validate GitHub key ─────────────────────────────────────────────
test_github_key() {
    ssh -i "$1" -o StrictHostKeyChecking=no -o BatchMode=yes -T git@github.com 2>&1 | grep -q "successfully authenticated"
}

use_project_key() {
    echo ""
    echo "Add a new SSH key to your GitHub account:"
    echo ""
    echo "  1. Copy the line here below:"
    cat "${SSH_KEY}.pub"
    echo "  2. Go to https://github.com/settings/ssh/new"
    echo "  3. Paste it in the 'Key' field."
    echo "  4. Add a name, click 'Add SSH key'"
    echo "You are done, run setup.sh again"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────"
    echo ""
    exit 0
}

TRICYCLER_CONFIG="${HOME}/.config/tricycler/config"
GITHUB_KEY=""

# ── Check cached GitHub key ───────────────────────────────────────────────────
if [ -f "${TRICYCLER_CONFIG}" ]; then
    CACHED_KEY=$(grep "^GITHUB_KEY=" "${TRICYCLER_CONFIG}" | cut -d= -f2-)
    if [ -f "${CACHED_KEY}" ]; then
        echo "Testing cached GitHub key: ${CACHED_KEY}"
        if test_github_key "${CACHED_KEY}"; then
            GITHUB_KEY="${CACHED_KEY}"
            echo "Cached key valid."
        else
            echo "Cached key no longer valid. Running key detection..."
        fi
    fi
fi

if [ -z "${GITHUB_KEY}" ]; then

FOUND_KEYS=()
for f in "${HOME}/.ssh"/*; do
    [[ "$f" == *.pub ]] && continue
    [[ "$f" == */known_hosts* ]] && continue
    [[ "$f" == */config* ]] && continue
    [[ "$f" == */authorized_keys* ]] && continue
    [[ "$f" == */${PROJECT} ]] && continue
    [[ "$f" == *.pem ]] && continue
    if [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q "PRIVATE KEY"; then
        FOUND_KEYS+=("$f")
    fi
done

ATTEMPTS=0
MAX_ATTEMPTS=3

while [ ${ATTEMPTS} -lt ${MAX_ATTEMPTS} ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    CANDIDATE=""

    if [ ${ATTEMPTS} -eq 1 ] && [ ${#FOUND_KEYS[@]} -eq 1 ]; then
        CANDIDATE="${FOUND_KEYS[0]}"

    elif [ ${#FOUND_KEYS[@]} -gt 1 ]; then
        echo ""
        echo "Select your GitHub SSH key:"
        for i in "${!FOUND_KEYS[@]}"; do
            echo "  $((i+1))) ${FOUND_KEYS[$i]}"
        done
        NEXT=$((${#FOUND_KEYS[@]}+1))
        echo "  ${NEXT}) Enter path manually"
        echo "  $((NEXT+1))) Create a new key for GitHub"
        read -rp "Choice: " CHOICE
        if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]]; then
            echo "Invalid choice."
            continue
        elif [ "${CHOICE}" -eq "$((NEXT+1))" ]; then
            use_project_key
        elif [ "${CHOICE}" -eq "${NEXT}" ]; then
            read -rp "Path: " CANDIDATE
        else
            CANDIDATE="${FOUND_KEYS[$((CHOICE-1))]}"
        fi

    else
        echo ""
        echo "No GitHub SSH key found. What would you like to do?"
        echo "  1) Enter path manually"
        echo "  2) Create a new key for GitHub"
        read -rp "Choice: " CHOICE
        if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]]; then
            echo "Invalid choice."
            continue
        elif [ "${CHOICE}" -eq "2" ]; then
            use_project_key
        else
            read -rp "Path: " CANDIDATE
        fi
    fi

    if [ ! -f "${CANDIDATE}" ]; then
        echo "File not found: ${CANDIDATE}"
        continue
    fi

    echo "Testing key: ${CANDIDATE}"
    if test_github_key "${CANDIDATE}"; then
        GITHUB_KEY="${CANDIDATE}"
        break
    else
        echo "Key did not authenticate with GitHub."
    fi
done

if [ -z "${GITHUB_KEY}" ]; then
    use_project_key
fi

# ── Cache the validated GitHub key ───────────────────────────────────────────
mkdir -p "$(dirname "${TRICYCLER_CONFIG}")"
if grep -q "^GITHUB_KEY=" "${TRICYCLER_CONFIG}" 2>/dev/null; then
    sed -i "s|^GITHUB_KEY=.*|GITHUB_KEY=${GITHUB_KEY}|" "${TRICYCLER_CONFIG}"
else
    echo "GITHUB_KEY=${GITHUB_KEY}" >> "${TRICYCLER_CONFIG}"
fi

fi # end key detection block

# ── Build image ──────────────────────────────────────────────────────────────
echo "Building image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

# ── Start container ──────────────────────────────────────────────────────────
echo "Starting container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${SSH_PORT}:22" \
    -v "${GITHUB_KEY}:/tmp/github_key:ro" \
    -v "${SSH_KEY}.pub:/tmp/authorized_keys:ro" \
    "${IMAGE_NAME}" > /dev/null
echo "Container ${CONTAINER_NAME} started."

# ── Write SSH config entry ───────────────────────────────────────────────────
SSH_CONFIG="${HOME}/.ssh/config"
if ! grep -q "Host ${PROJECT}" "${SSH_CONFIG}" 2>/dev/null; then
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
