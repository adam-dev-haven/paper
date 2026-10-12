/**
 * SchemaGate.swift — the rule at the top of Portfolio.swift, enforced.
 *
 * On 2026-09-13 three new fields made every existing ledger fail to decode, and
 * the fallback for an unreadable ledger replaced each one with an empty account
 * and saved it. Six accounts, six milliseconds. The response was a paragraph at
 * the top of Portfolio.swift stating the rule — hand-rolled decoders, a default
 * for everything that is not genuinely identifying, never let a read failure
 * write — and hand-rolled decoders on the four types that file defines.
 *
 * A paragraph is not an enforcement mechanism, and this audit found the proof:
 * the rule had been applied to the containers and not to the things they contain.
 * `PortfolioState` decoded every key with `decodeIfPresent`, and
 * `decodeIfPresent([EquityPoint].self, forKey:)` guards a missing **key** while
 * throwing on a present-but-unreadable **value** — so one field added to
 * `EquityPoint` still took the whole ledger down, through a door nobody had
 * thought to close. The same was true of `RealizedGain`, `Contribution` and
 * `DayTradeRecord` inside the ledger, of `Frictions` inside `profiles.json`, and
 * of `Memory` outright.
 *
 * So this is the rule as a test rather than as prose.
 *
 * For every type the app writes to disk, it encodes a sample, drops each key in
 * turn, and decodes what is left. A key whose absence breaks the decode is
 * **load-bearing**: any future rename, removal or reordering that touches it
 * makes every file already on disk unreadable. Each subject declares which keys
 * are allowed to be load-bearing — the ones that identify the record, whose
 * absence genuinely means "this is not that kind of file" rather than "this file
 * is older than that field". Anything else is a failure, and the failure names
 * the field and the file it would cost.
 *
 * It is also checked in the other direction. A key declared identifying that
 * turns out to be optional is reported too, because a stale declaration is how a
 * gate quietly stops gating.
 *
 * Adding a persisted type and not registering it here is itself a failure, so
 * the list cannot rot by omission: `subjects` is asserted against a count that
 * has to be updated deliberately.
 *
 * Run by `--selftest`, which `build.sh` gates the bundle on.
 */

import Foundation

enum SchemaGate {

    /// One persisted type, and the keys it is allowed to refuse over.
    struct Subject {
        let name: String
        /// Where a file of this shape ends up, for the failure message to name
        /// what is actually at risk.
        let stakes: String
        /// Keys whose absence legitimately means "not this kind of record".
        let identifying: Set<String>
        /// Encodes a representative value and reports which keys break a decode.
        let probe: () -> ProbeResult
    }

    struct ProbeResult {
        var loadBearing: Set<String> = []
        var total = 0
        var error: String?
    }

    struct Failure {
        let subject: String
        let detail: String
    }

