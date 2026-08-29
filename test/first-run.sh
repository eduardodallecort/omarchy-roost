#!/usr/bin/env bash
#
# What happens on a machine that has never run Roost.
#
# The unit tests cover the pure half of this — a missing store reads as switched
# on with no rules, an empty rule set still produces a loadable file — and pass
# whatever the shell does with those answers. This runs the real `Service.qml`
# under Quickshell against a home directory that does not exist yet, and checks
# the wiring: that the service finishes loading rather than waiting forever for
# a file that will never arrive, that a first install writes the Hyprland file
# and *no* store, that it does not reload the compositor to install an empty
# file, and that the first save then produces both files.
#
# Every one of those is currently guaranteed by a comment. A plugin that depends
# on a state file existing is the ordinary way a first install breaks, and it
# breaks only for people who do not have the file — never for whoever wrote it.
#
# Needs `qs` (Quickshell) and a session to run in, so it is not part of CI:
# ubuntu-latest has neither. Run it before publishing, and after touching
# anything in Service.qml's loading or repair paths.

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
        if (root.mode === "save") svc.capture()
      }
      if (root.tick === 5 && root.mode === "save")
        root.say("saved", svc.remember({ tiling: true, size: true, workspace: true }, {}))
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
    FAKE_CLIENTS="$work/clients.json" FAKE_MONITORS="$work/monitors.json" \
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

if (( failures )); then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall first-run checks passed\n'
