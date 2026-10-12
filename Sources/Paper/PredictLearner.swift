/**
 * PredictLearner.swift — a desk that can change its mind about *how* it reads a
 * window, not just how much it trusts one fixed reading.
 *
 * **The hole this fills, measured rather than asserted.** `PredictLearning` fits
 * three numbers, and the second of them — `modelWeight`, how much voice the
 * hand-written path model gets against the market price — came back at **0.0%**
 * on a book of 131 resolved windows. That is a correct finding: on that book the
 * market is 79% directionally accurate and the model is 71%, and every amount of
 * model in the blend makes the Brier score worse. The desk measured itself
 * honestly and concluded it had nothing to add.
 *
 * The trouble is what that conclusion *does*. The blend is
 * `σ(w·logit(pModel) + (1−w)·logit(pMarket))`, so at `w = 0` the blended
 * probability **is** the market price, to the last decimal. The edge over the
 * market is then zero by construction, the five-cent bar can never be cleared,
 * and the desk stops betting — permanently. Replaying the real book confirms it:
 * 0 qualifying looks at `w = 0`, against 242 at the shipped default. The entry
 * offset fit, which needs qualifying looks to have anything to measure, is
 * starved as a direct consequence and still reports `offsetSamples: 0`.
 *
 * So `w = 0` is an absorbing state. The one lever the old system had was *how
 * much to trust a fixed model*, and once that lever reaches zero there is no
 * mechanism — none, not with infinite data — by which it can ever come back. A
 * system that can only ever lower its opinion of itself is not learning from its
 * mistakes. It is failing safe, once, and calling it a day.
 *
 * **What this adds.** The fixed blend is replaced by a *family* of candidate
 * readings, each a logistic model over features that are already recorded, and
 * the family is strictly richer than the blend it replaces:
 *
 *   - `market` alone reproduces the market price, which is the incumbent and the
 *     null hypothesis in one.
 *   - `market + model` spans every blend the old `w` could express, and finds the
 *     coefficient by fitting rather than by sweeping.
 *   - The rest ask questions the blend cannot phrase at all. Is the market's price
 *     systematically off *late* in a window, when it has the most information and
 *     the least time? Does the tape's own projected move carry anything the price
 *     has not already absorbed? Do the cross-window regime readings help?
 *
 * That matters because a model does not have to beat the market to be worth
 * having. It has to find a **residual** — some part of the outcome the price is
 * reliably missing. A market-only champion at `w = 0` cannot express a residual.
 * This can, and can also report that there isn't one.
 *
 * **Why this is not a licence to fit noise.** Every candidate is scored
 * *out of sample*, walk-forward, on windows it was never fitted on, with the
 * splits falling on window boundaries so no window is ever half in training and
 * half in test. The comparison against the incumbent is **paired per window** and
 * the standard error is **clustered by window**, because sixteen samples taken
 * inside one five-minute window share a single outcome and counting them as
 * sixteen independent observations overstates the evidence fourfold. A challenger
 * is promoted only when it beats the reigning champion by more than
 * `promotionSigma` clustered standard errors, and a champion that stops clearing
 * that bar is demoted back to the market.
 *
 * **What it says today.** On the real 131-window book, every challenger is worse
 * out of sample than the market alone — the best of them by 0.0015 Brier against
 * a clustered standard error of 0.012, which is to say comfortably inside the
 * noise. Nothing is promoted, the desk keeps reading the market price, and the
 * audit says so in those words. That is the system working. The difference from
 * before is that it is now a *finding that is re-examined every time evidence
 * arrives*, rather than a switch that latched off and removed the machinery that
 * could ever have flipped it back.
 */

import Foundation

/* ------------------------------------------------------------- the features */

/**
 * What a candidate is allowed to look at.
 *
 * Every one of these is known at the moment the sample was taken, and every one
 * is already in the shadow book — nothing here needs a new recording path or a
 * new request. Deliberately few: the clustering unit is the *window*, so a book
 * of 3,000 windows is 3,000 independent observations however many samples it
 * holds, and a dozen features over a few hundred windows is how a fit ends up
 * describing its own training set.
 */
