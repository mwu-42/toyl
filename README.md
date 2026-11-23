# toyl

**things off your list.** A to-do list for the Mac that works with Oyl. It looks like Apple Notes
on near-white paper with the faintest warmth, set in Times New Roman, everything in lower case
except what you type.

## Open it

```bash
./build.sh          # builds toyl.app, installs it in ~/Applications, links `toyl` into ~/.local/bin
./build.sh --run    # same, then opens it in front
```

It needs macOS 26 and the Xcode command line tools (`xcode-select --install`). There's no Xcode
project. The first build makes a local signing certificate in its own keychain, so macOS remembers
toyl's permissions across rebuilds. If toyl is open when you build, it reopens quietly, in the
background with its window hidden, and never jumps in front of what you're doing.

## What's in it

- 🗂 **places**: all · inbox · today · ideas · timers, then your lists (in groups), tags, saved filters. ⌘1–5. it opens on all.
- 📅 **calendar panel** (⌥⌘C, or the calendar button): a day of google calendar beside your list.
  - the week on top · all-day events · the hours, with your timed tasks dashed among the events
  - drop a task on an hour to do it then, or on a day to move it · double-click an hour for a new event
  - click an event for its details · ⌥⌘[ and ⌥⌘] for the day before and after
- ↔️ **panels resize**: drag the line between them · double-click it for the usual width.
- ✉️ **important email**: gmail and outlook, pulled into the inbox and flagged ✉ email. below.
- 💡 **ideas**: loose ideas (`?` first) and anything put off (`/idea`, or drag it onto ideas). it keeps its list.
- ⌨️ **quick add** reads what you type: `essay draft fri 5pm #cs ~2h !`
  - `#cs` list or tag · `~list` a list · `?` an idea
  - `fri 5pm`, `tomorrow`, `nov 30` a deadline · `by fri`, `next week` an aim (can slip)
  - `every week` repeats · `~30m` how long · `!` pin · ` // ` notes
  - `/timer`, `/timer 25m`, `/stopwatch` start a timer on it
- ⏱ **timers on any task**: hover a task and click ⏱ (right-click it for lengths), pick a length in its details, or type one. time adds up on the task.
- 🪄 **autosort**: files new tasks where your others go (on the mac); ⌥⌘A does the inbox.
- 🔎 **filters**: `#tag`, `in:cs`, `due:week`, `is:late`… save one as a list.
- ✨ **small animations**: a check pops then fades, new things slide in, counts roll.
- 🕰 **late, quietly**: a soft red date, nothing more.
- 📅 **google calendar**: below.
- ⌃⌥T **quick entry** from anywhere · esc, click away or ⌃⌥T again to close.

## Google Calendar

toyl talks to Google Calendar directly. It reads your calendars, their labels and their events,
and adds events the way your calendar rules say.

**One-time setup, about five minutes.** Google gives each person's own app its own key.
1. Make a project in Google Cloud and turn on the Google Calendar API.
2. In Google Auth Platform › Audience, choose External and add your address as a test user. Then
   publish it ("In production"), so Google doesn't sign toyl out every week.
3. Under Clients, make a "Desktop app" client and download its JSON.
4. In toyl: settings › google calendar, paste the JSON, then connect. (Or run
   `toyl google client ~/Downloads/client_secret_….json`, then `toyl google connect`.)

The client and your sign-in are kept in your keychain, not in toyl's folder.

**What it does:**
- Shows events beside your tasks: the calendar panel, today, and the details pane's "still to come". It
  shows the calendars Google itself shows, minus the adopted treehacks and stanford feeds; choose
  others in settings.
- **add to google calendar…** (⇧⌘G, or right-click a task) opens a form filled in from the task
  and your rules. Nothing is added until nothing's missing, and what's still needed is said in
  plain words. Your rules (`CALENDAR.md`, also in `calendar-rules.json`):
  - Titles, descriptions and locations are lowercase. There are no em dashes, and no "#" in titles.
  - Descriptions are blank unless you write one. Events get no reminders.
  - An event goes on a sub-calendar, then a label in it (♡, ✩ a with cs 106b and the rest, and so
    on). Album drops go on r with music, "lunch with" on g with food, chores on r.
  - A tentative event gets a "?" in its title.
  - Mint all hands fills itself in: thursday 7:30-8:30pm at pigott hall 260-113, with margs after.
  - Nothing goes on m that's on another calendar too.
  - Nothing is guessed: a start with no end asks how long. toyl never makes a new calendar or label.
