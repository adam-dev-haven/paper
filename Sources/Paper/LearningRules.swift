/**
 * LearningRules.swift — how a measurement becomes a proposal.
 *
 * Each rule below answers one question the record can actually settle, states the
 * number that settles it, and names the single dial or habit that follows. They
 * are deliberately conservative:
 *
 *   - Every rule carries a minimum sample. Under it the finding is still shown,
 *     marked *watching*, so a user can see a pattern forming before the app claims
 *     it. Three trades is an anecdote, and an app that retunes itself on three
 *     trades is teaching the worst lesson in the market.
 *   - Every step is small. A whipsaw problem widens stops by 15%, not by half. Two
 *     runs of evidence move it twice; one run cannot move it far.
 *   - A rule that stops finding its evidence retires itself, so the calibration
 *     drifts back rather than accumulating forever.
 *
 * The engine's own picks and the user's own execution are graded separately and
 * produce different kinds of lesson. "The stops are too tight" is a dial. "You
 * sell winners after two days" is not a dial, and pretending it is would let
 * someone tune away a habit instead of noticing it.
 */

import Foundation

extension Learning {

    private static func lesson(
        kind: String, title: String, finding: String, reasoning: String,
        evidence: [String], sample: Int, minSample: Int,
        adjustment: Adjustment?, source: String = "engine"
    ) -> Lesson {
        let ratio = Double(sample) / Double(Swift.max(minSample, 1))
        return Lesson(
            id: kind, kind: kind, title: title, finding: finding, reasoning: reasoning,
            evidence: evidence, sampleSize: sample,
            confidence: Analysis.clamp(0.35 + 0.4 * Swift.min(ratio, 2) / 2, 0, 0.95),
            adjustment: sample >= minSample ? adjustment : nil,
            status: sample >= minSample ? .proposed : .watching,
            source: source, createdAt: nowMs(), updatedAt: nowMs(),
            appliedAt: nil, runsSinceApplied: 0, outcomeNote: nil
        )
    }

