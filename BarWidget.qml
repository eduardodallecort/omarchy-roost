import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for Roost: a glyph that opens the panel, and a count on hover.
//
// The widget deliberately owns no state. Everything Roost knows lives in its
// `service`, which the shell mounts once per plugin rather than once per
// monitor; a widget that kept its own copy would disagree with the other
// screen's copy the moment a rule changed.
BarWidget {
  id: root

  moduleName: "eduardodallecort.roost"

  // md-dock_window: a window settled into a place, which is the whole of what
  // Roost does. Resolved from the Nerd Fonts registry by name rather than
  // remembered from a cheat sheet — the ranges were renumbered between major
  // versions and the font has a glyph at every codepoint either way.
  // fromCodePoint because \u escapes consume exactly four hex digits.
  readonly property string icon: String.fromCodePoint(0xF10AC)

  readonly property var service: root.bar && root.bar.shell
    && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName) : null

  readonly property int placed: service ? service.ruleCount() : 0
  readonly property bool rulesOff: !!service && service.active === false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function togglePanel() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function")
      root.bar.shell.toggle(root.moduleName, "")
  }

  BarIconButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    text: root.icon
    foreground: root.bar ? root.bar.foreground : Color.foreground
    slotSize: Style.bar.statusSlot
    tooltipText: {
      if (root.rulesOff) return qsTr("Roost · rules switched off")
      if (root.placed === 0) return qsTr("Roost · nothing placed yet")
      if (root.placed === 1) return qsTr("Roost · 1 window placed")
      return qsTr("Roost · %1 windows placed").arg(root.placed)
    }

    onPressed: function (b) { root.togglePanel() }
  }
}
