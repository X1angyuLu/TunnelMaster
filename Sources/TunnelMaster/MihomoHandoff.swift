import Darwin
import Foundation

struct AdoptedMihomoProcess {
    let pid: Int32

    private let identity: audit_token_t
    private let executablePath: String
    private let home: PrivateDirectory
    private let socketDirectory: PrivateDirectory

    private typealias SignalProcess = @convention(c) (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32

    private static let signalProcess: SignalProcess? = {
        guard let library = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "proc_signal_with_audittoken") else { return nil }
        return unsafeBitCast(symbol, to: SignalProcess.self)
    }()

    init(pid: Int32, executable: String, workingDirectory: URL, port: Int, metricsSocket: URL) throws {
        let homeName = workingDirectory.lastPathComponent
        let socketParent = metricsSocket.deletingLastPathComponent()
        let socketName = socketParent.lastPathComponent
        let temporaryRoot = socketParent.deletingLastPathComponent().path
        guard pid > 1, (1024...65535).contains(port),
              homeName.hasPrefix("mihomo-"), UUID(uuidString: String(homeName.dropFirst("mihomo-".count))) != nil,
              temporaryRoot == "/tmp" || temporaryRoot == "/private/tmp",
              socketName.range(of: "^tunnelmaster-[a-zA-Z0-9]{6}$", options: .regularExpression) != nil,
              metricsSocket.lastPathComponent == "metrics.sock",
              let home = PrivateDirectory(workingDirectory),
              let socketDirectory = PrivateDirectory(socketParent),
              let token = Self.socketPeer(at: metricsSocket, expecting: pid),
              let processImage = Self.executable(for: token),
              processImage == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
              // Older macOS versions may lack a signal API that is safe against PID reuse. Leave the old app in charge.
              Self.signalProcess != nil else {
            throw SessionError.handoffFailed
        }

        let args = "-d \(workingDirectory.path) -f \(workingDirectory.appendingPathComponent("config.json").path)"
        let command = try MacCommand.capture("/bin/ps", arguments: ["-ww", "-p", String(pid), "-o", "command="])
        let processCommand = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.status == 0,
              processCommand == "\(executable) \(args)" || processCommand == "\(processImage) \(args)" else {
            throw SessionError.handoffFailed
        }
        let listener = try MacCommand.capture("/usr/sbin/lsof", arguments: [
            "-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn",
        ])
        guard listener.status == 0, listener.output.split(separator: "\n").contains("n127.0.0.1:\(port)"),
              Self.executable(for: token) == processImage else {
            throw SessionError.handoffFailed
        }
        self.pid = pid
        self.identity = token
        self.executablePath = processImage
        self.home = home
        self.socketDirectory = socketDirectory
    }

    var isRunning: Bool {
        Self.executable(for: identity) == executablePath
    }

    var mayRemoveDirectories: Bool {
        home.isUnchanged && socketDirectory.isUnchanged
    }

    func ownsMetricsSocket(_ url: URL) -> Bool {
        guard socketDirectory.isUnchanged, let live = Self.socketPeer(at: url, expecting: pid) else { return false }
        return withUnsafeBytes(of: live) { observed in
            withUnsafeBytes(of: identity) { adopted in observed.elementsEqual(adopted) }
        }
    }

    func terminateAndWait() -> Bool {
        guard isRunning else { return true }
        guard let signal = Self.signalProcess else { return false }
        var token = identity
        // Darwin validates the audit token's process generation when signaling, even if this PID was recycled.
        let result = signal(&token, SIGTERM)
        guard result == 0 || result == ESRCH else { return false }
        for _ in 0..<40 {
            if !isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }

    private static func executable(for identity: audit_token_t) -> String? {
        var token = identity
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath_audittoken(&token, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    private static func socketPeer(at url: URL, expecting pid: Int32) -> audit_token_t? {
        var socketFile = stat()
        guard lstat(url.path, &socketFile) == 0, socketFile.st_mode & S_IFMT == S_IFSOCK,
              socketFile.st_uid == geteuid() else { return nil }
        var address = sockaddr_un()
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { Darwin.close(socket) }
        guard fcntl(socket, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var peerPID: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidSize) == 0, peerPID == pid,
              getpeereid(socket, &peerUID, &peerGID) == 0, peerUID == geteuid(),
              getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else { return nil }
        return token
    }
}

private struct PrivateDirectory {
    let url: URL
    let device: dev_t
    let inode: ino_t

    init?(_ url: URL) {
        var information = stat()
        guard url.isFileURL, lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR, information.st_mode & 0o777 == 0o700,
              information.st_uid == geteuid() else { return nil }
        self.url = url
        self.device = information.st_dev
        self.inode = information.st_ino
    }

    var isUnchanged: Bool {
        guard let current = Self(url) else { return false }
        return device == current.device && inode == current.inode
    }
}