- A task you've put on the calendar stays in step with its event. Move the event, on any device
  or by any agent, and the task follows. Change the task and the event follows.
- An event called "todo: something" becomes a task. The event is left as it is.

## Email

toyl pulls **important** mail into the inbox every ten minutes while it's open, each task flagged ✉ email with a
link back to the message (`is:email` finds them):
- 📦 a package to pick up: QTrak's notices, a mail room, a locker, a front desk
- 📝 something due, or to sign, pay, submit, rsvp or answer
- 🙅 newsletters, receipts, shipping news, codes and sales stay in your inbox
- ✨ with apple intelligence on, mail the inbox flagged from a person is asked about too (on the mac)

**gmail**: settings › email › gmail. It uses your google sign-in, and asks google once more to allow reading mail.
In Google Cloud, also turn on the Gmail API for the same project.

**outlook** (stanford's mail, or outlook.com): it needs an app of your own, once.
1. entra.microsoft.com › app registrations › new registration (any name; "accounts in any organizational directory and personal accounts").
2. Authentication › add a platform › mobile and desktop applications › redirect URI `http://localhost`.
3. API permissions › Microsoft Graph › delegated › `Mail.Read` (and `User.Read`).
4. Copy its Application (client) ID into settings › email, then connect. (Or `toyl mail outlook client <id>` then
   `toyl mail outlook connect`.) A school account may need its IT to allow the app.

`toyl mail pull` (or the `pull_email` tool) checks now. Each message is judged once.

## Agents: Claude, Muse, Instinct

| way in | for | how |
| --- | --- | --- |
| MCP server (`toyl mcp`) | Claude Desktop, Claude Code, Muse Code | settings › agents and ai › link, or `toyl connect claude-code` |
| the `toyl` command | anything with a shell | `toyl today`, `toyl add "…"`, `toyl cal add …`, `--json` on everything |
| toyl.md | anything that reads files | the whole list as Markdown. Edit it and toyl takes the edits in |
| Google Calendar | Instinct, Muse, Claude | events toyl adds; "todo: …" events become tasks |
| `toyl://` links | Shortcuts, Raycast | `toyl://add?text=…`, `toyl://task/<id>`, `toyl://show/today`, `toyl://quick` |

The MCP server's tools:
- Tasks: `get_overview`, `list_tasks`, `get_task`, `add_task(s)`, `update_task`,
  `complete_task`, `delete_task`.
- Lists and tags: `list_lists`, `create_list`, `list_tags`.
- Agenda and timers: `get_agenda`, `start_timer`, `stop_timer`, `list_timers`.
- Inbox: `autosort_inbox`, `pull_email`.
- Calendar: `list_calendars`, `suggest_calendar_placement`, and `add_to_calendar`. That last one
  checks your calendar rules and answers with questions when something's missing.

**AGENTS.md** and **CALENDAR.md** in toyl's folder explain all of this to any agent.

## Oyl

toyl's file is the format Oyl's to-do features read. `docs/oyl-integration.md` tells the agent
working on Oyl how to switch Oyl over to toyl: its notch to-do field, ideas, timers and reminders
use toyl, and its projects page goes away. Oyl keeps its own built-ins for anyone without toyl.
`docs/oyl-toyl-integration.patch` is a tested start on it.

## Your data

Everything stays on this Mac, in `~/Library/Application Support/toyl/`:

| file | what it holds |
| --- | --- |
| `toyl.json` | the list: lists, tasks, groups, filters, timers (see AGENTS.md) |
| `toyl.md` | the same list as Markdown, written whenever it changes, and editable |
| `AGENTS.md`, `CALENDAR.md` | how agents read and change it, and your calendar rules |
| `calendar-rules.json` | the calendar rules toyl applies (calendars, labels, word rules) |
| `calendar.json` | the next two weeks of your Google Calendar, for the command line and MCP |
| `mail.json` | which inboxes are on, when they were last read, and which messages have been judged |
| `toyl.backup.json`, `backups/` | the file from at most ten minutes ago, and a copy a day for a fortnight |

`TOYL_HOME=/some/folder` points the app, the command and the MCP server at another folder, to try
things without touching your list.
