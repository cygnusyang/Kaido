import Foundation
import Testing
@testable import KaidoCore

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

    // MARK: - 滑杆区间（D-042）

    @Test func sliderRangeKeepsDefaultUpperWhenDayWidthFits() {
        // 常用区不动：读数在档位区间内时，滑杆尺度与引入本函数前逐位一致。
        #expect(GanttScale.sliderRange(forDayWidth: 12) == GanttScale.dayWidthRange)
        #expect(GanttScale.sliderRange(forDayWidth: 120) == GanttScale.dayWidthRange)
        #expect(GanttScale.sliderRange(forDayWidth: 2) == GanttScale.dayWidthRange)
    }

    @Test func sliderRangeWidensForSpanWidthBeyondPresetUpper() {
        // 1024pt 画布 / 7 天跨度 = 146.3 点/天：上界必须容得下当前值，否则滑杆
        // 一拖就把跨度宽度夹回 120 并静默退出跨度模式。
        let range = GanttScale.sliderRange(forDayWidth: 146.3)
        #expect(range.lowerBound == GanttScale.dayWidthRange.lowerBound)
        #expect(range.upperBound == 146.3)
        #expect(range.contains(146.3))
    }

    @Test func sliderRangeNeverNarrowsBelowDefault() {
        #expect(GanttScale.sliderRange(forDayWidth: 0).upperBound == GanttScale.dayWidthRange.upperBound)
        #expect(GanttScale.sliderRange(forDayWidth: -50).lowerBound == GanttScale.dayWidthRange.lowerBound)
    }

    @Test func sliderRangeFallsBackForNonFiniteWidth() {
        // 坏读数不许把滑杆尺度撑成无穷 / NaN。
        #expect(GanttScale.sliderRange(forDayWidth: .nan) == GanttScale.dayWidthRange)
        #expect(GanttScale.sliderRange(forDayWidth: .infinity) == GanttScale.dayWidthRange)
        #expect(GanttScale.sliderRange(forDayWidth: -.infinity) == GanttScale.dayWidthRange)
    }

    // MARK: - 常量

    @Test func declaredConstantsMatchContract() {
        #expect(GanttScale.dayWidthRange == 2.0...120.0)
        #expect(GanttScale.dayTickThreshold == 18)
        #expect(GanttScale.weekTickThreshold == 6)
        #expect(GanttScale.dayWidthStep == 1.0)
    }
}
