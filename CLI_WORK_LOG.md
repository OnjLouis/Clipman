# Clipman CLI work log

Working notes for `ClipmanCli/`. The design authority is `clipman-cli-spec.md`;
this file records what happened, what is half-finished, and the decisions behind
work that is designed but not yet built.

---

## 2026-08-06 — interface discoverability, `u` switching, exit codes

### The bug that started it

A screen-reader user reported that the cursor kept landing "on the status line
one space after the colon" instead of on the highlighted row, and spent a session
trying to fix caret placement in the full-screen renderer.

The caret was never wrong. A `--debug` caret trace, reading the row text back off
the screen rather than reprinting what the code intended, proved the caret sat on
the selected row at the right column on every draw.

What was actually happening: `renderer = "line"` in the configuration, so
`clipman-cli` with no arguments ran the **line** interface, whose prompt
`Command (? for help): ` parks the cursor after the colon by design. The fix was
being attempted in the renderer that was not running.

**Root cause: nothing named the interface you were in.** Two interchangeable
interfaces shipped, and top-level help asserted

    menu     Open the accessible line-based history manager

which is wrong whenever `renderer = "tui"` and tells a reader there is nothing
else to look for. The project's own author did not know the second interface
existed.

### Shipped

- **Interface self-naming.** Line interface greets with `Clipman line
  interface.`; the full-screen one prepends `Full-screen interface.` to its
  opening status row. `?` in either describes the other.
- **`status` reports `Interface:`**, and `interface` under `--json`.
- **`printUsage` corrected** — `menu` no longer claims to be line-based and now
  says it is what runs when no command is given.
- **`u` switches interface**, confirmed in both directions, carrying
  `{Selected, Filter, Kind}` through `internal/ui/handoff`. Loaded database is
  handed over (`cliStore.handOver`, consumed once) so the switch does not go
  silent through a download and a PBKDF2 decrypt while the screen is down.
  Screen is created before the choice is saved; a config write failure costs the
  preference, not the session. `pick` refuses on both sides.
- **Exit code 4 narrowed.** `mapRuntimeError` used to fall through to 4, so a
  local decode failure surfacing through a network call path reported a network
  fault. Now falls to 1; 4 requires `net.Error`, a certificate-trust failure, or
  `server.StatusError` reporting 413/5xx. Needed a typed `server.StatusError`
  because the status code previously existed only inside a message string.

### Removed as spent scaffolding

- `CLIPMAN_TUI_CURSOR_COLUMN` — existed only until the caret could be checked
  against a real screen reader. It was, on NVDA, and it works.
- `CLIPMAN_TUI_DEBUG` env fallback — superseded by `--debug` / `--debug-log`,
  which cmd-versus-PowerShell quoting cannot defeat.

### Decisions worth not relitigating

- **Bare `clipman-cli` keeps launching `menu`.** Requiring `menu` manufactures a
  new failure mode (`unknown command`, exit 2) for the dominant daily action, and
  `printUsage` is ~30 lines of flat text with no headings or skip targets — a
  worse first contact than one self-identifying sentence.
- **`line` stays the shipped default.** The full-screen renderer can fail on
  limited terminals, and the line interface's transcript survives in scrollback
  for review-cursor navigation, which is itself an accessibility property.
- **No first-run-only messaging.** Output that differs between run N and N+1
  based on invisible state cannot be reproduced, re-read, or described to someone
  else.
- **`IsInteractive()` tests for a controlling terminal, not a tty on stdout.**
  `clipman-cli > out.txt` from a shell still launches the menu. Only cron, CI,
  and non-tty ssh get the usage path. Do not describe it as "scripts get help".

---

## Designed, not built: clip viewer, `w` save, `x` run

Requested: the full-screen interface's Enter "doesn't do much other than
display" when not piped. Wanted a full-clip viewer with paging and `q`, `w` to
write the clip to a file, and `x` to run a command against it.

### Built so far

- `internal/clipexec` — command-line parsing, `@clip` substitution, and the
  runner. 24 tests. The security-critical half, done.
