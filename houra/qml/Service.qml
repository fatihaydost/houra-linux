import QtQuick
import QtQuick.Dialogs
import qs.Commons
import qs.Commons as Commons
import "Theme.js" as Theme
import "windows"

// Background service for Houra. Owns the session timer state machine, the
// serialized backend call queue (Host.call), audio chime, optional DND sync,
// IPC/tray commands (`houra <command>` -> ipc()), and all windows.
Item {
  id: svcRoot


  // --- Session Engine State ---
  property string phase: "idle" // "idle" | "focus" | "paused" | "rest"
  property int sessionId: 0
  property int sessionCategoryId: 0
  property string sessionGoal: ""
  property int workMinutes: 50
  property int restMinutes: 10
  property real sessionStart: 0
  property int elapsedSeconds: 0
  property int restRemaining: 0
  property string sessionNote: ""
  property var sessionTodos: []
  property bool breakOverlayVisible: false
  property bool breakNudgeActive: false
  property bool nativeDialogOpen: false
  readonly property bool newSessionOpen: newSessionWin.open

  property real _focusAnchorMs: 0
  property int _accumFocusSec: 0
  property real _pauseAnchorMs: 0
  property int _accumPausedSec: 0
  property int livePausedSeconds: 0
  property real _restEndMs: 0
  property int _lastNudgeBucket: 0
  property int _lastCheckpointBucket: 0

  // --- Omarchy DND integration state ---
  property bool _managedDnd: false
  property bool _priorDnd: false

  // --- Hydrated Backend Snapshot ---
  property var settings: ({
    language: "system",
    widgetStyle: "tag",
    widgetLeft: false,
    tagY: -1,
    positions: { capsule: [-1, -1], card: [-1, -1], ring: [-1, -1] },
    lastTopic: 0,
    rhythmMode: "50",
    rhythmWork: 50,
    customWork: 45,
    customRest: 10,
    weeklyOn: true,
    weeklyTemplate: "",
    todoistOn: false,
    todoistFilter: "today | overdue",
    themeMode: "system",
    focusDnd: false,
    widgetScreen: ""
  })
  property string lang: "en"
  readonly property string widgetStyle: settings && settings.widgetStyle ? String(settings.widgetStyle) : "tag"
  readonly property string resolvedWidgetScreenName: onScreenWidgetWin.resolvedScreenName
  property string dbPath: "~/.local/share/houra/houra.sqlite"
  property string chimePath: ""
  property string lastCsvStatus: ""
  property bool todoistSyncing: false

  property var categories: []
  property var todayData: ({})
  property var weeklyData: ({})
  property var todoistData: ({})
  readonly property bool todoistConnected: !!(todoistData && todoistData.enabled && todoistData.hasToken)
  property var statsData: ({})
  property var historyData: []

  // Query filter state
  property string statsRangeStart: ""
  property string statsRangeEnd: ""
  property int statsTopicId: 0
  property bool historyNotesOnly: false
  property int historyTopicId: 0
  property string historyDayFilter: ""

  // Live theme tokens reactive to Omarchy's active theme OR Houra Classic mode
  readonly property var tokens: Theme.resolveTokens(
    settings && settings.themeMode ? String(settings.themeMode) : "system",
    Commons.Color.background,
    Commons.Color.foreground,
    Commons.Color.accent,
    Commons.Color.urgent
  )

  readonly property var activeCategory: {
    for (var i = 0; i < categories.length; i++) {
      if (Number(categories[i].id) === sessionCategoryId) return categories[i]
    }
    return categories.length > 0 ? categories[0] : { id: 0, name: "General", color: "#4c8df0", emoji: "", icon: "", iconColor: "" }
  }

  readonly property string activeTodoTitle: {
    for (var i = 0; i < sessionTodos.length; i++) {
      if (Number(sessionTodos[i].state) === 1) return String(sessionTodos[i].title || "")
    }
    return ""
  }

  readonly property string clockText: {
    if (phase === "focus" || phase === "paused") {
      if (workMinutes > 0) {
        return Theme.formatClock(Math.max(0, workMinutes * 60 - elapsedSeconds))
      }
      return Theme.formatClock(elapsedSeconds)
    }
    if (phase === "rest") return Theme.formatClock(restRemaining)
    return "00:00"
  }

  readonly property string restClockText: Theme.formatClock(restRemaining)

  readonly property real plannedEndEpoch: {
    if ((phase !== "focus" && phase !== "paused") || workMinutes <= 0 || sessionStart <= 0) return 0
    return sessionStart + workMinutes * 60 + livePausedSeconds
  }

  readonly property real progress: {
    if (phase !== "focus" && phase !== "paused") return 0.0
    if (workMinutes > 0) {
      return Math.max(0.0, Math.min(1.0, elapsedSeconds / Math.max(1, workMinutes * 60)))
    }
    // Free mode fills to 1.0 over 50 minutes (3000s) matching Focus.swift:53
    return Math.max(0.0, Math.min(1.0, elapsedSeconds / 3000.0))
  }


  // --- Lifecycle ---
  Component.onCompleted: {
    enqueueRpc("snapshot", _withQueryFilters({ resumeIfLive: true }), function(res) {
      var s = res && res.resumedSession ? res.resumedSession : null
      if (s && svcRoot.phase === "idle") {
        var el = Math.max(0, Number(s.elapsedSec) || 0)
        svcRoot.sessionId = Number(s.id)
        svcRoot.sessionCategoryId = Number(s.categoryId)
        svcRoot.sessionGoal = String(s.goal || "")
        svcRoot.workMinutes = Number(s.workMin)
        svcRoot.restMinutes = Number(s.restMin)
        svcRoot.sessionStart = Number(s.start)
        svcRoot.sessionNote = String(s.note || "")
        svcRoot.sessionTodos = s.todos || []
        svcRoot.elapsedSeconds = el
        svcRoot._accumFocusSec = el
        svcRoot._accumPausedSec = 0
        svcRoot.livePausedSeconds = 0
        svcRoot._focusAnchorMs = Date.now()
        svcRoot._lastNudgeBucket = Math.floor(el / 3000)
        svcRoot._lastCheckpointBucket = Math.floor(el / 60)
        svcRoot.breakNudgeActive = false
        svcRoot.breakOverlayVisible = false
        svcRoot.phase = "focus"
        svcRoot._applyFocusDndIfEnabled()
      }
    })
  }

  Component.onDestruction: {
    _restoreDndIfManaged()
  }

  // --- DND Sync (Host: org.freedesktop.Notifications Inhibit) ---

  function _applyFocusDndIfEnabled() {
    if (!settings || !settings.focusDnd) {
      _restoreDndIfManaged()
      return
    }
    if (_managedDnd) return
    if (!Host.dndSupported) return
    _priorDnd = !!Host.doNotDisturb
    _managedDnd = true
    if (!_priorDnd) Host.setDoNotDisturb(true)
  }

  function _restoreDndIfManaged() {
    if (!_managedDnd) return
    Host.setDoNotDisturb(_priorDnd)
    _managedDnd = false
  }

  // --- Audio Chime ---
  function playChime() {
    if (!chimePath) return
    Host.playSound(chimePath)
  }

  // --- Sequential RPC Queue to Python SQLite Backend ---
  property var _rpcQueue: []
  property bool _rpcBusy: false
  property var _currentRpc: null

  function _withQueryFilters(extra) {
    var p = ({
      activeSessionId: svcRoot.sessionId > 0 ? svcRoot.sessionId : null,
      rangeStart: svcRoot.statsRangeStart || null,
      rangeEnd: svcRoot.statsRangeEnd || null,
      statsTopicId: svcRoot.statsTopicId,
      historyNotesOnly: svcRoot.historyNotesOnly,
      historyTopicId: svcRoot.historyTopicId,
      historyDay: svcRoot.historyDayFilter
    })
    if (extra) {
      for (var k in extra) p[k] = extra[k]
    }
    return p
  }

  function enqueueRpc(cmd, payload, onDone) {
    _rpcQueue.push({ cmd: cmd, payload: payload || ({}), onDone: onDone || null })
    _pumpRpc()
  }

  function _rpcDone(parsed) {
    var finishedJob = _currentRpc
    _currentRpc = null
    _rpcBusy = false
    if (parsed && parsed.ok) {
      _applySnapshot(parsed)
      if (finishedJob && finishedJob.onDone) {
        try { finishedJob.onDone(parsed) } catch (e2) {}
      }
    } else {
      todoistSyncing = false
    }
    _pumpRpc()
  }

  property int _rpcId: 0
  Connections {
    target: Host
    function onCallFinished(id, result) {
      if (svcRoot._rpcBusy && id === svcRoot._rpcId) svcRoot._rpcDone(result)
    }
  }

  function _pumpRpc() {
    if (_rpcBusy || _rpcQueue.length === 0) return
    _rpcBusy = true
    _currentRpc = _rpcQueue.shift()
    _rpcId = Host.call(_currentRpc.cmd, _currentRpc.payload)
  }

  function _applySnapshot(res) {
    if (!res || !res.ok) return
    if (res.settings) svcRoot.settings = res.settings
    if (res.resolvedLang) svcRoot.lang = res.resolvedLang
    if (res.dbPath) svcRoot.dbPath = res.dbPath
    if (res.chimePath) svcRoot.chimePath = res.chimePath
    if (res.categories) svcRoot.categories = res.categories
    if (res.today) svcRoot.todayData = res.today
    if (res.weekly) svcRoot.weeklyData = res.weekly
    if (res.todoist) svcRoot.todoistData = res.todoist
    if (res.stats) {
      svcRoot.statsData = res.stats
      if (!svcRoot.statsRangeStart && res.stats.rangeStart) svcRoot.statsRangeStart = res.stats.rangeStart
      if (!svcRoot.statsRangeEnd && res.stats.rangeEnd) svcRoot.statsRangeEnd = res.stats.rangeEnd
    }
    if (res.history) svcRoot.historyData = res.history
  }

  // Debounced live session note writer
  Timer {
    id: noteSaveTimer
    interval: 450
    onTriggered: {
      if (svcRoot.sessionId > 0) {
        svcRoot.enqueueRpc("set-session-note", {
          sessionId: svcRoot.sessionId,
          note: svcRoot.sessionNote
        }, null)
      }
    }
  }

  // --- 500ms Wall-Clock Session & Break Engine ---
  Timer {
    id: engineTimer
    interval: 500
    repeat: true
    running: svcRoot.phase === "focus" || svcRoot.phase === "paused" || svcRoot.phase === "rest"

    onTriggered: {
      var nowMs = Date.now()

      if (svcRoot.phase === "focus") {
        var deltaSec = Math.max(0, Math.floor((nowMs - svcRoot._focusAnchorMs) / 1000))
        svcRoot.elapsedSeconds = svcRoot._accumFocusSec + deltaSec
        svcRoot.livePausedSeconds = svcRoot._accumPausedSec

        if (svcRoot.workMinutes > 0) {
          if (svcRoot.elapsedSeconds >= svcRoot.workMinutes * 60) {
            svcRoot.elapsedSeconds = svcRoot.workMinutes * 60
            svcRoot.finishSession()
          }
        } else {
          // Free mode: checkpoint to SQLite every 60s & nudge every 50m (3000s)
          var cpBucket = Math.floor(svcRoot.elapsedSeconds / 60)
          if (cpBucket > svcRoot._lastCheckpointBucket) {
            svcRoot._lastCheckpointBucket = cpBucket
            if (svcRoot.sessionId > 0) {
              svcRoot.enqueueRpc("checkpoint-session", {
                sessionId: svcRoot.sessionId,
                focusSec: svcRoot.elapsedSeconds
              }, null)
            }
          }

          var nudgeBucket = Math.floor(svcRoot.elapsedSeconds / 3000)
          if (nudgeBucket > svcRoot._lastNudgeBucket) {
            svcRoot._lastNudgeBucket = nudgeBucket
            svcRoot.breakNudgeActive = true
            svcRoot.playChime()
            screenPulse.flash()
          }
        }
      } else if (svcRoot.phase === "paused") {
        var pDelta = Math.max(0, Math.floor((nowMs - svcRoot._pauseAnchorMs) / 1000))
        svcRoot.livePausedSeconds = svcRoot._accumPausedSec + pDelta
      } else if (svcRoot.phase === "rest") {
        var rem = Math.max(0, Math.ceil((svcRoot._restEndMs - nowMs) / 1000))
        svcRoot.restRemaining = rem
        if (rem <= 0) {
          svcRoot.phase = "idle"
          svcRoot._clearActiveSessionState()
          svcRoot.openNewSession(0, "")
        }
      }
    }
  }

  // --- Folder / file / CSV pickers (QtQuick.Dialogs) ---
  function _prettyPath(url) {
    var chosen = decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
    var homeDir = Host.homeDir
    return (homeDir && chosen.indexOf(homeDir) === 0) ? ("~" + chosen.slice(homeDir.length)) : chosen
  }

  FolderDialog {
    id: weeklyFolderDialog
    title: Theme.t(svcRoot.lang, "Haftalık görev klasörünü seç", "Choose weekly tasks folder")
    onAccepted: svcRoot.patchSettings({ weeklyOn: true, weeklyTemplate: svcRoot._prettyPath(selectedFolder).replace(/\/+$/, "") + "/*{WW}*.md" })
  }

  FileDialog {
    id: weeklyFileDialog
    title: Theme.t(svcRoot.lang, "Haftalık Markdown dosyasını seç", "Choose weekly Markdown file")
    nameFilters: ["Markdown (*.md)"]
    onAccepted: svcRoot.patchSettings({ weeklyOn: true, weeklyTemplate: svcRoot._prettyPath(selectedFile) })
  }

  FileDialog {
    id: csvDialog
    title: Theme.t(svcRoot.lang, "CSV olarak dışa aktar", "Export as CSV")
    fileMode: FileDialog.SaveFile
    nameFilters: ["CSV (*.csv)"]
    selectedFile: "file://" + Host.homeDir + "/Downloads/houra.csv"
    onAccepted: svcRoot.exportCsv(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
  }

  function chooseWeeklyFolder() { weeklyFolderDialog.open() }
  function chooseWeeklyFile() { weeklyFileDialog.open() }
  function exportCsvInteractive() { csvDialog.open() }

  // --- Public Actions ---

  function refreshSnapshot() {
    enqueueRpc("snapshot", _withQueryFilters({}), null)
  }

  function openNewSession(prefillCatId, prefillGoal, prefillWeeklyKey, prefillTodoistKey, prefillTodoId) {
    if (phase === "rest") {
      phase = "idle"
      _clearActiveSessionState()
    }
    refreshSnapshot()
    newSessionWin.showModal(
      Number(prefillCatId) || 0,
      String(prefillGoal || ""),
      String(prefillWeeklyKey || ""),
      String(prefillTodoistKey || ""),
      Number(prefillTodoId) || 0
    )
  }

  function openNewSessionForTodo(todoObj) {
    if (!todoObj) return
    openNewSession(
      Number(todoObj.categoryId) || 0,
      "",
      "",
      "",
      Number(todoObj.id) || 0
    )
  }

  function openNewSessionForWeekly(wt) {
    if (!wt) return
    openNewSession(Number(wt.categoryId) || 0, "", String(wt.key || ""), "", 0)
  }

  function openNewSessionForTodoist(td) {
    if (!td) return
    openNewSession(Number(td.categoryId) || 0, "", "", String(td.key || ""), 0)
  }

  function weeklyTaskCopied(wt) {
    var t = String((wt && wt.title) || "").trim().toLowerCase()
    var list = ((todayData || {}).todos) || []
    for (var i = 0; i < list.length; i++) if (String(list[i].title || "").trim().toLowerCase() === t) return true
    return false
  }

  // Local todo only: the weekly Markdown file is never written.
  function copyWeeklyTaskToToday(wt) {
    if (!wt || weeklyTaskCopied(wt)) return
    addTodo(String(wt.title || ""), "", { categoryId: Number(wt.categoryId) || 0 })
  }

  function importTodoistTaskToToday(td) {
    if (!td) return
    enqueueRpc("add-todo", _withQueryFilters({
      title: String(td.title || ""),
      detail: String(td.detail || td.dueLabel || ""),
      todoistId: String(td.id || ""),
      priority: Number(td.priority) || 1,
      dueTime: String(td.dueTime || ""),
      categoryId: Number(td.categoryId) || 0
    }), null)
  }

  function readClipboardText(onText) {
    if (onText) {
      try { onText(String(Host.clipboardText() || "").trim()) } catch (e) {}
    }
  }

  function openTodoistDeveloperSettings() {
    Qt.openUrlExternally("https://app.todoist.com/app/settings/integrations/developer")
  }

  function saveTodoistToken(tok) {
    var clean = String(tok || "").trim()
    if (!clean) return
    todoistSyncing = true
    enqueueRpc("save-todoist-token", _withQueryFilters({ token: clean }), function() {
      svcRoot.todoistSyncing = false
    })
  }

  function clearTodoistToken() {
    enqueueRpc("clear-todoist-token", _withQueryFilters({}), null)
  }

  function syncTodoistNow(filterOpt, onFlag) {
    var extra = ({})
    if (filterOpt !== undefined && filterOpt !== null && String(filterOpt).trim() !== "") {
      extra.todoistFilter = String(filterOpt).trim()
    }
    if (onFlag !== undefined && onFlag !== null) {
      extra.todoistOn = !!onFlag
    }
    todoistSyncing = true
    enqueueRpc("sync-todoist", _withQueryFilters(extra), function() {
      svcRoot.todoistSyncing = false
    })
  }

  function setTodoistTaskCompleted(todoistId, completed, localTodoId) {
    var tdId = String(todoistId || "").trim()
    var lTid = Number(localTodoId) || 0
    if (!tdId && lTid <= 0) return
    todoistSyncing = true
    enqueueRpc("set-todoist-completed", _withQueryFilters({
      todoistId: tdId,
      completed: !!completed,
      todoId: lTid
    }), function(res) {
      svcRoot.todoistSyncing = false
      if (svcRoot.sessionId > 0 && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
    })
  }

  function createTodoistTask(taskObj, onDone) {
    var src = taskObj || ({})
    var title = String(src.title || "").trim()
    if (!title) return
    todoistSyncing = true
    var p = {
      title: title,
      detail: String(src.detail || ""),
      priority: Number(src.priority) || 1,
      scope: String(src.scope || "day"),
      day: String(src.day || ""),
      endDay: String(src.endDay || ""),
      dueTime: String(src.dueTime || ""),
      recurrence: String(src.recurrence || ""),
      categoryId: Number(src.categoryId) || 0,
      projectId: String(src.projectId || "")
    }
    enqueueRpc("create-todoist-task", _withQueryFilters(p), function(res) {
      svcRoot.todoistSyncing = false
      if (onDone) {
        try { onDone(res) } catch (e) {}
      }
    })
  }

  function updateTodoistTask(todoistId, patchObj, onDone) {
    var tdId = String(todoistId || "").trim()
    if (!tdId) return
    var src = patchObj || ({})
    var p = { todoistId: tdId }
    var keys = ["title", "detail", "description", "priority", "projectId", "scope", "day", "endDay", "dueTime", "recurrence", "clearDue"]
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i]
      if (src[k] !== undefined) p[k] = src[k]
    }
    todoistSyncing = true
    enqueueRpc("update-todoist-task", _withQueryFilters(p), function(res) {
      svcRoot.todoistSyncing = false
      if (svcRoot.sessionId > 0 && res && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
      if (onDone) {
        try { onDone(res) } catch (e) {}
      }
    })
  }

  function deleteTodoistTask(todoistId) {
    var tdId = String(todoistId || "").trim()
    if (!tdId) return
    todoistSyncing = true
    enqueueRpc("delete-todoist-task", _withQueryFilters({ todoistId: tdId }), function() {
      svcRoot.todoistSyncing = false
    })
  }

  function openMainPanel(tabName) {
    refreshSnapshot()
    mainPanelWin.showTab(tabName || "")
  }

  function toggleMainPanel() {
    if (mainPanelWin.open && mainPanelWin.isOnCurrentWorkspace()) {
      mainPanelWin.hideWindow()
    } else {
      refreshSnapshot()
      mainPanelWin.showTab("")
    }
  }

  function _focusedScreenName() {
    return Host.activeScreenName
  }

  function startNewSession(catId, goal, workMin, restMin, todoIds, extraTasks, rhythmMode, customWork, customRest) {
    var startEpoch = Date.now() / 1000.0
    var prevSid = 0
    var prevFocusSec = 0
    if ((phase === "focus" || phase === "paused") && sessionId > 0) {
      prevSid = sessionId
      if (phase === "focus") {
        var dSec = Math.max(0, Math.floor((Date.now() - _focusAnchorMs) / 1000))
        prevFocusSec = _accumFocusSec + dSec
      } else {
        prevFocusSec = _accumFocusSec
      }
      if (noteSaveTimer.running) {
        noteSaveTimer.stop()
        enqueueRpc("set-session-note", { sessionId: prevSid, note: sessionNote }, null)
      }
    }

    var rpcPayload = {
      categoryId: Number(catId),
      goal: String(goal || ""),
      workMin: Number(workMin),
      restMin: Number(restMin),
      start: startEpoch,
      todoIds: todoIds || [],
      extraTasks: extraTasks || [],
      closeSessionId: prevSid,
      closeFocusSec: prevFocusSec
    }
    if (rhythmMode) rpcPayload.rhythmMode = String(rhythmMode)
    if (customWork !== undefined && customWork !== null) rpcPayload.customWork = Number(customWork)
    if (customRest !== undefined && customRest !== null) rpcPayload.customRest = Number(customRest)

    enqueueRpc(
      "start-session",
      _withQueryFilters(rpcPayload),
      function(res) {
        var s = res.startedSession
        if (!s) return
        svcRoot.sessionId = Number(s.id)
        svcRoot.sessionCategoryId = Number(s.categoryId)
        svcRoot.sessionGoal = String(s.goal || "")
        svcRoot.workMinutes = Number(s.workMin)
        svcRoot.restMinutes = Number(s.restMin)
        svcRoot.sessionStart = Number(s.start)
        svcRoot.sessionNote = ""
        svcRoot.sessionTodos = s.todos || []
        svcRoot.elapsedSeconds = 0
        svcRoot._accumFocusSec = 0
        svcRoot._accumPausedSec = 0
        svcRoot.livePausedSeconds = 0
        svcRoot._focusAnchorMs = Date.now()
        svcRoot._lastNudgeBucket = 0
        svcRoot._lastCheckpointBucket = 0
        svcRoot.breakNudgeActive = false
        svcRoot.breakOverlayVisible = false
        svcRoot.phase = "focus"
        mainPanelWin.hideWindow()
        svcRoot._applyFocusDndIfEnabled()
      }
    )
  }

  function quickStartSession(catId, goal, workMin, restMin) {
    var rMin = restMin !== undefined ? Number(restMin) : (Number(workMin) === 25 ? 5 : 10)
    var rMode = Number(workMin) === 25 ? "25" : (Number(workMin) === 50 ? "50" : (Number(workMin) <= 0 ? "free" : "custom"))
    startNewSession(catId, goal, workMin, rMin, [], [], rMode, null, null)
  }

  function togglePause() {
    if (phase === "focus") {
      var delta = Math.max(0, Math.floor((Date.now() - _focusAnchorMs) / 1000))
      _accumFocusSec += delta
      elapsedSeconds = _accumFocusSec
      _pauseAnchorMs = Date.now()
      phase = "paused"
      _restoreDndIfManaged()
    } else if (phase === "paused") {
      var pDelta = Math.max(0, Math.floor((Date.now() - _pauseAnchorMs) / 1000))
      _accumPausedSec += pDelta
      livePausedSeconds = _accumPausedSec
      _focusAnchorMs = Date.now()
      phase = "focus"
      _applyFocusDndIfEnabled()
    }
  }

  function dismissBreakNudge() {
    breakNudgeActive = false
  }

  function _clearActiveSessionState() {
    breakNudgeActive = false
    breakOverlayVisible = false
    sessionId = 0
    sessionGoal = ""
    sessionNote = ""
    sessionTodos = []
    elapsedSeconds = 0
    _accumFocusSec = 0
    _accumPausedSec = 0
    livePausedSeconds = 0
    restRemaining = 0
  }

  function finishSession() {
    if (phase !== "focus" && phase !== "paused") return
    if (phase === "focus") {
      var delta = Math.max(0, Math.floor((Date.now() - _focusAnchorMs) / 1000))
      _accumFocusSec += delta
      elapsedSeconds = _accumFocusSec
    }
    var finishedId = sessionId
    var finalFocusSec = Math.max(0, elapsedSeconds)
    var rMin = Math.max(1, restMinutes || 5)
    breakNudgeActive = false
    _restoreDndIfManaged()

    if (noteSaveTimer.running && finishedId > 0) {
      noteSaveTimer.stop()
      enqueueRpc("set-session-note", { sessionId: finishedId, note: sessionNote }, null)
    }

    if (finishedId > 0) {
      enqueueRpc("finish-session", _withQueryFilters({
        sessionId: finishedId,
        focusSec: finalFocusSec,
        end: Date.now() / 1000.0
      }), null)
    }

    restRemaining = rMin * 60
    _restEndMs = Date.now() + restRemaining * 1000
    phase = "rest"
    breakOverlayVisible = true
  }

  function closeSessionWithoutBreak() {
    if (phase !== "focus" && phase !== "paused") return
    if (phase === "focus") {
      var delta = Math.max(0, Math.floor((Date.now() - _focusAnchorMs) / 1000))
      _accumFocusSec += delta
      elapsedSeconds = _accumFocusSec
    }
    var finishedId = sessionId
    var finalFocusSec = Math.max(0, elapsedSeconds)
    var pendingNote = sessionNote
    var hadPendingNote = noteSaveTimer.running
    if (hadPendingNote) noteSaveTimer.stop()
    _restoreDndIfManaged()

    phase = "idle"
    _clearActiveSessionState()

    if (hadPendingNote && finishedId > 0) {
      enqueueRpc("set-session-note", { sessionId: finishedId, note: pendingNote }, null)
    }

    if (finishedId > 0) {
      enqueueRpc("finish-session", _withQueryFilters({
        sessionId: finishedId,
        focusSec: finalFocusSec,
        end: Date.now() / 1000.0,
        skipBreak: true
      }), null)
    } else {
      refreshSnapshot()
    }
  }

  function cancelSession() {
    if (phase !== "focus" && phase !== "paused") return
    var cancelledId = sessionId
    if (noteSaveTimer.running) noteSaveTimer.stop()
    _restoreDndIfManaged()

    phase = "idle"
    _clearActiveSessionState()

    if (cancelledId > 0) {
      enqueueRpc("cancel-session", _withQueryFilters({ sessionId: cancelledId }), null)
    } else {
      refreshSnapshot()
    }
  }

  function deleteSession(targetSid) {
    var sid = Number(targetSid) || 0
    if (sid <= 0) return
    if (sid === sessionId && (phase === "focus" || phase === "paused")) {
      cancelSession()
      return
    }
    if (sid === sessionId && phase === "rest") {
      phase = "idle"
      _clearActiveSessionState()
    }
    enqueueRpc("delete-session", _withQueryFilters({ sessionId: sid }), null)
  }

  function updateSession(targetSid, catId, goal, note) {
    var sid = Number(targetSid) || 0
    if (sid <= 0) return
    var p = { sessionId: sid, categoryId: Number(catId) || 0, goal: String(goal || "") }
    var live = sid === sessionId && phase !== "idle"
    if (live) {
      // note of the running session is owned by the detail card's autosave
      sessionCategoryId = p.categoryId
      sessionGoal = p.goal.trim().length > 0 ? p.goal.trim() : ""
    } else if (note !== undefined) {
      p.note = String(note || "")
    }
    enqueueRpc("update-session", _withQueryFilters(p), function(res) {
      if (live && res && res.ok && sid === svcRoot.sessionId && svcRoot.sessionGoal === "") {
        var cats = res.categories || []
        for (var i = 0; i < cats.length; i++) if (Number(cats[i].id) === p.categoryId) svcRoot.sessionGoal = String(cats[i].name)
      }
    })
  }

  function emergencyExit() {
    if (phase !== "rest") return
    breakOverlayVisible = false
    if (sessionId > 0) {
      enqueueRpc("mark-emergency", _withQueryFilters({ sessionId: sessionId }), null)
    }
  }

  function returnToBreak() {
    if (phase === "rest") {
      breakOverlayVisible = true
    }
  }

  function endBreakAndStartNew() {
    phase = "idle"
    _clearActiveSessionState()
    openNewSession(0, "")
  }

  function updateSessionNote(nextNote) {
    sessionNote = String(nextNote || "")
    if (sessionId > 0) noteSaveTimer.restart()
  }

  function addTodo(title, detail, opts) {
    var extra = opts || ({})
    var p = {
      title: String(title || ""),
      detail: String(detail || "")
    }
    if (extra.priority !== undefined) p.priority = Number(extra.priority) || 1
    if (extra.scope !== undefined) p.scope = String(extra.scope || "day")
    if (extra.day !== undefined) p.day = String(extra.day || "")
    if (extra.endDay !== undefined) p.endDay = String(extra.endDay || "")
    if (extra.dueTime !== undefined) p.dueTime = String(extra.dueTime || "")
    if (extra.recurrence !== undefined) p.recurrence = String(extra.recurrence || "")
    if (extra.categoryId !== undefined) p.categoryId = Number(extra.categoryId) || 0
    if (extra.todoistId !== undefined) p.todoistId = String(extra.todoistId || "")
    enqueueRpc("add-todo", _withQueryFilters(p), null)
  }

  function updateTodo(todoId, patchObj) {
    var tid = Number(todoId) || 0
    if (tid <= 0) return
    var src = patchObj || ({})
    var p = { todoId: tid }
    var keys = ["title", "detail", "priority", "scope", "day", "endDay", "dueTime", "recurrence", "categoryId"]
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i]
      if (src[k] !== undefined) p[k] = src[k]
    }
    enqueueRpc("update-todo", _withQueryFilters(p), function(res) {
      if (svcRoot.sessionId > 0 && res && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
    })
  }

  function cycleTodoState(todoId) {
    enqueueRpc("set-todo-state", _withQueryFilters({
      todoId: Number(todoId)
    }), function(res) {
      if (svcRoot.sessionId > 0 && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
    })
  }

  function setTodoStateExplicit(todoId, nextState) {
    enqueueRpc("set-todo-state", _withQueryFilters({
      todoId: Number(todoId),
      state: Number(nextState)
    }), function(res) {
      if (svcRoot.sessionId > 0 && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
    })
  }

  function deleteTodo(todoId) {
    enqueueRpc("delete-todo", _withQueryFilters({ todoId: Number(todoId) }), function(res) {
      if (svcRoot.sessionId > 0 && Array.isArray(res.activeSessionTodos)) {
        svcRoot.sessionTodos = res.activeSessionTodos
      }
    })
  }

  function addCategory(name, color, emoji, iconName, iconColor) {
    enqueueRpc("add-category", _withQueryFilters({
      name: name,
      color: color,
      emoji: emoji,
      icon: iconName,
      iconColor: iconColor
    }), null)
  }

  function updateCategory(catId, name, color, emoji, iconName, iconColor) {
    enqueueRpc("update-category", _withQueryFilters({
      id: Number(catId),
      name: name,
      color: color,
      emoji: emoji,
      icon: iconName,
      iconColor: iconColor
    }), null)
  }

  function deleteCategory(catId) {
    enqueueRpc("delete-category", _withQueryFilters({ id: Number(catId) }), null)
  }

  function patchSettings(patchObj) {
    enqueueRpc("save-settings", _withQueryFilters({ settings: patchObj }), function() {
      if (svcRoot.phase === "focus") {
        svcRoot._applyFocusDndIfEnabled()
      }
    })
  }

  function setWidgetStyle(styleKey) {
    var allowed = ["tag", "strip", "capsule", "card", "ring", "none"]
    if (allowed.indexOf(styleKey) === -1) return
    patchSettings({ widgetStyle: styleKey })
  }

  function saveWidgetPlacement(onLeftVal, tagYVal, floatKey, fx, fy, nextScreenName) {
    var patch = { widgetLeft: !!onLeftVal, tagY: Number(tagYVal) }
    if (nextScreenName) patch.widgetScreen = String(nextScreenName)
    if (floatKey && fx >= 0 && fy >= 0) {
      var posMap = ({})
      posMap[floatKey] = [Math.round(fx), Math.round(fy)]
      patch.positions = posMap
    }
    patchSettings(patch)
  }

  function setStatsRange(startIso, endIso, topicId) {
    statsRangeStart = String(startIso || "")
    statsRangeEnd = String(endIso || "")
    statsTopicId = Number(topicId) || 0
    refreshSnapshot()
  }

  function setHistoryFilter(notesOnly, topicId, dayIso) {
    historyNotesOnly = !!notesOnly
    historyTopicId = Number(topicId) || 0
    historyDayFilter = String(dayIso || "")
    refreshSnapshot()
  }

  function openDataFolder() {
    var folder = dbPath
    var slash = folder.lastIndexOf("/")
    if (slash > 0) folder = folder.slice(0, slash)
    Qt.openUrlExternally("file://" + folder)
  }

  function exportCsv(customPath) {
    var p = customPath ? { path: String(customPath) } : {}
    enqueueRpc("export-csv", p, function(res) {
      if (res && res.csvPath) {
        svcRoot.lastCsvStatus = Theme.t(svcRoot.lang, "Dışa aktarıldı: ", "Exported: ") + res.csvPath + " (" + (res.count || 0) + ")"
      }
    })
  }

  // --- Tray menu: the old bar popout's actions as a native menu model ---
  // Entry: { key, label, enabled?, checked?, children? } or { separator: true }; Python renders it.
  function trayMenu() {
    var L = lang
    var items = []
    var sep = function() { items.push({ separator: true }) }
    var td = todayData || {}
    items.push({ key: "", enabled: false,
      label: Theme.t(L, "Bugün ", "Today ") + Theme.formatMinutes(td.focusMinutes || 0, L) + Theme.t(L, " odak", " focused")
        + " · " + (td.sessionsCount || 0) + " " + Theme.t(L, "oturum", "sessions") })
    sep()
    if (phase === "idle") {
      items.push({ key: "start", label: Theme.t(L, "Oturum başlat…", "Start session…") })
      var reps = td.recentRepeats || []
      if (reps.length > 0) {
        var kids = []
        for (var i = 0; i < reps.length; i++) {
          var r = reps[i]
          kids.push({ key: "rep:" + i, label: (r.goal ? (r.categoryName + " · " + r.goal) : r.categoryName)
            + " (" + (r.rhythmLabel || Theme.formatRhythm(r.workMin, r.restMin, L)) + ")" })
        }
        items.push({ label: Theme.t(L, "Son oturumu tekrarla", "Repeat a recent session"), children: kids })
      }
    } else if (phase === "focus" || phase === "paused") {
      items.push({ key: "", enabled: false, label: workMinutes <= 0
        ? Theme.t(L, "serbest · ", "free · ") + clockText
        : clockText + " " + Theme.t(L, "kaldı", "left") })
      var stds = sessionTodos || []
      for (var t = 0; t < stds.length; t++)
        items.push({ key: "todo:" + stds[t].id, label: Theme.todoEmoji(Number(stds[t].state)) + " " + stds[t].title })
      items.push({ key: "pause", label: phase === "paused" ? Theme.t(L, "Devam et", "Resume") : Theme.t(L, "Duraklat", "Pause") })
      items.push({ key: "finish", label: Theme.t(L, "Oturumu bitir", "Finish session") })
      items.push({ key: "closeNoBreak", label: Theme.t(L, "Molasız kapat (kaydet)", "Close & save") })
      // Submenu instead of the popout's two-step confirm: one stray click can't discard a session.
      items.push({ label: Theme.t(L, "İptal et (kaydetme)", "Cancel (no save)"),
        children: [{ key: "cancel", label: Theme.t(L, "Kaydetmeden iptal et", "Discard session") }] })
    } else if (phase === "rest") {
      items.push({ key: "", enabled: false, label: Theme.t(L, "Mola · ", "Break · ") + restClockText })
      items.push({ key: "backToBreak", label: Theme.t(L, "Molaya geri dön", "Back to break") })
      items.push({ key: "endBreakNew", label: Theme.t(L, "Molayı bitir, yeni oturum…", "End break, new session…") })
    }
    sep()
    var styles = [
      ["tag", Theme.t(L, "Etiket", "Tag")], ["strip", Theme.t(L, "İnce şerit", "Thin strip")],
      ["capsule", Theme.t(L, "Kapsül", "Capsule")], ["card", Theme.t(L, "Kart", "Card")],
      ["ring", Theme.t(L, "Halka", "Ring")], ["none", Theme.t(L, "Hiçbiri", "None")]]
    var sk = []
    for (var s = 0; s < styles.length; s++)
      sk.push({ key: "style:" + styles[s][0], label: styles[s][1], checked: widgetStyle === styles[s][0] })
    items.push({ label: Theme.t(L, "Ekranda göster", "Show on screen"), children: sk })
    sep()
    items.push({ key: "nav:", label: Theme.t(L, "Paneli aç…", "Open panel…") })
    items.push({ key: "nav:stats", label: Theme.t(L, "İstatistikler…", "Statistics…") })
    items.push({ key: "nav:settings", label: Theme.t(L, "Ayarlar…", "Settings…") })
    sep()
    items.push({ key: "quit", label: Theme.t(L, "Çık", "Quit") })
    return items
  }

  function trayAction(key) {
    key = String(key)
    if (key === "start") openNewSession(0, "")
    else if (key.indexOf("rep:") === 0) {
      var r = ((todayData || {}).recentRepeats || [])[Number(key.slice(4))]
      if (r) quickStartSession(r.categoryId, r.goal, r.workMin, r.restMin)
    } else if (key.indexOf("todo:") === 0) cycleTodoState(Number(key.slice(5)))
    else if (key === "pause") togglePause()
    else if (key === "finish") finishSession()
    else if (key === "closeNoBreak") closeSessionWithoutBreak()
    else if (key === "cancel") cancelSession()
    else if (key === "backToBreak") returnToBreak()
    else if (key === "endBreakNew") endBreakAndStartNew()
    else if (key.indexOf("style:") === 0) setWidgetStyle(key.slice(6))
    else if (key.indexOf("nav:") === 0) openMainPanel(key.slice(4))
  }

  // --- IPC / tray commands (`houra <command> [arg]`), called by Host ---
  function ipc(name, arg) {
    switch (String(name)) {
    case "newSession":
      if (newSessionWin.open && newSessionWin.isOnCurrentWorkspace()) newSessionWin.closeModal()
      else svcRoot.openNewSession(0, "")
      return "ok"
    case "panel":
    case "toggle":
      svcRoot.toggleMainPanel()
      return "ok"
    case "open":
      svcRoot.openMainPanel("")
      return "ok"
    case "stats":
      svcRoot.openMainPanel("stats")
      return "ok"
    case "tab":
      svcRoot.openMainPanel(String(arg || "today").trim().toLowerCase())
      return "ok"
    case "close":
      newSessionWin.closeModal()
      mainPanelWin.hideWindow()
      return "ok"
    case "pause":
      svcRoot.togglePause()
      return svcRoot.phase
    case "finish":
      svcRoot.finishSession()
      return svcRoot.phase
    case "closeSession":
      svcRoot.closeSessionWithoutBreak()
      return svcRoot.phase
    case "cancel":
      svcRoot.cancelSession()
      return svcRoot.phase
    case "syncTodoist":
      svcRoot.syncTodoistNow("", null)
      return "ok"
    case "style":
      svcRoot.setWidgetStyle(String(arg || "").trim().toLowerCase())
      return svcRoot.widgetStyle
    case "status":
      return JSON.stringify({
        phase: svcRoot.phase,
        clock: svcRoot.clockText,
        category: svcRoot.activeCategory ? svcRoot.activeCategory.name : "",
        goal: svcRoot.sessionGoal,
        activeTodo: svcRoot.activeTodoTitle,
        widgetStyle: svcRoot.widgetStyle,
        widgetScreen: svcRoot.settings && svcRoot.settings.widgetScreen ? String(svcRoot.settings.widgetScreen) : "",
        activeScreen: onScreenWidgetWin.resolvedScreenName
      })
    }
    return "unknown command: " + name
  }

  // Tray title/tooltip follow the timer
  readonly property string _trayTitle: phase === "idle" ? "Houra" : ("Houra " + clockText)
  on_TrayTitleChanged: Host.setTrayStatus(_trayTitle, phase === "idle" ? "Houra" : (activeCategory.name + (sessionGoal ? " · " + sessionGoal : "") + " · " + clockText), phase)
  onPhaseChanged: Host.setTrayStatus(_trayTitle, _trayTitle, phase)

  // --- Windows ---

  NewSessionWindow {
    id: newSessionWin
    service: svcRoot
    fontFamily: Style.font.family
  }

  OnScreenWidgetWindow {
    id: onScreenWidgetWin
    service: svcRoot
    fontFamily: Style.font.family
  }

  ScreenPulseOverlay {
    id: screenPulse
  }

  RestOverlayWindow {
    id: restOverlayWin
    service: svcRoot
    active: svcRoot.phase === "rest" && svcRoot.breakOverlayVisible
    fontFamily: Style.font.family
  }

  MainPanelWindow {
    id: mainPanelWin
    service: svcRoot
  }
}
