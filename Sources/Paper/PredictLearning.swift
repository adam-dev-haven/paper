/**
 * PredictLearning.swift — the shadow book, and the three numbers fitted from it.
 *
 * **The problem this solves.** Three constants decide whether the prediction desk
 * ever bets, and all three were judgements written into the source by hand:
 *
 *   `PredictFidelity.assumedBps` = 15    how far this app's feed is from the resolver
 *   `PredictModel.defaultMaxWeight` = 0.25  how much of a voice the model is allowed
 *   `entryOffsetSeconds` = 150           how far into a window to form a view
 *
 * The second one carries a comment admitting as much: *"the cap is a judgement
 * rather than a derivation … measuring it properly — Brier scores for the market's
 * price against the model's probability at the same offset, over resolved windows —
 * is the honest next step."* This file is that step, for all three.
 *
 * **Why a shadow book rather than a record of bets.** A run that bets nothing
 * learns nothing from its bets, and betting nothing is the normal outcome here —
 * a thirty-minute run over six windows correctly declined all six. But those six
 * windows were still *observed*: the model had a probability, the market had a
 * price, and five minutes later the world published an answer. That is a complete
 * training example whether or not money moved. So every window the desk looks at is
 * written down with what both parties thought at each point in it, and the answer
 * is filled in when it resolves. A desk that bets twice an hour still accumulates
 * twelve labelled examples an hour, which is the difference between a system that
 * improves over months and one that never has enough data to.
 *
 * **What is deliberately not learned.** Drift, momentum, time-of-day effects, and
 * anything else that would amount to fitting a directional signal to a few thousand
 * five-minute windows. The three parameters here are all measurements of *how much
 * to trust an existing model*, not attempts to build a better one, and that is a
 * much smaller hypothesis space with a much lower chance of fitting noise. The
 * moment this file starts predicting Bitcoin rather than calibrating a prediction
 * about it, it has become the thing the rest of the app exists to avoid.
 */

import Foundation

/* ------------------------------------------------------------ the shadow book */

/**
 * What both parties thought at one moment inside one window.
 *
 * Decoded by hand, like everything else that reaches disk. See the note at the
 * top of Portfolio.swift and `SchemaGate.swift`: the shadow book is the most
 * expensive file in this app to lose — ten days of continuous watching to
 * rebuild, reconstructible from nothing else — and a single field added to this
 * struct would have made the whole of it unreadable.
 */
struct ShadowSample: Codable {
    /// Seconds into the window, snapped to a fifteen-second bucket. Bucketed
    /// because the desk looks every three seconds inside the tradeable band and
    /// three hundred near-identical samples per window would be storage, not data.
    let offset: Double
    /// The model's own probability of Up, **before** the market was folded in. The
    /// unblended number is the only one that can be scored against the market,
    /// since the blended one already contains it.
    let pModel: Double
    /// The market's implied probability of Up, with the overround divided out.
    let pMarket: Double?
    let upAsk: Double?
    let downAsk: Double?
    /// What the tape said the window had done so far: projected TWAP against the
    /// open, in basis points. This is what the feed-noise fit is built from.
    let moveBps: Double

    init(offset: Double, pModel: Double, pMarket: Double?, upAsk: Double?,
         downAsk: Double?, moveBps: Double) {
        self.offset = offset; self.pModel = pModel; self.pMarket = pMarket
        self.upAsk = upAsk; self.downAsk = downAsk; self.moveBps = moveBps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The offset is what makes a sample a sample rather than a duplicate of
        // its neighbour, and it is the key the recorder deduplicates on.
        offset = try c.decode(Double.self, forKey: .offset)
        // An unknown probability is an even one, which is the reading that
        // contributes nothing to a fit rather than a reading that biases it.
        pModel = try c.decodeIfPresent(Double.self, forKey: .pModel) ?? 0.5
        pMarket = try c.decodeIfPresent(Double.self, forKey: .pMarket)
        upAsk = try c.decodeIfPresent(Double.self, forKey: .upAsk)
        downAsk = try c.decodeIfPresent(Double.self, forKey: .downAsk)
        moveBps = try c.decodeIfPresent(Double.self, forKey: .moveBps) ?? 0
    }
}

/// One window, everything seen inside it, and how it turned out.
struct ShadowWindow: Codable {
    let start: Double
    var samples: [ShadowSample]
    var resolved: PredictSide?
    var resolvedAt: Double?
    /**
     * Whether the live exchange feed was healthy while this window was recorded.
     *
     * Load-bearing for the fit rather than decorative. Windows recorded on the Yahoo
     * fallback carry a materially different feed error from windows recorded on a
     * three-venue median, and pooling them fits the average of two feeds — a number
     * that describes neither and is too pessimistic for the good one. Degraded
     * windows are kept for the record and excluded from every fit.
     */
    var degraded: Bool
    /// What the twelve windows before this one had been doing, measured at its open.
    /// Optional so a book written before cross-window features existed still opens,
    /// and so those windows are simply absent from that fit rather than poisoning it.
    var regime: RegimeFeatures?
    /// The definition of the open the samples were measured against. See
    /// `PredictModel.openRule`; absent means a window from before the stamp.
    var openRule: Int?

