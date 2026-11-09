"""Global shortcuts through the org.freedesktop.portal.GlobalShortcuts XDG portal."""
from __future__ import annotations

import itertools
import os
import sys
import threading
from collections.abc import Callable

from PySide6.QtCore import QObject, Qt, Signal, Slot

try:  # QtDBus in PySide6 cannot marshal a(sa{sv}): qDBusRegisterMetaType is not exposed
    from jeepney import DBusAddress, MatchRule, message_bus, new_method_call
    from jeepney.io.blocking import Proxy, open_dbus_connection
    from jeepney.wrappers import unwrap_msg
except ImportError:
    open_dbus_connection = None

# id -> (IPC command, portal properties); triggers are XDG shortcuts-spec keysyms, so a lowercase n
SHORTCUTS = {
    "new-session": ("newSession", {"description": ("s", "New session"), "preferred_trigger": ("s", "CTRL+ALT+n")}),
    "panel": ("panel", {"description": ("s", "Open panel")}),
}
SESSION_TOKEN = "houra"
_PATH = "/org/freedesktop/portal/desktop"
_IFACE = "org.freedesktop.portal.GlobalShortcuts"
_TIMEOUT = 30
_tokens = itertools.count(1)


def missing(listed) -> list[str]:
    """Shortcut ids absent from a ListShortcuts `shortcuts` value."""
    have = {sid for sid, _ in listed}
    return [sid for sid in SHORTCUTS if sid not in have]


def _portal_call(method: str, signature: str, body: tuple):
    return new_method_call(DBusAddress(_PATH, "org.freedesktop.portal.Desktop", _IFACE), method, signature, body)


def _options(**extra) -> tuple[str, dict]:
    token = f"houra{next(_tokens)}"
    return token, {"handle_token": ("s", token), **extra}


def _request(conn, method: str, signature: str, args: tuple, **extra) -> dict:
    """Call a Request-returning portal method and wait for its Response."""
    token, options = _options(**extra)
    sender = conn.unique_name[1:].replace(".", "_")
    # Subscribed before the call: the Response may overtake the method reply
    rule = MatchRule(type="signal", interface="org.freedesktop.portal.Request", member="Response",
                     path=f"{_PATH}/request/{sender}/{token}")
    Proxy(message_bus, conn, timeout=_TIMEOUT).AddMatch(rule)
    with conn.filter(rule) as responses:
        unwrap_msg(conn.send_and_get_reply(_portal_call(method, signature, (*args, options)), timeout=_TIMEOUT))
        code, results = conn.recv_until_filtered(responses, timeout=_TIMEOUT).body
    if code:
        raise RuntimeError(f"{method} answered {code}")
    return results


def _bind(conn, session: str) -> str:
    # The whole set even if only one is missing: KDE replaces the session's list with what it gets.
    # The Response is not awaited, it depends on a human answering the portal's dialog.
    shortcuts = [(sid, props) for sid, (_, props) in SHORTCUTS.items()]
    body = (session, shortcuts, "", _options()[1])
    return unwrap_msg(conn.send_and_get_reply(_portal_call("BindShortcuts", "oa(sa{sv})sa{sv}", body),
                                              timeout=_TIMEOUT))[0]


def _serve(emit: Callable[[str], None], session_token: str = SESSION_TOKEN) -> None:
    try:
        # The portal session lives as long as this connection, so it stays open until exit
        with open_dbus_connection() as conn:
            session = _request(conn, "CreateSession", "a{sv}", (),
                               session_handle_token=("s", session_token))["session_handle"][1]
            listed = _request(conn, "ListShortcuts", "oa{sv}", (session,))["shortcuts"][1]
            rule = MatchRule(type="signal", interface=_IFACE, member="Activated", path=_PATH)
            Proxy(message_bus, conn, timeout=_TIMEOUT).AddMatch(rule)
            with conn.filter(rule, bufsize=16) as activated:
                if missing(listed):
                    _bind(conn, session)
                while True:
                    emit(conn.recv_until_filtered(activated).body[1])
    except Exception as exc:  # a missing portal or a dying bus must never reach the app
        print(f"houra: global shortcuts unavailable: {exc}", file=sys.stderr)


class _Bridge(QObject):
    activated = Signal(str)

    def __init__(self, run: Callable[[str], object], parent: QObject):
        super().__init__(parent)
        self._run = run
        self.activated.connect(self._fire, Qt.QueuedConnection)  # QML must only be touched on this thread

    @Slot(str)
    def _fire(self, sid: str) -> None:
        if sid in SHORTCUTS:
            self._run(SHORTCUTS[sid][0])


def start(run: Callable[[str], object], parent: QObject) -> None:
    """Register once on a daemon thread; never blocks or raises."""
    # Without an app id KDE pools every such app into one component, and BindShortcuts would drop the others' keys
    if not os.environ.get("FLATPAK_ID"):
        print("houra: global shortcuts: no Flatpak app identity, bind `houra <cmd>` by hand", file=sys.stderr)
    elif open_dbus_connection is None:
        print("houra: global shortcuts unavailable: jeepney is not installed", file=sys.stderr)
    else:
        threading.Thread(target=_serve, args=(_Bridge(run, parent).activated.emit,), daemon=True).start()
