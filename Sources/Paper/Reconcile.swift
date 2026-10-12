/**
 * Reconcile.swift — holding the ledger to account for the market it did not watch.
 *
 * Paper is a Mac app, not a server. It is shut most of the time, and the live
 * bracket sweep only ever sees the session in front of it: `dayHigh` and `dayLow`
 * off a one-day quote. So a position whose stop was taken out on Monday, in a
 * week the app never opened, was still sitting there open and green on Friday —
 * and the loss simply never entered the record.
 *
 * That is not a rounding error, it is a bias, and it runs in exactly one
 * direction. The only losers that ever got written down were the ones unlucky
 * enough to resolve while somebody was looking. Every dip that reversed over a
 * closed weekend was quietly promoted to a winner. An app whose entire argument
 * is that costs and gaps and stops are real cannot also be the thing that hides
 * the worst of them behind its own launch schedule.
 *
 * The fix is not to keep the app running. A resting stop at a real broker sits
 * with the exchange and fires whether or not you are logged in, whether or not
 * your laptop is shut. Reconstructing those fills afterwards is the *more*
 * faithful model, not a concession — the live-only sweep was the artifact.
 *
 * What this cannot do is pretend to precision it does not have. A daily bar
 * proves a level was touched; it does not say when in the session, or which leg
 * went first when both sat inside the same bar. Where it matters and the data
 * exists, five-minute bars settle the order. Where they do not, the stop is
 * assumed first — and the trade is marked as reconstructed either way, so the
 * record never presents a reasoned guess as an observation.
 */

import Foundation

/// One exit the desk missed, as rebuilt from bars.
struct ReconciledExit: Codable {
    let symbol: String
    let trigger: String      // "stop" | "target"
    let at: Double
    let level: Double
    let fill: Double
    let shares: Double
    let pnl: Double
    let rMultiple: Double?
    let gapped: Bool
    /// "daily" when a daily bar decided it, "intraday" when five-minute bars did.
    let resolution: String
    /// True when both legs sat inside one bar and nothing finer was available to
    /// order them, so the stop was assumed to have gone first.
    let assumedStopFirst: Bool
}

/// A position the pass refused to touch, and why.
struct ReconcileFlag: Codable {
    let symbol: String
    let reason: String
}

struct ReconcileReport: Codable {
    let profileId: String
    let profileName: String
    let from: Double
    let to: Double
    let sessionsReplayed: Int
    let exits: [ReconciledExit]
    let splitsApplied: [String]
    let contributionsPaid: Int
    let flagged: [ReconcileFlag]
    let netPnl: Double

    var isEmpty: Bool {
        exits.isEmpty && splitsApplied.isEmpty && flagged.isEmpty && contributionsPaid == 0
    }
}

enum Reconcile {

    /// Below this, the gap is the app being restarted rather than the app being
    /// shut for a stretch of market, and there is nothing to replay.
    static let minimumGapMs: Double = 6 * 60 * 60 * 1000

    /**
     * An overnight move this large is a corporate action the feed did not tell us
     * about, not a price. Firing a bracket on it would close a position at a level
     * that never existed, so the position is flagged for a human instead.
     *
     * Deliberately far outside anything the instruments here actually do
     * overnight — the worst real overnight gaps in this universe are a fraction of
     * it — so a genuine crash still fires its stop, which is the whole point of
     * having one.
     */
    static let implausibleDownGap = 0.40   // open below 40% of the prior close
    static let implausibleUpGap   = 2.50   // or above 250% of it

