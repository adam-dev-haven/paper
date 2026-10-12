/**
 * ReadingMode.swift — where the app opens, and how much it explains.
 *
 * The profile decides how Paper trades: stop width, target distance, minimum
 * reward-to-risk, volatility ceiling, trade duration. It has never decided how
 * Paper reads. Every profile is served the same screen, so an account opened
 * this morning and one with two years of record behind it both land on the same
 * desk, with the same forty terms used as though both already knew them.
 *
 * This is the second axis. It sets the surface the app opens on, whether terms
 * are explained where they are used, and what the analyst tab is called when the
 * mode goes there for something other than ideas. It changes no trading
 * parameter, touches no ledger, and can be changed at any time.
 *
 * Two further modes are designed and not built — a single-decision rail for a
 * first account, and a weekly verdict with a process streak. They are absent
 * here rather than listed, because a mode that names a surface the app does not
 * have is a setting that does nothing.
 */

import Foundation

enum ReadingMode: String, Codable, CaseIterable {
    case guided, diagnostic, configurable, instrument, dense

    /// Shown in settings. Short, and it names where the mode opens.
    var label: String {
        switch self {
        case .guided:       return "Guided"
        case .diagnostic:   return "Record"
        case .configurable: return "Rules"
        case .instrument:   return "Market"
        case .dense:        return "Desk"
        }
    }

    /// What picking it does.
    var note: String {
        switch self {
        case .guided:       return "Opens on the guide. Terms are explained where they are used."
        case .diagnostic:   return "Opens on your closed trades and what each exit cost."
        case .configurable: return "Opens on calibration. Every adjustment is listed with its evidence."
        case .instrument:   return "Opens on the markets board, with the analyst beside it."
        case .dense:        return "Opens on the desk. Nothing is added to the screen."
        }
    }

    /// The view the app opens on when no other destination was asked for.
    var landing: String {
        switch self {
        case .guided:       return "learn"
        case .diagnostic:   return "analyst"
        case .configurable: return "learning"
        case .instrument:   return "markets"
        case .dense:        return "desk"
        }
    }

    /// The segment inside that view, where it has segments.
    var landingSection: String? {
        self == .diagnostic ? "review" : nil
    }

    /// Whether terms carry their definition where they are used.
    var explains: Bool {
        self == .guided
    }

    /// The analyst tab holds ideas and the review of closed trades. One mode goes
    /// there for the second one, so it is named for that.
    var analystTabLabel: String {
        self == .diagnostic ? "Review" : "Analyst"
    }
}
