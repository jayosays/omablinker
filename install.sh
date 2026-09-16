#!/usr/bin/env bash
# Builds the privileged half of omablinker (the eBPF daemon) and installs it
# plus its systemd service, then links this checkout into Omarchy's plugin
# directory.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BPFD_DIR="$PLUGIN_DIR/bpfd"
PLUGIN_ID="jayosays.omablinker"
BIN_DEST="/usr/local/bin/omablinker-bpfd"
UNIT_DEST="/etc/systemd/system/omablinker.service"
ENV_DEST="/etc/omablinker.env"
PLUGIN_LINK="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "omablinker installer"
echo "This will:"
echo "  1. Install rustup and bpf-linker if either is missing."
echo "  2. Build the eBPF daemon (Rust/Aya)."
echo "  3. Install it and a systemd system service to $BIN_DEST (needs sudo)."
echo "  4. Link this checkout into $PLUGIN_LINK so Omarchy can find it."
echo

if ! command -v cargo >/dev/null 2>&1 || ! command -v bpf-linker >/dev/null 2>&1; then
  echo "Installing rustup/bpf-linker..."
  omarchy pkg add rustup bpf-linker
fi

echo "Building omablinker-bpfd (release)..."
( cd "$BPFD_DIR" && cargo build --release )

# Leftovers from earlier names this project used, if this is an upgrade:
# the original Python/BCC prototype, and the Rust daemon's previous name
# (omahddact) before the project was renamed to omablinker.
sudo rm -f /usr/local/bin/omahddact-bpfd.py
sudo systemctl disable --now omahddact.service 2>/dev/null || true
sudo rm -f /usr/local/bin/omahddact-bpfd /etc/systemd/system/omahddact.service
rm -f "$HOME/.config/omarchy/plugins/jayo.omahddact"

sudo install -Dm755 "$BPFD_DIR/target/release/omablinker-bpfd" "$BIN_DEST"
sudo install -Dm644 "$PLUGIN_DIR/systemd/omablinker.service" "$UNIT_DEST"
if [ ! -e "$ENV_DEST" ]; then
  sudo install -Dm644 "$PLUGIN_DIR/systemd/omablinker.env.example" "$ENV_DEST"
fi

sudo systemctl daemon-reload
sudo systemctl enable omablinker.service
# `restart`, not `--now`/`start`: if the service is already running (e.g. an
# upgrade from a previous install), `start` on an active unit is a no-op and
# would leave the old binary running.
sudo systemctl restart omablinker.service

mkdir -p "$HOME/.config/omarchy/plugins"
if [ "$PLUGIN_DIR" = "$PLUGIN_LINK" ]; then
  : # Already at the standard location, e.g. installed via `omarchy plugin add`.
elif [ ! -e "$PLUGIN_LINK" ]; then
  ln -s "$PLUGIN_DIR" "$PLUGIN_LINK"
  echo "Linked plugin into $PLUGIN_LINK"
elif [ -L "$PLUGIN_LINK" ]; then
  echo "$PLUGIN_LINK already links here."
else
  echo "warning: $PLUGIN_LINK already exists and isn't a symlink to this checkout; leaving it alone." >&2
fi

echo
echo "Daemon status:"
systemctl --no-pager status omablinker.service || true
echo
echo "Now enable the widget itself:"
echo "  omarchy plugin enable $PLUGIN_ID"
echo "Then add it to a bar section from Setup > Plugins, or edit shell.json directly."
echo
echo "Useful commands:"
echo "  systemctl status omablinker"
echo "  journalctl -u omablinker -f"
echo "  cat /run/omablinker/state        # current state: 0 (idle) or 1 (active)"
