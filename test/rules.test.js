const { test } = require("node:test")
const assert = require("node:assert")
const { readFileSync } = require("node:fs")
const { join } = require("node:path")
const vm = require("node:vm")

// lib/Rules.js is a QML `.pragma library`, which is plain JavaScript once the
// QML-only directives are gone. Running it in a bare context puts its
// top-level declarations on `Rules`, so the tests exercise exactly the file
// the shell loads rather than a copy of it.
const Rules = vm.createContext({})
const source = readFileSync(join(__dirname, "..", "lib", "Rules.js"), "utf8")
  .replace(/^\s*\.(pragma|import)\b.*$/gm, "")
vm.runInContext(source, Rules, { filename: "Rules.js" })

// The second entry is this machine's real monitor as `hyprctl monitors -j`
// reports it, bar reservation included, so the centring tests are anchored on
// a layout Hyprland was actually measured against rather than a round number.
const MONITORS = [
  { id: 0, name: "eDP-1", x: 0, y: 0, width: 1920, height: 1200, reserved: [0, 26, 0, 0],
    activeWorkspace: { id: 1, name: "1" }, specialWorkspace: { id: 0, name: "" } },
  { id: 1, name: "HDMI-A-1", x: 1920, y: 0, width: 3440, height: 1440, reserved: [0, 26, 0, 0],
    activeWorkspace: { id: 9, name: "9" }, specialWorkspace: { id: 0, name: "" } }
]

function client(overrides) {
  return Object.assign({
    address: "0x1",
    class: "Signal",
    title: "Signal",
    at: [1920 + 100, 200],
    size: [900, 700],
    floating: true,
    monitor: 1,
    workspace: { id: 9, name: "9" }
  }, overrides)
}

// ------------------------------------------------------------------ escaping

test("a class is escaped before it becomes a pattern", () => {
  assert.equal(Rules.anchoredPattern("org.gnome.Nautilus"), "^(org\\.gnome\\.Nautilus)$")
  assert.equal(Rules.anchoredPattern("steam_app_battlenet"), "^(steam_app_battlenet)$")
  assert.equal(Rules.anchoredPattern("a+b"), "^(a\\+b)$")
  assert.equal(Rules.anchoredPattern("(x)"), "^(\\(x\\))$")
})

test("a pattern is escaped again before it becomes Lua", () => {
  // The dot is escaped once for the regex and its backslash escaped again for
  // Lua. Getting this wrong is a syntax error in the user's Hyprland config,
  // not a rule that quietly fails to match.
  assert.equal(Rules.luaString("^(org\\.gnome\\.Nautilus)$"), "\"^(org\\\\.gnome\\\\.Nautilus)$\"")
  assert.equal(Rules.luaString("say \"hi\""), "\"say \\\"hi\\\"\"")
  assert.equal(Rules.luaString("tab\there"), "\"tab\\there\"")
  // Zero-padded on purpose: Lua reads up to three digits after a backslash,
  // so an unpadded escape merges with a following digit. This assertion used
  // to pin the bug rather than catch it.
  assert.equal(Rules.luaString("\u0007bell"), "\"\\007bell\"")
  assert.equal(Rules.luaString("a\u00075b"), "\"a\\0075b\"")
})

