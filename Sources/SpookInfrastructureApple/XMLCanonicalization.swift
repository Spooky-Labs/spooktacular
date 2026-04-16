import Foundation

/// Exclusive XML Canonicalization (`http://www.w3.org/2001/10/xml-exc-c14n#`).
///
/// Implements the byte-exact canonical form required by XML Digital
/// Signatures — specifically the subset used by SAML assertions.
///
/// ## Standards
/// - [Canonical XML Version 1.0](https://www.w3.org/TR/xml-c14n/)
/// - [Exclusive XML Canonicalization 1.0](https://www.w3.org/TR/xml-exc-c14n/)
/// - [XML Signature Syntax and Processing 1.1](https://www.w3.org/TR/xmldsig-core1/)
///
/// ## What's implemented
/// - UTF-8 output, no BOM, no XML declaration.
/// - Element text escaping: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `\r` → `&#xD;`.
/// - Attribute value escaping: plus `"` → `&quot;`, `\t` → `&#x9;`, `\n` → `&#xA;`.
/// - Attribute sort: namespace URI, then local name (C14N §2.3).
/// - Namespace declaration sort: default first, then by prefix.
/// - Empty elements expanded to `<e></e>` (no self-closing).
/// - Whitespace between attributes normalized to single space.
/// - Exclusive namespace rendering: emit a prefix only when visibly
///   utilized by the element or a descendant in the output subset,
///   and when not already output by an ancestor (Exc-C14N §3.2).
/// - Document-subset support: any subtree can be excluded (used to
///   strip the `<ds:Signature>` element when applying the
///   enveloped-signature transform).
///
/// ## What's deliberately left out
/// Comments, processing instructions, DTDs, `xml:base` fixup, and the
/// `InclusiveNamespaces PrefixList` are not emitted — SAML assertions
/// don't produce them. Adding them is mechanical if a future caller needs it.
public enum XMLCanonicalization {

    // MARK: - Public API

    /// Canonicalizes a subtree under Exclusive C14N rules.
    ///
    /// - Parameters:
    ///   - element: The root of the subtree to serialize.
    ///   - excluding: A predicate — any element returning `true` is
    ///     omitted from output together with its descendants. Used to
    ///     apply the enveloped-signature transform (strip `<Signature>`).
    /// - Returns: The canonical UTF-8 bytes for the subtree.
    public static func canonicalize(
        _ element: Element,
        excluding: (Element) -> Bool = { _ in false }
    ) -> Data {
        var out = Data()
        serializeElement(
            element,
            out: &out,
            renderedScope: [:],
            excluding: excluding
        )
        return out
    }

    /// Parses XML bytes into a canonicalization-ready tree.
    ///
    /// - Parameter data: Raw XML bytes.
    /// - Throws: ``XMLCanonicalizationError`` if parsing fails.
    /// - Returns: The root element of the parsed tree.
    public static func parse(_ data: Data) throws -> Element {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false  // XXE prevention
        parser.delegate = builder

        guard parser.parse() else {
            throw XMLCanonicalizationError.parseFailed(parser.parserError)
        }
        guard let root = builder.root else {
            throw XMLCanonicalizationError.emptyDocument
        }
        return root
    }

    // MARK: - Serialization

