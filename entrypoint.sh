#!/bin/bash
# entrypoint.sh — Container startup: configure SSH and start sshd.

set -e

mkdir -p /home/appuser/.ssh

# Install access key
cp /tmp/authorized_keys /home/appuser/.ssh/authorized_keys

# Install GitHub key and configure SSH for github.com
if [ -f /tmp/github_key ]; then
    cp /tmp/github_key /home/appuser/.ssh/github_key
    cat > /home/appuser/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile /home/appuser/.ssh/github_key
  StrictHostKeyChecking no
EOF
fi

chown -R appuser:appuser /home/appuser/.ssh
chmod 700 /home/appuser/.ssh
chmod 600 /home/appuser/.ssh/authorized_keys
[ -f /home/appuser/.ssh/github_key ] && chmod 600 /home/appuser/.ssh/github_key
[ -f /home/appuser/.ssh/config ] && chmod 600 /home/appuser/.ssh/config

exec /usr/sbin/sshd -D -e
