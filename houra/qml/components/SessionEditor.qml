import QtQuick
import "../Theme.js" as Theme

// Inline editor for a recorded session: category, goal, note.
Column {
  id: root

  property var service: null
  property var session: null
  property var tokens: ({})
  property string lang: "en"
  property string fontFamily: "Sans Serif"
  // running (or resting) session: its note lives in the detail card
  readonly property bool live: !!(service && session && Number(session.id) === service.sessionId && service.phase !== "idle")
  readonly property var categories: service ? service.categories : []
  property int catId: 0
  property int kbStop: 0 // 0 chips, 1 goal, 2 note, 3 cancel, 4 save

  signal closed()

  readonly property bool isEditingText: goalInput.activeFocus || noteInput.activeFocus

  spacing: 8

  Component.onCompleted: reset()
  // snapshot refreshes hand in a new object for the same row; keep the draft
  onSessionChanged: if (session && Number(session.id) !== _sid) reset()
  property int _sid: 0

  function reset() {
    if (!session) return
    _sid = Number(session.id)
    catId = Number(session.categoryId) || 0
    goalInput.text = session.goal && session.goal !== session.categoryName ? session.goal : ""
    noteInput.text = session.note || ""
    kbStop = 0
  }

  function releaseTextFocus() {
    if (!isEditingText) return false
    goalInput.focus = false
    noteInput.focus = false
    return true
  }

  function cycleCategory(delta) {
    if (categories.length === 0) return
    var idx = 0
    for (var i = 0; i < categories.length; i++) if (Number(categories[i].id) === catId) idx = i
    catId = Number(categories[(idx + delta + categories.length) % categories.length].id)
  }

  function _stops() { return live ? [0, 1, 3, 4] : [0, 1, 2, 3, 4] }

  function tabStep(delta) {
    var st = _stops()
    var i = st.indexOf(kbStop)
    kbStop = st[(i + delta + st.length) % st.length]
    releaseTextFocus()
    if (kbStop === 1) goalInput.forceActiveFocus()
    else if (kbStop === 2) noteInput.forceActiveFocus()
  }

  // Keys while no text field has focus; returns true when handled
  function handleKey(event) {
    var k = event.key
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
      tabStep((k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)) ? -1 : 1)
      return true
    }
    if (kbStop === 0 && (k === Qt.Key_Left || k === Qt.Key_Right)) { cycleCategory(k === Qt.Key_Left ? -1 : 1); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
      if (kbStop === 3) closed()
      else save()
      return true
    }
    return true // swallow list navigation while the editor is open
  }

  function save() {
    if (!service || !session || catId <= 0) return
    service.updateSession(Number(session.id), catId, goalInput.text, live ? undefined : noteInput.text)
    closed()
  }

  Flow {
    width: parent.width
    spacing: 6

    Repeater {
      model: root.categories.length
      delegate: Rectangle {
        readonly property var cat: root.categories[index]
        readonly property bool picked: Number(cat.id) === root.catId
        width: chipRow.implicitWidth + 16
        height: 26
        radius: 13
        color: picked ? Theme.withAlpha(cat.color || "#4c8df0", 0.28) : (root.tokens.card2 || "#1f1f25")
        border.width: picked && root.kbStop === 0 ? 2 : 1
        border.color: picked ? (cat.color || "#4c8df0") : (root.tokens.line || Qt.rgba(1, 1, 1, 0.10))

        Row {
          id: chipRow
          anchors.centerIn: parent
          spacing: 6
          CategorySwatch {
            anchors.verticalCenter: parent.verticalCenter
            swatchSize: 16
            swatchColor: cat.color || "#4c8df0"
            emoji: cat.emoji || ""
            iconName: cat.icon || ""
            iconColor: cat.iconColor || ""
          }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: cat.name
            font.family: root.fontFamily
            font.pixelSize: 11
            color: root.tokens.ink || "#ffffff"
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.catId = Number(cat.id); root.kbStop = 0 }
        }
      }
    }
  }

  Rectangle {
    width: parent.width
    height: 30
    radius: 7
    color: root.tokens.card2 || "#1e1e24"
    border.width: 1
    border.color: goalInput.activeFocus ? (root.tokens.accent || Qt.rgba(1, 1, 1, 0.30)) : (root.tokens.line || Qt.rgba(1, 1, 1, 0.08))

    TextInput {
      selectionColor: root.tokens.primaryBg || "#4c8df0"
      selectedTextColor: root.tokens.primaryInk || "#ffffff"
      id: goalInput
      anchors.fill: parent
      anchors.leftMargin: 10
      anchors.rightMargin: 10
      verticalAlignment: TextInput.AlignVCenter
      font.family: root.fontFamily
      font.pixelSize: 12
      color: root.tokens.ink || "#ffffff"
      selectByMouse: true
      clip: true
      onActiveFocusChanged: if (activeFocus) root.kbStop = 1
      onAccepted: root.save()
      Keys.onTabPressed: root.tabStep(1)
      Keys.onBacktabPressed: root.tabStep(-1)
    }

    Text {
      textFormat: Text.PlainText
      visible: goalInput.text.length === 0
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: 10
      text: Theme.t(root.lang, "Hedef (boşsa kategori adı)", "Goal (empty = category name)")
      font.family: root.fontFamily
      font.pixelSize: 12
      color: root.tokens.muted || "#8a8d96"
    }
  }

  Rectangle {
    visible: !root.live
    width: parent.width
    height: Math.max(56, noteInput.contentHeight + 16)
    radius: 7
    color: root.tokens.card2 || "#1e1e24"
    border.width: 1
    border.color: noteInput.activeFocus ? (root.tokens.accent || Qt.rgba(1, 1, 1, 0.30)) : (root.tokens.line || Qt.rgba(1, 1, 1, 0.08))

    TextEdit {
      id: noteInput
      textFormat: TextEdit.PlainText
      selectionColor: root.tokens.primaryBg || "#4c8df0"
      selectedTextColor: root.tokens.primaryInk || "#ffffff"
      anchors.fill: parent
      anchors.margins: 8
      wrapMode: TextEdit.Wrap
      font.family: root.fontFamily
      font.pixelSize: 12
      color: root.tokens.ink || "#ffffff"
      selectByMouse: true
      onActiveFocusChanged: if (activeFocus) root.kbStop = 2
      Keys.onTabPressed: root.tabStep(1)
      Keys.onBacktabPressed: root.tabStep(-1)
    }

    Text {
      textFormat: Text.PlainText
      visible: noteInput.text.length === 0
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: 8
      text: Theme.t(root.lang, "Not", "Note")
      font.family: root.fontFamily
      font.pixelSize: 12
      color: root.tokens.muted || "#8a8d96"
    }
  }

  Row {
    anchors.right: parent.right
    spacing: 8

    Repeater {
      model: 2
      delegate: Rectangle {
        readonly property bool isSave: index === 1
        readonly property bool kbOn: root.kbStop === (isSave ? 4 : 3)
        width: btnLbl.implicitWidth + 20
        height: 26
        radius: 7
        color: isSave ? (root.tokens.primaryBg || "#ffffff") : (root.tokens.card2 || "#1f1f25")
        border.width: 1
        border.color: root.tokens.line || Qt.rgba(1, 1, 1, 0.10)

        // Focus ring outside the button: on the filled Save button an inner accent border is invisible.
        Rectangle {
          visible: kbOn
          anchors.fill: parent
          anchors.margins: -3
          radius: parent.radius + 3
          color: "transparent"
          border.width: 2
          border.color: root.tokens.accent || "#4c8df0"
        }

        Text {
          id: btnLbl
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: isSave ? Theme.t(root.lang, "Kaydet", "Save") : Theme.t(root.lang, "Vazgeç", "Cancel")
          font.family: root.fontFamily
          font.pixelSize: 11
          font.weight: isSave ? Font.DemiBold : Font.Normal
          color: isSave ? (root.tokens.primaryInk || "#000000") : (root.tokens.secondary || "#cccccc")
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: isSave ? root.save() : root.closed()
        }
      }
    }
  }
}