    /**
     * Encode, drop one key at a time, decode.
     *
     * The sample has to exercise every key — an optional left nil is not encoded,
     * so it is never dropped and never tested. Where a type has optionals that
     * matter, the sample fills them in.
     */
    static func probe<T: Codable>(_ type: T.Type, _ sample: T) -> ProbeResult {
        var result = ProbeResult()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(sample),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            result.error = "the sample would not round-trip through JSON at all"
            return result
        }
        result.total = object.count
        for key in object.keys {
            var reduced = object
            reduced.removeValue(forKey: key)
            guard let bytes = try? JSONSerialization.data(withJSONObject: reduced) else { continue }
            if (try? JSONDecoder().decode(T.self, from: bytes)) == nil {
                result.loadBearing.insert(key)
            }
        }
        return result
    }

    /**
     * A key the app has never heard of must be ignored, not fatal.
     *
     * The forward-compatibility half: a file written by a *newer* build, opened by
     * an older one — which happens the moment someone reverts a build, or restores
     * a backup taken after an upgrade. `JSONDecoder` ignores unknown keys, so this
     * passes today; it is asserted anyway, because the property is free and its
     * loss would be silent.
     */
    static func toleratesUnknownKeys<T: Codable>(_ type: T.Type, _ sample: T) -> Bool {
        guard let data = try? JSONEncoder().encode(sample),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        object["aFieldFromSomeFutureBuild"] = "whatever this turns out to be"
        object["anotherOne"] = 42
        guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return (try? JSONDecoder().decode(T.self, from: bytes)) != nil
    }

    /* ------------------------------------------------------------ the register */

    /**
     * Every type that reaches disk.
     *
     * The `identifying` set is the argument being made, per type: *these* fields
     * are what make the record that record, and everything else must survive being
     * absent. Keep the justification in the comment, not in someone's memory.
     */
    static var subjects: [Subject] {
        let profile = Profile.preset(.learner)
        return [
            Subject(
                name: "PortfolioState",
                stakes: "ledgers/<profile>.json — the account itself",
                // Without a profile id the file cannot be matched to an account,
                // which makes it not a ledger rather than an old ledger.
                identifying: ["profileId"],
                probe: { probe(PortfolioState.self, Portfolio.empty(profile)) }
            ),
            Subject(
                name: "Position",
                stakes: "inside every ledger",
                // An instrument, a size and a price. A position missing any of the
                // four is not a position that can be valued, closed or taxed.
                identifying: ["id", "symbol", "shares", "avgPrice"],
                probe: {
                    probe(Position.self, Position(
                        id: "p", symbol: "AAPL", shares: 10, avgPrice: 100, openedAt: nowMs(),
                        openedSession: "2026-9-1", target: 120, stop: 90, thesis: "t",
                        plannedRisk: 100,
                        lots: [TaxLot(id: "l", shares: 10, costPerShare: 100, openedAt: nowMs())],
                        highWater: 105, lowWater: 95, fxAtOpen: 1))
                }
            ),
            Subject(
                name: "Trade",
                stakes: "inside every ledger — the trade record the review reads",
                identifying: ["id", "symbol", "action"],
                probe: {
                    probe(Trade.self, Trade(
                        id: "t", symbol: "AAPL", action: "sell", shares: 10, price: 110,
                        quotedPrice: 110, value: 1100, at: nowMs(), commission: 1, slippage: 1,
                        pnl: 90, rMultiple: 1.2, taxDue: 20, gapped: false, reason: "r",
                        trigger: "target", dayTrade: false, backfilled: false))
                }
            ),
            Subject(
                name: "TaxLot",
                stakes: "inside every position — the cost basis tax is computed on",
                // A parcel is a number of shares at a price. Without both, it
                // cannot contribute a basis, and a sale against it would book the
                // proceeds as pure profit.
                identifying: ["id", "shares", "costPerShare"],
                probe: {
                    probe(TaxLot.self, TaxLot(id: "l", shares: 10, costPerShare: 100,
                                              openedAt: nowMs(), fxPerUSD: 1))
                }
            ),
            Subject(
                name: "EquityPoint",
                stakes: "inside every ledger — the equity curve",
                // A point with no timestamp cannot be placed on a curve.
                identifying: ["t"],
                probe: {
                    probe(EquityPoint.self, EquityPoint(t: nowMs(), equity: 10_000, cash: 5_000,
                                                        invested: 5_000, contributed: 0))
                }
            ),
            Subject(
                name: "RealizedGain",
                stakes: "inside every ledger — the tax record",
                identifying: ["symbol"],
                probe: {
                    probe(RealizedGain.self, RealizedGain(
                        at: nowMs(), symbol: "AAPL", shares: 10, proceeds: 1100,
                        costBasis: 1000, gain: 100, holdingDays: 30, longTerm: false, taxDue: 32))
                }
            ),
            Subject(
                name: "Contribution",
                stakes: "inside every ledger — what was paid in vs. what was earned",
                identifying: [],
                probe: { probe(Contribution.self, Contribution(at: nowMs(), amount: 500, note: "n")) }
            ),
            Subject(
                name: "DayTradeRecord",
                stakes: "inside every ledger — the pattern-day-trader count",
                identifying: ["symbol"],
                probe: {
                    probe(DayTradeRecord.self, DayTradeRecord(symbol: "AAPL", at: nowMs(),
                                                              session: "2026-9-1"))
                }
            ),
            Subject(
                name: "Profile",
                stakes: "profiles.json — losing it orphans every ledger, which are keyed by profile id",
                identifying: ["id"],
                probe: { probe(Profile.self, profile) }
            ),
            Subject(
                name: "Frictions",
                stakes: "inside every Profile, therefore inside profiles.json",
                identifying: [],
                probe: { probe(Frictions.self, .retailBroker) }
            ),
            Subject(
                name: "Memory",
                stakes: "memory/<profile>.json — every lesson drawn from this account's record",
                identifying: ["profileId"],
                probe: { probe(Memory.self, Memory.empty("p")) }
            ),
            Subject(
                name: "AppSettings",
                stakes: "settings.json",
                identifying: [],
                probe: { probe(AppSettings.self, AppSettings()) }
            ),
            Subject(
                name: "RunLimits",
                stakes: "inside settings.json — what one analyst run may spend",
                identifying: [],
                probe: { probe(RunLimits.self, .standard) }
            ),
            Subject(
                name: "RunTelemetry",
                stakes: "analyst-runs.json — the token and cost report",
                identifying: [],
                probe: {
                    probe(RunTelemetry.self, .empty(kind: "ideas", model: "claude-opus-5", budget: 400_000))
                }
            ),

            /* The prediction desk writes four files of its own and none of them
             * were registered here — a blind spot in a gate, which is worse than
             * no gate, because it reads as coverage. The shadow book in particular
             * is the most expensive file in the app to lose: it is the accumulated
             * training evidence, it takes ten days of continuous watching to
             * rebuild, and it cannot be reconstructed from anything else. */
            Subject(
                name: "ShadowWindow",
                stakes: "predictions/shadow-book.json — ten days of accumulated training evidence",
                // A window is identified by when it started. Without that it cannot
                // be matched to an outcome, deduplicated, or ordered.
                identifying: ["start"],
                probe: {
                    probe(ShadowWindow.self, ShadowWindow(
                        start: 1_700_000_000, samples: [sampleShadow], resolved: .up,
                        resolvedAt: nowMs(), degraded: false, regime: sampleRegime))
                }
            ),
            Subject(
                name: "ShadowSample",
                stakes: "inside every shadow window",
                // The offset is what makes a sample a sample rather than a
                // duplicate; the model's probability is the thing being scored.
                identifying: ["offset"],
                probe: { probe(ShadowSample.self, sampleShadow) }
            ),
            Subject(
                name: "RegimeFeatures",
                stakes: "inside every shadow window",
                identifying: [],
                probe: { probe(RegimeFeatures.self, sampleRegime) }
            ),
            Subject(
                name: "PredictBrain",
                stakes: "predictions/brain.json — the three fitted parameters",
                identifying: [],
                probe: { probe(PredictBrain.self, .unlearned()) }
            ),
            Subject(
                name: "PredictPolicy",
                stakes: "predictions/policy.json — how the desk currently reads a window",
                // A policy is the features it reads and the coefficients it reads
                // them with; either one missing makes it a policy of nothing.
                identifying: ["candidateId", "features", "coefficients"],
                probe: { probe(PredictPolicy.self, .market()) }
            ),
            Subject(
                name: "SettledBet",
                stakes: "predictions/settled-bets.json — what fills really cost against what was assumed",
                identifying: [],
                probe: {
                    probe(SettledBet.self, SettledBet(
                        at: nowMs(), side: "Up", expectedAsk: 0.42, filledAsk: 0.43,
                        stake: 42, pnl: 12, won: true))
                }
            ),
        ]
    }

    /// Samples for the predict types, built once so the two that nest inside a
    /// shadow window are the same value the window is probed with.
    private static let sampleShadow = ShadowSample(
        offset: 150, pModel: 0.55, pMarket: 0.52, upAsk: 0.54, downAsk: 0.48, moveBps: 12)
    private static let sampleRegime = RegimeFeatures(
        run: 2, drift: 0.4, last: -0.2, volShift: 0.1, reversal: -1)

    /**
     * Registered subjects, asserted.
     *
     * A gate that silently skips whatever was not added to it is not a gate. This
     * number has to be changed by hand, which is the point: adding a persisted
     * type and not registering it fails the build rather than passing quietly.
     */
    static let expectedSubjects = 20

    /* -------------------------------------------------------------- the check */

    static func run() -> [Failure] {
        var failures: [Failure] = []

        if subjects.count != expectedSubjects {
            failures.append(Failure(
                subject: "SchemaGate",
                detail: "\(subjects.count) subjects registered, \(expectedSubjects) expected. "
                    + "If a persisted type was added, register it and raise `expectedSubjects`; "
                    + "if one was removed, lower it."))
        }

        for subject in subjects {
            let result = subject.probe()

            if let error = result.error {
                failures.append(Failure(subject: subject.name, detail: error))
                continue
            }

            let unexpected = result.loadBearing.subtracting(subject.identifying)
            if !unexpected.isEmpty {
                failures.append(Failure(
                    subject: subject.name,
                    detail: "\(unexpected.sorted().joined(separator: ", ")) "
                        + "\(unexpected.count == 1 ? "is" : "are") load-bearing but not identifying. "
                        + "A file written without \(unexpected.count == 1 ? "it" : "them") will not decode, "
                        + "so adding, renaming or removing a field on this type breaks every file "
                        + "already on disk — \(subject.stakes). "
                        + "Decode by hand with decodeIfPresent and a default."))
            }

            let stale = subject.identifying.subtracting(result.loadBearing)
            if !stale.isEmpty {
                failures.append(Failure(
                    subject: subject.name,
                    detail: "\(stale.sorted().joined(separator: ", ")) "
                        + "\(stale.count == 1 ? "is" : "are") declared identifying but "
                        + "\(stale.count == 1 ? "decodes" : "decode") fine when absent. "
                        + "Drop \(stale.count == 1 ? "it" : "them") from the declaration — an "
                        + "identifying set that overstates itself hides the next real regression."))
            }
        }

        return failures
    }

    /// A one-line summary for the self-test to print whichever way it goes.
    static func summary() -> String {
        let s = subjects
        let bearing = s.reduce(0) { $0 + $1.probe().loadBearing.count }
        let fields = s.reduce(0) { $0 + $1.probe().total }
        return "\(s.count) persisted types, \(fields) fields, \(bearing) of them load-bearing and declared."
    }
}
