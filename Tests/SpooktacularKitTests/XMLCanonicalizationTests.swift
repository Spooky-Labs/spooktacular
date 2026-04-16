import Testing
import Foundation
@testable import SpookInfrastructureApple

@Suite("XML Canonicalization", .tags(.security, .cryptography))
struct XMLCanonicalizationTests {

    /// Helper: parse, canonicalize the root, decode UTF-8 for assertion.
    private static func canonicalString(_ xml: String) throws -> String {
        let data = Data(xml.utf8)
        let root = try XMLCanonicalization.parse(data)
        let out = XMLCanonicalization.canonicalize(root)
        return String(data: out, encoding: .utf8) ?? ""
    }

    // MARK: - Character escaping

    @Suite("Text escaping (C14N §2.3)")
    struct TextEscaping {

        @Test("Ampersand escapes")
        func ampersand() throws {
            let out = try XMLCanonicalizationTests.canonicalString(
                "<e>foo &amp; bar</e>"
            )
            #expect(out == "<e>foo &amp; bar</e>")
        }

        @Test("Less-than escapes")
        func lessThan() throws {
            let out = try XMLCanonicalizationTests.canonicalString(
                "<e>foo &lt; bar</e>"
            )
            #expect(out == "<e>foo &lt; bar</e>")
        }

        @Test("Greater-than escapes in text (C14N requires this)")
        func greaterThan() throws {
            let out = try XMLCanonicalizationTests.canonicalString(
                "<e>foo &gt; bar</e>"
            )
            #expect(out == "<e>foo &gt; bar</e>")
        }
    }

    @Suite("Attribute-value escaping (C14N §2.3)")
    struct AttributeEscaping {

        @Test("Quote escapes inside attribute")
        func quote() throws {
            let out = try XMLCanonicalizationTests.canonicalString(
                #"<e attr="he said &quot;hi&quot;"></e>"#
            )
            #expect(out.contains(#"attr="he said &quot;hi&quot;""#))
        }

        @Test("Tab/newline/CR escape in attributes, not in element text")
        func whitespaceEscape() throws {
            // NB: XML parsers normalize CR/LF to LF before parsing,
            // per XML 1.0 §2.11 — this is the input the canonicalizer
            // actually sees.
            let out = try XMLCanonicalizationTests.canonicalString(
                "<e attr=\"a&#x9;b\"></e>"
            )
            #expect(out.contains(#"attr="a&#x9;b""#))
        }

        @Test("Ampersand-in-attribute escapes to &amp;")
        func ampersandInAttribute() throws {
            let out = try XMLCanonicalizationTests.canonicalString(
                #"<e attr="tom &amp; jerry"></e>"#
            )
            #expect(out.contains(#"attr="tom &amp; jerry""#))
        }
    }

    // MARK: - Structural rules

    @Suite("Structural canonicalization")
    struct Structure {

        @Test("Empty elements expand to start-end pairs")
        func emptyElementExpansion() throws {
            let out = try XMLCanonicalizationTests.canonicalString(#"<e/>"#)
            #expect(out == "<e></e>")
        }

        @Test("Attribute order: namespace URI then local name")
        func attributeSortOrder() throws {
            // Attributes presented out-of-order must come back sorted
            // lexicographically by (namespace URI, local name). Unprefixed
            // attributes live in no namespace and sort before prefixed ones.
            let out = try XMLCanonicalizationTests.canonicalString(
                #"<e zed="3" alpha="1" beta="2"></e>"#
            )
            #expect(out == #"<e alpha="1" beta="2" zed="3"></e>"#)
        }

        @Test("Namespace declarations sorted: default first, then by prefix")
        func namespaceSortOrder() throws {
            // The element itself uses the default namespace (no prefix);
            // its attributes use the two prefixed namespaces. All three
            // are visibly utilized, so all three must be emitted on this
            // element — default first, then prefixes lexicographically.
            let out = try XMLCanonicalizationTests.canonicalString(
                #"<e xmlns="d" xmlns:zed="z" xmlns:alpha="a" zed:flag="2" alpha:mark="1"/>"#
            )
            let xmlnsDefault = try #require(out.range(of: #"xmlns="d""#))
            let xmlnsAlpha = try #require(out.range(of: #"xmlns:alpha="a""#))
            let xmlnsZed = try #require(out.range(of: #"xmlns:zed="z""#))
            #expect(xmlnsDefault.lowerBound < xmlnsAlpha.lowerBound)
            #expect(xmlnsAlpha.lowerBound < xmlnsZed.lowerBound)
        }
    }

    // MARK: - Exclusive namespace rendering

    @Suite("Exclusive C14N namespace rendering")
    struct ExclusiveNamespaces {

        @Test("Unused ancestor namespace is dropped")
        func dropsUnusedAncestorNamespace() throws {
            // Classic Exclusive C14N example: n0 is declared on the root
            // but is not visibly used by `n1:elem1`. Under inclusive
            // C14N it would be emitted; under exclusive, it's dropped.
            let xml = """
            <n0:pdu xmlns:n0="http://a.example">\
            <n1:elem1 xmlns:n1="http://b.example">content</n1:elem1>\
            </n0:pdu>
            """
            let data = Data(xml.utf8)
            let root = try XMLCanonicalization.parse(data)
            let elem1 = root.children.compactMap { node -> XMLCanonicalization.Element? in
                if case .element(let e) = node { return e } else { return nil }
            }.first
            let inner = try #require(elem1)
            let out = XMLCanonicalization.canonicalize(inner)
            let text = try #require(String(data: out, encoding: .utf8))
            #expect(text == #"<n1:elem1 xmlns:n1="http://b.example">content</n1:elem1>"#)
            #expect(!text.contains("n0:"))
        }

        @Test("Utilized namespaces are rendered on the outermost element that uses them")
        func rendersUtilizedOnOutermost() throws {
            let xml = """
            <root xmlns:a="http://a.example"><a:child>x</a:child></root>
            """
            let out = try XMLCanonicalizationTests.canonicalString(xml)
            #expect(out == #"<root><a:child xmlns:a="http://a.example">x</a:child></root>"#)
        }
    }

    // MARK: - Subset exclusion (enveloped-signature transform)

    @Suite("Enveloped-signature subset exclusion")
    struct EnvelopedSignature {

        @Test("Excluded element and descendants are omitted from output")
        func excludesSubtree() throws {
            let xml = """
            <Assertion ID="_1">\
            <Issuer>idp</Issuer>\
            <Signature><SignatureValue>abc</SignatureValue></Signature>\
            </Assertion>
            """
            let data = Data(xml.utf8)
            let root = try XMLCanonicalization.parse(data)
            let signature = root.children.compactMap { node -> XMLCanonicalization.Element? in
                if case .element(let e) = node, e.localName == "Signature" { return e }
                return nil
            }.first
            let sigElement = try #require(signature, "Signature element must be locatable")

            let canonical = XMLCanonicalization.canonicalize(root) { element in
                element === sigElement
            }
            let text = try #require(String(data: canonical, encoding: .utf8))
            #expect(text.contains("<Issuer>idp</Issuer>"))
            #expect(!text.contains("<Signature"))
            #expect(!text.contains("SignatureValue"))
        }
    }
}
