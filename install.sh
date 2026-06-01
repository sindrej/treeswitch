#!/bin/zsh
# Install treeswitch: seed ~/.treeswitch and link the SwiftBar plugin.
set -e

SRC="${0:A:h}"
DATA="$HOME/.treeswitch"
PLUGIN="treeswitch.10s.sh"

# SwiftBar's plugin folder. Stored as a security-scoped bookmark in its prefs
# (not a readable path), so we can't auto-detect it reliably. Override order:
#   1) first CLI arg          ./install.sh /path/to/swiftbar-plugins
#   2) $SWIFTBAR_PLUGIN_DIR
#   3) the SwiftBar default location
PLUGINS="${1:-${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}}"

mkdir -p "$DATA/state" "$DATA/logs" "$PLUGINS"

# config: copy on first install, never clobber an edited one
if [[ -f "$DATA/config.zsh" ]]; then
  echo "kept existing config: $DATA/config.zsh"
else
  cp "$SRC/config.zsh" "$DATA/config.zsh"
  echo "installed config:    $DATA/config.zsh"
fi

chmod +x "$SRC/$PLUGIN"
ln -sf "$SRC/$PLUGIN" "$PLUGINS/$PLUGIN"
echo "linked plugin:       $PLUGINS/$PLUGIN -> $SRC/$PLUGIN"

echo
if command -v swiftbar >/dev/null 2>&1 || [[ -d "/Applications/SwiftBar.app" ]]; then
  echo "SwiftBar is installed. If it's running, click the icon → Refresh All,"
  echo "or restart SwiftBar to pick up the new plugin."
else
  echo "SwiftBar not found. Install it with:"
  echo "    brew install --cask swiftbar"
  echo "then launch it and point its Plugin Folder at:"
  echo "    $PLUGINS"
fi
