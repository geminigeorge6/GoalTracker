import SwiftUI
import Combine
import UIKit

struct ContentView: View {
    @AppStorage("app_language") private var appLanguage = "zh"

    var body: some View {
        TabView {
            LocalTrackerView(appLanguage: $appLanguage)
                .tabItem { Label("Tracker", systemImage: "calendar") }
            
            AIPriorityView(appLanguage: $appLanguage)
                .tabItem { Label("AI", systemImage: "sparkles") }
            
            GTFriendsView()
                .tabItem { Label("Friends", systemImage: "person.2") }

            GTSharedGoalsView()
                .tabItem { Label("Shared", systemImage: "eye") }

            GTSocialSettingsView(appLanguage: $appLanguage)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: - Local Tracker

struct LocalGoal: Identifiable, Codable {
    let id: UUID
    var title: String
    var checkedDates: Set<String>
    var colorHex: String

    init(id: UUID = UUID(), title: String, checkedDates: Set<String> = [], colorHex: String) {
        self.id = id
        self.title = title
        self.checkedDates = checkedDates
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, title, checkedDates, colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        checkedDates = try c.decode(Set<String>.self, forKey: .checkedDates)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#3B82F6"
    }
}

struct CalendarDay: Identifiable {
    let id = UUID()
    let date: Date?
}

struct GoalDot: Identifiable {
    let id: UUID
    let color: Color
    let isDone: Bool
}

final class LocalGoalStore: ObservableObject {
    @Published var goals: [LocalGoal] = [] { didSet { save() } }

    private let key = "local_goal_tracker_pretty_v5"
    private let palette = ["#3B82F6", "#EF4444", "#10B981", "#F59E0B", "#8B5CF6", "#06B6D4"]

    init() { load() }

    func addGoal(title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let c = palette[goals.count % palette.count]
        goals.append(LocalGoal(title: t, colorHex: c))
    }

    func deleteGoal(at offsets: IndexSet) {
        goals.remove(atOffsets: offsets)
    }

    func toggle(goal: LocalGoal, on date: Date) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        let k = Self.dateKey(from: date)
        if goals[i].checkedDates.contains(k) {
            goals[i].checkedDates.remove(k)
        } else {
            goals[i].checkedDates.insert(k)
        }
    }

    func isDone(_ goal: LocalGoal, on date: Date) -> Bool {
        goal.checkedDates.contains(Self.dateKey(from: date))
    }

    func doneCount(on date: Date) -> Int {
        goals.filter { isDone($0, on: date) }.count
    }

    func dots(on date: Date) -> [GoalDot] {
        goals.map { g in
            GoalDot(id: g.id, color: Color(hex: g.colorHex), isDone: isDone(g, on: date))
        }
    }

    func currentStreak(for goal: LocalGoal, until reference: Date = Date()) -> Int {
        let cal = Calendar.current
        let done = Set(goal.checkedDates.compactMap { Self.dateFromKey($0) }.map { cal.startOfDay(for: $0) })
        var streak = 0
        var cursor = cal.startOfDay(for: reference)

        while done.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    func weekDoneDays(for goal: LocalGoal, reference: Date = Date()) -> Int {
        let cal = Calendar.current
        let done = Set(goal.checkedDates.compactMap { Self.dateFromKey($0) }.map { cal.startOfDay(for: $0) })
        let ref = cal.startOfDay(for: reference)

        var count = 0
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: -i, to: ref), done.contains(d) { count += 1 }
        }
        return count
    }

    func monthDoneDays(for goal: LocalGoal, month: Date) -> Int {
        let cal = Calendar.current
        let done = Set(goal.checkedDates.compactMap { Self.dateFromKey($0) }.map { cal.startOfDay(for: $0) })

        guard let range = cal.range(of: .day, in: .month, for: month),
              let start = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return 0 }

        var c = 0
        for day in range {
            guard let d = cal.date(byAdding: .day, value: day - 1, to: start) else { continue }
            if done.contains(cal.startOfDay(for: d)) { c += 1 }
        }
        return c
    }

    func monthPerfectDays(for month: Date) -> Int {
        let cal = Calendar.current
        guard !goals.isEmpty,
              let range = cal.range(of: .day, in: .month, for: month),
              let start = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return 0 }

