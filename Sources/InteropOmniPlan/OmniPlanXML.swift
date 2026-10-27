import Foundation

/// 极简只读 XML 树（`.oplx` 场景文件用）。
///
/// 与 MSPDI 通道各自持有一份、互不引用：两条格式通道**零依赖**（14 §2 硬规则 1），
/// 删掉任一 target 另一个仍能编译。代价是这百来行重复——换来的是「对方格式更新时
/// 只改它自己的 target」这条架构约束。等两条通道都需要更复杂的 XML 能力时，
/// 再把公共部分下沉到 `KairoInterop`，而不是现在提前抽象。
///
/// 只保留定位与取值需要的两样东西：属性表与文本；不保留命名空间 URI——OmniPlan
/// 全文档同属一个命名空间，元素名已足够定位。
final class OmniPlanXMLNode {
    let name: String
    private(set) var attributes: [String: String]
    private(set) var rawText: String = ""
    private(set) var children: [OmniPlanXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// 去空白后的文本。
    var text: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func append(_ child: OmniPlanXMLNode) {
        children.append(child)
    }

    func append(text: String) {
        rawText += text
    }

    /// 属性值（去空白）；缺失返回 nil。
    func attribute(_ name: String) -> String? {
        attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 第一个同名子节点。
    func child(_ name: String) -> OmniPlanXMLNode? {
        children.first { $0.name == name }
    }

    /// 全部同名子节点（按文档顺序）。
    func children(named name: String) -> [OmniPlanXMLNode] {
        children.filter { $0.name == name }
    }

    /// 同名子节点的文本；缺失或空串返回 nil。
    func childText(_ name: String) -> String? {
        guard let value = child(name)?.text, !value.isEmpty else { return nil }
        return value
    }

    var doubleValue: Double? {
        Double(text)
    }
}

/// `XMLParser` 的树构建委托。
final class OmniPlanXMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: OmniPlanXMLNode?
    private(set) var failure: String?
    private var stack: [OmniPlanXMLNode] = []

    func parse(_ data: Data) -> OmniPlanXMLNode? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse(), failure == nil, let root else { return nil }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = OmniPlanXMLNode(name: Self.localName(elementName), attributes: attributeDict)
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
        if failure == nil {
            failure = "第 \(parser.lineNumber) 行第 \(parser.columnNumber) 列：\(parseError.localizedDescription)"
        }
    }

    /// 前缀无关：`opns:task` 与 `task` 视为同名元素。
    private static func localName(_ elementName: String) -> String {
        guard let separator = elementName.lastIndex(of: ":") else { return elementName }
        return String(elementName[elementName.index(after: separator)...])
    }
}
