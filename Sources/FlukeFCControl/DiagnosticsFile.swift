import AppKit
import Foundation

/// Mirrors the diagnostics log to a file, because the in-app log keeps only the last 500 lines and live
/// readings arrive several times a second, so anything older than a couple of minutes scrolls away.
/// `~/Library/Logs/Fluke FC Control/diagnostics.log` holds the current run; the previous run is kept as
/// `diagnostics.previous.log`. It contains what the Diagnostics window shows (including the meter's
/// serial number) and never leaves the Mac.
@MainActor
enum DiagnosticsFile {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fluke FC Control", isDirectory: true)
    static let url = directory.appendingPathComponent("diagnostics.log")

    private static var handle: FileHandle?
    private static var failed = false

    static func append(_ line: String) {
        guard !failed else { return }
        if handle == nil { open() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }

    private static func open() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = directory.appendingPathComponent("diagnostics.previous.log")
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: previous)
                try fm.moveItem(at: url, to: previous)
            }
            fm.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            let date = Date().formatted(.iso8601)
            try handle?.write(contentsOf: Data("# Fluke FC Control diagnostics, started \(date)\n".utf8))
        } catch {
            failed = true
        }
    }

    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
