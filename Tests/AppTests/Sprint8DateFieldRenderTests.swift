import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// F-14-10 日期字段与月历弹层的离屏渲染测试。
///
/// 覆盖 AC-S8-05（越界日置灰）、AC-S8-12（群组两行只读外观）、AC-S8-18（三态非空白且可区分、
/// 浅色/深色、选中态与今天态有差异）。真实 popover 动画、物理键盘事件与 VoiceOver 播报
/// 不在自动化范围（判据 §3 N1–N3）。
@MainActor
@Suite("S8 日期字段渲染")
struct Sprint8DateFieldRenderTests {
    private enum Threshold {
        /// 非空画面至少出现的颜色数；纯色空白画面为 1。
        static let distinctColors = 20
        /// 整套表面/文字 token 换肤后画面差异下限（背景占绝大多数像素）。
        static let themeChange = 0.3
    }

    /// 固定时区与周首（周一）的日历，避免渲染与断言随主机设置漂移。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            Issue.record("无法构造日期 \(year)-\(month)-\(day)")
            return Date()
        }
        return calendar.startOfDay(for: date)
    }

    // MARK: - 渲染入口

    /// 离屏渲染（支持指定深浅色；`GUIRenderer` 固定浅色，深色用例单独构造）。
    private func snapshot(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        scheme: ColorScheme
    ) throws -> RenderedSnapshot {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: height)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        let image = try #require(renderer.cgImage)

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drew)
        return RenderedSnapshot(width: image.width, height: image.height, pixels: pixels)
    }

    // MARK: - 夹具

    private func row(
        label: String = "开始",
        value: Date?,
        helper: String? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        minimumDate: Date? = nil
    ) -> some View {
        DateFieldRow(
            label: label,
            value: value,
            placeholder: "未设置",
            helper: helper,
            isEnabled: isEnabled,
            disabledReason: disabledReason,
            minimumDate: minimumDate,
            allowsClear: true,
            preview: nil,
            onCommit: { _ in }
        )
        .padding(8)
        .background(DesignTokens.surfaceChrome)
    }

    private func popover(
        selection: Date?,
        minimumDate: Date? = nil,
        allowsClear: Bool = false,
        preview: String? = nil,
        today: Date? = nil
    ) -> some View {
        let anchor = selection ?? date(2026, 11, 6)
        let month = CalendarGrid.month(containing: anchor, calendar: calendar).firstDay
        return CalendarPopover(
            label: "结束",
            selection: selection,
            minimumDate: minimumDate,
            maximumDate: nil,
            allowsClear: allowsClear,
            quickActions: DateQuickAction.allCases,
            preview: preview,
            disabledDayHint: minimumDate == nil ? nil : "结束须晚于开始，至少 1 天",
            today: today ?? date(2026, 11, 6),
            calendar: calendar,
            visibleMonth: .constant(month),
            onPick: { _ in },
            onDismiss: {}
        )
    }

    private func renderPopover(
        selection: Date?,
        minimumDate: Date? = nil,
        scheme: ColorScheme = .light,
        today: Date? = nil
    ) throws -> RenderedSnapshot {
        try snapshot(
            popover(selection: selection, minimumDate: minimumDate, today: today),
            width: CalendarPopover.width,
            height: CalendarPopover.height,
            scheme: scheme
        )
    }

    // MARK: - AC-S8-18 字段行三态

    @Test func dateFieldRowStatesRenderDistinctly() throws {
        let filled = try snapshot(
            row(value: date(2026, 11, 6), helper: "计划开始 2026-11-10"),
            width: 300, height: 64, scheme: .light
        )
        let empty = try snapshot(
            row(value: nil),
            width: 300, height: 64, scheme: .light
        )
        let disabled = try snapshot(
            row(value: date(2026, 11, 6), isEnabled: false, disabledReason: "群组字段由子任务聚合，只读"),
            width: 300, height: 64, scheme: .light
        )

        for rendered in [filled, empty, disabled] {
            #expect(rendered.distinctColorCount >= Threshold.distinctColors)
        }
        #expect(filled.differenceRatio(from: empty) > 0)
        #expect(filled.differenceRatio(from: disabled) > 0)
        #expect(empty.differenceRatio(from: disabled) > 0)
    }

    // MARK: - AC-S8-18 弹层浅色 / 深色

    @Test func calendarPopoverRendersInLightAndDark() throws {
        let light = try renderPopover(selection: date(2026, 11, 6), scheme: .light)
        let dark = try renderPopover(selection: date(2026, 11, 6), scheme: .dark)

        #expect(light.width == Int(CalendarPopover.width))
        #expect(light.height == Int(CalendarPopover.height))
        #expect(light.distinctColorCount >= Threshold.distinctColors)
        #expect(dark.distinctColorCount >= Threshold.distinctColors)
        // 差异必须大到只能是整套表面/文字 token 换肤，而非抗锯齿噪声。
        #expect(light.differenceRatio(from: dark) > Threshold.themeChange)
    }

    // MARK: - AC-S8-18 选中态与今天态可区分

    @Test func selectedAndTodayStatesRenderDifferently() throws {
        let today = date(2026, 11, 6)
        let selectedToday = try renderPopover(selection: today, today: today)
        // 同一天被选中 → 只剩选中底色；另一天选中 → 今天保留描边环。
        let selectedOtherDay = try renderPopover(selection: date(2026, 11, 10), today: today)

        #expect(selectedToday.distinctColorCount >= Threshold.distinctColors)
        #expect(selectedOtherDay.distinctColorCount >= Threshold.distinctColors)
        #expect(selectedToday.differenceRatio(from: selectedOtherDay) > 0)
    }

    // MARK: - AC-S8-05 结束日历越界日置灰

    @Test func finishCalendarDisablesDaysAtOrBeforeStart() throws {
        let start = date(2026, 11, 6)
        let minimum = ScheduleDateMath.minimumFinish(start: start, kind: .task, calendar: calendar)
        #expect(minimum == date(2026, 11, 7))

        let month = CalendarGrid.month(containing: start, calendar: calendar)
        for day in [date(2026, 11, 5), start] {
            let style = CalendarPopover.style(
                for: day,
                in: month,
                selection: minimum,
                minimumDate: minimum,
                maximumDate: nil,
                today: start
            )
            #expect(!style.isSelectable, "早于或等于起点的日子应不可选：\(Display.isoDate(day))")
        }
        let boundary = CalendarPopover.style(
            for: minimum,
            in: month,
            selection: minimum,
            minimumDate: minimum,
            maximumDate: nil,
            today: start
        )
        #expect(boundary.isSelectable)

        // 置灰必须落到画面上：有下限与无下限两张图应不同。
        let bounded = try renderPopover(selection: minimum, minimumDate: minimum, today: start)
        let unbounded = try renderPopover(selection: minimum, minimumDate: nil, today: start)
        #expect(bounded.distinctColorCount >= Threshold.distinctColors)
        #expect(bounded.differenceRatio(from: unbounded) > 0)
    }

    // MARK: - AC-S8-12 群组两行只读外观

    @Test func groupDateRowsRenderAsReadOnly() throws {
        func rows(isEnabled: Bool) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                DateFieldRow(
                    label: "开始",
                    value: date(2026, 11, 2),
                    placeholder: "未设置",
                    isEnabled: isEnabled,
                    disabledReason: "群组字段由子任务聚合，只读",
                    allowsClear: true,
                    onCommit: { _ in }
                )
                DateFieldRow(
                    label: "结束",
                    value: date(2026, 11, 6),
                    placeholder: "无排期",
                    isEnabled: isEnabled,
                    disabledReason: "群组字段由子任务聚合，只读",
                    onCommit: { _ in }
                )
            }
            .padding(8)
            .background(DesignTokens.surfaceChrome)
        }

        let group = try snapshot(rows(isEnabled: false), width: 300, height: 96, scheme: .light)
        let editable = try snapshot(rows(isEnabled: true), width: 300, height: 96, scheme: .light)

        #expect(group.distinctColorCount >= Threshold.distinctColors)
        // 只读行不再渲染可编辑样式（次要文字色 + 禁用说明副行）。
        #expect(group.differenceRatio(from: editable) > 0)
    }

    // MARK: - AC-S8-19 可静态断言的文案

    @Test func dateRowAccessibilityLabelsMatchDesign() {
        #expect(
            DateFieldRow.accessibilityLabelText(
                label: "开始",
                value: date(2026, 11, 6),
                calendar: calendar
            ) == "开始日期，2026年11月6日"
        )
        #expect(
            DateFieldRow.accessibilityLabelText(label: "开始", value: nil, calendar: calendar)
                == "开始日期，未设置"
        )
        // 字段名已含「日期」时不重复追加。
        #expect(
            DateFieldRow.accessibilityLabelText(label: "截止日期", value: nil, calendar: calendar)
                == "截止日期，未设置"
        )
    }

    @Test func dayLabelsDescribeTodaySelectionAndBounds() {
        let month = CalendarGrid.month(containing: date(2026, 11, 6), calendar: calendar)
        let label = CalendarPopover.dayAccessibilityLabel(
            for: date(2026, 11, 6),
            in: month,
            selection: date(2026, 11, 6),
            today: date(2026, 11, 6),
            isSelectable: false
        )
        #expect(label == "11 月 6 日，星期五，今天，已选中，不可选")

        let outside = CalendarPopover.dayAccessibilityLabel(
            for: date(2026, 10, 26),
            in: month,
            selection: nil,
            today: date(2026, 11, 6),
            isSelectable: true
        )
        #expect(outside.hasPrefix("10 月 26 日，星期一"))
        #expect(outside.contains("不在本月"))

        #expect(Display.monthTitle(date(2026, 11, 6), calendar: calendar) == "2026 年 11 月")
        #expect(Display.weekdaySymbols(calendar: calendar) == ["一", "二", "三", "四", "五", "六", "日"])
        #expect(Display.isoDate(date(2026, 11, 6)) == "2026-11-06")
    }

    // MARK: - AC-S8-15 快捷项口径

    @Test func quickActionsFollowDesignRules() {
        let monday = date(2026, 11, 2)
        let wednesday = date(2026, 11, 4)

        #expect(DateQuickAction.today.date(selection: nil, now: wednesday, calendar: calendar) == wednesday)
        // 今天即周一 → 下一个周一为 +7 天。
        #expect(DateQuickAction.nextMonday.date(selection: nil, now: monday, calendar: calendar) == date(2026, 11, 9))
        #expect(DateQuickAction.nextMonday.date(selection: nil, now: wednesday, calendar: calendar) == date(2026, 11, 9))
        // +1 周以当前选中值为基准。
        #expect(
            DateQuickAction.plusWeek.date(selection: date(2026, 11, 6), now: monday, calendar: calendar)
                == date(2026, 11, 13)
        )
        // 早于最小可选日的快捷项禁用。
        #expect(
            !CalendarPopover.isWithinBounds(
                monday,
                minimumDate: date(2026, 11, 7),
                maximumDate: nil,
                calendar: calendar
            )
        )
        #expect(
            CalendarPopover.isWithinBounds(
                date(2026, 11, 7),
                minimumDate: date(2026, 11, 7),
                maximumDate: nil,
                calendar: calendar
            )
        )
    }
}
