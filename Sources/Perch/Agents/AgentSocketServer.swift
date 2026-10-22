import Darwin
import Foundation

enum AgentSocketError: Error {
    case alreadyRunning
    case pathTooLong
    case system(String, Int32)
}

/// Listens on a Unix socket for messages from `perch-hook`: one JSON line per connection.
///
/// The socket lives in `~/.perch` (0700) and is itself 0600, so only this user's processes can
/// reach it. A connection stays open until Perch replies, which lets a permission request wait
/// for the decision made in the notch.
final class AgentSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data, AgentReply) -> Void

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.berkkanbutun.perch.agent-socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        // Another Perch (say, a second build) already serves this socket: leave it alone.
        if Self.canConnect(to: path) { throw AgentSocketError.alreadyRunning }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("socket", errno) }

        guard var address = Self.address(for: path) else {
            close(fd)
            throw AgentSocketError.pathTooLong
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw AgentSocketError.system("bind", error)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw AgentSocketError.system("listen", error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }

            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let reply = AgentReply(fd: client)
            if let line = Self.readLine(from: client) {
                handler(line, reply)
            } else {
                reply.send(nil)
            }
        }
    }

    /// Reads up to the first newline (or the end), capped at 4 MB.
    private static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(buffer, count: newline)
                return data
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        return address
    }

    private static func canConnect(to path: String) -> Bool {
        guard var address = address(for: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

/// The open connection back to a waiting `perch-hook`. Replying (or dropping the reply) closes it;
/// an empty reply means "no decision", which leaves the agent to ask in the terminal.
final class AgentReply: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        send(nil)
    }

    func send(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if var data {
            data.append(0x0A)
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
        close(fd)
    }
}
