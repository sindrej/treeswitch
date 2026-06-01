#!/bin/zsh
# Remove the SwiftBar plugin link. Leaves ~/.treeswitch (config + logs)
# alone unless you pass --purge.
set -e

PLUGIN="treeswitch.10s.sh"
PLUGINS="${1:-${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}}"
[[ "$1" == "--purge" ]] && PLUGINS="${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}"

rm -f "$PLUGINS/$PLUGIN" && echo "removed plugin: $PLUGINS/$PLUGIN"

if [[ "$1" == "--purge" || "$2" == "--purge" ]]; then
  rm -rf "$HOME/.treeswitch"
  echo "purged ~/.treeswitch (config + logs + state)"
else
  echo "kept ~/.treeswitch (config + logs). Remove with: rm -rf ~/.treeswitch"
fi

open "swiftbar://refreshallplugins" 2>/dev/null || true