test("every escape Lua would reject is spelled out", () => {
  // Lua 5.4 accepts \a \b \f \n \r \t \v \\ \" \' \ddd \xXX \z \u{}. Anything
  // else is a parse error, so no raw backslash may reach the output.
  const escaped = Rules.luaString("a\\b.c")
  assert.ok(!/[^\\]\\[^\\"nrt0-9]/.test(escaped), escaped)
})

// ------------------------------------------------------------------- windows

test("position is reported relative to the window's own monitor", () => {
  const win = Rules.normalizeWindow(client({ at: [1920 + 100, 200] }), MONITORS)
  assert.equal(win.x, 100)
  assert.equal(win.y, 200)
  assert.equal(win.monitor, "HDMI-A-1")
})

test("a window on an unknown monitor keeps absolute coordinates", () => {
  const win = Rules.normalizeWindow(client({ monitor: 7 }), MONITORS)
  assert.equal(win.x, 2020)
  assert.equal(win.monitor, "")
})

test("a window with no class is reported as unmatchable", () => {
  const win = Rules.normalizeWindow(client({ class: "" }), MONITORS)
  assert.equal(win.matchable, false)
  assert.equal(Rules.buildRule(win, { tiling: true }, {}), null)
})

test("a malformed client never throws", () => {
  assert.equal(Rules.normalizeWindow(null, MONITORS), null)
  const win = Rules.normalizeWindow({ class: "x", at: "nonsense", size: [null, "12"] }, null)
  assert.equal(win.x, 0)
  assert.equal(win.width, 0)
  assert.equal(win.height, 12)
})

test("workspaces are named the way Hyprland's rule expects", () => {
  const numbered = Rules.normalizeWindow(client({ workspace: { id: 8, name: "8" } }), MONITORS)
  assert.equal(Rules.workspaceSelector(numbered.workspace), "8")

  const named = Rules.normalizeWindow(client({ workspace: { id: 12, name: "chat" } }), MONITORS)
  assert.equal(Rules.workspaceSelector(named.workspace), "name:chat")

  const special = Rules.normalizeWindow(client({ workspace: { id: -98, name: "special:magic" } }), MONITORS)
  assert.equal(Rules.workspaceSelector(special.workspace), "special:magic")
})

test("a window without a workspace is not given one", () => {
  const win = Rules.normalizeWindow(client({ workspace: null }), MONITORS)
  assert.equal(win.workspace, null)
  const rule = Rules.buildRule(win, { workspace: true, tiling: true }, {})
  assert.equal(rule.aspects.workspace, undefined)
})

// ------------------------------------------------------------------- centring

test("a window placed by Hyprland's own centring is recognised as centred", () => {
  // Measured, not derived: with `center = true` on this monitor Hyprland put
  // an 820x540 window at absolute 3230, 463. Naive centring against the raw
  // 1440 px height predicts y = 450, so this case is exactly the one that
  // catches a check written against the wrong frame.
  const win = Rules.normalizeWindow(
    client({ at: [3230, 463], size: [820, 540] }), MONITORS)
  assert.equal(win.x, 1310)
  assert.equal(win.y, 463)
  assert.equal(Rules.isCentred(win), true)
  const rule = Rules.buildRule(win, { position: true }, {})
  assert.deepEqual(rule.aspects.position, { mode: "center" })
})

test("centring tolerates a hand-dragged window but not a placed one", () => {
  const near = Rules.normalizeWindow(
    client({ at: [3230 + 20, 463 - 20], size: [820, 540] }), MONITORS)
  assert.equal(Rules.isCentred(near), true)

  const far = Rules.normalizeWindow(
    client({ at: [3230 + 40, 463], size: [820, 540] }), MONITORS)
  assert.equal(Rules.isCentred(far), false)
  const rule = Rules.buildRule(far, { position: true }, {})
  assert.deepEqual(rule.aspects.position, { mode: "at", x: 1350, y: 463 })
})

test("a window whose monitor is unknown is never called centred", () => {
  const win = Rules.normalizeWindow(client({ monitor: 7 }), MONITORS)
  assert.equal(Rules.isCentred(win), false)
})

test("a monitor entirely covered by reserved space yields no usable area", () => {
  const covered = [{ id: 1, name: "x", x: 0, y: 0, width: 800, height: 40, reserved: [0, 40, 0, 0] }]
  const win = Rules.normalizeWindow(client({ monitor: 1 }), covered)
  assert.equal(win.usable, null)
  assert.equal(Rules.isCentred(win), false)
})

// ------------------------------------------------------------------- aspects

test("geometry is offered for a floating window and withheld from a tiled one", () => {
  const floating = Rules.normalizeWindow(client({ floating: true }), MONITORS)
  assert.deepEqual(Rules.availableAspects(floating).sort(), ["position", "size", "tiling", "workspace"])

  const tiled = Rules.normalizeWindow(client({ floating: false }), MONITORS)
  assert.deepEqual(Rules.availableAspects(tiled).sort(), ["tiling", "workspace"])
})

test("a tiled window is not asked to stay tiled by default", () => {
  const tiled = Rules.normalizeWindow(client({ floating: false }), MONITORS)
  const selection = Rules.defaultSelection(tiled)
  assert.equal(selection.workspace, true)
  assert.equal(selection.tiling, false)
})

test("a floating window is remembered whole by default", () => {
  const floating = Rules.normalizeWindow(client({ floating: true }), MONITORS)
  const selection = Rules.defaultSelection(floating)
  assert.deepEqual(selection, { workspace: true, tiling: true, size: true, position: true })
})

test("size is never written for a tiled window even if asked for", () => {
  const tiled = Rules.normalizeWindow(client({ floating: false }), MONITORS)
  const rule = Rules.buildRule(tiled, { workspace: true, size: true, position: true }, {})
  assert.equal(rule.aspects.size, undefined)
  assert.equal(rule.aspects.position, undefined)
})

test("a selection with nothing in it produces no rule", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  assert.equal(Rules.buildRule(win, {}, {}), null)
})

// ---------------------------------------------------------------------- Lua

test("a floating rule serializes in an order Hyprland can apply", () => {
  const win = Rules.normalizeWindow(client({ at: [1920 + 100, 200] }), MONITORS)
  const rule = Rules.buildRule(win, Rules.defaultSelection(win), { id: "r1" })
  const lua = Rules.ruleToLua(rule)

  assert.match(lua, /hl\.window_rule\(\{/)
  assert.match(lua, /match = \{ class = "\^\(Signal\)\$" \}/)
  // float has to precede size and move: Hyprland applies geometry to a window
  // that is already floating.
  assert.ok(lua.indexOf("float = true") < lua.indexOf("size ="), lua)
  assert.ok(lua.indexOf("size =") < lua.indexOf("move ="), lua)
  assert.match(lua, /size = \{ 900, 700 \}/)
  assert.match(lua, /move = \{ 100, 200 \}/)
  assert.match(lua, /workspace = "9"/)
})

test("matching one window adds the title and says so", () => {
  const win = Rules.normalizeWindow(client({ title: "Friends List" }), MONITORS)
  const rule = Rules.buildRule(win, { tiling: true }, { matchMode: "window" })
  assert.match(Rules.ruleToLua(rule), /title = "\^\(Friends List\)\$"/)
})

test("a silent workspace keeps the flag out of the pattern", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true }, { silent: true })
  assert.match(Rules.ruleToLua(rule), /workspace = "9 silent"/)
  assert.match(Rules.describeRule(rule), /without switching/)
})

test("a disabled rule is commented out rather than dropped", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, { tiling: true }, {})
  rule.enabled = false
  const file = Rules.rulesToLua([rule])
  assert.ok(!/^hl\.window_rule/m.test(file), file)
  assert.match(file, /-- hl\.window_rule/)
  assert.match(file, /\[off\]/)
})

test("an empty rule set still produces a loadable file", () => {
  const file = Rules.rulesToLua([])
  assert.match(file, /No rules yet/)
  assert.ok(!/hl\.window_rule/.test(file))
})

test("nothing that is not a rule reaches the file", () => {
  const file = Rules.rulesToLua([null, undefined, {}, { match: {} }])
  assert.ok(!/hl\.window_rule/.test(file), file)
})

// --------------------------------------------------------------- persistence

