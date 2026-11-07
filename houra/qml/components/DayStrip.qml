import QtQuick
import "../Theme.js" as Theme

// Compact horizontal timeline strip (at least 08:00..20:00, widened to cover the day's sessions) used inside DetailCard (DetailView.swift:163-193):
// Renders completed sessions, live growing current session block, and live current-time cursor.
Item {
  id: root

  property var sessions: []
  property int activeSessionId: 0
  property real activeStartEpoch: 0
  property bool hasActiveSession: false
  property var tokens: ({})
  property real nowHourFrac: _computeNowFrac()
  readonly property var _range: _computeRange()
  readonly property int startHour: _range[0]
  readonly property int endHour: _range[1]

  implicitHeight: 44
  height: 44

  readonly property real spanHours: Math.max(1, endHour - startHour)

  // from = min(8, floor(earliest start or now)), to = max(20, ceil(latest end or now)),
  // span rounded up to a multiple of 4 so the 5 tick labels land on whole hours.
  function _computeRange() {
    var lo = Infinity, hi = -Infinity
    var list = sessions || []
    for (var i = 0; i < list.length; i++) {
      var s = Number(list[i].startHourFrac), e = Number(list[i].endHourFrac)
      if (isFinite(s)) lo = Math.min(lo, s)
      if (isFinite(e)) hi = Math.max(hi, e)
    }
    if (hasActiveSession && activeStartEpoch > 0) {
      lo = Math.min(lo, _epochToHourFrac(activeStartEpoch))
      hi = Math.max(hi, nowHourFrac)
    }
    if (!isFinite(lo)) lo = nowHourFrac
    if (!isFinite(hi)) hi = nowHourFrac
    var from = Math.min(8, Math.floor(lo))
    var to = Math.max(20, Math.ceil(hi))
    return [from, from + Math.ceil((to - from) / 4) * 4]
  }

  function _px(h) {
    return Math.round(((h - startHour) / spanHours) * track.width)
  }

  function _computeNowFrac() {
    var d = new Date()
    return d.getHours() + d.getMinutes() / 60.0 + d.getSeconds() / 3600.0
  }

  function _epochToHourFrac(ep) {
    if (!ep || ep <= 0) return 0
    var d = new Date(Number(ep) * 1000)
    return d.getHours() + d.getMinutes() / 60.0 + d.getSeconds() / 3600.0
  }

  Timer {
    interval: 15000
    running: root.visible
    repeat: true
    onTriggered: root.nowHourFrac = root._computeNowFrac()
  }

  onVisibleChanged: {
    if (visible) nowHourFrac = _computeNowFrac()
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 26
    radius: 7
    color: Theme.withAlpha(root.tokens.ink || "#ffffff", 0.05)
    clip: true

    // Completed sessions today
    Repeater {
      model: root.sessions ? root.sessions.length : 0
      delegate: Rectangle {
        readonly property var sess: root.sessions[index]
        readonly property bool isCompletedOther: !!sess.completed && Number(sess.id) !== root.activeSessionId
        readonly property real sH: Math.max(root.startHour, Math.min(root.endHour, Number(sess.startHourFrac) || 0))
        readonly property real eH: Math.max(sH, Math.min(root.endHour, Number(sess.endHourFrac) || 0))
        visible: isCompletedOther && eH > root.startHour && sH < root.endHour
        x: root._px(sH)
        y: 5
        width: Math.max(2, root._px(eH) - x - 1)
        height: 16
        radius: 4
        color: Theme.withAlpha(root.tokens.ink || "#ffffff", 0.45)
      }
    }

    // Live active session block (start -> now)
    Rectangle {
      readonly property real liveStartH: Math.max(root.startHour, Math.min(root.endHour, root._epochToHourFrac(root.activeStartEpoch)))
      readonly property real liveEndH: Math.max(liveStartH, Math.min(root.endHour, root.nowHourFrac))
      visible: root.hasActiveSession && root.nowHourFrac > root.startHour && liveStartH < root.endHour
      x: root._px(liveStartH)
      y: 5
      width: Math.max(2, root._px(liveEndH) - x - 1)
      height: 16
      radius: 4
      color: Theme.withAlpha(root.tokens.primaryBg || "#ffffff", 0.90)
    }

    // Current-time marker
    Rectangle {
      visible: root.nowHourFrac >= root.startHour && root.nowHourFrac <= root.endHour
      x: root._px(root.nowHourFrac)
      y: 0
      width: 1.5
      height: track.height
      color: root.tokens.ink || "#ffffff"
    }
  }

  Item {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 13

    Repeater {
      model: 5
      delegate: Text {
        textFormat: Text.PlainText
        readonly property int hr: root.startHour + index * root.spanHours / 4
        readonly property int label: ((hr % 24) + 24) % 24
        x: index === 0 ? 0 : (index === 4 ? parent.width - implicitWidth : Math.round(index / 4 * parent.width - implicitWidth / 2))
        text: (label < 10 ? "0" + label : String(label))
        font.family: "Monospace"
        font.pixelSize: 10
        color: root.tokens.faint || "#666666"
      }
    }
  }
}
