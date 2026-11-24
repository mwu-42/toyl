# toyl changes for Oyl

Every change in toyl that matters to Oyl, numbered, oldest first: the file's format, the files in toyl's folder,
the `toyl` command's output, timers, ports. Each says what changed and what Oyl should do. Oyl keeps the number
it has taken in at `~/Oyl/.toyl-sync`; `docs/oyl-sync/pending.sh` prints the entries after it.

Headings are `## <number> · <date> · <what>`. Never renumber or rewrite an entry once it's written: add a new one.

## 1 · 2026-11-23 · the integration

Integrate toyl into Oyl as `docs/oyl-integration.md` describes. That document is up to date as of this entry
(toyl at commit 8baa73c): it already covers sublists, no aims, "in progress" sections, `event.follows`, email
tasks (`source: "email"`, `email`), toyl's timer lengths (10m, 30m, 1h, 6h, 24h; 30m by default), toyl's phone
page on port 47650, and `calendar.json` holding only the calendars shown in toyl.

When it's done, write `1` into `~/Oyl/.toyl-sync`.

## 2 · 2026-11-23 · tasks from Canvas, and no sections in toyl's window

- toyl can now bring assignments in from Canvas. Such a task has `source: "canvas"` and a new field,
  `canvas: {id, course, url}` (keep it, as every field). Its notes are the Canvas link. Where Oyl lists toyl's
  tasks it may mark these (a 🎓, or the course), but it doesn't have to.
- toyl's window no longer shows sections: a list is one list. They're still in the file (the "in progress" one
  included) and Oyl can treat them as it does now.
- toyl's quick entry from anywhere is ⌘⌥X now (it was ⌃⌥T). If Oyl ever mentions toyl's shortcut, use the new one.

When it's taken in, write `2` into `~/Oyl/.toyl-sync`.

## 3 · 2026-11-23 · projects inside lists

- A list can now hold projects: `projects: [{id, name, notes?}]` on the list entry, and a task's `project` is the
  id of one of its own list's projects. Keep both fields as you keep every field.
- When Oyl moves a task to another list, drop its `project` (it belonged to the old list), as toyl does.
- If Oyl shows toyl's tasks grouped, it may group a list's tasks by project, but it doesn't have to.

When it's taken in, write `3` into `~/Oyl/.toyl-sync`.

## 4 · 2026-11-23 · slash words that make something other than a task

- What's typed to add can now start with a slash word that makes something else: `/list groceries`,
  `/project final essay #cs` (in the list named, else the inbox), `/group school`, `/filter #cs due:week`, and
  `/timer 25m` or `/stopwatch` with nothing else on the line (just a timer, no task). `/timer 25m essay` is still a
  task with a timer on it.
- `toyl add "<text>"` does this too. For such a line, `toyl add --json` prints `{"made": "list" | "project" |
  "group" | "filter" | "timer", "id": ..., ...}` instead of a task. A slash word with nothing after it (`/list`)
  fails with a message, and `/event` fails pointing at `toyl cal add`.
- If Oyl passes what's typed in the notch to `toyl add` and reads the task back, check for `made` first. If Oyl
  parses quick add itself, it may offer the same words, or leave them be (then such a line becomes a task title).

When it's taken in, write `4` into `~/Oyl/.toyl-sync`.

## 5 · 2026-11-23 · fixes Oyl should know about (calendar links, Canvas, toyl.md, dates)

- A task's `event` link can now carry `agreed` (the task's `due|time|duration|title` when it and its event last
  agreed) and `seen` (the event's last-changed time then, in ms). toyl uses them to tell which side moved. Keep them
  as you keep every field; if Oyl changes a linked task's day or time, leave them alone (toyl sees the change).
- A Canvas task's `canvas` link can carry `due` (what Canvas last said, "2026-12-01 23:59"). toyl moves the task
  only when Canvas's date changes, so a task moved by hand (in toyl or Oyl) stays where it was put. Keep the field.
- toyl's folder has a new file, `.toyl.md.base`: the toyl.md toyl last wrote. When toyl.md is edited, only lines
  that differ from it are taken in, so a stale toyl.md can no longer undo what Oyl changed in toyl.json (a task
  Oyl checked off stays checked off). Oyl needn't do anything; don't delete the file.
- toyl.md no longer writes `by <aim>` on a task's line (toyl has no aims).
- The shared date reading (`IdeaQuick`, copied from Oyl) changed in two places; Oyl may want the same:
  - a count with no "in" before it isn't a day: "review 3 months of statements", "plan 2 weeks of meals" (it was
    read as due in 3 months / 2 weeks). "in 3 weeks", "within 2 weeks", "3 weeks or so" still are.
  - the month you're in means this month: "in nov" typed in November is now, not next November.
  `takeAim` has a sibling, `takeAimTimed`, that also returns a time said with the aim ("by fri 5pm").

When it's taken in, write `5` into `~/Oyl/.toyl-sync`.