    private static func pct(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) * 100 : 0
    }

    /* ------------------------------------------------- grading the engine */

    /**
     * What the recommendations did, taken or not.
     *
     * This is the half that can actually recalibrate the risk engine, because it
     * separates "the plan was wrong" from "the plan was fine and it was traded
     * badly". A stop that gets hit and then recovers is a stop inside the noise
     * whether or not anyone was in the trade.
     */
    static func engineLessons(_ runs: [RunRecord], current: Calibration) -> [Lesson] {
        let outcomes = runs.flatMap { run in run.outcomes.map { (run, $0) } }
        let picksBySymbol = Dictionary(
            runs.flatMap { run in run.picks.map { ($0.symbol + "|" + String(Int(run.at)), $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        func pick(for run: RunRecord, _ o: PickOutcome) -> RunPick? {
            picksBySymbol[o.symbol + "|" + String(Int(run.at))]
        }

        guard !outcomes.isEmpty else { return [] }
        var out: [Lesson] = []

        /* --- stops inside the noise ---------------------------------------- */

        let stopped = outcomes.filter { $0.1.hitStop }
        let recovered = stopped.filter { $0.1.recoveredAfterStop }
        if !stopped.isEmpty {
            let rate = pct(recovered.count, stopped.count)
            if rate >= 40 {
                out.append(lesson(
                    kind: "engine-stops-too-tight",
                    title: "The stops are being placed inside the ordinary noise",
                    finding: "\(recovered.count) of \(stopped.count) recommended stops were hit and then traded back above the entry price afterwards — \(f(rate, 0))% of them.",
                    reasoning: "A stop marks the point where the reason for the trade has stopped being true. When price crosses it and then recovers, the level sat inside the instrument's normal daily travel, so an ordinary session was enough to trigger it. Widening it costs more on the trades that do fail. Position size falls as the stop widens, so the money at risk is unchanged.",
                    evidence: recovered.prefix(4).map { "\($0.1.symbol): stopped out, then traded back to \(f(($0.1.mfeR ?? 0), 2))R above the entry" },
                    sample: stopped.count, minSample: 5,
                    adjustment: Adjustment(knob: .stopScale, from: current.stopScale, to: current.stopScale * 1.15)
                ))
            } else if rate <= 10 && stopped.count >= 8 {
                out.append(lesson(
                    kind: "engine-stops-generous",
                    title: "The stops are wider than they need to be",
                    finding: "Only \(recovered.count) of \(stopped.count) stopped-out recommendations recovered above their entry afterwards.",
                    reasoning: "Stops that are hit and never recover were placed correctly: the trade had failed. There is room to bring them in. A tighter stop means a smaller loss when the idea fails and a larger position for the same money at risk when it works.",
                    evidence: ["\(f(rate, 0))% recovery rate after a stop, against the 40% that would say the stops are too tight"],
                    sample: stopped.count, minSample: 8,
                    adjustment: Adjustment(knob: .stopScale, from: current.stopScale, to: current.stopScale * 0.92)
                ))
            }
        }

        /* --- targets --------------------------------------------------------- */

        let targeted = outcomes.filter { $0.1.hitTarget }
        let ranOn = targeted.filter { $0.1.ranOnAfterTarget }
        if !targeted.isEmpty, pct(ranOn.count, targeted.count) >= 50 {
            out.append(lesson(
                kind: "engine-targets-too-near",
                title: "Targets are being set short of where the moves actually go",
                finding: "\(ranOn.count) of \(targeted.count) recommendations that reached their target went on to travel at least another full unit of risk beyond it.",
                reasoning: "Taking a gain at a level price then passes through is a cost that a win rate does not show. Pushing the target out lowers the hit rate and raises what each hit is worth, which is the trade-off this engine already funds on.",
                evidence: ranOn.prefix(4).map { "\($0.1.symbol): target hit, then ran to \(f($0.1.mfeR ?? 0, 2))R" },
                sample: targeted.count, minSample: 5,
                adjustment: Adjustment(knob: .targetScale, from: current.targetScale, to: current.targetScale * 1.15)
            ))
        }

        let unresolved = outcomes.filter { !$0.1.resolved && $0.1.sessionsObserved >= 10 }
        let stalledNear = unresolved.filter { ($0.1.mfeR ?? 0) >= 0.7 }
        if unresolved.count >= 5, pct(stalledNear.count, unresolved.count) >= 55 {
            out.append(lesson(
                kind: "engine-targets-too-far",
                title: "Targets sit just past where the moves keep stopping",
                finding: "\(stalledNear.count) of \(unresolved.count) unresolved recommendations came within reach of their target — better than 0.7 of the way in units of risk — and then turned back without touching it.",
                reasoning: "A target repeatedly approached and never reached is a gain that was available and not taken. Pulling it in converts near-misses into closed winners, at the cost of the occasional move that runs further.",
                evidence: stalledNear.prefix(4).map { "\($0.1.symbol): reached \(f($0.1.mfeR ?? 0, 2))R of a \(f(pick(for: $0.0, $0.1).map { ($0.target - $0.entry) / Swift.max($0.entry - $0.stop, 0.0001) } ?? 0, 2))R target, then turned" },
                sample: unresolved.count, minSample: 5,
                adjustment: Adjustment(knob: .targetScale, from: current.targetScale, to: current.targetScale * 0.9)
            ))
        }

        /* --- how long the plans actually take -------------------------------- */

        let resolvedWithTime = outcomes.compactMap { $0.1.sessionsToResolve }
        if resolvedWithTime.count >= 6 {
            let avg = Double(resolvedWithTime.reduce(0, +)) / Double(resolvedWithTime.count)
            let expected = outcomes.compactMap { pick(for: $0.0, $0.1)?.horizonDays }
            if !expected.isEmpty {
                let avgExpected = expected.reduce(0, +) / Double(expected.count)
                if avg > avgExpected * 1.6 {
                    out.append(lesson(
                        kind: "engine-plans-run-long",
                        title: "Plans are taking far longer to resolve than the engine expects",
                        finding: "Recommendations resolved in \(f(avg, 0)) sessions on average, against the \(f(avgExpected, 0)) the plans projected.",
                        reasoning: "The projection decides whether a setup fits this account's horizon. If it is systematically short, setups are being funded that tie capital up longer than the profile intends, and setups refused for taking too long may have been the right ones.",
                        evidence: ["\(resolvedWithTime.count) resolved recommendations, \(f(avg, 0)) sessions on average against a \(f(avgExpected, 0))-session projection"],
                        sample: resolvedWithTime.count, minSample: 6,
                        adjustment: Adjustment(knob: .holdScale, from: current.holdScale, to: current.holdScale * 1.2)
                    ))
                }
            }
        }

        /* --- is the conviction score worth anything? ------------------------- */

        let scored = outcomes.compactMap { o -> (Double, Double)? in
            guard let p = pick(for: o.0, o.1), let r = o.1.rMultiple else { return nil }
            return (p.conviction, r)
        }
        if scored.count >= 8 {
            let high = scored.filter { $0.0 >= 65 }.map(\.1)
            let low = scored.filter { $0.0 < 65 }.map(\.1)
            if high.count >= 3, low.count >= 3 {
                let avgHigh = high.reduce(0, +) / Double(high.count)
                let avgLow = low.reduce(0, +) / Double(low.count)
                if avgHigh - avgLow > 0.4 && avgLow < 0 {
                    out.append(lesson(
                        kind: "engine-conviction-floor",
                        title: "Low-conviction picks are the ones losing money",
                        finding: "Recommendations scoring 65 or better returned \(f(avgHigh, 2))R on average; those under 65 returned \(f(avgLow, 2))R.",
                        reasoning: "The quantitative score is separating outcomes, and the bottom half is not paying for its risk. A floor refuses anything under it, which raises the average idea and reduces the number of trades.",
                        evidence: ["\(high.count) picks at 65+: \(f(avgHigh, 2))R average", "\(low.count) picks under 65: \(f(avgLow, 2))R average"],
                        sample: scored.count, minSample: 8,
                        adjustment: Adjustment(knob: .convictionFloor, from: current.convictionFloor, to: Swift.max(current.convictionFloor, 60))
                    ))
                }
            }
        }

        /* --- where the picks work, and where they do not --------------------- */

        out.append(contentsOf: keyedBias(
            outcomes, pick: pick, knob: .sectorBias, current: current.sectorBias,
            key: { p, _ in p.sector }, noun: "sector"
        ))
        out.append(contentsOf: keyedBias(
            outcomes, pick: pick, knob: .regimeBias, current: current.regimeBias,
            key: { p, _ in p.regime }, noun: "market regime"
        ))

        /* --- volatility ------------------------------------------------------ */

        let byVol = outcomes.compactMap { o -> (Double, Double)? in
            guard let p = pick(for: o.0, o.1), let atr = p.atrPct, let r = o.1.rMultiple else { return nil }
            return (atr, r)
        }
        if byVol.count >= 8 {
            let sorted = byVol.sorted { $0.0 < $1.0 }
            let topThird = Array(sorted.suffix(Swift.max(3, sorted.count / 3)))
            let rest = Array(sorted.prefix(sorted.count - topThird.count))

            // A tercile split over values that barely differ is not a finding about
            // volatility, it is a finding about the sort order. Unless the fast third
            // is genuinely faster, whatever separated these outcomes was something
            // else, and attributing it to volatility would tune the wrong dial.
            let spread = (topThird.first?.0 ?? 0) - (rest.last?.0 ?? 0)
            let separated = spread >= 0.5

            if rest.count >= 3, separated {
                let avgTop = topThird.map(\.1).reduce(0, +) / Double(topThird.count)
                let avgRest = rest.map(\.1).reduce(0, +) / Double(rest.count)
                if avgTop < -0.2 && avgRest > avgTop + 0.5 {
                    out.append(lesson(
                        kind: "engine-volatility-drag",
                        title: "The fastest-moving names are where the losses are",
                        finding: "The third of recommendations with the widest daily range returned \(f(avgTop, 2))R; the rest returned \(f(avgRest, 2))R.",
                        reasoning: "A wider daily range puts the stop further out, which means a smaller position for the same money at risk, and it means an ordinary session can cover the whole distance between entry and stop. Lowering the volatility ceiling refuses those instruments rather than sizing them down.",
                        evidence: [
                            "widest third by daily range, \(f(topThird.first?.0 ?? 0, 1))% and above (\(topThird.count) picks): \(f(avgTop, 2))R",
                            "the rest, up to \(f(rest.last?.0 ?? 0, 1))% (\(rest.count) picks): \(f(avgRest, 2))R",
                        ],
                        sample: byVol.count, minSample: 8,
                        adjustment: Adjustment(knob: .rangeCeiling, from: current.rangeCeilingScale, to: current.rangeCeilingScale * 0.85)
                    ))
                }
            }
        }

        return out
    }

    /// Sector and regime read the same way, so they share one implementation rather
    /// than two that drift apart.
    private static func keyedBias(
        _ outcomes: [(RunRecord, PickOutcome)],
        pick: (RunRecord, PickOutcome) -> RunPick?,
        knob: Knob, current: [String: Double],
        key: (RunPick, PickOutcome) -> String, noun: String
    ) -> [Lesson] {
        var buckets: [String: [Double]] = [:]
        for (run, outcome) in outcomes {
            guard let p = pick(run, outcome), let r = outcome.rMultiple else { continue }
            buckets[key(p, outcome), default: []].append(r)
        }

        return buckets.compactMap { name, results -> Lesson? in
            guard results.count >= 4 else { return nil }
            let avg = results.reduce(0, +) / Double(results.count)
            guard abs(avg) >= 0.45 else { return nil }
            let good = avg > 0
            let step = good ? 6.0 : -8.0     // the engine leans away faster than it leans in
            let existing = current[name] ?? 0
            return lesson(
                kind: "engine-\(knob.rawValue)-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: good
                    ? "\(name) has been paying for its risk here"
                    : "\(name) has been costing money here",
                finding: "\(results.count) recommendations in \(name) averaged \(f(avg, 2))R.",
                reasoning: good
                    ? "A small conviction bonus moves \(name) up the ranking when two setups are otherwise close, and does nothing when they are not. \(results.count) results is enough to tilt an ordering and not enough to justify concentrating in one \(noun)."
                    : "A small conviction penalty pushes \(name) down the ranking rather than excluding it. If the underlying reason is temporary the bias fades as the record fills in. The levels and sizing are untouched; only the ordering moves.",
                evidence: ["\(results.count) picks in \(name), \(f(avg, 2))R average, \(results.filter { $0 > 0 }.count) of them positive"],
                sample: results.count, minSample: 4,
                adjustment: Adjustment(knob: knob, key: name, from: existing, to: existing + step)
            )
        }
    }

    /* --------------------------------------------- grading the person */

    /**
     * What the execution says, which is a different subject from what the picks say.
     *
     * These mostly produce rules rather than dials. There is no parameter that fixes
     * selling a winner after two days, and offering one would let someone tune the
     * finding away instead of reading it.
     */
    static func behaviourLessons(_ reviews: [TradeReview], _ behaviour: BehaviourReport,
                                 _ scorecard: Scorecard, _ profile: Profile,
                                 current: Calibration) -> [Lesson] {
        var out: [Lesson] = []
        let n = behaviour.trades
        guard n > 0 else { return [] }

        /* --- stops that were inside the noise, from the trades actually taken -- */

        if behaviour.whipsawCount > 0 {
            let rate = pct(behaviour.whipsawCount, n)
            if rate >= 30 {
                out.append(lesson(
                    kind: "behaviour-whipsaw",
                    title: "You are being stopped out of trades that then recover",
                    finding: "\(behaviour.whipsawCount) of \(n) closed trades were stopped out and then traded back above the entry.",
                    reasoning: "This is the same finding the engine makes about its own recommendations, arriving from your actual fills. The stop is sitting inside the instrument's normal daily travel rather than at the point the idea fails. Widening it does not increase what is at risk; the position gets smaller by the same amount.",
                    evidence: reviews.filter { $0.verdict == .whipsawed }.prefix(4).map {
                        "\($0.symbol): stopped at \(f($0.exit, 2)), best afterwards \(f($0.postExitBestPct ?? 0, 1))% above the exit"
                    },
                    sample: n, minSample: 5,
                    adjustment: Adjustment(knob: .stopScale, from: current.stopScale, to: current.stopScale * 1.12)
                ))
            }
        }

        /* --- exits ----------------------------------------------------------- */

        if behaviour.soldTooEarlyCount > 0, pct(behaviour.soldTooEarlyCount, n) >= 30 {
            out.append(lesson(
                kind: "behaviour-sold-early",
                title: "You close winners before the plan says to",
                finding: "\(behaviour.soldTooEarlyCount) of \(n) closed trades kept running after the exit"
                    + (behaviour.captureRatePct.map { ", and you captured \(f($0, 0))% of the move that was available on average" } ?? "")
                    + ". Left on the table: \(money(behaviour.totalLeftOnTable)).",
                reasoning: "This is not a levels problem: the targets were reached or nearly reached and the exit came early anyway. Losses are running their full distance and wins are not. The bracket is already attached when a trade opens, so the change is to let it fire rather than closing by hand.",
                evidence: reviews.filter { $0.verdict == .soldTooEarly }.prefix(4).map {
                    "\($0.symbol): exited at \(f($0.exit, 2)), ran \(f($0.postExitBestPct ?? 0, 1))% further"
                },
                sample: n, minSample: 5, adjustment: nil
            ))
        }

        if behaviour.gaveItBackCount > 0, pct(behaviour.gaveItBackCount, n) >= 25 {
            out.append(lesson(
                kind: "behaviour-gave-it-back",
                title: "Positions that were well ahead are being closed near flat",
                finding: "\(behaviour.gaveItBackCount) of \(n) closed trades were meaningfully in profit at some point and finished at or below break-even.",
                reasoning: "An open profit is not a realised one. The standard response is mechanical: once a position is a full unit of risk ahead, move the stop to the entry price. That converts the worst outcome from a loss into a scratch, and it is a change to the bracket rather than a decision made while the position is moving.",
                evidence: reviews.filter { $0.verdict == .gaveItBack }.prefix(4).map {
                    "\($0.symbol): reached \(f($0.mfePct, 1))% ahead, closed at \(f(($0.exit - $0.entry) / Swift.max($0.entry, 0.0001) * 100, 1))%"
                },
                sample: n, minSample: 4, adjustment: nil
            ))
        }

        /* --- hold time ------------------------------------------------------- */

        if let asym = behaviour.holdAsymmetryDays, asym < -0.5,
           let w = behaviour.avgHoldWinnersDays, let l = behaviour.avgHoldLosersDays {
            out.append(lesson(
                kind: "behaviour-hold-asymmetry",
                title: "You hold losers longer than winners",
                finding: "Winners are held \(f(w, 1)) days on average, losers \(f(l, 1)).",
                reasoning: "Winners are being held for less time than losers, which is the asymmetry reversed. Neither exit is being made on a view of the instrument. The bracket already holds both levels, and using them removes the decision.",
                evidence: ["winners \(f(w, 1)) days, losers \(f(l, 1)) days: a \(f(abs(asym), 1))-day gap in the wrong direction"],
                sample: n, minSample: 6, adjustment: nil
            ))
        }

        /* --- discipline ------------------------------------------------------ */

        if behaviour.positionsWithoutStop > 0 {
            out.append(lesson(
                kind: "behaviour-no-stop",
                title: "Positions are being opened without a stop",
                finding: "\(behaviour.positionsWithoutStop) closed position\(behaviour.positionsWithoutStop == 1 ? " was" : "s were") held with no stop attached.",
                reasoning: "Without a stop there is no risk per trade and therefore no computed position size. The account's stated risk limit was not applied to those trades.",
                evidence: ["\(behaviour.positionsWithoutStop) of \(n) closed trades carried no stop"],
                sample: n, minSample: 1, adjustment: nil
            ))
        }

        /* --- what the frequency costs ---------------------------------------- */

        let costs = scorecard.totalCommission + scorecard.totalSlippage + scorecard.totalTax
        if let gross = scorecard.pnlBeforeCosts, abs(gross) > 0, scorecard.closedTrades >= 8 {
            let drag = costs / abs(gross) * 100
            if drag >= 30 {
                out.append(lesson(
                    kind: "behaviour-cost-drag",
                    title: "Costs are a large share of the result",
                    finding: "\(money(costs)) in spread, commission and tax against \(money(abs(gross))) of gross profit and loss — \(f(drag, 0))%.",
                    reasoning: "Every round trip pays the spread twice and the commission twice, and a gain realised inside a year pays the higher tax rate. Trading less is what reduces this, and the reward-to-risk floor is the setting that does it: demand more from a setup and fewer qualify.",
                    evidence: ["\(money(scorecard.totalSlippage)) crossing the spread", "\(money(scorecard.totalCommission)) commission", "\(money(scorecard.totalTax)) tax"],
                    sample: scorecard.closedTrades, minSample: 8,
                    adjustment: Adjustment(knob: .minRewardToRisk, from: current.minRewardToRiskDelta, to: current.minRewardToRiskDelta + 0.3)
                ))
            }
        }

        /* --- is the method paying at all? ------------------------------------ */

        if let expectancy = scorecard.expectancyR, scorecard.closedTrades >= 10, expectancy < -0.15 {
            out.append(lesson(
                kind: "behaviour-negative-expectancy",
                title: "Expectancy is negative, so size should come down",
                finding: "Expectancy is \(f(expectancy, 2))R over \(scorecard.closedTrades) closed trades.",
                reasoning: "Reducing risk per trade does not fix the edge, but it extends the number of trades available to diagnose it. Roll this one back deliberately once expectancy turns positive.",
                evidence: ["\(scorecard.wins) up, \(scorecard.losses) down", "expectancy \(f(expectancy, 2))R per trade"],
                sample: scorecard.closedTrades, minSample: 10,
                adjustment: Adjustment(knob: .riskScale, from: current.riskScale, to: current.riskScale * 0.75)
            ))
        }

        /* --- does the trading match the profile? ------------------------------ */

        if profile.horizon != .intraday, behaviour.dayTrades > 0, pct(behaviour.dayTrades, n) >= 25 {
            out.append(lesson(
                kind: "behaviour-horizon-mismatch",
                title: "The trading is far faster than the profile it runs under",
                finding: "\(behaviour.dayTrades) of \(n) closed trades opened and shut inside one session, on a \(profile.horizon.label.components(separatedBy: " —").first ?? profile.horizon.rawValue.lowercased()) profile.",
                reasoning: "Stop width, target distance and how long a plan may take are all derived from the horizon on the profile. Trading a different one means the plans are built for a trade you are not taking, and the short-term tax rate applies throughout. Either the profile or the trading needs to change.",
                evidence: ["\(f(pct(behaviour.dayTrades, n), 0))% of closed trades were same-session round trips"],
                sample: n, minSample: 4, adjustment: nil
            ))
        }

        /* --- against simply owning the index ---------------------------------- */

        if let account = behaviour.accountReturnPct, let bench = behaviour.benchmarkReturnPct,
           scorecard.closedTrades >= 10, account < bench - 4 {
            out.append(lesson(
                kind: "behaviour-benchmark-lag",
                title: "The trading is behind the index",
                finding: "The account is \(f(account, 1))% over this window against \(f(bench, 1))% for the S&P 500 — \(f(bench - account, 1)) points behind.",
                reasoning: "This is the figure the activity is measured against: the return available from holding the index and doing nothing. A trade log does not show it.",
                evidence: ["account \(f(account, 1))%, benchmark \(f(bench, 1))%, over \(scorecard.closedTrades) closed trades"],
                sample: scorecard.closedTrades, minSample: 10, adjustment: nil
            ))
        }

        return out
    }

    /* --------------------------------------------------------- merging */

    /**
     * Fold freshly derived findings into the memory.
     *
     * The rules are deliberately conservative about disturbing what the user has
     * already decided:
     *
     *   - A finding whose kind is already *applied* refreshes its evidence and its
     *     outcome note, and does not re-propose itself.
     *   - A finding the user *dismissed* stays dismissed. It updates its evidence so
     *     the Learning tab can show it strengthening, but it never jumps back into
     *     the queue on its own.
     *   - An applied lesson whose evidence has stopped appearing retires, and the
     *     calibration is recomposed without it. That is what stops the engine from
     *     accumulating a permanent tilt from a phase of the market that has ended.
     */
    static func merge(_ fresh: [Lesson], into memory: inout Memory) {
        let freshKinds = Set(fresh.map(\.kind))
        let now = nowMs()

        for finding in fresh {
            guard let idx = memory.lessons.firstIndex(where: { $0.kind == finding.kind }) else {
                memory.lessons.append(finding)
                continue
            }
            var existing = memory.lessons[idx]
            existing.finding = finding.finding
            existing.evidence = finding.evidence
            existing.sampleSize = finding.sampleSize
            existing.confidence = finding.confidence
            existing.updatedAt = now

            switch existing.status {
            case .watching:
                // It has crossed its own threshold; offer it.
                if finding.adjustment != nil || finding.status == .proposed {
                    existing.adjustment = finding.adjustment
                    existing.status = .proposed
                }
            case .proposed:
                existing.adjustment = finding.adjustment
            case .applied:
                existing.outcomeNote = "Still supported by the record: \(finding.finding)"
            case .dismissed, .retired:
                break
            }
            memory.lessons[idx] = existing
        }

        // Applied lessons whose evidence has gone quiet.
        for i in memory.lessons.indices where memory.lessons[i].status == .applied {
            guard !freshKinds.contains(memory.lessons[i].kind) else { continue }
            guard memory.lessons[i].runsSinceApplied >= 2 else { continue }
            memory.lessons[i].status = .retired
            memory.lessons[i].updatedAt = now
            memory.lessons[i].outcomeNote = "Retired: the record stopped supporting this after \(memory.lessons[i].runsSinceApplied) analyses, and its adjustment has been rolled back."
        }

        memory.recompose()
    }
}
