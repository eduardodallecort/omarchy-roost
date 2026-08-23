.pragma library

// Everything that turns a live Hyprland window into a permanent rule, and
// permanent rules into the Lua file Hyprland reads.
//
// This is a library rather than QML because it is the part that can be wrong
// in ways nothing reports: a mis-escaped class matches no window, a
// mis-escaped Lua string is a syntax error in the user's Hyprland config, and
// a window whose position is read against the wrong monitor opens off-screen.
// Kept here, it runs under `node --test` without a compositor.

// ---------------------------------------------------------------- constants

// Hyprland matches window rules with std::regex (ECMAScript grammar). A class
// is a literal, so every character the grammar would read as syntax has to be
// escaped before it goes in a pattern.
var REGEX_METACHARACTERS = /[.*+?^${}()|[\]\\\/]/g

// A floating window this close to its monitor's centre is treated as centred,
// and gets `center = true` instead of fixed coordinates. Windows are dragged
// into place by hand and land a few pixels out; a rule that says "centred"
// survives a monitor change, while one that says "at 812, 341" does not.
//
// The tolerance is for that hand-dragging slop and nothing else. Hyprland
// centres inside the reserved-adjusted area rather than the raw monitor, so
// the comparison below uses the same area; measured against a 3440x1440
// monitor with a 26 px bar, `center = true` lands a window exactly on the
// usable centre, not 13 px above it.
var CENTRE_TOLERANCE = 24

// Hyprland's own name for a window with no class. Rules cannot match it in any
// useful way, so Roost refuses rather than writing one that matches everything.
var UNMATCHABLE = ""

var ASPECT_WORKSPACE = "workspace"
var ASPECT_TILING = "tiling"
var ASPECT_SIZE = "size"
var ASPECT_POSITION = "position"


// Every rule is written as a pair: one rule that tags the matching windows,
// and one keyed on that tag that does the work.
//
// It looks like a detour and it is the whole reason Roost's rules take effect.
// Hyprland resolves tag-matched rules ahead of class-matched ones regardless
// of file order, so a plain class rule from Roost loses to any tag rule
// Omarchy already has — measured: btop opened at 875x600, the size Omarchy's
// `floating-window` tag carries, while Roost's rule asked for 1375x1000.
// Between two *tag* rules the later one wins, also measured, and Roost's file
// is loaded last. Routing through a tag of its own therefore beats every
// Omarchy tag without Roost having to know any of their names or take one
// away from a window that other rules may also be keyed on.
//
// Ordinary class rules do override each other in file order; that part was
// never the problem.
var TAG_PREFIX = "roost-"

// Ceilings on everything that arrives from outside this file.
//
// A plugin does not run beside the desktop, it runs inside it: one process owns
// the bar, the panels, the lock screen and the polkit agent. An input with no
// upper bound does not degrade Roost, it degrades the session — so the store,
// the generated file and the compositor's own output are all read against a
// limit rather than in full.
//
// The numbers are generous against real use and small against harm. A rule
// serializes to roughly 300 bytes, so a megabyte is some three thousand of
// them; a client entry from `hyprctl -j clients` is roughly 700, so four
// megabytes is several thousand windows. Nothing legitimate approaches either.
var MAX_STORE_BYTES = 1024 * 1024
var MAX_GENERATED_BYTES = 1024 * 1024
var MAX_CAPTURE_BYTES = 4 * 1024 * 1024
var MAX_CLIENTS = 2000

var MATCH_APP = "app"
var MATCH_WINDOW = "window"

// ------------------------------------------------------------------ escaping

// Escape a literal string for use inside a Hyprland match pattern.
function escapeRegex(value) {
  return String(value).replace(REGEX_METACHARACTERS, "\\$&")
}

// Escape a string for a Lua double-quoted literal.
//
// Lua 5.4 rejects unknown escape sequences outright, so a lone backslash in a
// class name — which every escaped regex has — is not a cosmetic problem: it
// makes the file fail to parse, and a Hyprland config that fails to parse is a
// broken desktop. Backslash and quote are doubled; anything below space is
// written as a decimal escape rather than passed through.
function luaString(value) {
  var text = String(value)
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    var code = text.charCodeAt(i)
    if (ch === "\\") out += "\\\\"
    else if (ch === "\"") out += "\\\""
    else if (ch === "\n") out += "\\n"
    else if (ch === "\r") out += "\\r"
    else if (ch === "\t") out += "\\t"
    // Zero-padded on purpose: Lua reads up to three digits after a backslash,
    // so an unpadded "\\7" followed by a digit is swallowed into one escape and
    // "a<BEL>5b" becomes "a\\75b", which Lua reads as "aKb" — a pattern that
    // matches nothing, silently.
    else if (code < 0x20 || code === 0x7f) out += "\\" + ("00" + code).slice(-3)
    else out += ch
  }
  return "\"" + out + "\""
}

