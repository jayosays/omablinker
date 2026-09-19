#!/usr/bin/env bash
# Reverses install.sh: disables the widget, stops and removes the system
# service and daemon binary, unlinks the plugin from Omarchy's plugin
# directory, and restarts the shell so the disabled widget actually
# disappears. /etc/omablinker.env is left in place in case you reinstall
# later.
set -euo pipefail

PLUGIN_ID="jayosays.omablinker"
PLUGIN_LINK="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

# Best-effort: fails if the widget was never enabled (e.g. install.sh ran
# but the widget was never turned on), which shouldn't abort the rest of
# the cleanup below.
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true

sudo systemctl disable --now omablinker.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/omablinker.service
sudo rm -f /usr/local/bin/omablinker-bpfd
sudo systemctl daemon-reload

if [ -L "$PLUGIN_LINK" ]; then
  rm -f "$PLUGIN_LINK"
  echo "Removed $PLUGIN_LINK"
fi

echo "omablinker disabled, and its system service and binary removed."
echo "/etc/omablinker.env was left in place; delete it manually if you want it gone too."

echo "Restarting the Omarchy shell..."
omarchy restart shell
