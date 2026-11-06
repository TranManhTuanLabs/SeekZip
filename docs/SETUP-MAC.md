# Connecting Muse to your Mac (one-time setup)

Goal: Muse works directly on the Mac — running `swift build`, tests and
installers over SSH — so the owner only assigns work in chat. This mirrors
the proven Termux phone bridge: same Tailscale network, same key-only SSH.

## Why SSH and not an MCP server?

Every remote-Mac MCP setup (cua-driver, mac-reader, …) is built **on top
of** SSH: they all require Remote Login enabled and the agent's public
key in `~/.ssh/authorized_keys` on the Mac. SSH alone already gives full
build/test/file access, so it is step 1. A GUI-control MCP (clicking and
screenshots, e.g. for Xcode GUI flows) can be layered on later without
changing this setup.

## Current state

- The Mac (`mnhs-macbook-pro`) is **already on the tailnet** and visible
  from Muse's VM.
- SSH port 22 does not answer yet → Remote Login is off. Only the steps
  below are missing.

## Owner steps (once, ~2 minutes, on the Mac)

1. Get `scripts/setup-mac-bridge.sh` onto the Mac (Muse sends the file).
2. In Terminal: `bash ~/Downloads/setup-mac-bridge.sh`
   It asks for the admin password once (to enable Remote Login), adds
   Muse's public key, checks Swift/Homebrew/7zz.
3. Send the printed summary block back to Muse (it contains the Mac
   username Muse needs for SSH).

Alternative to step 2's Remote Login part, if the command is blocked:
System Settings → General → Sharing → **Remote Login = ON**, then re-run
the script so the key step still happens.

## After that (Muse, no owner action)

```sh
MAC_USER=<from summary> scripts/ssh-mac.sh 'whoami && swift --version'
```

Then: clone/copy this repo to the Mac, `swift build && swift test`, run
the fixture matrix, and report results in chat.

## Reboot behaviour

Remote Login and Tailscale both come back automatically after a reboot.
If the Mac sleeps, wake it — a sleeping Mac cannot answer SSH.

## Security notes

- Key-only convenience: the script adds one public key; the matching
  private key never leaves Muse's VM. Password login stays as it was.
- Access rides the private tailnet only; nothing is exposed to the
  public internet. Revoke anytime: remove the `hatch` line from
  `~/.ssh/authorized_keys` and/or turn Remote Login off.
