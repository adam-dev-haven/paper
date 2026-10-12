/**
 * Log.swift — a record of what the app did, that survives the app.
 *
 * Paper's logging was one function: write a line to standard error. That is fine
 * for a binary you launched from a terminal and watched, and it is close to
 * useless for the thing this actually is — a bundled `.app` double-clicked from
 * Finder, whose standard error goes to a stream nobody has open. Every line the
 * ledger wrote about refusing to write, every stale price it fell back to, every
 * bracket it fired while the window sat behind a browser: emitted, unread, gone.
 *
 * That gap is not cosmetic for this app in particular. Paper keeps a financial
 * record, it reconstructs exits it did not witness, and it has destroyed accounts
 * once already. When something looks wrong in a ledger, the only honest way to
 * answer "what happened" is a contemporaneous record, and the only record that
 * counts is one written before anyone knew there was a question.
 *
 * So:
 *
 *   A **level**, so the interesting lines can be found among the chatty ones, and
 *     so `.error` can be counted without parsing prose.
 *   A **subsystem**, because "why is the desk showing a stale price" and "why did
 *     this position close" are different investigations through the same file.
 *   A **file**, one per day under `Application Support/Paper/logs`, kept for a
 *     fortnight. Long enough to cover a weekend the app was shut and the Monday
 *     that surfaced it; short enough that the directory is never the problem.
 *   A **ring buffer**, so the app can show its own recent history without reading
 *     back what it just wrote.
 *
 * Writes go through a serial queue and never block the caller, because a logger
 * that can stall a fill is worse than no logger. Nothing here can throw into a
 * call site: a log line failing must never be the reason an order does not.
 *
 * `log(_:)` keeps its old one-argument shape, so every existing call site still
 * compiles and lands in the file. The level and subsystem are optional, and the
 * subsystem is inferred from the `[tag]` prefix the codebase already writes when
 * one is not given — which means the convention that was already there turns into
 * structure for free.
 */

import Foundation

enum LogLevel: String, Codable, Comparable, CaseIterable {
    case debug, info, warn, error

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    /// Fixed width, so the file stays in columns when read in a terminal.
    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// One line, as the interface reads it back.
struct LogEntry: Codable, Identifiable {
    let id: Int
    let at: Double
    let level: LogLevel
    let subsystem: String
    let message: String
}

enum Log {

    /**
     * Lines below this are discarded before they are formatted.
     *
     * `PAPER_LOG_LEVEL=debug` lowers it for a run. The default is `info`: debug
     * lines are for someone actively working on a subsystem, and writing them
     * always would make the file harder to read for the case it exists to serve.
     */
    nonisolated(unsafe) private static var threshold: LogLevel = {
        let raw = ProcessInfo.processInfo.environment["PAPER_LOG_LEVEL"]?.lowercased() ?? ""
        return LogLevel(rawValue: raw) ?? .info
    }()

    /// How many days of files to keep.
    static let retainDays = 14
    /// How many lines the in-memory view holds.
    static let bufferSize = 2_000

    private static let queue = DispatchQueue(label: "paper.log")
    private static let lock = NSLock()

    nonisolated(unsafe) private static var buffer: [LogEntry] = []
    nonisolated(unsafe) private static var sequence = 0
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var openDay: String = ""
    nonisolated(unsafe) private static var counts: [LogLevel: Int] = [:]

    /// Where the files go. Beside the ledgers, so `PAPER_DATA_DIR` moves the log
    /// with the data it describes and a test run cannot scribble on the real one.
    static var directory: URL { Desk.dataDirectory.appendingPathComponent("logs", isDirectory: true) }

    /* ------------------------------------------------------------- writing */