// Text safe to put after `--` in the generated file.
//
// The comment above each rule is the one place a stored value reaches the Lua
// without going through luaString, and a comment only runs to the end of its
// line. A name carrying a newline therefore ends the comment and drops whatever
// follows at the top level of a file Hyprland requires — a config that does not
// parse, from a store this file's own header promises to treat as hostile.
// Verified by feeding the generator a rule named "Evil\nprint(1) --".
function commentText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\r\n\u2028\u2029]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

// A whole-string match for one literal class or title.
function anchoredPattern(value) {
  return "^(" + escapeRegex(value) + ")$"
}

// ------------------------------------------------------------------- windows

// Reduce one `hyprctl clients -j` entry, plus the monitor it sits on, to the
// facts a rule is built from.
//
// `at` is absolute across the whole layout while Hyprland's `move` rule is
// relative to the monitor the window opens on, so the monitor origin is
// subtracted here rather than at serialization time, where the monitor is no
// longer in scope.
function normalizeWindow(client, monitors) {
  if (!client || typeof client !== "object") return null

  var cls = typeof client["class"] === "string" ? client["class"] : ""
  var title = typeof client.title === "string" ? client.title : ""
  var at = Array.isArray(client.at) ? client.at : [0, 0]
  var size = Array.isArray(client.size) ? client.size : [0, 0]
  var monitor = monitorFor(client, monitors)

  var x = finiteOr(at[0], 0)
  var y = finiteOr(at[1], 0)
  var width = Math.max(0, Math.round(finiteOr(size[0], 0)))
  var height = Math.max(0, Math.round(finiteOr(size[1], 0)))

  return {
    address: typeof client.address === "string" ? client.address : "",
    "class": cls,
    title: title,
    floating: client.floating === true,
    width: width,
    height: height,
    // Monitor-relative, which is the frame `move` is expressed in.
    x: Math.round(x - (monitor ? finiteOr(monitor.x, 0) : 0)),
    y: Math.round(y - (monitor ? finiteOr(monitor.y, 0) : 0)),
    workspace: normalizeWorkspace(client.workspace),
    monitor: monitor ? String(monitor.name || "") : "",
    // The area Hyprland actually places windows in — the monitor minus
    // whatever the bar and any other layer surface reserved. Everything a
    // rule says about position is measured against this, because it is what
    // Hyprland measures `center = true` against.
    usable: usableArea(monitor),
    // A window with no class cannot be matched by anything narrower than
    // "every window", so it is reported rather than silently turned into a
    // rule that would reshape the whole desktop.
    matchable: cls !== UNMATCHABLE
  }
}

// Classes belonging to the shell itself. Roost is opened from the bar, and a
// rule about the surface the user opened Roost with is never what they meant.
var SHELL_CLASSES = ["org.quickshell", "quickshell"]

// Every window Roost could be about, most recently focused first.
//
// Hyprland numbers each client by how recently it was focused, so ordering by
// that puts the window the user was last in at the front and the one before it
// next — which is what makes stepping through the list useful rather than
// arbitrary. The focus *history* is read instead of live focus because opening
// Roost moves keyboard focus to a layer surface: "what is focused now" would
// answer with the panel, or with nothing.
function candidateClients(clients) {
  if (!Array.isArray(clients)) return []
  var eligible = []
  // A row ceiling as well as the byte ceiling on the way in: a JSON array that
  // parsed is not a JSON array worth walking in full, and everything past the
  // limit would be ordered behind thousands of windows nobody is looking at.
  var limit = Math.min(clients.length, MAX_CLIENTS)
  for (var i = 0; i < limit; i++) {
    var client = clients[i]
    if (!client || typeof client !== "object") continue
    if (client.mapped === false) continue
    if (SHELL_CLASSES.indexOf(String(client["class"] || "")) !== -1) continue
    var rank = parseInt(client.focusHistoryID, 10)
    // A client Hyprland gave no focus history sorts last rather than being
    // dropped: it is still a window the user might want to place.
    eligible.push({ client: client, rank: isFinite(rank) ? rank : Infinity, seen: i })
  }
  eligible.sort(function (a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    return a.seen - b.seen
  })
  var out = []
  for (var j = 0; j < eligible.length; j++) out.push(eligible[j].client)
  return out
}

