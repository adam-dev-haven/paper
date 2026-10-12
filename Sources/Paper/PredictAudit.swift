/**
 * PredictAudit.swift — is the prediction desk actually learning, and if not, why not.
 *
 * The prediction desk has a real learning loop and it is hard to tell whether it
 * is working. That is not a failure of attention; it is the shape of the thing.
 * Every parameter it fits is a *measurement of how much to trust something*, the
 * honest answer to most of those measurements is "not much", and a desk that has
 * correctly learned to do nothing looks exactly like a desk that never learned
 * anything. Both sit there, betting nothing, with a plausible summary string.
 *
 * Reading the source does not settle it either. The fits are correct. The
 * thresholds are defensible. What the source cannot tell you is the thing that
 * actually matters: **what the numbers have converged to, and what that
 * convergence has done to the desk's behaviour.**
 *
 * On the book this was built against, that turned out to be the whole story.
 * `modelWeight` had been fitted, correctly, to `0.0%` — the market was 79%
 * directionally accurate against the model's 71%, and every amount of model in
 * the blend scored worse. But the blend is
 * `σ(w·logit(pModel) + (1−w)·logit(pMarket))`, so a weight of zero makes the
 * desk's probability *identical* to the market's price, which makes the edge
 * identically zero, which means the five-cent bar can never be cleared. Replaying
 * the book confirms it: **0 qualifying looks**, against 242 at the shipped
 * default. And the entry-offset fit, which can only learn from looks that
 * qualified, was therefore starved — reporting `offsetSamples: 0` after 131
 * resolved windows, which reads as "not enough data yet" and was really "this can
 * never receive data again".
 *
 * None of those three facts is visible from any screen, and no two of them are in
 * the same file. This is the screen that puts them together.
 *
 * What it checks, in the order the questions actually get asked:
 *
 *   1. **Is evidence arriving?** Windows recorded, resolved, degraded, and the
 *      rate. A learning system with no inflow is not learning whatever else is true.
 *   2. **Has anything moved?** Each fitted parameter against its shipped default,
 *      with the evidence behind it and whether it is still waiting on a threshold.
 *   3. **Can the desk still act?** The qualifying-look count under the parameters
 *      currently in force. Zero because the desk honestly measured no edge is a
 *      finding; zero that neither the weight nor the contest explains is a fault.
 *   4. **Is the learning any good?** The candidate contest, out of sample.
 *   5. **Does the record match the rehearsal?** Realised bets against what the
 *      shadow book said would happen — the one check that can catch the shadow
 *      book being wrong about the world rather than about the model.
 *
 * Each check returns a verdict, and a verdict can be `blocked`, which is the
 * state this whole file exists to make nameable: not broken, not working, and
 * unable to become either without a change.
 */

import Foundation

/* ----------------------------------------------------------------- verdicts */

enum AuditVerdict: String, Codable {
    /// Working as intended, with evidence behind it.
    case healthy
    /// Not yet conclusive, and accumulating. Time fixes this.
    case waiting
    /// Cannot progress from here without a change. Time does not fix this.
    case blocked
    /// Actively wrong.
    case broken

    var label: String {
        switch self {
        case .healthy: return "Working"
        case .waiting: return "Gathering"
        case .blocked: return "Stuck"
        case .broken: return "Wrong"
        }
    }
}

struct AuditCheck: Codable, Identifiable {
    let id: String
    let question: String
    let verdict: AuditVerdict
    /// What was measured, in a sentence a person can act on.
    let finding: String
    /// What to do about it, when there is something to do.
    let remedy: String?
    /// The numbers behind the finding, for the screen to tabulate.
    var readings: [Reading] = []

    struct Reading: Codable {
        let name: String
        let value: String
        /// Set when this particular number is the problem.
        var flagged: Bool = false
    }
}

