#!/usr/bin/env bash
#
# Compile what Roost writes.
#
# The unit tests check that the generator produces the *string* it should. This
# checks the only thing that actually matters about that string: that Lua can
# parse it. Hyprland embeds Lua and requires the generated file at the end of
# the user's config, so a file that does not parse is not a plugin that fails —
# it is a Hyprland config that fails, on someone else's machine.
#
# The class names below are the ones that break naive escaping: dots that are
# regex syntax, backslashes that are Lua escape syntax, quotes that end the
# literal, and a bracket that would close a long string.

set -euo pipefail

cd "$(dirname "$0")/.."

LUAC=""
for candidate in luac5.4 luac luac5.3 luac5.1; do
  if command -v "$candidate" > /dev/null 2>&1; then
    LUAC="$candidate"
    break
  fi
done

if [[ -z $LUAC ]]; then
  echo "no luac on PATH; install lua5.4 to run this check" >&2
  exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

node -e '
const { readFileSync, writeFileSync } = require("node:fs")
const vm = require("node:vm")

const Rules = vm.createContext({})
vm.runInContext(
  readFileSync("lib/Rules.js", "utf8").replace(/^\s*\.(pragma|import)\b.*$/gm, ""),
  Rules, { filename: "Rules.js" })

const MONITORS = [{ id: 0, name: "M", x: 0, y: 0, width: 3440, height: 1440, reserved: [0, 26, 0, 0] }]

const CLASSES = [
  "Signal",
  "org.gnome.Nautilus",
  "steam_app_battlenet",
  "chrome-web.whatsapp.com__-Default",
  "a\\\\b",
  "quote\"inside",
  "bracket]]end",
  "paren(group)",
  "plus+star*question?",
  "dollar$caret^",
  "brace{1,2}",
  "pipe|alt",
  "slash/path",
  "tab\there",
  "unicode-é-日本語"
]

const rules = []
CLASSES.forEach((cls, i) => {
  const win = Rules.normalizeWindow({
    address: "0x" + i,
    class: cls,
    title: cls + " — a \"window\" \\ title",
    at: [100 + i, 200],
    size: [900, 700],
    floating: i % 2 === 0,
    monitor: 0,
    workspace: { id: i + 1, name: i === 3 ? "special:magic" : (i === 5 ? "my space" : String(i + 1)) }
  }, MONITORS)
  const rule = Rules.buildRule(win, Rules.defaultSelection(win), {
    id: "r" + i,
    matchMode: i % 3 === 0 ? "window" : "app",
    silent: i % 4 === 0
  })
  if (rule) {
    if (i % 5 === 0) rule.enabled = false
    rules.push(rule)
  }
})

if (rules.length < 10) {
  console.error("expected the generator to produce rules for most classes, got " + rules.length)
  process.exit(1)
}

writeFileSync(process.argv[1] + "/rules-on.lua", Rules.rulesToLua(rules, true))
writeFileSync(process.argv[1] + "/rules-off.lua", Rules.rulesToLua(rules, false))
writeFileSync(process.argv[1] + "/rules-empty.lua", Rules.rulesToLua([], true))
console.log("generated " + rules.length + " rules")
' "$out"

for file in "$out"/*.lua; do
  # `hl` does not exist outside Hyprland, so the file is compiled, not run:
  # -p parses and reports syntax errors without executing anything.
  "$LUAC" -p "$file"
  echo "ok: $(basename "$file")"
done

echo "all generated Lua compiles"
