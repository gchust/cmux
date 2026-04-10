import Foundation

/// Bridges a macOS Ghostty surface (Manual I/O mode) to a daemon terminal session.
/// Handles terminal.open, terminal.read loop, terminal.write, session.resize, and session.detach
/// via Unix socket JSON-RPC to cmuxd-remote.
final class DaemonTerminalBridge: @unchecked Sendable {
    private let socketPath: String
    let sessionID: String
    private let shellCommand: String

    private var socketFD: Int32 = -1
    private var attachmentID: String?
    private var readOffset: UInt64 = 0
    private var readThread: Thread?
    private var running = false
    private let lock = NSLock()
    private var rpcID: Int = 0

    /// Called on the read thread when terminal output arrives from the daemon.
    /// The receiver should call ghostty_surface_process_output().
    var onOutput: ((_ data: Data) -> Void)?

    /// Called when the session ends (EOF or error).
    var onDisconnect: ((_ error: String?) -> Void)?

    init(socketPath: String, sessionID: String, shellCommand: String) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.shellCommand = shellCommand
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Opens or attaches to the daemon session, then starts the read loop.
    func start(cols: Int, rows: Int) {
        guard !running else { return }
        running = true

        let thread = Thread { [weak self] in
            self?.sessionLoop(cols: cols, rows: rows)
        }
        thread.name = "DaemonTerminalBridge.\(sessionID)"
        thread.qualityOfService = .userInteractive
        thread.start()
        readThread = thread
    }

    func stop() {
        running = false
        lock.lock()
        if socketFD >= 0 {
            // Send detach before closing
            if let attachmentID {
                let params: [String: Any] = ["session_id": sessionID, "attachment_id": attachmentID]
                sendRPCNoResponse(method: "session.detach", params: params)
            }
            Darwin.close(socketFD)
            socketFD = -1
        }
        lock.unlock()
    }

    // MARK: - Write (user input → daemon)

    func writeToSession(_ data: Data) {
        let base64 = data.base64EncodedString()
        let params: [String: Any] = ["session_id": sessionID, "data": base64]
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.sendRPCNoResponse(method: "terminal.write", params: params)
        }
    }

    // MARK: - Resize

    func resize(cols: Int, rows: Int) {
        guard let attachmentID else { return }
        let params: [String: Any] = [
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sendRPCNoResponse(method: "session.resize", params: params)
        }
    }

    // MARK: - Session loop (runs on dedicated thread)

    private func sessionLoop(cols: Int, rows: Int) {
        while running {
            guard connectSocket() else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            // Try to attach to existing session first
            let attached = attachToSession(cols: cols, rows: rows)
            if !attached {
                // Create new session
                let opened = openSession(cols: cols, rows: rows)
                if !opened {
                    NSLog("📱 DaemonBridge[%@]: failed to open/attach, retrying in 1s", sessionID)
                    disconnectSocket()
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
            }

            NSLog("📱 DaemonBridge[%@]: connected, attachment=%@, starting read loop", sessionID, attachmentID ?? "nil")

            // Read loop
            readLoop()

            disconnectSocket()
            if running {
                NSLog("📱 DaemonBridge[%@]: disconnected, reconnecting in 1s", sessionID)
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func readLoop() {
        while running {
            let params: [String: Any] = [
                "session_id": sessionID,
                "offset": readOffset,
                "max_bytes": 65536,
                "timeout_ms": 250,
            ]

            guard let response = sendRPC(method: "terminal.read", params: params) else {
                break // Connection lost
            }

            guard let ok = response["ok"] as? Bool, ok,
                  let result = response["result"] as? [String: Any] else {
                // Check for timeout (not an error, just no data)
                if let error = response["error"] as? [String: Any],
                   let code = error["code"] as? String,
                   code == "deadline_exceeded" {
                    continue
                }
                break
            }

            // Update offset
            if let newOffset = result["offset"] as? UInt64 {
                readOffset = newOffset
            } else if let newOffset = result["offset"] as? Int {
                readOffset = UInt64(newOffset)
            }

            // Deliver output data
            if let base64 = result["data"] as? String,
               let data = Data(base64Encoded: base64),
               !data.isEmpty {
                onOutput?(data)
            }

            // Check EOF
            if let eof = result["eof"] as? Bool, eof {
                NSLog("📱 DaemonBridge[%@]: EOF", sessionID)
                onDisconnect?(nil)
                return
            }
        }
    }

    // MARK: - Session management

    private func attachToSession(cols: Int, rows: Int) -> Bool {
        let newAttachmentID = UUID().uuidString.lowercased()
        let params: [String: Any] = [
            "session_id": sessionID,
            "attachment_id": newAttachmentID,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]

        guard let response = sendRPC(method: "session.attach", params: params),
              let ok = response["ok"] as? Bool, ok else {
            return false
        }

        lock.lock()
        self.attachmentID = newAttachmentID
        self.readOffset = 0
        lock.unlock()
        NSLog("📱 DaemonBridge[%@]: attached as %@", sessionID, newAttachmentID)
        return true
    }

    private func openSession(cols: Int, rows: Int) -> Bool {
        let params: [String: Any] = [
            "session_id": sessionID,
            "command": shellCommand,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]

        guard let response = sendRPC(method: "terminal.open", params: params),
              let ok = response["ok"] as? Bool, ok,
              let result = response["result"] as? [String: Any],
              let attachID = result["attachment_id"] as? String else {
            return false
        }

        lock.lock()
        self.attachmentID = attachID
        self.readOffset = 0
        lock.unlock()
        NSLog("📱 DaemonBridge[%@]: opened, attachment=%@", sessionID, attachID)
        return true
    }

    // MARK: - Socket I/O

    private func connectSocket() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard socketFD < 0 else { return true }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            _ = memcpy(&addr.sun_path, cstr, min(Int(strlen(cstr)), pathSize - 1))
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        if result != 0 {
            Darwin.close(fd)
            return false
        }

        // Timeouts for send (write is async, so generous)
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        // Read timeout: short for responsiveness in read loop
        var recvTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        socketFD = fd
        return true
    }

    private func disconnectSocket() {
        lock.lock()
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        attachmentID = nil
        lock.unlock()
    }

    private func sendRPC(method: String, params: [String: Any]) -> [String: Any]? {
        lock.lock()
        guard socketFD >= 0 else { lock.unlock(); return nil }
        rpcID += 1
        let id = rpcID
        let fd = socketFD
        lock.unlock()

        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A) // newline delimiter

        let writeResult = data.withUnsafeBytes { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress, ptr.count)
        }
        guard writeResult > 0 else { return nil }

        // Read response (may span multiple read() calls)
        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 65536 + 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            accumulated.append(contentsOf: buf[0..<n])
            // Check if we have a complete line (newline-delimited JSON)
            if accumulated.contains(0x0A) { break }
        }

        // Parse up to first newline
        if let newlineIndex = accumulated.firstIndex(of: 0x0A) {
            let jsonData = accumulated[accumulated.startIndex..<newlineIndex]
            return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        }
        return try? JSONSerialization.jsonObject(with: accumulated) as? [String: Any]
    }

    private func sendRPCNoResponse(method: String, params: [String: Any]) {
        lock.lock()
        guard socketFD >= 0 else { lock.unlock(); return }
        rpcID += 1
        let id = rpcID
        let fd = socketFD
        lock.unlock()

        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)

        _ = data.withUnsafeBytes { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress, ptr.count)
        }

        // Drain response
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = Darwin.read(fd, &buf, buf.count)
    }
}