struct PredictAuditReport: Codable {
    let at: Double
    let checks: [AuditCheck]
    let candidates: [CandidateResult]
    let policy: PredictPolicy
    /// The one-line answer to "is it learning".
    let headline: String
    let verdict: AuditVerdict
    /// The bar a challenger has to clear, so the screen states the rule it is
    /// reporting against rather than repeating the constant.
    var promotionSigma: Double = PredictLearner.promotionSigma
}

/* ------------------------------------------------------------------ the audit */

enum PredictAudit {

    /**
     * The whole report.
     *
     * Pure over its inputs — a book, a brain, a policy and the realised bets — so
     * the self-test can hand it a book whose answer is known by construction and
     * check that a desk which *should* be reported stuck is reported stuck. An
     * audit that can only be exercised against live data is an audit nobody runs.
     */
    static func run(book: [ShadowWindow], brain: PredictBrain, policy: PredictPolicy,
                    bets: [SettledBet], minEdge: Double) -> PredictAuditReport {

        var checks: [AuditCheck] = []
        checks.append(inflow(book))
        checks.append(parameters(book, brain))
        let reach = reachability(book, brain: brain, policy: policy, minEdge: minEdge)
        checks.append(reach)
        let (contestCheck, results) = contest(book, policy: policy)
        checks.append(contestCheck)
        checks.append(fidelity(bets))

        // The worst verdict carries, because a healthy inflow does not offset a
        // desk that cannot act on it.
        let order: [AuditVerdict] = [.broken, .blocked, .waiting, .healthy]
        let verdict = order.first { v in checks.contains { $0.verdict == v } } ?? .healthy

        return PredictAuditReport(
            at: nowMs(), checks: checks, candidates: results, policy: policy,
            headline: headline(verdict, checks: checks, policy: policy),
            verdict: verdict)
    }

    private static func headline(_ verdict: AuditVerdict, checks: [AuditCheck],
                                 policy: PredictPolicy) -> String {
        switch verdict {
        case .broken:
            return "Something in the learning loop is wrong. " + (checks.first { $0.verdict == .broken }?.finding ?? "")
        case .blocked:
            return "The desk is learning, and what it has learned has stopped it being able to act. "
                + (checks.first { $0.verdict == .blocked }?.finding ?? "")
        case .waiting:
            return "The loop is turning and nothing has cleared its evidence bar yet. "
                + "That is the expected state early on: every window watched is written down, and the fits re-run as answers arrive."
        case .healthy:
            return policy.isDefault
                ? "The loop is working and its current conclusion is that the market price is the best available reading. "
                    + "That is a finding, not a failure, and it is re-tested every time evidence arrives."
                : "The loop is working and has promoted a reading that beats the market out of sample."
        }
    }

    /* ------------------------------------------------ 1. is evidence arriving */

