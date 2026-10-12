/**
 * PredictJournal.swift — what the prediction desk has actually done, kept.
 *
 * **The gap this closes.** The desk learns from every window it watches, and until
 * now none of that was visible and most of it was destroyed. One run file per
 * account: `open` overwrote it, `clear` deleted it, and a finished run survived
 * exactly until the next one started. The shadow book accumulated underneath, but
 * the only thing on screen was three fitted numbers with no history — so the honest
 * answer to *"is this calibrating from its mistakes after I close the app?"* was
 * that you could not tell from the app, which is the same as no.
 *
 * Three things are kept here, and they answer three different questions.
 *
 *   **The runs.** Every finished run, archived before anything can overwrite it,
 *   with its settings, its verdict tally, its closest miss and its bets. Answers
 *   *what has this thing been doing.*
 *
 *   **The changes.** Every time a fitted parameter actually moves, with what it
 *   moved from, to, and on how much evidence. A parameter that never moves is a
 *   parameter that never learned anything, and that has to be as visible as one
 *   that did. Answers *has it changed its mind, and when.*
 *
 *   **The score.** The model's probabilities against the market's, over every
 *   resolved window, by Brier and by hit rate, plus a calibration table of stated
 *   confidence against how often that confidence was right. Answers *is it any
 *   good, and does it know how good it is* — which is what calibration means and is
 *   the only one of the three that can say the model is not working.
 *
 * None of this is the trading journal and none of it goes near the ledger, for the
 * same reason the bankroll does not: a binary contract has no cost basis, no
 * holding period and nothing to sell back to, and putting one through the same
 * scorecard as a share would produce a number that is wrong about both.
 */

import Foundation

/* ------------------------------------------------------------- brain changes */

/// One fitted parameter actually moving, and the evidence it moved on.
///
/// Only recorded when the value changes. A log that also recorded every re-fit that
/// changed nothing would be a hundred identical lines an hour, and the signal —
/// *this is the moment the desk revised something* — would be invisible in it.
struct BrainChange: Codable {
    enum Parameter: String, Codable {
        case feedNoise = "feed-gap"
        case modelWeight = "model-weight"
        case entryOffset = "entry-offset"

        var label: String {
            switch self {
            case .feedNoise:   return "Gap to the resolver"
            case .modelWeight: return "Weight the model is allowed"
            case .entryOffset: return "Entry into the window"
            }
        }
        var unit: String {
            switch self {
            case .feedNoise:   return " bps"
            case .modelWeight: return "%"
            case .entryOffset: return "s"
            }
        }
    }

    let at: Double
    let parameter: Parameter
    let from: Double
    let to: Double
    /// Resolved windows the new value stands on.
    let evidence: Int
    /// True when this is the move off the shipped default — the first time the desk
    /// had enough to have an opinion of its own about this number.
    let firstMeasurement: Bool
    let note: String
}

/* ---------------------------------------------------------------- the score */

/// Stated confidence against how often it was right, in one band.
struct CalibrationBand: Codable {
    /// The band, as a probability of the side being called: 0.5–0.6, 0.6–0.7, …
    let from: Double
    let to: Double
    let windows: Int
    /// Mean confidence claimed across the windows in this band.
    let claimed: Double
    /// How often that call was actually right.
    let actual: Double
}

/**
 * The model's record against the market's, over resolved windows.
 *
 * **Brier is the headline and hit rate is the footnote**, which is the opposite of
 * what people expect, so it is worth saying why. Hit rate only asks whether the
 * favoured side won, which throws away everything the model is actually claiming:
 * a model that says 51% and one that says 99% score identically on a window they
 * both call correctly. Brier — mean squared error against the outcome — pays for
 * being confident and right and charges for being confident and wrong, which is the
 * quantity that decides whether betting on the model makes money.
 *
 * The comparison that matters is against the market at the same instant, because a
 * Brier score alone has no scale. The market's is the benchmark the model has to
 * beat before its opinion is worth any weight at all, and the weight fit in
 * `PredictFit.modelWeight` is exactly the answer to how much it beats it by.
 */
struct PredictScore: Codable {
    let windows: Int
    let samples: Int
    /// Lower is better. A coin flip on every window scores 0.25.
    let modelBrier: Double
    let marketBrier: Double
    /// The two blended at the weight currently in force — what the desk actually
    /// decides on, which is neither of the above.
    let blendBrier: Double
    let modelHitRate: Double
    let marketHitRate: Double
    /// Stated confidence against realised frequency, in bands.
    let calibration: [CalibrationBand]
    let summary: String

