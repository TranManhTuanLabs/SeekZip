#!/bin/bash
# setup-mac-bridge.sh — run ONCE on the Mac you want Muse to work on.
#
# What it does:
#   1. Adds Muse's SSH public key to your ~/.ssh/authorized_keys
#   2. Turns on Remote Login (SSH server) — asks for your admin password
#   3. Checks the SeekZip toolchain (Xcode CLT / Swift, Homebrew, 7zz)
#      and installs 7zz via Homebrew if Homebrew is present
#   4. Prints a summary block — send that block back to Muse.
#
# It does NOT disable your password login, install anything else, or
# change firewall settings. Tailscale must already be running on this
# Mac (it is: this Mac is on the owner's tailnet as mnhs-macbook-pro).
set -u

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjFrr3uCeSkgQjjpIyFZeAL+jqK8Wa9xoMZwmWAnlED hatch"

echo "=== SeekZip Mac bridge setup ==="

# 1. Authorize Muse's key
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if grep -qF "$PUBKEY" "$HOME/.ssh/authorized_keys"; then
  echo "[ok] Muse SSH key already authorized"
else
  echo "$PUBKEY" >> "$HOME/.ssh/authorized_keys"
  echo "[ok] Muse SSH key added to ~/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"

# 2. Enable Remote Login (sshd)
if sudo /usr/sbin/systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
  echo "[ok] Remote Login already on"
else
  echo "Enabling Remote Login (admin password required)…"
  sudo /usr/sbin/systemsetup -setremotelogin on || \
    echo "[!] Could not enable via command line. Enable manually: System Settings → General → Sharing → Remote Login = ON"
fi
sudo launchctl enable system/com.openssh.sshd 2>/dev/null || true

# 3. Toolchain checks
echo "--- toolchain ---"
if xcode-select -p >/dev/null 2>&1; then
  echo "[ok] Xcode Command Line Tools: $(xcode-select -p)"
else
  echo "[!] Xcode Command Line Tools missing — starting installer (click Install in the dialog)…"
  xcode-select --install || true
fi
swift --version 2>/dev/null | head -2 || echo "[!] swift not found yet"
if command -v brew >/dev/null 2>&1; then
  echo "[ok] Homebrew: $(brew --version | head -1)"
  if command -v 7zz >/dev/null 2>&1; then
    echo "[ok] 7zz: $(7zz | head -2 | tail -1)"
  else
    echo "Installing 7-Zip engine via Homebrew…"
    brew install sevenzip || echo "[!] brew install sevenzip failed — Muse can retry over SSH"
  fi
else
  echo "[!] Homebrew not installed — Muse can work without it, but installing it later helps"
fi

# 4. Summary for Muse
echo ""
echo "================ SEND THIS BLOCK TO CLAUDE ================"
echo "MAC-USERNAME: $(whoami)"
echo "MAC-HOSTNAME: $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "MAC-ARCH: $(uname -m)"
echo "MACOS: $(sw_vers -productVersion)"
echo "REMOTE-LOGIN: $(sudo /usr/sbin/systemsetup -getremotelogin 2>/dev/null || echo unknown)"
echo "TAILSCALE-IP: $(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip 2>/dev/null || tailscale ip 2>/dev/null || echo 'check Tailscale app')"
echo "SWIFT: $(swift --version 2>/dev/null | head -1 || echo missing)"
echo "==========================================================="
echo "Done. Muse can now SSH into this Mac over Tailscale."
