import Foundation
import Testing
@testable import KaidoMacApp

/// MCP 授权目录（App Store 沙盒版）：只放行用户显式选过的目录。
@Suite("MCP 授权目录")
struct MCPAuthorizationStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "kaido.mcp.auth.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kaido-mcp-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func authorizedFolderCoversItsChildren() throws {
        let store = MCPAuthorizationStore(defaults: makeDefaults())
        let root = try makeDirectory("root")
        store.authorize(root)

        #expect(store.allows(root.appendingPathComponent("plan.kaido")))
        #expect(store.allows(root))
        #expect(store.roots.count == 1)
    }

    @Test func siblingWithSharedPrefixIsNotAuthorized() throws {
        let store = MCPAuthorizationStore(defaults: makeDefaults())
        let root = try makeDirectory("work")
        store.authorize(root)

        // "/work2" 与 "/work" 只是字符串前缀相同，不是子目录。
        let sibling = URL(fileURLWithPath: root.path + "2").appendingPathComponent("plan.kaido")
        #expect(!store.allows(sibling))
    }

    @Test func revokeRemovesAccess() throws {
        let store = MCPAuthorizationStore(defaults: makeDefaults())
        let root = try makeDirectory("revoke")
        store.authorize(root)
        let id = try #require(store.roots.first?.id)

        store.revoke(id)
        #expect(store.roots.isEmpty)
        #expect(!store.allows(root.appendingPathComponent("plan.kaido")))
    }

    @Test func sameFolderIsNotDuplicated() throws {
        let store = MCPAuthorizationStore(defaults: makeDefaults())
        let root = try makeDirectory("dup")
        store.authorize(root)
        store.authorize(root)
        #expect(store.roots.count == 1)
    }
}
