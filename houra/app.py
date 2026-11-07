"""Houra desktop entry point: PySide6 host for the QML UI and the stdlib backend."""
from __future__ import annotations

import json
import os
import signal
import sys
from pathlib import Path

from PySide6.QtCore import (
    Property, QMetaObject, QObject, QRect, QRunnable, QThreadPool, QTimer, QUrl, Q_ARG,
    Q_RETURN_ARG, Qt, Signal, Slot, qInstallMessageHandler, QtMsgType,
)
from PySide6.QtDBus import QDBusConnection, QDBusInterface
from PySide6.QtGui import QGuiApplication, QIcon, QRegion
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtQml import QQmlApplicationEngine, QQmlComponent
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from . import autostart
from .backend import houra_cli

APP_ID = "io.github.fatihaydost.Houra"
PKG_DIR = Path(__file__).resolve().parent
QML_DIR = PKG_DIR / "qml"
ICON_PATH = PKG_DIR / "assets" / "icon.png"
COMMANDS = {
    "newSession", "panel", "open", "stats", "tab", "close", "toggle", "pause", "finish",
    "closeSession", "cancel", "syncTodoist", "style", "status",
}
# Only these may start the app when no instance is running; the rest act on a live one.
LAUNCH_COMMANDS = {"", "open", "newSession", "panel", "stats", "tab"}


class _Call(QRunnable):
    def __init__(self, host: "Host", call_id: int, cmd: str, payload: dict):
        super().__init__()
        self.host, self.call_id, self.cmd, self.payload = host, call_id, cmd, payload

    def run(self) -> None:
        try:
            # JSON round trip keeps the old CLI contract (plain types both ways)
            payload = json.loads(json.dumps(self.payload or {}))
            result = houra_cli.handle_command(self.cmd, payload if isinstance(payload, dict) else {})
            result = json.loads(json.dumps(result, ensure_ascii=False))
        except Exception as exc:  # backend errors must not stall the QML queue
            result = {"ok": False, "error": str(exc)}
        self.host.callFinished.emit(self.call_id, result)


