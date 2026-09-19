#!/bin/bash
# Entry point for `npx github:hamin-apple/claude-usage-bar`.
# Builds the app from source, quits a running copy, installs to /Applications, opens it.
# Never reads the token or calls the API itself.
set -euo pipefail

APP_NAME="ClaudeUsageBar"
DEST="/Applications/$APP_NAME.app"

usage() {
    echo "Usage: npx github:hamin-apple/claude-usage-bar [--no-open]" >&2
}

OPEN_AFTER=1
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN_AFTER=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Claude Usage Bar needs an Apple Silicon Mac." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift was not found. Install the Command Line Tools first:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

# npm links this file into node_modules/.bin, so resolve the link to find the package root.
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT"

echo "Building $APP_NAME (first build takes a minute)..."
./Scripts/bundle.sh

if [[ ! -w "/Applications" ]]; then
    echo "Can't write to /Applications. Built app is at: $ROOT/build/$APP_NAME.app" >&2
    exit 1
fi

# Only one instance may run at a time (they share one rate limit).
if pkill -x "$APP_NAME"; then
    sleep 1
fi
ditto "build/$APP_NAME.app" "$DEST"
echo "Installed: $DEST"

if [[ "$OPEN_AFTER" == 1 ]]; then
    open "$DEST"
    echo "Started. It lives in the menu bar (no Dock icon)."
fi
echo "Claude Code must be signed in. On the first keychain prompt, choose \"Always Allow\"."
