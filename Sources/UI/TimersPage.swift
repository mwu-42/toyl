import SwiftUI

/// Timers: type one as you'd say it ("25m essay", "10m tea", a task's name and a time to focus on
/// it), see what's going, and what's been timed today.
struct TimersPage: View {
    @ObservedObject var model: AppModel
    @Local private var text = ""

    var body: some View {
        let now = model.timers.now
        let snap = model.snap
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "timer").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    PlainField(text: $text, placeholder: "new timer", name: "timer", focus: model.focusQuick,
                               onSubmit: { if text.trimmingCharacters(in: .whitespaces).isEmpty { model.leaveTyping() } else { start() } },
                               onEscape: { if text.isEmpty { model.leaveTyping() } else { text = "" } },
                               onTab: { true })
                        .frame(height: 21)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                if let match = matchingTask {
                    Text("on “\(model.display(match.title))”, its time adding up there").font(Theme.meta).foregroundStyle(Theme.secondary)
                }
                if model.timers.timers.isEmpty {
                    Text("nothing going").font(Theme.font(17)).foregroundStyle(Theme.faint).padding(.top, 6)
                } else {
                    ForEach(model.timers.timers) { timer in
                        BigTimer(model: model, timer: timer, now: now).transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
                let today = Day.today(now)
                let log = snap.timerLog.filter { Day.string($0.ended) == today }
                if !log.isEmpty {
                    Hairline()
                    Label("timed today", systemImage: "clock.arrow.circlepath").font(Theme.font(15, bold: true))
                    let total = Int(log.reduce(0) { $0 + $1.seconds })
                    Text(Format.spent(total) + " in all").font(Theme.meta).foregroundStyle(Theme.secondary)
                    ForEach(log) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.display(entry.label)).font(Theme.font(15))
                            Spacer()
                            Text(Format.spent(Int(entry.seconds))).font(Theme.font(14).monospacedDigit()).foregroundStyle(Theme.secondary)
                            Text(Format.time(Day.clock(entry.ended))).font(Theme.meta).foregroundStyle(Theme.faint).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
    }

    /// A task named in what's typed: the timer goes on it.
    private var matchingTask: TaskModel? {
        let label = ReminderParser.parse(text.replacingOccurrences(of: "stopwatch", with: "")).label.trimmingCharacters(in: .whitespaces)
        guard label.count >= 3 else { return nil }
        let key = Query.fold(label)
        let open = model.snap.tasks.filter { !$0.done }
        return open.first { Query.fold($0.title) == key } ?? open.first { Query.fold($0.title).hasPrefix(key) }
    }

    private func start() {
        let stopwatch = text.lowercased().contains("stopwatch")
        let parsed = ReminderParser.parse(text.replacingOccurrences(of: "stopwatch", with: "", options: .caseInsensitive))
        let label = parsed.label.trimmingCharacters(in: .whitespaces)
        guard stopwatch || parsed.duration != nil || matchingTask != nil else { return }
        let task = matchingTask
        model.timers.start(task: task, minutes: parsed.duration.map { $0 / 60 }, stopwatch: stopwatch,
                           label: task == nil ? (label.isEmpty ? (stopwatch ? "stopwatch" : "timer") : label) : nil)
        text = ""
    }
}

/// A timer, big: its ring, its time, and what to do with it.
struct BigTimer: View {
    @ObservedObject var model: AppModel
    let timer: TimerModel
    let now: Date

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if timer.kind == .countdown {
                    Ring(fraction: timer.fractionLeft(at: now), size: 46, line: 3, color: timer.isRunning ? Theme.accent : Theme.faint)
                } else {
                    Circle().stroke(Theme.rule, lineWidth: 3).frame(width: 46, height: 46)
                    Image(systemName: "stopwatch").foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.kind == .countdown ? Format.clock(timer.remaining(at: now)) : Format.clock(timer.worked(at: now), roundingUp: false))
                    .font(Theme.font(30).monospacedDigit())
                    .foregroundStyle(timer.isRunning ? Theme.ink : Theme.secondary)
                HStack(spacing: 6) {
                    Text(model.display(timer.label)).font(Theme.font(15))
                    if timer.taskId != nil { Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                    if !timer.isRunning { Text("paused").font(Theme.meta).foregroundStyle(Theme.faint) }
                    if timer.mirroredByOyl { Text("on oyl's notch").font(Theme.meta).foregroundStyle(Theme.faint) }
                }
            }
            Spacer()
            Quiet(label: timer.isRunning ? "pause" : "go on") { model.timers.togglePause(timer.id) }
            if timer.kind == .countdown { Quiet(label: "+5") { model.timers.extend(timer.id, minutes: 5) } }
            Quiet(label: "stop", tint: Theme.ink) { model.timers.stop(timer.id) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
    }
}

/// What's going, along the foot of the window wherever you are.
struct TimerBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let now = model.timers.now
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 22) {
                ForEach(model.timers.timers.prefix(3)) { timer in
                    HStack(spacing: 8) {
                        if timer.kind == .countdown {
                            Ring(fraction: timer.fractionLeft(at: now), size: 14, line: 2, color: timer.isRunning ? Theme.accent : Theme.faint)
                            Text(Format.clock(timer.remaining(at: now))).font(Theme.font(15).monospacedDigit())
                        } else {
                            Image(systemName: "stopwatch").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Text(Format.clock(timer.worked(at: now), roundingUp: false)).font(Theme.font(15).monospacedDigit())
                        }
                        Text(model.display(timer.label)).font(Theme.font(14.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Quiet(label: "", symbol: timer.isRunning ? "pause.fill" : "play.fill", size: 11) { model.timers.togglePause(timer.id) }
                        Quiet(label: "", symbol: "stop.fill", size: 11) { model.timers.stop(timer.id) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let task = timer.taskId, model.snap.task(task) != nil { model.selection = [task]; model.anchor = task }
                    }
                }
                Spacer()
                Quiet(label: "timers") { model.place = .timers }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .background(Theme.sidebar)
        }
    }
}

/// A countdown that's just finished: done, five more minutes, or that's that.
struct RingingBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let rang = model.timers.ringing {
            VStack(spacing: 0) {
                Hairline()
                HStack(spacing: 18) {
                    Image(systemName: "bell").foregroundStyle(Theme.accent)
                    Text("“\(model.display(rang.label))” is up").font(Theme.font(16))
                    Spacer()
                    if let task = rang.taskId, model.snap.task(task)?.done == false {
                        Quiet(label: "check it off", symbol: "checkmark.circle", tint: Theme.ink) {
                            model.complete([task])
                            model.timers.dismissRinging()
                        }
                    }
                    Quiet(label: "5 more minutes") { model.timers.snooze(minutes: 5) }
                    Quiet(label: "ok") { model.timers.dismissRinging() }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(Theme.selectionFocused)
            }
        }
    }
}
