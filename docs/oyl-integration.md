# Integrating toyl into Oyl

Instructions for the agent working on Oyl (`~/Oyl`). Read all of this before you change anything.

## The goal

toyl is now the owner's to-do app: a separate Mac app at `~/toyl`, installed as `~/Applications/toyl.app`. It covers what Oyl's to-do features cover: tasks, ideas, groupings of lists, and timers.

1. **When toyl is present**, Oyl uses toyl for to-dos, ideas, groupings and timers, and removes its own copies of those features (details below).
2. **When toyl is absent**, Oyl keeps every built-in function exactly as it works today. This covers its tod integration, the ideas page, the projects page and outline, and its own timers. Someone without toyl must not notice any change.
3. Add **a setting** so the owner can choose. It is on by default when toyl is found, and off goes back to the built-ins.

Constraints:
- Don't change toyl's file format, and don't edit anything in `~/toyl`.
- Don't commit unless the owner asks. Follow Oyl's commit style when they do.
- **Never launch, relaunch or activate Oyl or toyl while testing.** The owner has asked not to have their desktop pulled around. Test headlessly (see Testing), and ask the owner when a check has to happen on screen.
- Keep Oyl's README in its own voice: one plain paragraph per change, describing what the feature does now.

## A reference patch exists

`~/toyl/docs/oyl-toyl-integration.patch` covers the data layer and the timers.
- It was made against Oyl at `e4f789e` and applies cleanly there (`git apply --check` passes).
- It was compiled with Oyl's full sources and tested with a harness built from Oyl's real `TodStore`, `TodQuick`, `TodRepeat` and `Timers` code against a toyl-format file.

Start from it, or reimplement it if Oyl has moved on. It does the following:

- **`TodStore.swift`**
  - `find()` prefers toyl's file when `~/Library/Application Support/toyl/toyl.json` exists, and falls back to tod's app as today. `Disk` gets an `init(folder:file:backup:port:app:)`: toyl's file is saved straight to disk under the same folder `flock` (there is no server), and backed up to `toyl.backup.json` at most every ten minutes.
  - Error messages name whichever app's data it is.
  - A `#name` with no matching list makes a new list with **one** section ("to do") in toyl's file, instead of tod's three lanes. The file is identified by its top-level `"toyl": 1` key, via `Boards.isToyl`.
  - New `@Published toylTimers: [TimerStore.Mirrored]`, parsed from toyl's `timers` array. Only countdowns are included.
  - New `saveToylTimer(_:)`. Through `Boards.apply` it writes timer changes back:
    - **shown:** marks the timer `"oyl": true`, so toyl leaves the ringing to Oyl.
    - **changed:** label, duration, `endsAt` and `pausedLeft`.
    - **stopped:** removes the timer, logs it in `timerLog` (latest 50 kept), and adds the seconds to its task's `spent` when it ran 30 seconds or more.
- **`Timers.swift` (`TimerStore`)**
  - `mirror(_:)` adds and updates toyl's countdowns among `timers`, and removes the ones toyl dropped. It holds a timer on the notch if toyl set `pin`.
  - Mirrored timers aren't persisted in UserDefaults; they come back from toyl's file.
  - `onMirroredChange` reports pause, extend, edit, cancel and finish back to toyl's file. A finished one is remembered in `rangMirrored`, so it never rings twice.
- **`NotchWindow.swift` (`NotchState.init`)** wires `tod.$toylTimers` to `timers.mirror` and `timers.onMirroredChange` to `tod.saveToylTimer`.
- **`README.md`** gets one paragraph. Rewrite it once the full integration below is done.

## toyl's data (what you may and may not touch)

Everything is in `~/Library/Application Support/toyl/`. `TOYL_HOME` overrides the folder; honour it too (see Testing).

| file | Oyl may |
| --- | --- |
| `toyl.json` | read, and write under the lock (below) |
| `toyl.md`, `.toyl.md.stamp` | not touch: toyl writes them, and reads edits made to `toyl.md` |
| `calendar.json` | read only: the next 15 days of the owner's Google Calendar, written by the toyl app |
| `calendar-rules.json`, `CALENDAR.md`, `AGENTS.md` | read only |
| `toyl.backup.json`, `backups/` | leave alone, apart from the ten-minute backup rule when you save |

