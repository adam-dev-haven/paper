/**
 * Review.swift — what actually happened, measured before anyone interprets it.
 *
 * A trade journal that records only entry, exit and P/L answers the least useful
 * question. The ones that change behaviour are:
 *
 *   How much heat did the position take before it worked?  (MAE)
 *   How much was on the table before you gave it back?      (MFE)
 *   What did it do *after* you sold?
 *
 * That last one is the measurement almost nobody makes, and it is the one that
 * separates "I got stopped out" from "I got stopped out and it recovered two days
 * later, which means my stop was inside the noise". Maximum adverse and favourable
 * excursion are what real trade-review software is built around, and they are
 * computable from bars the app already fetches.
 *
 * Everything here is arithmetic on price history. The analyst reads these numbers
 * and writes the account of them; it is never asked to remember what a stock did,
 * because it cannot, and a plausible invented history is worse than none.
 */

import Foundation

/// What a closed trade turned out to be, once the market had its say.
enum TradeVerdict: String, Codable {
    /// Sold, then it ran on without you.
    case soldTooEarly = "sold-too-early"
    /// Sold, and it fell afterwards. The exit was the right call.
    case goodExit = "good-exit"
    /// Stopped out, then it recovered above the entry. The stop was inside the noise.
    case whipsawed
    /// Stopped out and it kept falling. The stop did its job.
    case stopSavedYou = "stop-saved-you"
    /// Was well ahead at some point and closed near flat or worse.
    case gaveItBack = "gave-it-back"
    /// Went deep against you first and still worked out.
    case survivedHeat = "survived-heat"
    /// Went to plan without drama.
    case clean
    /// Not enough history after the exit to say anything yet.
    case tooSoon = "too-soon"

    var label: String {
        switch self {
        case .soldTooEarly: return "Sold too early"
        case .goodExit: return "Good exit"
        case .whipsawed: return "Whipsawed out"
        case .stopSavedYou: return "The stop saved you"
        case .gaveItBack: return "Gave it back"
        case .survivedHeat: return "Survived the heat"
        case .clean: return "Went to plan"
        case .tooSoon: return "Too soon to judge"
        }
    }

    /// Whether this reads as a lesson, a warning, or neither.
    var tone: String {
        switch self {
        case .goodExit, .stopSavedYou, .clean: return "up"
        case .soldTooEarly, .whipsawed, .gaveItBack: return "warn"
        case .survivedHeat: return "accent"
        case .tooSoon: return "ghost"
        }
    }
}

struct TradeReview: Codable {
    let tradeId: String
    let symbol: String
    let name: String
    let openedAt: Double
    let closedAt: Double
    let holdingDays: Double
    let entry: Double
    let exit: Double
    let stop: Double?
    let target: Double?
    let shares: Double
    let pnl: Double
    let rMultiple: Double?
    let trigger: String?
    let gapped: Bool
    /// Rebuilt from bars after the fact, rather than seen happen.
    var backfilled: Bool = false
    let dayTrade: Bool
    let costs: Double
    let taxDue: Double?
    let thesis: String

    /// While the position was held, in R where a stop existed and in percent always.
    let maeR: Double?
    let mfeR: Double?
    let maePct: Double
    let mfePct: Double

    /// After the exit.
    let priceNow: Double?
    let sinceExitPct: Double?
    let postExitBestPct: Double?
    let postExitWorstPct: Double?
    let postExitBestR: Double?
    /// Dollars this position would have made or lost had it simply been left alone.
    let leftOnTable: Double?
    let sessionsSinceExit: Int

    let verdict: TradeVerdict
    /// The arithmetic account of what happened, before any interpretation.
    let evidence: String
}

/// What the whole record says about the person keeping it.
struct BehaviourReport: Codable {
    let trades: Int
    let avgHoldWinnersDays: Double?
    let avgHoldLosersDays: Double?
    /// Positive means winners are held longer than losers, which is the right way round.
    let holdAsymmetryDays: Double?
    let avgMaeR: Double?
    let avgMfeR: Double?
    /// How much of the best available move was actually captured, on average.
    let captureRatePct: Double?
    let soldTooEarlyCount: Int
    let whipsawCount: Int
    let gaveItBackCount: Int
    let totalLeftOnTable: Double
    let positionsWithoutStop: Int
    let gappedExits: Int
    /// Exits rebuilt from bars for sessions the desk was closed, kept apart from
    /// the ones it watched happen.
    var backfilledExits: Int = 0
    let dayTrades: Int
    let byRegime: [String: RegimeRecord]
    let byAssetClass: [String: RegimeRecord]
    /// Account return against simply holding the benchmark over the same window.
    let benchmarkReturnPct: Double?
    let accountReturnPct: Double?
    let patterns: [String]
}

