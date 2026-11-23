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
- 📅 **calendar panel** (the calendar button): google calendar beside your list, as a **day, week or month**.
  - day: the week on top · all-day events · the hours, with your timed tasks dashed among the events
  - week: seven days of hours side by side; "n more" over a day opens the all-day row · month: each day's events and tasks; click a day to open it
  - **zoom** the hours: pinch on the trackpad, or ⌘= and ⌘-; it zooms about where you're pointing
  - drop a task on an hour to do it then, or on a day to move it · double-click an hour for a new event
  - **drag an event onto a task** to tie them: the task takes the event's day, time and list, and follows it if it moves. the event itself is never changed.
  - click an event for its details · ⌥⌘[ and ⌥⌘] for earlier and later · today is always one click
- ↔️ **panels**: the page (your to-dos), the description (a task's details) and the calendar, in that order at first.
  - show or hide any of them: view › page, description, calendar, or right-click a panel's grip. with the page hidden, the calendar (or the description) fills the window
  - drag the calendar's edge to make it wider or narrower, wherever it sits
  - drag a panel's grip (≡, at its top) onto another to swap them · right-click the grip to move it left or right
  - drag the line between panels to resize them · double-click it for the usual width
- 👆 **swipe a task** (two fingers on the trackpad, as in Mail; or a finger on the phone). it pulls freely, then harder and harder, like a rubber band
  - right: into its list's **in progress** (again to take it back out)
  - left: delete (⌘z puts it back)
- ✉️ **important email**: gmail and outlook, pulled into the inbox and flagged ✉ email. below.
- ☑️ **sublists**: a task's sublist shows right under it. select the task to add to it · ✨ "break it down" makes one with apple intelligence.
- 💡 **ideas**: loose ideas (`?` first) and anything put off (`/idea`, or drag it onto ideas). it keeps its list.
- ⌨️ **quick add** reads what you type: `essay draft fri 5pm #cs ~2h !`
  - `#cs` list or tag · `~list` a list · `?` an idea
  - `fri 5pm`, `tomorrow`, `nov 30`, `by fri`, `next week` when it's due
  - `every week` repeats · `~30m` its timer's length · `!` pin · ` // ` notes
  - `/timer`, `/timer 30m`, `/stopwatch` start a timer on it
- ⏱ **timers on any task**: hover a task and click ⏱ (right-click it for lengths), or pick one in its details: 10m · 30m · 1h · 6h · 24h, or type one. time adds up on the task.
- 🔗 **links in notes are cards** in the details: the page's icon and title; click to open. rows stay plain.
- ➕ **every list has its heading in all**, empty or not, with a + on the right to add straight into it.
- 🪄 **autosort**: files new tasks where your others go (on the mac); ⌥⌘A does the inbox.
- 🔎 **filters**: `#tag`, `in:cs`, `due:week`, `is:late`… save one as a list.
- ✨ **small animations**: a check pops then fades, new things slide in, counts roll.
- 🕰 **late, quietly**: a soft red date, nothing more.
- 📅 **google calendar**: below.
- ⌘⌥X **quick entry** from anywhere · esc, click away or ⌘⌥X again to close.

## Google Calendar

toyl talks to Google Calendar directly. It reads your calendars, their labels and their events,
and adds events the way your calendar rules say.

**One-time setup, about five minutes.** Google gives each person's own app its own key.
- In Google Cloud:
  - a project, with the Google Calendar API turned on
  - Google Auth Platform › Audience: External, your address as a test user, then published ("In production"),
    so Google doesn't sign toyl out every week
  - Clients: a "Desktop app" client, its JSON downloaded
- In toyl: settings › google calendar, paste the JSON, then connect
  - or `toyl google client ~/Downloads/client_secret_….json`, then `toyl google connect`

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
- In entra.microsoft.com › app registrations, a new registration:
  - any name; "accounts in any organizational directory and personal accounts"
  - Authentication › mobile and desktop applications › redirect URI `http://localhost`
  - API permissions › Microsoft Graph › delegated › `Mail.Read` (and `User.Read`)
- In toyl: settings › email, paste its Application (client) ID, then connect
  - or `toyl mail outlook client <id>`, then `toyl mail outlook connect`
  - a school account may need its IT to allow the app

`toyl mail pull` (or the `pull_email` tool) checks now. Each message is judged once.

## iPhone

toyl on your phone is made for adding tasks and running timers, served by toyl on your Mac (no calendar on it):
- ➕ a big "new task" field first, read the way quick add reads it (`fri 5pm`, `#cs`, `/timer 30m`), with your lists to file into
- ⏱ big buttons for 10m · 30m · 1h · 6h · 24h and a stopwatch, on anything or on a task; what's running, to pause, +5 or stop
- 🗂 your lists and their tasks (tap a list to fold it), to check off or time
  - swipe right: in progress · swipe left: delete (with undo)
- ✉️ added while the Mac can't be reached: kept on the phone, sent when it can

**Setting it up, once:**
- On the Mac: settings › iphone, turn it on, then pair
- On the phone: scan the code with the camera (or open the address and type the six digits)
- Then share › add to home screen, and it opens like an app

It works on the same Wi-Fi as the Mac, or from anywhere with Tailscale on both. The Mac has to be awake with
toyl open. Only paired phones get in (each keeps a long key; toyl keeps its hash), only from your network or
tailnet; settings › iphone › forget unpairs them all.

(A native iPhone app needs Xcode to build, which this Mac doesn't have. This page is the same list, live.)

## Agents: Claude, Muse, Instinct

| way in | for | how |
| --- | --- | --- |
| MCP server (`toyl mcp`) | Claude Desktop, Claude Code, Muse Code | settings › agents and ai › link, or `toyl connect claude-code` |
| the `toyl` command | anything with a shell | `toyl today`, `toyl add "…"`, `toyl cal add …`, `toyl merge stack`, `--json` on everything |
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
