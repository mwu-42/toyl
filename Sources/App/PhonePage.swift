import AppKit

/// toyl's iPhone page: what `PhoneLink` serves. Saved to the home screen, it opens full screen like
/// an app. Adding comes first (a big field, your lists to file into, what it read), then timers
/// (big buttons for 10m, 30m, 1h, 6h, 24h and a stopwatch; what's running, to pause, add to or
/// stop), then your lists, to check off, time, or swipe (left: in progress; right: delete). No
/// calendar. Paper, ink and Times New Roman, in lower case.
enum PhonePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="default">
    <meta name="apple-mobile-web-app-title" content="toyl">
    <meta name="theme-color" content="#fbfbfa">
    <link rel="apple-touch-icon" href="/icon.png">
    <link rel="manifest" href="/manifest.json">
    <title>toyl</title>
    <style>
    :root { --paper: #fbfbfa; --ink: #1d1d1c; --secondary: #737370; --faint: #a6a6a2; --rule: #e6e6e3; --field: #efefed;
            --selected: #e0dfdb; --accent: #978d79; --late: #a85a50; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body { margin: 0; background: var(--paper); color: var(--ink); font-family: "Times New Roman", Times, serif; }
    body { padding: calc(env(safe-area-inset-top) + 12px) 18px calc(env(safe-area-inset-bottom) + 96px); -webkit-text-size-adjust: 100%; }
    button { font: inherit; color: inherit; cursor: pointer; }
    button:active { opacity: 0.6; }
    [hidden] { display: none !important; }
    header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 14px; }
    h1 { font-size: 32px; margin: 0; }
    #mac { color: var(--faint); font-size: 15px; }
    #mac.off { color: var(--late); }
    h2 { font-size: 15px; font-weight: bold; margin: 26px 0 10px; display: flex; justify-content: space-between; align-items: baseline; }
    h2 span { color: var(--faint); font-weight: normal; }
    .field { display: flex; align-items: center; background: var(--field); border-radius: 16px; padding: 5px 5px 5px 16px; }
    .field input { flex: 1; min-width: 0; border: 0; background: transparent; font: inherit; font-size: 22px; padding: 11px 0; color: var(--ink); outline: none; }
    .field input::placeholder { color: var(--faint); }
    #addButton { width: 48px; height: 48px; border-radius: 13px; border: 0; background: var(--ink); color: var(--paper); font-size: 24px; line-height: 1; }
    #addButton:disabled { background: var(--selected); color: var(--faint); }
    .tokens { display: flex; flex-wrap: wrap; gap: 6px; min-height: 0; padding-top: 8px; }
    .tokens:empty { padding-top: 0; }
    .token { font-size: 14px; color: var(--secondary); background: rgba(151, 141, 121, 0.14); border-radius: 999px; padding: 3px 9px; }
    .chips { display: flex; gap: 7px; overflow-x: auto; padding: 10px 0 2px; margin: 0 -18px; padding-left: 18px; padding-right: 18px; scrollbar-width: none; }
    .chips::-webkit-scrollbar { display: none; }
    .chip { flex: none; border: 0; border-radius: 999px; background: var(--field); padding: 8px 13px; font-size: 16px; color: var(--secondary); }
    .chip.on { background: var(--ink); color: var(--paper); }
    .chip .mark { margin-right: 4px; }
    .presets { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
    .preset { height: 58px; border: 0; border-radius: 15px; background: var(--field); font-size: 21px; }
    .preset.small { height: 44px; font-size: 17px; border-radius: 12px; }
    .on-what { display: flex; align-items: center; gap: 8px; margin-top: 10px; color: var(--faint); font-size: 15px; }
    .on-what input { flex: 1; border: 0; border-bottom: 1px solid var(--rule); background: transparent; font: inherit; font-size: 17px; padding: 6px 0; color: var(--ink); outline: none; border-radius: 0; }
    .timer { display: flex; align-items: center; gap: 12px; padding: 12px 14px; background: var(--field); border-radius: 16px; margin-bottom: 8px; }
    .timer svg { flex: none; }
    .timer .what { flex: 1; min-width: 0; }
    .timer .left { font-size: 30px; font-variant-numeric: tabular-nums; line-height: 1.1; }
    .timer .title { color: var(--secondary); font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .timer .controls { display: flex; gap: 4px; }
    .timer .controls button { border: 0; background: transparent; padding: 8px 7px; font-size: 16px; color: var(--secondary); }
    .timer .controls button.stop { color: var(--ink); }
    .timer.paused .left { color: var(--faint); }
    ul { list-style: none; margin: 0; padding: 0; }
    li.task { position: relative; overflow: hidden; border-bottom: 1px solid var(--rule); transition: opacity 0.25s; }
    li.task.going { opacity: 0; }
    li.task .front { display: flex; align-items: flex-start; gap: 12px; padding: 11px 2px; background: var(--paper); position: relative; transition: transform 0.22s; }
    li.task .behind { position: absolute; inset: 0; display: none; align-items: center; padding: 0 18px; color: white; font-size: 17px; }
    li.task.right .behind { display: flex; justify-content: flex-start; background: rgba(168, 90, 80, 0.6); }
    li.task.left .behind { display: flex; justify-content: flex-end; background: rgba(151, 141, 121, 0.6); }
    li.task.right.reached .behind { background: var(--late); }
    li.task.left.reached .behind { background: var(--accent); }
    li.task.right .behind .prog, li.task.left .behind .del { display: none; }
    .circle { flex: none; width: 24px; height: 24px; margin-top: 1px; border-radius: 50%; border: 1.4px solid var(--faint); background: transparent; padding: 0; position: relative; transition: transform 0.2s; }
    .circle.done { background: var(--accent); border-color: var(--accent); transform: scale(1.08); }
    .circle.done::after { content: ""; position: absolute; left: 7.5px; top: 3.5px; width: 6px; height: 11px; border: solid white; border-width: 0 2.2px 2.2px 0; transform: rotate(45deg); }
    .task .body { flex: 1; min-width: 0; }
    .task .name { font-size: 19px; line-height: 1.25; }
    .task .meta { font-size: 14px; color: var(--secondary); margin-top: 2px; }
    .task .meta .late { color: rgba(168, 90, 80, 0.8); }
    .task .meta .progress { color: var(--accent); }
    .task .clock { flex: none; border: 0; background: transparent; color: var(--faint); padding: 2px 4px; font-size: 15px; }
    .task .clock.running { color: var(--accent); }
    h2.group { cursor: pointer; justify-content: flex-start; gap: 6px; }
    h2.group .count { margin-left: auto; }
    h2.group .name { color: var(--ink); font-weight: bold; font-size: 17px; }
    h2.group .mark { color: var(--ink); font-size: 17px; }
    h2.group .fold { color: var(--faint); font-weight: normal; font-size: 12px; }
    .swipe-hint { color: var(--faint); font-size: 14px; margin: 6px 0 0; }
    .task .timers { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; margin-top: 10px; }
    .faint { color: var(--faint); font-size: 15px; }
    #toast { position: fixed; left: 14px; right: 14px; bottom: calc(env(safe-area-inset-bottom) + 14px); background: var(--ink); color: var(--paper); border-radius: 14px;
             padding: 13px 16px; display: flex; justify-content: space-between; align-items: center; font-size: 17px; transition: opacity 0.2s; }
    #toast button { border: 0; background: transparent; color: var(--paper); text-decoration: underline; font-size: 17px; padding: 0 0 0 12px; }
    #ringing { display: flex; align-items: center; gap: 10px; background: rgba(151, 141, 121, 0.16); border-radius: 16px; padding: 14px 16px; margin-bottom: 14px; font-size: 18px; }
    #ringing span { flex: 1; }
    #ringing button { border: 0; background: var(--paper); border-radius: 10px; padding: 8px 12px; font-size: 16px; }
    #hint { color: var(--faint); font-size: 15px; text-align: center; margin-top: 30px; }
    #hint button { border: 0; background: transparent; color: var(--faint); font-size: 15px; }
    #pair { max-width: 360px; margin: 18vh auto 0; text-align: center; }
    #pair p { color: var(--secondary); font-size: 18px; }
    #code { width: 100%; text-align: center; font: inherit; font-size: 34px; letter-spacing: 8px; border: 0; background: var(--field); border-radius: 16px; padding: 14px; outline: none; color: var(--ink); }
    #pairButton { margin-top: 12px; width: 100%; height: 52px; border: 0; border-radius: 14px; background: var(--ink); color: var(--paper); font-size: 20px; }
    #pairError { color: var(--late); min-height: 1.4em; }
    </style>
    </head>
    <body>
    <main id="app" hidden>
      <header><h1>toyl</h1><span id="mac"></span></header>
      <div id="ringing" hidden><span id="ringText"></span><button id="ringMore">5 more</button><button id="ringOk">ok</button></div>
      <form id="add" autocomplete="off">
        <div class="field">
          <input id="text" placeholder="new task" enterkeyhint="send" autocapitalize="none" spellcheck="true">
          <button id="addButton" type="submit" aria-label="add" disabled>↑</button>
        </div>
        <div id="tokens" class="tokens"></div>
        <div id="lists" class="chips" aria-label="list"></div>
      </form>
      <h2>timers</h2>
      <div id="timers"></div>
      <div id="presets" class="presets"></div>
      <label class="on-what">on <input id="label" placeholder="anything" autocapitalize="none"></label>
      <div id="groups"></div>
      <p class="swipe-hint">swipe left: in progress · swipe right: delete</p>
      <p id="hint" hidden>share › add to home screen <button id="hintClose" aria-label="close">×</button></p>
    </main>
    <main id="pair" hidden>
      <h1>toyl</h1>
      <p>on the mac: settings › iphone › pair</p>
      <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="code">
      <button id="pairButton">pair</button>
      <p id="pairError"></p>
    </main>
    <div id="toast" hidden><span id="toastText"></span><button id="toastUndo" hidden>undo</button></div>
    <script src="/app.js"></script>
    </body>
    </html>
    """#

    static let script = #"""
    "use strict";
    const $ = (id) => document.getElementById(id);
    let state = null, offset = 0, list = null, timerFor = null, toastTimer = null, parseTimer = null, sending = false;

    function read(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch (e) { return fallback; } }
    function keep(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {} }
    let queue = read("toyl.queue", []);
    list = read("toyl.list", null);

    async function api(path, body) {
      const options = body
        ? { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json", "X-Toyl": "1" }, body: JSON.stringify(body) }
        : { cache: "no-store", credentials: "same-origin" };
      const response = await fetch(path, options);
      if (response.status === 401) { unpaired(); throw Object.assign(new Error("unpaired"), { unpaired: true }); }
      const json = await response.json().catch(() => ({}));
      if (!response.ok) throw Object.assign(new Error(json.error || "something went wrong"), { said: true });
      return json;
    }

    function el(tag, className, text) {
      const made = document.createElement(tag);
      if (className) made.className = className;
      if (text !== undefined) made.textContent = text;
      return made;
    }

    function nowHere() { return Date.now() / 1000 + offset; }

    function clock(seconds, up) {
      const total = Math.max(up ? Math.floor(seconds) : Math.ceil(seconds - 0.001), 0);
      const h = Math.floor(total / 3600), m = Math.floor(total % 3600 / 60), s = total % 60;
      return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
    }

    function length(minutes) {
      if (minutes % 60 === 0) return `${minutes / 60}h`;
      return minutes > 60 ? `${Math.floor(minutes / 60)}h${minutes % 60}m` : `${minutes}m`;
    }

    async function load() {
      try {
        show(await api("/api/state"));
        $("mac").textContent = state.mac.toLowerCase();
        $("mac").classList.remove("off");
        flush();
      } catch (error) {
        if (error.unpaired) return;
        $("mac").textContent = "can't reach the mac";
        $("mac").classList.add("off");
      }
    }

    function show(next) {
      state = next;
      offset = state.now - Date.now() / 1000;
      $("pair").hidden = true;
      $("app").hidden = false;
      drawLists();
      drawPresets();
      drawTimers();
      drawGroups();
      $("ringing").hidden = !state.ringing;
      if (state.ringing) $("ringText").textContent = `${state.ringing}: done`;
    }

    // adding

    function drawLists() {
      const box = $("lists");
      box.replaceChildren();
      const all = [{ id: null, name: "auto" }].concat(state.lists);
      if (list && !state.lists.some((l) => l.id === list)) list = null;
      for (const item of all) {
        const chip = el("button", "chip" + (item.id === list ? " on" : ""));
        chip.type = "button";
        if (item.mark) {
          const mark = el("span", "mark", item.mark);
          if (item.id !== list && !/\p{Extended_Pictographic}/u.test(item.mark)) mark.style.color = item.color;
          chip.append(mark);
        }
        chip.append(document.createTextNode(item.name.toLowerCase()));
        chip.addEventListener("click", () => { list = item.id; keep("toyl.list", list); drawLists(); $("text").focus(); });
        box.append(chip);
      }
    }

    $("text").addEventListener("input", () => {
      const text = $("text").value;
      $("addButton").disabled = !text.trim();
      clearTimeout(parseTimer);
      if (!text.trim()) { $("tokens").replaceChildren(); return; }
      parseTimer = setTimeout(async () => {
        try {
          const read = await api("/api/parse?text=" + encodeURIComponent(text));
          if ($("text").value !== text) return;
          $("tokens").replaceChildren(...read.tokens.map((token) => el("span", "token", token)));
        } catch (e) {}
      }, 220);
    });

    $("add").addEventListener("submit", async (event) => {
      event.preventDefault();
      const text = $("text").value.trim();
      if (!text) return;
      $("text").value = "";
      $("addButton").disabled = true;
      $("tokens").replaceChildren();
      $("text").focus();
      const body = { do: "add", text };
      if (list) body.list = list;
      try {
        const done = await api("/api/do", body);
        show(done.state);
        const added = done.added;
        say(done.said || "added", added ? async () => { try { show((await api("/api/do", { do: "remove", id: added.id })).state); say("taken back"); } catch (e) {} } : null);
      } catch (error) {
        if (error.unpaired) return;
        if (error.said) return say(error.message);
        queue.push(body);
        keep("toyl.queue", queue);
        say("kept here · it goes when the mac's back");
      }
    });

    async function flush() {
      if (sending || !queue.length) return;
      sending = true;
      try {
        while (queue.length) {
          const done = await api("/api/do", queue[0]);
          queue.shift();
          keep("toyl.queue", queue);
          show(done.state);
        }
        say("sent what was kept");
      } catch (e) {} finally { sending = false; }
    }

    // timers

    function drawPresets() {
      const box = $("presets");
      if (box.childElementCount) return;
      for (const minutes of state.presets) {
        const button = el("button", "preset", length(minutes));
        button.addEventListener("click", () => startTimer({ minutes }));
        box.append(button);
      }
      const watch = el("button", "preset", "stopwatch");
      watch.addEventListener("click", () => startTimer({ stopwatch: true }));
      box.append(watch);
    }

    async function startTimer(how, task) {
      const body = Object.assign({ do: "timer" }, how);
      if (task) body.id = task;
      else if ($("label").value.trim()) body.label = $("label").value.trim();
      try {
        show((await api("/api/do", body)).state);
        $("label").value = "";
        timerFor = null;
        drawGroups();
      } catch (error) { if (error.said) say(error.message); }
    }

    function ring(fraction, running) {
      const r = 15, c = 2 * Math.PI * r;
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("width", "38"); svg.setAttribute("height", "38"); svg.setAttribute("viewBox", "0 0 38 38");
      const back = document.createElementNS(svg.namespaceURI, "circle");
      back.setAttribute("cx", "19"); back.setAttribute("cy", "19"); back.setAttribute("r", r); back.setAttribute("fill", "none");
      back.setAttribute("stroke", "#e6e6e3"); back.setAttribute("stroke-width", "3");
      const front = back.cloneNode();
      front.setAttribute("stroke", running ? "#978d79" : "#a6a6a2");
      front.setAttribute("stroke-linecap", "round");
      front.setAttribute("stroke-dasharray", `${c * Math.max(Math.min(fraction, 1), 0)} ${c}`);
      front.setAttribute("transform", "rotate(-90 19 19)");
      front.classList.add("arc");
      svg.append(back, front);
      return svg;
    }

    function timerLeft(timer) {
      if (timer.stopwatch) return timer.elapsed + (timer.since ? nowHere() - timer.since : 0);
      if (timer.ends) return Math.max(timer.ends - nowHere(), 0);
      return timer.left ?? timer.duration;
    }

    function drawTimers() {
      const box = $("timers");
      box.replaceChildren();
      for (const timer of state.timers) {
        const running = timer.stopwatch ? !!timer.since : !!timer.ends;
        const card = el("div", "timer" + (running ? "" : " paused"));
        card.dataset.id = timer.id;
        card.append(timer.stopwatch ? el("span", "faint", "◷") : ring(timerLeft(timer) / timer.duration, running));
        const what = el("div", "what");
        what.append(el("div", "left", clock(timerLeft(timer), timer.stopwatch)), el("div", "title", timer.title.toLowerCase()));
        const controls = el("div", "controls");
        const pause = el("button", "", running ? "pause" : "go on");
        pause.addEventListener("click", () => act({ do: "pause", id: timer.id }));
        controls.append(pause);
        if (!timer.stopwatch) {
          const more = el("button", "", "+5");
          more.addEventListener("click", () => act({ do: "more", id: timer.id, minutes: 5 }));
          controls.append(more);
        }
        const stop = el("button", "stop", "stop");
        stop.addEventListener("click", () => act({ do: "stop", id: timer.id }));
        controls.append(stop);
        card.append(what, controls);
        box.append(card);
      }
    }

    function tick() {
      if (!state) return;
      for (const card of $("timers").children) {
        const timer = state.timers.find((t) => t.id === card.dataset.id);
        if (!timer) continue;
        card.querySelector(".left").textContent = clock(timerLeft(timer), timer.stopwatch);
        const arc = card.querySelector(".arc");
        if (arc) {
          const c = 2 * Math.PI * 15;
          arc.setAttribute("stroke-dasharray", `${c * Math.max(Math.min(timerLeft(timer) / timer.duration, 1), 0)} ${c}`);
        }
        if (!timer.stopwatch && timer.ends && timerLeft(timer) <= 0) load();
      }
    }

    async function act(body) {
      try { show((await api("/api/do", body)).state); } catch (error) { if (error.said) say(error.message); }
    }

    $("ringOk").addEventListener("click", () => act({ do: "dismiss" }));
    $("ringMore").addEventListener("click", () => act({ do: "snooze" }));

    // lists

    let folded = new Set(read("toyl.folded", []));
    let touching = false, stale = false;

    function drawGroups() {
      if (touching) { stale = true; return; }
      const box = $("groups");
      box.replaceChildren();
      for (const group of state.groups) {
        const head = el("h2", "group");
        if (group.mark) {
          const mark = el("span", "mark", group.mark);
          if (!/\p{Extended_Pictographic}/u.test(group.mark)) mark.style.color = group.color;
          head.append(mark);
        }
        head.append(el("span", "name", group.name.toLowerCase()));
        const isFolded = folded.has(group.id);
        head.append(el("span", "fold", isFolded ? "›" : "⌄"), el("span", "count", group.tasks.length ? String(group.tasks.length) : ""));
        head.addEventListener("click", () => {
          if (folded.has(group.id)) folded.delete(group.id); else folded.add(group.id);
          keep("toyl.folded", [...folded]);
          drawGroups();
        });
        box.append(head);
        if (isFolded) continue;
        const list = el("ul");
        for (const task of group.tasks) list.append(taskRow(task));
        box.append(list);
      }
    }

    function taskRow(task) {
      const row = el("li", "task");
      const behind = el("div", "behind");
      behind.append(el("span", "del", "delete"), el("span", "prog", task.progress ? "back to to-do" : "in progress"));
      const front = el("div", "front");
      const circle = el("button", "circle");
      circle.setAttribute("aria-label", "check off");
      circle.addEventListener("click", () => check(task, row, circle));
      const body = el("div", "body");
      body.append(el("div", "name", task.title));
      const meta = el("div", "meta");
      const parts = [];
      if (task.progress) parts.push(el("span", "progress", "◐ in progress"));
      if (task.when) parts.push(el("span", task.late ? "late" : "", task.when));
      if (task.email) parts.push(document.createTextNode("✉ email"));
      if (task.sublist) parts.push(document.createTextNode(`${task.sublist} in its sublist`));
      parts.forEach((part, index) => { if (index) meta.append(document.createTextNode("  ·  ")); meta.append(part); });
      if (parts.length) body.append(meta);
      if (timerFor === task.id) {
        const lengths = el("div", "timers");
        for (const minutes of state.presets) {
          const button = el("button", "preset small", length(minutes));
          button.addEventListener("click", () => startTimer({ minutes }, task.id));
          lengths.append(button);
        }
        const watch = el("button", "preset small", "stopwatch");
        watch.addEventListener("click", () => startTimer({ stopwatch: true }, task.id));
        lengths.append(watch);
        body.append(lengths);
      }
      const time = el("button", "clock" + (task.timer ? " running" : ""), task.timer ? "timing" : "timer");
      time.addEventListener("click", () => { timerFor = timerFor === task.id ? null : task.id; drawGroups(); });
      front.append(circle, body, time);
      row.append(behind, front);
      swipeable(row, front, task);
      return row;
    }

    // Swiping, as Apple's lists do: left for in progress, right to delete.
    function swipeable(row, front, task) {
      let x0 = 0, y0 = 0, dx = 0, sideways = null;
      row.addEventListener("touchstart", (event) => {
        const touch = event.touches[0];
        x0 = touch.clientX; y0 = touch.clientY; dx = 0; sideways = null;
        touching = true;
        front.style.transition = "none";
      }, { passive: true });
      row.addEventListener("touchmove", (event) => {
        const touch = event.touches[0], mx = touch.clientX - x0, my = touch.clientY - y0;
        if (sideways === null) {
          if (Math.abs(mx) > 10 && Math.abs(mx) > Math.abs(my) * 1.3) sideways = true;
          else if (Math.abs(my) > 10) sideways = false;
        }
        if (!sideways) return;
        event.preventDefault();
        dx = Math.max(Math.min(mx, 170), -170);
        front.style.transform = `translateX(${dx}px)`;
        row.classList.toggle("right", dx > 0);
        row.classList.toggle("left", dx < 0);
        row.classList.toggle("reached", Math.abs(dx) >= 80);
      }, { passive: false });
      const finish = () => {
        front.style.transition = "transform 0.22s";
        if (sideways && dx <= -80) {
          front.style.transform = "";
          progress(task);
        } else if (sideways && dx >= 80) {
          front.style.transform = "translateX(110%)";
          remove(task, row, front);
        } else {
          front.style.transform = "";
        }
        setTimeout(() => row.classList.remove("left", "right", "reached"), 230);
        touching = false;
        if (stale) { stale = false; setTimeout(drawGroups, 260); }
      };
      row.addEventListener("touchend", finish);
      row.addEventListener("touchcancel", finish);
    }

    async function progress(task) {
      try {
        const done = await api("/api/do", { do: "progress", id: task.id });
        show(done.state);
        say(done.said);
      } catch (error) { if (error.said) say(error.message); }
    }

    async function remove(task, row, front) {
      row.classList.add("going");
      try {
        const done = await api("/api/do", { do: "delete", id: task.id });
        setTimeout(() => show(done.state), 240);
        say("deleted", async () => { try { show((await api("/api/do", { do: "restore" })).state); say("put back"); } catch (e) {} });
      } catch (error) {
        row.classList.remove("going");
        front.style.transform = "";
        if (error.said) say(error.message);
      }
    }

    async function check(task, row, circle) {
      circle.classList.add("done");
      setTimeout(() => row.classList.add("going"), 300);
      try {
        const done = await api("/api/do", { do: "done", id: task.id });
        setTimeout(() => show(done.state), 520);
        say("checked off", async () => { try { show((await api("/api/do", { do: "undone", id: task.id })).state); } catch (e) {} });
      } catch (error) {
        circle.classList.remove("done");
        row.classList.remove("going");
        if (error.said) say(error.message);
      }
    }

    // saying things

    function say(text, undo) {
      $("toastText").textContent = text;
      $("toastUndo").hidden = !undo;
      $("toastUndo").onclick = undo ? () => { $("toast").hidden = true; undo(); } : null;
      $("toast").hidden = false;
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => { $("toast").hidden = true; }, undo ? 5000 : 2600);
    }

    // pairing

    function unpaired() {
      $("app").hidden = true;
      $("pair").hidden = false;
      if (location.search.includes("unpaired")) $("pairError").textContent = "that code didn't work: ask the mac for a new one";
    }

    $("pairButton").addEventListener("click", async () => {
      const code = $("code").value.replace(/\D/g, "");
      if (code.length !== 6) { $("pairError").textContent = "six digits"; return; }
      try {
        await api("/api/pair", { code });
        location.replace("/");
      } catch (error) { $("pairError").textContent = error.message; }
    });

    // the home screen

    if (!navigator.standalone && !read("toyl.hint", false)) $("hint").hidden = false;
    $("hintClose").addEventListener("click", () => { keep("toyl.hint", true); $("hint").hidden = true; });

    load();
    setInterval(() => { if (!document.hidden) load(); }, 4000);
    setInterval(tick, 1000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
    """#

    static let manifest = #"""
    {"name": "toyl", "short_name": "toyl", "start_url": "/", "display": "standalone", "background_color": "#fbfbfa",
     "theme_color": "#fbfbfa", "icons": [{"src": "/icon.png", "sizes": "180x180", "type": "image/png"}]}
    """#

    /// toyl's icon, for the home screen.
    @MainActor static let icon: Data = {
        let side = 180
        let image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        Theme.nsPaper.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // The Mac icon has a margin round it; the phone wants it edge to edge.
        image.draw(in: NSRect(x: -18, y: -18, width: side + 36, height: side + 36))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }()
}
