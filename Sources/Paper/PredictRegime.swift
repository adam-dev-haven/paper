/**
 * PredictRegime.swift — what the windows *before* this one have to say about it.
 *
 * **The rule this is in tension with, stated first.** `PredictModel.forecast` sets
 * the drift of the remaining path to zero, on purpose, with a comment that says
 * why: *"five-minute Bitcoin drift is not estimable from twenty minutes of data,
 * and every attempt to put it in is momentum-chasing wearing a statistics
 * costume."* That is correct, and it is exactly the trap that "there was a big rise
 * for a few runs and then it dropped, learn from that" walks into. Three Ups in a
 * row is the single most seductive pattern in any market and it is, on almost every
 * sample anyone has ever looked at, worth nothing.
 *
 * So this does not hand-code the pattern. It measures five cheap descriptions of
 * the recent past, fits them against what actually happened, and **scores the fit
 * out of sample against the same model with the features switched off**. If they
 * carry no information the fit lands on zero and the desk behaves exactly as it did
 * before — which is the outcome the null hypothesis predicts and the one this is
 * built to be able to report. Nothing here is used until it has beaten doing
 * nothing, on windows it was not fitted on.
 *
 * **What it buys when it does work**, and the reason it is worth building at all:
 * every one of these features is known at the *opening bell* of a window. The path
 * model has nothing to say until the window has run — that is what the entry offset
 * is for, and why the model is at its loudest early and its most informed late. A
 * regime reading is available at second zero. It is the only part of this system
 * that can form a view before the window has done anything.
 */

import Foundation

/* ----------------------------------------------------------- the features */

/**
 * Five readings of the recent past, all available before the window has moved.
 *
 * Five and not fifteen. Every feature added to a logistic fit on a few hundred
 * windows buys a little fit and a lot of variance, and the honest number of things
 * worth asking of an hour of five-minute bars is small. These five are chosen to
 * describe different shapes — level, trend, persistence, turn, and regime — rather
 * than five flavours of momentum, which would be one feature wearing five hats and
 * would fit beautifully in sample.
 *
 * All of them are normalised by the current volatility, so a 20-basis-point drift
 * in a calm hour and a 20-basis-point drift in a violent one are not read as the
 * same thing. Everything is clamped: one outlier window should move a coefficient,
 * not decide it.
 */
struct RegimeFeatures: Codable {
    /// Consecutive windows that moved the same way, signed, capped at ±5. The
    /// pattern everyone sees and almost nobody profits from — here so the fit can
    /// say so with a number instead of an opinion.
    let run: Double
    /// The last twelve windows' moves summed, in standard deviations of an hour.
    /// Level and direction of the recent stretch.
    let drift: Double
    /// The previous window alone, in standard deviations of a window.
    let last: Double
    /// Twenty-minute volatility against ninety-minute, logged. Positive means the
    /// market has just sped up — the "and then it drops" half of the question, which
    /// is a change in regime rather than a change in direction.
    let volShift: Double
    /// +1 when the last two windows disagreed in sign, −1 when they agreed. A turn
    /// is a different event from a trend and gets its own coefficient.
    let reversal: Double

    init(run: Double, drift: Double, last: Double, volShift: Double, reversal: Double) {
        self.run = run; self.drift = drift; self.last = last
        self.volShift = volShift; self.reversal = reversal
    }

