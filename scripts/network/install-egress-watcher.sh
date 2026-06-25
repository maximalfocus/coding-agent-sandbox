#!/usr/bin/env bash
# Install a per-user macOS LaunchAgent that keeps the egress watcher running:
# starts at login, survives logout/reboot, and (via watch-egress.sh --wait) self-heals
# across sandbox stop/restart cycles. Fires a desktop notification per newly-blocked host.
#
#   ./scripts/network/install-egress-watcher.sh             # install + start
#   ./scripts/network/install-egress-watcher.sh --uninstall # stop + remove
#   ./scripts/network/install-egress-watcher.sh --status    # show launchd state
#
# Why a LaunchAgent (not a compose service): the watcher must run on the HOST — it needs
# Notification Center (osascript) and the docker CLI. A per-user agent is the right scope;
# no sudo, no system domain.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"

LABEL="com.sandbox.watch-egress"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOGDIR="$HOME/Library/Logs/coding-agent-sandbox"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS only (LaunchAgent). On Linux/Windows, run the watcher manually:" >&2
    echo "  ./scripts/network/watch-egress.sh --notify-only --wait" >&2
    exit 1
fi

case "${1:-}" in
    --uninstall)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "removed $LABEL"
        exit 0 ;;
    --status)
        launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|program ) ' || echo "$LABEL is not loaded"
        exit 0 ;;
    ""|--install) ;;
    *) echo "usage: $0 [--install|--uninstall|--status]" >&2; exit 1 ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

# Absolute paths + an explicit minimal env: launchd does NOT source shell init, so PATH must
# carry docker (Homebrew, /usr/local, and Docker Desktop's bundled bin). DOCKER_CONFIG lets the
# CLI find the user's context; the socket is left to docker to resolve (Docker Desktop/Colima/
# OrbStack all differ — don't hard-code it).
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO/scripts/network/watch-egress.sh</string>
        <string>--notify-only</string>
        <string>--wait</string>
    </array>
    <key>WorkingDirectory</key><string>$REPO</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$HOME</string>
        <key>DOCKER_CONFIG</key><string>$HOME/.docker</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$LOGDIR/watch-egress.log</string>
    <key>StandardErrorPath</key><string>$LOGDIR/watch-egress.log</string>
</dict>
</plist>
PLIST_EOF

# Reinstall cleanly (bootout an existing copy first), then bootstrap into the GUI domain.
# Modern flow — `launchctl load` is deprecated and domain-ambiguous (wrong domain => the
# osascript notification silently no-ops).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "installed + started: $LABEL"
echo "  plist: $PLIST"
echo "  log:   $LOGDIR/watch-egress.log"
echo "  verify: ./scripts/network/install-egress-watcher.sh --status"