// The workspaces on screen right now — one per monitor, plus any special
// workspace a monitor happens to be showing.
//
// This is the frame the window picker is scoped to, rather than "the focused
// workspace". On one monitor the two are the same thing. On two they are not:
// the other monitor is showing a different workspace, its windows are in front
// of the user, and a picker that left them out would be denying the existence
// of something they are looking at.
function visibleWorkspaceIds(monitors) {
  var ids = {}
  var found = 0
  if (!Array.isArray(monitors)) return null
  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    if (!monitor) continue
    var active = monitor.activeWorkspace
    if (active && isFinite(parseInt(active.id, 10))) { ids[parseInt(active.id, 10)] = true; found++ }
    // Hyprland reports id 0 for "no special workspace here".
    var special = monitor.specialWorkspace
    var specialId = special ? parseInt(special.id, 10) : NaN
    if (isFinite(specialId) && specialId !== 0) { ids[specialId] = true; found++ }
  }
  // Knowing nothing is not the same as knowing nothing is on screen. An empty
  // set would be truthy and would filter every window away, leaving a picker
  // that is empty for no stated reason; null opens the scope instead.
  return found ? ids : null
}

// The candidates as Roost describes them.
//
// Two things are dropped. A window with no class cannot be narrowed down to
// anything less than "every window", so offering it would lead to a dead end.
// And, unless asked otherwise, anything not currently on screen: Roost is for
// windows you have just arranged, and stepping past twenty windows on eight
// workspaces to reach one of the three in front of you is the picker being in
// the way rather than helping.
function candidateWindows(clients, monitors, options) {
  var opts = options || {}
  var visible = opts.everywhere === true ? null : visibleWorkspaceIds(monitors)
  var list = candidateClients(clients)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var client = list[i]
    if (visible) {
      var ws = client.workspace ? parseInt(client.workspace.id, 10) : NaN
      if (!isFinite(ws) || !visible[ws]) continue
    }
    var win = normalizeWindow(client, monitors)
    if (win && win.matchable) out.push(win)
  }
  return out
}

// A class shortened to fit a control that cannot elide.
//
// Chromium web apps produce classes like
// `chrome-discord.com__channels_@me-Default`, which is four times the length of
// anything a native app reports. Left whole in a button label it pushes the
// control past the edge of the card, because a Button's text is centred in a
// Row that simply grows.
function shortClass(value, limit) {
  var text = String(value || "")
  var max = parseInt(limit, 10)
  if (!isFinite(max) || max < 4) max = 20
  if (text.length <= max) return text
  return text.slice(0, max - 1) + "…"
}

function finiteOr(value, fallback) {
  var number = parseFloat(value)
  return isFinite(number) ? number : fallback
}

function monitorFor(client, monitors) {
  if (!Array.isArray(monitors)) return null
  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    if (!monitor) continue
    if (monitor.id === client.monitor) return monitor
    if (client.monitor !== undefined && String(monitor.id) === String(client.monitor)) return monitor
  }
  return null
}

// `hyprctl` reports a workspace as an id and a name. Hyprland's rule takes the
// name for a named workspace, the number for a numbered one, and the whole
// `special:...` string for a scratchpad, so the three are distinguished here
// instead of being guessed from the id's sign.
function normalizeWorkspace(workspace) {
  if (!workspace || typeof workspace !== "object") return null
  var name = workspace.name === undefined || workspace.name === null ? "" : String(workspace.name)
  var id = parseInt(workspace.id, 10)
  if (!name && isFinite(id)) name = String(id)
  if (!name) return null

  var kind = "numbered"
  if (name.indexOf("special") === 0) kind = "special"
  else if (!/^\d+$/.test(name)) kind = "named"

  return { id: isFinite(id) ? id : 0, name: name, kind: kind }
}

// The value Hyprland's `workspace` rule expects for this workspace.
function workspaceSelector(workspace) {
  if (!workspace) return ""
  if (workspace.kind === "special") return workspace.name
  if (workspace.kind === "named") return "name:" + workspace.name
  return workspace.name
}

