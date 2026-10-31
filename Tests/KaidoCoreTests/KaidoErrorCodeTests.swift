import Foundation
import Testing
@testable import KaidoCore

// 错误码契约测试（F-0703 / 设计 §A）：文法冻结、全局唯一、Codable 稳定。
// 码表一旦发布即公共契约，只增不改；本套用例守住「同一 rawValue 不得出现两次」，
// 因为跨模块（KaidoCore / KaidoUpdater）各持一份码表时，唯一性只能靠断言兜底。

struct KaidoErrorCodeTests {
    /// 文法：`<group>_<detail>`，全小写、无空格、至少两段。
    @Test func rawValuesFollowGroupDetailGrammar() {
        for code in KaidoErrorCode.allCases {
            let raw = code.rawValue
            #expect(raw == raw.lowercased(), "码值必须全小写：\(raw)")
            #expect(!raw.contains(" "), "码值不得含空格：\(raw)")
            #expect(!raw.hasPrefix("_") && !raw.hasSuffix("_"), "码值不得以分隔符起止：\(raw)")
            #expect(raw.contains("_"), "码值必须为 <group>_<detail> 两段以上：\(raw)")
        }
    }

    /// 全局唯一：rawValue 去重后数量不变（防止复制粘贴出重码）。
    @Test func rawValuesAreGloballyUnique() {
        let values = KaidoErrorCode.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count, "存在重复错误码：\(values)")
    }

    /// 分组前缀必须落在约定的域内，便于按域过滤与文档归档。
    @Test func groupPrefixesAreFromFrozenVocabulary() {
        let allowed: Set<String> = [
            "model", "schedule", "storage", "session", "cli", "mcp", "internal",
        ]
        for code in KaidoErrorCode.allCases {
            let group = code.rawValue.split(separator: "_").first.map(String.init) ?? ""
            #expect(allowed.contains(group), "未登记的错误码分组：\(group)（\(code.rawValue)）")
        }
    }

    /// Codable 以 rawValue 编码，接口层（MCP/JSON）序列化后仍是稳定字符串。
    @Test func codableRoundTripsThroughRawValue() throws {
        for code in KaidoErrorCode.allCases {
            let data = try JSONEncoder().encode(code)
            #expect(String(data: data, encoding: .utf8) == "\"\(code.rawValue)\"")
            let decoded = try JSONDecoder().decode(KaidoErrorCode.self, from: data)
            #expect(decoded == code)
        }
    }

    /// 领域模型码（数量只增不改，加码时同步下面的计数与固定断言。
    /// 含 F-0703 新增的 model_resource_not_found：
    /// 「资源不存在」原先无码可落，硬塞单位/效率码会错误归因；
    /// 含 v0.12 新增的 model_actual_date_order_invalid：实际时间顺序非法；
    /// 含 v0.13 新增的 model_baseline_not_found / model_baseline_name_empty：基线查找与命名；
    /// 含 v0.14 新增的 model_baseline_color_index_invalid：基线改色的索引越界；
    /// 含 v0.16 新增的 model_cancel_reason_required：转已取消未给原因）。
    @Test func modelCodesCoverSessionValidationSites() {
        let modelCodes = KaidoErrorCode.allCases.filter { $0.rawValue.hasPrefix("model_") }
        #expect(modelCodes.count == 16, "model 码应为 16 个，实际 \(modelCodes.count)")
        #expect(KaidoErrorCode.resourceNotFound.rawValue == "model_resource_not_found")
        #expect(KaidoErrorCode.actualDateOrderInvalid.rawValue == "model_actual_date_order_invalid")
        #expect(KaidoErrorCode.baselineNotFound.rawValue == "model_baseline_not_found")
        #expect(KaidoErrorCode.baselineNameEmpty.rawValue == "model_baseline_name_empty")
        #expect(KaidoErrorCode.baselineColorIndexInvalid.rawValue == "model_baseline_color_index_invalid")
        #expect(KaidoErrorCode.cancelReasonRequired.rawValue == "model_cancel_reason_required")
    }

    /// 违例相关 9 个码齐全（F-0704 / F-0715 判据 + v1.3.6 的手动排期冲突）。
    @Test func scheduleCodesCoverEveryViolationReason() {
        let scheduleCodes = KaidoErrorCode.allCases.filter { $0.rawValue.hasPrefix("schedule_") }
        #expect(scheduleCodes.count == 9, "排期码应为 9 个，实际 \(scheduleCodes.count)")
        #expect(KaidoErrorCode.startAfterProjectWindow.rawValue == "schedule_start_after_project_window")
        #expect(KaidoErrorCode.manualStartConflict.rawValue == "schedule_manual_start_conflict")
    }
}