    /// The most complete read of the window: the latest sample taken, which had the
    /// most of the window in the books.
    var finalSample: ShadowSample? { samples.max { $0.offset < $1.offset } }

    /// Measured against the open the desk uses now, so its `pModel` and `moveBps`
    /// describe the model in force rather than a retired one.
    var isCurrentOpen: Bool { openRule == PredictModel.openRule }

    /// What every fit, the contest and the audit's replay read — defined once so
    /// they cannot quietly disagree about it.
    var isTrainable: Bool { resolved != nil && !degraded && isCurrentOpen }

    init(start: Double, samples: [ShadowSample], resolved: PredictSide?,
         resolvedAt: Double?, degraded: Bool, regime: RegimeFeatures?,
         openRule: Int? = PredictModel.openRule) {
        self.start = start; self.samples = samples; self.resolved = resolved
        self.resolvedAt = resolvedAt; self.degraded = degraded; self.regime = regime
        self.openRule = openRule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /* `start` is the window's identity — it is the Polymarket slug, the key
         * this is stored under and the thing an outcome is matched to. Its absence
         * means the row is not a window. Everything else defaults, because the
         * alternative is that adding one field to this struct destroys ten days of
         * accumulated evidence, which is the 2026-09-13 failure a third time. */
        start = try c.decode(Double.self, forKey: .start)
        samples = try c.decodeIfPresent([ShadowSample].self, forKey: .samples) ?? []
        resolved = try c.decodeIfPresent(PredictSide.self, forKey: .resolved)
        resolvedAt = try c.decodeIfPresent(Double.self, forKey: .resolvedAt)
        // A window whose feed health was not recorded is treated as degraded: it is
        // excluded from the fits rather than trusted, which is the conservative
        // reading and the one that cannot flatter a parameter.
        degraded = try c.decodeIfPresent(Bool.self, forKey: .degraded) ?? true
        regime = try c.decodeIfPresent(RegimeFeatures.self, forKey: .regime)
        // Absent means recorded before the stamp, which means the old open. Kept,
        // never fitted — the conservative reading, same as `degraded` above.
        openRule = try c.decodeIfPresent(Int.self, forKey: .openRule)
    }
}

/* ------------------------------------------------------------------ the brain */

/// The three fitted numbers, plus enough provenance to argue with them.
struct PredictBrain: Codable {
    var feedNoiseBps: Double
    var modelWeight: Double
    var entryOffsetSeconds: Double

    /// Resolved, non-degraded windows each fit is standing on.
    var feedWindows: Int
    var weightWindows: Int
    var offsetSamples: Int

    /// True while a parameter is still the shipped default because the evidence has
    /// not reached the threshold to move it.
    var feedIsDefault: Bool
    var weightIsDefault: Bool
    var offsetIsDefault: Bool

    var fittedAt: Double
    var summary: String

    /// The cross-window model. Optional for the same decoding reason as everything
    /// else that arrived late, and reached through `regime` so callers never have to
    /// think about a brain written before it existed.
    var regimeModel: RegimeModel?
    var regime: RegimeModel { regimeModel ?? .unlearned() }

    /* The thresholds, and why each is where it is. */

    /// Feed noise is a one-parameter fit and the live desk already does a
    /// twenty-four-window version of it. Thirty windows is where the persisted fit
    /// starts being the better of the two rather than a noisier duplicate.
    static let feedMinimum = 30
    /// Model weight is fitted by sweeping a blend over labelled outcomes. A hundred
    /// windows is roughly eight hours of continuous observation and is the point at
    /// which the Brier difference between two candidate weights stops being smaller
    /// than the standard error of the estimate.
    static let weightMinimum = 100
    /// Per bucket, not in total. Seventeen buckets are compared and the winner has
    /// to clear the field by more than a standard error, so each needs its own
    /// sample before the comparison means anything.
    static let offsetMinimumPerBucket = 40

    /// The ceiling chosen for this desk. The uncapped fit is reported in the summary
    /// when it lands above this, because a cap you cannot see is indistinguishable
    /// from a measurement.
    static let weightCeiling = 0.35

