# toyl

A personal to-do app for the Mac ("things off your list") that works with Oyl, the owner's notch
app at ~/Oyl. One Swift program, three ways in: the app (AppKit + SwiftUI), the `toyl` command
line, and an MCP server (`toyl mcp`).

## Build and check (never on screen)

```bash
./build.sh               # build, install to ~/Applications/toyl.app, link ~/.local/bin/toyl; build/toyl.app is removed
                         # a running toyl is reopened as it was: window open (behind your work, no focus taken), in front only if it was
./build.sh --no-install  # just build/toyl.app (don't leave it around: it shows up as a second toyl)
TOYL_HOME=/tmp/t toyl add "essay fri 5pm #cs"            # a scratch list
TOYL_HOME=/tmp/t toyl __snapshot today /tmp/today.png   # the window, drawn offscreen
```

- **Never open, relaunch or activate the app while working on it.** That includes `open`,
  `toyl://` links, `osascript … activate`, and launching the binary directly. The owner doesn't
  want their desktop pulled around. Check the look with `__snapshot` (needs `TOYL_HOME`: no
  window, no Dock icon) and logic with the command line.
- Test Google Calendar against a local mock: point `TOYL_GOOGLE_AUTH`, `TOYL_GOOGLE_TOKEN` and
  `TOYL_GOOGLE_API` at it (and `TOYL_GMAIL_API`, `TOYL_MS_AUTH`, `TOYL_GRAPH_API` for email).
  `__snapshot <place> <file> calendar` draws the window with the calendar panel. Use `toyl google connect --no-browser` and fetch the printed loopback
  redirect yourself. With `TOYL_HOME` set, secrets live in that folder, not toyl-private.
- Build with the command line tools' `swiftc` only. No Xcode project, no packages.

## How it's built

