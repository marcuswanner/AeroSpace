import Foundation

// todo refactor. showMessageInGui in common code looks weird
func showMessageInGui(filenameIfConsoleApp: String, title: String, message: String) {
    let recentEvents = readRecentFileLoggerEvents(maxLines: 50)
    let titleAndMessage = "##### \(title) #####\n\n" + message + recentEvents
    if isCli {
        print(titleAndMessage)
    } else {
        let file = persistentCrashLogUrl(filenameIfConsoleApp: filenameIfConsoleApp)
        Result {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }.getOrDie()
        Result { try (titleAndMessage + "\n").write(to: file, atomically: true, encoding: .utf8) }.getOrDie()

        // Maintain /tmp/bobko.aerospace/<filename> as a symlink to the latest
        // persistent file. Keeps the maintainer's documented path working
        // (`/tmp/bobko.aerospace/aerospace-runtime-error.txt`) while ensuring the
        // actual content survives reboots and isn't overwritten by the next crash.
        let legacyDir = URL(filePath: "/tmp/bobko.aerospace/")
        let legacyLink = legacyDir.appending(component: filenameIfConsoleApp)
        _ = try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        _ = try? FileManager.default.removeItem(at: legacyLink)
        _ = try? FileManager.default.createSymbolicLink(at: legacyLink, withDestinationURL: file)

        // Console.app renders the file but is awkward for copying text out.
        // TextEdit opens it as a plain document — fully selectable and
        // copyable, even when the parent process is being torn down.
        file.absoluteURL.open(with: URL(filePath: "/System/Applications/TextEdit.app"))
    }
}

/// Reads the tail of the current session's FileLogger output and formats it
/// for inclusion in a crash dump. Lets the recipient correlate the stack
/// trace with what the binary was doing in the seconds leading up to the
/// crash, in a single file — instead of needing to find the right
/// `aerospace.log` line by timestamp.
private func readRecentFileLoggerEvents(maxLines: Int) -> String {
    let logFile = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/AeroSpace/aerospace.log")
    guard let data = try? Data(contentsOf: logFile),
          let text = String(data: data, encoding: .utf8) else {
        return "\n\nRecent events: (no aerospace.log to read)\n"
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = lines.suffix(maxLines).joined(separator: "\n")
    return "\n\nRecent events (last \(maxLines) FileLogger lines from this session):\n\(tail)\n"
}

/// Writes crash artifacts under `~/Library/Logs/AeroSpace/crashes/` with an
/// ISO-8601 timestamp + pid, so each crash gets its own immortal file. We
/// previously wrote to `/tmp/bobko.aerospace/<filename>`, which is wiped on
/// reboot and overwritten on the next crash.
private func persistentCrashLogUrl(filenameIfConsoleApp: String) -> URL {
    let logsDir = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/AeroSpace/crashes", isDirectory: true)
    let stem = (filenameIfConsoleApp as NSString).deletingPathExtension
    let ext = (filenameIfConsoleApp as NSString).pathExtension
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let pid = ProcessInfo.processInfo.processIdentifier
    return logsDir.appending(component: "\(stem).\(stamp).pid\(pid).\(ext)")
}
