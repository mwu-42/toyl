# Integrating toyl into Oyl

Instructions for the agent working on Oyl (`~/Oyl`). Read all of this before you change anything, then
read "Keeping in step" at the end: toyl keeps changing, and that section is how Oyl follows it.

## The goal

toyl is the owner's to-do app: a separate Mac app at `~/toyl`, installed as `~/Applications/toyl.app`. It
covers what Oyl's to-do features cover (tasks, ideas, groupings of lists, timers) and more.

- **When toyl is present**, Oyl uses toyl for to-dos, ideas, groupings and timers, and hides its own copies of
  those features (details below).
- **When toyl is absent**, Oyl keeps every built-in exactly as it works today: its tod integration, the ideas
  page, the projects page and outline, its own timers. Someone without toyl must not notice any change.
- **A setting** lets the owner choose: on by default when toyl's file exists; off goes back to the built-ins.

Constraints:
- Don't change toyl's file format, and don't edit anything in `~/toyl`.
- Don't commit unless the owner asks. Follow Oyl's commit style when they do.
- Oyl's working tree has uncommitted work that isn't yours (`GitHubGrid.swift`, changes to `Activity`,
  `Awake`, `Features`, `NotchWindow`, `SettingsPage`, the README). Leave it as it is and build on top of it.
- **Never launch, relaunch or activate Oyl or toyl while testing.** The owner doesn't want their desktop pulled
  around. Test headlessly (see Testing), and ask the owner when a check has to happen on screen.
- Keep Oyl's README in its own voice: one plain paragraph per change, describing what the feature does now.
- Words, wherever Oyl shows toyl's things: a task's sub-items are its **sublist** (never "steps"); toyl has no
  aims (it reads "by fri" as a deadline).

## toyl as it is now

What Oyl will meet, briefly:
- **The app** opens on "all" (everything open, grouped by list), with inbox, today, ideas and timers. Its window
  has a calendar panel (Google Calendar, direct, as a day, week or month), the to-dos, and a details panel.
- **Timers** offer 10m, 30m, 1h, 6h and 24h, and start at 30m when nothing else says.
- **Sections**: swiping a task left moves it into its list's "in progress" section, which toyl adds to the list
  if it hasn't one. It's an ordinary section in the file.
- **Tasks tied to calendar events**: put on the calendar from toyl (kept in step both ways), or tied to an
  existing event by dragging the event onto the task (the task follows the event; toyl never writes to it).
- **Email**: toyl can pull important mail (a package to pick up, something due) into its inbox as tasks.
- **The iPhone**: toyl serves its own home-screen page from the Mac, on port **47650**, paired separately
  from Oyl's phone remote (which uses 47640). Don't listen on 47650.
- **Agents** reach toyl through `toyl` (the command), `toyl mcp`, and `toyl.md`.

## A reference patch exists

`~/toyl/docs/oyl-toyl-integration.patch` covers the data layer and the timers.
- It was made against Oyl at `e4f789e`. On 2026-11-23 it still applied cleanly to Oyl's working tree (at
  `67307ed`, with the uncommitted work above): `git apply --check` passes. Check again before using it.
- It was compiled with Oyl's full sources and tested with a harness built from Oyl's real `TodStore`,
  `TodQuick`, `TodRepeat` and `Timers` code against a toyl-format file.

Start from it, or reimplement it if Oyl has moved on. It does this:

- **`TodStore.swift`**
  - `find()` prefers toyl's file when `~/Library/Application Support/toyl/toyl.json` exists, and falls back to
    tod's app as today. `Disk` gets an `init(folder:file:backup:port:app:)`: toyl's file is saved straight to
    disk under the same folder `flock` (there is no server), and backed up to `toyl.backup.json` at most every
    ten minutes.
  - Error messages name whichever app's data it is.
  - A `#name` with no matching list makes a new list with **one** section ("to do") in toyl's file, instead of
    tod's three lanes. The file is identified by its top-level `"toyl": 1` key, via `Boards.isToyl`.
  - New `@Published toylTimers: [TimerStore.Mirrored]`, parsed from toyl's `timers` array. Only countdowns.
  - New `saveToylTimer(_:)`. Through `Boards.apply` it writes timer changes back:
    - **shown:** marks the timer `"oyl": true`, so toyl leaves the ringing to Oyl.
    - **changed:** label, duration, `endsAt` and `pausedLeft`.
    - **stopped:** removes the timer, logs it in `timerLog` (latest 50 kept), and adds the seconds to its
      task's `spent` when it ran 30 seconds or more.
