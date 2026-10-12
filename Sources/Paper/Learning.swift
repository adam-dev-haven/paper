/**
 * Learning.swift — the part of Paper that changes.
 *
 * Every other file in this app does the same thing on the hundredth run as on the
 * first. This one does not. It keeps a per-account memory of what the engine
 * recommended, what the user did with it, what the market then did to both, and
 * turns the difference into named, evidenced adjustments to how the next analysis
 * behaves.
 *
 * Two separate things get graded, and keeping them apart is the whole point:
 *
 *   The **engine** is graded on its picks, including the ones that were never
 *   taken. A recommendation that was ignored still has an answer — price either
 *   reached its target or its stop — and that answer is free, because the bars are
 *   already on disk. This is the only way to find out whether the stops are too
 *   tight or the targets too far, as opposed to whether the person is trading them
 *   badly.
 *
 *   The **user** is graded on execution: exits, hold times, stop discipline, cost
 *   drag. Those produce rules rather than knobs, because no parameter fixes
 *   selling a winner after two days.
 *
 * Nothing here moves on its own. A finding becomes a *proposal* carrying its
 * evidence, its sample size and the exact numeric change it would make; it only
 * touches the next analysis once the user applies it, and it can be reverted
 * afterwards with the calibration recomposed from whatever is left. An app that
 * silently retunes its own risk engine and tells you later is an app you cannot
 * audit, and this one is supposed to be teaching.
 *
 * The clamps are load-bearing. Every knob has a hard range, `riskScale` can only
 * ever reduce risk, and a proposal from the language model goes through exactly
 * the same clamp as one the arithmetic produced. Learning is allowed to make the
 * engine more careful without supervision; making it bolder is a decision a person
 * has to take.
 */

import Foundation

/* ------------------------------------------------------------------ knobs */

/// The dials the engine will let experience move, and how far.
enum Knob: String, Codable, CaseIterable {
    /// Multiplier on the horizon's stop width. Above 1 is a wider stop.
    case stopScale
    /// Multiplier on the horizon's target distance.
    case targetScale
    /// Added to the objective's minimum reward-to-risk. Positive funds fewer trades.
    case minRewardToRisk
    /// Multiplier on the risk taken per trade. Capped at 1: experience may make this
    /// account more careful, never bolder than its suitability limit allows.
    case riskScale
    /// Multiplier on how long a plan may take to resolve.
    case holdScale
    /// A minimum quantitative conviction a candidate must clear at all.
    case convictionFloor
    /// Multiplier on the objective's ceiling for average daily range.
    case rangeCeiling
    /// Conviction points added or removed for one sector.
    case sectorBias
    /// Conviction points for one market regime.
    case regimeBias
    /// Conviction points for one instrument.
    case symbolBias

    /// Everything a knob is allowed to be, and what it starts at.
    var bounds: (min: Double, max: Double, base: Double) {
        switch self {
        case .stopScale:       return (0.70, 1.60, 1)
        case .targetScale:     return (0.60, 1.80, 1)
        case .minRewardToRisk: return (-0.50, 1.50, 0)
        case .riskScale:       return (0.40, 1.00, 1)
        case .holdScale:       return (0.50, 1.60, 1)
        case .convictionFloor: return (0, 75, 0)
        case .rangeCeiling:    return (0.50, 1.50, 1)
        case .sectorBias, .regimeBias, .symbolBias: return (-25, 25, 0)
        }
    }

    /// True where the knob addresses one sector, regime or symbol rather than the
    /// engine as a whole — those carry a key and compose additively.
    var isKeyed: Bool { self == .sectorBias || self == .regimeBias || self == .symbolBias }

    var label: String {
        switch self {
        case .stopScale: return "Stop width"
        case .targetScale: return "Target distance"
        case .minRewardToRisk: return "Minimum reward-to-risk"
        case .riskScale: return "Risk per trade"
        case .holdScale: return "How long a trade may take"
        case .convictionFloor: return "Minimum conviction to fund"
        case .rangeCeiling: return "Volatility ceiling"
        case .sectorBias: return "Sector conviction"
        case .regimeBias: return "Regime conviction"
        case .symbolBias: return "Instrument conviction"
        }
    }

