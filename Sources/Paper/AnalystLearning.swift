/**
 * AnalystLearning.swift — the sixth pass: what to change about the engine itself.
 *
 * The five passes in Analyst.swift analyse a market and a record. This one
 * analyses the *analysis*: given what the desk recommended, what the user did with
 * it and what price then did to both, what should the engine do differently next
 * time?
 *
 * The model is given a deliberately narrow vocabulary. It cannot write a number
 * into the risk engine — it picks a dial from a fixed list, a direction, and one of
 * three step sizes, and the engine turns that into a delta and clamps it exactly as
 * it clamps its own arithmetic proposals. That constraint is the whole design:
 *
 *   - A language model reasoning about which dial and which direction is doing
 *     something it is genuinely good at, and something the arithmetic rules cannot
 *     do, because it can see a reason the numbers cannot ("every loss was in the
 *     same week, and that week had a Fed meeting in it").
 *   - A language model choosing "stop width 2.4×" is inventing a risk parameter,
 *     which is the exact failure this whole app exists to teach people to distrust.
 *
 * Every proposal it makes lands in the same queue as every other, marked as coming
 * from the analyst, needing the same approval and carrying the same evidence
 * requirement. Nothing here changes anything on its own.
 */

import Foundation

/// One proposal, in the vocabulary the model is allowed to use.
struct LessonProposal: Codable {
    /// Must match a `Knob` raw value, or "rule" for a behavioural finding with no dial.
    let knob: String
    /// Sector, regime or instrument, for the keyed dials. Empty otherwise.
    let key: String
    /// "increase" | "decrease"
    let direction: String
    /// "small" | "medium"
    let size: String
    let title: String
    let finding: String
    let reasoning: String
    let evidence: [String]
    /// How many closed trades or graded recommendations this rests on.
    let sampleSize: Double
}

struct LessonProposals: Codable {
    let proposals: [LessonProposal]
    /// What the record does *not* support saying yet. Stated explicitly, because a
    /// pass that always finds something to change is a pass that is inventing.
    let notYetSupported: String
}

extension Analyst {

    private enum LearnSchema {
        static let str: [String: Any] = ["type": "string"]
        static let proposal: [String: Any] = [
            "type": "object",
            "properties": [
                "knob": ["type": "string", "enum": Knob.allCases.map(\.rawValue) + ["rule"]],
                "key": str,
                "direction": ["type": "string", "enum": ["increase", "decrease"]],
                "size": ["type": "string", "enum": ["small", "medium"]],
                "title": str, "finding": str, "reasoning": str,
                "evidence": ["type": "array", "items": str],
                "sampleSize": ["type": "number"],
            ],
            "required": ["knob", "key", "direction", "size", "title", "finding", "reasoning", "evidence", "sampleSize"],
            "additionalProperties": false,
        ]
        static let batch: [String: Any] = [
            "type": "object",
            "properties": [
                "proposals": ["type": "array", "items": proposal],
                "notYetSupported": str,
            ],
            "required": ["proposals", "notYetSupported"],
            "additionalProperties": false,
        ]
    }

    /// How far each step size moves a dial. Small enough that two runs of agreeing
    /// evidence move it meaningfully and one run cannot move it far.
    private static func step(_ knob: Knob, size: String, up: Bool) -> Double {
        let magnitude: Double = size == "medium" ? 2 : 1
        let unit: Double
        switch knob {
        case .stopScale, .targetScale, .holdScale, .rangeCeiling, .riskScale: unit = 0.07
        case .minRewardToRisk: unit = 0.15
        case .convictionFloor: unit = 8
        case .sectorBias, .regimeBias, .symbolBias: unit = 5
        }
        return (up ? 1 : -1) * unit * magnitude
    }