// The area Hyprland places windows in, in the coordinates windows are reported
// in. A monitor Roost cannot identify yields a null area, and every position
// question then answers "not centred" rather than guessing against the wrong
// frame.
//
// `hyprctl monitors` mixes two coordinate spaces, which is the whole reason
// this function exists. Measured on a machine with one scaled screen and one
// unscaled:
//
//   eDP-1     width 2880  height 1800  scale 1.5  reserved [0,52,0,0]  x 0
//   HDMI-A-1  width 3440  height 1440  scale 1    reserved [0,26,0,0]  x 1920
//
// The bar is 26 logical pixels tall on both, so `reserved` is scaled along with
// `width` and `height` — all three are the monitor's own pixels. `x` is not:
// HDMI-A-1 sits at 1920, which is eDP-1's *logical* width (2880 / 1.5), so
// positions are already logical, and so are `client.at` and `client.size`.
// Dividing the first three by the scale puts everything in one space; leaving
// it out makes `isCentred` permanently false on any HiDPI screen, and a window
// the user centred gets fixed coordinates instead of `center = true`.
function usableArea(monitor) {
  if (!monitor) return null

  var scale = parseFloat(monitor.scale)
  if (!isFinite(scale) || scale <= 0) scale = 1

  var width = Math.round(finiteOr(monitor.width, 0) / scale)
  var height = Math.round(finiteOr(monitor.height, 0) / scale)
  if (width <= 0 || height <= 0) return null

  var reserved = Array.isArray(monitor.reserved) ? monitor.reserved : [0, 0, 0, 0]
  var left = Math.max(0, Math.round(finiteOr(reserved[0], 0) / scale))
  var top = Math.max(0, Math.round(finiteOr(reserved[1], 0) / scale))
  var right = Math.max(0, Math.round(finiteOr(reserved[2], 0) / scale))
  var bottom = Math.max(0, Math.round(finiteOr(reserved[3], 0) / scale))

  var usableWidth = width - left - right
  var usableHeight = height - top - bottom
  if (usableWidth <= 0 || usableHeight <= 0) return null

  return { x: left, y: top, width: usableWidth, height: usableHeight }
}

// A floating window is treated as centred when both axes land within
// CENTRE_TOLERANCE of the centre of the usable area. `center = true` then
// survives a resolution change, a different monitor, and a bar that grows a
// row taller; fixed coordinates survive none of those.
function isCentred(win) {
  if (!win || !win.usable) return false
  var area = win.usable
  var dx = Math.abs(win.x + win.width / 2 - (area.x + area.width / 2))
  var dy = Math.abs(win.y + win.height / 2 - (area.y + area.height / 2))
  return dx <= CENTRE_TOLERANCE && dy <= CENTRE_TOLERANCE
}

// ------------------------------------------------------------------- aspects

// Which aspects this window can be asked about at all.
//
// Size and position are offered only for a floating window: a tiled window's
// geometry belongs to the layout, so a rule stating it would be written,
// applied, and then immediately overruled — the worst kind of setting, one
// that reports success and does nothing.
function availableAspects(win) {
  if (!win) return []
  var available = [ASPECT_WORKSPACE, ASPECT_TILING]
  if (win.floating) available.push(ASPECT_SIZE, ASPECT_POSITION)
  return available
}

// What Roost proposes to remember before anyone touches a switch.
//
// A floating window is remembered whole, because someone who floated and
// placed a window did it on purpose. A tiled window is remembered only by
// where it belongs, because its shape is the layout's business and not the
// window's.
function defaultSelection(win) {
  var selection = {}
  var available = availableAspects(win)
  for (var i = 0; i < available.length; i++) selection[available[i]] = true
  // Tiled is the default for most windows, so a rule pinning it is usually
  // noise. Offered, not assumed.
  if (win && !win.floating) selection[ASPECT_TILING] = false
  return selection
}

// Keep the selection coherent after a chip is toggled.
//
// Size and position only mean anything on a floating window: Hyprland applies
// neither to a tiled one. So geometry implies floating, and turning floating
// off takes the geometry with it. Doing this in the panel rather than silently
// at write time means the user watches the floating chip light up instead of
// wondering why their rule grew a term.
function coerceSelection(selection, changedKey) {
  var next = {}
  for (var key in selection) next[key] = selection[key]

  if (changedKey === ASPECT_TILING && !next[ASPECT_TILING]) {
    next[ASPECT_SIZE] = false
    next[ASPECT_POSITION] = false
  } else if ((changedKey === ASPECT_SIZE || changedKey === ASPECT_POSITION)
             && (next[ASPECT_SIZE] || next[ASPECT_POSITION])) {
    next[ASPECT_TILING] = true
  }
  return next
}