test("a rule survives a round trip through the store", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, Rules.defaultSelection(win), { id: "r1", now: 1755900000000 })
  const restored = Rules.parseStore(Rules.serializeStore([rule], true))
  assert.equal(restored.rules.length, 1)
  assert.deepEqual(restored.rules[0], rule)
  assert.equal(restored.active, true)
  assert.equal(Rules.ruleToLua(restored.rules[0]), Rules.ruleToLua(rule))
})

test("the master switch survives a round trip", () => {
  assert.equal(Rules.parseStore(Rules.serializeStore([], false)).active, false)
  assert.equal(Rules.parseStore(Rules.serializeStore([], true)).active, true)
})

test("a corrupt or missing store reads as switched on with no rules", () => {
  // A store that has never been written must not read as "off", or a fresh
  // install would apply nothing and give no reason.
  for (const text of ["not json", "", "{}", "{\"rules\":\"nope\"}"]) {
    assert.deepEqual(Rules.parseStore(text), { active: true, rules: [], oversized: false }, text)
  }
})

test("a hand-edited store keeps only what it can apply", () => {
  const store = JSON.stringify({
    version: 1,
    rules: [
      { match: { class: "" }, aspects: { tiling: "float" } },
      { match: { class: "A" }, aspects: { tiling: "sideways" } },
      { match: { class: "B" }, aspects: { size: ["wide", 700] } },
      { match: { class: "C" }, aspects: { position: { mode: "at", x: "x", y: 1 } } },
      { match: { class: "D" }, aspects: { workspace: { selector: "3" }, size: [800, 600] } }
    ]
  })
  const rules = Rules.parseStore(store).rules
  assert.deepEqual(rules.map(r => r.match.class), ["D"])
  assert.deepEqual(rules[0].aspects.size, [800, 600])
  assert.equal(rules[0].aspects.workspace.silent, false)
})

test("re-remembering a window replaces its rule instead of stacking one", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const first = Rules.buildRule(win, { tiling: true }, { id: "r1" })
  const second = Rules.buildRule(win, { workspace: true }, { id: "r2" })
  const list = Rules.upsert(Rules.upsert([], first), second)
  assert.equal(list.length, 1)
  assert.equal(list[0].id, "r2")
})

test("a window rule and an app rule for the same app are different rules", () => {
  const win = Rules.normalizeWindow(client({ title: "Friends List" }), MONITORS)
  const app = Rules.buildRule(win, { tiling: true }, { id: "r1", matchMode: "app" })
  const one = Rules.buildRule(win, { tiling: true }, { id: "r2", matchMode: "window" })
  const list = Rules.upsert(Rules.upsert([], app), one)
  assert.equal(list.length, 2)
})

test("upsert leaves the caller's array alone", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, { tiling: true }, { id: "r1" })
  const original = []
  assert.equal(Rules.upsert(original, rule).length, 1)
  assert.equal(original.length, 0)
})

test("an existing rule is found for the window it came from", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, { tiling: true }, { id: "r1" })
  const list = [rule]
  assert.equal(Rules.findRuleFor(list, win, "app"), 0)
  assert.equal(Rules.findRuleFor(list, win, "window"), -1)
  assert.equal(Rules.findRuleFor(list, null, "app"), -1)
})

// -------------------------------------------------------------- descriptions

test("a rule describes itself in a sentence", () => {
  const win = Rules.normalizeWindow(client({ at: [1920 + 100, 200] }), MONITORS)
  const rule = Rules.buildRule(win, Rules.defaultSelection(win), {})
  assert.equal(Rules.describeRule(rule), "floating · 900×700 · at 100, 200 · workspace 9")
})

test("a centred rule says centred", () => {
  const win = Rules.normalizeWindow(client({ at: [1920 + 1270, 370] }), MONITORS)
  const rule = Rules.buildRule(win, { position: true, tiling: true }, {})
  assert.equal(Rules.describeRule(rule), "floating · centred")
})

test("a tiled workspace rule reads as one", () => {
  const win = Rules.normalizeWindow(client({ floating: false, workspace: { id: 4, name: "4" } }), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true, tiling: true }, {})
  assert.equal(Rules.describeRule(rule), "tiled · workspace 4")
})

// ------------------------------------------------------------ picking a window
//
// These live on candidateWindows now: it is what the service calls, and the
// single-window helper it replaced added nothing the list does not say.

test("an unmapped window is not offered", () => {
  const clients = [
    client({ class: "ghost", focusHistoryID: 0, mapped: false }),
    client({ class: "Signal", focusHistoryID: 4 })
  ]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class), ["Signal"])
})

// ---------------------------------------------------------------- undoing

function ruleFor(cls, id) {
  const win = Rules.normalizeWindow(client({ class: cls }), MONITORS)
  return Rules.buildRule(win, { tiling: true }, { id: id })
}

test("a forgotten rule goes back where it was", () => {
  const list = [ruleFor("a", "1"), ruleFor("b", "2"), ruleFor("c", "3")]
  const without = Rules.removeAt(list, 1)
  assert.deepEqual(without.map(r => r.match.class), ["a", "c"])
  const back = Rules.insertAt(without, list[1], 1)
  assert.deepEqual(back.map(r => r.match.class), ["a", "b", "c"])
})

test("undoing after re-remembering the same app replaces the newer rule", () => {
  // Otherwise the undo would leave two rules matching the same windows, and
  // the one that wins would be whichever Hyprland read last.
  const original = ruleFor("b", "old")
  const list = [ruleFor("a", "1"), ruleFor("b", "new")]
  const back = Rules.insertAt(list, original, 1)
  assert.equal(back.length, 2)
  assert.deepEqual(back.map(r => r.id), ["1", "old"])
})