enum PredictFeature: String, Codable, CaseIterable {
    /// `logit(pMarket)`. The incumbent's only input, and the null hypothesis.
    case market
    /// `logit(pModel)` — the hand-written path model, before the market is folded in.
    case model
    /// The tape's projected move for the window, volatility-normalised and clamped.
    case move
    /// How far into the window the sample was taken, centred and scaled.
    case offset
    /// `offset × market`. Lets the fit say the price is worth *more* late in a
    /// window than early, or less — which a fixed blend weight cannot express at
    /// all, and which is the most plausible place for a residual to be hiding.
    case offsetMarket
    /// The five cross-window readings from `RegimeFeatures`, as five coefficients.
    case regime

    /// Coefficients this feature contributes.
    var width: Int { self == .regime ? 5 : 1 }

    var label: String {
        switch self {
        case .market: return "the market price"
        case .model: return "the path model"
        case .move: return "the tape's own move"
        case .offset: return "how far into the window"
        case .offsetMarket: return "the price, weighted by how late it is"
        case .regime: return "the five cross-window readings"
        }
    }
}

/// One sample, reduced to the numbers a candidate can fit on.
struct LearnRow {
    /// Which window this came from. The clustering unit for every standard error
    /// in this file, and the unit every train/test split falls on.
    let window: Int
    /// 1 when the window resolved Up.
    let outcome: Double
    let logitMarket: Double
    let logitModel: Double
    let move: Double
    let offset: Double
    let regime: [Double]

    func vector(_ features: [PredictFeature]) -> [Double] {
        var v: [Double] = [1]
        for f in features {
            switch f {
            case .market: v.append(logitMarket)
            case .model: v.append(logitModel)
            case .move: v.append(move)
            case .offset: v.append(offset)
            case .offsetMarket: v.append(offset * logitMarket)
            case .regime: v.append(contentsOf: regime)
            }
        }
        return v
    }

    static func width(_ features: [PredictFeature]) -> Int {
        1 + features.reduce(0) { $0 + $1.width }
    }
}

/* ------------------------------------------------------------ the candidates */

/// A way of reading a window, and the argument for trying it.
struct PredictCandidate {
    let id: String
    let label: String
    let features: [PredictFeature]
    /// Why this one is on the list. Kept with the candidate so a table of results
    /// says what each row was testing rather than only how it scored.
    let asks: String

    /**
     * The field, in the order a report should read them.
     *
     * `market` is first because it is the incumbent and the null: every other row
     * is measured against it, and a candidate that cannot beat it has, by
     * definition, found nothing. The rest go from cheapest hypothesis to richest,
     * so a table of results reads as a widening search rather than a grab bag.
     */
    static let field: [PredictCandidate] = [
        PredictCandidate(
            id: "market", label: "The market price alone",
            features: [.market],
            asks: "The null. Is anything at all better than paying attention to the price?"),
        PredictCandidate(
            id: "market+model", label: "Market and path model",
            features: [.market, .model],
            asks: "Everything the old blend weight could express, fitted rather than swept."),
        PredictCandidate(
            id: "market+move", label: "Market and the tape",
            features: [.market, .move],
            asks: "Does the move the tape has already printed carry anything the price has not absorbed?"),
        PredictCandidate(
            id: "market+late", label: "Market, weighted by how late it is",
            features: [.market, .offset, .offsetMarket],
            asks: "Is the price systematically off early or late in a window? A fixed blend cannot ask this."),
        PredictCandidate(
            id: "market+model+tape", label: "Market, model and tape",
            features: [.market, .model, .move, .offset, .offsetMarket],
            asks: "Everything inside the window at once."),
        PredictCandidate(
            id: "everything", label: "Everything, including regime",
            features: [.market, .model, .move, .offset, .offsetMarket, .regime],
            asks: "The widest reading. Most likely of the field to fit its own training set, which is what the out-of-sample score is for."),
    ]

    static func of(_ id: String) -> PredictCandidate? { field.first { $0.id == id } }
}

/* -------------------------------------------------------------- the verdict */