    /// How the number reads to someone who has not met it before.
    func describe(_ value: Double, key: String?) -> String {
        switch self {
        case .stopScale:
            return value == 1 ? "stops at their normal width"
                : "stops \(f(abs(value - 1) * 100, 0))% \(value > 1 ? "wider" : "tighter") than normal"
        case .targetScale:
            return value == 1 ? "targets at their normal distance"
                : "targets \(f(abs(value - 1) * 100, 0))% \(value > 1 ? "further out" : "closer in")"
        case .minRewardToRisk:
            return value == 0 ? "the objective's own reward-to-risk floor"
                : "\(value > 0 ? "+" : "")\(f(value, 2)) on the reward-to-risk a setup must offer"
        case .riskScale:
            return value == 1 ? "the full risk this account's suitability allows"
                : "\(f(value * 100, 0))% of the risk per trade this account's suitability allows"
        case .holdScale:
            return value == 1 ? "the horizon's normal patience"
                : "\(f(abs(value - 1) * 100, 0))% \(value > 1 ? "more" : "less") time allowed to reach a target"
        case .convictionFloor:
            return value <= 0 ? "no conviction floor" : "nothing scored under \(f(value, 0))/100 gets funded"
        case .rangeCeiling:
            return value == 1 ? "the objective's own volatility ceiling"
                : "a volatility ceiling \(f(abs(value - 1) * 100, 0))% \(value > 1 ? "higher" : "lower") than the objective's"
        case .sectorBias, .regimeBias, .symbolBias:
            let what = key ?? "—"
            return "\(value > 0 ? "+" : "")\(f(value, 0)) conviction on \(what)"
        }
    }
}

/// One concrete change to one dial.
struct Adjustment: Codable {
    var knob: Knob
    /// Sector, regime or symbol, for the keyed knobs. Nil otherwise.
    var key: String?
    var from: Double
    var to: Double
    /// Stored rather than computed so it crosses the wire — the interface shows this
    /// sentence on the confirmation, and a change nobody can read is one nobody
    /// should be asked to approve.
    var summary: String

    var delta: Double { to - from }

    /// Clamped at construction, so nothing downstream has to trust the caller — a
    /// proposal written by a language model is built through exactly this path.
    init(knob: Knob, key: String? = nil, from: Double, to: Double) {
        let k = knob.isKeyed ? key : nil
        let b = knob.bounds
        let lo = Analysis.clamp(from, b.min, b.max)
        let hi = Analysis.clamp(to, b.min, b.max)
        self.knob = knob
        self.key = k
        self.from = lo
        self.to = hi
        self.summary = "\(knob.label): \(knob.describe(lo, key: k)) → \(knob.describe(hi, key: k))"
    }
}

/* ----------------------------------------------------------------- lessons */

enum LessonStatus: String, Codable {
    /// Seen, but not enough of it yet to act on. Shown so the user can watch it build.
    case watching
    /// Evidenced enough to offer. Waiting on the user.
    case proposed
    /// Live. It shapes the next analysis.
    case applied
    /// Turned down. Kept so the same finding is not offered again next week.
    case dismissed
    /// Was applied, and the evidence has since gone the other way.
    case retired
}

struct Lesson: Codable, Identifiable {
    var id: String
    /// Stable across runs, so a finding that recurs updates its own entry rather
    /// than stacking five near-identical proposals.
    var kind: String
    /// One line, in plain language, in the user's terms.
    var title: String
    /// What was measured. Numbers only — no interpretation.
    var finding: String
    /// Why that measurement implies this change.
    var reasoning: String
    /// The individual observations behind it, so the claim can be checked.
    var evidence: [String]
    var sampleSize: Int
    /// 0–1. Sample size and effect size, not a feeling.
    var confidence: Double
    /// Nil where the lesson is a rule about behaviour rather than a dial.
    var adjustment: Adjustment?
    var status: LessonStatus
    /// "engine" — derived from arithmetic. "analyst" — proposed by Claude and clamped.
    var source: String
    var createdAt: Double
    var updatedAt: Double
    var appliedAt: Double?
    /// Analyses that have run with this lesson live.
    var runsSinceApplied: Int
    /// What has happened since it was applied, once there is enough to say.
    var outcomeNote: String?

    var isRule: Bool { adjustment == nil }
}

/* -------------------------------------------------------------- run records */

/// One instrument as it was recommended, so the recommendation can be graded later
/// whether or not it was ever traded.
struct RunPick: Codable {
    var symbol: String
    var sector: String
    var regime: String
    var conviction: Double
    var entry: Double
    var target: Double
    var stop: Double
    var rr: Double
    var horizonDays: Double
    var atrPct: Double?
    var allocationPct: Double
}