    /// Turns a proposal into a clamped `Lesson`, or rejects it. Everything the model
    /// could get wrong is caught here rather than downstream.
    static func adopt(_ p: LessonProposal, current: Calibration) -> Lesson? {
        let sample = Int(p.sampleSize.rounded())
        // A proposal resting on fewer than four observations is an anecdote whoever
        // wrote it. The arithmetic rules hold themselves to the same floor.
        guard sample >= 4, !p.title.isEmpty, !p.finding.isEmpty else { return nil }

        var adjustment: Adjustment?
        if p.knob != "rule" {
            guard let knob = Knob(rawValue: p.knob) else { return nil }
            if knob.isKeyed && p.key.trimmingCharacters(in: .whitespaces).isEmpty { return nil }

            let up = p.direction == "increase"
            // Experience is allowed to make this account more careful on its own
            // recognisance. Making it bolder is a decision for a person.
            if knob == .riskScale && up { return nil }

            let from: Double
            switch knob {
            case .stopScale: from = current.stopScale
            case .targetScale: from = current.targetScale
            case .minRewardToRisk: from = current.minRewardToRiskDelta
            case .riskScale: from = current.riskScale
            case .holdScale: from = current.holdScale
            case .convictionFloor: from = current.convictionFloor
            case .rangeCeiling: from = current.rangeCeilingScale
            case .sectorBias: from = current.sectorBias[p.key] ?? 0
            case .regimeBias: from = current.regimeBias[p.key] ?? 0
            case .symbolBias: from = current.symbolBias[p.key] ?? 0
            }

            let delta = step(knob, size: p.size, up: up)
            // The multiplicative dials scale; the additive ones add.
            let to: Double
            switch knob {
            case .minRewardToRisk, .convictionFloor, .sectorBias, .regimeBias, .symbolBias:
                to = from + delta
            default:
                to = from * (1 + delta)
            }
            let built = Adjustment(knob: knob, key: p.key, from: from, to: to)
            guard abs(built.delta) > 1e-9 else { return nil }   // already at the clamp
            adjustment = built
        }

        let id = "analyst-\(p.knob)-\(p.key.isEmpty ? "all" : p.key)".lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return Lesson(
            id: id, kind: id, title: p.title, finding: p.finding, reasoning: p.reasoning,
            evidence: p.evidence, sampleSize: sample,
            confidence: Analysis.clamp(0.3 + Double(min(sample, 20)) / 40, 0, 0.9),
            adjustment: adjustment, status: .proposed, source: "analyst",
            createdAt: nowMs(), updatedAt: nowMs(), appliedAt: nil,
            runsSinceApplied: 0, outcomeNote: nil
        )
    }

