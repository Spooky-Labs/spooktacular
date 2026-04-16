import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("SnapshotManager", .tags(.infrastructure))
struct SnapshotManagerTests {

    // MARK: - Helpers

    /// Creates a temporary VM bundle with fake disk.img, auxiliary.bin, and machine-identifier.bin.
    private func makeTempBundle(
        in tmp: TempDirectory,
        diskContent: String = "fake-disk-image-data",
        auxContent: String = "fake-auxiliary-data",
        machineIdContent: String = "fake-machine-id"
    ) throws -> VirtualMachineBundle {
        let bundleURL = tmp.url.appendingPathComponent("test.vm")
        let bundle = try VirtualMachineBundle.create(
            at: bundleURL,
            spec: VirtualMachineSpecification()
        )

        for (name, content) in [
            ("disk.img", diskContent),
            ("auxiliary.bin", auxContent),
            ("machine-identifier.bin", machineIdContent),
        ] {
            try Data(content.utf8).write(to: bundleURL.appendingPathComponent(name))
        }

        return bundle
    }

    // MARK: - Save

    @Suite("save", .tags(.infrastructure))
    struct SaveTests {

        private func setup() throws -> (bundle: VirtualMachineBundle, tmp: TempDirectory) {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)
            return (bundle, tmp)
        }