/// How one candidate did, out of sample, against the incumbent.
struct CandidateResult: Codable, Identifiable {
    let id: String
    let label: String
    let asks: String
    /// Mean Brier over windows it was never fitted on. Lower is better.
    let oosBrier: Double
    /// Mean per-window Brier *improvement* over the champion. Positive is better.
    let gainOverChampion: Double
    /// Standard error of that gain, clustered by window — the only error bar that
    /// means anything here, since samples inside a window share one outcome.
    let standardError: Double
    /// `gain / standardError`. The number the promotion rule actually reads.
    let sigma: Double
    let windowsTested: Int
    let samplesTested: Int
    /// Coefficients from a final fit over everything, for the promoted one to use.
    let coefficients: [Double]
    let features: [PredictFeature]
    /// True when this cleared the bar and would be promoted.
    let promotable: Bool
    let verdict: String
}

/**
 * The reading currently in force.
 *
 * `isDefault` means nothing has ever earned promotion and the desk is reading the
 * market price, which is exactly what it does today at `modelWeight = 0` — except
 * that this states it as a standing conclusion under review rather than as the
 * side effect of a weight that happened to hit zero.
 */
struct PredictPolicy: Codable {
    var candidateId: String
    var features: [PredictFeature]
    var coefficients: [Double]
    var oosBrier: Double
    var sigma: Double
    var windows: Int
    var promotedAt: Double
    var isDefault: Bool
    var summary: String

    init(candidateId: String, features: [PredictFeature], coefficients: [Double],
         oosBrier: Double, sigma: Double, windows: Int, promotedAt: Double,
         isDefault: Bool, summary: String) {
        self.candidateId = candidateId; self.features = features
        self.coefficients = coefficients; self.oosBrier = oosBrier; self.sigma = sigma
        self.windows = windows; self.promotedAt = promotedAt
        self.isDefault = isDefault; self.summary = summary
    }

    /**
     * Decoded by hand. A policy that will not read is a desk that silently reverts
     * to the market, which is safe — but it should revert because it was *told*
     * to, not because a field was added to this struct.
     *
     * `candidateId`, `features` and `coefficients` are genuinely identifying:
     * without all three there is no reading to apply, and `probability` would be
     * evaluating coefficients against the wrong columns. Missing any of them
     * means this is not a policy, which is a real error, so it throws — and the
     * caller answers by using the market, which is the correct fallback.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateId = try c.decode(String.self, forKey: .candidateId)
        features = try c.decode([PredictFeature].self, forKey: .features)
        coefficients = try c.decode([Double].self, forKey: .coefficients)
        oosBrier = try c.decodeIfPresent(Double.self, forKey: .oosBrier) ?? 0
        sigma = try c.decodeIfPresent(Double.self, forKey: .sigma) ?? 0
        windows = try c.decodeIfPresent(Int.self, forKey: .windows) ?? 0
        promotedAt = try c.decodeIfPresent(Double.self, forKey: .promotedAt) ?? 0
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }

    static func market() -> PredictPolicy {
        PredictPolicy(
            candidateId: "market", features: [.market],
            // Intercept 0, one-for-one on the market's logit: exactly the market's
            // own probability, which is both the incumbent and the honest default.
            coefficients: [0, 1],
            oosBrier: 0, sigma: 0, windows: 0, promotedAt: 0, isDefault: true,
            summary: "The desk is reading the market price and nothing else. No candidate reading has beaten it "
                + "on windows it was not fitted on, so none has been promoted. Every window watched from here "
                + "is added to the book and the whole field is re-scored as answers arrive.")
    }

    /// P(Up) under this policy. The one place a policy turns into a number.
    func probability(_ row: LearnRow) -> Double {
        let v = row.vector(features)
        guard v.count == coefficients.count else {
            // A policy whose shape no longer matches the features it names is a
            // policy from an older build. Falling back to the market is both the
            // safe answer and the correct one.
            return Analysis.clamp(1 / (1 + exp(-row.logitMarket)), 0.005, 0.995)
        }
        let z = zip(v, coefficients).reduce(0) { $0 + $1.0 * $1.1 }
        return Analysis.clamp(1 / (1 + exp(-Analysis.clamp(z, -30, 30))), 0.005, 0.995)
    }
}

/* -------------------------------------------------------------- the fitting */

/**
 * Logistic regression, walk-forward evaluation, and the promotion rule.
 *
 * Pure functions over arrays, deliberately, for the reason `PredictFit` gives:
 * these are the parts most worth testing against books whose right answer is
 * known by construction, and `--selftest` is synchronous.
 */
enum PredictLearner {

