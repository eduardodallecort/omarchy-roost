# Roost

Arrange a window the way you want it. Press Enter. It opens that way from now on.

Roost turns the window in front of you into a permanent Hyprland window rule,
without you writing one.

![The Roost panel: a heading reading org.omarchy.btop above the line "Floating
on workspace 5 · HDMI-A-1"; under "REMEMBER THAT IT OPENS" four filled chips
numbered 1 to 4 reading "floating", "1375×1000", "centred" and "workspace 5",
beside an unfilled one reading "without switching to it"; a choice between
"Every org.omarchy.btop window" and "Only this one"; a "Remember this window"
button; and below a separator, "REMEMBERED · 2" listing two rules already
saved](preview.webp)

## What it is for

Omarchy floats a fixed set of apps — btop, the terminals, the file pickers, the
portal dialogs — and hands every one of them the same 875×600. That is a sensible
default for a dialog. For anything you actually read, it costs you information.

Here is btop at that size. It shows **twelve of this machine's twenty-two CPU
threads**, fourteen processes, three of its six filesystems, and no command
column at all:

![The desktop on workspace 5 with btop open at Omarchy's default floating size:
a small window centred on the wallpaper, taking up about a quarter of an
ultrawide screen](screenshots/btop-default.webp)

Drag it to a size the screen can afford, open Roost, press Enter. From then on
it opens like this — **all twenty-two threads**, twenty-seven processes, every
filesystem, and the command line that started each process:

![The same desktop and workspace, with btop now opening at the 1375×1000 size
Roost remembered — still centred, but filling most of the width of the
screen](screenshots/btop-remembered.webp)

Nothing was configured to get there. The window was dragged to a size, and Roost
wrote the rule.

## The alternative