/// What price did to a pick afterwards. Pure arithmetic over bars already on disk.
struct PickOutcome: Codable {
    var symbol: String
    var resolved: Bool
    var hitTarget: Bool
    var hitStop: Bool
    /// Sessions until whichever level was reached first.
    var sessionsToResolve: Int?
    /// The result in multiples of the risk the plan took, from the plan's own levels.
    var rMultiple: Double?
    /// The furthest price ran in favour, and against, since the run.
    var mfeR: Double?
    var maeR: Double?
    /// True where a stop was hit and price later traded back above the entry.
    var recoveredAfterStop: Bool
    /// True where the target was hit and price ran on at least another 1R.
    var ranOnAfterTarget: Bool
    var sessionsObserved: Int
}

struct RunRecord: Codable {
    var id: String
    var at: Double
    var profileId: String
    /// The calibration that was live when these picks were produced.
    var calibration: Calibration
    var lessonIds: [String]
    var picks: [RunPick]
    /// Filled in on a later review, once the market has answered.
    var outcomes: [PickOutcome]
    var gradedAt: Double?
}

/* ------------------------------------------------------------- calibration */

/// The composed effect of every applied lesson: the actual numbers the next
/// analysis runs with. Always derived, never edited directly, so removing a lesson
/// removes exactly its contribution and nothing else.
struct Calibration: Codable {
    var stopScale: Double = 1
    var targetScale: Double = 1
    var minRewardToRiskDelta: Double = 0
    var riskScale: Double = 1
    var holdScale: Double = 1
    var convictionFloor: Double = 0
    var rangeCeilingScale: Double = 1
    var sectorBias: [String: Double] = [:]
    var regimeBias: [String: Double] = [:]
    var symbolBias: [String: Double] = [:]

    static let neutral = Calibration()

    var isNeutral: Bool {
        stopScale == 1 && targetScale == 1 && minRewardToRiskDelta == 0 && riskScale == 1
            && holdScale == 1 && convictionFloor == 0 && rangeCeilingScale == 1
            && sectorBias.isEmpty && regimeBias.isEmpty && symbolBias.isEmpty
    }

    /// Rebuilt from scratch whenever the lesson set changes.
    static func compose(_ lessons: [Lesson]) -> Calibration {
        var c = Calibration()
        for lesson in lessons where lesson.status == .applied {
            guard let a = lesson.adjustment else { continue }
            let b = a.knob.bounds
            switch a.knob {
            case .stopScale:       c.stopScale = Analysis.clamp(c.stopScale * (a.to / max(a.from, 0.01)), b.min, b.max)
            case .targetScale:     c.targetScale = Analysis.clamp(c.targetScale * (a.to / max(a.from, 0.01)), b.min, b.max)
            case .riskScale:       c.riskScale = Analysis.clamp(c.riskScale * (a.to / max(a.from, 0.01)), b.min, b.max)
            case .holdScale:       c.holdScale = Analysis.clamp(c.holdScale * (a.to / max(a.from, 0.01)), b.min, b.max)
            case .rangeCeiling:    c.rangeCeilingScale = Analysis.clamp(c.rangeCeilingScale * (a.to / max(a.from, 0.01)), b.min, b.max)
            case .minRewardToRisk: c.minRewardToRiskDelta = Analysis.clamp(c.minRewardToRiskDelta + a.delta, b.min, b.max)
            case .convictionFloor: c.convictionFloor = Analysis.clamp(max(c.convictionFloor, a.to), b.min, b.max)
            case .sectorBias:      if let k = a.key { c.sectorBias[k] = Analysis.clamp((c.sectorBias[k] ?? 0) + a.delta, b.min, b.max) }
            case .regimeBias:      if let k = a.key { c.regimeBias[k] = Analysis.clamp((c.regimeBias[k] ?? 0) + a.delta, b.min, b.max) }
            case .symbolBias:      if let k = a.key { c.symbolBias[k] = Analysis.clamp((c.symbolBias[k] ?? 0) + a.delta, b.min, b.max) }
            }
        }
        return c
    }

    /// Where the calibration actually bites: the rules the plan builder reads.
    func apply(to rules: Analysis.SizingRules) -> Analysis.SizingRules {
        var r = rules
        r.stopScale *= stopScale
        r.targetScale *= targetScale
        r.minRewardToRisk = max(1.0, r.minRewardToRisk + minRewardToRiskDelta)
        r.riskPctPerTrade *= riskScale
        if let maxS = r.maxSessions { r.maxSessions = maxS * holdScale }
        if let minS = r.minSessions { r.minSessions = minS * min(1, holdScale) }
        if let cap = r.maxDailyRangePct { r.maxDailyRangePct = cap * rangeCeilingScale }
        return r
    }

