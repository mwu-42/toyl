import SwiftUI

/// Putting something on Google Calendar: filled in from the task and the calendar rules, and
/// added only once nothing's missing (what's still needed is said underneath, in plain words).
struct AddToCalendarView: View {
    @ObservedObject var model: AppModel
    @Local var form: EventForm
    @Local private var working = false
    @Local private var failure: String?

    init(model: AppModel, form: EventForm) {
        self.model = model
        _form = Local(initialValue: form)
    }

    var body: some View {
        let bridge = model.calendar
        let outcome = bridge.outcome(for: form)
        let calendar = bridge.calendars.first { $0.id == form.calendarId }
        let sub = bridge.google.first { $0.id == form.calendarId }.flatMap { bridge.rules.sub(for: $0) }
        VStack(alignment: .leading, spacing: 13) {
            Text("add to google calendar").font(Theme.font(21, bold: true))
            DetailRow(label: "title", icon: "textformat") {
                PlainField(text: $form.title, placeholder: "what it's called", font: Theme.nsFont(16)).frame(height: 20)
            }
            let styled = CalendarStyle.title(form.title) + (form.tentative && !CalendarStyle.title(form.title).hasSuffix("?") ? "?" : "")
            if !styled.isEmpty, styled != form.title.trimmingCharacters(in: .whitespaces) {
                Text("goes on as “\(styled)”").font(Theme.small).foregroundStyle(Theme.secondary).padding(.leading, 88)
            }
            DetailRow(label: "calendar", icon: "calendar") {
                Menu {
                    ForEach(ordered) { info in
                        Button(name(of: info)) {
                            form.calendarId = info.id
                            form.label = nil
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let calendar { CalendarMark(title: calendar.title, color: calendar.color) }
                        MenuLabel(text: calendar.map(name(of:)) ?? "choose one", faint: calendar == nil)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if form.calendarId == nil, !form.reason.isEmpty, form.reason != "nothing says where it goes" {
                Text(form.reason).font(Theme.small).foregroundStyle(Theme.faint).padding(.leading, 88)
            }
            if let calendar, !(sub?.labels.isEmpty ?? true) || !calendar.labels.isEmpty {
                DetailRow(label: "label", icon: "tag") {
                    Menu {
                        Button("no label" + (sub?.none.map { ": " + $0 } ?? "")) { form.label = nil }
                        ForEach(labelNames(calendar: calendar, sub: sub), id: \.self) { label in Button(label) { form.label = label } }
                    } label: {
                        MenuLabel(text: form.label ?? ("no label" + (sub?.none.map { ": " + $0 } ?? "")), faint: form.label == nil)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            DetailRow(label: "day", icon: "sun.max") {
                PlainField(text: $form.day, placeholder: "fri, nov 30, tomorrow", font: Theme.nsFont(15)).frame(height: 19)
            }
            Toggle(isOn: $form.allDay) { Text("all day").font(Theme.font(15)) }.toggleStyle(.checkbox).padding(.leading, 88)
            if !form.allDay {
                DetailRow(label: "from", icon: "clock") {
                    PlainField(text: $form.start, placeholder: "3pm", font: Theme.nsFont(15)).frame(height: 19)
                }
                DetailRow(label: "to", icon: "clock.badge.checkmark") {
                    HStack(spacing: 10) {
                        PlainField(text: $form.end, placeholder: "4:30pm", font: Theme.nsFont(15)).frame(width: 90, height: 19)
                        Text("or for").font(Theme.small).foregroundStyle(Theme.faint)
                        PlainField(text: $form.length, placeholder: "1h", font: Theme.nsFont(15)).frame(height: 19)
                    }
                }
            }
            DetailRow(label: "where", icon: "mappin.and.ellipse") {
                PlainField(text: $form.location, placeholder: "blank, or the place", font: Theme.nsFont(15)).frame(height: 19)
            }
            DetailRow(label: "notes", icon: "text.alignleft") {
                ZStack(alignment: .topLeading) {
                    if form.description.isEmpty {
                        Text(sub?.descriptive == true ? "m can say more" : "blank, or “no food”")
                            .font(Theme.font(15)).foregroundStyle(Theme.faint).padding(.top, 1).padding(.leading, 5)
                    }
                    TextEditor(text: $form.description)
                        .font(Theme.font(15))
                        .scrollContentBackground(.hidden)
                        .frame(height: 52)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            }
            Toggle(isOn: $form.tentative) { Text("tentative ?").font(Theme.font(15)) }.toggleStyle(.checkbox).padding(.leading, 88)
            if CalendarPlanner.allHands.firstMatch(in: form.title, range: NSRange(location: 0, length: (form.title as NSString).length)) != nil {
                Toggle(isOn: $form.margs) { Text("+ margs 8:30-9pm").font(Theme.font(15)) }.toggleStyle(.checkbox).padding(.leading, 88)
            }
            if !outcome.questions.isEmpty || !outcome.notes.isEmpty || failure != nil {
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.questions, id: \.self) { Text($0).font(Theme.font(14.5)).foregroundStyle(Theme.ink) }
                    ForEach(outcome.notes, id: \.self) { Text($0).font(Theme.small).foregroundStyle(Theme.secondary) }
                    if let failure { Text(failure).font(Theme.small).foregroundStyle(Theme.late) }
                }
            }
            HStack(spacing: 18) {
                Spacer()
                Quiet(label: "cancel") { model.calendarForm = nil }
                Quiet(label: working ? "adding…" : outcome.plans.count > 1 ? "add both" : "add", tint: outcome.questions.isEmpty ? Theme.ink : Theme.faint) {
                    guard outcome.questions.isEmpty, !working else { return }
                    add()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 540)
        .background(Theme.paper)
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
    }

    /// The calendars in the rules' order (♡, a, c…), then any others that can be added to.
    private var ordered: [CalInfo] {
        let bridge = model.calendar
        let ruled = bridge.rules.calendars.compactMap { sub in
            bridge.rules.calendar(for: sub, in: bridge.google).flatMap { g in bridge.calendars.first { $0.id == g.id } }
        }
        let rest = bridge.calendars.filter { info in info.writable && !ruled.contains(where: { $0.id == info.id }) }
        return ruled + rest
    }

    private func name(of info: CalInfo) -> String {
        let bridge = model.calendar
        guard let google = bridge.google.first(where: { $0.id == info.id }), let sub = bridge.rules.sub(for: google) else { return info.title.lowercased() }
        return sub.key == "♡" ? "♡ primary" : info.title.lowercased() + " " + sub.about
    }

    /// Its labels in Google, by name (the rules' first, in their order).
    private func labelNames(calendar: CalInfo, sub: CalendarRules.Sub?) -> [String] {
        let google = calendar.labels.map(\.name).filter { !$0.isEmpty }
        let ruled = (sub?.labels ?? []).filter { name in google.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        return ruled + google.filter { name in !ruled.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    private func add() {
        working = true
        failure = nil
        let filled = form
        Task { @MainActor in
            let error = await model.calendar.add(filled)
            working = false
            if let error { failure = error } else { model.calendarForm = nil }
        }
    }
}