    static func empty() -> PredictScore {
        PredictScore(
            windows: 0, samples: 0, modelBrier: 0, marketBrier: 0, blendBrier: 0,
            modelHitRate: 0, marketHitRate: 0, calibration: [],
            summary: "No window has resolved yet. Every window the desk watches is written down with "
                + "what it thought and what the market was pricing, and this fills in as Polymarket "
                + "publishes the answers — about twelve an hour while a run is going, whether or not "
                + "anything is bought.")
    }
}

extension PredictFit {

    /// Scores the model against the market over every resolved, undegraded window.
    ///
    /// Pure, like the three fits, and for the same reason: this is the arithmetic
    /// most worth testing against a book whose right answer is known, and actor
    /// isolation would put it out of reach of a synchronous `--selftest`.
    static func score(_ rows: [ShadowWindow], weight: Double) -> PredictScore {
        var pairs: [(model: Double, market: Double, up: Bool)] = []
        for row in rows {
            guard let resolved = row.resolved else { continue }
            for s in row.samples {
                guard let market = s.pMarket, market > 0.001, market < 0.999 else { continue }
                pairs.append((Analysis.clamp(s.pModel, 0.005, 0.995), market, resolved == .up))
            }
        }
        let windows = rows.filter { $0.resolved != nil && !$0.samples.isEmpty }.count
        guard !pairs.isEmpty else { return .empty() }

        func logit(_ p: Double) -> Double { log(p / (1 - p)) }
        func brier(_ get: ((model: Double, market: Double, up: Bool)) -> Double) -> Double {
            pairs.reduce(0) { total, s in
                let p = get(s)
                let outcome = s.up ? 1.0 : 0.0
                return total + (p - outcome) * (p - outcome)
            } / Double(pairs.count)
        }

        let modelBrier = brier { $0.model }
        let marketBrier = brier { $0.market }
        let blendBrier = brier {
            1 / (1 + exp(-(weight * logit($0.model) + (1 - weight) * logit($0.market))))
        }
        let modelHits = pairs.filter { ($0.model >= 0.5) == $0.up }.count
        let marketHits = pairs.filter { ($0.market >= 0.5) == $0.up }.count

        /* Calibration is measured on the *called* side rather than on Up.
         *
         * A model that says 20% Up is claiming 80% Down, and scoring it in an Up-
         * indexed band would file that claim under "20%" and then count it as wrong
         * whenever Down came in — which inverts the reading. Folding every sample onto
         * the side it favours puts all of them on one scale from 50% to 100%, where
         * "claimed 70 and was right 70% of the time" means what it sounds like. */
        var bands: [CalibrationBand] = []
        for lower in stride(from: 0.5, to: 1.0, by: 0.1) {
            let upper = lower + 0.1
            let inBand = pairs.compactMap { s -> (claimed: Double, right: Bool)? in
                let claimed = Swift.max(s.model, 1 - s.model)
                guard claimed >= lower, claimed < upper || (upper >= 1 && claimed <= 1) else { return nil }
                return (claimed, (s.model >= 0.5) == s.up)
            }
            guard !inBand.isEmpty else { continue }
            bands.append(CalibrationBand(
                from: lower, to: upper, windows: inBand.count,
                claimed: inBand.reduce(0) { $0 + $1.claimed } / Double(inBand.count),
                actual: Double(inBand.filter(\.right).count) / Double(inBand.count)))
        }

        let edge = marketBrier - modelBrier
        var summary = "Across \(windows) resolved window\(windows == 1 ? "" : "s") "
            + "(\(pairs.count) looks), the model scored \(f(modelBrier, 4)) by Brier against the "
            + "market's \(f(marketBrier, 4)) — lower is better, and a coin flip on everything scores 0.2500. "
        if edge > 0.002 {
            summary += "The model is ahead of the market by \(f(edge, 4)), which is the case for giving it weight. "
        } else if edge < -0.002 {
            summary += "**The market is ahead by \(f(-edge, 4))**, which is the normal result and the reason the "
                + "desk mostly defers to it. The weight fit is what decides whether any of the model's view survives. "
        } else {
            summary += "The two are within a rounding error of each other. "
        }
        summary += "Blended at the weight currently in force they score \(f(blendBrier, 4)). "
        summary += "Calling the favoured side, the model was right \(f(Double(modelHits) / Double(pairs.count) * 100, 1))% "
            + "of the time and the market \(f(Double(marketHits) / Double(pairs.count) * 100, 1))% — "
            + "which is the less useful of the two measures, because it pays the same for a 51% call as for a 99% one."

        return PredictScore(
            windows: windows, samples: pairs.count,
            modelBrier: modelBrier, marketBrier: marketBrier, blendBrier: blendBrier,
            modelHitRate: Double(modelHits) / Double(pairs.count),
            marketHitRate: Double(marketHits) / Double(pairs.count),
            calibration: bands, summary: summary)
    }
}