    private static func inflow(_ book: [ShadowWindow]) -> AuditCheck {
        let resolved = book.filter { $0.resolved != nil }
        let degraded = book.filter(\.degraded)
        let usable = book.filter(\.isTrainable)
        let retired = resolved.filter { !$0.degraded && !$0.isCurrentOpen }
        let unresolved = book.count - resolved.count

        let span: Double = {
            guard let first = book.map(\.start).min(), let last = book.map(\.start).max(),
                  last > first else { return 0 }
            return (last - first) / 3600
        }()
        let rate = span > 0 ? Double(book.count) / span : 0
        let degradedShare = book.isEmpty ? 0 : Double(degraded.count) / Double(book.count)

        var readings: [AuditCheck.Reading] = [
            .init(name: "Windows recorded", value: "\(book.count)"),
            .init(name: "Resolved", value: "\(resolved.count)"),
            .init(name: "Still awaiting the resolver", value: "\(unresolved)"),
            .init(name: "Degraded feed, never fitted", value: "\(degraded.count)",
                  flagged: degradedShare > 0.25),
            .init(name: "Measured under an older open, never fitted", value: "\(retired.count)"),
            .init(name: "Usable — what every fit reads", value: "\(usable.count)"),
            .init(name: "Observed span", value: span > 0 ? "\(f(span, 1)) hours at \(f(rate, 1))/hour" : "—"),
        ]

        if book.isEmpty {
            return AuditCheck(
                id: "inflow", question: "Is evidence arriving?", verdict: .waiting,
                finding: "Nothing has been recorded yet. The book fills whenever a prediction run is open — "
                    + "every window it watches is written down whether or not it bets on one.",
                remedy: "Start a prediction run and leave it open.", readings: readings)
        }
        if degradedShare > 0.5 {
            readings[3].flagged = true
            return AuditCheck(
                id: "inflow", question: "Is evidence arriving?", verdict: .broken,
                finding: "\(f(degradedShare * 100, 0))% of recorded windows are marked degraded, and degraded windows are "
                    + "excluded from every fit. Most of what is being written down cannot be learned from.",
                remedy: "The live exchange feed is dropping to the Yahoo fallback. Until that is fixed the book grows and the fits do not.",
                readings: readings)
        }
        if usable.count < PredictBrain.feedMinimum && !retired.isEmpty {
            return AuditCheck(
                id: "inflow", question: "Is evidence arriving?", verdict: .waiting,
                finding: "The model changed: the open is now the minute's average the resolver uses, not a single tick. "
                    + "The \(retired.count) windows recorded before that scored a model that no longer exists, so they are "
                    + "kept for the record and no longer fitted. \(usable.count) windows under the current open so far; "
                    + "the feed gap refits at \(PredictBrain.feedMinimum), the model weight at \(PredictBrain.weightMinimum), "
                    + "and the contest runs at \(PredictLearner.minimumWindows). Until then the desk uses the shipped defaults.",
                remedy: nil, readings: readings)
        }
        if usable.count < PredictBrain.feedMinimum {
            return AuditCheck(
                id: "inflow", question: "Is evidence arriving?", verdict: .waiting,
                finding: "\(usable.count) usable windows on record. The first fit needs \(PredictBrain.feedMinimum).",
                remedy: nil, readings: readings)
        }
        return AuditCheck(
            id: "inflow", question: "Is evidence arriving?", verdict: .healthy,
            finding: "\(usable.count) resolved, undegraded windows are available to fit on.",
            remedy: nil, readings: readings)
    }

    /* ----------------------------------------------- 2. has anything moved */

    private static func parameters(_ book: [ShadowWindow], _ brain: PredictBrain) -> AuditCheck {
        let usable = book.filter(\.isTrainable).count
        // The regime fit reads every resolved window, not only the trainable ones:
        // its features come from the tape's shape rather than from the open rule.
        let resolvedCount = book.filter { $0.resolved != nil }.count
        let readings: [AuditCheck.Reading] = [
            .init(name: "Feed gap",
                  value: brain.feedIsDefault
                      ? "\(f(brain.feedNoiseBps, 1)) bps — still the shipped default (\(usable)/\(PredictBrain.feedMinimum) windows)"
                      : "\(f(brain.feedNoiseBps, 1)) bps, fitted on \(brain.feedWindows) windows",
                  flagged: brain.feedIsDefault),
            .init(name: "Model weight",
                  value: brain.weightIsDefault
                      ? "\(f(brain.modelWeight * 100, 0))% — still the shipped default (\(usable)/\(PredictBrain.weightMinimum) windows)"
                      : "\(f(brain.modelWeight * 100, 1))%, fitted on \(brain.weightWindows) windows",
                  flagged: !brain.weightIsDefault && brain.modelWeight <= 0.001),
            .init(name: "Entry offset",
                  value: brain.offsetIsDefault
                      ? "\(f(brain.entryOffsetSeconds, 0))s — never fitted (\(brain.offsetSamples) qualifying looks)"
                      : "\(f(brain.entryOffsetSeconds, 0))s, fitted on \(brain.offsetSamples) looks",
                  flagged: brain.offsetIsDefault && brain.offsetSamples == 0),
            .init(name: "Cross-window regime",
                  value: brain.regime.isDefault
                      ? "not fitted — needs 300 resolved windows, has \(resolvedCount)"
                      : "fitted on \(brain.regime.windows) windows",
                  flagged: brain.regime.isDefault),
        ]

        let moved = [!brain.feedIsDefault, !brain.weightIsDefault,
                     !brain.offsetIsDefault, !brain.regime.isDefault].filter { $0 }.count

        /* A fitted weight of exactly zero is the finding that matters most here, and
         * it is not a "gathering" state — it is a conclusion, and a consequential
         * one. Flagged in its own right so it is not read as another empty slot. */
        if !brain.weightIsDefault && brain.modelWeight <= 0.001 {
            return AuditCheck(
                id: "parameters", question: "Has anything actually been learned?", verdict: .healthy,
                finding: "\(moved) of 4 parameters have moved off their defaults. The model weight was fitted to "
                    + "\(f(brain.modelWeight * 100, 1))%, which is the measured finding that the path model adds nothing "
                    + "to the market price on this book. That is real learning and a real result.",
                remedy: "See the reachability check below for what that weight does to the desk's ability to act.",
                readings: readings)
        }
        if moved == 0 {
            return AuditCheck(
                id: "parameters", question: "Has anything actually been learned?", verdict: .waiting,
                finding: "Nothing has moved off its shipped default yet. Every fit is still below its evidence threshold.",
                remedy: nil, readings: readings)
        }
        return AuditCheck(
            id: "parameters", question: "Has anything actually been learned?", verdict: .healthy,
            finding: "\(moved) of 4 fitted parameters have moved off their shipped defaults on measured evidence.",
            remedy: nil, readings: readings)
    }