- `internal/clipfile` — path resolution with `~/` expansion, existence checks,
  and a verbatim `0600` write. 10 tests.
- **The viewer**, wired and working: `v` opens it, arrows move a line at a time,
  Page Up/Down and space/`b` page, Home/End jump, `q` closes, Enter still emits.
  Rows are numbered by logical line with `+` marking continuations, wrapped by
  display width, control characters shown in caret notation.
- `drawLine` and `drawText` now advance by display width instead of one column
  per rune, so wide characters and combining marks no longer corrupt every
  column after them. This fixes the list too, where short ASCII previews were
  hiding it.
- `spaceAfterNumber` matches `+ ` as well as `. `, so the caret does not jump
  three columns left when a line wraps.
- `caretColumn` now derives from `currentRowText()`, which every mode answers —
  one place that knows what the caret is sitting on, the same shape as
  `promptParts`.

### Still to build

`w` is wired into the full-screen interface; `x` is not, and neither is wired
into the line interface. The packages underneath
them are done and tested; what remains is the prompt machinery, the mode
handling, and the announcements — including prompt line editing (item 5 below),
which `x` needs far more than the filter did.

### Constraints that are settled

- **Enter cannot change.** `pick --tui | ssh host 'cat > f'` depends on Enter
  emitting to stdout and exiting. The viewer gets its own key, `v`.
- **No shell, ever.** A clip is untrusted data. Substituting it into a command
  string for `sh -c` means a clip containing `; rm -rf ~` executes when the user
  asks to echo it. Command lines are split into argv here, the clip replaces
  whole arguments that are never re-split, and `os/exec` runs it directly.
- **Placeholder is `@clip`.** `$clip` promises shell expansion that is
  deliberately refused, so users would try `$HOME` and `"$clip"` and get
  literals. Braces are worse: at default punctuation verbosity many screen
  readers do not speak them, so `{clip}` and `clip` sound alike when reviewing
  what was typed, and an unclosed brace fails silently *and inaudibly*.
- **Refuse, do not warn**, on unquoted shell metacharacters and on `{}` /
  `{clip}` / `$clip` / `%clip%`. Quoting is the escape hatch, so a refusal fires
  only on the real mistake. Already implemented.
- **No placeholder → clip is piped to stdin.** Then close stdin or the child
  waits forever, and swallow `EPIPE` — `x head -1` exits early and that is
  success. With a placeholder, stdin is empty, never the console.

### Blocker found in review, must not be forgotten

**The child process's stdout must never be `os.Stdout`.** In
`pick --tui | ssh host 'cat > f'` there is a pipe on stdout; any child output
written there is injected into the payload and silently corrupts the file on the
far end. Capture buffer only. If a child is ever given a terminal it gets
`platform.OpenConsoleOutput()`, not `os.Stdout`.

### `x` output: capture, not `Screen.Suspend()`

tcell runs on the alternate screen, so `Resume()` repaints and everything the
child printed is gone — one unrepeatable pass at output, produced at whatever
rate the child produced it, with no scrollback. Captured output goes into the
viewer instead: navigable, re-readable. Do not ship both modes.

Run the child in a goroutine and `Screen.PostEvent` on completion so the event
loop keeps polling and Escape can kill it. No hard timeout; announce
`Still running, 20 seconds. Press Escape to stop it.` with a changing number so
the diff resends it. Cap capture at 1 MiB or `x yes` takes the process out.
Never put the clip in an environment variable — it may be a credential and env
is readable from `/proc`.

### Viewer design

Line-at-a-time with the caret on the current line, **not** page-at-a-time: a page
key repaints the content area and produces a screenful of speech, while a line
move rewrites two markers. Number every viewer row and put position in the row
(`-> 12. export PATH=...`), never announced separately — the number is spoken as
part of the row the caret lands on, so position costs no extra speech. Total goes
in the heading. Continuation rows of a wrapped logical line are `12+`. Track
position as logical line plus continuation index, never as a display-row ordinal,
or a resize moves the reader.

