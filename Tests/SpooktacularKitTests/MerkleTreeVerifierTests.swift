import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication

@Suite("MerkleTreeVerifier (RFC 6962)")
struct MerkleTreeVerifierTests {

    // MARK: - Primitive hashes

    @Test("leaf hash is SHA-256 of 0x00 || data")
    func leafHash() {
        let data = Data("hello".utf8)
        let got = MerkleTreeVerifier.leafHash(data)
        var input = Data([0x00])
        input.append(data)
        let expected = SHA256.hash(data: input).withUnsafeBytes { Data($0) }
        #expect(got == expected)
    }

    @Test("inner node hash is SHA-256 of 0x01 || left || right")
    func innerHash() {
        let left = Data(repeating: 0xAA, count: 32)
        let right = Data(repeating: 0xBB, count: 32)
        let got = MerkleTreeVerifier.innerHash(left, right)
        var input = Data([0x01])
        input.append(left)
        input.append(right)
        let expected = SHA256.hash(data: input).withUnsafeBytes { Data($0) }
        #expect(got == expected)
    }

    // MARK: - Golden tree (RFC 6962 shape)

    /// Builds a balanced 4-leaf tree matching RFC 6962's algorithm
    /// and exercises inclusion proofs for each leaf.
    @Test("4-leaf tree: every leaf verifies with its audit path", arguments: 0..<4)
    func fourLeafTree(leafIndex: Int) {
        // Leaf payloads.
        let leaves = (0..<4).map { Data("leaf-\($0)".utf8) }
        let leafHashes = leaves.map { MerkleTreeVerifier.leafHash($0) }

        // Tree:
        //        root
        //       /    \
        //     h01    h23
        //    /  \   /  \
        //   l0  l1 l2  l3
        let h01 = MerkleTreeVerifier.innerHash(leafHashes[0], leafHashes[1])
        let h23 = MerkleTreeVerifier.innerHash(leafHashes[2], leafHashes[3])
        let root = MerkleTreeVerifier.innerHash(h01, h23)

        let audit: [Data]
        switch leafIndex {
        case 0: audit = [leafHashes[1], h23]
        case 1: audit = [leafHashes[0], h23]
        case 2: audit = [leafHashes[3], h01]
        case 3: audit = [leafHashes[2], h01]
        default: audit = []
        }
        let rootHex = root.map { String(format: "%02x", $0) }.joined()
        let ok = MerkleTreeVerifier.verifyInclusion(
            leafBytes: leaves[leafIndex],
            leafIndex: leafIndex,
            auditPath: audit,
            treeSize: 4,
            expectedRootHex: rootHex
        )
        #expect(ok, "leaf \(leafIndex) should verify under its own audit path")
    }

    @Test("mismatched root fails verification")
    func mismatchedRoot() {
        let leaves = (0..<2).map { Data("leaf-\($0)".utf8) }
        let leafHashes = leaves.map { MerkleTreeVerifier.leafHash($0) }
        let badRoot = Data(repeating: 0xFF, count: 32)
            .map { String(format: "%02x", $0) }.joined()
        let ok = MerkleTreeVerifier.verifyInclusion(
            leafBytes: leaves[0],
            leafIndex: 0,
            auditPath: [leafHashes[1]],
            treeSize: 2,
            expectedRootHex: badRoot
        )
        #expect(!ok)
    }

    @Test("out-of-range leaf index fails verification")
    func outOfRangeIndex() {
        let data = Data("a".utf8)
        let hex = Data(repeating: 0, count: 32)
            .map { String(format: "%02x", $0) }.joined()
        let ok = MerkleTreeVerifier.verifyInclusion(
            leafBytes: data,
            leafIndex: 5,
            auditPath: [],
            treeSize: 1,
            expectedRootHex: hex
        )
        #expect(!ok)
    }

    // MARK: - Odd-leaf promotion (tree size 3)

    @Test("3-leaf tree with odd-leaf promotion: leaf 2 verifies")
    func threeLeafOddPromotion() {
        // RFC 6962 odd-leaf rule: at each level, a leaf with no
        // sibling is promoted unchanged to the next level.
        //
        //        root = inner(inner(l0,l1), l2)
        //        /                  \
        //       h01                   l2 (promoted)
        //      /   \
        //     l0    l1
        let leaves = (0..<3).map { Data("leaf-\($0)".utf8) }
        let h = leaves.map { MerkleTreeVerifier.leafHash($0) }
        let h01 = MerkleTreeVerifier.innerHash(h[0], h[1])
        let root = MerkleTreeVerifier.innerHash(h01, h[2])
        let rootHex = root.map { String(format: "%02x", $0) }.joined()

        let ok = MerkleTreeVerifier.verifyInclusion(
            leafBytes: leaves[2],
            leafIndex: 2,
            auditPath: [h01],
            treeSize: 3,
            expectedRootHex: rootHex
        )
        #expect(ok)
    }

    // MARK: - Hex decoding

    @Test("hexToData round-trips with upper and lower case")
    func hexDecoding() {
        let sample = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let lower = MerkleTreeVerifier.hexToData("deadbeef")
        let upper = MerkleTreeVerifier.hexToData("DEADBEEF")
        #expect(lower == sample)
        #expect(upper == sample)
    }

    @Test("hexToData returns empty on invalid input")
    func hexInvalid() {
        #expect(MerkleTreeVerifier.hexToData("xyz") == Data())
        #expect(MerkleTreeVerifier.hexToData("abc") == Data())
    }
}