    /**
     * Decoded by hand, and every feature defaults to zero.
     *
     * Zero is the right default rather than a convenient one: these are all
     * normalised readings where zero means "nothing unusual", so a feature the
     * file predates contributes exactly nothing to the fit instead of biasing it.
     * The alternative — the synthesised decoder — makes a new feature destroy the
     * whole shadow book, since these sit inside it.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decodeIfPresent(Double.self, forKey: .run) ?? 0
        drift = try c.decodeIfPresent(Double.self, forKey: .drift) ?? 0
        last = try c.decodeIfPresent(Double.self, forKey: .last) ?? 0
        volShift = try c.decodeIfPresent(Double.self, forKey: .volShift) ?? 0
        reversal = try c.decodeIfPresent(Double.self, forKey: .reversal) ?? 0
    }

    static let names = ["Run of same-way windows", "Drift over the last hour",
                        "The window just gone", "Volatility shift", "Just reversed"]

    var vector: [Double] { [run, drift, last, volShift, reversal] }

    /**
     * Measures the run-up to a window, from the tape alone.
     *
     * **From the tape rather than from published resolutions**, which matters more
     * than it sounds. Polymarket's resolver runs five to ten minutes behind the
     * bell, so the one or two windows immediately before this one routinely have no
     * published answer yet — and those are the two that a "what just happened"
     * feature most needs. Reading the tape's own verdict instead means the features
     * are always available at the opening bell, at the cost of being the app's
     * reading rather than the resolver's. That cost is already measured and already
     * in the model: it is `feedSd`, and the fit below is scored against outcomes
     * that came from the resolver, so any systematic gap between the two is
     * something the coefficients absorb rather than something that biases them.
     */
    static func measure(tape: BtcTape, window: PredictWindow, minuteVol: Double) -> RegimeFeatures? {
        let perWindow = minuteVol * sqrt(5.0)
        guard perWindow > 0, perWindow.isFinite else { return nil }

        // Newest first. Stops at the first window the tape cannot cover rather than
        // skipping it, because a gap in the middle of a run makes "consecutive"
        // meaningless and a shorter honest history is better than a longer invented one.
        var moves: [Double] = []
        for n in 1...12 {
            let prior = window.previous(n)
            guard let open = tape.price(at: prior.startMs), open > 0,
                  let twap = tape.twap(from: prior.startMs, to: prior.endMs) else { break }
            moves.append((twap - open) / open)
        }
        guard moves.count >= 6 else { return nil }

        func clamp(_ x: Double) -> Double { Analysis.clamp(x, -4, 4) }

        var runLength = 0.0
        if let first = moves.first, first != 0 {
            let sign = first > 0 ? 1.0 : -1.0
            for move in moves {
                guard move != 0, (move > 0 ? 1.0 : -1.0) == sign else { break }
                runLength += 1
            }
            runLength = Swift.min(runLength, 5) * sign
        }

        let total = moves.reduce(0, +)
        let drift = clamp(total / (perWindow * sqrt(Double(moves.count))))
        let last = clamp((moves.first ?? 0) / perWindow)

        let short = tape.minuteVol(lookbackMs: 20 * 60_000) ?? minuteVol
        let long = tape.minuteVol(lookbackMs: 90 * 60_000) ?? minuteVol
        let volShift = clamp(long > 0 ? log(short / long) : 0)

        let reversal: Double = moves.count >= 2
            ? ((moves[0] >= 0) == (moves[1] >= 0) ? -1 : 1) : 0

        return RegimeFeatures(run: runLength, drift: drift, last: last,
                              volShift: volShift, reversal: reversal)
    }
}

/* -------------------------------------------------------------- the model */

/// One coefficient, in a form that can be put on a screen.
struct FeatureReading: Codable {
    let name: String
    /// The fitted coefficient, on standardised features, so they are comparable.
    let weight: Double
    /// What it is saying right now, given the current reading.
    let contribution: Double
}

/**
 * The fitted cross-window model, and — as much as the numbers themselves — the
 * record of whether it was allowed to do anything.
 *
 * `kappa` is the whole safety story. It is the share of the fitted signal that
 * survived being tested on windows it was not fitted on, swept by cross-validated
 * log loss, and it is zero whenever the features failed to beat an intercept. A
 * zero here is not a failure of the code; it is the code reporting the most likely
 * truth about five-minute crypto, and it leaves the desk behaving exactly as it did
 * before this file existed.
 */
struct RegimeModel: Codable {
    let weights: [Double]
    /// Feature means and deviations from the training set, kept so that inference
    /// standardises the same way the fit did. Getting this wrong is silent: the
    /// model keeps producing plausible numbers from a different scale.
    let means: [Double]
    let deviations: [Double]
    /// How much of the fitted signal survived out-of-sample. Zero disables it.
    let kappa: Double
    let windows: Int
    let cvLogLoss: Double
    let baselineLogLoss: Double
    let isDefault: Bool
    let summary: String

    /// A hundred windows a feature is roughly twenty per coefficient, which is the
    /// usual floor for a logistic fit to mean anything. Three hundred is that with
    /// room, and is about a day of continuous watching.
    static let minimumWindows = 300

