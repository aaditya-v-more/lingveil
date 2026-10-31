#!/bin/sh
# Installs the Google voices plugin for Lingveil:
#   - google-tts-local, which runs Google's on-device speech engine natively on
#     Apple Silicon (https://github.com/aaditya-v-more/google-tts-local),
#   - its engine and voice data, downloaded from Google's ChromeOS mirror,
#   - a background service on 127.0.0.1:5591 that starts at login,
#   - a "Google" entry in Lingveil's engines.json.
# Run it again to update google-tts-local to the latest version.
set -eu

APP_NAME="${EARMARK_APP_NAME:-Lingveil}"
CONFIG="$HOME/Library/Application Support/$APP_NAME/engines.json"

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
    echo "Google voices need a Mac with Apple silicon." >&2
    exit 1
fi

BREW=$(command -v brew 2>/dev/null || true)
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -z "$BREW" ] && [ -x "$candidate" ]; then BREW=$candidate; fi
done
if [ -z "$BREW" ]; then
    echo "Homebrew is needed to install Google voices. Install it from https://brew.sh and try again." >&2
    exit 1
fi

if "$BREW" list --formula google-tts-local >/dev/null 2>&1; then
    echo "Updating google-tts-local"
    "$BREW" upgrade aaditya-v-more/tap/google-tts-local
else
    echo "Installing google-tts-local"
    "$BREW" install aaditya-v-more/tap/google-tts-local
fi
PREFIX=$("$BREW" --prefix)
GTTS="$PREFIX/bin/gtts"
SERVICE="$PREFIX/bin/gtts-service"

echo "Downloading Google's speech engine and voices"
"$GTTS" fetch

echo "Starting the voice service"
"$SERVICE" install

echo "Adding Google voices to $APP_NAME"
mkdir -p "$(dirname -- "$CONFIG")"
/usr/bin/python3 -I - "$CONFIG" "$SERVICE" <<'EOF'
import json, os, sys, tempfile
path, service = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {"engines": []}
engines = [e for e in config.get("engines", []) if e.get("name") != "Google"]
engines.insert(0, {
    "name": "Google",
    "url": "http://127.0.0.1:5591/speak",
    "voices": "http://127.0.0.1:5591/voices",
    "start": [service, "install"],
    "speed": "engine",
})
config["engines"] = engines
fd, temp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".engines-")
with os.fdopen(fd, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(temp, path)
EOF

echo "Google voices are ready. Choose one in Settings → Voices."