    /// Windows before any of this is allowed to have an opinion. Below this the
    /// clustered standard error is wider than any effect worth acting on.
    static let minimumWindows = 120
    /// Fraction of the book held back before the first test fold.
    static let warmupFraction = 0.4
    static let folds = 5
    /**
     * How many clustered standard errors a challenger must beat the champion by.
     *
     * Two, not one. Six candidates are compared and the best of six noisy scores
     * is high by construction — the same multiple-comparison problem the entry
     * offset fit guards against, and the same answer. At one sigma a field this
     * size would promote something roughly one run in three on pure noise.
     */
    static let promotionSigma = 2.0
    /// Ridge penalty. Small, and doing real work: with regime switched on the
    /// design matrix has eleven columns against a few hundred windows.
    static let ridge = 1.0

    /* ------------------------------------------------------------ preparing */

    /// The book, reduced to rows. Windows are numbered in time order, because
    /// every split here is a split in time.
    static func rows(_ book: [ShadowWindow]) -> [LearnRow] {
        let ordered = book
            .filter(\.isTrainable)
            .sorted { $0.start < $1.start }

        var out: [LearnRow] = []
        for (index, window) in ordered.enumerated() {
            guard let resolved = window.resolved else { continue }
            let regime = window.regime?.vector ?? [0, 0, 0, 0, 0]
            for sample in window.samples {
                guard let pMarket = sample.pMarket, pMarket > 0.001, pMarket < 0.999 else { continue }
                let pModel = Analysis.clamp(sample.pModel, 0.005, 0.995)
                out.append(LearnRow(
                    window: index,
                    outcome: resolved == .up ? 1 : 0,
                    logitMarket: log(pMarket / (1 - pMarket)),
                    logitModel: log(pModel / (1 - pModel)),
                    // Scaled so a typical move is order one and an extreme one is
                    // clamped rather than allowed to decide a coefficient.
                    move: Analysis.clamp(sample.moveBps / 50, -4, 4),
                    // Centred on the middle of the tradeable band, so the intercept
                    // stays interpretable as "at a normal entry".
                    offset: (sample.offset - 150) / 120,
                    regime: regime))
            }
        }
        return out
    }

    /**
     * The two prices beside each row, in the same order `rows` returns them.
     *
     * The learner has no use for asks — a probability is fitted against an
     * outcome, not against a price — but the replay that counts qualifying looks
     * needs both, and needs them lined up with the rows exactly. Built by the same
     * walk with the same filters so the two cannot fall out of step.
     */
    static func asks(_ book: [ShadowWindow]) -> [(up: Double?, down: Double?)] {
        let ordered = book
            .filter(\.isTrainable)
            .sorted { $0.start < $1.start }
        var out: [(up: Double?, down: Double?)] = []
        for window in ordered {
            for sample in window.samples {
                guard let pMarket = sample.pMarket, pMarket > 0.001, pMarket < 0.999 else { continue }
                out.append((sample.upAsk, sample.downAsk))
            }
        }
        return out
    }

    /* ------------------------------------------------------------- the solver */

    /**
     * Ridge-penalised logistic regression by iteratively reweighted least squares.
     *
     * Newton on the penalised likelihood. Converges in a handful of steps on
     * problems this size, and the ridge term keeps the Hessian invertible when a
     * feature is near-constant inside a fold — which happens with `regime` on a
     * short book and used to be the difference between a fit and a crash.
     */
    static func fit(_ rows: [LearnRow], _ features: [PredictFeature],
                    ridge: Double = PredictLearner.ridge, iterations: Int = 40) -> [Double] {
        let width = LearnRow.width(features)
        var beta = [Double](repeating: 0, count: width)
        guard rows.count > width else { return beta }
        let design = rows.map { $0.vector(features) }

        for _ in 0..<iterations {
            var gradient = [Double](repeating: 0, count: width)
            var hessian = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)

            for (i, x) in design.enumerated() {
                var z = 0.0
                for j in 0..<width { z += beta[j] * x[j] }
                let p = 1 / (1 + exp(-Analysis.clamp(z, -30, 30)))
                let w = Swift.max(p * (1 - p), 1e-6)
                let residual = p - rows[i].outcome
                for j in 0..<width {
                    gradient[j] += residual * x[j]
                    for k in 0..<width { hessian[j][k] += w * x[j] * x[k] }
                }
            }
            // The penalty is not applied to the intercept: shrinking it towards zero
            // would be shrinking the base rate towards a coin flip, which is a claim
            // about the world rather than a guard against overfitting.
            for j in 1..<width {
                gradient[j] += ridge * beta[j]
                hessian[j][j] += ridge
            }
            hessian[0][0] += 1e-8

            guard let step = solve(hessian, gradient) else { return beta }
            var largest = 0.0
            for j in 0..<width {
                beta[j] -= step[j]
                largest = Swift.max(largest, abs(step[j]))
            }
            if largest < 1e-9 { break }
        }
        return beta
    }