struct RegimeRecord: Codable {
    let trades: Int
    let wins: Int
    let expectancyR: Double?
    let netPnl: Double
}

enum Review {

    /* ------------------------------------------------------------ one trade */

    /**
     * Reconstruct one closed trade from the bars around it.
     *
     * `bars` must cover the entry through to now. Everything is derived from the
     * session ranges, so the excursions are what the position actually saw rather
     * than what the closing prices happened to record.
     */
    static func build(sell: Trade, openedAt: Double, entry: Double, stop: Double?,
                      target: Double?, thesis: String, bars: [Bar]) -> TradeReview {
        let closedAt = sell.at
        let held = MarketCalendar.calendarDays(from: openedAt, to: closedAt)
        let during = bars.filter { $0.t >= openedAt - 86_400_000 && $0.t <= closedAt + 86_400_000 }
        let after = bars.filter { $0.t > closedAt }

        let riskPerShare = stop.map { entry - $0 }.flatMap { $0 > 0 ? $0 : nil }

        // While held.
        let lowest = during.map(\.l).min() ?? Swift.min(entry, sell.price)
        let highest = during.map(\.h).max() ?? Swift.max(entry, sell.price)
        let maePct = entry != 0 ? ((lowest - entry) / entry) * 100 : 0
        let mfePct = entry != 0 ? ((highest - entry) / entry) * 100 : 0
        let maeR = riskPerShare.map { (entry - lowest) / $0 }
        let mfeR = riskPerShare.map { (highest - entry) / $0 }

        // After the exit.
        let priceNow = after.last?.c
        let bestAfter = after.map(\.h).max()
        let worstAfter = after.map(\.l).min()
        let sinceExitPct = priceNow.map { (($0 - sell.price) / sell.price) * 100 }
        let postBestPct = bestAfter.map { (($0 - sell.price) / sell.price) * 100 }
        let postWorstPct = worstAfter.map { (($0 - sell.price) / sell.price) * 100 }
        let postBestR = riskPerShare.flatMap { r in bestAfter.map { ($0 - sell.price) / r } }
        let leftOnTable = priceNow.map { ($0 - sell.price) * sell.shares }

        let verdict = classify(
            trigger: sell.trigger, pnl: sell.pnl ?? 0, entry: entry, exit: sell.price,
            mfeR: mfeR, maeR: maeR, rMultiple: sell.rMultiple,
            postBestR: postBestR, sinceExitPct: sinceExitPct, sessionsAfter: after.count
        )

        return TradeReview(
            tradeId: sell.id, symbol: sell.symbol,
            name: Universe.bySymbol[sell.symbol]?.name ?? sell.symbol,
            openedAt: openedAt, closedAt: closedAt, holdingDays: held,
            entry: entry, exit: sell.price, stop: stop, target: target, shares: sell.shares,
            pnl: sell.pnl ?? 0, rMultiple: sell.rMultiple, trigger: sell.trigger,
            gapped: sell.gapped, backfilled: sell.backfilled, dayTrade: sell.dayTrade,
            costs: sell.commission + sell.slippage, taxDue: sell.taxDue, thesis: thesis,
            maeR: maeR, mfeR: mfeR, maePct: maePct, mfePct: mfePct,
            priceNow: priceNow, sinceExitPct: sinceExitPct,
            postExitBestPct: postBestPct, postExitWorstPct: postWorstPct, postExitBestR: postBestR,
            leftOnTable: leftOnTable, sessionsSinceExit: after.count,
            verdict: verdict,
            evidence: evidence(
                symbol: sell.symbol, entry: entry, exit: sell.price, stop: stop, target: target,
                held: held, trigger: sell.trigger, gapped: sell.gapped, backfilled: sell.backfilled,
                maeR: maeR, mfeR: mfeR, maePct: maePct, mfePct: mfePct,
                sinceExitPct: sinceExitPct, postBestPct: postBestPct, postWorstPct: postWorstPct,
                leftOnTable: leftOnTable, sessions: after.count, costs: sell.commission + sell.slippage,
                tax: sell.taxDue, verdict: verdict
            )
        )
    }

