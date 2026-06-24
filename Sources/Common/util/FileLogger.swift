import Foundation

/// Always-on file logger writing to ~/Library/Logs/AeroSpace/aerospace.log.
///
/// AeroSpace has no `--verbose` / `--debug` flag today (issue #152). This is
/// the substitute: every important event lands here so when the next crash
/// or hang happens, we have the lead-up. Cheap (one line per command) and
/// rotates at 10 MiB so disk usage stays bounded.
///
/// .debug-level writes are gated on `FileLogger.verboseEnabled` so the
/// `--verbose` server flag in `initAppBundle.swift` can opt into the
/// chattier output without changing the binary's default cost.
///
/// Forensic-durability tweaks worth knowing about:
///
/// * `rotateForNewSession()` runs from `initAppBundle()` before the first
///   write, renaming `aerospace.log` to `aerospace.prev.log`. The prior
///   session's events are preserved at a predictable path that survives
///   across binary restarts, instead of getting mixed in with the new
///   session's appends.
/// * Every `write()` ends with `fsync(2)` so the kernel flushes the
///   pending bytes through the page cache before returning. Otherwise a
///   SIGKILL/SIGABRT can reap the corpse before the last few log lines
///   land on disk — exactly the situation FileLogger exists to survive.
public enum FileLogger {
    public enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warn = 2
        case error = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var tag: String {
            switch self {
                case .debug: "DEBUG"
                case .info:  "INFO "
                case .warn:  "WARN "
                case .error: "ERROR"
            }
        }
    }

    /// Toggled on by the `--verbose` server flag. Off → `.debug` lines are dropped.
    /// All reads/writes are wrapped in `unsafe { }` per the project's
    /// `.strictMemorySafety()` setting.
    public nonisolated(unsafe) static var verboseEnabled: Bool = false

    /// Cap on the active log file before it rolls over to .log.1. Keeps disk
    /// pressure predictable on long-lived sessions.
    private static let rotateBytes: Int = 10 * 1024 * 1024

    private static let queue = DispatchQueue(label: "bobko.aerospace.FileLogger", qos: .utility)

    private static let url: URL = {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AeroSpace", isDirectory: true)
        _ = try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("aerospace.log")
    }()

    private static let prevUrl: URL = url
        .deletingLastPathComponent()
        .appendingPathComponent("aerospace.prev.log")

    /// Move the previous session's log to `aerospace.prev.log` and start the
    /// new session with an empty `aerospace.log`. Call this from
    /// `initAppBundle()` *before* the first log write — that way the prior
    /// session's event trail is preserved as a stable file that
    /// `restore.py` can archive, instead of being mixed in with the new
    /// session's writes appended at the end.
    public static func rotateForNewSession() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        _ = try? fm.removeItem(at: prevUrl)
        _ = try? fm.moveItem(at: url, to: prevUrl)
    }

    /// ISO8601DateFormatter is not Sendable. We only touch it from inside the
    /// serial queue closure below, so concurrent access is impossible —
    /// `nonisolated(unsafe)` reflects that invariant.
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Append one line. Cheap fast path: closures aren't evaluated when the
    /// level is filtered out.
    public static func log(_ message: @autoclosure () -> String,
                           level: Level = .info,
                           event: String? = nil)
    {
        let isVerbose = unsafe verboseEnabled
        if level == .debug && !isVerbose { return }
        // Capture the message synchronously so the @autoclosure isn't held
        // across queue.async. Timestamp + write happen on the queue.
        let msg = message()
        let evt = event ?? "-"
        let tag = level.tag
        queue.async {
            let timestamp = unsafe iso.string(from: Date())
            write("\(timestamp) \(tag) [\(evt)] \(msg)\n")
        }
    }

    private static func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            // Force the write through the kernel page cache to disk before
            // returning. Without this, a SIGKILL/SIGABRT can reap the corpse
            // before the kernel has flushed our last few writes — and the
            // whole point of FileLogger is forensic durability after the
            // binary dies unexpectedly. ~1ms/line on SSD; well worth it.
            // (FileHandle.synchronize() is fsync under the hood, but it's a
            // safe Swift API — no `unsafe` marker that newer toolchains reject.)
            try? handle.synchronize()
        }
        rotateIfLarge()
    }

    private static func rotateIfLarge() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > rotateBytes else { return }
        let one = url.appendingPathExtension("1")
        let two = url.appendingPathExtension("2")
        _ = try? FileManager.default.removeItem(at: two)
        _ = try? FileManager.default.moveItem(at: one, to: two)
        _ = try? FileManager.default.moveItem(at: url, to: one)
    }
}