    init(feedNoiseBps: Double, modelWeight: Double, entryOffsetSeconds: Double,
         feedWindows: Int, weightWindows: Int, offsetSamples: Int,
         feedIsDefault: Bool, weightIsDefault: Bool, offsetIsDefault: Bool,
         fittedAt: Double, summary: String, regimeModel: RegimeModel?) {
        self.feedNoiseBps = feedNoiseBps; self.modelWeight = modelWeight
        self.entryOffsetSeconds = entryOffsetSeconds
        self.feedWindows = feedWindows; self.weightWindows = weightWindows
        self.offsetSamples = offsetSamples
        self.feedIsDefault = feedIsDefault; self.weightIsDefault = weightIsDefault
        self.offsetIsDefault = offsetIsDefault
        self.fittedAt = fittedAt; self.summary = summary; self.regimeModel = regimeModel
    }

    /**
     * Decoded by hand, defaulting to the unlearned brain field by field.
     *
     * Less costly to lose than the book — the brain is derived, and a refit
     * rebuilds it within a couple of minutes of the desk opening. But losing it
     * silently resets every fitted parameter to its shipped default while the
     * summary string still claims a measurement, which is worse than losing it
     * loudly, and there is no reason to accept either.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PredictBrain.unlearned()
        feedNoiseBps = try c.decodeIfPresent(Double.self, forKey: .feedNoiseBps) ?? d.feedNoiseBps
        modelWeight = try c.decodeIfPresent(Double.self, forKey: .modelWeight) ?? d.modelWeight
        entryOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .entryOffsetSeconds) ?? d.entryOffsetSeconds
        feedWindows = try c.decodeIfPresent(Int.self, forKey: .feedWindows) ?? 0
        weightWindows = try c.decodeIfPresent(Int.self, forKey: .weightWindows) ?? 0
        offsetSamples = try c.decodeIfPresent(Int.self, forKey: .offsetSamples) ?? 0
        // Defaulting these to true is the conservative read: a parameter whose
        // provenance the file does not state is treated as unproven rather than as
        // a measurement, so the interface does not claim evidence it cannot show.
        feedIsDefault = try c.decodeIfPresent(Bool.self, forKey: .feedIsDefault) ?? true
        weightIsDefault = try c.decodeIfPresent(Bool.self, forKey: .weightIsDefault) ?? true
        offsetIsDefault = try c.decodeIfPresent(Bool.self, forKey: .offsetIsDefault) ?? true
        fittedAt = try c.decodeIfPresent(Double.self, forKey: .fittedAt) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? d.summary
        regimeModel = try c.decodeIfPresent(RegimeModel.self, forKey: .regimeModel)
    }

    static func unlearned() -> PredictBrain {
        PredictBrain(
            feedNoiseBps: PredictFidelity.assumedBps,
            modelWeight: PredictModel.defaultMaxWeight,
            entryOffsetSeconds: 90,
            feedWindows: 0, weightWindows: 0, offsetSamples: 0,
            feedIsDefault: true, weightIsDefault: true, offsetIsDefault: true,
            fittedAt: 0,
            summary: "Nothing has been learned yet. The desk is running on its shipped defaults: "
                + "a \(f(PredictFidelity.assumedBps, 0)) basis point feed gap, "
                + "\(f(PredictModel.defaultMaxWeight * 100, 0))% maximum model weight, and a 90-second entry. "
                + "Every window it watches from now on is written down and the three will be re-fitted as answers arrive.",
            regimeModel: nil)
    }
}

/* ------------------------------------------------------------------ the store */

/**
 * The book on disk, and the fits over it.
 *
 * An actor because the desk is one and both of them are touched from a detached
 * loop. Saves are debounced to once every thirty seconds: the desk records a sample
 * every three seconds inside a window and writing a few thousand windows to disk
 * that often would be the most expensive thing the feature does, to protect data
 * that is regenerated within minutes if lost.
 */
actor PredictShadowBook {
    static let shared = PredictShadowBook()

    /// Ten days of continuous observation at twelve windows an hour. Past this the
    /// oldest windows are dropped: the three fits all describe *current* market
    /// microstructure, and a month-old window is not evidence about this one.
    private static let retainWindows = 3_000

    private static let bucketSeconds: Double = 15
    /// The offsets the entry-offset fit compares. Below thirty seconds nothing is
    /// settled; past two hundred and seventy the cutoff has already refused it.
    static let offsetBuckets: [Double] = stride(from: 30.0, through: 270.0, by: 15.0).map { $0 }

    private var windows: [Double: ShadowWindow] = [:]
    private var brain = PredictBrain.unlearned()
    /**
     * The reading currently in force.
     *
     * Separate from `brain` on purpose. The brain holds three numbers fitted from
     * the book; the policy holds a whole *reading* that won a contest against the
     * market. The brain can only ever turn one model's volume up or down, which is
     * how it ended up at zero with no way back; the policy is what lets the desk
     * change its mind about what to read in the first place.
     */
    private var policy = PredictPolicy.market()
    /**
     * Bets that have settled, and what they actually paid.
     *
     * Kept here rather than only in the run history because this is the file the
     * learning reads, and until now nothing in the learning read the bets at all.
     * Every fitted return in this system rests on the assumption that a contract
     * can be bought at the best ask; these are the observations that test it.
     */
    private var settled: [SettledBet] = []
    private var loaded = false
    private var dirty = false
    private var lastSaveAt: Double = 0
    private var lastFitAt: Double = 0
    private var lastContestAt: Double = 0
    /// Set when the book on disk existed and could not be read. While it is set
    /// nothing is written, for the reason the ledger gives: an unreadable file is
    /// a thing to show someone, not a thing to solve by overwriting the evidence.
    private(set) var readOnly: String?

    private var directory: URL {
        Desk.dataDirectory.appendingPathComponent("predictions", isDirectory: true)
    }
    private var bookURL: URL { directory.appendingPathComponent("shadow-book.json") }
    private var brainURL: URL { directory.appendingPathComponent("brain.json") }
    private var policyURL: URL { directory.appendingPathComponent("policy.json") }
    private var betsURL: URL { directory.appendingPathComponent("settled-bets.json") }

    /* --------------------------------------------------------------- loading */

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        /* The book, and the refusal.
         *
         * Tolerant decoders mean a book written by an older build reads. They do
         * not mean a *corrupt* one does, and the old path answered that case by
         * leaving `windows` empty and letting the next flush write the emptiness
         * over ten days of accumulated evidence — the 2026-09-13 ledger failure,
         * third instance, on the one file in this app that cannot be
         * reconstructed from anything else. So an unreadable book is quarantined,
         * left exactly where it is, and the store goes read-only. */
        if let data = try? Data(contentsOf: bookURL) {
            do {
                for row in try JSONDecoder().decode([ShadowWindow].self, from: data) {
                    windows[row.start] = row
                }
            } catch {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let aside = directory.appendingPathComponent("shadow-book.unreadable-\(stamp).json")
                try? data.write(to: aside)
                readOnly = "The shadow book could not be read, so nothing will be written to it and no "
                    + "parameter will be re-fitted. The file has not been changed and a copy is at "
                    + "\(aside.lastPathComponent). Reason: \(error)"
                log("[predict] REFUSING TO WRITE the shadow book: \(error)", .error, "predict")
                log("[predict] the file is untouched; a copy is at \(aside.path)", .error, "predict")
            }
        }
        if let data = try? Data(contentsOf: brainURL),
           let stored = try? JSONDecoder().decode(PredictBrain.self, from: data) {
            brain = stored
        }
        if let data = try? Data(contentsOf: policyURL),
           let stored = try? JSONDecoder().decode(PredictPolicy.self, from: data) {
            policy = stored
        }
        if let data = try? Data(contentsOf: betsURL),
           let stored = try? JSONDecoder().decode([SettledBet].self, from: data) {
            settled = stored
        }
        if !windows.isEmpty {
            log("[predict] shadow book: \(windows.count) windows, "
                + "\(windows.values.filter { $0.resolved != nil }.count) resolved")
        }
    }

