import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("SnapshotManager")
struct SnapshotManagerTests {

    // MARK: - Helpers

    /// Creates a temporary VM bundle with a fake disk.img, auxiliary.bin, and machine-identifier.bin.
    private func makeTempBundle(
        diskContent: String = "fake-disk-image-data",
        auxContent: String = "fake-auxiliary-data",
        machineIdContent: String = "fake-machine-id"
    ) throws -> (VirtualMachineBundle, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundleURL = tempDir.appendingPathComponent("test.vm")
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

        // Write fake disk.img, auxiliary.bin, and machine-identifier.bin.
        try Data(diskContent.utf8).write(
            to: bundleURL.appendingPathComponent("disk.img")
        )
        try Data(auxContent.utf8).write(
            to: bundleURL.appendingPathComponent("auxiliary.bin")
        )
        try Data(machineIdContent.utf8).write(
            to: bundleURL.appendingPathComponent("machine-identifier.bin")
        )

        return (bundle, tempDir)
    }

    // MARK: - Save

    @Suite("save")
    struct SaveTests {

        private func makeTempBundle() throws -> (VirtualMachineBundle, URL) {
            let tests = SnapshotManagerTests()
            return try tests.makeTempBundle()
        }

        @Test("Creates the snapshot directory and copies files")
        func saveCreatesDirectoryAndFiles() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "test-snap")