    /* ------------------------------------------- 3. can the desk still act */

    /**
     * The check the old system had no way to perform.
     *
     * Replays the book under the parameters currently in force and counts how many
     * moments would have cleared the edge bar. Zero is not a quiet statistic — it
     * means the desk cannot bet, cannot therefore produce a bet outcome, and
     * cannot feed the one fit that learns from qualifying looks. Reported against
     * the same count under the shipped defaults, because the gap between the two
     * is the entire diagnosis.
     */
    private static func reachability(_ book: [ShadowWindow], brain: PredictBrain,
                                     policy: PredictPolicy, minEdge: Double) -> AuditCheck {
        let usable = book.filter(\.isTrainable)
        let live = qualifyingLooks(usable, weight: brain.modelWeight, policy: policy, minEdge: minEdge)
        let shipped = qualifyingLooks(usable, weight: PredictModel.defaultMaxWeight,
                                      policy: nil, minEdge: minEdge)

        let readings: [AuditCheck.Reading] = [
            .init(name: "Qualifying looks, as configured", value: "\(live)", flagged: live == 0),
            .init(name: "…at the shipped \(f(PredictModel.defaultMaxWeight * 100, 0))% weight", value: "\(shipped)"),
            .init(name: "Edge required", value: cents(minEdge)),
            .init(name: "Reading in force",
                  value: policy.isDefault ? "the market price alone" : policy.candidateId),
        ]

        guard !usable.isEmpty else {
            return AuditCheck(
                id: "reach", question: "Can the desk still act on what it knows?", verdict: .waiting,
                finding: "No resolved windows to replay yet.", remedy: nil, readings: readings)
        }

        /* Idle by measurement. The weight has been fitted to zero on windows scored
         * under the current open, and nothing in the contest beats the price, so the
         * desk reads the market and has no edge over it. Before 4.16.0 this was an
         * absorbing state and reported `blocked`; it is not one any more. The weight
         * is re-swept over the whole current book every two minutes and can rise,
         * and the contest re-scores hourly and can promote a reading that sees a
         * residual. What it is, is a finding — and calling it STUCK sent people
         * looking for a fault in a desk that had correctly concluded it had no edge. */
        if live == 0 && shipped > 0 && !brain.weightIsDefault && policy.isDefault {
            return AuditCheck(
                id: "reach", question: "Can the desk still act on what it knows?", verdict: .healthy,
                finding: "Idle, and correctly. Over \(usable.count) resolved windows the model weight fitted to "
                    + "\(f(brain.modelWeight * 100, 1))% and nothing in the contest beats the price, so the desk reads the "
                    + "market, and a desk reading the market has no edge over it. At the shipped "
                    + "\(f(PredictModel.defaultMaxWeight * 100, 0))% it would have found \(shipped) looks — which is the "
                    + "model being trusted more than it has earned, not missed opportunity.",
                remedy: "Nothing to fix. The weight is re-fitted every two minutes and the contest every hour, on every "
                    + "window watched, so an edge that appears will be found without anyone intervening.",
                readings: readings)
        }
        if live == 0 && shipped > 0 {
            return AuditCheck(
                id: "reach", question: "Can the desk still act on what it knows?", verdict: .blocked,
                finding: "Replayed over \(usable.count) resolved windows, the desk as configured would have found "
                    + "no moment at all worth betting — against \(shipped) at the shipped defaults, and neither the "
                    + "fitted weight nor the contest accounts for the difference.",
                remedy: "Compare the reading in force with the contest below: a promoted reading that can never "
                    + "clear the bar is a promotion the contest should not have made.",
                readings: readings)
        }
        if live == 0 {
            return AuditCheck(
                id: "reach", question: "Can the desk still act on what it knows?", verdict: .blocked,
                finding: "No moment in \(usable.count) resolved windows would have cleared the \(cents(minEdge)) bar, "
                    + "under any weight. The market's prices and the desk's readings agree too closely for an edge to exist.",
                remedy: "Either the bar is set above anything this market offers, or there is genuinely no edge here. "
                    + "The contest below distinguishes those two.",
                readings: readings)
        }
        return AuditCheck(
            id: "reach", question: "Can the desk still act on what it knows?", verdict: .healthy,
            finding: "\(live) moments across \(usable.count) resolved windows would have cleared the \(cents(minEdge)) bar, "
                + "so the desk can still find something to do and the fits that depend on qualifying looks can still be fed.",
            remedy: nil, readings: readings)
    }

