#!/bin/sh
# Data lives at the host XDG paths so the native and Flatpak builds share one history.
if [ -z "$HOURA_DB" ]; then
  # db_path() hardens only its own default, not a path handed in through HOURA_DB.
  mkdir -p "$HOME/.local/share/houra" && chmod 700 "$HOME/.local/share/houra"
  export HOURA_DB="$HOME/.local/share/houra/houra.sqlite"
fi
export HOURA_CONFIG="${HOURA_CONFIG:-$HOME/.config/houra/settings.json}"
export HOURA_STATE_DIR="${HOURA_STATE_DIR:-$HOME/.local/state/houra}"
export PYTHONPATH="/app/share/houra${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m houra "$@"
