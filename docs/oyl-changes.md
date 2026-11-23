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
