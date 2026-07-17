#!/usr/bin/env bash
# Install/refresh the mosh-bootstrap sshd on klundstedt-mini. Run with sudo:
#   sudo ~/dotfiles/ssh/sshd-moshi/install-sshd-moshi.sh
# Idempotent — safe to re-run after config changes.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/ssh/sshd_moshi_config
PLIST=/Library/LaunchDaemons/dev.klundstedt.sshd-moshi.plist
LABEL=dev.klundstedt.sshd-moshi

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

install -m 0644 "$DIR/sshd_moshi_config" "$CONF"
/usr/sbin/sshd -t -f "$CONF"
install -m 0644 -o root -g wheel "$DIR/dev.klundstedt.sshd-moshi.plist" "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

sleep 2
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "[+] $LABEL running"
else
  echo "[!] $LABEL failed to start — see /var/log/sshd-moshi.log" >&2
  exit 1
fi
netstat -an | grep -q "100.123.154.23.2222.*LISTEN" \
  && echo "[+] listening on 100.123.154.23:2222" \
  || echo "[i] not listening yet (tailscale interface may still be coming up; KeepAlive will retry)"