**Writing `toyl.json`:**
1. `flock(LOCK_EX)` on the folder (open the folder `O_RDONLY`).
2. Read the latest file and make your change on that copy.
3. Replace the file whole (`Data.write(.atomic)`), pretty-printed with sorted keys and without escaped slashes, as `Boards.data(laidOut: true)` already does.

Keep every field you don't know. The format is the v3 format `TodStore.Boards` already reads, plus these additions:

- **Top level:**
  - `toyl: 1`
  - `groups: [{id, name}]`
  - `filters: [{id, name, query}]`
  - `timers: [...]`
  - `timerLog: [...]`
- **List:** `group?` (a group id), `notes?`, `archived?`.
  - The `inbox` and `dump` lists still exist; toyl shows `dump` as "ideas".
  - toyl lowercases these default names when it reads the file: Inbox, Brain dump, Unsorted, To do, In progress, Done, Next up, Waiting on.
- **Task:**
  - `tags?: [String]`, `pinned?`, `someday?`
  - `duration?` (minutes), `spent?` (seconds)
  - `updatedAt` (ms)
  - `event?: {id, calendar}`: the task's Google Calendar event
  - `source?`
  - Oyl's own `target`, `kept`, `repeat`, `repeated` and `repeatOf` are kept. toyl brings a repeating task back the same way Oyl does, and marks the done one `repeated`.
- **Timer:**
  - `{id, label, task?, kind, duration, endsAt?, pausedLeft?, startedAt, elapsed, runningSince?, pin, oyl?}`
  - `id` is a UUID string, as Oyl's `ReminderTimer.id` is.
  - `kind` is `"countdown"` or `"stopwatch"`.
  - Moments are milliseconds; durations are seconds.

**toyl's command** (`~/.local/bin/toyl`, or `~/Applications/toyl.app/Contents/MacOS/toyl`) does everything with `--json`:
- `toyl add --json "essay fri 5pm #cs ~2h"`
- `toyl done <id>`
- `toyl timer start <task or label> 25m --json`
- `toyl ls "<filter>" --json`
- `toyl agenda --json`

Using it keeps one parser. toyl's quick add understands much more than Oyl's `TodQuick`:
- `#list` or `#tag`, and `~list`
- aims ("by fri", "next week")
- repeats, `~30m` lengths, `!` pins, ` // ` notes

It honours `TOYL_HOME`.

**Detecting toyl:** use it when `toyl.json` exists in toyl's folder (and the setting is on). Show its pieces only while that's true. If the file goes away, fall back to the built-ins.

## What to change, feature by feature

For each feature: what it does with toyl, and what it does without.

1. **The data layer (`TodStore`).** Apply the patch's version.
   - Expose `source: .toyl | .tod | .none` so views can tell which one they're showing.
   - Without toyl, everything stays as it is.
2. **The setting.**
   - Add a feature in `Features.swift`, for example `useToyl` ("toyl"). Its hover help says: "with toyl installed, Oyl's to-dos, ideas, timers and projects are toyl's."
   - Add a row for it on the settings page (`SettingsPage.swift`).
   - Default: on when toyl's file exists. Off makes Oyl ignore toyl completely.
3. **The notch's to-do field.**
   - With toyl: hand the typed line to `toyl add --json` (a `Process`; it takes about 50 ms), so it parses exactly as toyl would. Fall back to `TodStore.add` if the command isn't there or fails.
   - Without toyl: as now.
4. **The ideas page.** It already works on the `dump` list through `TodStore`, so it works with toyl's file.
   - With toyl: drop any wording about tod. Ideas are toyl's ideas, and "?" in toyl's quick add makes one.
   - Without toyl: as now.