// ---------------------------------------------------------------------- rule

// Build the stored form of a rule. Patterns are NOT baked in here: the raw
// class and title are kept so the rule can be re-read, re-described and
// re-serialized, and so a change to how matching is escaped fixes every
// existing rule rather than only the next one.
function buildRule(win, selection, options) {
  if (!win || !win.matchable) return null
  var opts = options || {}
  var chosen = selection || {}
  var matchMode = opts.matchMode === MATCH_WINDOW ? MATCH_WINDOW : MATCH_APP

  var aspects = {}
  var available = availableAspects(win)
  for (var i = 0; i < available.length; i++) {
    var aspect = available[i]
    if (!chosen[aspect]) continue

    if (aspect === ASPECT_WORKSPACE && win.workspace) {
      aspects.workspace = {
        selector: workspaceSelector(win.workspace),
        label: win.workspace.name,
        // Without `silent` Hyprland follows the window to its workspace. That
        // is what someone launching the app wants; someone parking a chat
        // window out of the way wants the opposite, so it is a choice and not
        // a constant.
        silent: opts.silent === true
      }
    } else if (aspect === ASPECT_TILING) {
      aspects.tiling = win.floating ? "float" : "tile"
    } else if (aspect === ASPECT_SIZE) {
      if (win.width > 0 && win.height > 0) aspects.size = [win.width, win.height]
    } else if (aspect === ASPECT_POSITION) {
      aspects.position = isCentred(win) ? { mode: "center" }
                                        : { mode: "at", x: win.x, y: win.y }
    }
  }

  if (!Object.keys(aspects).length) return null

  // Hyprland cannot size or place a tiled window, so geometry without floating
  // is a rule that would be written, applied, and do nothing. Size and position
  // are offered only for a window that was already floating, which is why
  // "float" is the right value here rather than a guess.
  if ((aspects.size || aspects.position) && !aspects.tiling) aspects.tiling = "float"

  return {
    id: String(opts.id || ""),
    name: appName(win),
    match: {
      "class": win["class"],
      title: matchMode === MATCH_WINDOW ? win.title : ""
    },
    aspects: aspects,
    enabled: true,
    createdAt: parseInt(opts.now, 10) || 0
  }
}

// Two rules collide when they match the same windows; the newer one replaces
// the older rather than stacking a second, half-contradictory rule behind it.
function ruleKey(rule) {
  if (!rule || !rule.match) return ""
  return String(rule.match["class"]) + "\u0000" + String(rule.match.title || "")
}

// A readable name for the window, for the panel and for the comment above the
// rule. The class is what actually matches, so it is what gets shown; a title
// is a caption, not an identity.
function appName(win) {
  if (!win) return ""
  var cls = String(win["class"] || "")
  if (!cls) return String(win.title || "")
  return cls
}

// ---------------------------------------------------------------- describing

// The rule in a sentence, which is the only form most people will ever read.
function describeRule(rule) {
  if (!rule || !rule.aspects) return ""
  var parts = []
  var aspects = rule.aspects

  if (aspects.tiling === "float") parts.push("floating")
  else if (aspects.tiling === "tile") parts.push("tiled")

  if (aspects.size) parts.push(aspects.size[0] + "×" + aspects.size[1])

  if (aspects.position) {
    if (aspects.position.mode === "center") parts.push("centred")
    else parts.push("at " + aspects.position.x + ", " + aspects.position.y)
  }

  if (aspects.workspace) {
    var where = "workspace " + aspects.workspace.label
    if (aspects.workspace.silent) where += " (without switching)"
    parts.push(where)
  }

  return parts.join(" · ")
}

// ----------------------------------------------------------------- Lua output