class Host(QObject):
    callFinished = Signal(int, "QVariant")
    screenChanged = Signal()
    dndChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(1)  # serialized: keeps SQLite write ordering
        self._next_id = 0
        self._sound = None
        self._dnd_cookie = 0
        self.tray: QSystemTrayIcon | None = None
        self._notif = QDBusInterface(
            "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications", QDBusConnection.sessionBus(),
        )
        self._dnd_supported = False
        if self._notif.isValid():
            caps = self._notif.call("GetCapabilities").arguments()
            self._dnd_supported = bool(caps) and "inhibitions" in (caps[0] or [])
        app = QGuiApplication.instance()
        if app:  # activeScreenName follows the focused window
            app.focusWindowChanged.connect(self.screenChanged)

    @Slot(str, "QVariant", result=int)
    def call(self, cmd: str, payload) -> int:
        self._next_id += 1
        self._pool.start(_Call(self, self._next_id, cmd, payload if isinstance(payload, dict) else {}))
        return self._next_id

    @Slot(QObject, "QVariantList")
    def setInputMask(self, window, rects) -> None:
        if window is None:
            return
        if not rects:
            window.setMask(QRegion())
            return
        region = QRegion()
        for r in rects:
            w, h = int(r.get("width", 0)), int(r.get("height", 0))
            if w > 0 and h > 0:
                region = region.united(QRegion(QRect(int(r.get("x", 0)), int(r.get("y", 0)), w, h)))
        # An empty QRegion would mean "no mask"; a pixel outside the surface means "no input"
        window.setMask(region if not region.isEmpty() else QRegion(-1, -1, 1, 1))

    @Slot(result=str)
    def clipboardText(self) -> str:
        return QGuiApplication.clipboard().text()

    def _get_dnd_supported(self) -> bool:
        return self._dnd_supported

    dndSupported = Property(bool, _get_dnd_supported, constant=True)

    def _get_dnd(self) -> bool:
        if not self._dnd_supported:
            return False
        if self._dnd_cookie:
            return True
        v = self._notif.property("Inhibited")
        return bool(v)

    doNotDisturb = Property(bool, _get_dnd, notify=dndChanged)

    autostartChanged = Signal()

    def _get_autostart(self) -> bool:
        return autostart.is_enabled()

    autostartEnabled = Property(bool, _get_autostart, notify=autostartChanged)

    @Slot(bool, result=bool)
    def setAutostart(self, on: bool) -> bool:
        try:
            state = autostart.set_enabled(on)
        except OSError as e:
            print(f"houra: autostart: {e}", file=sys.stderr)
            state = autostart.is_enabled()
        self.autostartChanged.emit()
        return state

    @Slot(bool, result=bool)
    def setDoNotDisturb(self, on: bool) -> bool:
        """on: inhibit only if DND is not already on; returns whether Houra now holds its own cookie."""
        if not self._dnd_supported:
            return False
        if on and not self._dnd_cookie and not bool(self._notif.property("Inhibited")):
            reply = self._notif.call("Inhibit", APP_ID, "Houra focus session", {})
            args = reply.arguments()
            self._dnd_cookie = int(args[0]) if args else 0
        elif not on and self._dnd_cookie:
            self._notif.call("UnInhibit", self._dnd_cookie)
            self._dnd_cookie = 0
        self.dndChanged.emit()
        return bool(self._dnd_cookie)

    def _get_active_screen(self) -> str:
        win = QGuiApplication.focusWindow()
        screen = win.screen() if win else QGuiApplication.primaryScreen()
        return screen.name() if screen else ""

    activeScreenName = Property(str, _get_active_screen, notify=screenChanged)

    def _get_home(self) -> str:
        return str(Path.home())

    homeDir = Property(str, _get_home, constant=True)

    @Slot(str)
    def playSound(self, path: str) -> None:
        if not path:
            return
        from PySide6.QtMultimedia import QSoundEffect
        if self._sound is None:
            self._sound = QSoundEffect(self)
            self._sound.setVolume(0.6)
        self._sound.setSource(QUrl.fromLocalFile(path))
        self._sound.play()

    @Slot(str)
    def setTrayStatus(self, tooltip: str) -> None:
        if self.tray:
            self.tray.setToolTip(tooltip)


def _flush_on_quit(host: Host, root: QObject) -> None:
    """Run the QML side's pending writes and a final checkpoint synchronously before exit."""
    host._pool.waitForDone(3000)
    jobs = QMetaObject.invokeMethod(root, "drainForQuit", Qt.DirectConnection, Q_RETURN_ARG("QVariant"))
    if hasattr(jobs, "toVariant"):
        jobs = jobs.toVariant()
    for cmd, payload in jobs or []:
        try:
            res = houra_cli.handle_command(str(cmd), json.loads(json.dumps(payload or {})))
            if not res.get("ok"):
                print(f"houra: quit flush {cmd} failed: {res.get('error')}", file=sys.stderr)
        except Exception as exc:
            print(f"houra: quit flush {cmd} failed: {exc}", file=sys.stderr)


def _send_to_running(cmd: str, arg: str) -> str | None:
    sock = QLocalSocket()
    sock.connectToServer(APP_ID)
    if not sock.waitForConnected(500):
        return None
    sock.write((json.dumps([cmd, arg]) + "\n").encode())
    sock.flush()
    data = b""
    while sock.waitForReadyRead(3000):
        data += bytes(sock.readAll())
        if data.endswith(b"\n"):
            break
    sock.disconnectFromServer()
    return data.decode(errors="replace").strip()


def _layer_shell_available(engine: QQmlApplicationEngine) -> bool:
    if QGuiApplication.platformName() != "wayland":
        return False
    if "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", "").upper():
        return False
    probe = QQmlComponent(engine)
    probe.setData(b"import QtQml\nimport org.kde.layershell 1.0\nQtObject {}\n", QUrl())
    return probe.isReady()