    private static func classify(trigger: String?, pnl: Double, entry: Double, exit: Double,
                                 mfeR: Double?, maeR: Double?, rMultiple: Double?,
                                 postBestR: Double?, sinceExitPct: Double?,
                                 sessionsAfter: Int) -> TradeVerdict {
        // Fewer than three sessions of history after the exit is not evidence of
        // anything. Saying so is better than pretending.
        if sessionsAfter < 3 { return .tooSoon }

        let recovered = (sinceExitPct ?? 0) > 0
        if trigger == "stop" {
            if let best = postBestR, best >= 1.0, recovered { return .whipsawed }
            if (sinceExitPct ?? 0) < -2 { return .stopSavedYou }
            return recovered ? .whipsawed : .stopSavedYou
        }

        // Was well ahead and closed near flat: the exit discipline, not the pick, is the problem.
        if let mfe = mfeR, mfe >= 2, (rMultiple ?? 0) < 0.5 { return .gaveItBack }

        /* Where price is *now* is judged before where it went, and deliberately so.
         * A position that spiked above the exit and then gave it all back was not
         * sold too early — that is the exit being right and the market being noisy,
         * and calling it a mistake would teach exactly the wrong lesson. "Sold too
         * early" has to mean the move continued and held. */
        let nowVsExit = sinceExitPct ?? 0
        if nowVsExit < -3 { return .goodExit }
        if let best = postBestR, best >= 0.75, nowVsExit > 0 { return .soldTooEarly }
        if let mae = maeR, mae >= 0.8, pnl > 0 { return .survivedHeat }
        return .clean
    }

    /// The arithmetic, written out. This is what the analyst is handed; it never
    /// has to recall a price, only explain one.
    private static func evidence(symbol: String, entry: Double, exit: Double, stop: Double?,
                                 target: Double?, held: Double, trigger: String?, gapped: Bool,
                                 backfilled: Bool = false,
                                 maeR: Double?, mfeR: Double?, maePct: Double, mfePct: Double,
                                 sinceExitPct: Double?, postBestPct: Double?, postWorstPct: Double?,
                                 leftOnTable: Double?, sessions: Int, costs: Double,
                                 tax: Double?, verdict: TradeVerdict) -> String {
        var lines: [String] = []
        lines.append("\(symbol): bought \(f(entry, 2)), sold \(f(exit, 2)) after \(f(held, 1)) days via \(trigger ?? "manual") exit\(gapped ? " (gapped through the level)" : "")\(backfilled ? " (reconstructed from the daily bar — the desk was closed when this level was reached)" : "").")
        if let stop { lines.append("Stop was \(f(stop, 2)); target was \(target.map { f($0, 2) } ?? "not set").") }
        lines.append("While held it traded as low as \(f(maePct, 1))% and as high as \(f(mfePct, 1))% against the entry" +
                     (maeR != nil && mfeR != nil ? ": \(f(maeR!, 2))R of heat taken, \(f(mfeR!, 2))R available at best." : "."))
        if sessions >= 1 {
            lines.append("Since the exit, \(sessions) sessions: price is \(f(sinceExitPct ?? 0, 1))% from where you sold, having reached \(f(postBestPct ?? 0, 1))% at best and \(f(postWorstPct ?? 0, 1))% at worst.")
            if let left = leftOnTable {
                lines.append(left >= 0
                    ? "Holding the same size untouched would be \(money(left)) better off today."
                    : "Holding the same size untouched would be \(money(-left)) worse off today.")
            }
        } else {
            lines.append("No sessions have printed since the exit, so there is nothing yet to measure.")
        }
        lines.append("Costs on this trade: \(money(costs)) in spread and commission\(tap(tax)).")
        lines.append("Engine verdict: \(verdict.label).")
        return lines.joined(separator: " ")
    }

    private static func tap(_ tax: Double?) -> String {
        guard let tax, tax > 0 else { return "" }
        return ", plus \(money(tax)) of tax on the realised gain"
    }