var FILE_HEADER = [
  "-- Roost — window rules captured from your desktop.",
  "--",
  "-- Written by the Roost plugin. Every rule here was made by arranging a",
  "-- window and asking Roost to remember it; edit them in the Roost panel,",
  "-- because anything typed into this file is lost the next time it saves.",
  "--",
  "-- Hyprland loads this automatically: Omarchy requires every .lua file in",
  "-- ~/.local/state/omarchy/toggles/hypr at the end of its config.",
  "--",
  "-- Each rule is a pair. The first line tags the windows it covers; the second",
  "-- is keyed on that tag and does the work. Hyprland resolves tag-matched rules",
  "-- ahead of class-matched ones whatever their order in the config, so a plain",
  "-- class rule here would lose to the tag rules Omarchy already ships — and",
  "-- between two tag rules the later one wins, which this file is.",
  ""
].join("\n")

var EMPTY_BODY = "-- No rules yet.\n"

// One rule as a `hl.window_rule` call.
//
// `hl.window_rule` rather than Omarchy's `o.window` helper: both produce the
// same rule, but `o` is defined by Omarchy's own Lua and `hl` is Hyprland's.
// A file that only needs `hl` still loads for someone who has rearranged their
// hyprland.lua, and a Lua error here does not break one plugin — it breaks the
// whole config, which is the desktop.
function ruleToLua(rule, index) {
  if (!rule || !rule.match || !rule.aspects) return ""

  var match = ["class = " + luaString(anchoredPattern(rule.match["class"]))]
  if (rule.match.title) match.push("title = " + luaString(anchoredPattern(rule.match.title)))

  var aspects = rule.aspects
  var position = parseInt(index, 10)
  var tag = TAG_PREFIX + (isFinite(position) && position >= 0 ? position + 1 : 1)

  var lines = []
  lines.push("-- " + commentText(rule.name + " · " + describeRule(rule)))
  lines.push("hl.window_rule({ match = { " + match.join(", ") + " }, tag = "
    + luaString("+" + tag) + " })")
  lines.push("hl.window_rule({")
  lines.push("  match = { tag = " + luaString(tag) + " },")

  if (aspects.tiling === "float") lines.push("  float = true,")
  else if (aspects.tiling === "tile") lines.push("  tile = true,")

  if (aspects.size) lines.push("  size = { " + aspects.size[0] + ", " + aspects.size[1] + " },")

  if (aspects.position) {
    if (aspects.position.mode === "center") lines.push("  center = true,")
    else lines.push("  move = { " + aspects.position.x + ", " + aspects.position.y + " },")
  }

  if (aspects.workspace) {
    var selector = aspects.workspace.selector + (aspects.workspace.silent ? " silent" : "")
    lines.push("  workspace = " + luaString(selector) + ",")
  }

  lines.push("})")
  return lines.join("\n")
}

// Comment a rule out without deleting it, so the file still shows what Roost
// knows and someone reading it can see why a rule is not taking effect.
function commentOut(lua, note) {
  return lua.split("\n").map(function (line) {
    return line.indexOf("--") === 0 ? line + " [" + note + "]" : "-- " + line
  }).join("\n")
}

// The whole file. Disabled rules are written as comments rather than dropped,
// so turning the switch back on is the only thing that has to be believed.
//
// `active` is the master switch. Switched off, the file is still written and
// still loaded — it just applies nothing. Removing the file instead would be
// indistinguishable from Roost being broken, and this way the reason is
// written where someone debugging their Hyprland config will find it.
function rulesToLua(rules, active) {
  var list = Array.isArray(rules) ? rules : []
  var off = active === false
  var blocks = []

  for (var i = 0; i < list.length; i++) {
    var rule = list[i]
    if (!rule) continue
    var lua = ruleToLua(rule, i)
    if (!lua) continue
    if (off) blocks.push(commentOut(lua, "Roost off"))
    else if (rule.enabled === false) blocks.push(commentOut(lua, "off"))
    else blocks.push(lua)
  }

  var body = blocks.length ? blocks.join("\n\n") + "\n" : EMPTY_BODY
  if (off) body = "-- Roost is switched off in its panel. Nothing below applies.\n\n" + body
  return FILE_HEADER + "\n" + body
}

// --------------------------------------------------------------- persistence

// Read the rule store back, discarding anything that is not a rule this
// version understands. A store is a file on disk that survives downgrades and
// hand-editing, so it is parsed as if it were hostile.
//
// `active` defaults to true, because the file not existing yet and the file
// saying "off" have to be different answers: a fresh install that read as
// switched off would look broken and give no hint why.
function parseStore(text) {
  var raw = String(text || "")
  // Oversized is not the same as unreadable, and neither is the same as empty.
  // An empty answer here would let the next save overwrite a store this code
  // could not read — so the caller is told, and refuses to write.
  if (raw.length > MAX_STORE_BYTES) {
    return { active: true, rules: [], oversized: true }
  }

  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    return { active: true, rules: [], oversized: false }
  }
  var list = parsed && Array.isArray(parsed.rules) ? parsed.rules : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var rule = sanitizeRule(list[i])
    if (rule) out.push(rule)
  }
  return {
    active: !(parsed && parsed.active === false),
    rules: out,
    oversized: false
  }
}

