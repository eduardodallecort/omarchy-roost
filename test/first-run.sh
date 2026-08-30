#!/usr/bin/env bash
#
# The real service against the state a machine actually has.
#
# The unit tests cover the pure half of this and pass whatever the shell does
# with their answers. This runs `Service.qml` under Quickshell against a home
# directory it has to cope with, and checks the wiring. Four of those:
#
#   - never run before: it finishes loading rather than waiting forever for a
#     file that will never arrive, writes the Hyprland file and *no* store, does
#     not reload the compositor to install an empty one, and the first save then
#     produces both. A plugin that depends on a state file existing is the
#     ordinary way a first install breaks, and it breaks only for people who do
#     not have the file — never for whoever wrote it.
#   - a window title two megabytes long: the save is refused rather than
#     written, because a store past the reading ceiling would be unreadable from
#     the next start, and unreadable refuses every save after that.
#   - a store already past that ceiling: read as unknown rather than as empty,
#     and left exactly as it is.
#   - a store inside its ceiling whose generated file is past *its* ceiling:
#     nothing is written and Hyprland is not reloaded, on this start or any
#     later one. Written, that file would be refused on the next read, reported
#     as empty, and written again — every start, for as long as the rule exists.
#
# Needs `qs` (Quickshell), which is why CI runs this job in an Arch container
# rather than on ubuntu-latest. Skips where there is no `qs`, so the suite still
# runs on a machine without it; ROOST_REQUIRE_QS turns that skip into a failure,
# which is what CI sets.

set -uo pipefail

cd "$(dirname "$0")/.."
plugin=$PWD

# Skipping is right for someone running the suite on a machine without
# Quickshell. In CI it would be the worst kind of green — a job reporting
# success for a check it never ran — so CI sets ROOST_REQUIRE_QS and the skip
# becomes a failure.
if ! command -v qs > /dev/null 2>&1; then
  if [[ -n ${ROOST_REQUIRE_QS:-} ]]; then
    echo "ROOST_REQUIRE_QS is set and there is no qs on PATH" >&2
    exit 1
  fi
  echo "no qs on PATH; skipping (set ROOST_REQUIRE_QS to make this fatal)"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

home=$work/home
state=$home/.local/state/omarchy/plugins/eduardodallecort.roost
toggles=$home/.local/state/omarchy/toggles/hypr

failures=0
check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# A compositor that answers with two fixed windows and records every reload,
# so "a fresh install does not reload Hyprland" is something this can assert
# rather than something the code claims.
mkdir -p "$work/bin"
cat > "$work/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"-j clients"*) cat "$FAKE_CLIENTS" ;;
  *"-j monitors"*) cat "$FAKE_MONITORS" ;;
  *reload*) echo reload >> "$FAKE_RELOADS" ;;
  *configerrors*) : ;;
esac
FAKE
chmod +x "$work/bin/hyprctl"

cat > "$work/clients.json" <<'FIXTURE'
[{"address":"0x1","class":"org.example.app","title":"Example","floating":true,
  "at":[882,433],"size":[1200,800],"workspace":{"id":5,"name":"5"},
  "monitor":0,"focusHistoryID":0}]
FIXTURE
cat > "$work/monitors.json" <<'FIXTURE'
[{"id":0,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1.0,
  "activeWorkspace":{"id":5,"name":"5"},"reserved":[0,26,0,0]}]
FIXTURE

# The probe instantiates the real service and prints what it settled on. `mode`
# decides whether it also saves a rule.
write_probe() {
  cat > "$work/plugin/probe.qml" <<'PROBE'
import QtQuick
import Quickshell
import "." as Plugin

ShellRoot {
  id: root
  property string mode: Quickshell.env("PROBE_MODE")
  property int tick: 0
  Plugin.Service { id: svc }
  function say(k, v) { console.log("PROBE " + k + "=" + v) }

  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      root.tick += 1
      if (root.tick === 3) {
        root.say("loaded", svc.loaded)
        root.say("unreadable", svc.storeUnreadable)
        root.say("rules", svc.ruleCount())
        root.say("active", svc.active)
        root.say("error", svc.error === "" ? "(none)" : svc.error)
        if (root.mode !== "idle") svc.capture()
      }
      if (root.tick === 5 && root.mode === "save")
        root.say("saved", svc.remember({ tiling: true, size: true, workspace: true }, {}))
      // Matched on the title, which is the only string here with no length of
      // its own: this is the save that has to be refused rather than written.
      if (root.tick === 5 && root.mode === "huge") {
        root.say("saved", svc.remember({ tiling: true }, { matchMode: "window" }))
        root.say("error", svc.error === "" ? "(none)" : "reported")
      }
      if (root.tick === 9) {
        root.say("rules", svc.ruleCount())
        root.say("applying", svc.applying)
        Qt.exit(0)
      }
    }
  }
}
PROBE
}

