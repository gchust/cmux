import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private let launchTag = "ui-tests-automation-socket"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-diagnostics-\(UUID().uuidString).json"
        resetSocketDefaults()
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist. diagnostics=\(loadDiagnostics() ?? [:])")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testSurfaceListStillRespondsAfterRepeatedSendKey() {
        let app = configuredApp(mode: "automation")
        app.launch()
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for repeated send-key socket test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail(
                "Expected control socket to exist for repeated send-key socket test. " +
                "diagnostics=\(loadDiagnostics() ?? [:])"
            )
            return
        }
        socketPath = resolvedPath

        guard let target = ensureTerminalSurface(timeout: 10.0) else {
            XCTFail(
                "Expected a terminal surface before repeated send-key socket test. " +
                "socket=\(socketPath) diagnostics=\(loadDiagnostics() ?? [:])"
            )
            return
        }

        for iteration in 1...8 {
            XCTAssertEqual(
                socketCommand("ping", responseTimeout: 1.5),
                "PONG",
                "Expected ping before send_key on iteration \(iteration)"
            )

            XCTAssertNotNil(
                socketV2(
                    method: "surface.send_key",
                    params: [
                        "window_id": target.windowId,
                        "workspace_id": target.workspaceId,
                        "surface_id": target.surfaceId,
                        "key": "enter",
                    ],
                    responseTimeout: 4.0
                ),
                "Expected surface.send_key to succeed on iteration \(iteration)"
            )

            XCTAssertEqual(
                socketCommand("ping", responseTimeout: 1.5),
                "PONG",
                "Expected ping after send_key on iteration \(iteration)"
            )

            guard let payload = socketV2(
                method: "surface.list",
                params: [
                    "window_id": target.windowId,
                    "workspace_id": target.workspaceId,
                ],
                responseTimeout: 4.0
            ),
                  let surfaces = payload["surfaces"] as? [[String: Any]] else {
                XCTFail("Expected surface.list to respond after send_key on iteration \(iteration)")
                return
            }

            XCTAssertFalse(
                surfaces.isEmpty,
                "Expected surface.list to keep returning surfaces after send_key on iteration \(iteration)"
            )
        }
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                predicate()
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: self.socketPath) == exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        guard waitForSocket(exists: true, timeout: timeout) else {
            return nil
        }
        return socketPath
    }

    private func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd, responseTimeout: responseTimeout)
    }

    private func socketV2(
        method: String,
        params: [String: Any] = [:],
        responseTimeout: TimeInterval = 2.0
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let requestData = try? JSONSerialization.data(withJSONObject: request, options: []),
              let requestLine = String(data: requestData, encoding: .utf8),
              let raw = socketCommand(requestLine, responseTimeout: responseTimeout),
              !raw.hasPrefix("ERROR:"),
              let responseData = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              (response["ok"] as? Bool) == true else {
            return nil
        }
        return (response["result"] as? [String: Any]) ?? [:]
    }

    private func ensureTerminalSurface(timeout: TimeInterval) -> (windowId: String, workspaceId: String, surfaceId: String)? {
        let initialWindowId = currentWindowId()
        if let target = terminalSurface(windowId: initialWindowId) {
            return (
                windowId: initialWindowId ?? "",
                workspaceId: target.workspaceId,
                surfaceId: target.surfaceId
            )
        }

        var workspaceCreateParams: [String: Any] = [:]
        if let initialWindowId, !initialWindowId.isEmpty {
            workspaceCreateParams["window_id"] = initialWindowId
        }

        guard let workspacePayload = socketV2(
            method: "workspace.create",
            params: workspaceCreateParams,
            responseTimeout: 4.0
        ),
              let workspaceId = workspacePayload["workspace_id"] as? String else {
            return nil
        }
        let windowId = (workspacePayload["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var workspaceSelectParams: [String: Any] = [
            "workspace_id": workspaceId,
        ]
        if let windowId, !windowId.isEmpty {
            workspaceSelectParams["window_id"] = windowId
        }
        _ = socketV2(method: "workspace.select", params: workspaceSelectParams, responseTimeout: 4.0)

        let ready = waitForCondition(timeout: timeout) {
            self.terminalSurface(windowId: windowId, workspaceId: workspaceId) != nil
        }
        guard ready else { return nil }
        guard let target = terminalSurface(windowId: windowId, workspaceId: workspaceId) else {
            return nil
        }
        return (
            windowId: windowId ?? initialWindowId ?? "",
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId
        )
    }

    private func currentWindowId() -> String? {
        guard let payload = socketV2(method: "window.current", responseTimeout: 3.0),
              let windowId = payload["window_id"] as? String,
              !windowId.isEmpty else {
            return nil
        }
        return windowId
    }

    private func terminalSurface(
        windowId: String? = nil,
        workspaceId: String? = nil
    ) -> (workspaceId: String, surfaceId: String)? {
        var params: [String: Any] = [:]
        if let windowId, !windowId.isEmpty {
            params["window_id"] = windowId
        }
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        guard let payload = socketV2(method: "surface.list", params: params, responseTimeout: 3.0),
              let resolvedWorkspaceId = payload["workspace_id"] as? String,
              let surfaces = payload["surfaces"] as? [[String: Any]],
              let surface = surfaces.first(where: { surface in
                  guard let surfaceId = surface["id"] as? String, !surfaceId.isEmpty else {
                      return false
                  }
                  let type = surface["type"] as? String
                  return type == nil || type == "terminal"
              }),
              let surfaceId = surface["id"] as? String else {
            return nil
        }
        return (workspaceId: resolvedWorkspaceId, surfaceId: surfaceId)
    }

    private func socketCommandViaNetcat(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script =
            "printf '%s\\n' \(shellSingleQuote(cmd)) | " +
            "\(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval = 2.0) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
