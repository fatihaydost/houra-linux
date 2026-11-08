#!/bin/sh
# Data lives at the host XDG paths so the native and Flatpak builds share one history.
export HOURA_DB="${HOURA_DB:-$HOME/.local/share/houra/houra.sqlite}"
export HOURA_CONFIG="${HOURA_CONFIG:-$HOME/.config/houra/settings.json}"
export HOURA_STATE_DIR="${HOURA_STATE_DIR:-$HOME/.local/state/houra}"
export PYTHONPATH="/app/share/houra${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m houra "$@"