function sanitizeRule(candidate) {
  if (!candidate || typeof candidate !== "object") return null
  if (!candidate.match || typeof candidate.match !== "object") return null
  var cls = candidate.match["class"]
  if (typeof cls !== "string" || cls === UNMATCHABLE) return null

  var aspects = {}
  var source = candidate.aspects && typeof candidate.aspects === "object" ? candidate.aspects : {}

  if (source.tiling === "float" || source.tiling === "tile") aspects.tiling = source.tiling

  if (Array.isArray(source.size)) {
    var width = parseInt(source.size[0], 10)
    var height = parseInt(source.size[1], 10)
    if (isFinite(width) && isFinite(height) && width > 0 && height > 0) aspects.size = [width, height]
  }

  if (source.position && typeof source.position === "object") {
    if (source.position.mode === "center") {
      aspects.position = { mode: "center" }
    } else if (source.position.mode === "at") {
      var x = parseInt(source.position.x, 10)
      var y = parseInt(source.position.y, 10)
      if (isFinite(x) && isFinite(y)) aspects.position = { mode: "at", x: x, y: y }
    }
  }

  if (source.workspace && typeof source.workspace === "object") {
    var selector = String(source.workspace.selector || "")
    if (selector) {
      aspects.workspace = {
        selector: selector,
        label: String(source.workspace.label || selector),
        silent: source.workspace.silent === true
      }
    }
  }

  if (!Object.keys(aspects).length) return null

  return {
    id: String(candidate.id || ""),
    // Flattened here too, not only where it is written: a name with a newline
    // in it is not a name, and the panel would render it just as oddly.
    name: commentText(candidate.name || cls) || cls,
    match: { "class": cls, title: typeof candidate.match.title === "string" ? candidate.match.title : "" },
    aspects: aspects,
    enabled: candidate.enabled !== false,
    createdAt: parseInt(candidate.createdAt, 10) || 0
  }
}

function serializeStore(rules, active) {
  return JSON.stringify({
    version: 1,
    active: active !== false,
    rules: Array.isArray(rules) ? rules : []
  }, null, 2) + "\n"
}

// Replace any rule matching the same windows, otherwise append. Returns a new
// array; the caller's copy is never mutated in place, because QML only
// notices a list property that has been reassigned.
function upsert(rules, rule) {
  var list = Array.isArray(rules) ? rules.slice() : []
  if (!rule) return list
  var key = ruleKey(rule)
  for (var i = 0; i < list.length; i++) {
    if (ruleKey(list[i]) === key) {
      list[i] = rule
      return list
    }
  }
  list.push(rule)
  return list
}

function removeAt(rules, index) {
  var list = Array.isArray(rules) ? rules.slice() : []
  if (index < 0 || index >= list.length) return list
  list.splice(index, 1)
  return list
}

// Put a rule back where it was — the other half of forgetting one.
//
// Any rule matching the same windows is dropped first, so undoing a delete
// after having remembered the same app again replaces that newer rule rather
// than leaving two rules fighting over the same windows.
function insertAt(rules, rule, index) {
  var list = Array.isArray(rules) ? rules.slice() : []
  if (!rule) return list

  var key = ruleKey(rule)
  for (var i = list.length - 1; i >= 0; i--) {
    if (ruleKey(list[i]) === key) list.splice(i, 1)
  }

  var at = parseInt(index, 10)
  if (!isFinite(at) || at < 0 || at > list.length) at = list.length
  list.splice(at, 0, rule)
  return list
}

// Does a rule already cover this window, and is it the same rule?
function findRuleFor(rules, win, matchMode) {
  var list = Array.isArray(rules) ? rules : []
  if (!win) return -1
  var wanted = String(win["class"]) + "\u0000"
    + (matchMode === MATCH_WINDOW ? String(win.title || "") : "")
  for (var i = 0; i < list.length; i++) {
    if (ruleKey(list[i]) === wanted) return i
  }
  return -1
}
