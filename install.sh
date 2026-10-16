#!/bin/sh
# Installs the latest Crumb and opens it:
#
#   curl -fsSL https://raw.githubusercontent.com/bhaskar0210s/crumb/main/install.sh | sh
#
# The download is checked against the signature of Crumb's release key before anything is installed. Files that
# curl downloads carry no quarantine flag, so macOS opens Crumb without the warning it shows for apps from a browser
# that aren't notarized by Apple.
set -eu

repo="bhaskar0210s/crumb"

if [ "$(uname -m)" != "arm64" ] || [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]; then
    echo "Crumb needs a Mac with Apple silicon and macOS 27 or later." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

echo "Downloading Crumb…"
curl -fsSL -o Crumb.zip "https://github.com/$repo/releases/latest/download/Crumb.zip"
curl -fsSL -o Crumb.zip.sig "https://github.com/$repo/releases/latest/download/Crumb.zip.sig"

cat > key.pem <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4B8jaUoU1r8LIYJLZz6eS3u7EYfP
9jX5JkZTkdDqqJiTEXaHXeakbhDwujgL4KJNLaySl1r4VPUGRSSn3i4J1A==
-----END PUBLIC KEY-----
KEY
if ! /usr/bin/openssl dgst -sha256 -verify key.pem -signature Crumb.zip.sig Crumb.zip >/dev/null 2>&1; then
    echo "The download isn't signed by Crumb's release key, so it wasn't installed." >&2
    exit 1
fi

ditto -x -k Crumb.zip unpacked
codesign --verify --deep --strict unpacked/Crumb.app

# /Applications when it can be written to, otherwise the Applications folder in your home folder.
target=/Applications
if [ ! -w "$target" ]; then
    target="$HOME/Applications"
    mkdir -p "$target"
fi
pkill -x Crumb 2>/dev/null && sleep 1 || true
rm -rf "$target/Crumb.app"
ditto unpacked/Crumb.app "$target/Crumb.app"
open "$target/Crumb.app"
echo "Crumb is installed in $target. Press ⇧⌘C anywhere to open it."