    static func unlearned() -> RegimeModel {
        RegimeModel(
            weights: [Double](repeating: 0, count: RegimeFeatures.names.count),
            means: [Double](repeating: 0, count: RegimeFeatures.names.count),
            deviations: [Double](repeating: 1, count: RegimeFeatures.names.count),
            kappa: 0, windows: 0, cvLogLoss: 0, baselineLogLoss: 0, isDefault: true,
            summary: "The cross-window model has not been fitted yet. It needs "
                + "\(minimumWindows) resolved windows — about a day of continuous watching — and then it "
                + "has to beat doing nothing on windows it was not fitted on before any of it is used. "
                + "Until both of those happen the desk reads each window entirely on its own, which is how "
                + "it has always worked.")
    }

    /// The log-odds this model wants to add, given a current reading. Zero when the
    /// fit was never accepted, so every caller can apply it unconditionally.
    func adjustment(_ features: RegimeFeatures?) -> Double {
        guard !isDefault, kappa > 0, let features else { return 0 }
        let x = features.vector
        guard x.count == weights.count else { return 0 }
        var z = 0.0
        for i in 0..<x.count {
            let sd = deviations[i] > 1e-9 ? deviations[i] : 1
            z += weights[i] * ((x[i] - means[i]) / sd)
        }
        /* The intercept is deliberately not applied.
         *
         * It is fitted, because leaving it out would push the base rate into the
         * coefficients, and it is then thrown away, because a fitted intercept on a
         * sample that happened to contain more Ups than Downs is a standing bet on Up
         * dressed as a measurement. The features describe *departures* from the usual;
         * the usual is the path model's job and the market's.
         */
        return Analysis.clamp(kappa * z, -1.5, 1.5)
    }

    /// What each feature is contributing right now, for the screen.
    func readings(_ features: RegimeFeatures?) -> [FeatureReading] {
        guard let features, features.vector.count == weights.count else { return [] }
        let x = features.vector
        return (0..<x.count).map { i in
            let sd = deviations[i] > 1e-9 ? deviations[i] : 1
            return FeatureReading(
                name: RegimeFeatures.names[i],
                weight: weights[i],
                contribution: kappa * weights[i] * ((x[i] - means[i]) / sd))
        }
    }
}

/* --------------------------------------------------------------- the fit */

extension PredictFit {