    /// Conviction after experience. The bias is bounded so a learned opinion tilts
    /// the ranking without ever overwhelming what the chart says.
    func conviction(_ base: Double, symbol: String, sector: String, regime: String) -> Double {
        let bias = (sectorBias[sector] ?? 0) + (regimeBias[regime] ?? 0) + (symbolBias[symbol] ?? 0)
        return Analysis.clamp(base + Analysis.clamp(bias, -30, 30), 0, 100)
    }

    /// Said in the prompts and on the Learning tab, so the engine's current state of
    /// mind is always legible rather than buried in a JSON file.
    var lines: [String] {
        var out: [String] = []
        if stopScale != 1 { out.append(Knob.stopScale.describe(stopScale, key: nil)) }
        if targetScale != 1 { out.append(Knob.targetScale.describe(targetScale, key: nil)) }
        if minRewardToRiskDelta != 0 { out.append(Knob.minRewardToRisk.describe(minRewardToRiskDelta, key: nil)) }
        if riskScale != 1 { out.append(Knob.riskScale.describe(riskScale, key: nil)) }
        if holdScale != 1 { out.append(Knob.holdScale.describe(holdScale, key: nil)) }
        if convictionFloor > 0 { out.append(Knob.convictionFloor.describe(convictionFloor, key: nil)) }
        if rangeCeilingScale != 1 { out.append(Knob.rangeCeiling.describe(rangeCeilingScale, key: nil)) }
        for (k, v) in sectorBias.sorted(by: { $0.key < $1.key }) { out.append(Knob.sectorBias.describe(v, key: k)) }
        for (k, v) in regimeBias.sorted(by: { $0.key < $1.key }) { out.append(Knob.regimeBias.describe(v, key: k)) }
        for (k, v) in symbolBias.sorted(by: { $0.key < $1.key }) { out.append(Knob.symbolBias.describe(v, key: k)) }
        return out
    }
}

/* ------------------------------------------------------------------ memory */

struct Memory: Codable {
    var version: Int = 1
    var profileId: String
    var lessons: [Lesson] = []
    var runs: [RunRecord] = []
    /// Recomposed on every write, so it can never drift from the lesson set.
    var calibration: Calibration = .neutral
    var updatedAt: Double = 0
    /// Analyses run under this memory, applied or not.
    var analysesRun: Int = 0

    static func empty(_ profileId: String) -> Memory { Memory(profileId: profileId) }

    init(version: Int = 1, profileId: String, lessons: [Lesson] = [], runs: [RunRecord] = [],
         calibration: Calibration = .neutral, updatedAt: Double = 0, analysesRun: Int = 0) {
        self.version = version; self.profileId = profileId; self.lessons = lessons
        self.runs = runs; self.calibration = calibration
        self.updatedAt = updatedAt; self.analysesRun = analysesRun
    }

    /**
     * Decoded by hand, like the ledger.
     *
     * Every one of the seven keys was load-bearing under the synthesised decoder,
     * so adding a field made every existing memory file unreadable — and the read
     * path answered that by substituting `Memory.empty` and letting the next write
     * put it on disk. The lessons a desk has drawn from its own record are not
     * recoverable by any other means: they are the distilled form of trades that
     * have already happened, and losing them means the market has to teach the
     * same thing twice.
     *
     * `profileId` is the only key worth refusing over — without it the file cannot
     * be matched to an account, which means it is not a memory rather than an old
     * one.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        lessons = try c.decodeIfPresent([Lesson].self, forKey: .lessons) ?? []
        runs = try c.decodeIfPresent([RunRecord].self, forKey: .runs) ?? []
        // Recomposed from the lessons on load anyway, so a missing or stale value
        // here costs nothing.
        calibration = try c.decodeIfPresent(Calibration.self, forKey: .calibration) ?? .neutral
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        analysesRun = try c.decodeIfPresent(Int.self, forKey: .analysesRun) ?? 0
    }

    var applied: [Lesson] { lessons.filter { $0.status == .applied } }
    var open: [Lesson] { lessons.filter { $0.status == .proposed } }
    var watching: [Lesson] { lessons.filter { $0.status == .watching } }

    mutating func recompose() {
        calibration = Calibration.compose(lessons)
        updatedAt = nowMs()
    }

    /// What the analyst is told the desk has learned. Rules first, because those are
    /// the ones the model has to write around; the dials it merely has to respect.
    var brief: String {
        let rules = applied.filter(\.isRule)
        let dials = calibration.lines
        guard !rules.isEmpty || !dials.isEmpty else {
            return "This desk has no accumulated lessons yet — this account's record is too short to have taught it anything. Do not pretend otherwise."
        }
        var lines = ["What this desk has learned from this account's own record, and is now running with:"]
        for r in rules {
            lines.append("- RULE: \(r.title) (from \(r.sampleSize) trade\(r.sampleSize == 1 ? "" : "s") — \(r.finding))")
        }
        if !dials.isEmpty {
            lines.append("- The risk engine is calibrated to: " + dials.joined(separator: "; ") + ".")
            lines.append("  Those numbers are already baked into every level you are shown. Do not restate them as your own recommendation and do not argue against them; if one looks wrong given what you can see, say so plainly instead.")
        }
        return lines.joined(separator: "\n")
    }
}

/* ---------------------------------------------------------------- grading */

enum Learning {

