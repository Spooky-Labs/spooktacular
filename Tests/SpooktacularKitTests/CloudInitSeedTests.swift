import Testing
import Foundation
import SpooktacularCore
@testable import SpooktacularApplication

@Suite("CloudInitSeed")
struct CloudInitSeedTests {

    private func makeSeed(script: String? = nil) throws -> CloudInitSeed {
        let id = try #require(UUID(uuidString: "D5C8A6DA-DD80-49D4-9FE2-855ADA4AFA1F"))
        return try CloudInitSeed(
            spec: GuestProvisioningSpec(
                fullName: "Admin", username: "admin", password: "hunter2hunter2"
            ),
            instanceID: id,
            hostname: "dev-box",
            runScript: script,
            authorizedKeys: ["ssh-ed25519 AAAA test@host"]
        )
    }

    @Test("user-data carries the account with a $6$ hash, never plaintext")
    func hashNotPlaintext() throws {
        let ud = try makeSeed().userData
        #expect(ud.hasPrefix("#cloud-config"))
        #expect(ud.contains("name: admin"))
        #expect(ud.contains("passwd: $6$"))
        #expect(!ud.contains("hunter2hunter2"))
        #expect(ud.contains("ssh_pwauth: true"))
        #expect(ud.contains("expire: false"))
        #expect(ud.contains("ssh-ed25519 AAAA test@host"))
    }

    @Test("run script rides runcmd via a written file")
    func runcmd() throws {
        let ud = try makeSeed(script: "#!/bin/bash\necho hi\n").userData
        #expect(ud.contains("write_files:"))
        #expect(ud.contains("path: /var/lib/spooktacular/first-boot.sh"))
        #expect(ud.contains("runcmd:"))
        #expect(ud.contains("[bash, /var/lib/spooktacular/first-boot.sh]"))
        // Script content is base64 — raw bytes must not leak into YAML.
        #expect(!ud.contains("echo hi"))
    }

    @Test("meta-data carries instance id + hostname")
    func metaData() throws {
        let md = try makeSeed().metaData
        #expect(md.contains("instance-id: iid-D5C8A6DA-DD80-49D4-9FE2-855ADA4AFA1F"))
        #expect(md.contains("local-hostname: dev-box"))
    }

    @Test("writeISO produces a cidata ISO9660 image")
    func isoBuild() throws {
        let iso = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: iso) }
        try makeSeed().writeISO(to: iso)
        let data = try Data(contentsOf: iso)
        #expect(data.count > 2048)
        // ISO9660 primary volume descriptor magic: "CD001" at 0x8001.
        try #require(data.count > 0x8006)
        #expect(Array(data[0x8001...0x8005]) == Array("CD001".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("cidata") || text.contains("CIDATA"))
    }
}