    /**
     * Replay every session between where the sweep last got to and now.
     *
     * `intraday` is asked for five-minute bars only when a daily bar is genuinely
     * ambiguous — both legs inside it — so the common case costs no extra requests.
     */
    /**
     * `fx` prices foreign holdings during the replay.
     *
     * Stated rather than buried: these are *current* rates applied to past sessions,
     * because Paper does not keep a rate history and inventing one would be worse
     * than a known approximation. The consequence is bounded and worth knowing — a
     * replayed exit's proceeds and a backfilled equity point convert a kronor figure
     * at today's rate rather than that day's, so the shape of a replayed week
     * reflects what the stock did and not what the currency did. The levels
     * themselves are untouched: a stop is compared against the bar in the currency
     * both are quoted in, so *whether* it fired is exactly as certain as before.
     */
    static func run(ledger: Portfolio,
                    profileName: String,
                    fx: FXRates = .unavailable,
                    bars: [String: [Bar]],
                    splits: [String: [Split]],
                    now: Double = nowMs(),
                    intraday: (String) async -> [Bar]?) async -> ReconcileReport? {

        let from = startPoint(ledger: ledger, now: now)
        guard let from else {
            ledger.markSwept(now)
            return nil
        }

        // Today belongs to the live sweep, which has the real-time session range and
        // does not need a bar that is still being written. Replay stops at yesterday.
        // Each instrument answers to its own exchange calendar, so "today" is asked
        // per symbol rather than once in New York.
        func sessionKey(_ ms: Double, _ symbol: String) -> String {
            MarketCalendar.sessionKey(Date(timeIntervalSince1970: ms / 1000), for: symbol)
        }
        func rate(_ symbol: String) -> Double { fx.rate(Universe.currency(of: symbol)) }

        var exits: [ReconciledExit] = []
        var splitsApplied: [String] = []
        var flagged: [ReconcileFlag] = []
        var refused: Set<String> = []

        // Contributions first: the cash was there for the sessions being replayed.
        let paid = ledger.applyContribution(now: Date(timeIntervalSince1970: now / 1000))

        // Every session any held symbol printed in the window, oldest first. Walking
        // by date rather than by position keeps the cash flows and the equity curve
        // in the order they actually happened.
        let held = Set(ledger.state.positions.map(\.symbol))
        guard !held.isEmpty || !paid.isEmpty else {
            ledger.markSwept(now)
            return nil
        }

        var sessions: Set<Double> = []
        for symbol in held {
            // Today belongs to the live sweep, which has the real-time session range
            // and does not need a bar that is still being written.
            let todayKey = sessionKey(now, symbol)
            for bar in bars[symbol] ?? [] where bar.t > from {
                guard sessionKey(bar.t, symbol) != todayKey else { continue }
                sessions.insert(bar.t)
            }
        }
        let ordered = sessions.sorted()

        for stamp in ordered {
            // Restate for any split effective on or before this session before a single
            // level is compared, because the bars from here on are already restated.
            for symbol in ledger.state.positions.map(\.symbol) {
                for split in splits[symbol] ?? [] where split.at <= stamp {
                    if ledger.applySplit(symbol: symbol, ratio: split.ratio, at: split.at, label: split.label) {
                        splitsApplied.append("\(symbol) \(split.label)")
                    }
                }
            }

            for pos in ledger.state.positions {
                guard !refused.contains(pos.symbol) else { continue }
                let key = sessionKey(stamp, pos.symbol)
                guard let series = bars[pos.symbol],
                      let i = series.firstIndex(where: { sessionKey($0.t, pos.symbol) == key })
                else { continue }
                let bar = series[i]

                // An unexplained overnight discontinuity is a corporate action, not a move.
                if i > 0 {
                    let prior = series[i - 1].c
                    if prior > 0, bar.o < prior * implausibleDownGap || bar.o > prior * implausibleUpGap {
                        refused.insert(pos.symbol)
                        flagged.append(ReconcileFlag(
                            symbol: pos.symbol,
                            reason: "\(pos.symbol) opened at \(priceText(bar.o)) against a prior close of \(priceText(prior)) \(Universe.currency(of: pos.symbol).code) on \(key). That is a corporate action the feed did not report, not a price move, so the bracket was left alone rather than closed at a level that never traded. Check the position and its stop by hand."
                        ))
                        continue
                    }
                }

                ledger.recordWater(symbol: pos.symbol, high: bar.h, low: bar.l)

                guard var decision = Portfolio.decideBracket(
                    stop: pos.stop, target: pos.target,
                    high: bar.h, low: bar.l, open: bar.o
                ) else { continue }

                // Both legs inside one bar: the daily series cannot order them. Ask for
                // five-minute bars before falling back to assuming the worse one.
                var resolution = "daily"
                var assumed = false
                // The daily bar's own stamp, unless five-minute bars can say better.
                var stampedAt = stamp
                let bothInside = pos.stop != nil && pos.target != nil
                    && bar.l <= pos.stop! && bar.h >= pos.target!
                if bothInside {
                    if let fine = await intraday(pos.symbol),
                       let first = firstTouch(bars: fine, session: key, symbol: pos.symbol,
                                              stop: pos.stop!, target: pos.target!) {
                        resolution = "intraday"
                        stampedAt = first.at
                        if !first.stopFirst, let target = pos.target {
                            // The target genuinely went first. Rebuild the decision around it.
                            decision = Portfolio.BracketDecision(
                                useStop: false, level: target,
                                fill: bar.o > target ? bar.o : target,
                                gapped: bar.o > target
                            )
                        }
                    } else {
                        assumed = true
                    }
                }

                let mark = MarkPrice(price: bar.c, prevClose: i > 0 ? series[i - 1].c : nil,
                                     dayHigh: bar.h, dayLow: bar.l, dayOpen: bar.o,
                                     fxPerUSD: rate(pos.symbol))
                let result = ledger.sell(
                    symbol: pos.symbol, mark: mark,
                    reason: ledger.bracketReason(decision, position: pos, backfilled: true),
                    trigger: decision.useStop ? "stop" : "target",
                    fillOverride: decision.fill, gapped: decision.gapped,
                    skipGate: true, asOf: stampedAt, backfilled: true
                )
                if case .ok(let trade) = result {
                    exits.append(ReconciledExit(
                        symbol: trade.symbol, trigger: trade.trigger ?? "stop", at: stampedAt,
                        level: decision.level, fill: decision.fill, shares: trade.shares,
                        pnl: trade.pnl ?? 0, rMultiple: trade.rMultiple, gapped: decision.gapped,
                        resolution: resolution, assumedStopFirst: assumed && decision.useStop
                    ))
                }
            }

            // One equity point per replayed session, so a week the desk was shut draws
            // the shape it actually had rather than a straight line across it.
            var closes: [String: MarkPrice] = [:]
            for pos in ledger.state.positions {
                let key = sessionKey(stamp, pos.symbol)
                guard let series = bars[pos.symbol],
                      let bar = series.first(where: { sessionKey($0.t, pos.symbol) == key })
                else { continue }
                closes[pos.symbol] = MarkPrice(price: bar.c, dayHigh: bar.h, dayLow: bar.l,
                                               dayOpen: bar.o, fxPerUSD: rate(pos.symbol))
            }
            let valued = ledger.value(closes)
            ledger.backfillEquityPoint(at: stamp, equity: valued.equity,
                                       cash: valued.cash, invested: valued.invested)
        }

        ledger.markSwept(now)

        let report = ReconcileReport(
            profileId: ledger.state.profileId,
            profileName: profileName,
            from: from, to: now,
            sessionsReplayed: ordered.count,
            exits: exits,
            splitsApplied: splitsApplied,
            contributionsPaid: paid.count,
            flagged: flagged,
            netPnl: exits.reduce(0) { $0 + $1.pnl }
        )
        return report.isEmpty ? nil : report
    }

