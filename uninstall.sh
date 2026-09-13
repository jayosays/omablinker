#!/usr/bin/env bash
# Reverses install.sh: stops and removes the system service and daemon
# binary, and unlinks the plugin from Omarchy's plugin directory.
# /etc/omablinker.env is left in place in case you reinstall later.
set -euo pipefail

PLUGIN_ID="jayosays.omablinker"
PLUGIN_LINK="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

sudo systemctl disable --now omablinker.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/omablinker.service
sudo rm -f /usr/local/bin/omablinker-bpfd
sudo systemctl daemon-reload

if [ -L "$PLUGIN_LINK" ]; then
  rm -f "$PLUGIN_LINK"
  echo "Removed $PLUGIN_LINK"
fi

echo "omablinker system service and binary removed."
echo "If the widget is still enabled in ~/.config/omarchy/shell.json, run:"
echo "  omarchy plugin disable $PLUGIN_ID"
echo "/etc/omablinker.env was left in place; delete it manually if you want it gone too."
