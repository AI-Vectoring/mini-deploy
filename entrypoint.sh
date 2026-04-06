#!/bin/bash
# entrypoint.sh — Container startup: install the project SSH key and start sshd.
#
# setup.sh generates a project-specific keypair on the host and docker cp's
# the public key to /tmp/authorized_keys before this runs.

set -e

mkdir -p /home/appuser/.ssh
cp /tmp/authorized_keys /home/appuser/.ssh/authorized_keys
chown -R appuser:appuser /home/appuser/.ssh
chmod 700 /home/appuser/.ssh
chmod 600 /home/appuser/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e