- **`Timers.swift` (`TimerStore`)**
  - `mirror(_:)` adds and updates toyl's countdowns among `timers`, and removes the ones toyl dropped. It holds a
    timer on the notch if toyl set `pin`.
  - Mirrored timers aren't persisted in UserDefaults; they come back from toyl's file.
  - `onMirroredChange` reports pause, extend, edit, cancel and finish back to toyl's file. A finished one is
    remembered in `rangMirrored`, so it never rings twice.
- **`NotchWindow.swift` (`NotchState.init`)** wires `tod.$toylTimers` to `timers.mirror` and
  `timers.onMirroredChange` to `tod.saveToylTimer`.
- **`README.md`** gets one paragraph. Rewrite it once the full integration below is done.

## toyl's data (what you may and may not touch)

Everything is in `~/Library/Application Support/toyl/`. `TOYL_HOME` overrides the folder; honour it too.

| file | Oyl may |
| --- | --- |
| `toyl.json` | read, and write under the lock (below) |
| `toyl.md`, `.toyl.md.stamp` | not touch: toyl writes them, and reads edits made to `toyl.md` |
| `calendar.json` | read only: the next 15 days of the calendars the owner shows in toyl |
| `calendar-rules.json`, `CALENDAR.md`, `AGENTS.md` | read only |
| `mail.json` | not touch: which inboxes toyl reads, and which messages it has judged |
| `toyl.backup.json`, `backups/` | leave alone, apart from the ten-minute backup rule when you save |

**Writing `toyl.json`:**
- `flock(LOCK_EX)` on the folder (open the folder `O_RDONLY`).
- Read the latest file and make your change on that copy.
- Replace the file whole (`Data.write(.atomic)`), pretty-printed with sorted keys and without escaped slashes,
  as `Boards.data(laidOut: true)` already does.

Keep every field you don't know. The format is the v3 format `TodStore.Boards` already reads, plus:

- **Top level:** `toyl: 1`, `groups: [{id, name}]`, `filters: [{id, name, query}]`, `timers: [...]`,
  `timerLog: [...]`, `settings: {weekStart}` (0 sunday, 1 monday).
