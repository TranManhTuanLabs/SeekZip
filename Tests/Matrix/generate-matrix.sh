#!/bin/sh
# Generate SeekZip test fixtures. Requires 7zz (or 7z) on PATH.
# Usage: ./generate-matrix.sh [output-dir]   (default: ./fixtures)
set -eu
OUT="${1:-fixtures}"
SEVEN="${SEVEN:-7zz}"
command -v "$SEVEN" >/dev/null 2>&1 || { echo "need 7zz on PATH"; exit 1; }
mkdir -p "$OUT/src/sub"
cd "$OUT"

printf 'hello seekzip\n' > src/hello.txt
printf 'xin chào, đây là file tiếng Việt\n' > "src/tiếng việt.txt"
printf 'nested\n' > src/sub/nested.txt
head -c 1048576 /dev/urandom > src/random-1mb.bin

# Basic formats
"$SEVEN" a -tzip plain.zip src >/dev/null
"$SEVEN" a -t7z solid.7z src >/dev/null
"$SEVEN" a -ttar plain.tar src >/dev/null
"$SEVEN" a -tgzip plain.tar.gz plain.tar >/dev/null || true

# Encrypted
"$SEVEN" a -tzip -pseekzip aes.zip src >/dev/null
"$SEVEN" a -t7z -pseekzip -mhe=on encrypted-headers.7z src >/dev/null

# Split volumes
"$SEVEN" a -t7z -v1m split.7z src >/dev/null

# Nested archive
"$SEVEN" a -tzip inner.zip src/hello.txt >/dev/null
"$SEVEN" a -tzip nested.zip inner.zip >/dev/null

# Many entries
mkdir -p many && i=1; while [ $i -le 2000 ]; do printf '%s' "$i" > "many/f$i.txt"; i=$((i+1)); done
"$SEVEN" a -tzip many-entries.zip many >/dev/null

# Corrupted copies
cp plain.zip truncated.zip && truncate -s 40 truncated.zip
cp plain.zip bitflip.zip && printf 'XXXX' | dd of=bitflip.zip bs=1 seek=60 conv=notrunc 2>/dev/null

# Zip-slip (entry escaping the destination) — built with python3 zipfile
python3 - <<'PY'
import zipfile
with zipfile.ZipFile("zip-slip.zip", "w") as z:
    z.writestr("../evil.txt", "escaped")
    z.writestr("/abs.txt", "absolute")
    z.writestr("good/ok.txt", "fine")
PY

echo "fixtures generated in $OUT"