    /* ------------------------------------------------------------- internals */

    /**
     * Where the replay starts.
     *
     * Nil means there is nothing to do. A ledger written before this existed has no
     * `lastSweptAt`, so it falls back to the oldest open position — which is the
     * furthest back a bracket could possibly have fired — rather than silently
     * skipping every exit the app has ever missed.
     */
    static func startPoint(ledger: Portfolio, now: Double) -> Double? {
        let recorded = ledger.state.lastSweptAt
        let candidate: Double
        if recorded > 0 {
            candidate = recorded
        } else if let oldest = ledger.state.positions.map(\.openedAt).min() {
            candidate = oldest
        } else {
            return nil
        }
        guard now - candidate >= minimumGapMs else { return nil }
        return candidate
    }

    /// Which level a session reached first, from five-minute bars.
    /// Nil when the series does not cover that session at all.
    static func firstTouch(bars: [Bar], session: String, symbol: String = "",
                           stop: Double, target: Double) -> (stopFirst: Bool, at: Double)? {
        // The session string was produced in the instrument's own venue, so the bars
        // have to be keyed the same way or nothing matches and the pessimistic
        // fallback fires on every ambiguous bar.
        let venue = symbol.isEmpty ? Venue.us : Universe.venue(of: symbol)
        let inSession = bars.filter {
            MarketCalendar.sessionKey(Date(timeIntervalSince1970: $0.t / 1000), venue: venue) == session
        }
        guard !inSession.isEmpty else { return nil }
        for bar in inSession.sorted(by: { $0.t < $1.t }) {
            let hitStop = bar.l <= stop
            let hitTarget = bar.h >= target
            // Inside a single five-minute bar the order is unknowable again, so the
            // pessimistic rule applies one level down rather than being abandoned.
            if hitStop { return (true, bar.t) }
            if hitTarget { return (false, bar.t) }
        }
        return nil
    }
}
