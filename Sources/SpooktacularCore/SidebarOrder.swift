import Foundation

/// Pure ordering logic for a user-reorderable sidebar list.
///
/// The GUI's VM sidebar becomes drag-reorderable on macOS 27 via SwiftUI's
/// `reorderable()` / `reorderContainer(for:move:)` (both new in macOS 27).
/// The *rules* of reordering — how a drag mutates the persisted order, and
/// how a persisted order arranges the live key set — are framework-free and
/// live here so they're unit-testable without a running view.
public enum SidebarOrder {

    /// Applies a drag: removes `ids` from `order` and reinserts them as one
    /// contiguous block immediately before `target`, or at the end when
    /// `target` is `nil` or absent from the list.
    ///
    /// Mirrors SwiftUI's `ReorderDifference` payload, whose `destination`
    /// position is `.before(id)` or `.end`.
    ///
    /// - Parameters:
    ///   - ids: The item ids being moved (drag can carry a multi-selection),
    ///     kept in their given relative order.
    ///   - target: The id the block lands before; `nil` means "to the end".
    ///   - order: The current full order.
    /// - Returns: The new order.
    public static func moving(
        _ ids: [String],
        before target: String?,
        in order: [String]
    ) -> [String] {
        let moved = Set(ids)
        var result = order.filter { !moved.contains($0) }
        if let target, let idx = result.firstIndex(of: target) {
            result.insert(contentsOf: ids, at: idx)
        } else {
            result.append(contentsOf: ids)
        }
        return result
    }

    /// Arranges `keys` by a persisted custom order: keys present in
    /// `customOrder` come first, in that order; keys not yet ranked (e.g. a
    /// VM created since the last drag) are appended in `fallback` order.
    ///
    /// This keeps the sidebar stable — a newly-created VM shows up in its
    /// natural place rather than disturbing the user's arrangement — and it
    /// self-heals when `customOrder` references keys that no longer exist
    /// (those are simply dropped).
    ///
    /// - Parameters:
    ///   - keys: The live key set to arrange.
    ///   - customOrder: The persisted user order (may contain stale keys).
    ///   - fallback: Orders the not-yet-ranked keys (e.g. alphabetical).
    /// - Returns: `keys` arranged; a permutation of `keys` (no additions,
    ///   no drops).
    public static func arrange(
        _ keys: [String],
        by customOrder: [String],
        fallback: ([String]) -> [String]
    ) -> [String] {
        let live = Set(keys)
        var seen = Set<String>()
        var ranked: [String] = []
        for key in customOrder where live.contains(key) && seen.insert(key).inserted {
            ranked.append(key)
        }
        let rest = fallback(keys.filter { !seen.contains($0) })
        return ranked + rest
    }
}