Hyprland has always been able to do this. Getting it to means opening
`~/.config/hypr/`, recalling the difference between `class` and `initialClass`,
writing a `windowrule`, reloading, discovering the pattern matches nothing, and
trying again — and then finding out that Omarchy's own rules quietly outrank
yours anyway, which took measuring a compositor to work out (see
[Where the rules live](#where-the-rules-live)).

Roost replaces all of that with the part you had already done: arranging the
window.

## How it goes

1. Drag, resize, float or send a window wherever it belongs.
2. Open Roost from the bar, or with a keybinding.
3. Roost shows what it would remember, already chosen sensibly. Drop anything
   you do not want by clicking its chip.
4. Enter.

The rule is live from that moment on: the next time that app opens, it opens
that way. Nothing is applied to windows already on screen, including the one you
just captured — it is already where the rule says it should be.

## Install

```bash
omarchy plugin add https://github.com/eduardodallecort/omarchy-roost.git --enable
```

The icon appears in the right-hand section of the bar. Move it with
`omarchy bar move eduardodallecort.roost <section>`.

### A keybinding

Roost is quicker on a key than in the bar, because the window you want to place
is usually the one you are already in. Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + R", "Remember this window",
  "omarchy-shell shell toggle eduardodallecort.roost ''")
```

`SUPER + <letter>` is Omarchy's window-verb tier — `T` floats, `O` pops out,
`W` closes — which is where this belongs: it is the verb you reach for straight
after arranging a window, not an app launch. `R` is free there; Omarchy's
reminders use `R` only in combination with `CTRL`.

Roost never writes that line for you. Editing your keybindings is your business,
and the plugin has no way to ask.

## Update

```bash
omarchy plugin update eduardodallecort.roost
omarchy restart shell
```

The restart is not optional. Updating fast-forwards the checkout, but the shell
compiles QML once at startup and does not hot-reload it, so until you restart
you are still running the old version. Your rules are untouched by an update.

## Remove

```bash
omarchy plugin remove eduardodallecort.roost
omarchy restart shell
```

That leaves your rules in place and still working, because they live in a file
Hyprland reads directly. To take them away as well:

```bash
rm ~/.local/state/omarchy/toggles/hypr/roost.lua
rm -rf ~/.local/state/omarchy/plugins/eduardodallecort.roost
hyprctl reload
```

## What it can remember

| Chip | What it writes | Offered when |
|---|---|---|
| floating / tiled | `float` or `tile` | always |
| 900×700 | `size` | the window is floating |
| at 210, 140 | `move`, relative to the monitor | the window is floating |
| centred | `center` | the window is floating and sitting on the centre |
| workspace 9 | `workspace` | the window is on a workspace |
| without switching to it | `workspace "9 silent"` | a workspace is being remembered |

**A tiled window is not offered a size or a position.** In a tiling layout those
belong to the layout, not the window: a rule stating them would be written,
applied, and immediately overruled. Float the window first if you want its shape
remembered too — `SUPER + T` toggles it.

**Size and position come with floating.** Picking either lights up the floating
chip, and turning floating off drops both. Hyprland does not size or place a
tiled window, so the three only mean anything together.

**Centred beats coordinates.** A floating window sitting on the centre of its
monitor is remembered as *centred* rather than as a pair of numbers, so the rule
still does the right thing on a different monitor, a different resolution, or
after the bar grows a row taller. Hyprland centres inside the usable area rather
than the raw monitor, and so does Roost's idea of what counts as centred — on a
HiDPI screen too, where `hyprctl` reports the monitor in its own pixels while
windows are reported in logical ones.

## Which window it is about

Roost opens on the window you were last in, which is the right one nearly every
time — you arranged it a second ago. When it is not, the header carries a
stepper (`‹ 2/4 ›`) and `←` / `→` walk through the others without leaving the
panel. The order is how recently each window was focused, so the one you want
is usually one step away.

**The stepper offers the windows that are on a screen, not every window you
have open.** Roost is for windows you have just arranged, and stepping past
twenty windows on eight workspaces to reach one of the three in front of you is
a picker getting in the way. On two monitors that means both screens' windows,
not just the focused workspace: the other monitor's windows are in front of you
too, and leaving them out would be denying something you are looking at.

To place a window that is not on screen, switch to it and open Roost again.

Stepping rebuilds the proposal from scratch. Carrying the chips over from the
window you were looking at would silently write *its* size onto a different
window.

## More than one monitor

**No rule Roost writes ever names a monitor.** That is deliberate, and it is
what makes unplugging one safe: there is nothing for a missing monitor to
invalidate.

What that leaves:

- **`workspace` keeps working.** Hyprland moves an orphaned workspace to a
  monitor that is still connected, so a rule saying "workspace 9" still puts
  the window on workspace 9 wherever that now lives.
- **`centred` is immune**, because it is resolved against whichever monitor the
  window actually opens on, at whatever resolution that monitor has. This is
  the main reason Roost prefers it to coordinates whenever a window is sitting
  near the middle.
- **`size` and `at x, y` are not.** They are plain numbers, measured against
  the monitor the window was on when you captured it. Capture a 1600×1000
  window at 2600, 300 on an ultrawide, then open that app with only a 1920×1080
  laptop screen attached, and the rule still asks for 1600×1000 at 2600, 300 —
  which is mostly off the side of that screen.

A monitor that comes back with the same name but a different resolution is the
same case: nothing looks the monitor up, so the numbers are simply applied to
whatever is there.

If you move between very different screens, prefer `centred` over `at x, y`,
and drop the `size` chip for anything you sized generously. A rule with only
`workspace` on it is completely portable.

## Every window of an app, or only one

By default a rule matches every window of the app, by class. The other option
matches this window, by class **and** title.

Titles are where window rules usually go wrong, so the panel says it where the
choice is made rather than burying it here: an app that renames its window after
opening — an editor showing a filename, a browser showing a page, a terminal
showing the running command — will not match a rule written against the title it
happened to have. Match one window only for apps whose titles are stable, like
a password manager's or a chat client's secondary windows.

## Where the rules live

Two files, both under `~/.local/state`, both entirely Roost's:

- `~/.local/state/omarchy/toggles/hypr/roost.lua` — the rules, as Hyprland reads
  them. Omarchy requires every `.lua` file in that directory at the very end of
  its config, after its own defaults and after your `~/.config/hypr/*.lua`, which
  is both why a Roost rule wins and why the plugin needs no line in anybody's
  `hyprland.lua`.
- `~/.local/state/omarchy/plugins/eduardodallecort.roost/rules.json` — the same
  rules in the form the panel reads. `roost.lua` is generated from it, and if the
  two ever disagree the next shell start regenerates the Lua from the JSON.

Both are readable, and `roost.lua` is meant to be read: ordinary
`hl.window_rule` calls with a comment above each one saying what it does. It is
not meant to be edited — the next save rewrites it.

Each rule is written as a **pair** — one call that tags the windows it covers,
one keyed on that tag that does the work:

```lua
-- org.omarchy.btop · floating · 1375×1000 · centred · workspace 5
hl.window_rule({ match = { class = "^(org\\.omarchy\\.btop)$" }, tag = "+roost-3" })
hl.window_rule({
  match = { tag = "roost-3" },
  float = true,
  size = { 1375, 1000 },
  center = true,
  workspace = "5",
})
```

That detour is the reason Roost's rules take effect. Hyprland resolves
tag-matched rules ahead of class-matched ones **whatever their order in the
config**, and Omarchy ships several: `floating-window` gives btop, the
terminals, the file dialogs and the portal a float, a centre and a fixed
875×600, and `chromium-based-browser` forces browser windows to tile. A plain
class rule from Roost loses to all of them even though Roost is loaded last.
Between two *tag* rules the later one wins — and Roost's file is the later one.

Routing through a tag of its own means Roost never has to know Omarchy's tag
names, never takes a tag away from a window other rules may also be keyed on,
and keeps working if Omarchy adds more.

Both halves were measured against a running compositor rather than reasoned
about: btop opened at 875×600 with a plain class rule asking for 1375×1000, and
at 1375×1000 once the rule went through a tag.

`~/.local/state` is not usually part of a dotfiles backup. If you want your rules
to survive a reinstall, copy `rules.json` somewhere that is.

**Roost never writes anywhere else.** Not `hyprland.lua`, not `shell.json`, not
your bindings, not your look-and-feel. The marketplace requires that a plugin
not overwrite your configuration without consent, and the way Roost meets it is
by having nothing of yours to overwrite.

## When something goes wrong

Every save runs `hyprctl reload` and then asks Hyprland whether the config still
parses. If Roost's file is the one it complains about, the previous file is put
back, Hyprland is reloaded again, and the panel says what happened. Because the
file is required last, an error in it cannot take your monitors, keybindings or
window rules with it — everything before it has already applied.

The list of remembered rules is bounded rather than endless: it shows as many
rows as the screen has room for, up to five, and scrolls past that with an
indicator on its right edge. `↑` `↓` scroll it as they move the cursor, and the
heading always states the real total — thirty rules read as "REMEMBERED · 30"
with five on screen.

Four things reach the shell process from outside Roost — the two files, the
window list, and Hyprland's answer to "did that config load" — and each is read
against a ceiling rather than in full. For the rule store that means refusing
one larger than a megabyte, one declaring more than five hundred rules, or a
name that turns out not to be a regular file at all. A store it would not read
is not a store it treats as empty — the panel says the rules are **unknown** rather than
none, and every save is refused for as long as that holds, because the one thing
worse than not showing your rules is overwriting them with nothing. The same
applies while the store is still being read, which on an ordinary machine is a
few milliseconds and on a stalled filesystem is not.

The ceilings hold in the other direction too: Roost does not write a file it
would refuse to read. A window title has no length of its own — the application
picks it — so a rule matched on a very long one would produce a store past the
size Roost reads, and from the next start that store would be unreadable, which
refuses every save and takes the rest of your rules with it. The save is refused
instead, at the moment you make it, with everything already remembered
untouched.

The same applies to the repair that runs at startup, and there it is not the
same ceiling: a class and a title are escaped for Hyprland's pattern and then
again for the Lua literal, so a store comfortably inside its own limit can
generate a rule file past that one. Rather than write it, Roost leaves both
files alone and says so — otherwise it would write a file it could not read
back, find it missing on the next start, and rewrite it again on every start
after that.

The switch beside the REMEMBERED heading turns every rule off at once without
forgetting any of them, which is the first thing to try when you are wondering
whether Roost is responsible for something. Switched off, the rules stay in
`roost.lua` as comments, so the file still says what Roost knows.

Forgetting a rule is one keystroke, so the panel keeps the last rule it removed
and offers an Undo beside the receipt line — or `u`. Both appear together, and
only once the change has actually reached the disk: if the write fails, the rule
stays in the list, the panel says why, and there is nothing to undo because
nothing happened. Reopening the panel clears it.

## Keys

| Key | What it does |
|---|---|
| Enter | remember the window |
| ← → | step to another open window |
| 1–9 | drop or restore the chip with that number |
| ↑ ↓ | move through the rules already remembered |
| space | turn the selected rule off or on |
| x | forget the selected rule |
| u | put back the rule you just forgot |
| Esc | close |

## Tests

```bash
node --test
./test/file-io.sh
./test/lua-syntax.sh
./test/first-run.sh      # needs Quickshell; skips without it
./test/text-format.sh    # needs qml6 and python3; skips without them
```

`node --test` covers the part that decides what a rule says: escaping a class
into a pattern and a pattern into a Lua literal, reading a window's geometry
against the right monitor and at the right scale, what is offered for a tiled
window versus a floating one, which windows the picker offers, the rule store
surviving a round trip, a corrupt file and a hostile one, the ceiling on every
input that reaches the shell process, and the shape of the tag pair. No
dependencies beyond Node's built-in runner.

`file-io.sh` points a hostile filesystem at the two shell scripts Roost reads
and writes its files with — a symlink to something enormous, a device that never
ends, a named pipe that never opens, a target symlinked at one of your own
files. The scripts are extracted from `Service.qml` rather than copied, so the
check cannot go on passing while the code it describes drifts away from it.

`lua-syntax.sh` compiles the generated Lua with `luac -p` for a set of class
names chosen to break naive escaping — dots, backslashes, quotes, `]]`, regex
metacharacters, non-ASCII. It needs `lua` installed. This check exists because
Roost's output is loaded by your Hyprland config: a syntax error there is not a
plugin that fails, it is a desktop that fails.

`first-run.sh` runs the real service against the state a machine actually has,
which is what the pure tests cannot reach. A home directory that has never seen
Roost: the service finishes loading rather than waiting for a file that will
never arrive, writes the Hyprland file and no store, does not reload the
compositor to install an empty one, and produces both files on the first save.
Depending on a state file that only exists once the plugin has been used is the
ordinary way a first install breaks — and it breaks only for people who do not
have the file, never for whoever wrote it. Then the three ways a file can be
the wrong size: a window title too long to store is refused rather than saved,
a store already past the reading ceiling is left exactly as it is, and a store
inside its ceiling whose generated file is past *its* ceiling is not written and
does not reload Hyprland — on that start or any later one.

It runs in CI, in an Arch container: the service opens no windows, so Quickshell
drives it headless with no compositor at all.

`text-format.sh` renders a window title written to attack the shell — an `<img>`
tag pointing at a listener on this machine — and checks that the socket stays
quiet. The first case in it is a control that must *fetch*, because a beacon
that has stopped working would otherwise report every case as safe.

Every number in this README that could drift was measured against a running
compositor rather than inferred, and each measurement is pinned in a test:

- `move` is relative to the monitor, not to the desktop.
- Hyprland centres inside the reserved area, so a centred window sits 13 px
  below the midpoint of a 1440 px screen with a 26 px bar.
- `hyprctl monitors` reports `width`, `height` **and** `reserved` in the
  monitor's own pixels while positions and window geometry are logical, so all
  three are divided by `scale`.
- A tag-matched rule beats a class-matched one whatever the file order; a later
  tag rule beats an earlier one; ordinary class rules override in file order.

## Notes

- Roost is a `service` plus a `panel` plus a `bar-widget`. The service holds all
  the state and is mounted once per plugin; a bar widget is built once per
  monitor, and two copies would be two writers racing over one config file.
- Nothing polls. The service does no work at all until you open the panel, and
  the panel asks Hyprland what is on screen exactly once per open.
- The window Roost describes is the one Hyprland's focus history puts first,
  which is the window you were last in. Opening the panel moves keyboard focus
  to a layer surface, so "what is focused right now" would answer with the
  panel; the history still answers with the window you arranged.
- No network access, no external services, no dependencies at runtime beyond
  `hyprctl`, which Omarchy already has.
- Every piece of text on the panel is drawn as plain text. A window's class and
  title are chosen by the application that owns the window — a web page writes
  its own title in one line of JavaScript — and QML's default is to guess, per
  string, whether it is markup. Guessed as markup, an `<img>` in a title is a
  URL the shell process fetches. The two labels Roost hands to a control it does
  not draw itself have those characters removed instead, since the property
  cannot be set from outside.
- Roost never writes a file it would refuse to read. The ceilings on both files
  apply in both directions, counted in bytes rather than characters, so a title
  long enough to make the store unreadable is refused at the save with the rest
  of your rules left alone.
- Both files are read through a descriptor Roost opened itself, and every
  decision — is this a regular file, is it within the ceiling, how many bytes
  come back — is made about that descriptor rather than about the name it was
  opened by. Measuring a path and then reopening it is a check on one file and a
  read of another, and a symlink defeats it without needing the race at all.
  They are written by creating a new file and renaming it over the old one, so a
  reader sees the whole of one version or the whole of the other, and a name
  pointed at something of yours gets replaced rather than followed.

## License

MIT — see [LICENSE](LICENSE).