    /* ------------------------------------------------------- the whole record */

    static func behaviour(_ reviews: [TradeReview], state: PortfolioState,
                          accountReturnPct: Double?, benchmarkReturnPct: Double?) -> BehaviourReport {
        let winners = reviews.filter { $0.pnl > 0 }
        let losers = reviews.filter { $0.pnl <= 0 }

        let avgHoldWin = winners.isEmpty ? nil : winners.reduce(0) { $0 + $1.holdingDays } / Double(winners.count)
        let avgHoldLose = losers.isEmpty ? nil : losers.reduce(0) { $0 + $1.holdingDays } / Double(losers.count)

        let maes = reviews.compactMap(\.maeR)
        let mfes = reviews.compactMap(\.mfeR)
        let avgMae = maes.isEmpty ? nil : maes.reduce(0, +) / Double(maes.count)
        let avgMfe = mfes.isEmpty ? nil : mfes.reduce(0, +) / Double(mfes.count)

        // Of the move that was available while you held it, how much did you take?
        let capturable = reviews.compactMap { r -> (Double, Double)? in
            guard let mfe = r.mfeR, mfe > 0.1, let got = r.rMultiple else { return nil }
            return (Swift.max(0, got), mfe)
        }
        let captureRate: Double? = capturable.isEmpty ? nil
            : (capturable.reduce(0) { $0 + $1.0 } / capturable.reduce(0) { $0 + $1.1 }) * 100

        func record(_ subset: [TradeReview]) -> RegimeRecord {
            let rs = subset.compactMap(\.rMultiple)
            return RegimeRecord(
                trades: subset.count,
                wins: subset.filter { $0.pnl > 0 }.count,
                expectancyR: rs.isEmpty ? nil : rs.reduce(0, +) / Double(rs.count),
                netPnl: subset.reduce(0) { $0 + $1.pnl }
            )
        }

        /* Broken out by venue rather than by asset class.
         *
         * "Equity" used to mean everything that was not crypto, which was one market.
         * It is now two, and they behave differently enough that averaging them hides
         * the finding worth having — someone who is good at Swedish industrials and
         * bad at US momentum reads as mediocre at "equity". */
        var byClass: [String: RegimeRecord] = [:]
        for venue in Venue.allCases {
            let subset = reviews.filter { Universe.venue(of: $0.symbol) == venue }
            guard !subset.isEmpty else { continue }
            byClass[venue.rawValue] = record(subset)
        }

        var byVerdict: [String: RegimeRecord] = [:]
        for v in Set(reviews.map(\.verdict)) {
            byVerdict[v.rawValue] = record(reviews.filter { $0.verdict == v })
        }

        let leftOnTable = reviews.compactMap(\.leftOnTable).filter { $0 > 0 }.reduce(0, +)

        /* Patterns are only stated when the record actually supports them. A
         * behavioural claim from four trades is astrology. */
        var patterns: [String] = []
        if reviews.count >= 6 {
            if let w = avgHoldWin, let l = avgHoldLose, l > w * 1.4 {
                patterns.append("Losers are held \(f(l / Swift.max(w, 0.01), 1))x longer than winners: \(f(l, 1)) days against \(f(w, 1)). Winners are being cut early while losers are held.")
            } else if let w = avgHoldWin, let l = avgHoldLose, w > l * 1.4 {
                patterns.append("Winners are held \(f(w / Swift.max(l, 0.01), 1))x longer than losers, which is the correct asymmetry.")
            }
            let early = reviews.filter { $0.verdict == .soldTooEarly }.count
            if Double(early) / Double(reviews.count) > 0.35 {
                patterns.append("\(early) of \(reviews.count) exits were followed by a further move of three-quarters of a risk unit or more. The entries are finding moves; the exits are leaving most of them.")
            }
            let whip = reviews.filter { $0.verdict == .whipsawed }.count
            if Double(whip) / Double(Swift.max(1, reviews.filter { $0.trigger == "stop" }.count)) > 0.5 {
                patterns.append("Over half the stop-outs recovered afterwards. The stop is sitting inside the instrument's normal daily range rather than at the point the thesis fails.")
            }
            if let c = captureRate, c < 40 {
                patterns.append("On average \(f(c, 0))% of the move available while a position was open was captured. The picks are working; the exit rules are the constraint.")
            }
            let noStop = reviews.filter { $0.stop == nil }.count
            if noStop > 0 {
                patterns.append("\(noStop) closed position\(noStop == 1 ? "" : "s") had no stop, so \(noStop == 1 ? "its" : "their") loss was never bounded and \(noStop == 1 ? "it has" : "they have") no R multiple.")
            }
            if reviews.filter(\.backfilled).count >= 3 {
                patterns.append("\(reviews.filter(\.backfilled).count) exits were reconstructed after the fact from sessions Paper was closed for. The fills are honest — a resting stop fires whether or not you are logged in — but their timing inside the day is inferred, so treat the hold periods on those trades as approximate.")
            }
            if reviews.filter(\.gapped).count >= 2 {
                patterns.append("\(reviews.filter(\.gapped).count) exits filled through the level on a gap rather than at it. Overnight risk is why position size, not stop placement, is the binding control.")
            }
            if reviews.filter(\.dayTrade).count >= 3 {
                let dt = reviews.filter(\.dayTrade)
                let cost = dt.reduce(0) { $0 + $1.costs + ($1.taxDue ?? 0) }
                patterns.append("\(dt.count) trades opened and closed the same session, costing \(money(cost)) in spread, commission and short-term tax. Frequency raises costs regardless of whether it raises returns.")
            }
        } else if !reviews.isEmpty {
            patterns.append("\(reviews.count) closed trade\(reviews.count == 1 ? "" : "s") on the record. Behavioural patterns need a couple of dozen before they are readable.")
        }

        return BehaviourReport(
            trades: reviews.count,
            avgHoldWinnersDays: avgHoldWin,
            avgHoldLosersDays: avgHoldLose,
            holdAsymmetryDays: (avgHoldWin != nil && avgHoldLose != nil) ? avgHoldWin! - avgHoldLose! : nil,
            avgMaeR: avgMae, avgMfeR: avgMfe, captureRatePct: captureRate,
            soldTooEarlyCount: reviews.filter { $0.verdict == .soldTooEarly }.count,
            whipsawCount: reviews.filter { $0.verdict == .whipsawed }.count,
            gaveItBackCount: reviews.filter { $0.verdict == .gaveItBack }.count,
            totalLeftOnTable: leftOnTable,
            positionsWithoutStop: reviews.filter { $0.stop == nil }.count,
            gappedExits: reviews.filter(\.gapped).count,
            backfilledExits: reviews.filter(\.backfilled).count,
            dayTrades: reviews.filter(\.dayTrade).count,
            byRegime: byVerdict,
            byAssetClass: byClass,
            benchmarkReturnPct: benchmarkReturnPct,
            accountReturnPct: accountReturnPct,
            patterns: patterns
        )
    }