run() {
  rm -rf "$work/plugin"
  mkdir -p "$work/plugin/lib"
  cp "$plugin"/Service.qml "$plugin"/Panel.qml "$plugin"/BarWidget.qml "$work/plugin/"
  cp "$plugin"/lib/Rules.js "$work/plugin/lib/"
  write_probe
  env HOME="$home" PATH="$work/bin:$PATH" PROBE_MODE="$1" \
    FAKE_CLIENTS="${FAKE_CLIENTS_OVERRIDE:-$work/clients.json}" \
    FAKE_MONITORS="$work/monitors.json" \
    FAKE_RELOADS="$work/reloads" \
    timeout 60 qs -p "$work/plugin/probe.qml" 2>&1 | sed -n 's/.*PROBE //p'
}

said() { grep -q "^$1=$2\$" "$work/out"; }
# The last value printed for a key, not the first: the probe reports `rules`
# once on load and again after the save.
value() { sed -n "s/^$1=//p" "$work/out" | tail -n 1; }

echo "a home directory that has never seen Roost"

# Nothing exists: not the state directory, not the toggles directory, not
# either file. This is what `omarchy plugin add` leaves behind on a new machine.
rm -rf "$home"
mkdir -p "$home"
: > "$work/reloads"
run idle > "$work/out"

check "the service finishes loading"            "true"  "$(value loaded)"
check "the store is not called unreadable"      "false" "$(value unreadable)"
check "it starts with no rules"                 "0"     "$(value rules)"
check "and switched on, not off"                "true"  "$(value active)"
check "with nothing to report"                  "(none)" "$(value error)"
check "no rule store is written"                "no"    "$([[ -e $state/rules.json ]] && echo yes || echo no)"
check "the state directory is created anyway"   "yes"   "$([[ -d $state ]] && echo yes || echo no)"
check "the Hyprland file is written"            "yes"   "$([[ -s $toggles/roost.lua ]] && echo yes || echo no)"
check "Hyprland is not reloaded for an empty file" "0"  "$(wc -l < "$work/reloads")"
check "no temporary files are left"             "0"     "$(find "$home" -name '.roost.*' | wc -l)"

if command -v luac5.4 > /dev/null 2>&1 || command -v luac > /dev/null 2>&1; then
  luac=$(command -v luac5.4 || command -v luac)
  "$luac" -p "$toggles/roost.lua" 2> /dev/null
  check "the file it wrote is loadable Lua"     "0"     "$?"
fi

echo "starting a second time on what the first one left"

before_lua=$(md5sum < "$toggles/roost.lua")
: > "$work/reloads"
run idle > "$work/out"

check "it loads again"                          "true"  "$(value loaded)"
check "and rewrites nothing"                    "$before_lua" "$(md5sum < "$toggles/roost.lua")"
check "and does not reload Hyprland"            "0"     "$(wc -l < "$work/reloads")"
check "still no rule store"                     "no"    "$([[ -e $state/rules.json ]] && echo yes || echo no)"

echo "the first rule ever saved"

rm -rf "$home"
mkdir -p "$home"
: > "$work/reloads"
run save > "$work/out"

check "the save is accepted"                    "true"  "$(value saved)"
check "the store now exists"                    "yes"   "$([[ -s $state/rules.json ]] && echo yes || echo no)"
check "the service holds one rule"              "1"     "$(value rules)"
check "and the store on disk names the window"  "yes"   "$(grep -qF '"class": "org.example.app"' "$state/rules.json" && echo yes || echo no)"
# -F, because what the generator writes is `org\\.example\\.app`: the class is
# escaped for Hyprland's regex, and that backslash is then escaped again for the
# Lua literal. A pattern here would have to re-do both, and would go wrong
# quietly — it did, the first time this was written.
check "the Hyprland file names the window"      "yes"   "$(grep -qF 'org\\.example\\.app' "$toggles/roost.lua" && echo yes || echo no)"
check "and Hyprland was reloaded for it"        "yes"   "$([[ $(wc -l < "$work/reloads") -ge 1 ]] && echo yes || echo no)"
check "nothing is still being applied"          "false" "$(value applying)"
check "no temporary files are left"             "0"     "$(find "$home" -name '.roost.*' | wc -l)"

echo "a window whose title is two megabytes long"