- `Sources/Core`: shared by everything.
  - `Doc` is toyl.json as a plain dictionary, so unknown fields survive. It has typed reads
    (`Models`) and every change.
  - `Disk` saves under a `flock` on the folder (the lock Oyl takes too), read-modify-write on the
    latest file, replaced whole, with backups.
  - `Mirror` writes toyl.md and takes edits made in it back in.
  - `Quick` is quick add, built on `TodQuick`, `IdeaQuick` and `TodRepeat`, which are copied
    unchanged from Oyl so dates mean the same in both apps.
  - `Views` holds the smart places, the `Query` filters, auto sort and grouping.
  - `Classifier` is autosort.
  - `Google` handles OAuth (a loopback listener on 127.0.0.1, with PKCE) and the Calendar API
    (labels via `eventLabelVersion=1`). `Secrets` keeps its keys in `~/Library/Application Support/toyl-private/`
    (files only the owner can read). **Never the keychain**: it prompted after every rebuild, and the owner asked for it to stop.
  - `Mail` pulls important email: Gmail (Google's sign-in plus `gmail.readonly`) and Outlook (Microsoft Graph,
    the owner's own Entra app, PKCE, no secret), judged by `MailRules`. `mail.json` holds which inboxes and what's
    been judged; the sign-ins are in toyl-private.
  - `CalendarRules` holds the owner's calendar rules: style, sub-calendars and labels, and the
    planner that asks rather than guesses. `AgentDocs` and `CalendarGuide` write AGENTS.md and
    CALENDAR.md.
- `Sources/CLI`: `CLI` (the command, including `google` and `cal`), `MCP` (stdio JSON-RPC with
  tools, resources and prompts), and `Actions` (the changes both make).
- `Sources/App`:
  - `Store`: the window's copy of the list. A change shows at once, then is made again on the
    latest file. It watches the folder and handles undo.
  - `AppModel`: UI state and actions.
  - `TimerEngine`, whose wall-clock alarm is copied from Oyl.
  - `MailBridge`: pulls email every ten minutes into the inbox.
  - `PhoneLink`, `PhonePage`, `PhoneServer` (Oyl's, copied): toyl on the iPhone, a home-screen page served on the
    Wi-Fi or tailnet, for adding tasks and timers, then the lists. No calendar on the phone. Paired phones only. `toyl __phone <seconds> [picture.png]`
    (with `TOYL_HOME`) serves it on localhost:47659 with the code 123456 and draws it at iPhone size.
  - `CalendarBridge`: Google Calendar in the window. It reads events, keeps linked tasks in step
    both ways, and imports "todo:" events.
  - `Integrations` (agent links, the hot key, Apple's on-device model), `AppDelegate` (menus,
    windows, `toyl://` links) and `Picture` (`__snapshot`).
- `Sources/UI`: the views. `Theme` holds the colors, the face and `PlainField`.
- **Changes are closures on `Doc`**, made twice (on screen, then on the file). Anything random,
  such as a new id or the next repeat's id, is made outside the closure.
- **`@Local`, not `@State`.** In the macOS 26 SDK `@State` is a macro whose plugin only ships with
  Xcode.

## Data (`~/Library/Application Support/toyl/toyl.json`)

It's the v3 format Oyl's to-do store reads, grown:
- `toyl: 1` at the top.
- Lists: `{id, name, color, columns[], group?, notes?, archived?}`. The columns are sections.
  `inbox` is the inbox and `dump` is ideas.
- Tasks: `{listId, columnId, title, notes, due, time, target?, subtasks, done, doneAt, createdAt,
  updatedAt, order, tags?, pinned?, someday?, repeat?, duration?, spent?, event?: {id, calendar}}`.
- Also `groups`, `filters`, `timers` (UUID ids; Oyl may mark a timer `oyl: true` when it shows
  it), and `timerLog`.
- Keep every field you don't know. Never break an existing file.

## Design rules (keep them)

- **Lower case** for every word toyl says: menus, headings, buttons, dates. What the owner typed is
  shown as typed.
- **Times New Roman** everywhere. **Italics hardly ever**: secondary things are gray, not slanted.
- **Colors**: near-white paper (#fbfbfa), a warmer gray sidebar (#f4f4f2), ink (#1d1d1c), a
  gray-gold accent (#978d79) for done, today and timers, and a muted red (#a85a50) for late.
  Nothing yellow. Lists show their emoji, their symbol in their color, or a dot.
- **Quiet, like Notes**: plain word buttons and hairline rules. Always light.
- **Icons and a few words**, never paragraphs: every description in the app is an SF Symbol and a short phrase.
- **Quick, small animations** (0.2–0.4s): a check pops and fades out, new rows slide in, counts roll.
- **Places**: all (`anytime` inside; first, and where the window opens), inbox, today, ideas (loose ideas and
  anything put off: `someday` in the file), timers. No upcoming or logbook in the window (the command line and
  agents can still ask for them). **No line of description under a place's title.**
- **Panels** (`Panel`, `AppModel.panelOrder`): to-dos, details, calendar by default, dragged into any order by
  the grip at each one's top. The sidebar stays at the left edge. The line beside a panel resizes the one on the
  far side of it from the to-dos, so the calendar's edge always resizes the calendar.
- **Panels show and hide**, the page (to-dos) too (`showTasks`); the owner calls them page, description and
  calendar. With the page hidden, the calendar (else the description) takes the spare width (`fillingPanel`).
- Quick entry from anywhere is ⌘⌥X. The calendar has no shortcut of its own; ⌘= and ⌘- (and a pinch) zoom its
  hours (`calendarZoom`) about the pointer or the pinch.
- **Swipes rubber-band** (`AppModel.rubber`): free for 80 points, then harder, never past 170.
- **Calendar**: day, week and month (`CalendarMode`); the today button always shows; events stay clearly
  colored (past ones barely faded). Dragging an event onto a task ties them one way (`event.follows`): the
  task takes the event's day, time, length and list, and toyl never writes to that event.
- **Swipes** (Mail's way): right moves a task into its list's "in progress" section, left deletes it.
- **Links** show as cards in the details only, never on rows.
- **Late is quiet**: a soft red date and nothing else. No badges, red headings or red circles.
- **Sublists, not steps**: a task's sub-items (`subtasks` in the file) are its sublist, always shown under it in
  the list. Setup instructions are indented sublists too, never numbered steps.
- **Prompts are a word or two**: "new task", "when", "how long". No examples in fields.
- **Panels resize** by dragging the line between them (`PanelDivider`); widths are kept.
- **The calendar panel** (`CalendarPanel`) is Google Calendar itself, so it shows everything on the shown
  calendars (floor meetings too); rundowns elsewhere still leave them out.
- **Email**: only what needs doing comes in (`MailRules`: packages first, then action words; lists and newsletters
  only from .edu), flagged `source: "email"` with an `email` link. Rules before the on-device model.
- **No priorities.** What's pressing is what's due. Pins are the only way to lift something.
- **No aims, no "takes"**: "by fri" is when it's due. A length from quick add (`~30m`) only sets the task's
  timer and calendar length; it isn't shown or edited. (`target` and `duration` stay in the file for Oyl and agents.)
- **Timer lengths**: 10m, 30m, 1h, 6h, 24h (`TimerEngine.presets`); 30m by default.
- **Links in notes are cards** (`Links.swift`: LinkPresentation for the title and icon).
- **Every list's heading shows in all**, empty or not, with a + to add straight into it.
- **Google Calendar, never Apple's.** Everything written follows CALENDAR.md:
  - lowercase, no em dashes, no "#" in titles
  - minimal descriptions, no reminders, no links
  - a sub-calendar, then a label
  - nothing guessed: a missing day, time, end or placement is asked about
  - never a new calendar or label without asking
- **No mention of tod** anywhere in the app or its docs.
- **Agents get the window's powers**: anything the app can change, the command line and MCP can.

## Oyl

Oyl (`~/Oyl`, another agent's work) reads toyl's folder. **Whenever a change touches what Oyl sees** (toyl.json's
format, the folder's files, the `toyl` command's output, timers, ports), add a numbered entry to
`docs/oyl-changes.md` in the same commit: what changed and what Oyl should do. Keep `docs/oyl-integration.md`
true too. Never edit `~/Oyl` from here.

## Privacy

Everything stays on the Mac. Google and Microsoft keys live in toyl-private (0600 files), never in the folder agents read.
