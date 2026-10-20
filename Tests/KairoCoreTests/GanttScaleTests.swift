import Foundation
import Testing
@testable import KairoCore

/// 甘特日宽策略单测（Sprint 6 / T3）：夹取区间、刻度档位推导与档位默认值自洽。
///
/// 等比性不变式由核心布局保证（全轴 x = 天数 × 日宽），本文件只锁定
/// 「策略常量 + 纯函数」的行为契约。
struct GanttScaleTests {
    // MARK: - 夹取

    @Test func clampKeepsValuesInsideRange() {
        #expect(GanttScale.clampDayWidth(12) == 12)
        #expect(GanttScale.clampDayWidth(12.5) == 12.5)
        #expect(GanttScale.clampDayWidth(2) == 2)
        #expect(GanttScale.clampDayWidth(120) == 120)
    }

    @Test func clampBoundsOutOfRangeValues() {
        #expect(GanttScale.clampDayWidth(-5) == 2)
        #expect(GanttScale.clampDayWidth(0) == 2)
        #expect(GanttScale.clampDayWidth(1.99) == 2)
        #expect(GanttScale.clampDayWidth(1000) == 120)
        #expect(GanttScale.clampDayWidth(120.01) == 120)
    }

    @Test func clampHandlesNonFiniteValues() {
        // NaN / ±∞ 必须有确定回落，绝不产生 NaN 日宽。
        #expect(GanttScale.clampDayWidth(.nan) == 2)
        #expect(GanttScale.clampDayWidth(.infinity) == 120)
        #expect(GanttScale.clampDayWidth(-.infinity) == 2)
    }

    @Test func clampResultAlwaysInsideDeclaredRange() {
        let samples: [Double] = [
            -1e9, -1, 0, 0.5, 1.99, 2, 5, 12, 32, 119.999, 120, 120.001, 1e9, .nan, .infinity, -.infinity
        ]
        for sample in samples {
            let clamped = GanttScale.clampDayWidth(sample)
            #expect(GanttScale.dayWidthRange.contains(clamped))
            #expect(!clamped.isNaN)
        }
    }

    // MARK: - 刻度档位推导

    @Test func tickUnitMatchesPresetDefaults() {
        // 与档位默认值自洽：自定义宽度取到档位默认时视觉密度与该档位一致。
        #expect(GanttScale.tickUnit(forDayWidth: GanttZoom.day.dayWidth) == .day)
        #expect(GanttScale.tickUnit(forDayWidth: GanttZoom.week.dayWidth) == .week)
        #expect(GanttScale.tickUnit(forDayWidth: GanttZoom.month.dayWidth) == .month)
    }

    @Test func tickUnitRespectsThresholds() {
        #expect(GanttScale.tickUnit(forDayWidth: 18) == .day)
        #expect(GanttScale.tickUnit(forDayWidth: 17.99) == .week)
        #expect(GanttScale.tickUnit(forDayWidth: 6) == .week)
        #expect(GanttScale.tickUnit(forDayWidth: 5.99) == .month)
        #expect(GanttScale.tickUnit(forDayWidth: 1.99) == .month)
    }

    @Test func tickUnitNeverGetsFinerAsWidthGrows() {
        // 单调性：宽度递增时刻度只会变粗，不会变细（order 中 .day 最细、.month 最粗）。
        var previous = GanttScale.tickUnit(forDayWidth: 0.5)
        for step in 1...240 {
            let granularity = GanttScale.tickUnit(forDayWidth: Double(step) / 2)
            let order: [GanttZoom] = [.day, .week, .month]
            let current = order.firstIndex(of: granularity)!
            let last = order.firstIndex(of: previous)!
            #expect(current <= last)
            previous = granularity
        }
    }

    @Test func tickUnitOfNonFiniteWidthFallsBackToCoarsest() {
        // NaN 不得被误判为逐日（否则会放大绘制量）。
        #expect(GanttScale.tickUnit(forDayWidth: .nan) == .month)
        #expect(GanttScale.tickUnit(forDayWidth: .infinity) == .day)
    }

    // MARK: - 常量

    @Test func declaredConstantsMatchContract() {
        #expect(GanttScale.dayWidthRange == 2.0...120.0)
        #expect(GanttScale.dayTickThreshold == 18)
        #expect(GanttScale.weekTickThreshold == 6)
        #expect(GanttScale.dayWidthStep == 1.0)
    }
}
