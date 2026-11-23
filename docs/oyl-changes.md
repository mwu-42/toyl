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
