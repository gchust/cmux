import Foundation

enum RestorableAgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    private var hookStoreFilename: String {
        "\(rawValue)-hook-sessions.json"
    }

    func resumeCommand(sessionId: String) -> String {
        let quotedSessionId = Self.shellSingleQuoted(sessionId)
        switch self {
        case .claude:
            return "claude --resume \(quotedSessionId)"
        case .codex:
            return "codex resume \(quotedSessionId)"
        }
    }

    func hookStoreFileURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent(hookStoreFilename, isDirectory: false)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?

    var resumeCommand: String {
        kind.resumeCommand(sessionId: sessionId)
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    private struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private let snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        snapshotsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]

        for kind in RestorableAgentKind.allCases {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let panelId = UUID(uuidString: record.surfaceId) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd)
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = (snapshot: snapshot, updatedAt: record.updatedAt)
            }
        }

        return RestorableAgentSessionIndex(snapshotsByPanel: resolved.mapValues(\.snapshot))
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]) {
        self.snapshotsByPanel = snapshotsByPanel
    }
}