    /**
     * Pair each close with the entry that produced it.
     *
     * Trades are stored newest-first as a flat log, so walking backwards and
     * accumulating buys until the sold quantity is covered reconstructs the
     * position the sale closed — including the averaged-in case.
     */
    static func pairs(_ trades: [Trade]) -> [(sell: Trade, openedAt: Double, entry: Double)] {
        let chronological = trades.sorted { $0.at < $1.at }
        var open: [String: [(shares: Double, price: Double, at: Double)]] = [:]
        var out: [(sell: Trade, openedAt: Double, entry: Double)] = []

        for t in chronological {
            if t.action == "buy" {
                open[t.symbol, default: []].append((t.shares, t.price, t.at))
                continue
            }
            var remaining = t.shares
            var cost = 0.0
            var matched = 0.0
            var first: Double?
            var lots = open[t.symbol] ?? []
            while remaining > 1e-12, !lots.isEmpty {
                var lot = lots[0]
                let take = Swift.min(remaining, lot.shares)
                if first == nil { first = lot.at }
                cost += take * lot.price
                matched += take
                remaining -= take
                lot.shares -= take
                if lot.shares <= 1e-12 { lots.removeFirst() } else { lots[0] = lot }
            }
            open[t.symbol] = lots
            guard matched > 0, let openedAt = first else { continue }
            out.append((t, openedAt, cost / matched))
        }
        return out
    }
}