test("an out-of-range or missing index appends", () => {
  const list = [ruleFor("a", "1")]
  assert.equal(Rules.insertAt(list, ruleFor("b", "2"), 99).length, 2)
  assert.equal(Rules.insertAt(list, ruleFor("b", "2"), -3)[1].match.class, "b")
  assert.equal(Rules.insertAt(list, ruleFor("b", "2"), "nope")[1].match.class, "b")
})

test("insertAt leaves the caller's array alone and ignores a missing rule", () => {
  const list = [ruleFor("a", "1")]
  assert.equal(Rules.insertAt(list, null, 0).length, 1)
  assert.equal(Rules.insertAt(list, ruleFor("b", "2"), 0).length, 2)
  assert.equal(list.length, 1)
})

// -------------------------------------------------- choosing among windows

test("candidates come back most recently focused first", () => {
  const clients = [
    client({ class: "foot", focusHistoryID: 3 }),
    client({ class: "Signal", focusHistoryID: 0 }),
    client({ class: "firefox", focusHistoryID: 1 })
  ]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class),
    ["Signal", "firefox", "foot"])
})

test("a window with no focus history sorts last but is still offered", () => {
  const clients = [
    client({ class: "ghost", focusHistoryID: undefined }),
    client({ class: "Signal", focusHistoryID: 2 })
  ]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class),
    ["Signal", "ghost"])
})

test("the picker never offers a window no rule could match", () => {
  const clients = [
    client({ class: "", focusHistoryID: 0 }),
    client({ class: "org.quickshell", focusHistoryID: 1 }),
    client({ class: "Signal", focusHistoryID: 2 })
  ]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class), ["Signal"])
})

test("no windows at all is an empty list, not an error", () => {
  assert.deepEqual(Rules.candidateWindows([], MONITORS), [])
  assert.deepEqual(Rules.candidateWindows(null, MONITORS), [])
})

// ------------------------------------------------------- long class names

test("a class too long for a control is shortened, not left to overflow", () => {
  // The real one, from a Chromium web app.
  const long = "chrome-discord.com__channels_@me-Default"
  assert.equal(long.length, 40)
  const short = Rules.shorten(long, 20)
  assert.equal(short.length, 20)
  assert.ok(short.endsWith("…"), short)
  assert.ok(long.startsWith(short.slice(0, -1)), short)
})

test("a class that already fits is left alone", () => {
  assert.equal(Rules.shorten("foot", 20), "foot")
  assert.equal(Rules.shorten("org.gnome.Nautilus", 20), "org.gnome.Nautilus")
})

test("shortening never returns something longer than asked for", () => {
  for (const n of [4, 8, 20, 64]) {
    assert.ok(Rules.shorten("x".repeat(200), n).length <= n, String(n))
  }
  // A nonsense limit falls back rather than producing a one-character label.
  assert.equal(Rules.shorten("x".repeat(50), 0).length, 20)
  assert.equal(Rules.shorten("", 20), "")
})


// ------------------------------------------------- scoping to what is on screen

test("the picker offers only windows that are on a screen right now", () => {
  const clients = [
    client({ class: "hidden", focusHistoryID: 0, workspace: { id: 5, name: "5" } }),
    client({ class: "onLaptop", focusHistoryID: 1, workspace: { id: 1, name: "1" } }),
    client({ class: "onWide", focusHistoryID: 2, workspace: { id: 9, name: "9" } })
  ]
  // Both monitors count, not just the focused one: the other screen's windows
  // are in front of the user.
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class),
    ["onLaptop", "onWide"])
})

test("a special workspace counts only while a monitor is showing it", () => {
  const clients = [client({ class: "scratch", focusHistoryID: 0, workspace: { id: -98, name: "special:magic" } })]
  const closed = [Object.assign({}, MONITORS[0], { specialWorkspace: { id: 0, name: "" } })]
  assert.deepEqual(Rules.candidateWindows(clients, closed).map(w => w.class), [])

  const open = [Object.assign({}, MONITORS[0], { specialWorkspace: { id: -98, name: "special:magic" } })]
  assert.deepEqual(Rules.candidateWindows(clients, open).map(w => w.class), ["scratch"])
})

test("asking for everywhere brings the other workspaces back", () => {
  const clients = [
    client({ class: "hidden", focusHistoryID: 0, workspace: { id: 5, name: "5" } }),
    client({ class: "onWide", focusHistoryID: 1, workspace: { id: 9, name: "9" } })
  ]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS, { everywhere: true }).map(w => w.class),
    ["hidden", "onWide"])
})

test("monitors Roost cannot read do not silently hide every window", () => {
  // No monitor list means no way to know what is on screen. Dropping
  // everything would leave a picker that is simply empty, with no reason
  // given, so the scope opens instead.
  const clients = [client({ class: "Signal", focusHistoryID: 0, workspace: { id: 5, name: "5" } })]
  assert.deepEqual(Rules.candidateWindows(clients, null).map(w => w.class), ["Signal"])
})

test("a window with no workspace is not offered when scoping to the screen", () => {
  const clients = [client({ class: "orphan", focusHistoryID: 0, workspace: null })]
  assert.deepEqual(Rules.candidateWindows(clients, MONITORS).map(w => w.class), [])
})

// ------------------------------------- losing to Omarchy's own tag rules

test("a rule is written as a tagging half and a working half", () => {
  // This is what makes a Roost rule take effect at all. Measured against the
  // compositor: btop opened 875×600 — the size Omarchy's floating-window tag
  // carries — while a plain class rule from Roost asked for 1375×1000. Routed
  // through a tag of its own it opened at 1375×1000.
  const win = Rules.normalizeWindow(
    client({ class: "org.omarchy.btop", size: [1375, 1000], floating: true }), MONITORS)
  const lua = Rules.ruleToLua(Rules.buildRule(win, Rules.defaultSelection(win), {}), 0)

  assert.match(lua, /match = \{ class = "\^\(org\\\\\.omarchy\\\\\.btop\)\$" \}, tag = "\+roost-1" \}\)/)
  assert.match(lua, /match = \{ tag = "roost-1" \}/)
  // The properties belong to the tag rule, never to the class rule: on the
  // class rule they would lose to Omarchy's tags.
  assert.ok(lua.indexOf('tag = "roost-1"') < lua.indexOf("size ="), lua)
  assert.ok(lua.indexOf("class =") < lua.indexOf('tag = "roost-1"'), lua)
})