    /**
     * Replays the edge test over a book and counts the moments that would have
     * cleared the bar.
     *
     * Walks the same rows the learner builds, in the same order, so the policy's
     * probability and the sample it came from cannot drift apart — an earlier
     * version matched them up through a dictionary keyed on a formatted `Double`,
     * which is a way of being wrong that never announces itself. `asks` carries
     * the two prices alongside each row, since the learner has no use for them and
     * this has no use for anything else.
     */
    static func qualifyingLooks(_ book: [ShadowWindow], weight: Double,
                                policy: PredictPolicy?, minEdge: Double) -> Int {
        let rows = PredictLearner.rows(book)
        let asks = PredictLearner.asks(book)
        guard rows.count == asks.count else { return 0 }

        var count = 0
        for (row, ask) in zip(rows, asks) {
            let pUp: Double
            if let policy, !policy.isDefault {
                pUp = policy.probability(row)
            } else {
                // The old blend, which is what the desk runs when nothing has been
                // promoted: the market's logit and the model's, mixed at `weight`.
                let mixed = weight * row.logitModel + (1 - weight) * row.logitMarket
                pUp = Analysis.clamp(1 / (1 + exp(-mixed)), 0.005, 0.995)
            }
            guard let best = PredictModel.cheaperSide(pUp: pUp, upAsk: ask.up, downAsk: ask.down),
                  best.ask > 0.01, best.edge >= minEdge else { continue }
            count += 1
        }
        return count
    }

    /* ------------------------------------------------ 4. is the learning good */

