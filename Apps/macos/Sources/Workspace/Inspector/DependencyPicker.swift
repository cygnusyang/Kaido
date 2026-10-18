import SwiftUI
import KairoCore

/// 添加前置任务弹层（320×400）：搜索、四型、延隔 −30…+30 天。
struct DependencyPicker: View {
    let candidates: [WorkspaceStore.TaskChoice]
    let onAdd: (UUID, TaskDependency.DependencyType, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var type: TaskDependency.DependencyType = .fs
    @State private var lagDays: Double = 0

    private var filtered: [WorkspaceStore.TaskChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加前置任务")
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(12)

            Divider()

            TextField("搜索任务", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if filtered.isEmpty {
                ContentUnavailableView(
                    "没有可选任务",
                    systemImage: "magnifyingglass",
                    description: Text("已排除自身、子任务与已有前置任务。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { choice in
                            HStack(spacing: 6) {
                                Image(systemName: selectedID == choice.id
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(selectedID == choice.id
                                        ? DesignTokens.accentStrong
                                        : DesignTokens.textSecondary)
                                Text(choice.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                            .background(selectedID == choice.id
                                ? DesignTokens.selection
                                : Color.clear)
                            .onTapGesture { selectedID = choice.id }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("类型", selection: $type) {
                    ForEach(TaskDependency.DependencyType.allCases, id: \.self) { value in
                        Text(Display.dependencyTitle(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    Text("延隔")
                        .font(.system(size: DesignTokens.captionFontSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                    Stepper(value: $lagDays, in: -30...30, step: 0.5) {
                        Text(Display.duration(lagDays))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .leading)
                    }
                }

                HStack {
                    Spacer()
                    Button("添加") {
                        guard let selectedID else { return }
                        onAdd(selectedID, type, lagDays)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil)
                }
            }
            .padding(12)
        }
        .frame(width: 320, height: 400)
        .background(DesignTokens.surfaceElevated)
    }
}