test("every rule gets a tag of its own", () => {
  // One shared tag would make the last rule in the file apply to every window
  // any of them matched.
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rules = [
    Rules.buildRule(win, { workspace: true }, { id: "a" }),
    Rules.buildRule(Rules.normalizeWindow(client({ class: "other" }), MONITORS), { workspace: true }, { id: "b" })
  ]
  const file = Rules.rulesToLua(rules, true)
  const tags = [...file.matchAll(/tag = "\+?(roost-\d+)"/g)].map(m => m[1])
  assert.deepEqual([...new Set(tags)].sort(), ["roost-1", "roost-2"])
})

test("a workspace-only rule is routed the same way", () => {
  // Uniform on purpose: one shape to read, and the strongest one available.
  const win = Rules.normalizeWindow(client({ floating: false }), MONITORS)
  const lua = Rules.ruleToLua(Rules.buildRule(win, { workspace: true }, {}), 3)
  assert.match(lua, /tag = "\+roost-4"/)
  assert.match(lua, /match = \{ tag = "roost-4" \}/)
})

test("forcing a tagged app to tile goes through the tag too", () => {
  const win = Rules.normalizeWindow(client({ floating: false }), MONITORS)
  const lua = Rules.ruleToLua(Rules.buildRule(win, { tiling: true, workspace: true }, {}), 0)
  assert.match(lua, /match = \{ tag = "roost-1" \}/)
  assert.match(lua, /tile = true/)
})

// ------------------------------------------------ keeping the chips coherent

test("choosing a size turns floating on with it", () => {
  const before = { workspace: true, tiling: false, size: false, position: false }
  const after = Rules.coerceSelection(Object.assign({}, before, { size: true }), "size")
  assert.equal(after.tiling, true)
})

test("turning floating off takes the geometry with it", () => {
  const before = { workspace: true, tiling: false, size: true, position: true }
  const after = Rules.coerceSelection(before, "tiling")
  assert.equal(after.size, false)
  assert.equal(after.position, false)
})

test("toggling the workspace chip does not disturb the others", () => {
  const before = { workspace: false, tiling: true, size: true, position: true }
  const after = Rules.coerceSelection(before, "workspace")
  assert.deepEqual(after, before)
})

test("coerceSelection leaves the caller's object alone", () => {
  const before = { tiling: false, size: true }
  Rules.coerceSelection(before, "size")
  assert.equal(before.tiling, false)
})

test("geometry from a hand-edited store still floats the window", () => {
  // The backstop for a selection that never went through the panel.
  const win = Rules.normalizeWindow(client({ floating: true }), MONITORS)
  const rule = Rules.buildRule(win, { size: true, position: true }, {})
  assert.equal(rule.aspects.tiling, "float")
  assert.match(Rules.ruleToLua(rule), /float = true/)
})

// ------------------------------------------------ a store that fights back

test("a name carrying a newline cannot break out of its comment", () => {
  // The comment above each rule is the one value that reaches the Lua without
  // going through luaString, and a comment ends at the end of its line. Left
  // alone, this store emitted `print(1) --` at the top level of a file
  // Hyprland requires, i.e. a config that does not parse.
  const store = JSON.stringify({
    version: 1, active: true,
    rules: [{
      id: "x", name: "Evil\nprint(1) --", match: { class: "Evil", title: "" },
      aspects: { workspace: { selector: "5", label: "lab\nprint(2)", silent: false } },
      enabled: true
    }]
  })
  const file = Rules.rulesToLua(Rules.parseStore(store).rules, true)
  for (const line of file.split("\n")) {
    // Every line is either a comment, part of a rule call, or blank. None is
    // stray code.
    assert.ok(!/^\s*print\(/.test(line), line)
  }
  assert.match(file, /^-- Evil print\(1\) -- · workspace lab print\(2\)$/m)
})

test("a stored name that is only whitespace falls back to the class", () => {
  const store = JSON.stringify({
    version: 1, active: true,
    rules: [{ id: "x", name: "\n\n", match: { class: "Signal", title: "" },
              aspects: { workspace: { selector: "5", label: "5", silent: false } }, enabled: true }]
  })
  assert.equal(Rules.parseStore(store).rules[0].name, "Signal")
})

// ------------------------------------------------------- the file on disk

test("no source file carries a NUL byte", () => {
  // A NUL is a valid character inside a JS string, so two of them sat in the
  // ruleKey separator through every run of this suite: the code worked, the
  // tests were green, and nothing said otherwise. Anything that sniffs a file
  // for one calls it binary — the marketplace security baseline refused to
  // scan the library and the submission failed validation with "not a
  // supported text file". The separator is still a NUL at runtime, written as
  // an escape sequence so the file itself stays text.
  const { readdirSync, statSync } = require("node:fs")
  const root = join(__dirname, "..")
  const sources = []
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      if (name === ".git" || name === "node_modules" || name === "screenshots") continue
      const full = join(dir, name)
      if (statSync(full).isDirectory()) walk(full)
      else if (/\.(js|mjs|qml|json|sh|md|ya?ml)$/.test(name)) sources.push(full)
    }
  }
  walk(root)
  assert.ok(sources.length > 8, `expected to find the sources, found ${sources.length}`)
  for (const file of sources) {
    assert.equal(readFileSync(file).includes(0), false, `${file} contains a NUL byte`)
  }
})