    /// Sessions of history a pick needs before its outcome counts for anything.
    static let minSessionsToGrade = 3

    /**
     * Grade one recommendation against what price actually did.
     *
     * Walks the bars from the run forward, watching for the stop and the target the
     * plan set. When both sit inside one session the stop is assumed to have filled
     * first, for the same reason the ledger assumes it: taking the good side of an
     * ambiguity is how a backtest flatters itself.
     */
    static func grade(_ pick: RunPick, bars: [Bar], from: Double) -> PickOutcome? {
        let after = bars.filter { $0.t > from }
        guard !after.isEmpty else { return nil }

        let risk = pick.entry - pick.stop
        guard risk > 0 else { return nil }

        var hitTarget = false
        var hitStop = false
        var sessions: Int?
        var best = pick.entry
        var worst = pick.entry
        var afterStopHigh: Double?
        var afterTargetHigh: Double?

        for (i, bar) in after.enumerated() {
            best = Swift.max(best, bar.h)
            worst = Swift.min(worst, bar.l)

            if hitStop { afterStopHigh = Swift.max(afterStopHigh ?? bar.h, bar.h) }
            if hitTarget { afterTargetHigh = Swift.max(afterTargetHigh ?? bar.h, bar.h) }

            if !hitStop && !hitTarget {
                let touchedStop = bar.l <= pick.stop
                let touchedTarget = bar.h >= pick.target
                if touchedStop { hitStop = true; sessions = i + 1 }
                else if touchedTarget { hitTarget = true; sessions = i + 1 }
            }
        }

        let r: Double? = hitStop ? -1
            : hitTarget ? (pick.target - pick.entry) / risk
            : ((after.last!.c - pick.entry) / risk)

        return PickOutcome(
            symbol: pick.symbol,
            resolved: hitStop || hitTarget,
            hitTarget: hitTarget,
            hitStop: hitStop,
            sessionsToResolve: sessions,
            rMultiple: r,
            mfeR: (best - pick.entry) / risk,
            maeR: (worst - pick.entry) / risk,
            recoveredAfterStop: hitStop && (afterStopHigh ?? 0) > pick.entry,
            ranOnAfterTarget: hitTarget && (afterTargetHigh ?? 0) >= pick.target + risk,
            sessionsObserved: after.count
        )
    }

    /// Grades every run old enough to have an answer. Returns the runs, updated.
    static func gradeRuns(_ runs: [RunRecord], bars: [String: [Bar]]) -> [RunRecord] {
        runs.map { run in
            var r = run
            var graded: [PickOutcome] = []
            for pick in run.picks {
                guard let series = bars[pick.symbol],
                      let outcome = grade(pick, bars: series, from: run.at),
                      outcome.sessionsObserved >= minSessionsToGrade
                else { continue }
                graded.append(outcome)
            }
            if !graded.isEmpty { r.outcomes = graded; r.gradedAt = nowMs() }
            return r
        }
    }
}

/* ------------------------------------------------------------ app settings */

/// The handful of things that belong to the app rather than to any one account.
struct AppSettings: Codable {
    /// False until someone has been through the setup or explicitly skipped it.
    /// Decides whether the app opens on the desk or on the first question.
    var hasOnboarded: Bool = false
    /// What one analyst run may spend, and when the governor calls a halt.
    var analystLimits: RunLimits = .standard
    /// The model that does the thinking. Empty means "whatever the app defaults to",
    /// which keeps an untouched install following the default as it moves rather than
    /// pinning it to whatever was current the day the file was written.
    var analystModel: String = ""
    /// An optional cheaper model for the mechanical passes. Empty means the main one
    /// does everything.
    var analystFastModel: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasOnboarded = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        analystLimits = (try c.decodeIfPresent(RunLimits.self, forKey: .analystLimits) ?? .standard).sanitised()
        analystModel = try c.decodeIfPresent(String.self, forKey: .analystModel) ?? ""
        analystFastModel = try c.decodeIfPresent(String.self, forKey: .analystFastModel) ?? ""
    }
}