    /// The fitted parameters, loading the book on first use.
    func parameters() -> PredictBrain {
        loadIfNeeded()
        return brain
    }

    /* -------------------------------------------------------------- recording */

    /**
     * Writes down what the desk saw, at most one sample per fifteen-second bucket
     * per window.
     *
     * First-in wins within a bucket rather than last. The fits ask what was knowable
     * *at* an offset, and a sample taken at 62 seconds is a more honest answer to
     * "what did the desk know at 60" than one taken at 74.
     */
    func record(window: PredictWindow, forecast: PredictForecast,
                books: (up: PredictBook?, down: PredictBook?), degraded: Bool,
                regime: RegimeFeatures? = nil) {
        loadIfNeeded()
        let bucket = (forecast.elapsed / PredictShadowBook.bucketSeconds).rounded(.down)
            * PredictShadowBook.bucketSeconds
        guard bucket >= PredictShadowBook.offsetBuckets.first!,
              bucket <= PredictShadowBook.offsetBuckets.last! else { return }

        var row = windows[window.start]
            ?? ShadowWindow(start: window.start, samples: [], resolved: nil,
                            resolvedAt: nil, degraded: degraded, regime: regime)
        // Measured at the window's open and constant within it, so the first reading
        // is the one kept — a later one would be describing a window that has since
        // started moving, which is the path model's job and not this one's.
        if row.regime == nil { row.regime = regime }
        // A window that spent any of its life on the fallback feed is degraded for
        // the whole of it: the samples are pooled per window by the fits, and half a
        // window of Yahoo is enough to move the feed-noise estimate it contributes.
        row.degraded = row.degraded || degraded
        guard !row.samples.contains(where: { $0.offset == bucket }) else { return }

        row.samples.append(ShadowSample(
            offset: bucket,
            pModel: forecast.pModel,
            pMarket: PredictModel.implied(up: books.up, down: books.down),
            upAsk: books.up?.bestAsk,
            downAsk: books.down?.bestAsk,
            moveBps: forecast.signalBps))
        windows[window.start] = row
        dirty = true
    }

