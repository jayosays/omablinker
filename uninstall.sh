#!/usr/bin/env bash
# Reverses install.sh: disables the widget, removes it from Omarchy's
# plugin directory, stops and removes the system service and daemon
# binary, and restarts the shell so the disabled widget actually
# disappears. /etc/omablinker.env is left in place in case you reinstall
# later.
set -euo pipefail

PLUGIN_ID="jayosays.omablinker"

# Best-effort: fails if the widget was never enabled (e.g. install.sh ran
# but the widget was never turned on), which shouldn't abort the rest of
# the cleanup below.
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true

# Also best-effort: fails if the plugin was already removed (e.g. a
# previous, interrupted uninstall) or was never added via `omarchy plugin
# add`/symlinked in the first place. Handles unlinking a symlink,
# deleting a git-managed clone, or backing up a plain directory — whichever
# this install actually is.
omarchy plugin remove "$PLUGIN_ID" --yes 2>/dev/null || true

sudo systemctl disable --now omablinker.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/omablinker.service
sudo rm -f /usr/local/bin/omablinker-bpfd
sudo systemctl daemon-reload

# Best-effort: catches a stray instance that was never managed by systemd
# at all, e.g. left running from a `cd bpfd && cargo run ...` dev-testing
# session (see the Development section of the README). The `systemctl
# disable --now` above only stops the systemd-managed one.
sudo pkill -x omablinker-bpfd 2>/dev/null || true

echo "omablinker removed, and its system service and binary deleted."
echo "/etc/omablinker.env was left in place; delete it manually if you want it gone too."

echo "Restarting the Omarchy shell..."
omarchy restart shell
