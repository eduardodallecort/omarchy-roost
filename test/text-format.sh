#!/usr/bin/env bash
#
# That a window title cannot make the shell fetch a URL.
#
# The panel displays the class and the title of whatever window is in front,
# and both are chosen by that window's application — a web page sets its own
# title with one line of JavaScript. QML's `Text` defaults to `Text.AutoText`,
# which decides per string whether it is markup, so a title shaped like an
# `<img>` tag is parsed as one and its source is fetched over the network by
# the long-lived shell process.
#
# `test/rules.test.js` checks that every `Text` in `Panel.qml` declares
# `Text.PlainText`, and that every untrusted value handed to a component the
# plugin does not own goes through `Rules.inertText`. That is source
# inspection: it assumes those two things work. This renders them and watches a
# socket.
#
# The first case is a control that must *fail* closed — a default `Text` that
# does fetch. Without it a broken beacon would report every case as safe.
#
# Needs `qml6` from qt6-declarative, which Quickshell depends on, and python3
# for the listener. Skips without them unless ROOST_REQUIRE_QS is set, which is
# how CI turns the skip into a failure.

set -uo pipefail

cd "$(dirname "$0")/.."
plugin=$PWD

require() {
  command -v "$1" > /dev/null 2>&1 && return 0
  if [[ -n ${ROOST_REQUIRE_QS:-} ]]; then
    echo "ROOST_REQUIRE_QS is set and there is no $1 on PATH" >&2
    exit 1
  fi
  echo "no $1 on PATH; skipping (set ROOST_REQUIRE_QS to make this fatal)"
  exit 0
}

require qml6
require python3

work=$(mktemp -d)
trap 'rm -rf "$work"; kill %1 2> /dev/null' EXIT

pass=0
fail=0

check() {
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n        wanted: %s\n        got:    %s\n' "$1" "$3" "$2" >&2
  fi
}

# ------------------------------------------------------------- the listener
#
# Port 0 so two copies of the suite can run at once, and so a port left open by
# a previous run cannot make this one look safe. Every request is a line in
# hits; the QML side names each case in its path.
cat > "$work/beacon.py" <<'PY'
import http.server, socketserver, sys

hits, port_file, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(hits, "a") as f:
            f.write(self.path + "\n")
        self.send_response(404)
        self.end_headers()
    def log_message(self, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.timeout = 0.5
    for _ in range(limit):
        server.handle_request()
PY

: > "$work/hits"
python3 "$work/beacon.py" "$work/hits" "$work/port" 40 &

for _ in $(seq 20); do
  [[ -s $work/port ]] && break
  sleep 0.2
done
port=$(cat "$work/port" 2> /dev/null)

if [[ -z $port ]]; then
  echo "the listener never came up" >&2
  exit 1
fi

# ---------------------------------------------------------------- the probe
#
# The payload is the shape a real one would take: something innocent to read
# followed by the tag, so the title looks ordinary in every other window list
# on the machine.
cat > "$work/probe.qml" <<QML
import QtQuick
import "$plugin/lib/Rules.js" as Rules

Window {
  id: probe

  width: 600
  height: 400
  visible: true

  readonly property string hostile:
    'My Bank — Login<img src="http://127.0.0.1:$port/%1.png">'

  // Control: this one must fetch, or the checks below prove nothing.
  Text { text: probe.hostile.arg("CONTROL") }

  // What every Text in Panel.qml now declares.
  Text {
    y: 40
    text: probe.hostile.arg("PLAINTEXT")
    textFormat: Text.PlainText
  }

  // What Panel.qml hands to a shell Button or ButtonGroup, which renders it
  // through a Text this plugin cannot set textFormat on. Deliberately left at
  // the default here: inertText has to survive the guess, not avoid it.
  Text { y: 80; text: Rules.inertText(probe.hostile.arg("INERT")) }

  // The same for a class, which is what actually reaches those labels.
  Text {
    y: 120
    text: Rules.inertText('<img src="http://127.0.0.1:$port/CLASS.png">')
  }

  Timer { interval: 2500; running: true; onTriggered: Qt.quit() }
}
QML

QT_QPA_PLATFORM=offscreen qml6 "$work/probe.qml" > "$work/qml.log" 2>&1
sleep 2

fetched() { grep -qF "/$1.png" "$work/hits"; }

if fetched CONTROL; then
  check "a default Text fetches the URL in a hostile title" "yes" "yes"
else
  echo "the control never fetched — the probe did not render, so nothing below is evidence" >&2
  sed -n '1,20p' "$work/qml.log" >&2
  exit 1
fi

fetched PLAINTEXT && got=fetched || got=silent
check "Text.PlainText does not fetch" "$got" "silent"

fetched INERT && got=fetched || got=silent
check "inertText does not fetch, at a Text left on AutoText" "$got" "silent"

fetched CLASS && got=fetched || got=silent
check "inertText does not fetch for a hostile window class" "$got" "silent"


echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