    /// Fills in an answer. Called as resolutions arrive, from the pass the desk
    /// already makes over recent markets — no extra requests are spent on this.
    func resolve(start: Double, side: PredictSide) {
        loadIfNeeded()
        guard var row = windows[start], row.resolved == nil else { return }
        row.resolved = side
        row.resolvedAt = nowMs()
        windows[start] = row
        dirty = true
    }

    /// Windows still waiting for an answer, oldest first, so the desk knows which
    /// resolutions are worth asking about.
    func unresolved(olderThan ms: Double) -> [Double] {
        loadIfNeeded()
        return windows.values
            .filter { $0.resolved == nil && $0.start * 1000 + 300_000 < ms }
            .map(\.start)
            .sorted()
    }

    /* ------------------------------------------------------------ persistence */

    func flush(force: Bool = false) {
        loadIfNeeded()
        guard readOnly == nil else { return }
        guard dirty, force || nowMs() - lastSaveAt > 30_000 else { return }
        lastSaveAt = nowMs()
        dirty = false

        if windows.count > PredictShadowBook.retainWindows {
            let keep = windows.keys.sorted().suffix(PredictShadowBook.retainWindows)
            let kept = Set(keep)
            windows = windows.filter { kept.contains($0.key) }
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = windows.values.sorted { $0.start < $1.start }
        if let data = try? encoder.encode(rows) { atomically(data, to: bookURL) }
        if let data = try? encoder.encode(brain) { atomically(data, to: brainURL) }
        if let data = try? encoder.encode(policy) { atomically(data, to: policyURL) }
        // The last thousand settled bets. The fidelity check needs a recent sample,
        // not the whole history, and the run journal keeps the full record anyway.
        if let data = try? encoder.encode(Array(settled.suffix(1_000))) { atomically(data, to: betsURL) }
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

    /* ------------------------------------------------------------------ fitting */

    /// Re-fits all three, at most once every two minutes. Cheap — a few thousand
    /// windows and a couple of one-dimensional sweeps — but not free, and nothing
    /// it reads changes faster than one window per five minutes.
    @discardableResult
    func refit(force: Bool = false) async -> PredictBrain {
        loadIfNeeded()
        guard force || nowMs() - lastFitAt > 120_000 else { return brain }
        lastFitAt = nowMs()

        let previous = brain
        let usable = trainingSet()
        let feed = PredictFit.feedNoise(usable)
        let weight = PredictFit.modelWeight(usable)
        let offset = PredictFit.entryOffset(usable, weight: weight.value)
        // Fitted on every resolved window rather than only undegraded ones: the
        // features come from the tape's shape rather than from its absolute accuracy,
        // and a window recorded on the fallback feed still had twelve real windows
        // before it. The outcomes are the resolver's either way.
        let regime = PredictFit.regime(windows.values.filter { $0.resolved != nil })

        var summary = ""
        summary += feed.isDefault
            ? "Feed gap still assumed at \(f(feed.bps, 0)) bps — \(usable.count) resolved windows on record against the \(PredictBrain.feedMinimum) this fit asks for. "
            : "Feed gap fitted at \(f(feed.bps, 1)) bps across \(feed.windows) resolved windows. "
        summary += weight.isDefault
            ? "Model weight held at the shipped \(f(PredictModel.defaultMaxWeight * 100, 0))%, which needs \(PredictBrain.weightMinimum) windows to move. "
            : "Model weight fitted at \(f(weight.value * 100, 1))% by Brier score over \(weight.windows) windows"
              + (weight.capped ? ", capped down from \(f(weight.raw * 100, 1))%. " : ". ")
        summary += offset.isDefault
            ? "Entry offset left where it was set: no offset bucket beat the field by more than its own standard error."
            : "Entry at \(f(offset.value, 0))s, which returned \(f(offset.meanReturn * 100, 1))% a dollar staked over \(offset.samples) qualifying looks — \(f(offset.edgeOverField * 100, 1)) points better than the average bucket."

        brain = PredictBrain(
            feedNoiseBps: feed.bps,
            modelWeight: weight.value,
            entryOffsetSeconds: offset.isDefault ? brain.entryOffsetSeconds : offset.value,
            feedWindows: feed.windows,
            weightWindows: weight.windows,
            offsetSamples: offset.samples,
            feedIsDefault: feed.isDefault,
            weightIsDefault: weight.isDefault,
            offsetIsDefault: offset.isDefault,
            fittedAt: nowMs(),
            summary: summary,
            regimeModel: regime)
        dirty = true
        flush(force: true)
        // Only the moves are logged, and only once each. A re-fit that changed
        // nothing writes nothing, so the log is a record of the desk revising its
        // mind rather than a record of it thinking.
        await PredictJournal.shared.note(from: previous, to: brain)
        return brain
    }

    /* ------------------------------------------------------------ the read-outs */

    /// Resolved, undegraded windows recorded under the current open — the training
    /// set every fit and the scoreboard all read. See `ShadowWindow.isTrainable`.
    func trainingSet() -> [ShadowWindow] {
        loadIfNeeded()
        return windows.values.filter(\.isTrainable)
    }

    /// How much is on record, and how much of it is usable. The gap between the
    /// three is worth showing: windows still waiting on Polymarket's resolver are
    /// not lost, and degraded ones are kept but never fitted.
    func counts() -> (recorded: Int, resolved: Int, degraded: Int) {
        loadIfNeeded()
        return (windows.count,
                windows.values.filter { $0.resolved != nil }.count,
                windows.values.filter(\.degraded).count)
    }

    /* ------------------------------------------------------------- the policy */

    /// The reading in force. What the desk should use to turn a window into a
    /// probability.
    func currentPolicy() -> PredictPolicy {
        loadIfNeeded()
        return policy
    }

    /// Settled bets, for the fidelity check.
    func settledBets() -> [SettledBet] {
        loadIfNeeded()
        return settled
    }

    /**
     * Records what a bet actually cost against what the rehearsal assumed.
     *
     * `expected` is the best offer the decision was taken against — the price the
     * shadow book scores every hypothetical return at — and `filled` is the
     * volume-weighted average actually paid after walking the book. The gap
     * between them is the only measurement in this system that can catch the
     * rehearsal being wrong about the *world* rather than about the model, and
     * nothing was taking it. On the 4.14.0 stake-cap failure it would have read
     * four hundred percent on the first bet rather than the sixth.
     */
    func recordSettled(_ bet: SettledBet) {
        loadIfNeeded()
        settled.append(bet)
        if settled.count > 2_000 { settled.removeFirst(settled.count - 2_000) }
        dirty = true
    }

    /**
     * Re-runs the candidate contest and adopts the winner.
     *
     * Hourly rather than every two minutes like `refit`. A contest fits six
     * logistic models five times each over the whole book, which is real work, and
     * nothing it reads changes faster than one window per five minutes. Promotion
     * and demotion are both logged and both journalled, because a desk quietly
     * changing how it reads the market is precisely the thing a person needs told.
     */
    @discardableResult
    func runContest(force: Bool = false) -> (policy: PredictPolicy, results: [CandidateResult]) {
        loadIfNeeded()
        guard force || nowMs() - lastContestAt > 3_600_000 else { return (policy, []) }
        lastContestAt = nowMs()

        let (settledPolicy, results, changed) = PredictLearner.settle(
            trainingSet(), champion: policy)
        guard changed else { return (policy, results) }

        let was = policy.isDefault ? "the market price alone" : policy.candidateId
        policy = settledPolicy
        dirty = true
        flush(force: true)
        log("[predict] reading changed: \(was) -> "
            + "\(settledPolicy.isDefault ? "the market price alone" : settledPolicy.candidateId). "
            + settledPolicy.summary, .warn, "predict")
        return (policy, results)
    }

    /// The whole audit, over everything this actor holds.
    func audit(minEdge: Double) -> PredictAuditReport {
        loadIfNeeded()
        return PredictAudit.run(book: Array(windows.values), brain: brain,
                                policy: policy, bets: settled, minEdge: minEdge)
    }

}

/* --------------------------------------------------------------- the fitting */

/**
 * The three fits, as pure functions over a book.
 *
 * Deliberately not methods on the actor. Nothing here touches disk, the clock or
 * the network — each one is a sweep over an array that returns a number — and
 * actor isolation would make the most important arithmetic in this file reachable
 * only from an `await`, which is to say only from code that has a running desk.
 * These are the parts most worth testing against books whose right answer is known
 * by construction, and `--selftest` is synchronous.
 */
enum PredictFit {
/* ------------------------------------------------------- fit 1: feed noise */

/**
 * How far this app's tape is from the feed the market settles on.
 *
 * Identical in form to `PredictFidelity.fit` and different in reach: that one
 * sees the last twenty-four windows and re-fits them every four minutes, which
 * is the right thing for a live reading and a small sample for a parameter. This
 * one stands on the whole book.
 *
 * Model the discrepancy as `ε ~ Normal(0, σ²)`. A window whose tape said the
 * move was `m` basis points then agrees with the published answer with
 * probability `Φ(|m| / σ)` — near-ties disagree often, decisive moves rarely —
 * and the whole history is a one-parameter likelihood in `σ`. Swept rather than
 * solved because the likelihood is cheap and the sweep cannot land on a local
 * optimum the way a Newton step can.
 */
static func feedNoise(_ rows: [ShadowWindow])
    -> (bps: Double, windows: Int, isDefault: Bool) {
    let samples: [(moveBps: Double, agreed: Bool)] = rows.compactMap { row in
        guard let resolved = row.resolved, let final = row.finalSample,
              final.moveBps.isFinite else { return nil }
        let tapeSaid: PredictSide = final.moveBps >= 0 ? .up : .down
        return (final.moveBps, tapeSaid == resolved)
    }
    guard samples.count >= PredictBrain.feedMinimum else {
        return (PredictFidelity.assumedBps, samples.count, true)
    }

    func logLikelihood(_ sigma: Double) -> Double {
        samples.reduce(0) { total, s in
            let p = Analysis.clamp(PredictModel.normalCDF(abs(s.moveBps) / sigma), 1e-9, 1 - 1e-9)
            return total + log(s.agreed ? p : 1 - p)
        }
    }

    var scores: [(sigma: Double, score: Double)] = []
    var sigma = absoluteFloorBps
    while sigma <= PredictFidelity.ceilingBps {
        scores.append((sigma, logLikelihood(sigma)))
        sigma += 0.25
    }
    guard let peak = scores.max(by: { $0.score < $1.score }) else {
        return (PredictFidelity.assumedBps, samples.count, true)
    }

    /* **The operating value is the upper edge of the likelihood interval, not the
     * peak**, and that choice is what let the hardcoded floor go.
     *
     * `PredictFidelity.fit` — the twenty-four-window live version of this — clamps
     * its answer at four basis points, with the reasoning that a small sample
     * cannot honestly claim the two feeds are nearly identical, and that being
     * wrong about this in the confident direction is the expensive mistake. Both
     * halves of that are right and the fix for it was a constant, which is only
     * correct at one sample size. The live probe showed it binding: with a
     * three-venue median tape the fit wanted to go below four, and a floor written
     * for a polled Yahoo feed was the thing stopping the whole feed change from
     * showing up in the number that scales the model.
     *
     * So the conservatism is expressed as what it actually is — uncertainty about
     * `σ` — by taking the largest `σ` whose log-likelihood is within half a unit of
     * the maximum, which is the one-standard-error edge of a one-parameter
     * likelihood interval. On thirty windows that interval is wide and the answer
     * comes back close to the old floor on its own; on three thousand it is tight
     * and the answer converges on the peak. The behaviour the constant was
     * protecting is kept, and it now scales with the evidence instead of with a
     * guess about how much evidence there will be.
     */
    let edge = scores.filter { $0.score >= peak.score - 0.5 }.map(\.sigma).max() ?? peak.sigma
    return (Swift.max(absoluteFloorBps, edge), samples.count, false)
}

/// No feed is identical to another one: there is always latency, and always a tick
/// of disagreement about what the last price was. A basis point is the smallest
/// claim this is willing to make, however much evidence turns up.
static let absoluteFloorBps: Double = 1.0

/* ----------------------------------------------------- fit 2: model weight */

/**
 * How much of a voice the model has earned against the market.
 *
 * The blend is `σ(w·logit(pModel) + (1−w)·logit(pMarket))`, and `w` is swept
 * from zero to the ceiling, scoring each candidate by Brier — mean squared
 * error against the published outcome — over every sample in every resolved
 * window. The weight that scores best is the weight at which the model's opinion
 * has actually been adding information rather than noise. At `w = 0` the score
 * is the market's own Brier, which is the benchmark: a fitted weight of zero is
 * the honest finding that the model never helped.
 *
 * **Every offset is pooled deliberately.** Fitting a separate weight per offset
 * would be seventeen parameters over the same data, and the formula it is
 * replacing already varies with offset on its own — `pathVar/(pathVar+feedVar)`
 * falls as a window runs out, and this number is only its *ceiling*. What is
 * being fitted here is how high that ceiling should be, which is one number.
 *
 * The cap is applied after the fit, not during, so the summary can report what
 * the unconstrained answer was. A cap that hides the number it is capping is
 * indistinguishable from a measurement.
 */
static func modelWeight(_ rows: [ShadowWindow])
    -> (value: Double, raw: Double, windows: Int, capped: Bool, isDefault: Bool) {

    var scored: [(pModel: Double, pMarket: Double, up: Bool)] = []
    for row in rows {
        guard let resolved = row.resolved else { continue }
        for s in row.samples {
            guard let pMarket = s.pMarket, pMarket > 0.001, pMarket < 0.999 else { continue }
            scored.append((Analysis.clamp(s.pModel, 0.005, 0.995), pMarket, resolved == .up))
        }
    }
    let windowCount = rows.filter { $0.resolved != nil && !$0.samples.isEmpty }.count
    guard windowCount >= PredictBrain.weightMinimum, !scored.isEmpty else {
        return (PredictModel.defaultMaxWeight, PredictModel.defaultMaxWeight,
                windowCount, false, true)
    }

    func logit(_ p: Double) -> Double { log(p / (1 - p)) }
    func brier(_ w: Double) -> Double {
        scored.reduce(0) { total, s in
            let mixed = w * logit(s.pModel) + (1 - w) * logit(s.pMarket)
            let p = 1 / (1 + exp(-mixed))
            let outcome = s.up ? 1.0 : 0.0
            return total + (p - outcome) * (p - outcome)
        } / Double(scored.count)
    }

    var best = 0.0
    var bestScore = Double.infinity
    var w = 0.0
    // Swept past the ceiling on purpose: the cap is a risk decision and the fit
    // is a measurement, and reporting "the data wanted 48% and it was held to
    // 35%" is more useful than a number that stops at the cap by construction.
    while w <= 0.60 {
        let score = brier(w)
        if score < bestScore { bestScore = score; best = w }
        w += 0.01
    }
    let capped = Swift.min(best, PredictBrain.weightCeiling)
    return (capped, best, windowCount, best > PredictBrain.weightCeiling, false)
}

/* ---------------------------------------------------- fit 3: entry offset */

/**
 * Which point in a window has actually been worth entering at.
 *
 * For each fifteen-second bucket, replay every sample in it: blend at the
 * learned weight, take the cheaper side, and if the edge would have cleared five
 * cents, score what that contract actually returned — `1/ask − 1` when the side
 * was right, `−1` when it was not. The bucket's score is the mean return per
 * dollar staked across its qualifying looks.
 *
 * **The multiple-comparison guard is the point of the last clause.** Seventeen
 * buckets are being compared and the best of seventeen noisy means is high by
 * construction — with no real effect at all, the winner still beats the field by
 * roughly the standard error every time. So the winner has to beat the field
 * average by more than one standard error of its own mean before it is allowed
 * to move anything, and otherwise the offset stays where the user set it. That
 * check is why this can report "no bucket won" rather than always having an
 * answer, and a fit that can never fail to find something is not a fit.
 */
static func entryOffset(_ rows: [ShadowWindow], weight: Double)
    -> (value: Double, meanReturn: Double, edgeOverField: Double, samples: Int, isDefault: Bool) {

    func logit(_ p: Double) -> Double { log(p / (1 - p)) }

    var returnsByBucket: [Double: [Double]] = [:]
    for row in rows {
        guard let resolved = row.resolved else { continue }
        for s in row.samples {
            guard let pMarket = s.pMarket, pMarket > 0.001, pMarket < 0.999 else { continue }
            let mixed = weight * logit(Analysis.clamp(s.pModel, 0.005, 0.995))
                + (1 - weight) * logit(pMarket)
            let pUp = Analysis.clamp(1 / (1 + exp(-mixed)), 0.005, 0.995)
            guard let best = PredictModel.cheaperSide(
                    pUp: pUp, upAsk: s.upAsk, downAsk: s.downAsk),
                  best.edge >= 0.05, best.ask > 0.01 else { continue }
            let won = best.side == resolved
            returnsByBucket[s.offset, default: []].append(won ? (1 / best.ask) - 1 : -1)
        }
    }

    let eligible = returnsByBucket.filter { $0.value.count >= PredictBrain.offsetMinimumPerBucket }
    guard eligible.count >= 2 else {
        return (0, 0, 0, returnsByBucket.values.reduce(0) { $0 + $1.count }, true)
    }

    func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
    let means = eligible.mapValues(mean)
    guard let winner = means.max(by: { $0.value < $1.value }),
          let sample = eligible[winner.key] else {
        return (0, 0, 0, 0, true)
    }

    let field = mean(Array(means.values))
    let variance = sample.reduce(0) { $0 + pow($1 - winner.value, 2) } / Double(Swift.max(1, sample.count - 1))
    let standardError = sqrt(variance / Double(sample.count))
    let advantage = winner.value - field

    guard advantage > standardError else {
        return (winner.key, winner.value, advantage, sample.count, true)
    }
    return (winner.key, winner.value, advantage, sample.count, false)
}
}