    /// Serializes one element per Canonical XML 1.0 + Exclusive C14N rules.
    private static func serializeElement(
        _ element: Element,
        out: inout Data,
        renderedScope: [String: String],
        excluding: (Element) -> Bool
    ) {
        if excluding(element) { return }

        // 1. Compute visibly-utilized prefixes for this element alone.
        //    Descendants emit their own prefixes when we recurse — the
        //    Exc-C14N rule is "rendered by an output ancestor *for this
        //    element's visibly utilized prefix*", not "a descendant's".
        let utilized = visiblyUtilizedPrefixes(of: element)

        // 2. Decide which namespaces to emit on this element.
        //    Emit a namespace declaration if:
        //      - the prefix is visibly utilized here or below, AND
        //      - the same binding is not already in the rendered scope.
        var newlyRendered: [(prefix: String, uri: String)] = []
        for prefix in utilized {
            guard let uri = lookupNamespace(prefix, in: element) else { continue }
            if renderedScope[prefix] == uri { continue }
            newlyRendered.append((prefix, uri))
        }
        // Special case: if the default namespace is utilized but this
        // element doesn't declare it (inherited from ancestor), we still
        // need `xmlns=""` when the ancestor's default was non-empty but
        // this element uses the no-namespace default. SAML assertions
        // don't hit this corner, but the case is here for completeness.
        if utilized.contains("") && lookupNamespace("", in: element) == nil
            && renderedScope[""] != nil && renderedScope[""] != "" {
            newlyRendered.append(("", ""))
        }

        // 3. Sort namespace declarations: default first, then by prefix.
        newlyRendered.sort { lhs, rhs in
            if lhs.prefix.isEmpty && !rhs.prefix.isEmpty { return true }
            if !lhs.prefix.isEmpty && rhs.prefix.isEmpty { return false }
            return lhs.prefix < rhs.prefix
        }

        // 4. Sort attributes: namespace URI, then local name.
        let attributes = element.attributes.sorted { lhs, rhs in
            if lhs.namespaceURI != rhs.namespaceURI {
                return lhs.namespaceURI < rhs.namespaceURI
            }
            return lhs.localName < rhs.localName
        }

        // 5. Emit start tag.
        out.append(UInt8(ascii: "<"))
        out.append(contentsOf: Array(element.qualifiedName.utf8))

        for ns in newlyRendered {
            out.append(UInt8(ascii: " "))
            if ns.prefix.isEmpty {
                out.append(contentsOf: Array("xmlns=\"".utf8))
            } else {
                out.append(contentsOf: Array("xmlns:\(ns.prefix)=\"".utf8))
            }
            appendEscapedAttribute(ns.uri, into: &out)
            out.append(UInt8(ascii: "\""))
        }

        for attr in attributes {
            out.append(UInt8(ascii: " "))
            out.append(contentsOf: Array(attr.qualifiedName.utf8))
            out.append(contentsOf: Array("=\"".utf8))
            appendEscapedAttribute(attr.value, into: &out)
            out.append(UInt8(ascii: "\""))
        }

        out.append(UInt8(ascii: ">"))

        // 6. Build the scope passed to children.
        var childScope = renderedScope
        for ns in newlyRendered {
            childScope[ns.prefix] = ns.uri
        }

        // 7. Emit children.
        for child in element.children {
            switch child {
            case .element(let childElement):
                serializeElement(
                    childElement,
                    out: &out,
                    renderedScope: childScope,
                    excluding: excluding
                )
            case .text(let text):
                appendEscapedText(text, into: &out)
            }
        }

        // 8. Emit end tag (always — no self-closing in canonical form).
        out.append(contentsOf: Array("</".utf8))
        out.append(contentsOf: Array(element.qualifiedName.utf8))
        out.append(UInt8(ascii: ">"))
    }

    // MARK: - Namespace analysis

    /// Returns the prefixes visibly utilized by `element` itself.
    ///
    /// Per Exc-C14N §3.2, a prefix is "visibly utilized" when it is the
    /// prefix on the element's own qualified name, or on any of its
    /// attributes' qualified names. **Descendants are not considered** —
    /// they handle their own rendering when we recurse into them. The
    /// prefix of the element's own name counts even when it is the
    /// empty string (the default namespace).
    private static func visiblyUtilizedPrefixes(of element: Element) -> Set<String> {
        var used: Set<String> = [element.prefix ?? ""]
        for attr in element.attributes {
            if let p = attr.prefix {
                used.insert(p)
            }
            // Unprefixed attributes live in no namespace and don't pull
            // in the default namespace — C14N §2.3 / Exc-C14N §3.2.
        }
        return used
    }

    /// Walks up the element's in-scope declarations to resolve a prefix
    /// to its URI. Returns `nil` if undeclared.
    private static func lookupNamespace(_ prefix: String, in element: Element) -> String? {
        if let uri = element.declaredNamespaces[prefix] { return uri }
        if let parent = element.parent { return lookupNamespace(prefix, in: parent) }
        return nil
    }

    // MARK: - Escaping

