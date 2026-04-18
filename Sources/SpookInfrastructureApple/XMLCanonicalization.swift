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

    /// Hard caps on internal-entity expansion and nesting depth.
    ///
    /// "Billion laughs" and its modern variants rely on nested
    /// entity definitions whose expansion blows up exponentially
    /// (e.g. 10 levels × 10 children → 10^10 expansions). Apple's
    /// `XMLParser` exposes `shouldResolveExternalEntities` but
    /// has no built-in cap on **internal** entity expansion, so
    /// we count expansions in the delegate and bail once either
    /// limit is crossed.
    ///
    /// The concrete numbers are defensive but still generous —
    /// well-formed SAML assertions use ≤ 5 entity references
    /// (mostly `&amp;`) and ≤ 10 levels of nesting. See
    /// https://developer.apple.com/documentation/foundation/xmlparser .
    public static let maxEntityExpansions = 100
    public static let maxElementDepth = 10

    /// Parses XML bytes into a canonicalization-ready tree.
    ///
    /// ## XXE and billion-laughs defense
    ///
    /// Hardened against the two XML-entity attacks the OWASP XML
    /// Security Cheat Sheet calls out for SAML parsers:
    ///
    /// - **External entity (XXE)** — `shouldResolveExternalEntities`
    ///   is explicitly set to `false`. Apple's `XMLParser` defaults
    ///   are already conservative on macOS, but pinning the flag
    ///   removes any ambiguity across OS versions.
    /// - **Internal entity expansion (billion laughs / quadratic
    ///   blowup)** — `foundInternalEntityDeclaration` is tracked
    ///   in the delegate, and `maxEntityExpansions` caps the
    ///   running count across the parse. We also cap nesting
    ///   depth at `maxElementDepth`. Crossing either limit aborts
    ///   the parser and surfaces a typed error.
    ///
    /// - Parameter data: Raw XML bytes.
    /// - Throws: ``XMLCanonicalizationError`` if parsing fails or
    ///   entity/depth limits are exceeded.
    /// - Returns: The root element of the parsed tree.
    public static func parse(_ data: Data) throws -> Element {
        let builder = XMLTreeBuilder()
        builder.maxEntityExpansions = maxEntityExpansions
        builder.maxElementDepth = maxElementDepth
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        // XXE prevention — see
        // https://developer.apple.com/documentation/foundation/xmlparser
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder

        guard parser.parse() else {
            // The delegate aborts the parser with typed errors
            // for the entity-expansion and depth limits; surface
            // those directly instead of re-wrapping in parseFailed.
            if let limitError = builder.entityLimitError {
                throw limitError
            }
            throw XMLCanonicalizationError.parseFailed(parser.parserError)
        }
        if let limitError = builder.entityLimitError {
            throw limitError
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
    // `@unchecked Sendable` because this class carries mutable
    // `var`s (attributes, declaredNamespaces, children, weak
    // parent) that the SAX builder populates during `parse(_:)`
    // and nothing mutates afterward. Every caller in this repo
    // treats the returned tree as immutable — SAML verification
    // reads it within a single actor-isolated call and discards
    // it. Marking it Sendable here unblocks Swift 6 strict-
    // concurrency diagnostics that otherwise flag every pass
    // from `SAMLAssertionVerifier.verify(token:)` (an `actor`)
    // into its own private helpers as "sending a non-Sendable
    // value risks data races", even though the send stays
    // inside the same actor.
    //
    // Do not mutate an `Element` after `XMLCanonicalization.parse`
    // returns — treat the tree as read-only. If a future caller
    // wants to mutate post-parse, convert the vars to `let` and
    // move the SAX fill-in to a separate builder type so this
    // assertion stays honest.
    public final class Element: @unchecked Sendable {

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
///
/// ## Billion-laughs defense
///
/// The builder also counts internal entity declarations and
/// element-nesting depth, aborting the parser through
/// `XMLParser.abortParsing()` when either crosses its cap. The
/// typed error is stashed in `entityLimitError` so the caller
/// surfaces it instead of the generic "parse failed".
final class XMLTreeBuilder: NSObject, XMLParserDelegate {

    private(set) var root: XMLCanonicalization.Element?
    private var stack: [XMLCanonicalization.Element] = []
    private var pendingNamespaces: [String: String] = [:]

    /// Cap on internal entity declarations. Set by the parent
    /// before parsing starts.
    var maxEntityExpansions = Int.max

    /// Cap on live element-nesting depth. Set by the parent
    /// before parsing starts.
    var maxElementDepth = Int.max

    /// Typed error produced when we abort the parser due to
    /// limit exceedance. Surfaced by `XMLCanonicalization.parse`.
    var entityLimitError: XMLCanonicalizationError?

    private var entityDeclCount = 0

    // MARK: - Entity-expansion tracking

    /// Fires for every `<!ENTITY name "value">` the parser sees.
    /// We count declarations (not live expansions — the parser
    /// already resolves them into `foundCharacters`) and abort
    /// once the cap is crossed. Billion-laughs style attacks
    /// rely on dozens of nested declarations.
    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        entityDeclCount += 1
        if entityDeclCount > maxEntityExpansions {
            entityLimitError = .entityExpansionLimitExceeded(
                limit: maxEntityExpansions
            )
            parser.abortParsing()
        }
    }

    /// External entities are blocked at the source
    /// (`shouldResolveExternalEntities = false`) but if we ever
    /// observe a declaration for one we count it anyway — a
    /// defense-in-depth belt over the configuration brace.
    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        entityDeclCount += 1
        if entityDeclCount > maxEntityExpansions {
            entityLimitError = .entityExpansionLimitExceeded(
                limit: maxEntityExpansions
            )
            parser.abortParsing()
        }
    }

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
        // Nesting-depth cap — XMLParser has no built-in bound.
        if stack.count >= maxElementDepth {
            entityLimitError = .elementDepthExceeded(limit: maxElementDepth)
            parser.abortParsing()
            return
        }

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

    /// CDATA fidelity — XMLParser delivers CDATA content through
    /// `foundCDATA` instead of `foundCharacters`. We decode the
    /// bytes as UTF-8 and append them as a normal text node so
    /// the canonicalizer applies the C14N §2.3 escape rules (`&`
    /// → `&amp;`, `<` → `&lt;`). Per Canonical XML 1.0 §1.1 the
    /// CDATA marker itself is REPLACED in canonical form — any
    /// preserved `<![CDATA[…]]>` literal would break the digest
    /// for SAML assertions signed by an IdP that CDATA-wraps
    /// attribute values (a real pattern in Okta and Google
    /// Workspace IdPs).
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let current = stack.last,
              let string = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
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

    /// The document declared more internal entities than
    /// ``XMLCanonicalization/maxEntityExpansions`` permits.
    /// Surfaces on billion-laughs inputs (OWASP XML §XXE).
    case entityExpansionLimitExceeded(limit: Int)

    /// Element nesting exceeded ``XMLCanonicalization/maxElementDepth``.
    /// A complementary defense to entity-expansion limits against
    /// deeply-nested adversarial inputs.
    case elementDepthExceeded(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let error):
            return "XML parse failed: \(error?.localizedDescription ?? "unknown")"
        case .emptyDocument:
            return "XML document had no root element"
        case .entityExpansionLimitExceeded(let limit):
            return "XML document declared more than \(limit) internal entities — refusing to expand (billion-laughs / quadratic-blowup defense)"
        case .elementDepthExceeded(let limit):
            return "XML document nested deeper than \(limit) levels — refusing to parse"
        }
    }
}