The `-> ` marker is load-bearing, not decoration: without it, moving down one row
dirties zero cells and the whole viewer bets on the screen reader announcing bare
cursor movement.

Suggested synthesis with the requested `more` behavior: keep space/PgDn paging
available, but make line motion primary.

### Caret-model work this requires

1. ~~`handleKey` falls through to `handleListKey`.~~ **Done.** `case modeView`
   added and tested; without it `d` in the viewer deleted the entry being read.
2. ~~Viewer needs its own position.~~ **Done.** `viewCursor`/`viewTop`, held as
   a logical line so a resize does not move the reader.
3. ~~`caretPosition`/`caretColumn` assume list geometry.~~ **Done.** Both go
   through `currentRowText()`, which every mode answers.
4. ~~`promptParts` must own the new prompts.~~ **Done for `w`.** File path,
   overwrite confirm, and a `modeNotice` whose prompt is the message. The
   running-state prompt arrives with `x`.
5. ~~**Prompt line editing.**~~ **Done.** `promptEditor` in `prompt.go` owns the
   typed line and the caret inside it; `promptParts` returns that offset and
   `caretPosition` uses it instead of `len(typed)`. Left, Right, Home, End,
   Delete, Ctrl+U, Ctrl+A, and Ctrl+E work in every prompt, shared through
   `editPrompt`. The caret rests on the character being edited, so moving back
   through a line reads it out. Any new prompt gets all of this for free.
6. ~~**Double-width runes.**~~ **Done, in two parts.** `drawLine`/`drawText`
   advance by display width and pass combining runes to the cell they modify.
   Caret columns were a separate half, missed the first time: `caretPosition`
   added a rune offset to a column, so a filter containing CJK left the caret
   short by one column per character, and `spaceAfterNumber` returned a rune
   index as a column. Both now measure display width.
7. ~~Sanitise control characters for display only.~~ **Done.** Caret notation
   for controls, tabs expanded, line endings normalised. Bytes written by `w`,
   piped to `x`, and emitted by Enter stay raw.

### Other rulings

- `w` and `x` bind in both list and viewer, acting on the selected entry; both
  resolve templates via `b.text(entry)` or they disagree with Enter about what
  "the clip" is. Prompts must name their target since the viewer shows no marker.
- `w`: no confirm on a new path (the path was typed), confirm on overwrite,
  write `0600` (a clip may be a credential), expand leading `~/`, no added
  trailing newline. Needs a dismissible `Saved 220 lines to ...` notice — the
  caret returns to the content row, so an ordinary status message is very likely
  never heard.
- `x`: no confirm. The user typed a whole command line; safety is structural.
- `pick` gets `v` (it mutates nothing and confirming *which* clip is about to go
  down the pipe is what `pick` most needs) but not `w` or `x`. The principle is
  "`pick` has exactly one output and its caller chose it."
- Render help through the viewer — `helpLines` already truncates silently on
  short terminals and has no navigation.

### Known pre-existing defect, prerequisite for parity

Line interface bare `NUMBER` calls `Console.Say(b.text(entry))` — a 5000-line
clip announced in one unstoppable block. Needs a paged sub-loop following the
`clip>` precedent in `addEntry`. Line spellings `v NUMBER`, `w NUMBER`,
`x NUMBER`, each collecting arguments at a sub-prompt to dodge `dispatch`'s
split-on-first-space.

### Verify on Windows before shipping

With no shell, `.cmd`/`.bat` targets may not run via `CreateProcess`, and Go
1.19+ removed cwd from `LookPath`, so `x ./script.sh` needs an explicit path.
Decide and document both rather than failing cryptically.

---

## Open items

- `debugRow` reserves one entry row permanently (`firstListRow = 5`) whether or
  not `--debug` is on — 19 rows instead of 20 on a 24-row terminal.
- Man page is unrendered; no `groff` on the development machine.
- macOS, Android, and iOS fixture generators absent — no Xcode, JDK, or reachable
  Mac.
- CI for build targets and checksum determinism (Phase 6 remainder).
- Full-screen interface exercised against NVDA on Windows only.
