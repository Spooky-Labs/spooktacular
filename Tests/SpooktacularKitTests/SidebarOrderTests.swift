import Testing
@testable import SpooktacularCore

@Suite("SidebarOrder")
struct SidebarOrderTests {

    // MARK: - moving

    @Test("moves one item before a target")
    func moveBefore() {
        #expect(SidebarOrder.moving(["c"], before: "a", in: ["a", "b", "c"]) == ["c", "a", "b"])
    }

    @Test("nil target moves to the end")
    func moveToEnd() {
        #expect(SidebarOrder.moving(["a"], before: nil, in: ["a", "b", "c"]) == ["b", "c", "a"])
    }

    @Test("absent target moves to the end")
    func absentTargetToEnd() {
        #expect(SidebarOrder.moving(["a"], before: "zzz", in: ["a", "b", "c"]) == ["b", "c", "a"])
    }

    @Test("moves a contiguous multi-selection, preserving their order")
    func moveBlock() {
        #expect(SidebarOrder.moving(["a", "c"], before: "b", in: ["a", "b", "c", "d"]) == ["a", "c", "b", "d"])
    }

    @Test("moving is a permutation — no drops, no dupes")
    func movePermutation() {
        let result = SidebarOrder.moving(["b"], before: "a", in: ["a", "b", "c"])
        #expect(Set(result) == Set(["a", "b", "c"]))
        #expect(result.count == 3)
    }

    // MARK: - arrange

    @Test("ranked keys come first in custom order, rest via fallback")
    func arrangeRankedThenRest() {
        let out = SidebarOrder.arrange(
            ["a", "b", "c"], by: ["c", "a"], fallback: { $0.sorted() }
        )
        #expect(out == ["c", "a", "b"])
    }

    @Test("new (unranked) key appears via fallback, not dropped")
    func arrangeNewKey() {
        // "d" was created since the last drag — it's not in customOrder.
        let out = SidebarOrder.arrange(
            ["a", "b", "c", "d"], by: ["c", "a"], fallback: { $0.sorted() }
        )
        #expect(out == ["c", "a", "b", "d"])
    }

    @Test("stale keys in the custom order are ignored (self-healing)")
    func arrangeStaleKeys() {
        // "gone" was deleted; customOrder still references it.
        let out = SidebarOrder.arrange(
            ["a", "b"], by: ["gone", "b", "a"], fallback: { $0.sorted() }
        )
        #expect(out == ["b", "a"])
    }

    @Test("arrange is always a permutation of the live keys")
    func arrangePermutation() {
        let keys = ["x", "y", "z"]
        let out = SidebarOrder.arrange(keys, by: ["z"], fallback: { $0.sorted() })
        #expect(Set(out) == Set(keys))
        #expect(out.count == keys.count)
    }
}
