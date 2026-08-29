#!/usr/bin/env bash
#
# Exercise the two shell scripts Roost reads and writes its files with.
#
# They live as string literals in Service.qml, which no unit test can reach and
# no QML test can point a hostile filesystem at. They are also the part of Roost
# that faces the one thing it cannot trust: two files in a directory writable by
# everything running as the user. So they are extracted from the QML and run
# here, against the shapes that break a naive implementation — a symlink to
# something enormous, a device that never ends, a named pipe that never opens, a
# temporary name somebody got to first.
#
# Extracted rather than duplicated on purpose. A copy of the script in this file
# would pass this test forever while the one that ships drifted away from it.

set -euo pipefail

cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Pull `readonly property string <name>: [ '...', '...' ].join("\n")` out of the
# QML and print the script it builds.
extract() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync("Service.qml", "utf8")
    const start = src.indexOf("property string " + process.argv[1] + ":")
    if (start < 0) throw new Error("no such property: " + process.argv[1])
    const open = src.indexOf("[", start)
    const close = src.indexOf("].join", open)
    if (open < 0 || close < 0) throw new Error("not an array literal: " + process.argv[1])
    const lines = src.slice(open + 1, close)
      .split("\n")
      .map(l => l.trim().replace(/,$/, ""))
      .filter(l => l.startsWith("'"'"'") && l.endsWith("'"'"'"))
      .map(l => l.slice(1, -1))
    if (!lines.length) throw new Error("empty script: " + process.argv[1])
    process.stdout.write(lines.join("\n"))
  ' "$1"
}

READ_SCRIPT=$(extract _readScript)
WRITE_SCRIPT=$(extract _writeScript)

LIMIT=$((1024 * 1024))
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

# `timeout` is not part of the script: Service.qml wraps both of them in it
# from the command array, with the same seconds used here.
read_file() {
  set +e
  timeout 5 bash -c "$READ_SCRIPT" roost "$1" "$LIMIT" > "$work/out" 2> /dev/null
  local code=$?
  set -e
  return $code
}

write_file() {
  set +e
  printf '%s' "$2" | timeout 10 bash -c "$WRITE_SCRIPT" roost "$1" 2> /dev/null
  local code=$?
  set -e
  return $code
}

echo "reading"

printf 'the-rules' > "$work/plain.json"
read_file "$work/plain.json" && rc=0 || rc=$?
check "a plain file is read" 0 "$rc"
check "and its content arrives whole" "the-rules" "$(cat "$work/out")"

read_file "$work/absent.json" && rc=0 || rc=$?
check "a file that does not exist says so, distinctly" 10 "$rc"

# The case the size check has to be bound to a descriptor for. `stat` on the
# path measures the *link* — seven bytes, comfortably inside a megabyte — while
# whatever opens the path afterwards follows it to the whole file.
head -c $((LIMIT * 2)) /dev/zero > "$work/enormous.bin"
ln -s "$work/enormous.bin" "$work/link-to-enormous.json"
read_file "$work/link-to-enormous.json" && rc=0 || rc=$?
check "a symlink pointing at something enormous is refused" 12 "$rc"
check "and nothing was read from it" 0 "$(wc -c < "$work/out")"

ln -s "$work/plain.json" "$work/link-to-plain.json"
read_file "$work/link-to-plain.json" && rc=0 || rc=$?
check "a symlink pointing at a real store is still read" 0 "$rc"

read_file "$work/enormous.bin" && rc=0 || rc=$?
check "a file over the ceiling is refused" 12 "$rc"

read_file /dev/zero && rc=0 || rc=$?
check "a device that would never end is refused" 11 "$rc"

read_file "$work" && rc=0 || rc=$?
check "a directory is refused" 11 "$rc"

mkfifo "$work/pipe.json"
read_file "$work/pipe.json" && rc=0 || rc=$?
check "a named pipe nobody writes to gives up rather than hanging" 124 "$rc"

head -c "$LIMIT" /dev/zero > "$work/exact.bin"
read_file "$work/exact.bin" && rc=0 || rc=$?
check "a file exactly at the ceiling is read" 0 "$rc"
check "and all of it arrives" "$LIMIT" "$(wc -c < "$work/out")"

echo "writing"

mkdir -p "$work/state"
write_file "$work/state/rules.json" '{"rules":[]}' && rc=0 || rc=$?
check "a new file is created" 0 "$rc"
check "with the content given" '{"rules":[]}' "$(cat "$work/state/rules.json")"

write_file "$work/state/rules.json" 'replaced' && rc=0 || rc=$?
check "an existing file is replaced" 0 "$rc"
check "with the new content" "replaced" "$(cat "$work/state/rules.json")"

# The target being a symlink is the footgun: a writer that follows it writes
# Roost's Lua into whatever it aims at. Renaming over the name replaces the
# link itself and leaves the file it pointed at alone.
printf 'not ours\n' > "$work/bystander"
ln -s "$work/bystander" "$work/state/roost.lua"
write_file "$work/state/roost.lua" 'rules go here' && rc=0 || rc=$?
check "writing through a symlinked target does not follow it" 0 "$rc"
check "the file it pointed at is untouched" "not ours" "$(cat "$work/bystander")"
check "and the name now holds what was written" "rules go here" "$(cat "$work/state/roost.lua")"
check "the symlink is gone" "no" "$([[ -L $work/state/roost.lua ]] && echo yes || echo no)"

mkdir -p "$work/readonly"
chmod 500 "$work/readonly"
write_file "$work/readonly/rules.json" 'nope' && rc=0 || rc=$?
check "a directory that cannot be written to reports the failure" 21 "$rc"
chmod 700 "$work/readonly"

before=$(find "$work/state" -name '.roost.*' | wc -l)
check "no temporary files are left behind" 0 "$before"

if (( failures )); then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall file I/O checks passed\n'
