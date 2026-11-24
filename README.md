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
toyl's permissions across rebuilds. If toyl is open when you build, it reopens as it was, its window
open behind what you're doing (in front only if you were using toyl), never taking the focus.

## What's in it

- 🗂 **places**: all · inbox · today · in progress · ideas · timers, then your lists (in groups), tags, saved filters. ⌘1–6. it opens on all.
  - **in progress**: everything you've swiped into progress, the ones with a timer going first
  - what you just did ("deleted", "timer stopped") shows at the top right for a moment, then fades
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
  - soft right: into its list's **in progress** (or out of it) · hard right: in progress, with a timer going
  - soft left: a **timer** on it (or, if one's going, stop it) · hard left: delete (⌘z undoes it)
- ✉️ **important email**: gmail and outlook, pulled into the inbox and flagged ✉ email. below.
- 📁 **projects** inside a list: the big pieces of work (a final project, midterm prep, an event)
  - a list shows its loose tasks first, then each project under a big heading, with a + to add straight into it
  - make one: "new project" at the bottom of a list, the list's menu, or a task's project in its description
  - drop a task on a project's heading to put it in; double-click the heading to rename it; right-click to delete it (its tasks stay)
  - a task with a sublist can **turn into a project**: right-click › turn into a project (or "make it a project" by its sublist). each item becomes a task in it
- ☑️ **sublists**: a task's sublist shows right under it. right-click › add to its sublist (or use its description) to add · ✨ "break it down" makes one with apple intelligence.
- 💡 **ideas**: loose ideas (`?` first) and anything put off (`/idea`, or drag it onto ideas). it keeps its list.
- ↩️ **the keys**: press Return anywhere to start a new task, or just start typing
  - Return adds it and stays for the next · Return with nothing typed, Escape or ↓ go back to the list
  - ↑ ↓ move through the list (⇧ to take more) · ↑ from the top goes into quick add
  - double-click a title or press ⌘E to change it: Return keeps it, Escape doesn't, clicking away keeps it
  - space shows or hides the description · ⌫ deletes · Escape lets go of what's selected
  - the + lines (under a heading, in a sublist) take the caret at once, stay for the next, and close on Return with nothing typed
- ⌨️ **quick add** reads what you type: `essay draft fri 5pm #cs ~2h !`
  - `#cs` list or tag · `~list` a list · `?` an idea
  - `fri 5pm`, `tomorrow`, `nov 30`, `by fri`, `next week` when it's due
  - `every week` repeats · `~30m` its timer's length · `!` pin · ` // ` notes
  - `/timer`, `/timer 30m`, `/stopwatch` start a timer on it
- ⏱ **timers on any task** (a running one shows on its task, and in timers; nothing at the window's foot): swipe it softly left, right-click › timer for a length, or pick one in its details: 10m · 30m · 1h · 6h · 24h, or type one. time adds up on the task.
- 🔗 **links in notes are cards** in the details: the page's icon and title; click to open. rows stay plain.
- ➕ **every list has its heading in all**, empty or not, with a + on the right to add straight into it.
- 🪄 **autosort**: files new tasks where your others go (on the mac). the 🪄 by the filter (in all and the inbox, or ⌥⌘A) sorts everything in the inbox at once:
  - a task naming a list goes there ("mint all hands slides" → mint); then where autosort's sure; then apple intelligence, which has to agree twice
  - what clearly fits nowhere stays in the inbox · ⌘z undoes the whole sort · "look over autosort's guesses…" (the inbox's menu) to go one by one
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

The client and your sign-in are kept in `~/Library/Application Support/toyl-private/`, readable by your account
alone, not in toyl's folder. (Not the keychain: it asked for permission again after every update of toyl.)

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

## Canvas

toyl reads your Canvas (canvas.stanford.edu, or another school's) and brings in what's due, to get ready for:
- 📚 each assignment, quiz and graded discussion becomes a task, due when Canvas says, in the list named like
  its course ("CS 106B" goes to 💻 cs 106b; else the inbox), with its Canvas page linked in the description
- ✅ submitted on Canvas: checked off here · its due date moved there: moved here · deleted here: not brought in again
- every half hour while toyl's open; `toyl canvas pull` (or the `pull_canvas` tool) checks now; `is:canvas` finds them

**Connecting it, once** (settings › canvas):
- in Canvas: account › settings › new access token, then paste the token
  - or, if your school doesn't allow tokens: calendar › calendar feed, and paste that address (it can't tell
    what's been submitted)
- another school's Canvas: type its address in settings › canvas, or `toyl canvas site canvas.school.edu`
- the token and feed are kept in toyl-private, readable by your account alone

## iPhone

toyl on your phone is made for adding tasks and running timers, served by toyl on your Mac (no calendar on it):
- ➕ a big "new task" field first, read the way quick add reads it (`fri 5pm`, `#cs`, `/timer 30m`), with your lists to file into
- ⏱ big buttons for 10m · 30m · 1h · 6h · 24h and a stopwatch, on anything or on a task; what's running, to pause, +5 or stop
- 🗂 your lists and their tasks (tap a list to fold it), to check off or time
  - soft right: in progress · hard right: in progress with a timer
  - soft left: a timer (or stop it) · hard left: delete (with undo)
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
