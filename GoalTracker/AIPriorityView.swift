import SwiftUI

struct AITask: Identifiable, Codable {
    let id: UUID
    var title: String
    var isCritical: Bool
    var isUrgent: Bool
    var estimateMinutes: Int
    var createdAt: Date
    var lastFeedbackHelpful: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        isCritical: Bool,
        isUrgent: Bool,
        estimateMinutes: Int,
        createdAt: Date = Date(),
        lastFeedbackHelpful: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.isCritical = isCritical
        self.isUrgent = isUrgent
        self.estimateMinutes = estimateMinutes
        self.createdAt = createdAt
        self.lastFeedbackHelpful = lastFeedbackHelpful
    }
}

@MainActor
final class AIPriorityStore: ObservableObject {
    @Published var tasks: [AITask] = [] { didSet { saveTasks() } }

    // 学习权重
    @Published var wCritical: Double = 3.0 { didSet { saveWeights() } }
    @Published var wUrgent: Double = 2.0 { didSet { saveWeights() } }
    @Published var wSpeed: Double = 1.0 { didSet { saveWeights() } }

    private let tasksKey = "ai_priority_tasks_v1"
    private let weightsKey = "ai_priority_weights_v1"

    init() {
        loadTasks()
        loadWeights()
    }

    func addTask(title: String, critical: Bool, urgent: Bool, estimateMinutes: Int) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        tasks.append(
            AITask(
                title: t,
                isCritical: critical,
                isUrgent: urgent,
                estimateMinutes: max(5, estimateMinutes)
            )
        )
    }

    func removeTask(_ task: AITask) {
        tasks.removeAll { $0.id == task.id }
    }

    func score(for task: AITask) -> Double {
        let c = task.isCritical ? wCritical : 0
        let u = task.isUrgent ? wUrgent : 0
        let s = (60.0 / Double(max(task.estimateMinutes, 5))) * wSpeed
        return c + u + s
    }

    var rankedTasks: [AITask] {
        tasks.sorted {
            let lhs = score(for: $0)
            let rhs = score(for: $1)
            if lhs == rhs { return $0.createdAt < $1.createdAt }
            return lhs > rhs
        }
    }

    func feedback(task: AITask, helpful: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].lastFeedbackHelpful = helpful

        let delta = helpful ? 0.15 : -0.15
        if task.isCritical { wCritical = clamp(wCritical + delta, 1.0, 6.0) }
        if task.isUrgent { wUrgent = clamp(wUrgent + delta, 1.0, 6.0) }

        if task.estimateMinutes <= 30 {
            wSpeed = clamp(wSpeed + delta, 0.4, 3.0)
        } else {
            wSpeed = clamp(wSpeed - 0.08 * (helpful ? -1 : 1), 0.4, 3.0)
        }
    }

    func resetLearning() {
        wCritical = 3.0
        wUrgent = 2.0
        wSpeed = 1.0
    }

    private func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(max(value, minValue), maxValue)
    }

    private func saveTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: tasksKey)
    }

    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: tasksKey),
              let decoded = try? JSONDecoder().decode([AITask].self, from: data) else { return }
        tasks = decoded
    }

    private func saveWeights() {
        let payload: [String: Double] = [
            "wCritical": wCritical,
            "wUrgent": wUrgent,
            "wSpeed": wSpeed
        ]
        UserDefaults.standard.set(payload, forKey: weightsKey)
    }

    private func loadWeights() {
        guard let payload = UserDefaults.standard.dictionary(forKey: weightsKey) as? [String: Double] else { return }
        wCritical = payload["wCritical"] ?? 3.0
        wUrgent = payload["wUrgent"] ?? 2.0
        wSpeed = payload["wSpeed"] ?? 1.0
    }
}

struct AIPriorityView: View {
    @Binding var appLanguage: String
    @StateObject private var store = AIPriorityStore()

    @State private var title = ""
    @State private var critical = false
    @State private var urgent = false
    @State private var estimate = 30
    @FocusState private var focused: Bool

    private func t(_ zh: String, _ en: String) -> String {
        appLanguage == "zh" ? zh : en
    }

    var body: some View {
        NavigationView {
            List {
                Section(t("创建任务", "Create Task")) {
                    TextField(t("输入 action item", "Action item"), text: $title)
                        .focused($focused)

                    Toggle(t("重要 (Critical)", "Critical"), isOn: $critical)
                    Toggle(t("紧急 (Urgent)", "Urgent"), isOn: $urgent)

                    Stepper(
                        "\(t("预计时长", "Estimate")): \(estimate) \(t("分钟", "min"))",
                        value: $estimate,
                        in: 5...240,
                        step: 5
                    )

                    Button(t("添加并自动排序", "Add & Auto Prioritize")) {
                        store.addTask(
                            title: title,
                            critical: critical,
                            urgent: urgent,
                            estimateMinutes: estimate
                        )
                        title = ""
                        critical = false
                        urgent = false
                        estimate = 30
                        focused = false
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(t("优先级结果", "Priority Queue")) {
                    if store.rankedTasks.isEmpty {
                        Text(t("暂无任务", "No tasks yet"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(store.rankedTasks.enumerated()), id: \.element.id) { index, task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("#\(index + 1)").font(.caption.bold())
                                    Text(task.title).font(.headline)
                                    Spacer()
                                    Text(String(format: "%.1f", store.score(for: task)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                HStack(spacing: 8) {
                                    if task.isCritical { Text("Critical").font(.caption2).padding(6).background(Color.red.opacity(0.15)).cornerRadius(8) }
                                    if task.isUrgent { Text("Urgent").font(.caption2).padding(6).background(Color.orange.opacity(0.15)).cornerRadius(8) }
                                    Text("\(task.estimateMinutes) min").font(.caption2).padding(6).background(Color.gray.opacity(0.15)).cornerRadius(8)
                                }

                                HStack {
                                    Button(t("有帮助", "Helpful")) {
                                        store.feedback(task: task, helpful: true)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(t("没帮助", "Not helpful")) {
                                        store.feedback(task: task, helpful: false)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(t("完成", "Done"), role: .destructive) {
                                        store.removeTask(task)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(t("学习参数", "Learning Weights")) {
                    Text("Wcritical: \(String(format: "%.2f", store.wCritical))")
                    Text("Wurgent: \(String(format: "%.2f", store.wUrgent))")
                    Text("Wspeed: \(String(format: "%.2f", store.wSpeed))")
                    Button(t("重置学习", "Reset Learning"), role: .destructive) {
                        store.resetLearning()
                    }
                }
            }
            .navigationTitle(t("AI 排序", "AI Prioritizer"))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(t("完成", "Done")) { focused = false }
                }
            }
        }
    }
}
