import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "lib/Rules.js" as Rules

// The whole of Roost's interface: what it would remember about the window you
// were just in, and everything it already remembers.
//
// One surface rather than two. A separate "capture" dialog would have to ask
// the same question the rule list already answers — what does this app do when
// it opens — and would put the answer somewhere the user is not looking. The
// list is therefore always on screen, including when it is empty: a panel that
// hid it until the first rule existed read as a one-shot dialog with no memory,
// which is the opposite of what Roost is.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var service: null

  readonly property string moduleName: "eduardodallecort.roost"

  property bool opened: false

  // ------------------------------------------------------------------ theme
  //
  // Nothing here encodes a reading in colour: a chip is on or off, a rule is
  // active or not, and both of those are states rather than measurements. So
  // every colour is the theme's. The tokens are [menu]'s, which is the surface
  // role Omarchy's own summoned overlays use, so a theme that restyles the
  // emoji picker restyles this too.
  readonly property color surface: Color.menu.background
  readonly property color ink: Color.menu.text
  readonly property color scrimColor: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property color muted: Qt.rgba(ink.r, ink.g, ink.b, 0.64)
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.34)

  // A panel inset into the card, for grouping. Derived from the theme's own
  // ink so it lands on the right side of the background in light themes and
  // dark ones alike, rather than being a grey that only works in one.
  readonly property color inset: Qt.rgba(ink.r, ink.g, ink.b, 0.055)
  readonly property color insetLine: Qt.rgba(ink.r, ink.g, ink.b, 0.11)

  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  readonly property int contentWidth: Style.space(470)

  // Glyphs, resolved from the Nerd Fonts registry by name rather than
  // remembered: the ranges were renumbered between major versions and the font
  // has *a* glyph at every codepoint either way. fromCodePoint because \u
  // escapes consume exactly four hex digits.
  readonly property string glyphApp: String.fromCodePoint(0xF10AC)      // md-dock_window
  readonly property string glyphOn: String.fromCodePoint(0xF0133)       // md-checkbox_marked_circle
  readonly property string glyphOff: String.fromCodePoint(0xF0130)      // md-checkbox_blank_circle_outline
  readonly property string glyphForget: String.fromCodePoint(0xF0156)   // md-close
  readonly property string glyphUndo: String.fromCodePoint(0xF054C)     // md-undo
  readonly property string glyphPrev: String.fromCodePoint(0xF0141)     // md-chevron_left
  readonly property string glyphNext: String.fromCodePoint(0xF0142)     // md-chevron_right

  // ------------------------------------------------------------------ state

  // Which aspects of the captured window the next rule will carry. Rebuilt
  // from the window every time one is captured, so the panel opens showing a
  // sensible proposal rather than whatever was left selected last time.
  property var selection: ({})
  property string matchMode: Rules.MATCH_APP
  property bool silentWorkspace: false

  // Cursor in the rule list. -1 means the cursor is on the capture card,
  // which is where every keystroke starts.
  property int cursor: -1

  // Cleared on the next capture; this is the one-line receipt after a save.
  property string notice: ""

  // The last rule forgotten, kept only so it can be put back. Forgetting is
  // one keystroke and takes effect immediately, which is exactly the shape of
  // action that needs a way back.
  property var undoRule: null
  property int undoIndex: -1

  readonly property var win: service ? service.window : null
  readonly property int windowCount: service && Array.isArray(service.windows) ? service.windows.length : 0
  readonly property int windowNumber: service ? service.windowIndex + 1 : 0
  readonly property bool hasWindow: !!win && win.matchable === true
  readonly property var rules: service && Array.isArray(service.rules) ? service.rules : []
  readonly property bool rulesActive: !service || service.active !== false

  // The rule store could not be read, so an empty list means "unknown", not
  // "none". Everything that would otherwise report emptiness has to say so.
  readonly property bool rulesUnreadable: !!service && service.storeUnreadable === true

  // Index of the rule this window already has, or -1. Computed from `rules`
  // rather than by asking the service, so that saving a rule re-evaluates it:
  // a binding that called a service *method* would depend on the service and
  // the match mode but not on the list, and the button would still offer to
  // add a rule that now exists.
  readonly property int replacingIndex: root.hasWindow
    ? Rules.findRuleFor(root.rules, root.win, root.matchMode) : -1

  // ------------------------------------------------------------- open/close

  function open(payloadJson) {
    root.notice = ""
    root.undoRule = null
    root.undoIndex = -1
    root.cursor = -1
    // Clear the last transient failure — "Could not reach Hyprland…" from an
    // earlier session should not sit on every panel from then on. A standing
    // condition is not cleared here: a store that could not be read is still
    // unread when the panel opens again, and erasing the reason for it is how
    // this panel came to greet someone with three saved rules by telling them
    // they had none.
    if (root.service && !root.service.storeUnreadable) root.service.error = ""
    root.opened = true
    if (service) service.capture()
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  // Leaving by Escape or by clicking away has to go through the shell, or the
  // panel hides while the shell still believes it is open and the next toggle
  // does nothing.
  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.moduleName)
    else root.close()
  }

  // Rebuild the proposal whenever a fresh window arrives.
  Connections {
    target: root.service
    enabled: !!root.service

    function onCaptureFinished() {
      root.selection = root.win ? Rules.defaultSelection(root.win) : ({})
      root.silentWorkspace = false
      root.matchMode = Rules.MATCH_APP
    }

    function onRuleSaved(name) {
      root.notice = qsTr("Remembered. %1 opens this way from now on.").arg(name)
      root.undoRule = null
      root.undoIndex = -1
    }
  }

  // ------------------------------------------------------------------ chips
  //
  // The chips are the rule, written out as a sentence: turning one off is how
  // you say "remember the size but not where it sat". Building them here
  // rather than in the layout keeps the order of the sentence and the order of
  // the generated rule the same thing.
  function chipModel() {
    if (!root.hasWindow) return []
    var w = root.win
    var chips = []
    var available = Rules.availableAspects(w)

    if (available.indexOf(Rules.ASPECT_TILING) !== -1)
      chips.push({
        key: Rules.ASPECT_TILING,
        label: w.floating ? qsTr("floating") : qsTr("tiled"),
        hint: w.floating ? qsTr("Opens outside the tiling layout.")
                         : qsTr("Forces it into the tiling layout, even if it would float.")
      })

    if (available.indexOf(Rules.ASPECT_SIZE) !== -1 && w.width > 0 && w.height > 0)
      chips.push({
        key: Rules.ASPECT_SIZE,
        label: w.width + "×" + w.height,
        hint: qsTr("Opens at exactly this size.")
      })

    if (available.indexOf(Rules.ASPECT_POSITION) !== -1)
      chips.push({
        key: Rules.ASPECT_POSITION,
        label: Rules.isCentred(w) ? qsTr("centred") : qsTr("at %1, %2").arg(w.x).arg(w.y),
        hint: Rules.isCentred(w)
          ? qsTr("Centred on whichever monitor it opens on.")
          : qsTr("Opens at this spot, measured from the corner of its monitor.")
      })

    if (available.indexOf(Rules.ASPECT_WORKSPACE) !== -1 && w.workspace)
      chips.push({
        key: Rules.ASPECT_WORKSPACE,
        label: qsTr("workspace %1").arg(w.workspace.name),
        hint: qsTr("Always opens on this workspace.")
      })

    return chips
  }

  function chipSelected(key) { return root.selection[key] === true }

  function toggleChip(key) {
    var next = {}
    for (var k in root.selection) next[k] = root.selection[k]
    next[key] = !next[key]
    // Geometry and floating move together — see Rules.coerceSelection. Doing
    // it here means the floating chip visibly lights up when you pick a size,
    // rather than the rule quietly growing a term at write time.
    root.selection = Rules.coerceSelection(next, key)
    root.notice = ""
  }

  function toggleChipAt(index) {
    var chips = root.chipModel()
    if (index < 0 || index >= chips.length) return
    root.toggleChip(chips[index].key)
  }

  function anythingSelected() {
    var chips = root.chipModel()
    for (var i = 0; i < chips.length; i++) if (root.chipSelected(chips[i].key)) return true
    return false
  }

  // ----------------------------------------------------------------- actions

  function remember() {
    if (!root.service || !root.hasWindow || !root.anythingSelected()) return
    root.notice = ""
    root.service.remember(root.selection, {
      matchMode: root.matchMode,
      silent: root.silentWorkspace && root.chipSelected(Rules.ASPECT_WORKSPACE)
    })
  }

  // A panel's functions are a public surface: the shell will invoke any of
  // them by name over IPC (`omarchy-shell shell call <id> <method> <arg>`),
  // and IPC arguments are always strings. Coercing rather than trusting the
  // key handler's integer keeps `moveCursor "1"` from computing "-1" + "1".
  function moveCursor(delta) {
    var count = root.rules.length
    if (count === 0) { root.cursor = -1; return }
    var step = parseInt(delta, 10)
    if (!isFinite(step)) return
    var next = root.cursor + step
    if (next < -1) next = -1
    if (next >= count) next = count - 1
    root.cursor = next
  }

  // Like moveCursor, these take an index over IPC as well as from the key
  // handler, and IPC arguments are always strings. Parsing once here means
  // neither the service nor the rule store ever sees "0" where it expects 0.
  function forgetAt(index) {
    var at = parseInt(index, 10)
    if (!isFinite(at) || at < 0 || at >= root.rules.length || !root.service) return
    // The receipt and the undo are recorded only once the delete has actually
    // been written. A persist can refuse — the state directory is not ready, or
    // a previous reload is still in flight — and announcing "Forgot Signal."
    // beside a Signal that is still listed, with an Undo for something that
    // never happened, is worse than the refusal it is hiding.
    var rule = root.rules[at]
    if (!root.service.forget(at)) return
    root.undoRule = rule
    root.undoIndex = at
    root.notice = qsTr("Forgot %1.").arg(rule.name)
    if (root.cursor >= root.rules.length) root.cursor = root.rules.length - 1
  }

  function forgetSelected() { root.forgetAt(root.cursor) }

  function undoForget() {
    if (!root.undoRule || !root.service) return
    var rule = root.undoRule
    if (!root.service.restore(rule, root.undoIndex)) return
    root.undoRule = null
    root.undoIndex = -1
    root.notice = qsTr("%1 is back.").arg(rule.name)
  }

  // Point the panel at another open window. The rule being composed belongs to
  // whichever window is shown, so the proposal is rebuilt from scratch: keeping
  // the previous selection would silently carry "floating, 900×700" from the
  // window you were looking at onto the one you moved to.
  function stepWindow(delta) {
    if (!root.service || root.windowCount < 2) return
    root.service.stepWindow(delta)
    root.selection = root.win ? Rules.defaultSelection(root.win) : ({})
    root.silentWorkspace = false
    root.matchMode = Rules.MATCH_APP
    root.notice = ""
  }

  function toggleAt(index) {
    var at = parseInt(index, 10)
    if (!isFinite(at) || at < 0 || at >= root.rules.length || !root.service) return
    root.service.setRuleEnabled(at, root.rules[at].enabled === false)
    root.notice = ""
  }

  function toggleSelected() { root.toggleAt(root.cursor) }

  // ------------------------------------------------------------------ window

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "roost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimColor
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card

      anchors.centerIn: parent

      // BorderSurface exposes its padding rather than applying it, so the
      // content takes it through the insets and the card is sized from the
      // same numbers. Deriving the height from the column's implicit height
      // is what keeps a card with no rules and a card with ten both correct.
      width: root.contentWidth + card.contentLeftInset + card.contentRightInset
      height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
      radius: Style.cornerRadius
      color: root.surface
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // The scrim's dismiss handler covers the whole screen underneath this
      // card and BorderSurface takes no mouse events of its own, so without
      // this every press that lands on padding or a heading closes the panel.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keys

        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          // A held key repeats at the OS rate. Nothing here wants that: a held
          // Enter would try to save the same rule several times a second, and
          // each attempt reloads Hyprland.
          if (event.isAutoRepeat) {
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) {
            root.dismiss(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.remember(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Right || event.key === Qt.Key_L
              || event.key === Qt.Key_Tab) {
            root.stepWindow(1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Left || event.key === Qt.Key_H
              || event.key === Qt.Key_Backtab) {
            root.stepWindow(-1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.moveCursor(1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.moveCursor(-1); event.accepted = true; return
          }
          if (event.key === Qt.Key_X || event.key === Qt.Key_Delete) {
            root.forgetSelected(); event.accepted = true; return
          }
          if (event.key === Qt.Key_U) {
            root.undoForget(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Space) {
            root.toggleSelected(); event.accepted = true; return
          }
          // Digits pick a chip off the sentence without reaching for the
          // mouse. The chips are numbered in the interface, so this is a
          // shortcut for something visible rather than a hidden command.
          if (event.text >= "1" && event.text <= "9") {
            root.toggleChipAt(parseInt(event.text, 10) - 1)
            event.accepted = true
            return
          }
        }

        Column {
          id: content

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: card.contentTopInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset
          spacing: Style.spacing.panelGap

          // ------------------------------------------------------ the window
          //
          // The app is the subject of everything below it, so it is the one
          // thing set at display size. Everything else on the card is a
          // caption, a control, or a list.
          Row {
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              id: appGlyph

              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphApp
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              color: root.hasWindow ? root.accent : root.faint
            }

            Column {
              // Measured off the glyph and the stepper rather than guessed
              // from a point size: a Nerd Font glyph's advance is not its
              // pixelSize, and the difference is a heading that wraps a word
              // early.
              width: parent.width - parent.spacing * 2 - appGlyph.width - stepper.width
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                width: parent.width
                text: {
                  if (!root.service || !root.service.loaded) return qsTr("Reading your rules…")
                  if (root.service.capturing) return qsTr("Looking at the desktop…")
                  if (!root.win) return qsTr("No window on screen")
                  if (!root.win.matchable) return qsTr("This window has no class")
                  return root.win["class"]
                }
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
                color: root.hasWindow ? root.ink : root.muted
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                visible: text !== ""
                text: {
                  if (!root.service || !root.service.loaded || root.service.capturing) return ""
                  if (!root.win)
                    return qsTr("Nothing on screen to place. Roost offers the windows you can see; switch to the one you want and open it again.")
                  if (!root.win.matchable)
                    return qsTr("Hyprland reports no class for it, and a rule with nothing to match on would reshape every window.")
                  var where = root.win.floating ? qsTr("Floating") : qsTr("Tiled")
                  if (root.win.workspace) where += qsTr(" on workspace %1").arg(root.win.workspace.name)
                  if (root.win.monitor) where += " · " + root.win.monitor
                  return where
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.muted
              }
            }

            // Which window this is about.
            //
            // Opening Roost from the bar lands on the window you were last in,
            // which is right almost always and useless the one time it is not:
            // with a dozen windows open, having to go and focus the right one
            // first makes the bar icon the slow way round. The list is ordered
            // by how recently each window was focused, so the one you want is
            // usually a step or two away rather than buried.
            Row {
              id: stepper

              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs
              visible: root.windowCount > 1

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyphPrev
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: prevMouse.containsMouse ? root.accent : root.muted

                MouseArea {
                  id: prevMouse
                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.stepWindow(-1)
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.windowNumber + "/" + root.windowCount
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.muted
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyphNext
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: nextMouse.containsMouse ? root.accent : root.muted

                MouseArea {
                  id: nextMouse
                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.stepWindow(1)
                }
              }
            }
          }

          // ---------------------------------------------------- the sentence
          //
          // Grouped into an inset panel so the chips read as one object — the
          // rule — rather than as four loose buttons.
          BorderSurface {
            id: sentence

            width: parent.width
            visible: root.hasWindow
            height: sentenceBody.implicitHeight + sentence.contentTopInset + sentence.contentBottomInset
            radius: Style.cornerRadius
            color: root.inset
            padding: Style.spacing.rowPaddingX
            borderSpec: Border.flat(root.insetLine, Math.max(1, Style.space(1)))

            Column {
              id: sentenceBody

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: sentence.contentTopInset
              anchors.leftMargin: sentence.contentLeftInset
              anchors.rightMargin: sentence.contentRightInset
              spacing: Style.spacing.md

              PanelSectionHeader {
                foreground: root.ink
                text: root.replacingIndex >= 0 ? qsTr("REPLACE ITS RULE WITH") : qsTr("REMEMBER THAT IT OPENS")
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.chipModel()

                  delegate: Button {
                    required property var modelData
                    required property int index

                    text: (index + 1) + "  " + modelData.label
                    iconText: root.chipSelected(modelData.key) ? root.glyphOn : root.glyphOff
                    iconSize: Style.font.bodySmall
                    tooltipText: modelData.hint
                    selected: root.chipSelected(modelData.key)
                    bordered: true
                    // The unselected state is deliberately quieter than the
                    // kit's default: which chips are on is the single most
                    // important thing to read on this panel, and a difference
                    // in fill alone was not carrying it.
                    foreground: root.chipSelected(modelData.key) ? root.ink : root.faint
                    accent: root.accent
                    background: "transparent"
                    fontSize: Style.font.bodySmall
                    onClicked: root.toggleChip(modelData.key)
                  }
                }

                // Follows the workspace chip and only exists while it is on,
                // because "without switching" is a qualifier on the workspace
                // and means nothing without it.
                Button {
                  visible: root.chipSelected(Rules.ASPECT_WORKSPACE)
                  text: qsTr("without switching to it")
                  iconText: root.silentWorkspace ? root.glyphOn : root.glyphOff
                  iconSize: Style.font.bodySmall
                  tooltipText: qsTr("The window opens there and you stay where you are.")
                  selected: root.silentWorkspace
                  bordered: true
                  foreground: root.silentWorkspace ? root.ink : root.faint
                  accent: root.accent
                  background: "transparent"
                  fontSize: Style.font.bodySmall
                  onClicked: { root.silentWorkspace = !root.silentWorkspace; root.notice = "" }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.anythingSelected()
                  ? qsTr("Filled chips get remembered. Click one, or press its number, to drop it.")
                  : qsTr("Nothing selected — there is nothing to remember.")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.anythingSelected() ? root.faint : root.accent
              }
            }
          }

          // ------------------------------------------------------- matching
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.hasWindow

            PanelSectionHeader {
              foreground: root.ink
              text: qsTr("AND THAT THE RULE COVERS")
            }

            ButtonGroup {
              // The class is shortened for the label because a ButtonGroup
              // chip has no elide: its text sits in a centred Row that grows,
              // so a 40-character Chromium web-app class pushes the control
              // clean off the card. The full class is spelled out underneath.
              options: [
                { value: Rules.MATCH_APP, label: qsTr("Every %1 window").arg(Rules.shortClass(root.win ? root.win["class"] : "", 22)) },
                { value: Rules.MATCH_WINDOW, label: qsTr("Only this one") }
              ]
              value: root.matchMode
              foreground: root.ink
              accent: root.accent
              background: root.surface
              fontSize: Style.font.bodySmall
              focusable: false
              onChanged: function (value) { root.matchMode = value; root.notice = "" }
            }

            // Always shown, and wrapping rather than elided: this is the only
            // place the class is written out in full, and a rule you cannot
            // read is a rule you cannot check. The title warning is stated
            // where the choice is made rather than in the README, because a
            // rule matched on a title the app rewrites after it opens is the
            // one failure mode of this plugin that looks like Roost simply not
            // working.
            Text {
              width: parent.width
              wrapMode: Text.WrapAnywhere
              visible: root.hasWindow
              text: {
                if (!root.win) return ""
                if (root.matchMode === Rules.MATCH_WINDOW)
                  return qsTr("Matches class %1 and title “%2”. Apps that rename their window after opening — editors, browsers, terminals — will stop matching.")
                    .arg(root.win["class"]).arg(root.win.title)
                return qsTr("Matches class %1.").arg(root.win["class"])
              }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.muted
            }
          }

          // --------------------------------------------------------- action
          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              width: parent.width
              visible: root.hasWindow
              enabled: !root.rulesUnreadable
              opacity: enabled ? 1 : 0.5
              text: root.rulesUnreadable
                ? qsTr("Cannot save while the rule store is unreadable")
                : (root.replacingIndex >= 0 ? qsTr("Replace rule   ⏎") : qsTr("Remember this window   ⏎"))
              bordered: true
              selected: root.anythingSelected()
              foreground: root.anythingSelected() ? root.ink : root.faint
              accent: root.accent
              verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xs
              onClicked: root.remember()
            }

            // ---------------------------------------------------- receipt
            //
            // One caption line, reserved whether or not there is anything to
            // say.
            //
            // This line appears on its own schedule — "Applying…" while
            // Hyprland reloads, then a result — and a row that joined and left
            // the layout resized the whole card under the pointer, twice, for
            // a message lasting a fraction of a second. That reads as the
            // panel breaking, not as feedback.
            //
            // Undo is a word rather than a button for the same reason: a
            // control is taller than a line of caption text, so it would have
            // set the height of the row and reintroduced the jump the moment
            // it appeared. It earns its discoverability from the accent colour
            // and the cursor instead.
            Item {
              id: receiptRow

              width: parent.width
              height: Math.ceil(Style.font.caption * 1.6)

              Text {
                id: receipt

                anchors.left: parent.left
                anchors.right: undoLink.visible ? undoLink.left : parent.right
                anchors.rightMargin: undoLink.visible ? Style.spacing.md : 0
                anchors.verticalCenter: parent.verticalCenter
                // Bounded rather than free: an unbounded error message would
                // grow the row it was just made immune to growing.
                elide: Text.ElideRight
                text: {
                  if (root.service && root.service.error) return root.service.error
                  if (root.service && root.service.applying) return qsTr("Applying…")
                  return root.notice
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.service && root.service.error ? root.accent : root.muted

                opacity: text === "" ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
              }

              Text {
                id: undoLink

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !!root.undoRule
                text: root.glyphUndo + " " + qsTr("Undo")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.underline: undoMouse.containsMouse
                color: root.accent

                MouseArea {
                  id: undoMouse

                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.undoForget()
                }
              }
            }
          }

          // ----------------------------------------------------- the rules
          PanelSeparator { width: parent.width; foreground: root.ink }

          Item {
            width: parent.width
            height: Math.max(remembered.implicitHeight, masterRow.implicitHeight)

            PanelSectionHeader {
              id: remembered

              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.ink
              text: {
                if (root.rulesUnreadable) return qsTr("REMEMBERED · UNKNOWN")
                if (root.rules.length === 0) return qsTr("REMEMBERED · NONE YET")
                return qsTr("REMEMBERED · %1").arg(root.rules.length)
              }
            }

            Row {
              id: masterRow

              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md
              visible: root.rules.length > 0

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.rulesActive ? qsTr("all on") : qsTr("all off")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.rulesActive ? root.muted : root.accent
              }

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.rulesActive
                foreground: root.ink
                accent: root.accent
                // ToggleSwitch reports that it was toggled, not what to; the
                // new value is the opposite of what it is showing.
                onToggled: if (root.service) root.service.setActive(!root.rulesActive)
              }
            }
          }

          // The empty state is the only thing on the panel that explains what
          // Roost is for, so it is worth its space: a first-time user arrives
          // with no rules and this is the paragraph they read.
          Text {
            width: parent.width
            visible: root.rules.length === 0
            wrapMode: Text.WordWrap
            text: root.rulesUnreadable
              ? qsTr("Roost could not read your rule store, so it does not know what is in it. Nothing has been lost and nothing will be written over it — the file is still on disk, unchanged.")
              : qsTr("Nothing placed yet. Arrange a window the way you want it, press Enter, and it appears here — with a switch to turn it off and a way to forget it.")
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.rulesUnreadable ? root.accent : root.faint
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.rules.length > 0

          ListView {
            id: ruleList

            width: parent.width - scrollTrack.width - parent.spacing
            // The list is bounded so the card cannot grow past the screen on a
            // machine with fifty rules, and the bound is measured rather than
            // fixed: five rows keeps the card compact on a desktop, and a
            // 768-pixel laptop takes fewer still. Everything else on the card
            // is roughly constant, so what is left over for the list is the
            // panel's height minus that.
            readonly property int rowHeight: Style.space(40)
            readonly property int maxRows: {
              var spare = panel.height - Style.space(360)
              var fits = Math.floor(spare / Math.max(1, rowHeight))
              return Math.max(3, Math.min(5, fits))
            }
            height: Math.min(root.rules.length, maxRows) * rowHeight
            visible: root.rules.length > 0
            clip: true
            interactive: root.rules.length > maxRows
            currentIndex: root.cursor
            model: root.rules

            // Setting currentIndex does not scroll the view on its own, so
            // past the tenth rule the keyboard cursor would move somewhere the
            // user cannot see. Contain rather than Center: rows already on
            // screen stay where they are instead of jumping to the middle.
            onCurrentIndexChanged: {
              if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            }

            delegate: Item {
              id: row

              required property var modelData
              required property int index

              width: ruleList.width
              height: Style.space(40)

              readonly property bool hot: root.cursor === row.index || rowMouse.containsMouse
              readonly property bool live: row.modelData.enabled !== false && root.rulesActive

              Rectangle {
                anchors.fill: parent
                anchors.topMargin: Style.spacing.xxs
                anchors.bottomMargin: Style.spacing.xxs
                radius: Style.cornerRadius
                color: row.hot ? root.inset : "transparent"

                // A bar rather than a tint: the cursor has to be findable at a
                // glance in a list where the rows are otherwise identical.
                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.max(2, Style.space(2))
                  radius: parent.radius
                  color: root.accent
                  visible: root.cursor === row.index
                }
              }

              MouseArea {
                id: rowMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.cursor = row.index
                onClicked: root.toggleAt(row.index)
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.right: forget.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: row.modelData.name
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - offPill.width - parent.spacing)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    color: row.live ? root.ink : root.faint
                  }

                  // Said in a word, not implied by dimness alone: a row that
                  // is merely low-contrast is indistinguishable from a theme
                  // with low contrast.
                  Text {
                    id: offPill

                    anchors.verticalCenter: parent.verticalCenter
                    visible: !row.live
                    text: row.modelData.enabled === false ? qsTr("off") : qsTr("all off")
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.accent
                  }
                }

                Text {
                  width: parent.width
                  text: Rules.describeRule(row.modelData)
                    + (row.modelData.match.title ? " · " + qsTr("one window") : "")
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: row.live ? root.muted : root.faint
                }
              }

              // Always on screen, not revealed by hover: a control that only
              // exists once the pointer is already on it cannot be found by
              // someone looking for it.
              Button {
                id: forget

                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.glyphForget
                iconSize: Style.font.body
                tooltipText: qsTr("Forget this rule")
                foreground: row.hot ? root.ink : root.faint
                accent: root.accent
                onClicked: root.forgetAt(row.index)
              }
            }
          }

          // How much of the list is on screen, and where.
          //
          // Thirty rules showed ten and stopped, with nothing to say the other
          // twenty existed: the count in the heading was the only clue, and a
          // number is not a scrollbar. This is drawn from the view's own
          // visibleArea, so it is right by construction rather than by
          // arithmetic repeated here.
          Rectangle {
            id: scrollTrack

            width: Math.max(2, Style.space(3))
            height: ruleList.height
            radius: width / 2
            color: root.inset
            visible: ruleList.interactive

            Rectangle {
              width: parent.width
              radius: parent.radius
              color: root.faint
              y: ruleList.visibleArea.yPosition * parent.height
              height: Math.max(Style.space(12), ruleList.visibleArea.heightRatio * parent.height)
            }
          }
          }

          // ----------------------------------------------------------- hint
          //
          // Two deliberate lines rather than one that wraps: the first is what
          // the keys do to the window, the second what they do to the list,
          // which is the order the panel itself is read in. Left to wrap, the
          // single line orphaned "esc close" on a line of its own.
          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            Text {
              width: parent.width
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.faint
              text: qsTr("⏎ remember · 1–9 chips · esc close")
            }

            Text {
              width: parent.width
              visible: root.rules.length > 0
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.faint
              text: qsTr("↑↓ pick a rule · space on/off · x forget · u undo")
            }
          }
        }
      }
    }
  }
}
