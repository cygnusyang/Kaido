import Foundation
import Testing
import KairoCommands
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// App 侧 CSV 导出（v0.15.1）：界面入口曾缺失，这里锁住「store 能写出与 CLI 同格式的文件」。
@MainActor
@Suite("偏差 CSV 导出（应用侧）")
struct VarianceCSVExportTests {

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.tests.csv.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KairoFile.read(from: $0) }
        )
    }

    @Test func exportWritesBOMAndFixedHeader() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        try store.exportVarianceCSV(to: url)

        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))
        // String(data:encoding:) 会吞掉 BOM，必须按字节断言（Excel 靠这三个字节判 UTF-8）。
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]), "CSV 必须带 BOM，否则 Excel 打开中文乱码")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 4)
        #expect(lines[0].hasPrefix("# baselineID,"))
        #expect(lines[3] == VarianceCSV.header.joined(separator: ","), "第 4 行必须是 11 列固定表头")
        // 任务行逐行 11 列（孤儿节前的空行除外）。
        let taskRows = lines.dropFirst(4).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for row in taskRows {
            #expect(row.split(separator: ",", omittingEmptySubsequences: false).count == VarianceCSV.header.count)
        }
    }

    @Test func exportWithoutBaselineThrows() {
        let store = makeStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).csv")
        #expect(throws: CSVWriteFailure.self) {
            try store.exportVarianceCSV(to: url)
        }
    }
}
