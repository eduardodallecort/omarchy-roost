import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Rules.js" as Rules

// Roost's single instance: the rule store, the Hyprland file it generates, and
// the only code path that reloads the compositor.
//
// This is a `service` rather than state on the widget because a bar widget is
// built once per monitor. Two copies of this would be two writers racing over
// one Hyprland config file, and the loser would be whatever the user asked for
// last.
Item {
  id: service

  // Injected by the shell.
  property var shell: null

  readonly property string pluginId: "eduardodallecort.roost"
  readonly property string home: Quickshell.env("HOME")

  // Roost's own state: the rules, in the form Roost reasons about.
  readonly property string stateDir: home + "/.local/state/omarchy/plugins/" + pluginId
  readonly property string storePath: stateDir + "/rules.json"

  // The Hyprland half. Omarchy requires every .lua file in this directory at
  // the very end of its config, after the defaults and after the user's own
  // hypr/*.lua — which is both why a rule written here wins, and why Roost
  // needs no line in anybody's hyprland.lua to work. Nothing outside this one
  // generated file is ever touched.
  readonly property string luaDir: home + "/.local/state/omarchy/toggles/hypr"
  readonly property string luaPath: luaDir + "/roost.lua"

  // ------------------------------------------------------------------ state

  property var rules: []
  property bool active: true
  property bool loaded: false
  property bool dirsReady: false

  // Every window a rule could be made from, most recently focused first, and
  // which of them the panel is pointed at. Opening Roost from the bar lands on
  // the first — the window you were last in — but the whole list is kept so
  // the panel can step through it without the user having to go and focus
  // something else first.
  property var windows: []
  property int windowIndex: 0
  property bool capturing: false

  readonly property var window: windowIndex >= 0 && windowIndex < windows.length
    ? windows[windowIndex] : null

  // "" while nothing is wrong. Anything else is shown to the user verbatim,
  // because a silent failure here means their desktop quietly stopped
  // behaving the way the panel says it does.
  property string error: ""
  property bool applying: false

  signal ruleSaved(string name)
  signal captureFinished()

  // Set once the shell has repaired a store/file mismatch, so it cannot turn
  // into a reload every time something touches the store.
  property bool healed: false

  // Whether the generated file has reported back yet — loaded or missing.
  // Distinct from luaFile.loaded, which is false in both the "not read yet"
  // and the "there is no file" cases; healing needs to tell those apart.
  property bool luaKnown: false

  // What was on disk before the write in flight, kept so a config Hyprland
  // refuses can be put back exactly as it was. Only meaningful while
  // `_persisting` is true — see _checkReload.
  property string _previousLua: ""
  property var _previousRules: []
  property bool _previousActive: true

  // True only between a persist writing its files and the reload it started
  // reporting back. The reload started by _healIfNeeded sets neither this nor
  // the _previous* snapshot, and rolling that one back would restore the
  // snapshot's *defaults* — an empty store — losing every rule the user has.
  property bool _persisting: false

  // Set by _reportWriteFailure. Writes are blocking, so a failure lands inside
  // the setText call rather than afterwards, and whatever follows in _persist
  // would otherwise overwrite both the flag and the message.
  property bool _writeFailed: false

  // ---------------------------------------------------------------- reading

  function ruleCount() { return Array.isArray(rules) ? rules.length : 0 }

  // ---------------------------------------------------------- capturing

  // Ask Hyprland what is on screen. One process for both queries: they are
  // read together and a rule built from a window measured against a stale
  // monitor list would be positioned against the wrong frame.
  function capture() {
    if (capturing) return
    capturing = true
    captureProc.running = true
  }

  function _applyCapture(text) {
    var payload = null
    try {
      payload = JSON.parse(text)
    } catch (parseError) {
      payload = null
    }
    if (!payload || !Array.isArray(payload.clients)) {
      service.windows = []
      service.windowIndex = 0
      service.capturing = false
      service.captureFinished()
      return
    }
    service.windows = Rules.candidateWindows(payload.clients, payload.monitors)
    service.windowIndex = 0
    service.capturing = false
    service.captureFinished()
  }

  // Step to another window without leaving the panel. Wraps, because the list
  // is short and a cursor that stops dead at the end is worse than one that
  // comes round again.
  function stepWindow(delta) {
    var step = parseInt(delta, 10)
    if (!isFinite(step) || windows.length === 0) return
    var next = (windowIndex + step) % windows.length
    if (next < 0) next += windows.length
    windowIndex = next
  }

  // ----------------------------------------------------------- writing

  // Remember the captured window. `selection` names the aspects to keep;
  // `options` carries the match mode and the silent-workspace choice.
  function remember(selection, options) {
    if (!window) return false
    var opts = options || {}
    opts.id = "r" + String(Date.now())
    opts.now = Date.now()
    var rule = Rules.buildRule(window, selection, opts)
    if (!rule) {
      error = qsTr("There is nothing to remember about this window.")
      return false
    }
    var next = Rules.upsert(rules, rule)
    if (!_persist(next, active)) return false
    ruleSaved(rule.name)
    return true
  }

  function forget(index) {
    if (index < 0 || index >= ruleCount()) return false
    return _persist(Rules.removeAt(rules, index), active)
  }

  // Put a forgotten rule back at the position it held. Forgetting is instant
  // and destructive, so the panel keeps the last one it removed and offers
  // this; without it the only way back is to find the window again and
  // rebuild the rule from memory.
  function restore(rule, index) {
    if (!rule) return false
    return _persist(Rules.insertAt(rules, rule, index), active)
  }

  function setRuleEnabled(index, on) {
    if (index < 0 || index >= ruleCount()) return false
    var next = rules.slice()
    var rule = {}
    for (var key in next[index]) rule[key] = next[index][key]
    rule.enabled = on === true
    next[index] = rule
    return _persist(next, active)
  }

  function setActive(on) {
    return _persist(rules, on === true)
  }

  // Write both halves and hand the result to Hyprland.
  //
  // The store and the Lua file are written with blocking, atomic writes: a
  // half-written Hyprland config is a broken desktop, and these are two small
  // files written on an explicit keystroke, not on a timer. The reload and the
  // check that follows it are asynchronous, because `hyprctl` is a round trip
  // to another process and the panel should not freeze for it.
  function _persist(nextRules, nextActive) {
    if (!dirsReady) {
      error = qsTr("Roost's state directory is not ready yet. Try again in a moment.")
      return false
    }
    if (applying) {
      error = qsTr("Still saving the last change.")
      return false
    }

    service._previousLua = luaFile.loaded ? luaFile.text() : Rules.rulesToLua([], true)
    service._previousRules = rules
    service._previousActive = active

    service.error = ""
    service._writeFailed = false

    var lua = Rules.rulesToLua(nextRules, nextActive)
    luaFile.setText(lua)
    storeFile.setText(Rules.serializeStore(nextRules, nextActive))

    // blockWrites makes those synchronous, so a failure has already been
    // reported by the time control returns. Reloading now would tell Hyprland
    // to re-read a file that never changed and then report success.
    if (service._writeFailed) {
      service.applying = false
      return false
    }

    service.rules = nextRules
    service.active = nextActive === true
    service.applying = true
    service._persisting = true
    reloadProc.running = true
    return true
  }

  // Hyprland reports a config it could not read through `configerrors`, and
  // keeps running on what it had. Because Roost's file is required last, an
  // error in it leaves everything before it — monitors, bindings, the user's
  // own rules — already applied, so the blast radius of a bad write is Roost
  // and nothing else. This puts even that back.
  function _checkReload(errorsText) {
    var fromPersist = service._persisting
    service._persisting = false
    service.applying = false

    var text = String(errorsText || "")
    if (text.indexOf("roost.lua") === -1) {
      // Never clear a write failure here: that message describes the disk, not
      // the compositor, and the reload it is about never happened.
      if (!service._writeFailed) service.error = ""
      return
    }

    // A reload this service did not start has no snapshot to go back to, and
    // the _previous* properties still hold their defaults — an empty store.
    // Restoring those would delete every rule the user has. Say what happened
    // and leave both files alone; the store is still correct either way.
    if (!fromPersist) {
      service.error = qsTr("Hyprland will not load Roost's rules. %1").arg(text.split("\n")[0])
      return
    }

    service._writeFailed = false
    luaFile.setText(service._previousLua)
    storeFile.setText(Rules.serializeStore(service._previousRules, service._previousActive))
    service.rules = service._previousRules
    service.active = service._previousActive
    // A rollback that could not be written is worse news than the rule being
    // refused, so it keeps the message it set.
    if (!service._writeFailed) {
      service.error = qsTr("Hyprland refused that rule, so nothing changed. %1")
        .arg(text.split("\n")[0])
    }
    rollbackProc.running = true
  }

  // A write that never reached the disk — a full filesystem, a read-only home —
  // leaves Hyprland reading the old file while the panel shows the new rule.
  // Nothing else would notice: `hyprctl configerrors` is happy with a file that
  // parses, including the one that was already there.
  function _reportWriteFailure(path) {
    service.applying = false
    service._writeFailed = true
    service.error = qsTr("Could not write %1, so nothing changed on disk.").arg(path)
  }

  // ---------------------------------------------------------------- loading

  function _loadStore(text) {
    var store = Rules.parseStore(text)
    service.rules = store.rules
    service.active = store.active
    service.loaded = true
    Qt.callLater(service._healIfNeeded)
  }

  // The store and the generated file are two writes; a machine that lost power
  // between them, or a hand-edited roost.lua, leaves the desktop behaving
  // differently from what the panel says. Regenerating from the store settles
  // it in the store's favour, once per shell session.
  //
  // Both views have to have answered first. They load asynchronously and in no
  // defined order, so healing as soon as the *store* arrives can find
  // luaFile.loaded still false, read the existing file as "", conclude it
  // differs from what the store implies, and rewrite it — then reload Hyprland.
  // On every shell start, for anyone with at least one rule.
  function _healIfNeeded() {
    if (healed || !loaded || !luaKnown || !dirsReady) return
    healed = true
    var expected = Rules.rulesToLua(rules, active)
    var current = luaFile.loaded ? luaFile.text() : ""
    if (current === expected) return
    luaFile.setText(expected)
    if (service._writeFailed) return
    // No reload when there is nothing to apply either way: a fresh install
    // would otherwise reload Hyprland just to install an empty file.
    if (ruleCount() > 0 || current !== "") reloadProc.running = true
  }

  // --------------------------------------------------------------- processes

  Process {
    id: ensureDirsProc

    command: ["mkdir", "-p", service.stateDir, service.luaDir]
    running: true
    onExited: function (code) {
      service.dirsReady = code === 0
      if (!service.dirsReady) {
        service.error = qsTr("Could not create %1.").arg(service.stateDir)
        return
      }
      // Only now: a FileView whose directory does not exist yet has nothing to
      // read and nowhere to write, and the failure is silent.
      storeFile.path = service.storePath
      luaFile.path = service.luaPath
    }
  }

  Process {
    id: captureProc

    // Both queries in one shell so the windows and the monitors they are
    // measured against come from the same instant.
    command: ["bash", "-c",
      "printf '{\"clients\":%s,\"monitors\":%s}' \"$(hyprctl -j clients)\" \"$(hyprctl -j monitors)\""]
    running: false
    stdout: StdioCollector {
      onStreamFinished: service._applyCapture(text)
    }
    onExited: function (code) {
      // A non-zero exit never produced usable stdout, so the collector's
      // handler will not have cleared this.
      if (code !== 0) {
        service.windows = []
        service.windowIndex = 0
        service.capturing = false
        service.captureFinished()
      }
    }
  }

  Process {
    id: reloadProc

    // `hyprctl reload` re-reads the whole config, which is how Omarchy's own
    // toggles take effect. `configerrors` is then the only honest answer to
    // "did that work"; its output includes any pre-existing error in the
    // user's config, so the caller matches on Roost's filename rather than on
    // there being any error at all.
    command: ["bash", "-c", "hyprctl reload >/dev/null 2>&1; hyprctl configerrors 2>&1"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: service._checkReload(text)
    }
    onExited: function (code) {
      if (code !== 0 && service.applying) {
        service.applying = false
        service.error = qsTr("Could not reach Hyprland to apply the change.")
      }
    }
  }

  Process {
    id: rollbackProc

    command: ["bash", "-c", "hyprctl reload >/dev/null 2>&1"]
    running: false
  }

  // ------------------------------------------------------------------- files

  // `path` is assigned after mkdir rather than bound here, so neither view
  // ever looks at a directory that does not exist yet.
  FileView {
    id: storeFile

    watchChanges: false
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: service._loadStore(text())
    // First run: no file yet, which is not an error and must still finish
    // loading, or the panel waits forever for a store that will never arrive.
    onLoadFailed: service._loadStore("")
    onSaveFailed: service._reportWriteFailure(service.storePath)
  }

  FileView {
    id: luaFile

    watchChanges: false
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: { service.luaKnown = true; Qt.callLater(service._healIfNeeded) }
    onLoadFailed: { service.luaKnown = true; Qt.callLater(service._healIfNeeded) }
    onSaveFailed: service._reportWriteFailure(service.luaPath)
  }
}