5. **Projects page, outline window and quick entry** (`Projects.swift`, `ProjectsPage.swift`, `ProjectsWindow.swift`). These duplicate toyl's lists and groups.
   - With toyl: hide the projects tab, its page, the outline window and its menu items (`Projects…` on the notch's right-click). Pressing tasks come from toyl: the soonest open dated tasks from `TodStore` (`open`, `next`).
   - Without toyl: unchanged.
   - `~/Library/Application Support/Oyl/Projects/Projects.json` doesn't exist on the owner's Mac, so no migration is needed. If it ever does exist, offer to move it into toyl only when the owner asks: areas become groups, projects become lists, tasks become tasks.
6. **Timers.**
   - With toyl:
     - Mirror toyl's countdowns, as in the patch.
     - Create new countdowns in toyl too, so there is one timer system. A "25m essay" typed into Oyl's timers page (or a gesture or the phone remote) should become `toyl timer start "essay" 25m --json`, or a timer entry written under the lock. The mirror then shows it.
     - Keep `ReminderParser` for reading what's typed.
     - Snooze or "one more" on a toyl timer should start the new one in toyl.
   - Without toyl: `TimerStore` as now.
7. **Reminders for timed tasks.** toyl rings only timers; it has no reminders for tasks with a time. Oyl's projects reminders (the notch pops open with a chime, and +10 min / OK / Done) are the right surface.
   - With toyl: ring them for toyl tasks that have a `due` and a `time`. "Done" goes through `TodStore.toggle`.
   - Keep the "reminded" state on Oyl's side (UserDefaults keyed by task id and time). Don't add fields to toyl's tasks.
   - Missed while Oyl was off: ring if it's within 12 hours, as projects reminders do now.
8. **The work log.**
   - "What's been done today" reads done tasks through `TodStore`, so it works with toyl. Word it as toyl's when the source is toyl.
9. **The phone remote.**
   - Its ideas and timers go through `TodStore` and `TimerStore`, so they work with toyl. Its timers start in toyl when the source is toyl (see 6).
10. **The calendar bar** (`Calendar.swift`, EventKit).
    - With toyl: optionally read toyl's `calendar.json` instead. It holds the owner's Google calendars, label names and events, with "floor meeting"s already left out per the owner's rules. That needs no calendar permission and shows the same events toyl shows.
    - Fall back to EventKit when `calendar.json` is missing or more than 30 minutes old (toyl writes it while it's open).
    - Without toyl: EventKit as now.

**"Remove the parts related to toyl"** means: with toyl present, hide Oyl's duplicates. That is the projects page, outline and window; Oyl-only timers; and tod discovery. Don't delete their code: users without toyl still need it.

## Testing (headless; never on screen)

- **Point Oyl at a scratch list.** Make Oyl's toyl detection honour `TOYL_HOME`. Fill the scratch list with toyl's command, for example `TOYL_HOME=/tmp/t toyl add "x fri"` or `TOYL_HOME=/tmp/t toyl timer start x 1m`.
- **Use a harness, as the patch's test did.** Compile `TodStore.swift`, `TodQuick.swift`, `TodRepeat.swift` and `Timers.swift`, a stub for `Haptics`, and a small `@main` that drives:
  - `TodStore(root:port:)` (or the toyl path, through `TOYL_HOME`)
  - `TimerStore(defaults: UserDefaults(suiteName: "test"))`
  - `mirror` and `onMirroredChange`

  Then inspect the JSON on disk.
- **Check that it compiles without touching the installed app:** `swiftc -Onone -swift-version 5 -parse-as-library -target arm64-apple-macos14.2 Sources/*.swift -o /tmp/OylCheck`. Don't run `build.sh` while Oyl is running unless the owner asks: it replaces `build/Oyl.app`, and `--run` relaunches Oyl.
- **Don't open, relaunch or `osascript activate` Oyl or toyl, and don't open toyl:// links.** Those all bring windows forward.

## Done when

- With toyl installed and the setting on:
  - The notch's to-do field, ideas page, work log and phone remote all work on toyl's list.
  - toyl's countdowns show and ring on the notch.
  - Pausing or stopping one on the notch does the same in toyl.
  - New timers started in Oyl appear in toyl.
  - Tasks with a time ring on the notch.
  - The projects page and outline are gone.
- With the setting off, or toyl not installed, Oyl behaves exactly as at `e4f789e`.
- toyl's file keeps every field through any number of Oyl edits. Check with a diff of `toyl.json` before and after.
- Oyl compiles with no new warnings in the files you touched, and the README describes the result in Oyl's voice.
