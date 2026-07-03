#!/usr/bin/env swift
import AppKit

// Diagnostic: dumps the current state of NSPasteboard.general
// so we can empirically compare two paste scenarios:
//
//   1. Native ⌘⇧⌃4 screenshot paste on host.
//   2. Guest ⌘⇧⌃4 screenshot, pasted into the host via the
//      SPICE clipboard bridge.
//
// Run with:  swift scripts/dump-pasteboard.swift
//
// What to look for in the diff:
//   - Set of declared `types`. Missing or extra UTIs explain
//     whether a consumer app (iMessage) sees an "inline image"
//     signal it's expecting.
//   - Byte counts per type. A zero-byte type is a promised
//     placeholder — the producer (Apple's SPICE peer) hasn't
//     materialized it yet, and a read will force a round-trip.
//   - Number of pasteboard items. Native screenshot paste is
//     typically one item with several types; multi-item state
//     can trigger different consumer-app branches.

let pb = NSPasteboard.general
print("changeCount: \(pb.changeCount)")

let topTypes = pb.types ?? []
print("top-level types (\(topTypes.count)):")
for t in topTypes {
    let size = pb.data(forType: t)?.count ?? -1
    print("  \(t.rawValue): \(size) bytes")
}

let items = pb.pasteboardItems ?? []
print("pasteboardItems (\(items.count)):")
for (idx, item) in items.enumerated() {
    print("  item[\(idx)] types:")
    for t in item.types {
        let size = item.data(forType: t)?.count ?? -1
        print("    \(t.rawValue): \(size) bytes")
    }
}

// Canonical consumer-app probes. iMessage / Mail / Notes all
// go through some variant of these. Whichever returns `true`
// is what makes the paste land as an inline image vs. file.
let probes: [(label: String, types: [String])] = [
    ("public.image conformance",          ["public.image"]),
    ("NSImage class readable (png/tiff)", [NSPasteboard.PasteboardType.png.rawValue,
                                           NSPasteboard.PasteboardType.tiff.rawValue]),
    ("public.file-url",                   ["public.file-url"]),
    ("com.apple.pasteboard.promised-file-url",
                                          ["com.apple.pasteboard.promised-file-url"]),
]
print("probes:")
for probe in probes {
    let types = probe.types.map(NSPasteboard.PasteboardType.init(rawValue:))
    let answer = pb.canReadItem(withDataConformingToTypes: types.map(\.rawValue))
    print("  \(probe.label): \(answer)")
}