    private static func contest(_ book: [ShadowWindow], policy: PredictPolicy)
        -> (AuditCheck, [CandidateResult]) {
        let (results, winner) = PredictLearner.contest(book, champion: policy)
        let windows = book.filter(\.isTrainable).count

        var readings = results.map {
            AuditCheck.Reading(
                name: $0.label,
                value: "Brier \(f($0.oosBrier, 5)) · \($0.gainOverChampion >= 0 ? "+" : "")\(f($0.gainOverChampion, 5)) vs champion · \(f($0.sigma, 1))σ",
                flagged: $0.promotable)
        }
        readings.insert(.init(name: "Promotion bar",
                              value: "\(f(PredictLearner.promotionSigma, 0)) clustered standard errors"), at: 0)

        guard results.count > 0 else {
            return (AuditCheck(
                id: "contest", question: "Is anything better than the market?", verdict: .waiting,
                finding: "\(windows) usable windows against the \(PredictLearner.minimumWindows) the contest needs. "
                    + "Below that the standard error is wider than any effect worth acting on.",
                remedy: nil, readings: readings), results)
        }

        if let winner {
            return (AuditCheck(
                id: "contest", question: "Is anything better than the market?", verdict: .healthy,
                finding: "\(winner.label) beats the reading in force by \(f(winner.gainOverChampion, 5)) Brier "
                    + "at \(f(winner.sigma, 1)) standard errors, on windows it was never fitted on.",
                remedy: nil, readings: readings), results)
        }

        // The champion is in the field as the baseline — it scores against itself,
        // so it is always "closest" and naming it here would be circular.
        let best = results.first { $0.id != policy.candidateId }
        let incumbent = policy.isDefault ? "the market price" : (PredictCandidate.of(policy.candidateId)?.label ?? policy.candidateId)
        let closest = best.map {
            "The closest challenger is \($0.label.lowercased()), "
                + ($0.gainOverChampion >= 0
                    ? "better by \(f($0.gainOverChampion, 5)) Brier at \(f($0.sigma, 1))σ"
                    : "\(f(-$0.gainOverChampion, 5)) Brier worse")
                + ", against a bar of \(f(PredictLearner.promotionSigma, 0))σ. "
        } ?? ""
        return (AuditCheck(
            id: "contest", question: "Is anything better than the market?", verdict: .healthy,
            finding: "Nothing beats \(incumbent). " + closest
                + "On this evidence it is the best reading available.",
            remedy: "This is a finding rather than a fault. It is re-tested on every contest, so a residual that "
                + "appears as the book grows will be found and promoted without anyone intervening.",
            readings: readings), results)
    }

    /* --------------------------------------- 5. does the record match rehearsal */

