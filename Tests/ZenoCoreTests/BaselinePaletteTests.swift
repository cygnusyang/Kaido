import Foundation
import Testing

@testable import ZenoCore

// MARK: - 夹具

private func makeBaseline(_ name: String, colorIndex: Int? = nil) -> Baseline {
    Baseline(
        name: name,
        createdAt: Date(timeIntervalSince1970: 0),
        colorIndex: colorIndex
    )
}

// MARK: - 判据 4：颜色稳定（最小未占用索引）

@Test func emptyListAllocatesFirstColor() {
    #expect(BaselinePalette.count == 8)
    #expect(BaselinePalette.colorIndex(for: []) == 0)
}

@Test func allocationTakesSmallestUnusedIndex() {
    let baselines = [
        makeBaseline("A", colorIndex: 0),
        makeBaseline("B", colorIndex: 2),
    ]

    // 0 与 2 已占用 → 新基线取最小空缺 1（不追加到末尾）。
    #expect(BaselinePalette.colorIndex(for: baselines) == 1)
}

@Test func deletingMiddleBaselineReusesItsColorWithoutRenumbering() {
    var baselines = [0, 1, 2, 3].map { (index: Int) in makeBaseline("基线 \(index)", colorIndex: index) }

    baselines.removeAll { $0.colorIndex == 1 }

    // 已分配索引永不因其他基线删除而改变（§10-4）。
    #expect(baselines.map(\.colorIndex) == [0, 2, 3])
    // 删除中间那条后新建仍取 1，不串色。
    #expect(BaselinePalette.colorIndex(for: baselines) == 1)
}

@Test func exhaustedPaletteFallsBackDeterministically() {
    let full = (0..<BaselinePalette.count).map { makeBaseline("基线 \($0)", colorIndex: $0) }
    let allocated = BaselinePalette.colorIndex(for: full)

    // 8 色用尽是降级态：按已用数量取模兜底，不下标越界、不崩。
    #expect(allocated == 0)
    #expect((0..<BaselinePalette.count).contains(allocated))
}

// MARK: - 判据 5：旧文件补色（只在写路径发生）

@Test func ensureColorsFillsLegacyBaselinesInCreationOrder() {
    var baselines = [
        makeBaseline("旧 1"),
        makeBaseline("旧 2"),
        makeBaseline("旧 3"),
    ]

    BaselinePalette.ensureColors(in: &baselines)

    #expect(baselines.map(\.colorIndex) == [0, 1, 2])
}

@Test func ensureColorsOnlyTouchesBaselinesWithoutColor() {
    var baselines = [
        makeBaseline("A", colorIndex: 0),
        makeBaseline("B"),
        makeBaseline("C", colorIndex: 2),
    ]

    BaselinePalette.ensureColors(in: &baselines)

    // 缺色的取最小未占用 1；已有 0 / 2 原地不动。
    #expect(baselines.map(\.colorIndex) == [0, 1, 2])

    // 幂等：再次补齐不产生任何变化（写路径可安全重复调用）。
    let settled = baselines.map(\.colorIndex)
    BaselinePalette.ensureColors(in: &baselines)
    #expect(baselines.map(\.colorIndex) == settled)
}

@Test func ensureColorsAssignsUniqueIndicesWhenLegacyListExceedsPalette() {
    var baselines = (0..<10).map { makeBaseline("旧 \($0)") }

    BaselinePalette.ensureColors(in: &baselines)

    let indices = baselines.compactMap(\.colorIndex)
    #expect(indices.count == baselines.count)
    #expect(indices.allSatisfy { (0..<BaselinePalette.count).contains($0) })
    // 前 8 条各得一个唯一索引，越界后按模兜底。
    #expect(Set(indices.prefix(8)).count == BaselinePalette.count)
}

@Test func resolveDerivesStableIndicesForMissingOrInvalidValues() {
    #expect(BaselinePalette.resolve([nil, nil, nil]) == [0, 1, 2])
    // 重复值 → 后来者取最小未用；越界值 → 同样重新派生。
    #expect(BaselinePalette.resolve([0, 0, 9]) == [0, 1, 2])
    #expect(BaselinePalette.resolve([3, nil, 3]) == [3, 0, 1])
}

// MARK: - 判据 6：编码往返

@Test func colorIndexSurvivesCodableRoundTrip() throws {
    let baseline = makeBaseline("带色", colorIndex: 5)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(Baseline.self, from: encoder.encode(baseline))

    #expect(decoded.colorIndex == 5)
    #expect(decoded == baseline)
}

@Test func legacyBaselineWithoutColorIndexDecodesToNil() throws {
    let taskID = UUID()
    let json = """
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "基线 1 · 2026-10-25",
      "createdAt": "2026-10-25T00:00:00Z",
      "entries": [
        {
          "taskID": "\(taskID.uuidString)",
          "start": "2026-11-02T00:00:00Z",
          "finish": "2026-11-03T00:00:00Z",
          "progress": 0.5,
          "isMilestone": false
        }
      ]
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let baseline = try decoder.decode(Baseline.self, from: Data(json.utf8))

    // 旧文件缺字段 → nil，且不影响其余字段（不升 formatVersion）。
    #expect(baseline.colorIndex == nil)
    #expect(baseline.entries.count == 1)
}

@Test func encodingOmitsColorIndexWhenUnset() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(makeBaseline("无色"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    // 与 anchor 同口径：nil 不落盘，避免给旧文件补出无意义的 null。
    #expect(object["colorIndex"] == nil)
}