- **List:** `group?` (a group id), `notes?`, `archived?`, `projects?: [{id, name, notes?}]` (the big pieces of work
  in the list; a task's `project` names one of them).
  - The `inbox` and `dump` lists always exist; toyl shows `dump` as "ideas".
  - toyl lowercases these default names when it reads the file: Inbox, Brain dump, Unsorted, To do, In
    progress, Done, Next up, Waiting on.
  - A list may have an "in progress" section that toyl added. Treat it like any section.
- **Task:**
  - `tags?: [String]`, `pinned?`, `someday?` (put off: toyl shows it under ideas, in its own list)
  - `subtasks` is the task's **sublist** (say "sublist" if Oyl shows it)
  - `duration?` (minutes): now only the length its timer and calendar event get; toyl doesn't show it
  - `spent?` (seconds timed), `updatedAt` (ms)
  - `event?: {id, calendar, follows?}`: its Google Calendar event. Without `follows`, toyl put it there and keeps
    the two in step both ways; with `follows: true`, the owner tied the task to an event that already existed,
    and the task takes the event's day and time
  - `source?`: where it came from (`toyl`, `iphone`, `email`, `calendar`, `cli`, `mcp`, `link`, `drop`…)
  - `email?: {account, id, from, subject, link?}`: the email it was pulled from (`source: "email"`)
  - `canvas?: {id, course, url?}`: the Canvas assignment it's for (`source: "canvas"`)
  - `target?` (an aim): toyl no longer sets or shows it, but keep it
  - Oyl's own `kept`, `repeat`, `repeated` and `repeatOf` are kept. toyl brings a repeating task back the same
    way Oyl does, and marks the done one `repeated`.
- **Timer:**
  - `{id, label, task?, kind, duration, endsAt?, pausedLeft?, startedAt, elapsed, runningSince?, pin, oyl?}`
  - `id` is a UUID string, as Oyl's `ReminderTimer.id` is. `kind` is `"countdown"` or `"stopwatch"`.
  - Moments are milliseconds; durations are seconds.

**toyl's command** (`~/.local/bin/toyl`, or `~/Applications/toyl.app/Contents/MacOS/toyl`) does everything
with `--json`, and honours `TOYL_HOME`:
- `toyl add --json "essay fri 5pm #cs"`, `toyl done <id>`
- `toyl timer start <task or label> 30m --json`, `toyl timers --json`
- `toyl ls "<filter>" --json` (for example `is:email`, `due:today`, `in:cs`), `toyl agenda --json`

Using it keeps one parser. toyl's quick add understands much more than Oyl's `TodQuick`: `#list` or `#tag`,
`~list`, "by fri" and "next week" (as deadlines), repeats, `~30m` lengths, `!` pins, ` // ` notes, `/timer 30m`.

**Detecting toyl:** use it when `toyl.json` exists in toyl's folder (and the setting is on). Show its pieces
only while that's true. If the file goes away, fall back to the built-ins.

## What to change, feature by feature

Each: what it does with toyl, and what it does without.

- **The data layer (`TodStore`).** Apply the patch's version.
  - Expose `source: .toyl | .tod | .none` so views can tell which one they're showing.
  - Without toyl, everything stays as it is.
- **The setting.**
  - Add a feature in `Features.swift`, for example `useToyl` ("toyl"). Its hover help: "with toyl installed,
    Oyl's to-dos, ideas, timers and projects are toyl's."
  - Add a row for it on the settings page (`SettingsPage.swift`).
  - Default: on when toyl's file exists. Off makes Oyl ignore toyl completely.
- **The notch's to-do field.**
  - With toyl: hand the typed line to `toyl add --json` (a `Process`; about 50 ms), so it parses exactly as
    toyl would. Fall back to `TodStore.add` if the command isn't there or fails.
  - Without toyl: as now.
- **The ideas page.** It already works on the `dump` list through `TodStore`, so it works with toyl's file.
  - With toyl: drop any wording about tod. Ideas are toyl's ideas; "?" in toyl's quick add makes one.
  - Without toyl: as now.
- **Projects page, outline window and quick entry** (`Projects.swift`, `ProjectsPage.swift`,
  `ProjectsWindow.swift`). These duplicate toyl's lists and groups.
  - With toyl: hide the projects tab, its page, the outline window and its menu items (`Projects…` on the
    notch's right-click). Pressing tasks come from toyl: the soonest open dated tasks from `TodStore`.
  - Without toyl: unchanged.
  - `~/Library/Application Support/Oyl/Projects/Projects.json` doesn't exist on the owner's Mac, so nothing to
    migrate. If it ever does, offer to move it into toyl only when the owner asks.
- **Timers.**
  - With toyl:
    - Mirror toyl's countdowns, as in the patch.
    - Start new countdowns in toyl too, so there's one timer system. "25m essay" typed into Oyl's timers page
      (or a gesture, or the phone remote) becomes `toyl timer start "essay" 25m --json`, or a timer written
      under the lock. The mirror then shows it.
    - A timer with no length said gets toyl's: 30 minutes. toyl's lengths are 10m, 30m, 1h, 6h and 24h; offer
      those where Oyl offers a toyl task a choice of lengths.
    - Keep `ReminderParser` for reading what's typed. Snooze or "one more" on a toyl timer starts it in toyl.
  - Without toyl: `TimerStore` as now.
- **Reminders for timed tasks.** toyl rings only timers. Oyl's projects reminders (the notch opens with a chime;
  +10 min, OK, Done) are the right surface.
  - With toyl: ring them for toyl tasks that have a `due` and a `time`, **except tasks with an `event`**: those
    are calendar items, and the owner wants no reminders for calendar events unless they ask.
  - "Done" goes through `TodStore.toggle`.
  - Keep the "reminded" state on Oyl's side (UserDefaults keyed by task id and time). Don't add fields to toyl's
    tasks.
  - Missed while Oyl was off: ring if it's within 12 hours, as projects reminders do now.
- **The work log.** "What's been done today" reads done tasks through `TodStore`, so it works with toyl. Word it
  as toyl's when the source is toyl.
- **The phone remote.**
  - Its ideas and timers go through `TodStore` and `TimerStore`, so they work with toyl. Its timers start in toyl
    when the source is toyl (see Timers).
  - toyl has its own phone page for adding tasks and timers. Oyl's remote keeps what's Oyl's (agents and their
    requests, music, keeping awake, the log). Don't copy toyl's page into Oyl.
