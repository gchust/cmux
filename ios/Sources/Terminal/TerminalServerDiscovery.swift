import Combine
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

/// Discovers cmux daemons by probing the 52100-52199 port range on localhost
/// (simulator) or the embedded relay host (device). This is the same probe
/// `ServerScannerView` uses; the two discovery paths are deliberately unified
/// so the main sidebar and the Find Servers sheet can't disagree about which
/// hosts exist.
///
/// The embedded `debug-ws-port` file from `reload.sh` is treated as a hint
/// (probed first) but is no longer authoritative. If it's missing or stale,
/// the full port scan picks up whatever is actually running.
final class TailscaleServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    private let subject = CurrentValueSubject<[TerminalHost], Never>([])
    private var probeTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var knownHosts: [TerminalHost] = []
    private let wsSecret: String
    private let probeHostname: String
    private let hintedPorts: [Int]

    @MainActor
    convenience init() {
        let secret = Self.loadWsSecret()
        let hostname = Self.loadProbeHostname()
        let hints = Self.loadHintedPorts()

        ScannerLog.shared.log("discovery.init hostname=\(hostname) secret=\(secret.isEmpty ? "empty" : "\(secret.prefix(8))...") hints=\(hints)")

        #if DEBUG
        self.init(hostname: hostname, secret: secret, hintedPorts: hints, existingHosts: [])
        #else
        // Production: seed with any persisted hosts in addition to the dynamic scan.
        var persisted: [TerminalHost] = []
        do {
            let store = try TerminalCacheRepository(database: AppDatabase.live())
            persisted = store.load().hosts.filter { $0.wsPort != nil }
        } catch {
            persisted = []
        }
        self.init(hostname: hostname, secret: secret, hintedPorts: hints, existingHosts: persisted)
        #endif
    }

    init(hostname: String, secret: String, hintedPorts: [Int], existingHosts: [TerminalHost]) {
        self.hostsPublisher = subject.eraseToAnyPublisher()
        self.wsSecret = secret
        self.probeHostname = hostname
        self.hintedPorts = hintedPorts
        self.knownHosts = existingHosts

        // Kick off the first scan immediately, then repeat periodically.
        performScan()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.performScan()
        }
        timer.resume()
        self.probeTimer = timer
    }

    deinit {
        probeTimer?.cancel()
    }

    /// Used by callers (e.g. the manual Find Servers sheet) to inject a
    /// host they discovered. The next scan will probe it alongside the
    /// default port range.
    func addHost(_ host: TerminalHost) {
        stateLock.lock()
        if !knownHosts.contains(where: { $0.stableID == host.stableID }) {
            knownHosts.append(host)
        }
        stateLock.unlock()
        performScan()
    }

    // MARK: - Scan

    private func performScan() {
        let hostname = probeHostname
        let secret = wsSecret
        let hints = hintedPorts
        stateLock.lock()
        let existing = knownHosts
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Probe the full cmuxd-remote port range. Hinted ports get probed
            // too (deduped via Set) so the embedded `debug-ws-port` file still
            // works as a fast-path but isn't required.
            var ports = Set<Int>(52100...52199)
            ports.formUnion(hints)
            for host in existing {
                if let port = host.wsPort { ports.insert(port) }
            }
            ScannerLog.shared.log("discovery.scan starting host=\(hostname) ports=\(ports.count)")

            var found: [TerminalHost] = []
            let lock = NSLock()
            let group = DispatchGroup()

            for port in ports.sorted() {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    // Run the scanner's full hello probe so we get a reliable
                    // workspace_count and treat a bound-but-non-cmux TCP port
                    // as offline.
                    let result = ServerScanner.probeSync(
                        hostname: hostname,
                        port: port,
                        secret: secret
                    )
                    if let result {
                        let matched = existing.first(where: {
                            $0.hostname == hostname && $0.wsPort == port
                        })
                        var host = matched ?? TerminalHost(
                            stableID: "\(hostname)-\(port)",
                            name: hostname == "127.0.0.1" ? "Local Dev (:\(port))" : "\(hostname) (:\(port))",
                            hostname: hostname,
                            port: 22,
                            username: "cmux",
                            symbolName: "desktopcomputer",
                            palette: .sky,
                            source: .discovered,
                            transportPreference: .remoteDaemon,
                            wsPort: port,
                            wsSecret: secret
                        )
                        host.machineStatus = .online
                        host.wsPort = port
                        if host.wsSecret == nil || host.wsSecret?.isEmpty == true {
                            host.wsSecret = secret
                        }
                        lock.lock()
                        found.append(host)
                        lock.unlock()
                        ScannerLog.shared.log("discovery.scan.found \(hostname):\(port) ws=\(result.workspaceCount)")
                    }
                }
            }

            group.wait()

            // Also carry forward any existing non-localhost hosts (e.g. manually
            // added remotes) that didn't happen to match the current scan,
            // probed individually on their own saved port.
            let extras = existing.filter { host in
                guard let port = host.wsPort else { return false }
                return host.hostname != hostname
                    || !found.contains(where: { $0.hostname == hostname && $0.wsPort == port })
            }
            for host in extras {
                let port = host.wsPort ?? 0
                let ok = Self.probeReachability(hostname: host.hostname, port: port)
                var probed = host
                probed.machineStatus = ok ? .online : .offline
                lock.lock()
                found.append(probed)
                lock.unlock()
                ScannerLog.shared.log("discovery.scan.extra \(host.hostname):\(port) online=\(ok)")
            }

            ScannerLog.shared.log("discovery.scan.done online=\(found.count)")
            DispatchQueue.main.async { self?.subject.send(found) }
        }
    }

    // MARK: - Helpers

    private static func probeReachability(hostname: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, hostname, &addr.sin_addr)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        return connectResult == 0
    }

    private static func loadWsSecret() -> String {
        if let bundlePath = Bundle.main.path(forResource: "mobile-ws-secret", ofType: nil),
           let s = try? String(contentsOfFile: bundlePath, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let secretPath = "\(home)/Library/Application Support/cmux/mobile-ws-secret"
        return (try? String(contentsOfFile: secretPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private static func loadProbeHostname() -> String {
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        if let path = Bundle.main.path(forResource: "debug-relay-host", ofType: nil),
           let host = try? String(contentsOfFile: path, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return "127.0.0.1"
        #endif
    }

    private static func loadHintedPorts() -> [Int] {
        // Optional hint from reload.sh. Treated as a hint only - the full
        // port scan is authoritative so a missing or stale hint can never
        // silently break discovery.
        guard let path = Bundle.main.path(forResource: "debug-ws-port", ofType: nil),
              let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return [] }
        return [port]
    }
}