    /// Gaussian elimination with partial pivoting. Nil when the system is singular,
    /// which the caller answers by keeping the coefficients it already had.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot); b.swapAt(col, pivot)
            let d = a[col][col]
            for row in 0..<n where row != col {
                let factor = a[row][col] / d
                guard factor != 0 else { continue }
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                b[row] -= factor * b[col]
            }
        }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n { out[i] = b[i] / a[i][i] }
        return out
    }

    /* -------------------------------------------------- walk-forward scoring */

    /**
     * Per-window Brier for one candidate, on windows it was never fitted on.
     *
     * Expanding training window, test blocks in time order, splits on window
     * boundaries. Returned per window rather than averaged because the comparison
     * against the champion has to be **paired** — the same windows scored by both
     * readings — and a pair of means throws away exactly the information that
     * makes the comparison sensitive.
     */
    static func walkForward(_ rows: [LearnRow], _ features: [PredictFeature])
        -> [Int: Double] {
        guard let last = rows.map(\.window).max() else { return [:] }
        let windowCount = last + 1
        let warmup = Int(Double(windowCount) * warmupFraction)
        guard windowCount - warmup >= folds else { return [:] }

        var scores: [Int: (total: Double, count: Int)] = [:]
        for fold in 0..<folds {
            let from = warmup + (windowCount - warmup) * fold / folds
            let to = warmup + (windowCount - warmup) * (fold + 1) / folds
            guard to > from else { continue }

            let train = rows.filter { $0.window < from }
            let test = rows.filter { $0.window >= from && $0.window < to }
            guard test.count > 0, train.count > LearnRow.width(features) * 10 else { continue }

            let beta = fit(train, features)
            for row in test {
                let v = row.vector(features)
                var z = 0.0
                for j in 0..<v.count { z += beta[j] * v[j] }
                let p = Analysis.clamp(1 / (1 + exp(-Analysis.clamp(z, -30, 30))), 0.005, 0.995)
                let error = (p - row.outcome) * (p - row.outcome)
                var entry = scores[row.window] ?? (0, 0)
                entry.total += error
                entry.count += 1
                scores[row.window] = entry
            }
        }
        return scores.mapValues { $0.total / Double($0.count) }
    }

    /* ----------------------------------------------------------- the contest */

    /**
     * Every candidate, scored against the champion, with the promotion decision.
     *
     * The champion is whichever reading is currently in force. On a fresh desk
     * that is the market alone, which makes the first contest a straight test of
     * "does anything beat paying attention to the price" — the question the old
     * `modelWeight` fit was answering one candidate at a time, with no error bar.
     */
    static func contest(_ book: [ShadowWindow], champion: PredictPolicy)
        -> (results: [CandidateResult], promote: CandidateResult?) {

        let all = rows(book)
        let windows = Set(all.map(\.window)).count
        guard windows >= minimumWindows else {
            return ([], nil)
        }

        // The champion is scored the same way as everything else — walk-forward,
        // refitted per fold — so the comparison is like for like. Scoring a
        // champion on coefficients fitted over the whole book, against challengers
        // scored out of sample, would hand it an advantage it has not earned.
        let championFeatures = champion.isDefault ? [PredictFeature.market] : champion.features
        let championScores = walkForward(all, championFeatures)
        guard !championScores.isEmpty else { return ([], nil) }

        var results: [CandidateResult] = []
        for candidate in PredictCandidate.field {
            let scores = walkForward(all, candidate.features)
            let shared = Set(scores.keys).intersection(championScores.keys).sorted()
            guard shared.count >= 20 else { continue }

            // Paired per window: how much better than the champion, window by window.
            let gains = shared.map { (championScores[$0] ?? 0) - (scores[$0] ?? 0) }
            let mean = gains.reduce(0, +) / Double(gains.count)
            let variance = gains.count > 1
                ? gains.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gains.count - 1)
                : 0
            let standardError = sqrt(variance / Double(gains.count))
            let sigma = standardError > 1e-12 ? mean / standardError : 0
            let oos = shared.map { scores[$0] ?? 0 }.reduce(0, +) / Double(shared.count)
            let samples = all.filter { shared.contains($0.window) }.count

            let isChampion = candidate.id == champion.candidateId
            let promotable = !isChampion && sigma >= promotionSigma

            let verdict: String
            if isChampion {
                verdict = "Currently in force."
            } else if mean <= 0 {
                verdict = "Worse than the reading in force by \(f(-mean, 5)) Brier. Nothing here."
            } else if sigma < promotionSigma {
                verdict = "Better by \(f(mean, 5)), which is \(f(sigma, 1)) standard errors — inside the noise. "
                    + "Needs \(f(promotionSigma, 0)) before it is allowed to change anything."
            } else {
                verdict = "Better by \(f(mean, 5)) Brier at \(f(sigma, 1)) standard errors over \(shared.count) windows it was never fitted on. Promoted."
            }

            results.append(CandidateResult(
                id: candidate.id, label: candidate.label, asks: candidate.asks,
                oosBrier: oos, gainOverChampion: mean, standardError: standardError,
                sigma: sigma, windowsTested: shared.count, samplesTested: samples,
                // Fitted over everything for the promoted policy to carry forward.
                // Out-of-sample scoring decided *whether* to use it; once that is
                // settled, the best coefficients are the ones standing on all the data.
                coefficients: fit(all, candidate.features),
                features: candidate.features,
                promotable: promotable, verdict: verdict))
        }

        results.sort { $0.gainOverChampion > $1.gainOverChampion }
        let winner = results.filter(\.promotable).max { $0.sigma < $1.sigma }
        return (results, winner)
    }

    /**
     * The contest, resolved into the reading that should now be in force.
     *
     * Demotion is the other half of the rule and the half that makes this
     * adaptive rather than merely improvable. A promoted reading is re-scored on
     * every contest, and one that has stopped beating the market by its own bar is
     * returned to the market rather than left running on a result it earned on a
     * different market a fortnight ago.
     */
    static func settle(_ book: [ShadowWindow], champion: PredictPolicy)
        -> (policy: PredictPolicy, results: [CandidateResult], changed: Bool) {

        let (results, winner) = contest(book, champion: champion)
        guard !results.isEmpty else { return (champion, results, false) }

        if let winner {
            let policy = PredictPolicy(
                candidateId: winner.id, features: winner.features,
                coefficients: winner.coefficients, oosBrier: winner.oosBrier,
                sigma: winner.sigma, windows: winner.windowsTested,
                promotedAt: nowMs(), isDefault: false,
                summary: "Reading windows with \(winner.label.lowercased()). It beat the previous reading by "
                    + "\(f(winner.gainOverChampion, 5)) Brier at \(f(winner.sigma, 1)) standard errors over "
                    + "\(winner.windowsTested) windows it had never been fitted on.")
            return (policy, results, true)
        }

        // Nothing was promoted. If the champion is still the market, that is simply
        // the finding restated. If it is a reading that was promoted earlier, it has
        // to still be earning its place.
        guard !champion.isDefault else { return (champion, results, false) }
        let stillWinning = results.first { $0.id == champion.candidateId }
        let market = results.first { $0.id == "market" }
        if let stillWinning, let market, market.gainOverChampion > stillWinning.standardError * promotionSigma {
            var demoted = PredictPolicy.market()
            demoted.promotedAt = nowMs()
            demoted.summary = "Back to reading the market price alone. "
                + "\(PredictCandidate.of(champion.candidateId)?.label ?? champion.candidateId) was promoted earlier "
                + "and has stopped beating the market on recent windows, so it has been stood down rather than "
                + "left running on a result it earned under different conditions."
            return (demoted, results, true)
        }
        return (champion, results, false)
    }
}
