import AppKit
import Foundation
import UserNotifications

/// Runs the whole save: cut the clip, then send it where it needs to go.
@MainActor
final class ClipCoordinator {
    static let shared = ClipCoordinator()

    private var isSaving = false

    /// Posted as a clip moves through its stages so the menu bar can show progress.
    static let statusChanged = Notification.Name("ClipFarmClipStatusChanged")

    enum Status: Equatable {
        case idle
        case saving(String)
        case finished(String)
        case failed(String)
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: ClipCoordinator.statusChanged, object: nil) }
    }

    private init() {}

    /// Where clips are staged before being copied or uploaded.
    private var stagingDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipFarm", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func saveClip() {
        guard !isSaving else {
            Log.info("A clip is already being saved")
            return
        }
        isSaving = true
        Task { await performSave() }
    }

    private func performSave() async {
        defer { isSaving = false }

        let preferences = Preferences.shared
        let chosen = Destination.allCases.filter { preferences.isEnabled($0) }
        guard !chosen.isEmpty else {
            finish(.failed("Pick somewhere to save clips in settings first."))
            return
        }
        guard CaptureEngine.shared.isRunning else {
            finish(.failed("Recording is not running. Check screen recording permission."))
            return
        }

        status = .saving("Cutting the clip")
        let duration = preferences.clipDuration
        let filename = ClipExporter.makeFilename()
        let staged = stagingDirectory.appendingPathComponent(filename)

        let clipURL: URL
        do {
            let source = preferences.audioSource
            clipURL = try await ClipExporter.export(
                duration: duration,
                videoBuffer: CaptureEngine.shared.videoBuffer,
                systemAudio: source.needsSystemAudio ? CaptureEngine.shared.audioBuffer : nil,
                inputAudio: source.needsInputDevice ? CaptureEngine.shared.inputRecorder.buffer : nil,
                to: staged
            )
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }

        var savedFolderURL: URL?
        var permalink: URL?
        var problems: [String] = []

        if chosen.contains(.folder) {
            status = .saving("Saving to your folder")
            do {
                savedFolderURL = try copyToFolder(clipURL, filename: filename)
            } catch {
                problems.append("folder: \(error.localizedDescription)")
            }
        }

        if chosen.contains(.cdn) {
            status = .saving("Uploading to HALP/CDN")
            do {
                permalink = try await CDNUploader.upload(fileURL: clipURL)
            } catch {
                problems.append("CDN: \(error.localizedDescription)")
            }
        }

        // The clipboard gets the file when clipboard is on. When it is off and the
        // upload worked, the link goes there instead so the clip is still one paste away.
        if chosen.contains(.clipboard) {
            let fileToCopy = savedFolderURL ?? clipURL
            copyFileToClipboard(fileToCopy)
        } else if let permalink {
            copyTextToClipboard(permalink.absoluteString)
        }

        // The staged file has to survive as long as the clipboard points at it. Once
        // the clipboard holds a folder copy or a link instead, it can go.
        let clipboardPointsAtStagedFile = chosen.contains(.clipboard) && savedFolderURL == nil
        if !clipboardPointsAtStagedFile {
            try? FileManager.default.removeItem(at: clipURL)
        }
        pruneStagingDirectory()

        if problems.isEmpty {
            let seconds = Int(duration.rounded())
            var message = "Saved \(seconds)s"
            if chosen.contains(.clipboard) { message += ", copied" }
            if let permalink { message += ", \(permalink.lastPathComponent) is up" }
            finish(.finished(message))
            notify(title: "Clip saved", body: summary(chosen: chosen, permalink: permalink))
        } else {
            finish(.failed(problems.joined(separator: " · ")))
            notify(title: "Clip had trouble", body: problems.joined(separator: "\n"))
        }
    }

    private func summary(chosen: [Destination], permalink: URL?) -> String {
        var lines: [String] = []
        if chosen.contains(.clipboard) { lines.append("On the clipboard") }
        if chosen.contains(.folder), let folder = Preferences.shared.saveFolder {
            lines.append("In \(folder.lastPathComponent)")
        }
        if let permalink { lines.append(permalink.absoluteString) }
        return lines.joined(separator: "\n")
    }

    private func finish(_ status: Status) {
        self.status = status
        if case .failed(let message) = status { Log.error(message) }
        // Drop back to idle so the menu stops showing the last result forever.
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.status == status { self.status = .idle }
        }
    }

    /// Clears staged clips older than a day, since a clip left on the clipboard keeps
    /// its file around and nothing else deletes them.
    private func pruneStagingDirectory() {
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func copyToFolder(_ url: URL, filename: String) throws -> URL {
        guard let folder = Preferences.shared.saveFolder else {
            throw NSError(
                domain: "dev.haelp.clipfarm",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No folder is picked in settings."]
            )
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(filename)
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (filename as NSString).deletingPathExtension
            destination = folder.appendingPathComponent("\(base)-\(attempt).mp4")
            attempt += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