- **The calendar bar** (`Calendar.swift`, EventKit).
  - With toyl: read toyl's `calendar.json` instead. It holds the owner's Google calendars, their labels, and the
    events of the calendars they show in toyl (floor meetings already left out, per their rules). It needs no
    calendar permission and shows what toyl shows. toyl rewrites it every few minutes while it's open; its
    `updated` key is in milliseconds.
  - Fall back to EventKit when `calendar.json` is missing or more than 30 minutes old.
  - Without toyl: EventKit as now.
- **Email tasks.** Where Oyl lists toyl's tasks, a task with `source: "email"` can carry a small ✉. Nothing
  else to do: toyl does the pulling.

"Remove the parts related to toyl" means: with toyl present, hide Oyl's duplicates (the projects page, outline
and window; Oyl-only timers; tod discovery). Don't delete their code: users without toyl still need it.

## Testing (headless; never on screen)

- **Point Oyl at a scratch list.** Make Oyl's toyl detection honour `TOYL_HOME`. Fill the scratch list with
  toyl's command: `TOYL_HOME=/tmp/t toyl add "x fri"`, `TOYL_HOME=/tmp/t toyl timer start x 1m`.
- **Use a harness, as the patch's test did.** Compile `TodStore.swift`, `TodQuick.swift`, `TodRepeat.swift` and
  `Timers.swift`, a stub for `Haptics`, and a small `@main` that drives `TodStore(root:port:)` (or the toyl path,
  through `TOYL_HOME`), `TimerStore(defaults: UserDefaults(suiteName: "test"))`, `mirror` and
  `onMirroredChange`. Then inspect the JSON on disk.
- **Check it compiles without touching the installed app:** `swiftc -Onone -swift-version 5 -parse-as-library
  -target arm64-apple-macos14.2 Sources/*.swift -o /tmp/OylCheck`. Don't run `build.sh` while Oyl is running
  unless the owner asks: it replaces `build/Oyl.app`, and `--run` relaunches Oyl.
- **Don't open, relaunch or `osascript activate` Oyl or toyl, and don't open `toyl://` links.**

## Done when

- With toyl installed and the setting on:
  - The notch's to-do field, ideas page, work log and phone remote all work on toyl's list.
  - toyl's countdowns show and ring on the notch; pausing or stopping one there does the same in toyl.
  - New timers started in Oyl appear in toyl, at toyl's 30m when no length is said.
  - Tasks with a time ring on the notch, but not tasks tied to a calendar event.
  - The calendar bar shows what toyl's `calendar.json` holds.
  - The projects page and outline are gone.
- With the setting off, or toyl not installed, Oyl behaves exactly as before.
- toyl's file keeps every field through any number of Oyl edits. Check with a diff of `toyl.json` before and
  after.
- Oyl compiles with no new warnings in the files you touched, and the README describes the result in Oyl's voice.
- `~/Oyl/.toyl-sync` holds the number of the latest entry in `~/toyl/docs/oyl-changes.md` (see below).

## Keeping in step with toyl

toyl will keep changing. So Oyl doesn't drift:
- **toyl's side:** every toyl change that matters to Oyl (the file's format, the folder's files, the command's
  output, timers, ports) gets a numbered entry in `~/toyl/docs/oyl-changes.md`, saying what changed and what
  Oyl should do about it.
- **Oyl's side:** `~/Oyl/.toyl-sync` holds the number of the last entry Oyl has taken in (commit it with the
  work that took it in).
- **Seeing what's new:** `~/toyl/docs/oyl-sync/pending.sh` prints the entries Oyl hasn't taken in yet (nothing
  when it's up to date). `docs/oyl-sync/README.md` has a Claude Code command (`/toyl-sync`) and a session-start
  hook that use it.
- When you finish this integration, write the latest entry's number into `~/Oyl/.toyl-sync`.