test("the rule key separates class from title unambiguously", () => {
  // Which is why the separator is a NUL rather than a space: a title can
  // contain a space, and these two would otherwise produce the same key.
  assert.notEqual(
    Rules.ruleKey({ match: { class: "a b", title: "" } }),
    Rules.ruleKey({ match: { class: "a", title: "b" } }))
})

// ------------------------------------------------- ceilings on outside input
//
// Raised by the marketplace maintainer's security review: the store, the
// generated file and the compositor's output all reach a process that owns the
// bar, the lock screen and the polkit agent, so none of them may be read
// without an upper bound.

test("an oversized store is refused rather than read as empty", () => {
  // Empty and unreadable have to be different answers. Read as empty, the next
  // save would write an empty store over a file this code could not parse.
  const padding = "x".repeat(Rules.MAX_STORE_BYTES + 1)
  const store = Rules.parseStore(padding)
  assert.equal(store.oversized, true)
  assert.deepEqual(store.rules, [])
})

test("a store just inside the limit is still read normally", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true }, { id: "r1" })
  const text = Rules.serializeStore([rule], true)
  assert.ok(text.length < Rules.MAX_STORE_BYTES)
  const store = Rules.parseStore(text)
  assert.equal(store.oversized, false)
  assert.equal(store.rules.length, 1)
})

test("a corrupt store is not reported as oversized", () => {
  // The two failures need different handling: unreadable-but-small is safe to
  // overwrite, oversized is not.
  const store = Rules.parseStore("not json")
  assert.equal(store.oversized, false)
  assert.deepEqual(store.rules, [])
})

test("the window list is capped however many windows are open", () => {
  const clients = []
  for (let i = 0; i < Rules.MAX_CLIENTS + 500; i++) {
    clients.push(client({ class: "app" + i, focusHistoryID: i, workspace: { id: 9, name: "9" } }))
  }
  const windows = Rules.candidateWindows(clients, MONITORS)
  assert.ok(windows.length <= Rules.MAX_CLIENTS, `got ${windows.length}`)
  // The cap keeps the most recently focused, which is the end anyone cares
  // about — the picker is ordered by focus recency.
  assert.equal(windows[0].class, "app0")
})

test("the ceilings are sane relative to each other", () => {
  assert.ok(Rules.MAX_STORE_BYTES > 0 && Rules.MAX_GENERATED_BYTES > 0)
  assert.ok(Rules.MAX_CAPTURE_BYTES >= Rules.MAX_STORE_BYTES)
  assert.ok(Rules.MAX_CLIENTS > 100)
})

test("a store holding more rules than the ceiling is refused, not truncated", () => {
  // Bytes and rules are not the same limit. A store well inside a megabyte can
  // still declare thousands of rules, and every one of them becomes a window
  // rule Hyprland evaluates for the rest of the session.
  const win = Rules.normalizeWindow(client(), MONITORS)
  const one = Rules.buildRule(win, { workspace: true }, { id: "r1" })
  const many = []
  for (let i = 0; i <= Rules.MAX_RULES; i++) {
    many.push(Object.assign({}, one, { id: "r" + i, match: { class: "app" + i, title: "" } }))
  }
  const text = Rules.serializeStore(many, true)
  assert.ok(text.length < Rules.MAX_STORE_BYTES, "the byte ceiling is not what catches this")
  const store = Rules.parseStore(text)
  assert.equal(store.oversized, true)
  assert.deepEqual(store.rules, [])
})

test("a store at exactly the rule ceiling is still read", () => {
  const win = Rules.normalizeWindow(client(), MONITORS)
  const one = Rules.buildRule(win, { workspace: true }, { id: "r1" })
  const many = []
  for (let i = 0; i < Rules.MAX_RULES; i++) {
    many.push(Object.assign({}, one, { id: "r" + i, match: { class: "app" + i, title: "" } }))
  }
  const store = Rules.parseStore(Rules.serializeStore(many, true))
  assert.equal(store.oversized, false)
  assert.equal(store.rules.length, Rules.MAX_RULES)
})

test("a window with an absurd class cannot be turned into a rule", () => {
  // The class is whatever the application says it is. A megabyte of it would
  // go into the store, and the store would then be too large to read — every
  // rule the user has, unreadable, at the choice of any application on the
  // desktop.
  const absurd = client({ class: "x".repeat(Rules.MAX_MATCH_LENGTH + 1) })
  const win = Rules.normalizeWindow(absurd, MONITORS)
  assert.equal(win.matchable, false)
  assert.equal(Rules.buildRule(win, { workspace: true }, { id: "r1" }), null)
  // And it never reaches the panel to be refused there.
  const offered = Rules.candidateWindows([absurd, client()], MONITORS)
  assert.deepEqual(offered.map(w => w.class), [client().class])
})

test("a class at the length limit still works", () => {
  const win = Rules.normalizeWindow(client({ class: "x".repeat(Rules.MAX_MATCH_LENGTH) }), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true }, { id: "r1" })
  assert.ok(rule)
  assert.equal(rule.match.class.length, Rules.MAX_MATCH_LENGTH)
})

test("a long title is kept whole, because a cut one matches nothing", () => {
  // Titles are matched with an anchored pattern. Shortening one produces a
  // rule that is saved, written, applied — and silently matches no window that
  // has ever existed. The ceiling is on the class, which an application can
  // choose unilaterally; a title only reaches the store when the user asks for
  // "only this window".
  const title = "t".repeat(Rules.MAX_MATCH_LENGTH * 3)
  const win = Rules.normalizeWindow(client({ title: title }), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true }, { id: "r1", matchMode: Rules.MATCH_WINDOW })
  assert.equal(rule.match.title, title)
  // And the pattern it generates matches the window it was made from.
  const pattern = new RegExp(Rules.anchoredPattern(rule.match.title))
  assert.ok(pattern.test(title))
})