            let snapshotDir = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("test-snap")

            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.path
            ))
            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.appendingPathComponent("disk.img").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.appendingPathComponent("auxiliary.bin").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.appendingPathComponent("machine-identifier.bin").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.appendingPathComponent("snapshot-info.json").path
            ))
        }

        @Test("Copied disk.img matches the original")
        func saveCopiesDiskContent() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "content-check")

            let originalData = try Data(contentsOf:
                bundle.url.appendingPathComponent("disk.img")
            )
            let snapshotData = try Data(contentsOf:
                bundle.url
                    .appendingPathComponent("SavedStates")
                    .appendingPathComponent("content-check")
                    .appendingPathComponent("disk.img")
            )
            #expect(originalData == snapshotData)
        }

        @Test("Snapshot info JSON contains correct label")
        func saveWritesInfoWithLabel() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "labeled")

            let infoURL = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("labeled")
                .appendingPathComponent("snapshot-info.json")

            let data = try Data(contentsOf: infoURL)
            let info = try VirtualMachineBundle.decoder.decode(SnapshotInfo.self, from: data)
            #expect(info.label == "labeled")
            #expect(info.sizeInBytes > 0)
        }

        @Test("Copies machine-identifier.bin into the snapshot")
        func saveCopiesMachineIdentifier() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "mid-check")

            let snapshotMID = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("mid-check")
                .appendingPathComponent("machine-identifier.bin")

            #expect(FileManager.default.fileExists(atPath: snapshotMID.path))

            let originalData = try Data(contentsOf:
                bundle.url.appendingPathComponent("machine-identifier.bin")
            )
            let snapshotData = try Data(contentsOf: snapshotMID)
            #expect(originalData == snapshotData)
        }

        @Test("Fails when a snapshot with the same label already exists")
        func saveFailsOnDuplicate() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "dup")

            #expect {
                try SnapshotManager.save(bundle: bundle, label: "dup")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .alreadyExists(label: "dup")
            }
        }

        @Test("Fails when disk.img is missing from the bundle")
        func saveFailsWithoutDisk() throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let bundleURL = tempDir.appendingPathComponent("nodisk.vm")
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // No disk.img created — should fail.
            #expect {
                try SnapshotManager.save(bundle: bundle, label: "fail")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                if case .fileNotFound = snapError { return true }
                return false
            }
        }
    }

    // MARK: - Restore

    @Suite("restore")
    struct RestoreTests {

        private func makeTempBundle() throws -> (VirtualMachineBundle, URL) {
            let tests = SnapshotManagerTests()
            return try tests.makeTempBundle()
        }

        @Test("Replaces the original disk with the snapshot copy")
        func restoreReplacesDisk() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Save the original state.
            try SnapshotManager.save(bundle: bundle, label: "original")

            // Modify disk.img.
            try Data("modified-disk-data".utf8).write(
                to: bundle.url.appendingPathComponent("disk.img")
            )

            // Verify it changed.
            let modifiedData = try Data(contentsOf:
                bundle.url.appendingPathComponent("disk.img")
            )
            #expect(String(data: modifiedData, encoding: .utf8) == "modified-disk-data")

            // Restore.
            try SnapshotManager.restore(bundle: bundle, label: "original")

            // Verify restored to original.
            let restoredData = try Data(contentsOf:
                bundle.url.appendingPathComponent("disk.img")
            )
            #expect(String(data: restoredData, encoding: .utf8) == "fake-disk-image-data")
        }

        @Test("Replaces auxiliary.bin with the snapshot copy")
        func restoreReplacesAuxiliary() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "snap")

            // Modify auxiliary.bin.
            try Data("modified-aux".utf8).write(
                to: bundle.url.appendingPathComponent("auxiliary.bin")
            )

            try SnapshotManager.restore(bundle: bundle, label: "snap")

            let restoredData = try Data(contentsOf:
                bundle.url.appendingPathComponent("auxiliary.bin")
            )
            #expect(String(data: restoredData, encoding: .utf8) == "fake-auxiliary-data")
        }

        @Test("Restores machine-identifier.bin from the snapshot")
        func restoresMachineIdentifier() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "snap")

            // Modify machine-identifier.bin.
            try Data("modified-machine-id".utf8).write(
                to: bundle.url.appendingPathComponent("machine-identifier.bin")
            )

            try SnapshotManager.restore(bundle: bundle, label: "snap")

            let restoredData = try Data(contentsOf:
                bundle.url.appendingPathComponent("machine-identifier.bin")
            )
            #expect(String(data: restoredData, encoding: .utf8) == "fake-machine-id")
        }

        @Test("Restore does not leave .restoring temp files behind")
        func restoreCleansTempFiles() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "snap")
            try SnapshotManager.restore(bundle: bundle, label: "snap")

            // Verify no .restoring files remain.
            let bundleContents = try FileManager.default.contentsOfDirectory(
                at: bundle.url, includingPropertiesForKeys: nil
            )
            let restoringFiles = bundleContents.filter {
                $0.lastPathComponent.hasSuffix(".restoring")
            }
            #expect(restoringFiles.isEmpty, "No .restoring temp files should remain after restore")
        }

        @Test("Fails on nonexistent snapshot label")
        func restoreFailsOnNonexistent() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            #expect {
                try SnapshotManager.restore(bundle: bundle, label: "nonexistent")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .notFound(label: "nonexistent")
            }
        }
    }

    // MARK: - List

    @Suite("list")
    struct ListTests {

        private func makeTempBundle() throws -> (VirtualMachineBundle, URL) {
            let tests = SnapshotManagerTests()
            return try tests.makeTempBundle()
        }

        @Test("Returns empty array when no snapshots exist")
        func listEmpty() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let snapshots = try SnapshotManager.list(bundle: bundle)
            #expect(snapshots.isEmpty)
        }

        @Test("Returns correct snapshot info for saved snapshots")
        func listReturnsCorrectInfo() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "alpha")
            try SnapshotManager.save(bundle: bundle, label: "beta")

            let snapshots = try SnapshotManager.list(bundle: bundle)
            #expect(snapshots.count == 2)
            #expect(snapshots[0].label == "alpha")
            #expect(snapshots[1].label == "beta")
            #expect(snapshots[0].sizeInBytes > 0)
            #expect(snapshots[1].sizeInBytes > 0)
        }

        @Test("List is sorted alphabetically by label")
        func listIsSorted() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "zebra")
            try SnapshotManager.save(bundle: bundle, label: "alpha")
            try SnapshotManager.save(bundle: bundle, label: "middle")

            let snapshots = try SnapshotManager.list(bundle: bundle)
            let labels = snapshots.map(\.label)
            #expect(labels == ["alpha", "middle", "zebra"])
        }
    }

    // MARK: - Delete

    @Suite("delete")
    struct DeleteTests {

        private func makeTempBundle() throws -> (VirtualMachineBundle, URL) {
            let tests = SnapshotManagerTests()
            return try tests.makeTempBundle()
        }

        @Test("Delete removes the snapshot directory")
        func deleteRemovesDirectory() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "to-delete")

            let snapshotDir = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("to-delete")
            #expect(FileManager.default.fileExists(atPath: snapshotDir.path))

            try SnapshotManager.delete(bundle: bundle, label: "to-delete")
            #expect(!FileManager.default.fileExists(atPath: snapshotDir.path))
        }

        @Test("Delete fails on nonexistent label")
        func deleteFailsOnNonexistent() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            #expect {
                try SnapshotManager.delete(bundle: bundle, label: "ghost")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .notFound(label: "ghost")
            }
        }

        @Test("Delete then list no longer includes the deleted snapshot")
        func deleteRemovesFromList() throws {
            let (bundle, tempDir) = try makeTempBundle()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try SnapshotManager.save(bundle: bundle, label: "keep")
            try SnapshotManager.save(bundle: bundle, label: "remove")

            try SnapshotManager.delete(bundle: bundle, label: "remove")

            let snapshots = try SnapshotManager.list(bundle: bundle)
            #expect(snapshots.count == 1)
            #expect(snapshots[0].label == "keep")
        }
    }

    // MARK: - SnapshotInfo

    @Suite("SnapshotInfo")
    struct SnapshotInfoTests {

        @Test("Round-trips through JSON")
        func jsonRoundTrip() throws {
            let info = SnapshotInfo(
                label: "test",
                createdAt: Date(),
                sizeInBytes: 1_234_567
            )

            let data = try VirtualMachineBundle.encoder.encode(info)
            let decoded = try VirtualMachineBundle.decoder.decode(SnapshotInfo.self, from: data)

            #expect(decoded.label == info.label)
            #expect(decoded.sizeInBytes == info.sizeInBytes)
            // ISO 8601 truncates to seconds.
            #expect(
                abs(decoded.createdAt.timeIntervalSince(info.createdAt)) < 1.0,
                "createdAt must survive round-trip"
            )
        }
    }
}