    /**
     * Fits the cross-window model, and mostly declines to.
     *
     * Ordinary L2-penalised logistic regression by batch gradient descent, which is
     * unremarkable and is not where the care is. The care is in the two gates:
     *
     *   **Five-fold cross-validation.** Every reported number comes from windows the
     *   coefficients producing it never saw. An in-sample log loss on five features
     *   and three hundred windows will beat the baseline essentially always, and
     *   would have this thing trading on noise within a day.
     *
     *   **A shrinkage swept on the held-out folds.** Even a fit that genuinely beats
     *   the baseline usually overstates itself, so `κ` — the share of the fitted
     *   log-odds actually applied — is chosen by the same cross-validation rather
     *   than set to one. A weak but real signal ends up quietly scaled down instead
     *   of being taken at face value, and a signal that is real in sample and absent
     *   out of it ends at zero.
     *
     * Standardisation is computed on each training fold and applied to its held-out
     * fold, not computed once over everything. Computing it over the whole set first
     * is the most common way cross-validation is quietly made to lie, because the
     * held-out fold then contributed to something the model saw.
     */
    static func regime(_ rows: [ShadowWindow]) -> RegimeModel {
        let samples: [(x: [Double], up: Bool)] = rows.compactMap { row in
            guard let resolved = row.resolved, let features = row.regime else { return nil }
            return (features.vector, resolved == .up)
        }
        guard samples.count >= RegimeModel.minimumWindows else { return .unlearned() }

        let dimension = RegimeFeatures.names.count
        guard samples.allSatisfy({ $0.x.count == dimension }) else { return .unlearned() }

        /* -------------------------------------------------- the pieces, once */

        func standardise(_ set: [(x: [Double], up: Bool)]) -> (means: [Double], deviations: [Double]) {
            var means = [Double](repeating: 0, count: dimension)
            var deviations = [Double](repeating: 1, count: dimension)
            for i in 0..<dimension {
                let column = set.map { $0.x[i] }
                let mean = column.reduce(0, +) / Double(column.count)
                let variance = column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(Swift.max(1, column.count - 1))
                means[i] = mean
                deviations[i] = variance > 1e-12 ? variance.squareRoot() : 1
            }
            return (means, deviations)
        }

        func fit(_ set: [(x: [Double], up: Bool)],
                 means: [Double], deviations: [Double]) -> (weights: [Double], intercept: Double) {
            var weights = [Double](repeating: 0, count: dimension)
            var intercept = 0.0
            let rate = 0.15
            // L2, and not small. The prior this expresses — that these coefficients
            // are near zero until the data insists otherwise — is the same prior the
            // rest of this file is built on, and it is usually right.
            let penalty = 0.02
            let n = Double(set.count)
            for _ in 0..<600 {
                var gradW = [Double](repeating: 0, count: dimension)
                var gradB = 0.0
                for s in set {
                    var z = intercept
                    for i in 0..<dimension { z += weights[i] * ((s.x[i] - means[i]) / deviations[i]) }
                    let p = 1 / (1 + exp(-z))
                    let error = p - (s.up ? 1 : 0)
                    for i in 0..<dimension { gradW[i] += error * ((s.x[i] - means[i]) / deviations[i]) }
                    gradB += error
                }
                for i in 0..<dimension {
                    weights[i] -= rate * (gradW[i] / n + penalty * weights[i])
                }
                intercept -= rate * (gradB / n)
            }
            return (weights, intercept)
        }

        func logLoss(_ p: Double, _ up: Bool) -> Double {
            let q = Analysis.clamp(p, 1e-6, 1 - 1e-6)
            return -(up ? log(q) : log(1 - q))
        }

        /* --------------------------------------------- cross-validated scoring */

        // Interleaved rather than contiguous: the windows are in time order, and
        // five contiguous blocks would each be a different couple of hours of the
        // market. Testing a trend model on one afternoon after fitting it on another
        // measures the afternoons, not the model.
        let folds = 5
        var heldOut: [(z: Double, base: Double, up: Bool)] = []
        for fold in 0..<folds {
            let test = samples.enumerated().filter { $0.offset % folds == fold }.map(\.element)
            let train = samples.enumerated().filter { $0.offset % folds != fold }.map(\.element)
            guard !test.isEmpty, train.count > dimension * 10 else { continue }
            let scale = standardise(train)
            let fitted = fit(train, means: scale.means, deviations: scale.deviations)
            let baseRate = Double(train.filter(\.up).count) / Double(train.count)
            for s in test {
                var z = 0.0
                for i in 0..<dimension {
                    z += fitted.weights[i] * ((s.x[i] - scale.means[i]) / scale.deviations[i])
                }
                heldOut.append((z, baseRate, s.up))
            }
        }
        guard heldOut.count >= RegimeModel.minimumWindows / 2 else { return .unlearned() }

        /* -------------------------------------- choosing κ, and then testing it
         *
         * **These are split in two, and the first version of this was wrong for
         * exactly the reason the split exists.** It swept fifty-one values of κ
         * against the held-out predictions, took the best, and then asked whether
         * that best beat the baseline *on the same predictions*. That is selection on
         * the test set: the minimum of fifty-one noisy evaluations is below the mean
         * of them by construction, whether or not anything is there. Against a
         * synthetic book of six hundred windows whose outcome depended on none of the
         * five features, it accepted κ = 0.74 on an improvement of 0.006 — well
         * inside one standard error, and enough to have the desk sizing bets off
         * pure noise within a day of running.
         *
         * So the held-out predictions are split by parity — interleaved rather than
         * cut in half, so both sides span the same stretch of market. κ is chosen on
         * one side and judged on the other, which it has never touched.
         */
        let chooseOn = heldOut.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let judgeOn = heldOut.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        guard chooseOn.count >= 60, judgeOn.count >= 60 else { return .unlearned() }

        func meanLoss(_ set: [(z: Double, base: Double, up: Bool)], _ kappa: Double) -> Double {
            set.reduce(0) { total, s in
                let p = 1 / (1 + exp(-(log(s.base / (1 - s.base)) + kappa * s.z)))
                return total + logLoss(p, s.up)
            } / Double(set.count)
        }

        var bestKappa = 0.0
        var bestOnChooser = meanLoss(chooseOn, 0)
        var kappa = 0.02
        while kappa <= 1.0001 {
            let loss = meanLoss(chooseOn, kappa)
            if loss < bestOnChooser { bestOnChooser = loss; bestKappa = kappa }
            kappa += 0.02
        }

        let baseline = meanLoss(judgeOn, 0)
        let bestLoss = meanLoss(judgeOn, bestKappa)

        /* And the test itself is paired, which is the other half of the repair.
         *
         * "Better on average" is not a finding on a few hundred windows — the
         * standard error of a log-loss difference at this sample size is larger than
         * every effect anyone has ever claimed to find in five-minute crypto. So the
         * improvement is measured per window and has to clear two standard errors of
         * its own mean, which is a statement that scales with the evidence rather
         * than a threshold guessed in advance. The fixed half-a-percent margin this
         * replaces would have passed the noise book.
         */
        let differences = judgeOn.map { s -> Double in
            let p = 1 / (1 + exp(-(log(s.base / (1 - s.base)) + bestKappa * s.z)))
            return logLoss(s.base, s.up) - logLoss(p, s.up)
        }
        let meanGain = differences.reduce(0, +) / Double(differences.count)
        let spread = differences.reduce(0) { $0 + ($1 - meanGain) * ($1 - meanGain) }
            / Double(Swift.max(1, differences.count - 1))
        let standardError = (spread / Double(differences.count)).squareRoot()

        guard bestKappa > 0, meanGain > 2 * standardError else {
            return RegimeModel(
                weights: [Double](repeating: 0, count: dimension),
                means: [Double](repeating: 0, count: dimension),
                deviations: [Double](repeating: 1, count: dimension),
                kappa: 0, windows: samples.count, cvLogLoss: bestLoss, baselineLogLoss: baseline,
                isDefault: true,
                summary: "Fitted across \(samples.count) resolved windows and then **refused**. "
                    + "On windows it had never seen — and at a shrinkage chosen on a different set of "
                    + "windows again — the five cross-window features scored \(f(bestLoss, 4)) by log loss "
                    + "against \(f(baseline, 4)) for ignoring them entirely. That is \(f(meanGain, 5)) per "
                    + "window against a standard error of \(f(standardError, 5)), which is not a finding. "
                    + "It is the expected result on a five-minute crypto market: the desk reads each window "
                    + "on its own, exactly as it did before, and this is re-fitted as more windows resolve.")
        }

        // Accepted. The reported coefficients are fitted on everything, since there
        // is no longer a held-out set to protect — the decision to use them at all
        // was already made on one.
        let scale = standardise(samples)
        let final = fit(samples, means: scale.means, deviations: scale.deviations)
        let ranked = (0..<dimension)
            .map { (name: RegimeFeatures.names[$0], weight: final.weights[$0]) }
            .sorted { abs($0.weight) > abs($1.weight) }
        let leader = ranked.first

        var summary = "Fitted across \(samples.count) resolved windows and **accepted**. "
        summary += "On windows it had never seen, at a shrinkage chosen on a different set again, the five "
        summary += "cross-window features scored \(f(bestLoss, 4)) by log loss against \(f(baseline, 4)) for "
        summary += "ignoring them — \(f(meanGain, 5)) per window against a standard error of "
        summary += "\(f(standardError, 5)), so it clears the two-error bar this asks for. "
        summary += "\(f(bestKappa * 100, 0))% of the fitted signal is applied; the rest was in-sample flattery. "
        if let leader {
            summary += "The strongest reading is *\(leader.name.lowercased())* at \(f(leader.weight, 3)), "
            summary += leader.weight > 0
                ? "pushing toward Up when it is high. "
                : "pushing toward Down when it is high. "
        }
        summary += "This is the only part of the desk that has a view before a window has moved at all."

        return RegimeModel(
            weights: final.weights, means: scale.means, deviations: scale.deviations,
            kappa: bestKappa, windows: samples.count,
            cvLogLoss: bestLoss, baselineLogLoss: baseline, isDefault: false,
            summary: summary)
    }
}