def _make_engine(app, host: Host, layer: bool) -> QQmlApplicationEngine:
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(QML_DIR))
    engine.addImportPath(str(QML_DIR / ("shell-layer" if layer else "shell-plain")))
    engine.rootContext().setContextProperty("Host", host)
    engine.warnings.connect(lambda ws: [print("QML:", w.toString(), file=sys.stderr) for w in ws])
    return engine


def _invoke(root: QObject, cmd: str, arg: str) -> str:
    res = QMetaObject.invokeMethod(
        root, "ipc", Qt.DirectConnection, Q_RETURN_ARG("QVariant"),
        Q_ARG("QVariant", cmd), Q_ARG("QVariant", arg),
    )
    return str(res)


def _smoke() -> int:
    """Load every QML file headless; fail on any QML warning or error."""
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    problems: list[str] = []

    def handler(mode, ctx, msg):
        if mode != QtMsgType.QtDebugMsg and ("qml" in msg.lower() or (ctx.file or "").endswith((".qml", ".js"))):
            problems.append(f"{ctx.file}:{ctx.line}: {msg}")
        sys.stderr.write(msg + "\n")

    qInstallMessageHandler(handler)
    app = QApplication(sys.argv[:1])
    host = Host()
    for layer in (False, True):
        engine = _make_engine(app, host, layer)
        engine.warnings.connect(lambda ws: problems.extend(w.toString() for w in ws))
        files = sorted(QML_DIR.rglob("*.qml"))
        for f in files:
            if ("shell-plain" in f.parts and layer) or ("shell-layer" in f.parts and not layer):
                continue
            comp = QQmlComponent(engine, QUrl.fromLocalFile(str(f)))
            if comp.isError():
                problems.extend(e.toString() for e in comp.errors())
        if not layer:
            engine.load(QUrl.fromLocalFile(str(QML_DIR / "Service.qml")))
            if not engine.rootObjects():
                problems.append("Service.qml did not load")
            else:
                root = engine.rootObjects()[0]
                _invoke(root, "newSession", "")
                if not any(w.isVisible() for w in QGuiApplication.topLevelWindows()):
                    problems.append("newSession did not show a window")
                for cmd in ("status", "panel", "close"):
                    _invoke(root, cmd, "")
                QTimer.singleShot(1500, app.quit)
                app.exec()
        print(f"checked {len(files)} QML files (layer-shell={'on' if layer else 'off'})")
    for p in problems:
        print("QML PROBLEM:", p)
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    args = argv[1:]
    if args and args[0] == "--smoke":
        return _smoke()
    if args and args[0] == "--selftest":
        return houra_cli.run_selftest()
    if args and args[0] == "--login":
        if len(args) > 1 and args[1] in ("on", "off"):
            autostart.set_enabled(args[1] == "on")
        elif len(args) > 1:
            print("usage: houra --login [on|off]", file=sys.stderr)
            return 2
        print("on" if autostart.is_enabled() else "off")
        return 0
    cmd = args[0] if args else ""
    arg = args[1] if len(args) > 1 else ""
    if cmd and cmd not in COMMANDS:
        print(f"usage: houra [{'|'.join(sorted(COMMANDS))}] [arg]", file=sys.stderr)
        return 2

    QGuiApplication.setDesktopFileName(APP_ID)
    app = QApplication(argv[:1])
    app.setApplicationName("Houra")
    app.setOrganizationDomain("io.github.fatihaydost")
    app.setQuitOnLastWindowClosed(False)
    app.setWindowIcon(QIcon(str(ICON_PATH)))

    reply = _send_to_running(cmd or "open", arg)
    if reply is not None:
        if reply and (cmd == "status" or reply.startswith("unknown")):
            print(reply)
        return 0
    if cmd not in LAUNCH_COMMANDS:
        print("Houra is not running", file=sys.stderr)
        return 1

    # Listen before the slow QML load so a second `houra ...` during startup finds
    # this instance instead of launching another one; requests wait in `queued`.
    QLocalServer.removeServer(APP_ID)
    server = QLocalServer(app)
    server.setSocketOptions(QLocalServer.UserAccessOption)
    if not server.listen(APP_ID):  # e.g. a TMPDIR long enough to pass the 108-byte socket path limit
        print(f"houra: commands disabled, cannot listen: {server.errorString()}", file=sys.stderr)
    state: dict = {"root": None, "queued": []}

    def run(c: str, a: str = "") -> str:
        if state["root"] is None:
            state["queued"].append((c, a))
            return "starting"
        return _invoke(state["root"], c, a)

    def on_conn():
        sock = server.nextPendingConnection()

        def on_read():
            if not sock.canReadLine():
                return
            try:
                c, a = json.loads(bytes(sock.readLine()).decode())
            except Exception:
                c, a = "", ""
            out = run(str(c), str(a)) if c in COMMANDS else "unknown command"
            sock.write((out + "\n").encode())
            sock.flush()
            sock.disconnectFromServer()

        sock.readyRead.connect(on_read)
        sock.disconnected.connect(sock.deleteLater)
        on_read()  # the request may already be buffered

    server.newConnection.connect(on_conn)

    host = Host()
    engine = _make_engine(app, host, _layer_shell_available(QQmlApplicationEngine()))
    engine.load(QUrl.fromLocalFile(str(QML_DIR / "Service.qml")))
    if not engine.rootObjects():
        return 1
    state["root"] = engine.rootObjects()[0]
    for c, a in state["queued"]:
        QTimer.singleShot(0, lambda c=c, a=a: run(c, a))

    tray = QSystemTrayIcon(QIcon(str(ICON_PATH)), app)
    tray.setToolTip("Houra")
    menu = QMenu()
    root = state["root"]

    def tray_action(key: str) -> None:
        if key == "quit":
            app.quit()
        else:
            QMetaObject.invokeMethod(root, "trayAction", Qt.DirectConnection, Q_ARG("QVariant", key))

    def fill(target: QMenu, entries) -> None:
        for e in entries or []:
            if e.get("separator"):
                target.addSeparator()
            elif e.get("children"):
                fill(target.addMenu(str(e.get("label", ""))), e["children"])
            else:
                act = target.addAction(str(e.get("label", "")))
                act.setEnabled(bool(e.get("enabled", True)))
                if e.get("checked") is not None:
                    act.setCheckable(True)
                    act.setChecked(bool(e["checked"]))
                key = str(e.get("key", ""))
                act.triggered.connect(lambda _=False, k=key: tray_action(k))

    def rebuild() -> None:
        entries = QMetaObject.invokeMethod(root, "trayMenu", Qt.DirectConnection, Q_RETURN_ARG("QVariant"))
        if hasattr(entries, "toVariant"):  # a JS array arrives as QJSValue
            entries = entries.toVariant()
        menu.clear()
        fill(menu, entries)

    # Rebuilt on open so the clock, phase and chosen counter style are current.
    menu.aboutToShow.connect(rebuild)
    rebuild()
    tray.setContextMenu(menu)
    tray.activated.connect(lambda reason: run("panel") if reason == QSystemTrayIcon.Trigger else None)
    host.tray = tray
    tray.show()

    app.aboutToQuit.connect(lambda: _flush_on_quit(host, root))
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    sig_tick = QTimer(app)  # lets Python run its signal handler while Qt's loop blocks
    sig_tick.timeout.connect(lambda: None)
    sig_tick.start(500)

    if cmd:
        QTimer.singleShot(0, lambda: run(cmd, arg))
    rc = app.exec()
    host.setDoNotDisturb(False)
    del engine  # destroy QML before Host so bindings never see a null Host
    return rc
