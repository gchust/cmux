import Foundation
import Combine

/// A panel that provides a simple text editor for a file.
/// Tracks dirty state, supports save, and watches for external file changes.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current text content of the editor.
    @Published var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has unsaved changes.
    @Published private(set) var isDirty: Bool = false

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The saved content, used to detect dirty state.
    private var savedContent: String = ""

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.editor-file-watch", qos: .utility)
    /// Suppresses file-watcher reloads immediately after a save.
    private var suppressNextReload: Bool = false

    private static let maxReattachAttempts = 6
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Focus is managed by the view's NSTextView first responder.
    }

    func unfocus() {
        // No-op; NSTextView resigns naturally.
    }

    func close() {
        if isDirty {
            save()
        }
        isClosed = true
        stopFileWatcher()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Dirty tracking

    func markDirty() {
        let dirty = content != savedContent
        if isDirty != dirty {
            isDirty = dirty
            updateDisplayTitle()
        }
    }

    // MARK: - Save

    func save() {
        guard isDirty else { return }
        do {
            suppressNextReload = true
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            savedContent = content
            isDirty = false
            updateDisplayTitle()
        } catch {
            suppressNextReload = false
            #if DEBUG
            NSLog("editor.save failed path=%@ error=%@", filePath, "\(error)")
            #endif
        }
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            savedContent = newContent
            isDirty = false
            isFileUnavailable = false
        } catch {
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                savedContent = decoded
                isDirty = false
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        updateDisplayTitle()
    }

    private func updateDisplayTitle() {
        let filename = (filePath as NSString).lastPathComponent
        displayTitle = isDirty ? "\(filename) *" : filename
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    if self.suppressNextReload {
                        self.suppressNextReload = false
                        self.startFileWatcher()
                    } else {
                        self.loadFileContent()
                        if self.isFileUnavailable {
                            self.scheduleReattach(attempt: 1)
                        } else {
                            self.startFileWatcher()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if self.suppressNextReload {
                        self.suppressNextReload = false
                    } else if !self.isDirty {
                        self.loadFileContent()
                    }
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }
}
