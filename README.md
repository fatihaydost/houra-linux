# Houra for Linux

A calm focus timer for the Linux desktop: focus sessions with an on-screen counter,
full-screen breaks on every monitor, daily/weekly tasks (optional two-way Todoist),
and local SQLite focus statistics. Built with PySide6 + QML, independent of any
particular desktop.

Houra started as a macOS app: [serbestonline/Houra](https://github.com/serbestonline/Houra)
by Emirhan, the macOS version of Houra. This is a Linux port of it (by way of an
Omarchy shell plugin); the app icon is the macOS original's. Data stays compatible
with the original SQLite schema.

## Requirements

- Python 3.11+
- **System PySide6 / Qt 6** (Arch: `pyside6`; Debian/Ubuntu: `python3-pyside6.*`; Fedora: `python3-pyside6`).
  Do not install PySide6 from pip: the pip wheel bundles its own Qt and cannot load
  the system `org.kde.layershell` QML module.
- For the on-screen counter and break overlay: a compositor with wlr-layer-shell
  (KDE Plasma, Hyprland, Sway, niri, COSMIC) and `layer-shell-qt` 6.
  GNOME and X11 get a plain always-on-top window instead.
- Optional: Qt Multimedia for the chime, a StatusNotifierItem tray (KDE, Waybar, ...).

## Run

```sh
python3 -m houra            # start (or focus) Houra; lives in the tray
python3 -m houra newSession # open the new-session window
```

Or install the `houra` command with `pip install --user --no-deps .` and copy
`data/io.github.fatihaydost.Houra.desktop` to `~/.local/share/applications/`.

## Commands and global shortcuts

A running instance accepts commands; bind them to global shortcuts in any desktop:

```
houra newSession | panel | stats | tab <name> | close | toggle | pause | finish
      closeSession | cancel | syncTodoist | style <name> | status
```

`houra status` prints the current state as JSON.

## Data

- `~/.local/share/houra/houra.sqlite` (`HOURA_DB`), settings `~/.config/houra/settings.json`
  (`HOURA_CONFIG`), cache `~/.cache/houra` (`HOURA_CACHE_DIR`).
- The Todoist token lives only in `~/.local/state/houra/todoist_token` (0600) and is passed
  to the backend in-process, never on a command line.

## Tests

```sh
python3 houra/backend/houra_cli.py --selftest
python3 -m unittest discover tests
QT_QPA_PLATFORM=offscreen python3 -m houra --smoke   # loads every QML file headless
```

## License

MIT, see `LICENSE`.
