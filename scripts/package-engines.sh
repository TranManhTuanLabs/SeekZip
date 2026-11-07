#!/bin/bash
# package-engines.sh — stage the bundled engine binaries for the
# SeekZip app bundle (M7).
#
#   ./scripts/package-engines.sh [--out DIR] [--force]
#
# Downloads the pinned 7-Zip 26.05 macOS console tarball, verifies its
# SHA-256, and copies 7zz + License.txt into <out>/ (default
# build/Helpers, next to the Xcode project). Then stages lsar/unar
# (The Unarchiver's command-line tools, the XAD engine): from Homebrew
# when available (`brew install unar`), else from PATH, else from an
# existing <out>/ copy. The Xcode "Bundle Engines" phase copies
# <out>/ into the built app and signs the helpers with the inherit
# entitlement; see docs/RELEASE.md.
#
# The 7zz download+verify works on any OS with curl and a SHA-256
# tool. lsar/unar staging needs a Mac with Homebrew (or a manual copy
# into <out>/); on other systems the script stops after 7zz with a
# clear message instead of failing obscurely.
set -euo pipefail

SEVENZIP_VERSION="26.05"
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz"
# Pinned checksum, verified 2026-11-07 by downloading the tarball and
# running sha256sum on it (1,868,068 bytes; contains a universal
# x86_64+arm64 7zz, License.txt, readme.txt, History.txt, MANUAL/).
SEVENZIP_SHA256="12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Helpers"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "usage: $0 [--out DIR] [--force]" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
    if have shasum; then shasum -a 256 "$1" | awk '{print $1}';
    elif have sha256sum; then sha256sum "$1" | awk '{print $1}';
    else echo "no SHA-256 tool (need shasum or sha256sum)" >&2; exit 1; fi
}

download() {
    if have curl; then curl -fsSL -o "$2" "$1";
    elif have wget; then wget -q -O "$2" "$1";
    else echo "need curl or wget to download $1" >&2; exit 1; fi
}

mkdir -p "$OUT"

# --- 7zz ---------------------------------------------------------------
if [ -x "$OUT/7zz" ] && [ -f "$OUT/License.txt" ] && [ "$FORCE" -eq 0 ]; then
    echo "7zz already staged in $OUT (use --force to re-download)"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "Downloading 7-Zip $SEVENZIP_VERSION for macOS..."
    download "$SEVENZIP_URL" "$TMP/7z2605-mac.tar.xz"
    echo "Verifying SHA-256..."
    ACTUAL="$(sha256_of "$TMP/7z2605-mac.tar.xz")"
    if [ "$ACTUAL" != "$SEVENZIP_SHA256" ]; then
        echo "SHA-256 MISMATCH for 7z2605-mac.tar.xz" >&2
        echo "  expected: $SEVENZIP_SHA256" >&2
        echo "  actual:   $ACTUAL" >&2
        echo "Refusing to bundle an unverified engine binary." >&2
        exit 1
    fi
    tar -xf "$TMP/7z2605-mac.tar.xz" -C "$TMP"
    if [ ! -x "$TMP/7zz" ] || [ ! -f "$TMP/License.txt" ]; then
        echo "tarball did not contain 7zz + License.txt" >&2; exit 1
    fi
    cp -f "$TMP/7zz" "$TMP/License.txt" "$OUT/"
    chmod +x "$OUT/7zz"
    echo "Staged 7zz $SEVENZIP_VERSION + License.txt"
fi

# --- lsar / unar --------------------------------------------------------
# Homebrew paths first (Apple Silicon / Intel), then PATH, then an
# existing staged copy.
find_tool() {
    for d in /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done
    command -v "$1" || true
}

for tool in lsar unar; do
    if [ -x "$OUT/$tool" ] && [ "$FORCE" -eq 0 ]; then
        echo "$tool already staged in $OUT"
        continue
    fi
    found="$(find_tool "$tool")"
    if [ -z "$found" ] && have brew; then
        echo "$tool not found — installing via Homebrew..."
        brew install unar
        found="$(find_tool "$tool")"
    fi
    if [ -n "$found" ]; then
        cp -f "$found" "$OUT/$tool"
        chmod +x "$OUT/$tool"
        echo "Staged $tool from $found"
    else
        echo "WARNING: $tool not found (no Homebrew, not on PATH)." >&2
        echo "  The XAD engine will report unavailable until lsar/unar" >&2
        echo "  are staged: on a Mac run 'brew install unar' and re-run" >&2
        echo "  this script, or copy the two binaries into $OUT/." >&2
    fi
done

# --- summary ------------------------------------------------------------
echo ""
echo "Staged engines in $OUT:"
ls -l "$OUT"
echo ""
echo "Next: open SeekZip.xcodeproj in Xcode and Archive (or run"
echo "  scripts/release.sh for the full notarised release)."