# A title has no ceiling of its own — a web page picks it with one line of
# JavaScript, and only the whole capture's four megabytes bound it. Saved, it
# produced a store past the size Roost will read, so from the next start the
# store read as unreadable and unreadable refuses every save. One window title
# and the panel never writes again, taking every other rule with it.
rm -rf "$home"
mkdir -p "$home"
: > "$work/reloads"
huge=$(head -c 2000000 /dev/zero | tr '\0' 'T')
printf '[{"address":"0x1","class":"org.example.app","title":"%s","floating":true,
  "at":[882,433],"size":[1200,800],"workspace":{"id":5,"name":"5"},
  "monitor":0,"focusHistoryID":0}]\n' "$huge" > "$work/clients-huge.json"
FAKE_CLIENTS_OVERRIDE=$work/clients-huge.json run huge > "$work/out"

check "the save is refused"                     "false" "$(value saved)"
check "and it says why"                         "reported" "$(value error)"
check "no store is written"                     "no"    "$([[ -e $state/rules.json ]] && echo yes || echo no)"
check "the service still holds no rules"        "0"     "$(value rules)"
check "Hyprland is not reloaded"                "0"     "$(wc -l < "$work/reloads")"
check "no temporary files are left"             "0"     "$(find "$home" -name '.roost.*' | wc -l)"

echo "starting on a store larger than Roost will read"

# The other half of the same failure, and the reason the ceiling above matters:
# a store past the ceiling is not read as empty — it is read as unknown, and
# every save is refused while that holds, so nothing overwrites rules Roost
# cannot see. Planted directly here rather than produced by the bug, so the
# check outlives it.
rm -rf "$home"
mkdir -p "$state" "$toggles"
: > "$work/reloads"
# With a real rule inside it, so "reads as unknown" and "reads as empty" are
# distinguishable: both report zero rules, and only one of them is telling the
# truth about what is on disk.
printf '{"version":1,"active":true,"rules":[{"id":"r1","name":"kitty",
  "match":{"class":"kitty","title":""},"aspects":{"tiling":"float"},
  "enabled":true}],"pad":"%s"}\n' "$huge" > "$state/rules.json"
planted=$(md5sum < "$state/rules.json")
FAKE_CLIENTS_OVERRIDE= run save > "$work/out"

check "the store reads as unknown"              "true"  "$(value unreadable)"
check "the rule inside it is not reported"      "0"     "$(value rules)"
check "the save is refused"                     "false" "$(value saved)"
check "and the store is left exactly as it was" "$planted" "$(md5sum < "$state/rules.json")"

echo "a store Roost can read that would generate a file it cannot"

# The ceiling on the store does not imply the ceiling on the generated file. A
# class and a title are escaped for Hyprland's regex and then again for the Lua
# literal, so a metacharacter arrives four bytes wide: this store is 400 KB and
# parses into five ordinary rules, and the Lua it generates is 1.2 MB.
#
# Nothing here is hostile — a store like this is what an older Roost, with no
# ceiling on the save, would have written. What matters is the loop it used to
# start: the repair writes the oversized file, the reader refuses it on the next
# start and reports it as empty, and the repair writes it again. A rewrite and a
# compositor reload on every start, forever, with nothing on screen to say so.
rm -rf "$home"
mkdir -p "$state" "$toggles"
: > "$work/reloads"
fat='$.*+?'
for _ in $(seq 14); do fat="$fat$fat"; done      # doubling, not 16k appends
{
  printf '{"version":1,"active":true,"rules":['
  for i in 1 2 3 4 5; do
    [[ $i -gt 1 ]] && printf ','
    printf '{"id":"r%s","name":"kitty","match":{"class":"kitty","title":"%s"},' "$i" "$fat"
    printf '"aspects":{"tiling":"float"},"enabled":true}'
  done
  printf ']}\n'
} > "$state/rules.json"
FAKE_CLIENTS_OVERRIDE= run idle > "$work/out"

check "the store itself reads fine"             "false" "$(value unreadable)"
check "and holds its five rules"                "5"     "$(value rules)"
check "the oversized file is not written"       "no"    "$([[ -e $toggles/roost.lua ]] && echo yes || echo no)"
check "Hyprland is not reloaded"                "0"     "$(wc -l < "$work/reloads")"
check "and the panel is told"                   "reported" "$([[ $(value error) == "(none)" ]] && echo silent || echo reported)"
check "no temporary files are left"             "0"     "$(find "$home" -name '.roost.*' | wc -l)"

# The loop is what the check above is really about, so run it twice.
: > "$work/reloads"
FAKE_CLIENTS_OVERRIDE= run idle > "$work/out"
check "a second start writes nothing either"    "no"    "$([[ -e $toggles/roost.lua ]] && echo yes || echo no)"
check "and reloads nothing either"              "0"     "$(wc -l < "$work/reloads")"

if (( failures )); then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall first-run checks passed\n'
