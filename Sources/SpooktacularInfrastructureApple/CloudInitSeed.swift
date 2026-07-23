import Foundation
import SpooktacularCore

/// A cloud-init NoCloud seed: `user-data` + `meta-data`, packaged as a
/// `cidata`-labeled ISO attached read-only to a Linux guest's first boot.
///
/// This is Linux's counterpart to macOS native provisioning plus the
/// injected provisioner daemon: cloud-init (preinstalled in every cloud
/// image) creates the account, enables SSH, and runs the first-boot
/// script **as root** from `runcmd`. The password is embedded only as a
/// SHA-512-crypt hash (``SpooktacularCore/SHA512Crypt``) — the same
/// at-rest posture as `/etc/shadow`; plaintext never touches the host
/// disk, and the seed itself is scrubbed after the first successful
/// boot.
///
/// NoCloud datasource contract: an ISO9660 (or FAT) volume labeled
/// `cidata`/`CIDATA` containing `user-data` and `meta-data` at its
/// root. The ISO is built with the native `hdiutil makehybrid` — no
/// third-party dependencies.
public struct CloudInitSeed {

    /// Guest path the first-boot script is written to via `write_files`
    /// and executed from via `runcmd` (as root, cloud-init's final
    /// module stage).
    public static let guestScriptPath = "/var/lib/spooktacular/first-boot.sh"

    /// The rendered `#cloud-config` document.
    public let userData: String

    /// The rendered NoCloud `meta-data` document.
    public let metaData: String

    /// Renders the seed documents.
    ///
    /// - Parameters:
    ///   - spec: Account to create. Only the SHA-512-crypt hash of
    ///     `spec.password` enters `userData`; the plaintext is not
    ///     retained by this type.
    ///   - instanceID: The VM's stable UUID — becomes the NoCloud
    ///     `instance-id` (prefixed `iid-`), which is what makes
    ///     cloud-init treat a boot as "first boot for this instance".
    ///   - hostname: Guest hostname (`local-hostname`).
    ///   - runScript: Optional first-boot script; delivered base64 via
    ///     `write_files` and run by `runcmd` as root.
    ///   - authorizedKeys: SSH public keys for the account (typically
    ///     the host user's, for passwordless `ssh` after boot).
    /// - Throws: ``SpooktacularCore/SHA512CryptError`` if the generated
    ///   salt is rejected (practically unreachable).
    public init(
        spec: GuestProvisioningSpec,
        instanceID: UUID,
        hostname: String,
        runScript: String?,
        authorizedKeys: [String]
    ) throws {
        let hashed = try SHA512Crypt.hash(
            password: spec.password, salt: SHA512Crypt.generateSalt()
        )
        var ud = """
        #cloud-config
        users:
          - name: \(spec.username)
            gecos: \(spec.fullName)
            groups: [sudo, wheel]
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            lock_passwd: false
            passwd: \(hashed)
        """
        if !authorizedKeys.isEmpty {
            ud += "\n    ssh_authorized_keys:\n"
            ud += authorizedKeys.map { "      - \($0)" }.joined(separator: "\n")
        }
        ud += """


        ssh_pwauth: true
        chpasswd:
          expire: false
        """
        if let runScript {
            // base64 keeps arbitrary script bytes YAML-safe.
            let b64 = Data(runScript.utf8).base64EncodedString()
            ud += """


            write_files:
              - path: \(Self.guestScriptPath)
                permissions: '0700'
                encoding: b64
                content: \(b64)
            runcmd:
              - [bash, \(Self.guestScriptPath)]
            """
        }
        self.userData = ud + "\n"
        self.metaData = """
        instance-id: iid-\(instanceID.uuidString)
        local-hostname: \(hostname)

        """
    }

    /// Builds the `cidata` ISO with `hdiutil makehybrid`.
    ///
    /// Stages `user-data`/`meta-data` in a private (0700) temp
    /// directory, removed on exit; replaces any existing file at
    /// `isoURL`.
    ///
    /// - Parameter isoURL: Destination for the ISO (conventionally the
    ///   bundle's `seed.iso`).
    /// - Throws: ``ProcessRunnerError/processFailed(command:stdout:stderr:exitCode:)``
    ///   when `hdiutil` exits non-zero.
    public func writeISO(to isoURL: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory
            .appendingPathComponent("cidata-\(UUID().uuidString)")
        try fm.createDirectory(
            at: stage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: stage) }
        try Data(userData.utf8).write(to: stage.appendingPathComponent("user-data"))
        try Data(metaData.utf8).write(to: stage.appendingPathComponent("meta-data"))
        try? fm.removeItem(at: isoURL)

        try ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: [
                "makehybrid", "-iso", "-joliet",
                "-default-volume-name", "cidata",
                "-o", isoURL.path, stage.path,
            ]
        )
    }
}