test("a long title survives a round trip through the store", () => {
  const title = "t".repeat(Rules.MAX_MATCH_LENGTH * 3)
  const win = Rules.normalizeWindow(client({ title: title }), MONITORS)
  const rule = Rules.buildRule(win, { workspace: true }, { id: "r1", matchMode: Rules.MATCH_WINDOW })
  const store = Rules.parseStore(Rules.serializeStore([rule], true))
  assert.equal(store.rules.length, 1)
  assert.equal(store.rules[0].match.title, title)
})

test("a stored rule with an absurd class is dropped on read", () => {
  const store = Rules.parseStore(JSON.stringify({
    version: 1,
    active: true,
    rules: [{
      id: "r1",
      name: "big",
      match: { class: "x".repeat(Rules.MAX_MATCH_LENGTH + 1), title: "" },
      aspects: { tiling: "float" },
      enabled: true
    }]
  }))
  assert.equal(store.oversized, false)
  assert.deepEqual(store.rules, [])
})

test("every stream that reaches the shell process has a ceiling", () => {
  // Four things arrive from outside: the two files, the window list, and the
  // compositor's answer to "did that config load". This is the list, so that
  // adding a fifth without a ceiling fails here rather than in review.
  for (const name of ["MAX_STORE_BYTES", "MAX_GENERATED_BYTES", "MAX_CAPTURE_BYTES", "MAX_ERRORS_BYTES"]) {
    assert.equal(typeof Rules[name], "number", `${name} is missing`)
    assert.ok(Rules[name] > 0 && Rules[name] <= 8 * 1024 * 1024, `${name} is not a sane ceiling`)
  }
  // And two on counts, because bytes bound neither of these.
  assert.ok(Rules.MAX_CLIENTS > 100 && Rules.MAX_RULES > 10 && Rules.MAX_MATCH_LENGTH > 64)
  // And one on what is laid out, which is not the same as what is stored: a
  // title is kept whole so the rule still matches, and cut before it is drawn.
  assert.ok(Rules.MAX_SHOWN_TITLE > 40 && Rules.MAX_SHOWN_TITLE < Rules.MAX_MATCH_LENGTH)
})

test("utf8Length counts what lands on disk, not characters", () => {
  // The ceilings are byte counts and a JS length is UTF-16 code units. They
  // agree for everything a Western desktop produces, which is what makes the
  // difference invisible until somebody's window title is in Japanese.
  for (const text of ["", "abc", "café", "日本語", "😀", "a😀b", "\ud800"]) {
    assert.equal(Rules.utf8Length(text), Buffer.byteLength(text, "utf8"), JSON.stringify(text))
  }
  assert.equal(Rules.utf8Length(null), 4)
  assert.equal(Rules.utf8Length(12), 2)
})

test("a store Roost would refuse to read is one it can tell apart in advance", () => {
  // The invariant behind the check in Service._persist: what the writer is
  // about to put on disk is measured the same way the reader measures it, so
  // "will not read" and "will not write" cannot disagree.
  const title = "T".repeat(2 * 1024 * 1024)
  const win = Rules.normalizeWindow(client({ title: title }), MONITORS)
  const rule = Rules.buildRule(win, { tiling: true }, { id: "r1", matchMode: Rules.MATCH_WINDOW })
  const store = Rules.serializeStore([rule], true)
  assert.ok(Rules.utf8Length(store) > Rules.MAX_STORE_BYTES)
  assert.ok(Rules.utf8Length(Rules.rulesToLua([rule], true)) > Rules.MAX_GENERATED_BYTES)
  // And this is what would happen on the next start if it were written.
  assert.equal(Rules.parseStore(store).oversized, true)
  assert.deepEqual(Rules.parseStore(store).rules, [])
})

// ----------------------------------------------- text the plugin did not write

test("inertText removes what markup is built from, and nothing else", () => {
  assert.equal(Rules.inertText('<img src="http://x/y.png">'), 'img src="http://x/y.png">')
  assert.equal(Rules.inertText("Steam&nbsp;Client"), "Steamnbsp;Client")
  assert.equal(Rules.inertText("org.gnome.Nautilus"), "org.gnome.Nautilus")
  // Inert is not the whole job: what is left has to stay worth reading, since
  // this is a label somebody uses to tell one rule from another.
  assert.equal(Rules.inertText("My Bank — Login<img src=x>"), "My Bank — Loginimg src=x>")
  assert.equal(Rules.inertText("kitty"), "kitty")
  // A class is whatever the application says it is, including nothing at all.
  assert.equal(Rules.inertText(null), "")
  assert.equal(Rules.inertText(undefined), "")
  assert.equal(Rules.inertText(0), "0")
  // Every occurrence, not the first: one tag is enough and there is no reason
  // an attacker would stop at one.
  assert.equal(Rules.inertText("<a><b><c>"), "a>b>c>")
})