    /**
     * The shadow book assumes a fill at the best ask. A real bet walks the book.
     *
     * This is the one check that can catch the rehearsal being wrong about the
     * *world* rather than about the model, and it is the check the old system had
     * no way to make at all — the fits read the shadow book and nothing read the
     * bets. It is also how the 4.14.0 stake-cap failure would have been caught in
     * one window instead of six: every one of those bets filled at four to twenty
     * times the price the shadow book assumed, and that is exactly the quantity
     * measured here.
     */
    private static func fidelity(_ bets: [SettledBet]) -> AuditCheck {
        guard !bets.isEmpty else {
            return AuditCheck(
                id: "fidelity", question: "Does the real record match the rehearsal?", verdict: .waiting,
                finding: "No settled bets to compare against. The shadow book's assumptions are untested by anything real.",
                remedy: nil,
                readings: [.init(name: "Settled bets", value: "0")])
        }

        /* The floor is a hair above zero, not a tenth of a cent.
         *
         * An earlier version skipped any bet whose expected ask was at or below
         * 0.001, on the reasoning that a price that small is not a real quote. It
         * is the opposite: a dust order at a tenth of a cent sitting on top of the
         * book is exactly the configuration that produced the 4.14.0 losses, where
         * the fill averaged twenty times the ask. Excluding those from the
         * measurement excludes the only bets it was built to catch. */
        let slips = bets.compactMap { bet -> Double? in
            guard bet.expectedAsk > 1e-9, bet.filledAsk > 0 else { return nil }
            return (bet.filledAsk - bet.expectedAsk) / bet.expectedAsk
        }
        let meanSlip = slips.isEmpty ? 0 : slips.reduce(0, +) / Double(slips.count)
        let worst = slips.max() ?? 0
        let wins = bets.filter { $0.pnl > 0 }.count
        let net = bets.reduce(0) { $0 + $1.pnl }

        var readings: [AuditCheck.Reading] = [
            .init(name: "Settled bets", value: "\(bets.count)"),
            .init(name: "Won", value: "\(wins) of \(bets.count)"),
            .init(name: "Net", value: money(net), flagged: net < 0),
            .init(name: "Average fill vs the ask assumed",
                  value: meanSlip >= 0 ? "+\(f(meanSlip * 100, 1))% worse" : "\(f(meanSlip * 100, 1))% better",
                  flagged: meanSlip > 0.15),
            .init(name: "Worst single fill",
                  value: "+\(f(worst * 100, 0))% worse", flagged: worst > 0.5),
        ]
        if slips.isEmpty { readings.removeLast(2) }

        if worst > 1.0 {
            return AuditCheck(
                id: "fidelity", question: "Does the real record match the rehearsal?", verdict: .broken,
                finding: "At least one bet filled at more than twice the price the shadow book assumed. Every fit in the "
                    + "system is trained on the assumption that a contract can be bought at the best ask, and on this "
                    + "evidence it cannot.",
                remedy: "Until the gap is closed the learned parameters are optimistic by an unknown amount, because they "
                    + "are fitted on returns that were never achievable.",
                readings: readings)
        }
        if meanSlip > 0.15 {
            return AuditCheck(
                id: "fidelity", question: "Does the real record match the rehearsal?", verdict: .blocked,
                finding: "Real fills come in \(f(meanSlip * 100, 0))% worse than the best ask the shadow book scores against, "
                    + "so every fitted return is optimistic by roughly that much.",
                remedy: "Score the book against a depth-aware fill rather than the best ask.",
                readings: readings)
        }
        return AuditCheck(
            id: "fidelity", question: "Does the real record match the rehearsal?", verdict: .healthy,
            finding: "Real fills land within \(f(abs(meanSlip) * 100, 1))% of the price the shadow book assumes, "
                + "so what it scores is close to what the desk could actually have got.",
            remedy: nil, readings: readings)
    }

    private static func cents(_ v: Double) -> String { "\(f(v * 100, 1))¢" }
}

/* ---------------------------------------------------------------- the bets */

/**
 * A bet that has settled, reduced to what the audit needs.
 *
 * `expectedAsk` against `filledAsk` is the whole point: the first is what the
 * shadow book assumed was buyable, the second is what the order actually paid
 * after walking the book. Everything the learning system believes about returns
 * rests on those two being close, and nothing was checking.
 */
struct SettledBet: Codable {
    let at: Double
    let side: String
    /// Best ask at the moment the decision was taken — what the shadow book scores.
    let expectedAsk: Double
    /// Average price actually paid across the fill.
    let filledAsk: Double
    let stake: Double
    let pnl: Double
    let won: Bool

    init(at: Double, side: String, expectedAsk: Double, filledAsk: Double,
         stake: Double, pnl: Double, won: Bool) {
        self.at = at; self.side = side
        self.expectedAsk = expectedAsk; self.filledAsk = filledAsk
        self.stake = stake; self.pnl = pnl; self.won = won
    }

    /// Decoded by hand, like everything else that reaches disk. Nothing here is
    /// identifying: a settled bet missing a field is a weaker observation, not a
    /// reason to make the whole file of them unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? ""
        expectedAsk = try c.decodeIfPresent(Double.self, forKey: .expectedAsk) ?? 0
        filledAsk = try c.decodeIfPresent(Double.self, forKey: .filledAsk) ?? 0
        stake = try c.decodeIfPresent(Double.self, forKey: .stake) ?? 0
        pnl = try c.decodeIfPresent(Double.self, forKey: .pnl) ?? 0
        won = try c.decodeIfPresent(Bool.self, forKey: .won) ?? (pnl > 0)
    }
}
