#!/bin/bash
# ssh-mac.sh — one-command SSH from Muse's VM into the user's Mac over
# Tailscale, through the runtime proxy (port 3130).
# Usage: ./ssh-mac.sh [ssh args / remote command]
# Set MAC_USER to the Mac username printed by setup-mac-bridge.sh.
set -eu
MAC_USER="${MAC_USER:?set MAC_USER to the username from the setup summary}"
MAC_IP="${MAC_IP:-100.100.160.113}"   # mnhs-macbook-pro on the tailnet
HERE="$(cd "$(dirname "$0")" && pwd)"

exec ssh \
  -o ProxyCommand="python3 $HERE/mac-proxy-connect.py %h %p" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
  -i "$HOME/.ssh/id_ed25519" \
  "$MAC_USER@$MAC_IP" "$@"