    /// Applies the element-text escape rules from C14N §2.3.
    private static func appendEscapedText(_ string: String, into out: inout Data) {
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: Array("&amp;".utf8))
            case "<": out.append(contentsOf: Array("&lt;".utf8))
            case ">": out.append(contentsOf: Array("&gt;".utf8))
            case "\u{0D}": out.append(contentsOf: Array("&#xD;".utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
    }

    /// Applies the attribute-value escape rules from C14N §2.3.
    private static func appendEscapedAttribute(_ string: String, into out: inout Data) {
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: Array("&amp;".utf8))
            case "<": out.append(contentsOf: Array("&lt;".utf8))
            case "\"": out.append(contentsOf: Array("&quot;".utf8))
            case "\u{09}": out.append(contentsOf: Array("&#x9;".utf8))
            case "\u{0A}": out.append(contentsOf: Array("&#xA;".utf8))
            case "\u{0D}": out.append(contentsOf: Array("&#xD;".utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
    }

    // MARK: - Tree Model (nested to avoid colliding with Foundation.XMLElement)

    /// An XML element node in a canonicalization tree.
    ///
    /// Reference semantics are used so the parser can populate children
    /// during SAX callbacks and so canonicalization can walk parent
    /// links to resolve inherited namespaces.
    public final class Element {

        /// Namespace URI (empty if none).
        public let namespaceURI: String

        /// Local (unqualified) element name.
        public let localName: String

        /// Namespace prefix as it appeared in the source, if any.
        public let prefix: String?

        /// Attributes declared on the element (not namespace declarations).
        public var attributes: [Attribute]

        /// Namespace prefixes declared on *this* element (prefix → URI).
        /// Does not include inherited declarations.
        public var declaredNamespaces: [String: String]

        /// Child nodes in document order.
        public var children: [Node]

        /// Parent element, or `nil` for the root.
        public weak var parent: Element?

        public init(
            namespaceURI: String,
            localName: String,
            prefix: String?,
            attributes: [Attribute] = [],
            declaredNamespaces: [String: String] = [:],
            children: [Node] = [],
            parent: Element? = nil
        ) {
            self.namespaceURI = namespaceURI
            self.localName = localName
            self.prefix = prefix
            self.attributes = attributes
            self.declaredNamespaces = declaredNamespaces
            self.children = children
            self.parent = parent
        }

        /// Qualified name as it appears in source (`"ds:SignedInfo"` or `"Assertion"`).
        public var qualifiedName: String {
            if let prefix, !prefix.isEmpty {
                return "\(prefix):\(localName)"
            }
            return localName
        }
    }

    /// A node in the canonicalization tree — either an element or text.
    public enum Node {
        case element(Element)
        case text(String)
    }

    /// An attribute on an ``XMLCanonicalization/Element``.
    public struct Attribute {
        public let namespaceURI: String
        public let localName: String
        public let prefix: String?
        public let value: String

        public init(namespaceURI: String, localName: String, prefix: String?, value: String) {
            self.namespaceURI = namespaceURI
            self.localName = localName
            self.prefix = prefix
            self.value = value
        }

        public var qualifiedName: String {
            if let prefix, !prefix.isEmpty {
                return "\(prefix):\(localName)"
            }
            return localName
        }
    }
}

// MARK: - Tree Builder

/// Builds an ``XMLElement`` tree from ``XMLParser`` SAX events.
///
/// Tracks namespace declarations via `didStartMappingPrefix` — those
/// callbacks fire *before* `didStartElement`, letting us attach the
/// declarations to the element that actually introduced them.
final class XMLTreeBuilder: NSObject, XMLParserDelegate {

    private(set) var root: XMLCanonicalization.Element?
    private var stack: [XMLCanonicalization.Element] = []
    private var pendingNamespaces: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        // Prefix bindings declared on the element about to open.
        pendingNamespaces[prefix] = namespaceURI
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        // Foundation hands us the qualified name in `qName`; split it.
        let qualified = qName ?? elementName
        let (prefix, localName) = splitQualifiedName(qualified)

        // Map the raw attribute dict into structured attributes. The
        // dict keys are qualified names; infer namespace URI from the
        // prefix lookup against the *element about to be pushed*.
        var attributes: [XMLCanonicalization.Attribute] = []
        for (rawName, value) in attributeDict {
            let (attrPrefix, attrLocal) = splitQualifiedName(rawName)
            let attrNSURI: String
            if let p = attrPrefix {
                attrNSURI = resolveNamespace(
                    p,
                    pending: pendingNamespaces,
                    stack: stack
                ) ?? ""
            } else {
                // Unprefixed attributes have no namespace per XMLNS.
                attrNSURI = ""
            }
            attributes.append(XMLCanonicalization.Attribute(
                namespaceURI: attrNSURI,
                localName: attrLocal,
                prefix: attrPrefix,
                value: value
            ))
        }

        let element = XMLCanonicalization.Element(
            namespaceURI: namespaceURI ?? "",
            localName: localName,
            prefix: prefix,
            attributes: attributes,
            declaredNamespaces: pendingNamespaces,
            children: [],
            parent: stack.last
        )
        pendingNamespaces = [:]

        if let current = stack.last {
            current.children.append(.element(element))
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = stack.last else { return }
        // Coalesce adjacent text nodes so canonicalization emits a
        // single escaped run.
        if case .text(let existing) = current.children.last {
            current.children[current.children.count - 1] = .text(existing + string)
        } else {
            current.children.append(.text(string))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    // MARK: - Private helpers

    private func splitQualifiedName(_ name: String) -> (prefix: String?, local: String) {
        if let colon = name.firstIndex(of: ":") {
            let prefix = String(name[..<colon])
            let local = String(name[name.index(after: colon)...])
            return (prefix, local)
        }
        return (nil, name)
    }

    private func resolveNamespace(
        _ prefix: String,
        pending: [String: String],
        stack: [XMLCanonicalization.Element]
    ) -> String? {
        if let uri = pending[prefix] { return uri }
        for ancestor in stack.reversed() {
            if let uri = ancestor.declaredNamespaces[prefix] { return uri }
        }
        // Implicit "xml" prefix always binds to the XML namespace.
        if prefix == "xml" { return "http://www.w3.org/XML/1998/namespace" }
        return nil
    }
}

// MARK: - Errors

/// Errors raised by ``XMLCanonicalization``.
public enum XMLCanonicalizationError: Error, LocalizedError {
    case parseFailed(Error?)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let error):
            return "XML parse failed: \(error?.localizedDescription ?? "unknown")"
        case .emptyDocument:
            return "XML document had no root element"
        }
    }
}