/* -------------------------------------------------------- the offset profile */

/// What one fifteen-second offset has been worth, historically.
struct OffsetReading: Codable {
    let offset: Double
    /// Resolved windows with a look recorded at this offset.
    let samples: Int
    /// How often a qualifying edge was on the table here, 0–1.
    let edgeRate: Double
    /// Mean return per dollar staked across the looks that qualified. Positive means
    /// taking every one of them would have made money.
    let meanReturn: Double
    /// Looks that qualified — the denominator `meanReturn` is over, which is much
    /// smaller than `samples` and is the number that decides whether to believe it.
    let qualified: Int
    /// How sharp the model was here, against the market at the same instant.
    let modelBrier: Double
    let marketBrier: Double
}

/**
 * Every offset, side by side, rather than only the one the fit chose.
 *
 * `PredictFit.entryOffset` answers "which offset should the desk use" and answers
 * it conservatively: it needs forty qualifying looks in a bucket and a winner that
 * beats the field by more than a standard error, so for the first day of running it
 * correctly says nothing at all. That is right for a number that changes behaviour
 * and useless for the question underneath it — *is the edge already gone by the
 * time it is allowed to look?*
 *
 * This is the same data with no decision attached. It reports what each offset has
 * been worth and how many windows that stands on, and lets the reader judge. A row
 * built on nine windows is not evidence, and it is shown with a nine on it.
 */
extension PredictFit {

    static func offsetProfile(_ rows: [ShadowWindow], minEdge: Double, weight: Double) -> [OffsetReading] {
        func logit(_ p: Double) -> Double { log(p / (1 - p)) }

        var readings: [OffsetReading] = []
        for offset in PredictShadowBook.offsetBuckets {
            var returns: [Double] = []
            var looks = 0
            var modelLoss = 0.0
            var marketLoss = 0.0

            for row in rows {
                guard let resolved = row.resolved,
                      let s = row.samples.first(where: { $0.offset == offset }),
                      let market = s.pMarket, market > 0.001, market < 0.999 else { continue }
                looks += 1

                let outcome = resolved == .up ? 1.0 : 0.0
                let model = Analysis.clamp(s.pModel, 0.005, 0.995)
                modelLoss += (model - outcome) * (model - outcome)
                marketLoss += (market - outcome) * (market - outcome)

                let mixed = weight * logit(model) + (1 - weight) * logit(market)
                let pUp = Analysis.clamp(1 / (1 + exp(-mixed)), 0.005, 0.995)
                guard let best = PredictModel.cheaperSide(
                        pUp: pUp, upAsk: s.upAsk, downAsk: s.downAsk),
                      best.edge >= minEdge, best.ask > 0.01 else { continue }
                returns.append(best.side == resolved ? (1 / best.ask) - 1 : -1)
            }

            guard looks > 0 else { continue }
            readings.append(OffsetReading(
                offset: offset, samples: looks,
                edgeRate: Double(returns.count) / Double(looks),
                meanReturn: returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count),
                qualified: returns.count,
                modelBrier: modelLoss / Double(looks),
                marketBrier: marketLoss / Double(looks)))
        }
        return readings
    }
}

/* -------------------------------------------------------------- the journal */

/// Everything the Predict tab shows about the past, in one payload.
struct PredictJournalPayload: Codable {
    let runs: [PredictRun]
    let changes: [BrainChange]
    let brain: PredictBrain
    let score: PredictScore
    /// What each point in a window has been worth, with the count it stands on.
    let offsets: [OffsetReading]
    /// Resolved windows on record, and how many are still waiting on Polymarket.
    let windowsRecorded: Int
    let windowsResolved: Int
    let windowsDegraded: Int
}

/**
 * The archive on disk.
 *
 * Separate from `PredictShadowBook` because the two have different lifetimes and
 * different reasons to exist: the book is a rolling ten-day training set that
 * deliberately forgets, and this is a record that deliberately does not. Pooling
 * them would mean either throwing away run history to keep the book bounded or
 * keeping a month of samples to preserve a run summary.
 */
