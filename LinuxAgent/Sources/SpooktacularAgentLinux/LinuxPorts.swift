import Foundation

/// Lists listening TCP ports on the Linux guest by parsing
/// `/proc/net/tcp` + `/proc/net/tcp6`.
///
/// Matches the shape of `GuestPortInfo` on the host: `port`,
/// `pid`, `processName`. PID resolution walks `/proc/<pid>/fd/*`
/// looking for the matching socket inode — the standard Linux
/// pattern that `ss` uses.
///
/// This is best-effort. If the agent runs unprivileged it can
/// only see its own PIDs; when run via systemd as root it sees
/// everything.
enum LinuxPortScanner {

    struct PortEntry: Encodable {
        let port: UInt16
        let pid: Int32
        let processName: String
    }

    /// TCP socket state code for LISTEN, per
    /// https://www.kernel.org/doc/Documentation/networking/proc_net_tcp.txt
    private static let listenState = "0A"

    static func scan() -> [PortEntry] {
        var bySocket: [UInt64: UInt16] = [:]
        for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
            bySocket.merge(parseListeners(path: path)) { a, _ in a }
        }
        guard !bySocket.isEmpty else { return [] }

        let socketToPid = resolvePIDs(inodes: Set(bySocket.keys))
        var entries: [PortEntry] = []
        for (inode, port) in bySocket {
            let pid = socketToPid[inode] ?? 0
            let name = pid > 0 ? processName(pid: pid) : ""
            entries.append(PortEntry(port: port, pid: pid, processName: name))
        }
        return entries.sorted { $0.port < $1.port }
    }

    /// Parses lines like:
    ///   sl local_address rem_address st ... inode
    ///   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 ... 27883
    private static func parseListeners(path: String) -> [UInt64: UInt16] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var out: [UInt64: UInt16] = [:]
        var iter = text.split(separator: "\n").makeIterator()
        _ = iter.next() // header
        while let line = iter.next() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 10 else { continue }
            // fields[1] = "LOCAL_IP:PORT_HEX"
            // fields[3] = state
            // fields[9] = inode
            guard fields[3] == listenState else { continue }
            let localAddr = fields[1]
            guard let colonIdx = localAddr.firstIndex(of: ":") else { continue }
            let portHex = localAddr[localAddr.index(after: colonIdx)...]
            guard let port = UInt16(portHex, radix: 16) else { continue }
            guard let inode = UInt64(fields[9]) else { continue }
            out[inode] = port
        }
        return out
    }

    private static func resolvePIDs(inodes: Set<UInt64>) -> [UInt64: Int32] {
        guard let pids = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return [:]
        }
        var result: [UInt64: Int32] = [:]
        for entry in pids {
            guard let pid = Int32(entry) else { continue }
            let fdDir = "/proc/\(pid)/fd"
            guard let fds = try? FileManager.default.contentsOfDirectory(atPath: fdDir) else {
                continue
            }
            for fd in fds {
                let linkPath = "\(fdDir)/\(fd)"
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
                    continue
                }
                // Targets look like "socket:[27883]"
                guard target.hasPrefix("socket:[") else { continue }
                let inodeText = target.dropFirst("socket:[".count).dropLast()
                guard let inode = UInt64(inodeText), inodes.contains(inode) else { continue }
                result[inode] = pid
            }
        }
        return result
    }

    private static func processName(pid: Int32) -> String {
        // /proc/<pid>/comm is the process's 15-byte command name
        // (TASK_COMM_LEN). It's what `ps` reads and what matches
        // what the host's port panel expects.
        let path = "/proc/\(pid)/comm"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