    static func write(_ message: String, _ level: LogLevel, _ subsystem: String?) {
        guard level >= threshold else { return }

        // The codebase already prefixes its lines with `[market]`, `[ledger]`,
        // `[reconcile]` and so on. Where a subsystem is not given, that prefix is
        // the answer — and the message keeps it, because a line read in a terminal
        // should look the way it always has.
        let system = subsystem ?? inferred(from: message) ?? "app"
        let at = nowMs()

        lock.lock()
        sequence += 1
        let entry = LogEntry(id: sequence, at: at, level: level, subsystem: system, message: message)
        buffer.append(entry)
        if buffer.count > bufferSize { buffer.removeFirst(buffer.count - bufferSize) }
        counts[level, default: 0] += 1
        lock.unlock()

        // Standard error keeps working. Running from a terminal is still how this
        // gets developed, and taking that away to add a file would be a trade.
        FileHandle.standardError.write(Data((message + "\n").utf8))

        let line = "\(Log.stamp(at))  \(level.tag)  \(system.padding(toLength: 10, withPad: " ", startingAt: 0))  \(message)\n"
        queue.async { Log.append(line, on: at) }
    }

    /// `[market] …` → `market`. Nil when the line does not carry one.
    private static func inferred(from message: String) -> String? {
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else { return nil }
        let tag = message[message.index(after: message.startIndex)..<close]
        guard !tag.isEmpty, tag.count <= 16, tag.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return String(tag)
    }

    /* --------------------------------------------------------------- files */

    /// Runs on `queue`, so the handle and the open day are only ever touched here.
    private static func append(_ line: String, on at: Double) {
        let day = Log.dayKey(at)
        if day != openDay || handle == nil {
            handle?.closeFile()
            handle = nil
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("paper-\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            openDay = day
            prune()
        }
        guard let handle else { return }
        // `write(contentsOf:)` throws where the old `write(_:)` traps, and a full
        // disk must not take the app down over a log line.
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Drop anything older than the retention window. Called on rotation, which is
    /// at most once a day.
    private static func prune() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("paper-") && $0.pathExtension == "log" } ?? []
        guard files.count > retainDays else { return }
        for stale in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(retainDays) {
            try? fm.removeItem(at: stale)
        }
    }

    /* -------------------------------------------------------------- reading */

    /// The recent history, newest first, optionally narrowed.
    static func recent(limit: Int = 400, level: LogLevel = .debug, subsystem: String? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.reversed()
            .filter { $0.level >= level && (subsystem == nil || $0.subsystem == subsystem) }
            .prefix(limit)
            .map { $0 }
    }

    /// Every subsystem that has said anything this run, for the filter control.
    static func subsystems() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(buffer.map(\.subsystem))).sorted()
    }

    /// How many of each level this run has produced — the one number worth putting
    /// on a badge, because an error count above zero is the whole point of asking.
    static func tally() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    /// The files on disk, so the interface can point at one rather than describe it.
    static func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .map(\.lastPathComponent)
            .sorted(by: >)
    }

    static var thresholdName: String { threshold.rawValue }

    /// Lowering the floor at runtime, so a problem that only shows up in a built
    /// app can be investigated without a rebuild and a relaunch.
    static func setThreshold(_ level: LogLevel) {
        threshold = level
        write("[log] level set to \(level.rawValue)", .info, "log")
    }

    /* --------------------------------------------------------------- stamps */

    /// Local time, because the person reading it is sitting in it. Fixed format
    /// rather than a DateFormatter, which is slow and locale-sensitive in a place
    /// where neither is wanted.
    private static func parts(_ at: Double) -> DateComponents {
        Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: at / 1000))
    }

    static func dayKey(_ at: Double) -> String {
        let c = parts(at)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func stamp(_ at: Double) -> String {
        let c = parts(at)
        let ms = Int(at.truncatingRemainder(dividingBy: 1000))
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    /// Flush and close, for the self-test and for a clean quit.
    static func close() {
        queue.sync {
            handle?.closeFile()
            handle = nil
            openDay = ""
        }
    }
}

/**
 * The call the whole app already makes.
 *
 * Unchanged for every existing caller — `log("[market] …")` still works and now
 * lands in a file as well as on standard error. The two extra arguments are there
 * for new code that knows something the message text does not: that a line is a
 * warning rather than a note, or that it belongs to a subsystem whose name is not
 * in the prefix.
 */
func log(_ message: String, _ level: LogLevel = .info, _ subsystem: String? = nil) {
    Log.write(message, level, subsystem)
}
