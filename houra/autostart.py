"""Launch at login via an XDG autostart entry; state is the file's existence."""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

APP_ID = "io.github.fatihaydost.Houra"
REPO_DIR = Path(__file__).resolve().parent.parent


FLATPAK = bool(os.environ.get("FLATPAK_ID"))


def desktop_path() -> Path:
    # Inside Flatpak XDG_CONFIG_HOME is the sandbox's; the session reads the host ~/.config/autostart.
    base = str(Path.home() / ".config") if FLATPAK else (os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config"))
    return Path(base) / "autostart" / f"{APP_ID}.desktop"


def _exec_arg(arg: str) -> str:
    # Desktop Entry spec quoting (shlex.quote's single quotes are not valid here); % is a field code.
    arg = arg.replace("%", "%%")
    if not any(c in arg for c in ' \t\n"\'\\><~|&;$*?#()`'):
        return arg
    return '"' + "".join("\\" + c if c in '"`$\\' else c for c in arg) + '"'


def exec_line() -> tuple[str, str | None]:
    """(Exec value, working dir or None) matching how the user runs Houra now."""
    if FLATPAK:
        return f"flatpak run {os.environ['FLATPAK_ID']}", None
    found = shutil.which("houra")
    if found:  # absolute: the login session's PATH may lack ~/.local/bin
        return _exec_arg(found), None
    return " ".join(_exec_arg(a) for a in (sys.executable, "-m", "houra")), str(REPO_DIR)


def is_enabled() -> bool:
    return desktop_path().is_file()


def set_enabled(on: bool) -> bool:
    path = desktop_path()
    if on:
        cmd, cwd = exec_line()
        lines = ["[Desktop Entry]", "Type=Application", "Name=Houra", f"Exec={cmd}",
                 f"Icon={APP_ID}", "X-GNOME-Autostart-enabled=true"]
        if cwd:
            lines.append(f"Path={cwd}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    else:
        path.unlink(missing_ok=True)
    return is_enabled()