// Which Text element each line of Panel.qml sits inside.
//
// Braces are counted whether they open an element or a JavaScript block, so
// the depth stays right either way; only element-opening lines put a name on
// the stack. The parser asserts it ends where it started, which is what makes
// a wrong answer here fail loudly rather than quietly.
function enclosingElements(source) {
  const lines = source.split("\n")
  const stack = []
  const out = []
  for (const line of lines) {
    const bare = line.replace(/\/\/.*$/, "")
    const opens = (bare.match(/\{/g) || []).length
    const closes = (bare.match(/\}/g) || []).length
    const element = bare.match(/^\s*([A-Z]\w*)\s*\{\s*$/)
    out.push({ line, inside: stack.slice() })
    for (let i = 0; i < opens; i++) stack.push(i === 0 && element ? element[1] : null)
    for (let i = 0; i < closes; i++) stack.pop()
  }
  assert.equal(stack.length, 0, "the QML brace count does not balance")
  return out
}

test("every Text in Panel.qml is PlainText", () => {
  // Text.AutoText, the default, decides per string whether it is markup. The
  // panel shows the class and title of whatever window is in front, both of
  // them written by that window's application, so a title shaped like an
  // <img> tag is fetched over the network by the shell process. Declared on
  // every element rather than on the four that carry an untrusted value
  // today: a missing property is invisible, and a fifth element is one edit
  // away. test/text-format.sh renders this and watches a socket.
  const source = readFileSync(join(__dirname, "..", "Panel.qml"), "utf8")
  const code = source.replace(/\/\/.*$/gm, "")
  // Every way of declaring one, not only the way they happen to be written
  // today: a `Text { text: … }` on a single line is exactly the edit this test
  // exists to catch, and splitting on an anchored line would not see it.
  const declared = (code.match(/\bText\s*\{/g) || []).length
  const blocks = source.split(/^\s*Text \{$/m).slice(1)
  assert.equal(blocks.length, declared,
    `${declared} Text elements declared, ${blocks.length} of them on their own line`)
  assert.ok(blocks.length >= 17, `expected the Text elements, found ${blocks.length}`)
  for (const [i, block] of blocks.entries()) {
    const head = block.split(/\n\s*\}/)[0]
    assert.match(head, /textFormat: Text\.PlainText/,
      `Text element ${i + 1} in Panel.qml does not declare textFormat`)
  }
  // Counted with the comments stripped, because this convention is explained
  // in one of them and would otherwise count itself.
  assert.equal((code.match(/textFormat:/g) || []).length, blocks.length)
  assert.equal(code.match(/textFormat: (?!Text\.PlainText)/), null)
})

test("no sentence is built by chaining arg", () => {
  // String.arg rescans what the previous call inserted, so a `%2` inside an
  // application's own window class swallows the title that was meant for it.
  // One call is safe however hostile its value; two are not.
  for (const name of ["Panel.qml", "Service.qml", "BarWidget.qml"]) {
    const code = readFileSync(join(__dirname, "..", name), "utf8").replace(/\/\/.*$/gm, "")
    assert.equal(code.match(/\.arg\([^\n]*\)\s*\.arg\(/), null,
      `${name} chains .arg() — use Rules.fillOnce`)
  }
})

test("fillOnce cannot read a value as a marker", () => {
  assert.equal(Rules.fillOnce("class %1 title %2", ["kitty", "vim"]), "class kitty title vim")
  // The value that breaks the chained form.
  assert.equal(
    Rules.fillOnce("class %1 title %2", ["chrome-ex.com__a%2Fb-Default", "MY_TITLE"]),
    "class chrome-ex.com__a%2Fb-Default title MY_TITLE")
  // And the trivial version of it: a class that is only the marker.
  assert.equal(Rules.fillOnce("%1 %2", ["%2", "T"]), "%2 T")
  // A marker with nothing to fill it is left alone rather than blanked.
  assert.equal(Rules.fillOnce("%1 %2", ["only"]), "only %2")
  assert.equal(Rules.fillOnce("%1", []), "%1")
})

test("shorten never cuts through a character", () => {
  // Two code units each, so a naive cut at an odd offset splits one in half and
  // the panel draws a replacement box.
  const emoji = "😀".repeat(200)
  for (let limit = 4; limit < 40; limit++) {
    const cut = Rules.shorten(emoji, limit)
    assert.ok(cut.length <= limit, `limit ${limit}`)
    for (const ch of cut) assert.notEqual(ch.codePointAt(0), 0xfffd)
    assert.equal(/[\ud800-\udbff]$/.test(cut.slice(0, -1)), false, `lone surrogate at limit ${limit}`)
  }
  assert.equal(Rules.shorten("abcdefghij", 5), "abcd…")
})

test("no untrusted value reaches a component Roost does not own", () => {
  // Setting textFormat only works on the elements this file declares. A shell
  // Button or ButtonGroup renders its label through a Text of its own, which
  // is AutoText like every default and cannot be reached from out here — so a
  // value from outside has to be made inert before it is handed over.
  //
  // This is the list of values Hyprland reports that Roost did not write. Add
  // to it when the panel starts showing another one.
  const untrusted = [
    /win\["class"\]/,
    /win\.title/,
    /workspace\.name/,
    /modelData\.name/,
    /service\.error/,
    /win\.monitor/,
    // Roost's own wording, but it interpolates a rule name into itself.
    /root\.notice/
  ]
  // Reading one of these, or clearing it, is not showing it. What counts is a
  // line that puts the value into something a component will render — so an
  // assignment is judged by what it stores, not by what it stores into.
  const displays = /\b(text|label|tooltipText):|\.arg\(/
  const source = readFileSync(join(__dirname, "..", "Panel.qml"), "utf8")
  let seen = 0
  for (const { line, inside } of enclosingElements(source)) {
    const bare = line.replace(/\/\/.*$/, "")
    const assignment = bare.match(/^\s*[\w.[\]"']+\s*=(?!=)\s*(.*)$/)
    const value = assignment ? assignment[1] : bare
    if (!untrusted.some((p) => p.test(value))) continue
    // The nearest *named* element, skipping the JavaScript blocks a
    // multi-line `text:` binding opens: a line inside one of those is still
    // inside the Text that declares it.
    const element = inside.filter(Boolean).pop()
    const rendered = element === "Text" || displays.test(value)
    if (!rendered) continue
    seen++
    if (element === "Text") continue
    assert.match(value, /Rules\.inertText\(/,
      `an untrusted value outside a Text is not made inert:\n${line}`)
  }
  assert.ok(seen >= 8, `expected to find the untrusted values, found ${seen}`)
})
