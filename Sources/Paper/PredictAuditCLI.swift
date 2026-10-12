/**
 * PredictAuditCLI.swift — the audit, from a terminal, against the book on disk.
 *
 * `--predictaudit` exists because the question it answers is one you want to ask
 * *about* a desk rather than *inside* one. Opening the app starts the loop, and a
 * loop that is running is a loop that is changing the thing you are trying to
 * read. This opens the book, scores the field, prints the report and exits,
 * writing nothing.
 *
 * `PAPER_DATA_DIR` points it at a different book, which is how it is exercised
 * against a fabricated one whose answer is known by construction.
 */

import Foundation

enum PredictAuditCLI {

    static func run() -> Bool {
        let directory = Desk.dataDirectory.appendingPathComponent("predictions", isDirectory: true)

        guard let bookData = try? Data(contentsOf: directory.appendingPathComponent("shadow-book.json")),
              let book = try? JSONDecoder().decode([ShadowWindow].self, from: bookData)
        else {
            print("No shadow book at \(directory.path).")
            print("The book fills whenever a prediction run is open — every window it watches is")
            print("written down, whether or not it bets on one.")
            return true
        }

        let brain = (try? Data(contentsOf: directory.appendingPathComponent("brain.json")))
            .flatMap { try? JSONDecoder().decode(PredictBrain.self, from: $0) }
            ?? .unlearned()
        let policy = (try? Data(contentsOf: directory.appendingPathComponent("policy.json")))
            .flatMap { try? JSONDecoder().decode(PredictPolicy.self, from: $0) }
            ?? .market()
        let bets = (try? Data(contentsOf: directory.appendingPathComponent("settled-bets.json")))
            .flatMap { try? JSONDecoder().decode([SettledBet].self, from: $0) }
            ?? []

        let report = PredictAudit.run(book: book, brain: brain, policy: policy,
                                      bets: bets, minEdge: 0.05)
        print(render(report))
        return report.verdict != .broken
    }

    /* ---------------------------------------------------------------- output */

    static func render(_ report: PredictAuditReport) -> String {
        var out = "\n"
        out += "PREDICTION DESK — LEARNING AUDIT\n"
        out += String(repeating: "=", count: 78) + "\n\n"
        out += "  \(report.verdict.label.uppercased())\n"
        out += wrap(report.headline, indent: 2) + "\n"

        for check in report.checks {
            out += "\n" + String(repeating: "-", count: 78) + "\n"
            out += "\(marker(check.verdict))  \(check.question)\n"
            out += String(repeating: "-", count: 78) + "\n"
            out += wrap(check.finding, indent: 4) + "\n"
            if let remedy = check.remedy {
                out += "\n" + wrap("→ " + remedy, indent: 4) + "\n"
            }
            if !check.readings.isEmpty {
                out += "\n"
                let width = check.readings.map(\.name.count).max() ?? 0
                for reading in check.readings {
                    let pad = String(repeating: " ", count: Swift.max(0, width - reading.name.count))
                    out += "      \(reading.flagged ? "!" : " ") \(reading.name)\(pad)   \(reading.value)\n"
                }
            }
        }

        if !report.candidates.isEmpty {
            out += "\n" + String(repeating: "=", count: 78) + "\n"
            out += "THE FIELD — every reading, scored on windows it was never fitted on\n"
            out += String(repeating: "=", count: 78) + "\n\n"
            for candidate in report.candidates {
                out += "  \(candidate.promotable ? "PROMOTE" : "       ")  \(candidate.label)\n"
                out += wrap(candidate.asks, indent: 12) + "\n"
                out += "            Brier \(f(candidate.oosBrier, 5))"
                out += "   vs champion \(candidate.gainOverChampion >= 0 ? "+" : "")\(f(candidate.gainOverChampion, 5))"
                out += "   \(f(candidate.sigma, 1))σ"
                out += "   \(candidate.windowsTested) windows\n"
                out += wrap(candidate.verdict, indent: 12) + "\n\n"
            }
        }

        out += String(repeating: "=", count: 78) + "\n"
        out += "Reading in force: \(report.policy.isDefault ? "the market price alone" : report.policy.candidateId)\n"
        out += wrap(report.policy.summary, indent: 2) + "\n"
        return out
    }

    private static func marker(_ v: AuditVerdict) -> String {
        switch v {
        case .healthy: return "[ ok ]"
        case .waiting: return "[wait]"
        case .blocked: return "[STUCK]"
        case .broken: return "[BROKEN]"
        }
    }

    /// Hard-wrapped to 78 columns. A terminal report that relies on the terminal
    /// to wrap it is a report that reads differently in every window.
    static func wrap(_ text: String, indent: Int, width: Int = 78) -> String {
        let prefix = String(repeating: " ", count: indent)
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = prefix
            for word in paragraph.split(separator: " ") {
                if line.count + word.count + 1 > width, line.count > indent {
                    lines.append(line)
                    line = prefix
                }
                line += (line.count > indent ? " " : "") + word
            }
            if line.count > indent { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }
}
