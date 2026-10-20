import SwiftUI
import KairoCore
import KairoPresentation

/// 日宽调节面板（工具栏 popover 内容）。
///
/// 构成：连续滑杆（对数映射）+ 读数 + ± 步进 + 档位芯片 + 重置。
/// 拖动中按 ≥100ms 节流提交、松手必提交最终值（设计稿 R-02）；
/// 面板、菜单步进与快捷键共用同一组动作，不产生第二套真相源。
struct DayWidthControl: View {
    @ObservedObject var store: WorkspaceStore
    /// 生效日宽（点/天）：自定义取用户值，fit 取 fit 宽度，预设取档位默认。
    let dayWidth: Double

    /// 拖动中的本地值；nil 时跟随外部生效值。
    @State private var draft: Double?
    /// 拖动中：本地草稿权威，外部生效值的变化不打断手势。
    @State private var isDragging = false
    /// 上次提交时刻（节流基准）。
    @State private var lastCommitAt = Date.distantPast
    /// 拖动中待提交的节流任务。
    @State private var pendingCommit: Task<Void, Never>?

    /// 提交节流间隔（秒）：拖动中最多每 100ms 提交一次。
    static let commitInterval: TimeInterval = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("日宽")
                .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            stepperRow
            slider
            presetRow
            Text("范围 \(rangeHint) 点/天")
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(12)
        .frame(width: 268)
        .onChange(of: dayWidth) { _, _ in
            // 外部生效值变了（如面板打开时按 ⌘+）：丢弃本地草稿，读数与滑杆回到生效值。
            // 拖动中不丢弃：节流提交的回声会与手势互相打断，滑杆会往回跳。
            guard !isDragging else { return }
            draft = nil
        }
        .onDisappear {
            // 关闭面板时提交最后一次拖动值：节流窗口内的末值不能丢。
            if let draft {
                commit(draft)
                self.draft = nil
            }
            pendingCommit?.cancel()
            pendingCommit = nil
        }
    }

    // MARK: - 子视图

    private var stepperRow: some View {
        HStack(spacing: 8) {
            stepButton(title: "更窄", delta: -GanttScale.dayWidthStep, symbol: "minus")
            Spacer(minLength: 0)
            Text(readout)
                .font(.system(size: DesignTokens.bodyFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 84)
            Spacer(minLength: 0)
            stepButton(title: "更宽", delta: GanttScale.dayWidthStep, symbol: "plus")
        }
    }

    private var slider: some View {
        Slider(
            value: sliderPosition,
            in: 0...1,
            onEditingChanged: { editing in
                isDragging = editing
                if !editing { finishDragging() }
            }
        )
        .accessibilityLabel("每日宽度")
        .accessibilityValue(readout)
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(GanttZoom.allCases, id: \.self) { zoom in
                Button(presetTitle(zoom)) { applyPreset(zoom) }
                    .buttonStyle(.bordered)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .help("\(presetTitle(zoom))：\(Int(zoom.dayWidth)) 点/天")
            }
            Button("重置") { applyReset() }
                .buttonStyle(.bordered)
                .font(.system(size: DesignTokens.captionFontSize))
                .help("回到当前档位默认宽度")
        }
    }

    private func stepButton(title: String, delta: Double, symbol: String) -> some View {
        Button {
            apply(width: GanttScale.clampDayWidth(currentWidth + delta))
        } label: {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                Text("\(Int(abs(delta)))")
            }
            .font(.system(size: DesignTokens.captionFontSize))
            .frame(minWidth: 34)
        }
        .buttonStyle(.bordered)
        .help("\(title) \(Int(abs(delta))) 点/天")
        .accessibilityLabel("\(title) \(Int(abs(delta))) 点/天")
    }

    // MARK: - 读数与映射

    /// 当前面板显示的日宽：拖动中用本地值，否则跟随生效值。
    private var currentWidth: Double {
        draft ?? dayWidth
    }

    private var readout: String {
        WorkspacePresenter.zoomDetail(dayWidth: currentWidth)
    }

    private var rangeHint: String {
        let lower = Int(GanttScale.dayWidthRange.lowerBound)
        let upper = Int(GanttScale.dayWidthRange.upperBound)
        return "\(lower)–\(upper)"
    }

    private func presetTitle(_ zoom: GanttZoom) -> String {
        let name: String
        switch zoom {
        case .day: name = "日"
        case .week: name = "周"
        case .month: name = "月"
        }
        return "\(name) \(Int(zoom.dayWidth))"
    }

    /// 滑杆位置（0…1）↔ 日宽。
    private var sliderPosition: Binding<Double> {
        Binding(
            get: { Self.position(forDayWidth: currentWidth) },
            set: { handleSlide($0) }
        )
    }

    /// 日宽 → 滑杆位置的对数映射。
    ///
    /// 线性映射会把常用区（5–32 点/天）挤在左端四分之一；对数映射下常用区落在中段，
    /// 拖动手感均匀。
    static func position(forDayWidth width: Double) -> Double {
        let clamped = GanttScale.clampDayWidth(width)
        let lower = GanttScale.dayWidthRange.lowerBound
        let upper = GanttScale.dayWidthRange.upperBound
        return log(clamped / lower) / log(upper / lower)
    }

    /// 滑杆位置 → 日宽（点/天），结果落在合法区间内。
    static func dayWidth(forPosition position: Double) -> Double {
        let lower = GanttScale.dayWidthRange.lowerBound
        let upper = GanttScale.dayWidthRange.upperBound
        let t = min(max(position, 0), 1)
        return GanttScale.clampDayWidth(lower * pow(upper / lower, t))
    }

    // MARK: - 提交

    /// 设定宽度：先夹取再提交；提交后本地草稿失效，跟随生效值。
    private func apply(width: Double) {
        draft = nil
        store.dispatch(.setCustomDayWidth(width))
    }

    private func applyPreset(_ zoom: GanttZoom) {
        draft = nil
        store.dispatch(.setZoom(zoom))
    }

    private func applyReset() {
        draft = nil
        store.dispatch(.clearCustomDayWidth)
    }

    /// 拖动中按节流提交；节流窗口内的最后一次变更由待提交任务补上。
    private func handleSlide(_ position: Double) {
        let width = Self.dayWidth(forPosition: position)
        draft = width
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCommitAt)
        if elapsed >= Self.commitInterval {
            commit(width)
        } else {
            pendingCommit?.cancel()
            let delay = Self.commitInterval - elapsed
            pendingCommit = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.commit(width)
            }
        }
    }

    /// 松手：取消待提交任务并提交最终值。
    private func finishDragging() {
        pendingCommit?.cancel()
        pendingCommit = nil
        if let draft {
            commit(draft)
            self.draft = nil
        }
    }

    private func commit(_ width: Double) {
        lastCommitAt = Date()
        store.dispatch(.setCustomDayWidth(width))
    }
}