actor PredictJournal {
    static let shared = PredictJournal()

    /// Runs are small — settings, a tally and a handful of bets — so this is far
    /// more than anyone will read and still a trivial file.
    private static let retainRuns = 200
    /// Changes are rarer still, and the early ones are the interesting ones.
    private static let retainChanges = 500

    private var runs: [PredictRun] = []
    private var changes: [BrainChange] = []
    private var loaded = false

    private var directory: URL {
        Desk.dataDirectory.appendingPathComponent("predictions", isDirectory: true)
    }
    private var runsURL: URL { directory.appendingPathComponent("run-history.json") }
    private var changesURL: URL { directory.appendingPathComponent("brain-log.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: runsURL),
           let rows = try? JSONDecoder().decode([PredictRun].self, from: data) { runs = rows }
        if let data = try? Data(contentsOf: changesURL),
           let rows = try? JSONDecoder().decode([BrainChange].self, from: data) { changes = rows }
    }

    /* ---------------------------------------------------------------- writing */

    /**
     * Files a finished run, once.
     *
     * Idempotent on the run's id because there are three places a run can reach a
     * terminal state — the tick that notices a limit, an explicit end, and a new run
     * opening over a stale one — and all three call this rather than each trying to
     * work out whether one of the others already did.
     */
    func archive(_ run: PredictRun) {
        loadIfNeeded()
        guard run.status.isOver else { return }
        if let existing = runs.firstIndex(where: { $0.id == run.id }) {
            runs[existing] = run
        } else {
            runs.append(run)
        }
        runs.sort { $0.startedAt > $1.startedAt }
        if runs.count > PredictJournal.retainRuns { runs.removeLast(runs.count - PredictJournal.retainRuns) }
        write()
    }

    /**
     * Archived runs still carrying a bet the resolver had not published by the time
     * the run ended.
     *
     * Settlement only ever ran against the *current* run, so a bet placed in the
     * last minutes of a run was stranded the moment the next run opened over it —
     * no payout, no loss, `pnl` nil forever, and a P/L that quietly omitted a real
     * position. One such bet is sitting in this file from 20 September. The desk
     * sweeps this list on a timer and re-files whatever the resolver has caught up
     * on; the runs come back by value, so a caller settles a copy and archives it.
     */
    func unsettled(newerThan cutoff: Double) -> [PredictRun] {
        loadIfNeeded()
        return runs.filter { run in
            run.bets.contains { $0.pnl == nil && $0.window.endMs > cutoff }
        }
    }

    /// Records whichever of the three parameters actually moved between two fits.
    func note(from old: PredictBrain, to new: PredictBrain) {
        loadIfNeeded()
        var added = false

        func record(_ parameter: BrainChange.Parameter, _ from: Double, _ to: Double,
                    _ evidence: Int, _ wasDefault: Bool, _ isDefault: Bool) {
            // A hair of movement in a continuously re-fitted number is not a change of
            // mind, and a log full of them would bury the ones that are.
            guard abs(to - from) > 1e-6 else { return }
            let note: String
            if wasDefault && !isDefault {
                note = "First measurement — until now this was the value the app shipped with, "
                    + "held there because \(evidence) resolved windows was not enough to have an opinion of its own."
            } else if !wasDefault && isDefault {
                note = "Fell back to the shipped default: the evidence stopped supporting a measured value."
            } else {
                note = "Re-fitted on \(evidence) resolved windows."
            }
            changes.append(BrainChange(
                at: nowMs(), parameter: parameter, from: from, to: to,
                evidence: evidence, firstMeasurement: wasDefault && !isDefault, note: note))
            added = true
        }

        record(.feedNoise, old.feedNoiseBps, new.feedNoiseBps,
               new.feedWindows, old.feedIsDefault, new.feedIsDefault)
        record(.modelWeight, old.modelWeight * 100, new.modelWeight * 100,
               new.weightWindows, old.weightIsDefault, new.weightIsDefault)
        record(.entryOffset, old.entryOffsetSeconds, new.entryOffsetSeconds,
               new.offsetSamples, old.offsetIsDefault, new.offsetIsDefault)

        guard added else { return }
        changes.sort { $0.at > $1.at }
        if changes.count > PredictJournal.retainChanges {
            changes.removeLast(changes.count - PredictJournal.retainChanges)
        }
        for change in changes.prefix(3) where change.at > nowMs() - 5_000 {
            log("[predict] \(change.parameter.label): \(f(change.from, 2)) → \(f(change.to, 2))"
                + "\(change.parameter.unit) on \(change.evidence) windows")
        }
        write()
    }

    private func write() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(runs) { atomically(data, to: runsURL) }
        if let data = try? encoder.encode(changes) { atomically(data, to: changesURL) }
    }

    private func atomically(_ data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url)
        }
    }

    /* ---------------------------------------------------------------- reading */

    func payload(brain: PredictBrain, score: PredictScore, offsets: [OffsetReading],
                 recorded: Int, resolved: Int, degraded: Int) -> PredictJournalPayload {
        loadIfNeeded()
        return PredictJournalPayload(
            runs: runs, changes: changes, brain: brain, score: score, offsets: offsets,
            windowsRecorded: recorded, windowsResolved: resolved, windowsDegraded: degraded)
    }

    /// `--selftest` only.
    func loadForTesting(runs: [PredictRun], changes: [BrainChange]) {
        loaded = true
        self.runs = runs
        self.changes = changes
    }
}