        let today = cal.startOfDay(for: Date())
        var c = 0
        for day in range {
            guard let d = cal.date(byAdding: .day, value: day - 1, to: start) else { continue }
            if cal.startOfDay(for: d) > today { continue }
            if doneCount(on: d) == goals.count { c += 1 }
        }
        return c
    }

    static func dateKey(from date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func dateFromKey(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LocalGoal].self, from: data) else { return }
        goals = decoded
    }
}

struct LocalTrackerView: View {
    @Binding var appLanguage: String
    @StateObject private var store = LocalGoalStore()
    @StateObject private var fm = FirebaseManager.shared

    @State private var input = ""
    @State private var selectedDate = Date()
    @State private var displayMonth = Date()
    @State private var selectedGoalID: UUID?
    @State private var info: String?
    @FocusState private var focused: Bool

    private let cal = Calendar.current

    private func t(_ zh: String, _ en: String) -> String {
        appLanguage == "zh" ? zh : en
    }

    private var weekLabels: [String] {
        appLanguage == "zh"
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    private var selectedGoal: LocalGoal? {
        guard let id = selectedGoalID else { return nil }
        return store.goals.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    topCard
                    monthHeader
                    calendarGrid
                    inputRow

                    if let goal = selectedGoal {
                        summaryCard(goal: goal)
                    }

                    goalList
                }
                .padding(.vertical, 8)
            }
            .background(
                LinearGradient(
                    colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "target").foregroundColor(.blue)
                        Text(t("目标达成器", "Goal Tracker")).font(.headline)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(t("完成", "Done")) { focused = false }
                }
            }
            .alert("Message", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) { info = nil }
            } message: {
                Text(info ?? "")
            }
        }
    }

    private var topCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monthTitle(displayMonth)).font(.title3.weight(.semibold))
            Text("\(t("今日完成", "Today")): \(store.doneCount(on: selectedDate))/\(store.goals.count)")
                .font(.subheadline)
            Text("\(t("本月全完成天数", "Perfect days this month")): \(store.monthPerfectDays(for: displayMonth))")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.15), Color.cyan.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .padding(.horizontal)
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(monthTitle(displayMonth)).font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal)
    }

    private var calendarGrid: some View {
        let days = makeCalendarDays(for: displayMonth)

        return VStack(spacing: 8) {
            HStack {
                ForEach(weekLabels, id: \.self) { s in
                    Text(s).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(days) { item in
                    if let date = item.date {
                        CalendarDayCell(
                            day: cal.component(.day, from: date),
                            dots: store.dots(on: date),
                            isSelected: cal.isDate(date, inSameDayAs: selectedDate),
                            isFuture: cal.startOfDay(for: date) > cal.startOfDay(for: Date())
                        )
                        .onTapGesture {
                            selectedDate = date
                            focused = false
                        }
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var inputRow: some View {
        HStack {
            TextField(t("输入目标，例如：读书30分钟", "Enter goal title"), text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)

            Button(t("添加", "Add")) {
                store.addGoal(title: input)
                input = ""
                focused = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
    }

    private func summaryCard(goal: LocalGoal) -> some View {
        let week = store.weekDoneDays(for: goal, reference: selectedDate)
        let month = store.monthDoneDays(for: goal, month: displayMonth)
        let streak = store.currentStreak(for: goal, until: selectedDate)
        let color = Color(hex: goal.colorHex)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text("\(t("目标总结", "Summary")) · \(goal.title)").font(.headline)
                Spacer()
                Button(t("收起", "Hide")) { selectedGoalID = nil }
                    .font(.caption)
            }

            Text("\(t("今日", "Today")): \(store.isDone(goal, on: selectedDate) ? t("已完成", "Done") : t("未完成", "Not done"))")
            Text("\(t("连续打卡", "Streak")): \(streak) \(t("天", "days"))")
            Text("\(t("近7天", "Last 7 days")): \(week)/7")
            Text("\(t("本月完成", "This month")): \(month)")
            Text("\(t("累计完成", "Total")): \(goal.checkedDates.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35), lineWidth: 1))
        .padding(.horizontal)
    }

    private var goalList: some View {
        VStack(spacing: 8) {
            ForEach(store.goals) { goal in
                let done = store.isDone(goal, on: selectedDate)

                HStack(spacing: 10) {
                    Button {
                        store.toggle(goal: goal, on: selectedDate)
                    } label: {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(done ? .green : .gray)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: goal.colorHex))
                        .frame(width: 6, height: 24)

                    Text(goal.title)
                    Spacer()

                    Button {
                        Task {
                            do {
                                try await fm.createGoal(title: goal.title, colorHex: goal.colorHex)
                                info = t("已上传到云端，可到 Shared 页面分享", "Uploaded to cloud. Share it in Shared tab.")
                            } catch {
                                info = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    if selectedGoalID == goal.id {
                        Image(systemName: "chart.bar.fill").foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedGoalID == goal.id ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
                )
                .padding(.horizontal)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedGoalID = (selectedGoalID == goal.id) ? nil : goal.id
                    focused = false
                }
            }

            if !store.goals.isEmpty {
                Button(role: .destructive) {
                    if let last = store.goals.indices.last {
                        store.deleteGoal(at: IndexSet(integer: last))
                    }
                } label: {
                    Text(t("删除最后一个目标", "Delete last goal")).font(.footnote)
                }
                .padding(.top, 6)
            }
        }
    }

    private func makeCalendarDays(for month: Date) -> [CalendarDay] {
        guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let dayRange = cal.range(of: .day, in: .month, for: firstDay) else { return [] }

        let firstWeekday = cal.component(.weekday, from: firstDay)
        let leading = firstWeekday - 1

        var result: [CalendarDay] = Array(repeating: CalendarDay(date: nil), count: leading)
        for d in dayRange {
            if let date = cal.date(byAdding: .day, value: d - 1, to: firstDay) {
                result.append(CalendarDay(date: date))
            }
        }
        return result
    }

    private func shiftMonth(_ delta: Int) {
        guard let m = cal.date(byAdding: .month, value: delta, to: displayMonth) else { return }
        displayMonth = m
    }

    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        if appLanguage == "zh" {
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy年M月"
        } else {
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMMM yyyy"
        }
        return f.string(from: date)
    }
}

struct CalendarDayCell: View {
    let day: Int
    let dots: [GoalDot]
    let isSelected: Bool
    let isFuture: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day)")
                .font(.caption2)
                .foregroundColor(isFuture ? .gray : .primary)

            HStack(spacing: 2) {
                ForEach(dots.prefix(4)) { dot in
                    Circle()
                        .fill(dot.isDone ? dot.color : Color.gray.opacity(0.2))
                        .frame(width: 5, height: 5)
                }

                if dots.count > 4 {
                    Text("+\(dots.count - 4)")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 8)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue : Color.gray.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        )
        .opacity(isFuture ? 0.65 : 1)
    }
}

// MARK: - Social

struct GTFriendsView: View {
    @StateObject private var fm = FirebaseManager.shared
    @State private var friendUidInput = ""
    @State private var info: String?

    private var shortUID: String {
        guard !fm.uid.isEmpty else { return "-" }
        return String(fm.uid.prefix(8)) + "..."
    }

    var body: some View {
        NavigationView {
            List {
                Section("Add Friend by UID") {
                    HStack {
                        Text("My UID")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(shortUID)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Copy") {
                            UIPasteboard.general.string = fm.uid
                            info = "UID copied"
                        }
                        .font(.caption)
                    }

                    TextField("Friend UID", text: $friendUidInput)

                    Button("Send Request") {
                        Task {
                            let id = friendUidInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !id.isEmpty else { return }
                            do {
                                try await fm.sendFriendRequest(to: id)
                                friendUidInput = ""
                                info = "Request sent"
                            } catch {
                                info = error.localizedDescription
                            }
                        }
                    }
                }

                Section("Incoming Requests") {
                    ForEach(fm.incomingRequests, id: \.id) { req in
                        HStack {
                            Text(req.requesterId)
                            Spacer()
                            Button("Accept") {
                                Task {
                                    do {
                                        try await fm.acceptFriendRequest(req.id)
                                        info = "Accepted"
                                    } catch {
                                        info = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Friends") {
                    ForEach(fm.friends, id: \.id) { f in
                        Text("\(f.name) (\(f.id))")
                    }
                }
            }
            .navigationTitle("Friends")
            .alert("Message", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) { info = nil }
            } message: {
                Text(info ?? "")
            }
        }
    }
}

struct GTSharedGoalsView: View {
    @StateObject private var fm = FirebaseManager.shared
    @State private var cloudGoalTitle = ""
    @State private var info: String?

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var body: some View {
        NavigationView {
            List {
                Section("Create Cloud Goal (shareable)") {
                    TextField("Goal title", text: $cloudGoalTitle)
                    Button("Create") {
                        Task {
                            let t = cloudGoalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            do {
                                try await fm.createGoal(title: t)
                                cloudGoalTitle = ""
                                info = "Cloud goal created"
                            } catch {
                                info = error.localizedDescription
                            }
                        }
                    }
                }

                Section("My Cloud Goals (Share)") {
                    ForEach(fm.myGoals, id: \.id) { goal in
                        NavigationLink(goal.title) {
                            GTShareCloudGoalView(goal: goal)
                        }
                    }
                }

                Section("Goals Shared With Me") {
                    ForEach(fm.sharedGoals, id: \.id) { goal in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(goal.title).font(.headline)
                                Text("Owner: \(goal.ownerId)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Nudge") {
                                Task {
                                    do {
                                        try await fm.sendNudge(to: goal.ownerId, goalId: goal.id, dateKey: todayKey)
                                        info = "Nudge sent"
                                    } catch {
                                        info = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Shared")
            .alert("Message", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) { info = nil }
            } message: {
                Text(info ?? "")
            }
        }
    }
}

struct GTShareCloudGoalView: View {
    @StateObject private var fm = FirebaseManager.shared
    let goal: SharedGoal
    @State private var info: String?

    var body: some View {
        List {
            ForEach(fm.friends, id: \.id) { friend in
                HStack {
                    Text(friend.name)
                    Spacer()
                    Button("Share") {
                        Task {
                            do {
                                try await fm.shareGoal(goalId: goal.id, with: friend.id)
                                info = "Shared with \(friend.name)"
                            } catch {
                                info = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Share Goal")
        .alert("Message", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) { info = nil }
        } message: {
            Text(info ?? "")
        }
    }
}

struct GTSocialSettingsView: View {
    @Binding var appLanguage: String
    @StateObject private var fm = FirebaseManager.shared
    @State private var allow = true
    @State private var quietEnabled = false
    @State private var quietStart = 22
    @State private var quietEnd = 8
    @State private var info: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Language / 语言") {
                    Picker("App Language", selection: $appLanguage) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Account") {
                    if fm.authEmail.isEmpty {
                        Text("Current: Anonymous")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Current: \(fm.authEmail)")
                            .foregroundColor(.secondary)
                    }

                    if fm.isAnonymousUser {
                        NavigationLink("Sign Up / Log In") {
                            AuthView()
                        }
                    } else {
                        Text("Account linked")
                            .foregroundColor(.secondary)
                    }

                    Button("Sign Out", role: .destructive) {
                        do {
                            try fm.signOut()
                            fm.refreshAuthState()
                        } catch {
                            info = error.localizedDescription
                        }
                    }
                }

                Section("Friend Nudges") {
                    Toggle("Enable friend reminders", isOn: $allow)
                    Toggle("Quiet hours", isOn: $quietEnabled)
                    Stepper("Quiet start: \(quietStart):00", value: $quietStart, in: 0...23).disabled(!quietEnabled)
                    Stepper("Quiet end: \(quietEnd):00", value: $quietEnd, in: 0...23).disabled(!quietEnabled)

                    Button("Save") {
                        Task {
                            do {
                                try await fm.updateNudgeSettings(
                                    allow: allow,
                                    quietEnabled: quietEnabled,
                                    quietStart: quietStart,
                                    quietEnd: quietEnd
                                )
                                info = "Saved"
                            } catch {
                                info = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                fm.refreshAuthState()
                allow = fm.myProfile?.allowFriendNudges ?? true
                quietEnabled = fm.myProfile?.quietHoursEnabled ?? false
                quietStart = fm.myProfile?.quietStartHour ?? 22
                quietEnd = fm.myProfile?.quietEndHour ?? 8
            }
            .alert("Message", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) { info = nil }
            } message: {
                Text(info ?? "")
            }
        }
    }
}

// MARK: - Color Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: UInt64
        switch hex.count {
        case 6:
            r = (int >> 16) & 0xFF
            g = (int >> 8) & 0xFF
            b = int & 0xFF
        default:
            r = 59; g = 130; b = 246
        }

        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}