    /**
     * Pass 6 — read the desk's own track record and say what to change about it.
     *
     * The evidence handed over is the grading of recommendations the app made,
     * including the ones that were never traded. That is the half the model cannot
     * reconstruct and the half that actually distinguishes a bad engine from a badly
     * traded one.
     */
    static func proposeLessons(
        runs: [RunRecord], behaviour: BehaviourReport, scorecard: Scorecard,
        memory: Memory, profile: Profile,
        alreadyFound: [Lesson], governor: Governor? = nil
    ) async -> (lessons: [Lesson], note: String?) {
        guard available() else { return ([], nil) }

        let graded = runs.filter { !$0.outcomes.isEmpty }
        guard !graded.isEmpty || scorecard.closedTrades >= 4 else { return ([], nil) }

        let picksByKey = Dictionary(
            graded.flatMap { run in run.picks.map { ("\(Int(run.at))|\($0.symbol)", $0) } },
            uniquingKeysWith: { a, _ in a }
        )

        let rows = graded.flatMap { run -> [String] in
            run.outcomes.map { o in
                let p = picksByKey["\(Int(run.at))|\(o.symbol)"]
                let plan = p.map { "entry \(fmt($0.entry)), target \(fmt($0.target)), stop \(fmt($0.stop)), \(fmt($0.rr)):1, projected \(fmt($0.horizonDays, 0)) sessions, quant \(fmt($0.conviction, 0))/100, \($0.sector), \($0.regime), daily range \(fmt($0.atrPct, 1))%" } ?? "plan unavailable"
                let result = o.hitTarget ? "reached its target in \(o.sessionsToResolve.map(String.init) ?? "?") sessions"
                    : o.hitStop ? "hit its stop in \(o.sessionsToResolve.map(String.init) ?? "?") sessions\(o.recoveredAfterStop ? ", then traded back above the entry" : ", and kept going")"
                    : "unresolved after \(o.sessionsObserved) sessions"
                return "  - \(o.symbol): \(plan). Outcome: \(result). Best \(fmt(o.mfeR))R, worst \(fmt(o.maeR))R, currently \(fmt(o.rMultiple))R.\(o.ranOnAfterTarget ? " Ran on at least another 1R past the target." : "")"
            }
        }

        let alreadyText = alreadyFound.isEmpty ? "  (none)"
            : alreadyFound.map { "  - \($0.kind): \($0.title) [\($0.status.rawValue)]" }.joined(separator: "\n")

        let user = """
        You are reviewing this desk's own track record as an engine, not the market.

        The account:
        \(profile.brief)

        \(memory.brief)

        Recommendations this desk has made, and what price then did to each — including the ones that were never traded, which is the point of showing them to you:
        \(rows.isEmpty ? "  (no graded recommendations yet)" : rows.joined(separator: "\n"))

        How the account has actually been traded:
          Closed trades \(scorecard.closedTrades) (\(scorecard.wins) up, \(scorecard.losses) down). Expectancy \(scorecard.expectancyR.map { fmt($0) + "R" } ?? "n/a").
          Stopped out \(scorecard.stoppedOut), targets hit \(scorecard.targetsHit), closed by hand \(scorecard.manualExits).
          Sold too early \(behaviour.soldTooEarlyCount), whipsawed \(behaviour.whipsawCount), gave it back \(behaviour.gaveItBackCount).
          Capture rate \(behaviour.captureRatePct.map { fmt($0, 0) + "%" } ?? "n/a"). Average heat \(behaviour.avgMaeR.map { fmt($0) + "R" } ?? "n/a"), average best available \(behaviour.avgMfeR.map { fmt($0) + "R" } ?? "n/a").
          Held: winners \(behaviour.avgHoldWinnersDays.map { fmt($0, 1) } ?? "n/a") days, losers \(behaviour.avgHoldLosersDays.map { fmt($0, 1) } ?? "n/a") days.
          Patterns already flagged by the arithmetic: \(behaviour.patterns.isEmpty ? "none" : behaviour.patterns.joined(separator: " | "))

        Findings the arithmetic rules have already produced, which you do not need to repeat:
        \(alreadyText)

        Propose at most three changes the arithmetic has not already found. For each, pick one dial:

          stopScale        — how wide stops sit, in multiples of the instrument's own daily range
          targetScale      — how far targets sit
          minRewardToRisk  — the reward-to-risk a setup must offer to be funded at all
          riskScale        — how much is risked per trade (decrease only; you may not raise it)
          holdScale        — how long a plan is allowed to take
          convictionFloor  — the quantitative score below which nothing is funded
          rangeCeiling     — the ceiling on how much an instrument may move on an average day
          sectorBias       — conviction points for one sector (put the sector in "key")
          regimeBias       — conviction points for one market regime (regime name in "key")
          symbolBias       — conviction points for one instrument (ticker in "key")
          rule             — a finding about how the account is being traded, with no dial to turn

        Then a direction and a step size, "small" or "medium". You do not set the number; the engine computes and clamps the step. Do not ask for a specific value and do not describe one in the reasoning.

        Rules for this pass:
        - Ground every proposal in the rows above. Name the instruments. "Stops seem tight" is worthless; "four of the six stop-outs traded back above their entry within three sessions, and all four were in names moving over 4% a day" is a finding.
        - A proposal resting on fewer than four observations will be discarded, so do not make one. Put the honest count in sampleSize.
        - Separate the engine from the trader. A stop that was hit and then recovered is the engine's problem. A winner closed by hand after two days is not, and belongs under "rule".
        - Say what the record does not yet support in notYetSupported. Returning an empty proposal list with a clear statement of what is still too thin to call is a correct and valuable answer, and a better one than three weak proposals.
        - You are writing for someone who will read this and decide whether to apply it. The reasoning has to be worth reading on its own terms, and has to include what the change would cost if the finding turns out to be noise.
        """

        switch await run(LessonProposals.self, schema: LearnSchema.batch,
                         user: user, pass: "learn", governor: governor) {
        case .ok(let out):
            let lessons = out.proposals.compactMap { adopt($0, current: memory.calibration) }
            log("[analyst] learn pass: \(out.proposals.count) proposed, \(lessons.count) survived clamping")
            return (lessons, out.notYetSupported.isEmpty ? nil : out.notYetSupported)
        case .empty(let why), .failed(let why):
            log("[analyst] learn pass: \(why)")
            return ([], nil)
        case .stopped:
            return ([], nil)
        }
    }
}
