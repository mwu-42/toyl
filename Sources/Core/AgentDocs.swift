import Foundation

/// AGENTS.md, written into toyl's folder: how an agent (Claude, Muse, anything that reads
/// files) finds its way around the list and changes it.
enum AgentDocs {
    static func text() -> String {
        let folder = Paths.home.path
        let program = Paths.program.path
        return """
        # toyl: things off your list

        toyl is a to-do list (a Mac app). This folder is all of it. Read this before changing anything.

        ## Where things are

        - `\(folder)/toyl.json`: the list itself. The app, the `toyl` command, toyl's MCP server and the Oyl \
        menu bar app all work on it.
        - `\(folder)/toyl.md`: the same list as Markdown, rewritten whenever it changes. Read it for a quick \
        look, or edit it (see below).
        - `\(folder)/calendar.json`: the next two weeks of the owner's Google Calendar (events, calendars and their \
        labels) as the app last read them. Read-only.
        - `\(folder)/CALENDAR.md`: the owner's rules for their Google Calendar. Follow them for any event you add.

        ## Reading and changing the list (best first)

        1. **MCP**, if toyl's server is connected (tools named `list_tasks`, `add_task`, `update_task`, \
        `complete_task`, `get_agenda`…). Start with `get_overview`.
        2. **The command line**: `toyl` (or `\(program)`). Add `--json` for JSON.
           - `toyl today`, `toyl inbox`, `toyl upcoming`, `toyl ls [filter]`, `toyl show <id>`, `toyl lists`, `toyl tags`, `toyl agenda`
           - `toyl add "essay draft fri 5pm #cs ~2h"` (read as quick add reads it, below)
           - `toyl done <id or title>`, `toyl undo <id>`, `toyl rm <id>`
           - `toyl edit <id> --title … --due fri --time 17:00 --list cs --tag +reading -old --notes … --pin --someday --repeat weekly --duration 45m`
           - `toyl merge <list> [into]`: fold one list into another (the inbox, if none's named)
           - `toyl timer start <id> [25m]`, `toyl timer stop`, `toyl timers`
           - `toyl new-list "name" [--group school]`, `toyl autosort [--apply]`
           - `toyl cal` (calendars and labels), `toyl cal suggest <task>`, `toyl cal add <title> --cal a --label "cs 106b" --day fri --start 3pm --end 4pm` \
        (checks the calendar rules; prints questions and exits 3 when something's missing)
           - `toyl mcp` runs the MCP server on stdin/stdout.
        3. **toyl.md**: edit it like any Markdown file. Tick a box (`[x]`), change a title or what's after its \
        ` — `, add `- [ ] read ch 3 fri #reading` under a list's `##` heading, indent `- [ ]` under a task for a \
        subtask, put `[-]` in a box to delete, add a `## heading` for a new list. Keep the `{t:…}`, `{l:…}` and \
        `{c:…}` ids. Lines you remove are not deleted (say `[-]`). toyl takes the edit in within a few seconds \
        while the app is open, or the next time anything saves.
        4. Don't write `toyl.json` yourself while toyl might be running: use one of the above.

        ## How the list works

        - **Lists** hold tasks, and can have **sections** (`columns` in the file). \
        Lists can sit in **groups** (school, clubs). The **inbox** (list id `inbox`) holds what hasn't been filed. \
        **Ideas** (list id `dump`) holds loose ideas; its sections are folders.
        - A task has a **deadline** (`due`, `YYYY-MM-DD`, plus `time` `HH:MM`, 24-hour), which can't slip and is \
        late once past. toyl doesn't use aims any more: "by fri" means due fri (don't set `target`). There are no \
        priorities: what's pressing is what's due. **Pinned** keeps \
        a task at the top of today. **Putting it off** (`someday` in the file) moves it into ideas.
        - **Tags** are plain words (`#reading`). **Repeat** is one of daily, weekdays, weekly, biweekly, monthly, \
        yearly: checking a repeating task off adds the next one. **Duration** (minutes) only sets its timer and calendar length; the window doesn't show it. \
        **Spent** is seconds timed on it. A task's **sublist** (`subtasks` in the file) shows under it in the list: \
        call it a sublist, not steps.
        - **Today** shows what's due today or before, plus pinned tasks. **All** (`anytime` in the file and commands) is everything open, and where the window opens. \
        **Ideas** holds loose ideas and anything put off. (Agents can also ask for upcoming, dated later, and logbook, done.)
        - Text is shown in lower case, but keep the case the person typed. Don't capitalize their words.

        ## Google Calendar

        toyl reads and writes the owner's Google Calendar itself. To add an event, use the MCP tool `add_to_calendar` \
        (or `toyl cal add`): it writes the event their way (lowercase, no em dashes, no "#" in titles, minimal \
        description, no reminders) on the sub-calendar and label CALENDAR.md says, and it adds nothing until it has the \
        day, the start and end (or all day) and the placement, answering with questions instead. Ask the owner those \
        questions; never guess a day, a time, a length or a calendar. `list_calendars` and `suggest_calendar_placement` \
        help. An event titled "todo: something" becomes a task the next time the app reads the calendar.

        A task's `event` is `{id, calendar}` when toyl put it on the calendar (they keep in step both ways), or \
        `{id, calendar, follows: true}` when the owner tied it to an existing event by dragging the event onto it: \
        then the task takes the event's day, time and length, and toyl never changes that event.

        ## Canvas

        If the owner connected Canvas (settings › canvas, or `toyl canvas`), toyl brings in what's due every half \
        hour: each assignment, quiz and graded discussion is a task due when Canvas says, in the list named like its \
        course, with `source: "canvas"`, `canvas: {id, course, url}` and the Canvas link as its notes. Submitted on \
        Canvas, it's checked off; moved there, it moves. `pull_canvas` (or `toyl canvas pull`) checks now; \
        `is:canvas` finds them.

        ## Email

        If the owner turned it on (settings › email, or `toyl mail`), toyl pulls **important** mail from Gmail and \
        Outlook into the inbox, every ten minutes while the app is open: a package to pick up (QTrak's notices and \
        the like), something due, something to sign, pay, submit or answer. Everything else stays in their inbox. \
        Such a task has `source: "email"` and `email: {account, id, from, subject, link}`; `is:email` finds them. \
        `pull_email` (or `toyl mail pull`) checks now; each message is judged once.

        ## Quick add (what `toyl add`, `add_task` with `text`, and new toyl.md lines understand)

        `essay draft fri 5pm #cs ~2h !` is "essay draft", due Friday at 5pm, in the list "#cs" names (a list whose \
        name starts with it, like "💻 cs 106b", otherwise a tag), taking two hours, pinned.
        - `?` first: an idea. `~list` or `~"two words"`: a list, made if needed. `#word`: list or tag.
        - Days: `today`, `tomorrow`, `fri`, `next fri`, `in 3 days`, `nov 30`, `2026-12-01`, `5pm`, `17:00`, `noon`, `3-4pm`.
        - `by fri`, `next week`, `early dec`, `in a month or so`, `fri-ish`: due then.
        - `every day/weekday/week/other week/month/year`, `every fri`, `daily`, `weekly`.
        - `~30m`, `for 2h`, `1h30m`: duration. `!` or `/pin`: pinned. `/idea`: put off into ideas. ` // ` then notes.
        - `/timer`, `/timer 25m`, `/stopwatch`: start a timer on it as it's added.

        ## Filters (`toyl ls <filter>`, `list_tasks` with `query`, saved filters)

        Words must all appear. Also: `#tag`, `-#tag`, `in:cs`, `due:today|tomorrow|week|month|overdue|soon|none|any|fri|2026-12-01`, \
        `before:dec 1`, `after:fri`, `is:open|done|all|pinned|someday|repeating|idea|late|slipped|stale|inbox|email|canvas`, \
        `has:notes|subtasks|tags|time|date|aim|timer|event|duration`, `-word`, `"a phrase"`.

        ## toyl.json, in brief

        `{ version: 3, toyl: 1, lists: [{id, name, color, columns: [{id, name}], group?, notes?, archived?, kind?}], \
        tasks: {id: {id, listId, columnId, title, notes, due, time, target?, subtasks: [{id, title, done}], done, doneAt, \
        createdAt, updatedAt, order, tags?, pinned?, someday?, repeat?, duration?, spent?, event?, source?, email?, canvas?}}, groups: [{id, name}], \
        filters: [{id, name, query}], timers: [{id, label, task?, kind, duration, endsAt?, pausedLeft?, startedAt, elapsed, \
        runningSince?}], timerLog: […], settings: {weekStart}, order, layout, collapsed }`. Moments (createdAt, doneAt…) are \
        milliseconds since 1970. Keep any field you don't know about.

        """
    }

    /// Writes AGENTS.md if it's missing or out of date.
    static func write() {
        let text = self.text()
        if (try? String(contentsOf: Paths.agents, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? text.write(to: Paths.agents, atomically: true, encoding: .utf8)
    }
}
