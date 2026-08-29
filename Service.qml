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

  // Raised when a change the panel already announced turned out not to reach
  // the disk. Writes are asynchronous, so "Forgot Signal." is said before the
  // store has been replaced; this is how the panel takes it back rather than
  // leaving a receipt, and an Undo, for something that never happened.
  signal writeFailed()

  // Set once the shell has repaired a store/file mismatch, so it cannot turn
  // into a reload every time something touches the store.
  property bool healed: false

  // Set when the store on disk could not be read — too large, not a regular
  // file, or gone while being read. Unreadable is not the same as empty:
  // writing over it would destroy rules this process could not parse, so every
  // write is refused while this holds.
  property bool storeUnreadable: false

  // Whether the generated file has reported back yet — read, missing, or
  // refused. Distinct from it being empty; healing needs to tell those apart.
  property bool luaKnown: false

  // The generated file as it is on disk, as far as Roost knows: read once at
  // startup and updated on every write that succeeded. It is never read again,
  // because Roost is the only thing that is supposed to write it and a reread
  // would only ever be a second chance for a hostile file.
  property string luaText: ""

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

  // ---------------------------------------------------------------- reading

  function ruleCount() { return Array.isArray(rules) ? rules.length : 0 }

  // ---------------------------------------------------------- capturing

  // Ask Hyprland what is on screen. One process for both queries: they are
  // read together and a rule built from a window measured against a stale
  // monitor list would be positioned against the wrong frame.
  function capture() {
    if (capturing) return
    capturing = true
    captureProc.answered = false
    captureProc.running = true
  }

  function _noWindows() {
    service.windows = []
    service.windowIndex = 0
    service.capturing = false
    service.captureFinished()
  }

  function _applyCapture(text) {
    // Cleared first, not last. Everything below this line can throw — it walks
    // a JSON document Roost did not write — and a throw inside a signal handler
    // is caught and logged by the QML engine rather than crashing anything,
    // which means `capturing` would stay true and the panel would never ask
    // Hyprland what is on screen again for the rest of the session.
    service.capturing = false
    var raw = String(text || "")
    // At or past the ceiling means the answer was cut, and a cut answer is not
    // a smaller answer — it is a different one. Said out loud rather than
    // shown as an empty desktop.
    if (raw.length >= Rules.MAX_CAPTURE_BYTES) {
      service.error = qsTr("Hyprland reported more open windows than Roost will read.")
      service._noWindows()
      return
    }

    var payload = null
    try {
      payload = JSON.parse(raw)
    } catch (parseError) {
      payload = null
    }
    // An answer that arrived and did not parse is the truncation case again —
    // the ceiling is counted in bytes and `raw.length` in characters, so a
    // desktop full of non-ASCII titles reaches the cut without reaching the
    // comparison above. Reported rather than shown as an empty desktop, which
    // is what a silent return would have looked like.
    if (!payload || !Array.isArray(payload.clients)) {
      if (raw !== "") service.error = qsTr("Hyprland's answer could not be read.")
      service._noWindows()
      return
    }
    service.windows = Rules.candidateWindows(payload.clients, payload.monitors)
    service.windowIndex = 0
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
  // Returns whether the change was *accepted*, not whether it reached the
  // disk: the two files are written by a subprocess, one after the other, and
  // the answer comes back in _writeExited. A write that fails raises
  // `writeFailed`, and `rules` is only replaced once both files are on disk,
  // so a failure leaves the panel showing exactly what Hyprland is still
  // applying.
  function _persist(nextRules, nextActive) {
    if (storeUnreadable) {
      error = qsTr("Roost will not write over a rule store it could not read.")
      return false
    }
    if (!dirsReady) {
      error = qsTr("Roost's state directory is not ready yet. Try again in a moment.")
      return false
    }
    // Not read *yet* is not the same as read and empty, and it has to refuse
    // for the same reason unreadable does. A read that has not come back is
    // normally a matter of milliseconds, but a store on a filesystem that
    // stalls — or one that is not a file at all, where the open blocks until
    // the timeout — leaves seconds in which `rules` is an empty list that was
    // never anybody's, and saving would make it the real one. Found by
    // pointing the store at a named pipe: the save was accepted and replaced
    // it while the read was still waiting.
    if (!loaded) {
      error = qsTr("Roost is still reading your rules. Try again in a moment.")
      return false
    }
    // `reloadProc.running` as well as Roost's own flags, because the repair
    // that runs once at startup reloads Hyprland without ever setting
    // `applying`. A save accepted inside that window would be answered by the
    // *repair's* reload: _checkReload would read `_persisting`, take it for its
    // own answer, clear the save's state while its files were still being
    // written, and — if the config had an error — start a rollback over the
    // top of the queue in flight. Two writers, one queue.
    if (applying || _writeReason !== "" || reloadProc.running) {
      error = qsTr("Still saving the last change.")
      return false
    }

    service._previousLua = service.luaText || Rules.rulesToLua([], true)
    service._previousRules = rules
    service._previousActive = active

    service.error = ""
    service._pendingLua = Rules.rulesToLua(nextRules, nextActive)
    service._pendingRules = nextRules
    service._pendingActive = nextActive === true

    service.applying = true
    service._persisting = true
    // The generated file first: if the second write fails, Hyprland is left
    // applying rules the store does not list, which _healIfNeeded settles on
    // the next start. The other order leaves a store listing rules the desktop
    // never had, which nothing settles.
    service._startWrites("persist", [
      { path: service.luaPath, text: service._pendingLua },
      { path: service.storePath, text: Rules.serializeStore(nextRules, service._pendingActive) }
    ])
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

    // A cut answer cannot be searched for Roost's filename: the name might be
    // past the cut. Nothing is rolled back on it either, because a config
    // producing this many complaints is not one Roost's rule broke, and
    // undoing the change the user just asked for would not fix any of them.
    if (text.length >= Rules.MAX_ERRORS_BYTES) {
      service.error = qsTr("Hyprland reported more configuration errors than Roost will read.")
      return
    }

    if (text.indexOf("roost.lua") === -1) {
      service.error = ""
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

    service.error = qsTr("Hyprland refused that rule, so nothing changed. %1")
      .arg(text.split("\n")[0])
    service._startWrites("rollback", [
      { path: service.luaPath, text: service._previousLua },
      { path: service.storePath,
        text: Rules.serializeStore(service._previousRules, service._previousActive) }
    ])
  }

  // The file name on its own, for anything that lands in the panel's receipt
  // line. That row is one line and elides on the right, and a full path elides
  // away precisely the part that answers the question — leaving
  // "/home/you/.local/state/omarchy/…" and no file name at all. There are two
  // files, both named in the README, and the name is the whole of what the
  // reader needs. Found by reading one that had been cut.
  function _fileName(path) {
    var text = String(path || "")
    var cut = text.lastIndexOf("/")
    return cut >= 0 ? text.slice(cut + 1) : text
  }

  function _reloadUnreachable() {
    service.applying = false
    service._persisting = false
    service.error = qsTr("Could not reach Hyprland to apply the change.")
  }

  // A write that never reached the disk — a full filesystem, a read-only home,
  // a name that is no longer a file — leaves Hyprland reading the old file
  // while the panel shows the new rule. Nothing else would notice: `hyprctl
  // configerrors` is happy with a file that parses, including the one that was
  // already there.
  function _reportWriteFailure(path) {
    service.error = qsTr("Could not write %1, so nothing changed on disk.").arg(service._fileName(path))
    // Before `applying` drops, so the panel takes its receipt back while the
    // Undo beside it is still hidden rather than for the frame in between.
    service.writeFailed()
    service.applying = false
  }

  // ---------------------------------------------------------------- loading

  function _loadStore(text) {
    var store = null
    try {
      store = Rules.parseStore(text)
    } catch (parseError) {
      // The parser is defensive, but it walks a document from disk and this is
      // the one place a throw would be unrecoverable: `loaded` would never
      // become true and the panel would read the rules forever. Treated as
      // unreadable rather than as empty, which is what stops the next save
      // writing an empty store over one this code could not parse.
      store = { active: true, rules: [], oversized: true }
    }
    if (store.oversized) {
      service.storeUnreadable = true
      service.error = qsTr("%1 holds more rules than Roost will read.").arg(service._fileName(service.storePath))
    }
    service.rules = store.rules
    service.active = store.active
    service.loaded = true
    Qt.callLater(service._healIfNeeded)
  }

  // What came back from reading the store. `code` is the read script's own
  // vocabulary — see _readScript.
  function _storeRead(code, text) {
    if (code === 0) {
      service._loadStore(String(text || ""))
      return
    }
    if (code === 10) {
      // No file yet. A fresh install, not a failure, and it must still finish
      // loading or the panel waits forever for a store that will never arrive.
      service._loadStore("")
      return
    }
    // Refuse rather than guess. Reading part of a rule store, or reading
    // something that is not one, would produce a plausible-looking set of
    // rules that is not the user's — and saving over it would then be the
    // last time those rules existed.
    service.storeUnreadable = true
    // Short on purpose: the panel puts the whole of what this means — nothing
    // lost, nothing to be written over — in the paragraph where the rule list
    // would be, which is shown in exactly this case and wraps.
    service.error = code === 12
      ? qsTr("%1 is larger than Roost will read.").arg(service._fileName(service.storePath))
      : qsTr("%1 could not be read.").arg(service._fileName(service.storePath))
    service._loadStore("")
  }

  function _luaRead(code, text) {
    // Anything other than a clean read is treated as "not what Roost wrote":
    // the generated file is Roost's own, it is rewritten wholesale, and the
    // repair below replaces it. Nothing is read from it in that case, so an
    // oversized or hostile file costs one rewrite and no bytes.
    service.luaText = code === 0 ? String(text || "") : ""
    service.luaKnown = true
    Qt.callLater(service._healIfNeeded)
  }

  // The store and the generated file are two writes; a machine that lost power
  // between them, or a hand-edited roost.lua, leaves the desktop behaving
  // differently from what the panel says. Regenerating from the store settles
  // it in the store's favour, once per shell session.
  //
  // Both reads have to have answered first. They run concurrently and in no
  // defined order, so healing as soon as the *store* arrives can find the
  // generated file still unread, take it for empty, conclude it differs from
  // what the store implies, and rewrite it — then reload Hyprland. On every
  // shell start, for anyone with at least one rule.
  function _healIfNeeded() {
    if (healed || !loaded || !luaKnown || !dirsReady) return
    // Never repair from a store that could not be read. `rules` is empty in
    // that case because nothing was parsed, not because there is nothing — and
    // regenerating from it would rewrite the Hyprland file with no rules at
    // all, destroying the ones still being applied.
    if (storeUnreadable) return
    if (_writeReason !== "") return
    healed = true
    var expected = Rules.rulesToLua(rules, active)
    if (luaText === expected) return
    // No reload when there is nothing to apply either way: a fresh install
    // would otherwise reload Hyprland just to install an empty file.
    service._healReload = ruleCount() > 0 || luaText !== ""
    service._pendingLua = expected
    service._startWrites("heal", [{ path: service.luaPath, text: expected }])
  }

  // ----------------------------------------------------------------- writes

  // Why the write in flight is happening, "" when none is. Also the guard that
  // keeps two of them from sharing the one process below.
  property string _writeReason: ""
  property var _writeQueue: []
  property int _writeIndex: 0
  property string _writePayload: ""

  property string _pendingLua: ""
  property var _pendingRules: []
  property bool _pendingActive: true
  property bool _healReload: false

  function _startWrites(reason, queue) {
    // A backstop, not a guard the callers rely on: every one of them checks
    // first. Replacing a queue that is in flight would abandon a half-written
    // pair of files and report neither, which is the one failure here with no
    // symptom at all.
    if (service._writeReason !== "") return false
    service._writeReason = reason
    service._writeQueue = queue
    service._writeIndex = 0
    service._writeNext()
    return true
  }

  function _writeNext() {
    if (service._writeIndex >= service._writeQueue.length) {
      service._writesDone(true)
      return
    }
    var step = service._writeQueue[service._writeIndex]
    service._writePayload = step.text
    writeProc.command = ["timeout", "10", "bash", "-c", service._writeScript, "roost", step.path]
    // Reset before the run, not after: this is the flag that tells a process
    // which failed to start from one that has not been started yet.
    writeProc.answered = false
    writeProc.stdinEnabled = true
    writeProc.running = true
  }

  function _writeExited(code) {
    if (code !== 0) {
      var step = service._writeQueue[service._writeIndex]
      service._reportWriteFailure(step ? step.path : service.storePath)
      service._writesDone(false)
      return
    }
    service._writeIndex += 1
    service._writeNext()
  }

  function _writesDone(ok) {
    var reason = service._writeReason
    service._writeReason = ""
    service._writeQueue = []

    if (reason === "persist") {
      if (!ok) {
        service.applying = false
        service._persisting = false
        return
      }
      service.rules = service._pendingRules
      service.active = service._pendingActive
      service.luaText = service._pendingLua
      reloadProc.answered = false
      reloadProc.running = true
      return
    }

    if (reason === "rollback") {
      // A rollback that could not be written is worse news than the rule being
      // refused, so _reportWriteFailure keeps the message it set.
      if (!ok) return
      service.rules = service._previousRules
      service.active = service._previousActive
      service.luaText = service._previousLua
      rollbackProc.running = true
      return
    }

    if (reason === "heal") {
      if (!ok) return
      service.luaText = service._pendingLua
      if (service._healReload) { reloadProc.answered = false; reloadProc.running = true }
    }
  }

  // --------------------------------------------------------------- processes

  // Every process below carries an `answered` flag and a `runningChanged`
  // guard, because a Quickshell Process that cannot be started emits neither
  // `started` nor `exited` — it goes from running to not running in silence.
  // Measured, on a command that does not exist.
  //
  // Silence is the worst answer any of these could give. The flags that say
  // "reading", "capturing" and "applying" are all cleared by a handler that
  // would never run, so a fork that failed under memory pressure would not
  // degrade Roost, it would freeze it: a panel reading rules forever, or
  // applying a change forever, with no error and nothing to retry. `exited`
  // fires before `running` goes false, so a false with nothing recorded is a
  // process that never ran, and is reported as the failure it is.

  // Read a file the way a filesystem that may be hostile requires: open it
  // once, and decide everything from the descriptor that open returned rather
  // than from the name it was opened by.
  //
  // Measuring a path and then handing the same path to something that opens it
  // again is a check on one file and a read of another — between the two, the
  // name can be pointed somewhere else. And a symlink does not even need the
  // race: `stat` measures the link itself, so seven bytes of "../../big" pass a
  // megabyte ceiling and whatever opens the path next follows it. Measured.
  //
  // So: open once. Ask the descriptor whether it is a regular file — a device
  // would never end, a directory is not a store. Ask the descriptor its size.
  // Then read from that same descriptor through `head`, which caps the bytes
  // before any of them reach QML, rather than after. The exit codes are the
  // vocabulary, because "you have no rules" and "I would not read your rules"
  // must not arrive looking alike.
  //
  // `timeout` is for the one case an open can hang on rather than fail: a
  // named pipe with nobody writing to it.
  readonly property string _readScript: [
    'exec 3<"$1" 2>/dev/null || exit 10',
    '[ -f /dev/fd/3 ] || exit 11',
    'size=$(stat -Lc%s /dev/fd/3 2>/dev/null) || exit 11',
    '[ "$size" -le "$2" ] || exit 12',
    'head -c "$2" <&3'
  ].join("\n")

  // Write by creating a new file and renaming it over the old one, so a reader
  // — Hyprland, on a reload started by somebody else — sees either the whole
  // previous file or the whole new one, never half of either.
  //
  // The temporary is created with `noclobber`, which opens O_EXCL: if anything
  // already holds that name the write fails instead of following it. That is
  // the difference between a temporary file and a footgun, because the state
  // directory is writable by everything running as the user. And `mv` replaces
  // a *name*: pointing roost.lua at somebody's .bashrc gets the symlink
  // replaced, not the file it aimed at.
  readonly property string _writeScript: [
    'exec 2>/dev/null',
    'set -o noclobber',
    'dir=${1%/*}',
    '[ -n "$dir" ] || exit 20',
    'tmp=$dir/.roost.$$.$RANDOM',
    'cat > "$tmp" || { rm -f -- "$tmp"; exit 21; }',
    'mv -f -- "$tmp" "$1" || { rm -f -- "$tmp"; exit 22; }'
  ].join("\n")

  Process {
    id: ensureDirsProc

    property bool answered: false

    command: ["mkdir", "-p", service.stateDir, service.luaDir]
    running: true
    onExited: function (code) {
      ensureDirsProc.answered = true
      service.dirsReady = code === 0
      if (!service.dirsReady) {
        service.error = qsTr("Could not create Roost's state directory.")
        return
      }
      storeReadProc.running = true
      luaReadProc.running = true
    }
    onRunningChanged: {
      if (running || ensureDirsProc.answered) return
      ensureDirsProc.answered = true
      service.error = qsTr("Could not create Roost's state directory.")
    }
  }

  Process {
    id: storeReadProc

    property bool answered: false

    command: ["timeout", "5", "bash", "-c", service._readScript,
      "roost", service.storePath, String(Rules.MAX_STORE_BYTES)]
    running: false
    stdout: StdioCollector { id: storeReadOut }
    // The collector waits for the stream to end before this fires, so the text
    // beside the code is the whole of what was read.
    onExited: function (code) {
      storeReadProc.answered = true
      service._storeRead(code, storeReadOut.text)
    }
    onRunningChanged: {
      if (running || storeReadProc.answered) return
      storeReadProc.answered = true
      service._storeRead(13, "")
    }
  }

  Process {
    id: luaReadProc

    property bool answered: false

    command: ["timeout", "5", "bash", "-c", service._readScript,
      "roost", service.luaPath, String(Rules.MAX_GENERATED_BYTES)]
    running: false
    stdout: StdioCollector { id: luaReadOut }
    onExited: function (code) {
      luaReadProc.answered = true
      service._luaRead(code, luaReadOut.text)
    }
    onRunningChanged: {
      if (running || luaReadProc.answered) return
      luaReadProc.answered = true
      service._luaRead(13, "")
    }
  }

  Process {
    id: writeProc

    property bool answered: false

    running: false
    stdinEnabled: true
    // The content goes in over stdin rather than as an argument: an argument
    // has a length the kernel enforces at a few hundred kilobytes, and a store
    // is allowed to be larger than that.
    onStarted: {
      writeProc.write(service._writePayload)
      // Setting this false is how Quickshell closes the pipe, which is what
      // tells `cat` the file is finished.
      writeProc.stdinEnabled = false
    }
    onExited: function (code) {
      writeProc.answered = true
      service._writeExited(code)
    }
    onRunningChanged: {
      if (running || writeProc.answered) return
      writeProc.answered = true
      service._writeExited(23)
    }
  }

  Process {
    id: captureProc

    property bool answered: false

    // Both queries in one shell so the windows and the monitors they are
    // measured against come from the same instant.
    //
    // Each stream is bounded on the way out with `head -c`, and piped rather
    // than captured in a variable, so no part of this ever holds the whole of
    // an unbounded `hyprctl` answer — not the subshell, and not the collector
    // in the shell process. Truncated output does not parse, which is the
    // point: a partial window list would be read as "these are your windows".
    // `timeout` because a ceiling on the answer is not a ceiling on the wait:
    // a compositor that never replies would leave `capturing` true, and Roost
    // would refuse to look at the desktop again for the rest of the session.
    command: ["timeout", "10", "bash", "-c",
      "limit=$1; { printf '{\"clients\":'; hyprctl -j clients | head -c \"$limit\";"
      + " printf ',\"monitors\":'; hyprctl -j monitors | head -c \"$limit\";"
      + " printf '}'; } | head -c \"$limit\"",
      "roost", String(Rules.MAX_CAPTURE_BYTES)]
    running: false
    stdout: StdioCollector { id: captureOut }
    // Decided here rather than in the collector, which fires *before* this and
    // therefore before the exit code exists. Handling the output first would
    // mean reading a truncated answer as an answer, and then finding out.
    onExited: function (code) {
      captureProc.answered = true
      if (code !== 0) { service._noWindows(); return }
      service._applyCapture(captureOut.text)
    }
    onRunningChanged: {
      if (running || captureProc.answered) return
      captureProc.answered = true
      service._noWindows()
    }
  }

  Process {
    id: reloadProc

    property bool answered: false

    // `hyprctl reload` re-reads the whole config, which is how Omarchy's own
    // toggles take effect. `configerrors` is then the only honest answer to
    // "did that work"; its output includes any pre-existing error in the
    // user's config, so the caller matches on Roost's filename rather than on
    // there being any error at all.
    // Bounded like every other stream that ends up in this process. The reload
    // is gated on its own exit code rather than the pipeline's, because `head`
    // closing the pipe early is a *truncated* answer and not a failed one —
    // with `pipefail` the two would arrive looking the same.
    command: ["timeout", "10", "bash", "-c",
      "limit=$1; hyprctl reload >/dev/null 2>&1 || exit 4;"
      + " hyprctl configerrors 2>&1 | head -c \"$limit\"",
      "roost", String(Rules.MAX_ERRORS_BYTES)]
    running: false
    stdout: StdioCollector { id: reloadOut }
    // Same ordering trap as the capture above, and a worse outcome. The
    // collector fires first; handling the output there would clear `applying`
    // and the error before the exit code arrived, and the non-zero branch —
    // which is what the timeout comes back as — would then find nothing left to
    // report. A reload that never happened would read as one that worked.
    onExited: function (code) {
      reloadProc.answered = true
      if (code !== 0) {
        if (service.applying) service._reloadUnreachable()
        return
      }
      service._checkReload(reloadOut.text)
    }
    onRunningChanged: {
      if (running || reloadProc.answered) return
      reloadProc.answered = true
      if (service.applying) service._reloadUnreachable()
    }
  }

  Process {
    id: rollbackProc

    command: ["timeout", "10", "bash", "-c", "hyprctl reload >/dev/null 2>&1"]
    running: false
  }
}