        @Test(
            "Creates the snapshot directory and copies all required files",
            .timeLimit(.minutes(1)),
            arguments: ["disk.img", "auxiliary.bin", "machine-identifier.bin", "snapshot-info.json"]
        )
        func saveCreatesFiles(filename: String) throws {
            let (bundle, _tmp) = try setup()
            try SnapshotManager.save(bundle: bundle, label: "test-snap")

            let snapshotDir = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("test-snap")

            #expect(FileManager.default.fileExists(
                atPath: snapshotDir.appendingPathComponent(filename).path
            ))
        }

        @Test("Copied disk.img matches the original", .timeLimit(.minutes(1)))
        func saveCopiesDiskContent() throws {
            let (bundle, _tmp) = try setup()
            try SnapshotManager.save(bundle: bundle, label: "content-check")

            let originalData = try Data(contentsOf: bundle.url.appendingPathComponent("disk.img"))
            let snapshotData = try Data(contentsOf: bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("content-check")
                .appendingPathComponent("disk.img"))
            #expect(originalData == snapshotData)
        }

        @Test("Snapshot info JSON contains correct label and nonzero size", .timeLimit(.minutes(1)))
        func saveWritesInfoWithLabel() throws {
            let (bundle, _tmp) = try setup()
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

        @Test("Fails when a snapshot with the same label already exists", .timeLimit(.minutes(1)))
        func saveFailsOnDuplicate() throws {
            let (bundle, _tmp) = try setup()
            try SnapshotManager.save(bundle: bundle, label: "dup")

            #expect {
                try SnapshotManager.save(bundle: bundle, label: "dup")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .alreadyExists(label: "dup")
            }
        }

        @Test("Fails when disk.img is missing from the bundle", .timeLimit(.minutes(1)))
        func saveFailsWithoutDisk() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.url.appendingPathComponent("nodisk.vm")
            let bundle = try VirtualMachineBundle.create(
                at: bundleURL,
                spec: VirtualMachineSpecification()
            )

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

    @Suite("restore", .tags(.infrastructure))
    struct RestoreTests {

        private func setup() throws -> (bundle: VirtualMachineBundle, tmp: TempDirectory) {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)
            return (bundle, tmp)
        }

        @Test(
            "Restores modified files to original content",
            .timeLimit(.minutes(1)),
            arguments: [
                ("disk.img", "fake-disk-image-data", "modified-disk-data"),
                ("auxiliary.bin", "fake-auxiliary-data", "modified-aux"),
                ("machine-identifier.bin", "fake-machine-id", "modified-machine-id"),
            ]
        )
        func restoreFile(filename: String, originalContent: String, modifiedContent: String) throws {
            let (bundle, _tmp) = try setup()
            try SnapshotManager.save(bundle: bundle, label: "original")

            // Modify the file.
            try Data(modifiedContent.utf8).write(
                to: bundle.url.appendingPathComponent(filename)
            )

            // Verify it changed.
            let modifiedData = try Data(contentsOf: bundle.url.appendingPathComponent(filename))
            try #require(
                String(data: modifiedData, encoding: .utf8) == modifiedContent,
                "File must be modified before restore"
            )

            // Restore and verify original content.
            try SnapshotManager.restore(bundle: bundle, label: "original")
            let restoredData = try Data(contentsOf: bundle.url.appendingPathComponent(filename))
            #expect(String(data: restoredData, encoding: .utf8) == originalContent)
        }

        @Test("Restore does not leave .restoring temp files behind", .timeLimit(.minutes(1)))
        func restoreCleansTempFiles() throws {
            let (bundle, _tmp) = try setup()
            try SnapshotManager.save(bundle: bundle, label: "snap")
            try SnapshotManager.restore(bundle: bundle, label: "snap")

            let bundleContents = try FileManager.default.contentsOfDirectory(
                at: bundle.url, includingPropertiesForKeys: nil
            )
            let restoringFiles = bundleContents.filter {
                $0.lastPathComponent.hasSuffix(".restoring")
            }
            #expect(restoringFiles.isEmpty, "No .restoring temp files should remain after restore")
        }

        @Test("Fails on nonexistent snapshot label", .timeLimit(.minutes(1)))
        func restoreFailsOnNonexistent() throws {
            let (bundle, _tmp) = try setup()

            #expect {
                try SnapshotManager.restore(bundle: bundle, label: "nonexistent")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .notFound(label: "nonexistent")
            }
        }
    }

    // MARK: - List

    @Suite("list", .tags(.infrastructure))
    struct ListTests {

        @Test("Returns empty array when no snapshots exist", .timeLimit(.minutes(1)))
        func listEmpty() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)
            let snapshots = try SnapshotManager.list(bundle: bundle)
            #expect(snapshots.isEmpty)
        }

        @Test("Returns snapshot info with correct labels and nonzero sizes", .timeLimit(.minutes(1)))
        func listReturnsCorrectInfo() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)

            try SnapshotManager.save(bundle: bundle, label: "alpha")
            try SnapshotManager.save(bundle: bundle, label: "beta")

            let snapshots = try SnapshotManager.list(bundle: bundle)
            let labels = snapshots.map(\.label)
            #expect(labels == ["alpha", "beta"])
            for snapshot in snapshots {
                #expect(snapshot.sizeInBytes > 0)
            }
        }

        @Test("List is sorted alphabetically by label", .timeLimit(.minutes(1)))
        func listIsSorted() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)

            try SnapshotManager.save(bundle: bundle, label: "zebra")
            try SnapshotManager.save(bundle: bundle, label: "alpha")
            try SnapshotManager.save(bundle: bundle, label: "middle")

            let labels = try SnapshotManager.list(bundle: bundle).map(\.label)
            #expect(labels == ["alpha", "middle", "zebra"])
        }
    }

    // MARK: - Delete

    @Suite("delete", .tags(.infrastructure))
    struct DeleteTests {

        @Test("Delete removes the snapshot directory", .timeLimit(.minutes(1)))
        func deleteRemovesDirectory() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)
            try SnapshotManager.save(bundle: bundle, label: "to-delete")

            let snapshotDir = bundle.url
                .appendingPathComponent("SavedStates")
                .appendingPathComponent("to-delete")
            try #require(
                FileManager.default.fileExists(atPath: snapshotDir.path),
                "Snapshot must exist before delete"
            )

            try SnapshotManager.delete(bundle: bundle, label: "to-delete")
            #expect(!FileManager.default.fileExists(atPath: snapshotDir.path))
        }

        @Test("Delete fails on nonexistent label", .timeLimit(.minutes(1)))
        func deleteFailsOnNonexistent() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)

            #expect {
                try SnapshotManager.delete(bundle: bundle, label: "ghost")
            } throws: { error in
                guard let snapError = error as? SnapshotError else { return false }
                return snapError == .notFound(label: "ghost")
            }
        }

        @Test("Delete then list no longer includes the deleted snapshot", .timeLimit(.minutes(1)))
        func deleteRemovesFromList() throws {
            let tmp = TempDirectory()
            let bundle = try SnapshotManagerTests().makeTempBundle(in: tmp)
            try SnapshotManager.save(bundle: bundle, label: "keep")
            try SnapshotManager.save(bundle: bundle, label: "remove")

            try SnapshotManager.delete(bundle: bundle, label: "remove")

            let snapshots = try SnapshotManager.list(bundle: bundle)
            let labels = snapshots.map(\.label)
            #expect(labels == ["keep"])
        }
    }

    // MARK: - SnapshotInfo

    @Suite("SnapshotInfo", .tags(.infrastructure))
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
            #expect(
                abs(decoded.createdAt.timeIntervalSince(info.createdAt)) < 1.0,
                "createdAt must survive round-trip"
            )
        }
    }
}
