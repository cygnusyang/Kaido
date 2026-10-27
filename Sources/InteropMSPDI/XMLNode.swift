import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 极简 XML 树（只读）。
///
/// 为什么不写 SAX 状态机：MSPDI 里 `Baseline` 既出现在 `Task` 下也出现在 `Assignment` 下，
/// `ExtendedAttribute` 既出现在项目级（定义）也出现在 `Task` 下（值）。用路径树表达
/// 「谁的孩子」不会张冠李戴，读代码时也不必在脑内维护一摞状态位。
///
/// 883 KB / 5 万节点的真实样本在内存里是几 MB 量级，可接受；解析是一次性动作。
final class XMLNode {
    let name: String
    let namespaceURI: String?
    private(set) var rawText: String = ""
    private(set) var children: [XMLNode] = []

    init(name: String, namespaceURI: String?) {
        self.name = name
        self.namespaceURI = namespaceURI
    }

    /// 去空白后的文本。
    var text: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func append(_ child: XMLNode) {
        children.append(child)
    }

    func append(text: String) {
        rawText += text
    }

    /// 第一个同名子节点。
    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// 某条路径下的第一个节点（`path(["Calendars", "Calendar"])[-1]` 场景用 `children`）。
    func child(_ path: [String]) -> XMLNode? {
        var current: XMLNode? = self
        for step in path {
            current = current?.child(step)
        }
        return current
    }

    /// 全部同名子节点。
    func children(named name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    var intValue: Int? {
        Int(text)
    }

    var doubleValue: Double? {
        Double(text)
    }

    /// MSPDI 的布尔口径：`1` / `0`（也有 `true`/`false` 的写法）。
    var boolValue: Bool? {
        switch text.lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }
}

/// `XMLParser` 的树构建委托。
final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private var stack: [XMLNode] = []
    private(set) var failure: String?
    private(set) var parserError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLNode(name: elementName, namespaceURI: namespaceURI)
        if let parent = stack.last {
            parent.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(text: string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.append(text: text)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserError = parseError
        if failure == nil {
            failure = "第 \(parser.lineNumber) 行第 \(parser.columnNumber) 列：\(parseError.localizedDescription)"
        }
    }
}
