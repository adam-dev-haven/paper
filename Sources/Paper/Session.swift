/**
 * Session.swift — a timed day-trading run, on bars that can actually resolve one.
 *
 * The rest of Paper reads daily bars, and the Guide has always said plainly that a
 * daily bar cannot resolve a trade that opens and closes inside one session. A day
 * trading mode built on that data would be a lie of exactly the kind this app
 * exists to argue against, so this one does not use it: a session pulls **five-day,
 * five-minute bars** — 391 of them per instrument — and every level it sets is
 * derived from intraday volatility, intraday pivots and intraday averages.
 *
 * What a session is: a fixed amount of money, a fixed amount of time, and a set of
 * rules that cannot be argued with while the clock is running.
 *
 *   **A stake, not the account.** Risk per trade is a percentage of what was
 *   committed to the session, so a bad hour costs a bounded fraction of one hour's
 *   money rather than a fraction of everything.
 *
 *   **A loss limit that ends it.** The single rule that separates day traders who
 *   are still trading from day traders who are not. Hit it and the session closes:
 *   no more entries, whatever the clock says. It is checked before every scan and
 *   after every fill, and it is not overridable while the session runs — a limit
 *   you can lift in the moment you most want to lift it is not a limit.
 *
 *   **A target that also ends it.** Trading past the goal is how the goal is given
 *   back. This is the symmetric rule and it is the one people resent.
 *
 *   **Flat at the end.** Positions opened in a session are closed when it ends.
 *   Carrying a day trade overnight, because it is slightly down and might come
 *   back, is the specific mistake this mode exists to make visible.
 *
 * The scanning is deliberately the **engine's alone**. Six chained model passes
 * every five minutes would be the exact token bonfire the governor exists to
 * prevent, and it would buy nothing: intraday setups are geometry, not narrative.
 * The analyst can be asked about one specific setup, once, on request.
 */

import Foundation

/* ---------------------------------------------------------------- the shape */

enum SessionStatus: String, Codable {
    case running
    /// The target was reached. Trading past it is how it is given back.
    case metTarget = "met-target"
    /// The loss limit stopped it.
    case hitLossLimit = "hit-loss-limit"
    case outOfTime = "out-of-time"
    case stopped

    var label: String {
        switch self {
        case .running: return "Running"
        case .metTarget: return "Target reached"
        case .hitLossLimit: return "Loss limit hit"
        case .outOfTime: return "Time up"
        case .stopped: return "Ended early"
        }
    }

    var isOver: Bool { self != .running }
}

/// One entry taken during a session, with the reason it was taken.
struct SessionEntry: Codable {
    var symbol: String
    var at: Double
    var entry: Double
    var stop: Double
    var target: Double
    var shares: Double
    var plannedRisk: Double
    var thesis: String
    /// Filled in when the position closes.
    var closedAt: Double?
    var exit: Double?
    var pnl: Double?
    var rMultiple: Double?
    var trigger: String?
    /// Spread and commission across both fills. Tracked per entry because on an
    /// intraday timeframe this is routinely most of the result, and a session report
    /// that leaves it out is describing a different activity from the one you did.
    var costs: Double?
}

struct TradingSession: Codable {
    var id: String
    var profileId: String
    var startedAt: Double
    var endsAt: Double
    var minutes: Double

    /// Committed to the session, in the ledger's dollars.
    var stake: Double
    /// Of the stake. Hitting it ends the session.
    var maxLossPct: Double
    /// Of the stake. Reaching it ends the session.
    var targetPct: Double
    /// Of the stake, per trade.
    var riskPctPerTrade: Double
    var maxTrades: Int
    /// Bar interval the session reads. Five minutes is the shortest Yahoo serves
    /// five days of, which is the shortest that also gives enough history for an
    /// ATR and a moving-average stack to mean anything.
    var interval: String
    /// Close whatever the session opened when it ends.
    var flatAtEnd: Bool

    var status: SessionStatus
    /// Account equity when the session opened, so its P/L is its own.
    var startEquity: Double
    var entries: [SessionEntry]
    var scans: Int
    var endedAt: Double?
    var endNote: String?

    static func opening(profile: Profile, stake: Double, minutes: Double, equity: Double,
                        maxLossPct: Double, targetPct: Double, riskPctPerTrade: Double,
                        maxTrades: Int, flatAtEnd: Bool) -> TradingSession {
        TradingSession(
            id: UUID().uuidString, profileId: profile.id,
            startedAt: nowMs(), endsAt: nowMs() + minutes * 60_000, minutes: minutes,
            stake: stake, maxLossPct: maxLossPct, targetPct: targetPct,
            riskPctPerTrade: riskPctPerTrade, maxTrades: maxTrades,
            interval: "5m", flatAtEnd: flatAtEnd,
            status: .running, startEquity: equity, entries: [], scans: 0,
            endedAt: nil, endNote: nil
        )
    }

    var lossLimit: Double { stake * (maxLossPct / 100) }
    var targetAmount: Double { stake * (targetPct / 100) }
    var riskPerTrade: Double { stake * (riskPctPerTrade / 100) }
    var secondsLeft: Double { Swift.max(0, (endsAt - nowMs()) / 1000) }
    var tradesTaken: Int { entries.count }

    /// Realised across every entry that has closed. Open positions are marked
    /// separately, because a session's realised and unrealised results answer
    /// different questions and averaging them hides both.
    var realised: Double { entries.compactMap(\.pnl).reduce(0, +) }

    /// What the session paid to trade, across every closed entry.
    var costsPaid: Double { entries.compactMap(\.costs).reduce(0, +) }

    /// What the result would have been with no spread and no commission. The gap
    /// between this and `realised` is the whole argument about trading frequency.
    var grossOfCosts: Double { realised + costsPaid }

    /**
     * The sizing rules a session trades under.
     *
     * Built from the session rather than the profile's horizon: the stake is the
     * equity, the stop is a fraction of the *intraday* average range, and the plan is
     * expected to resolve in bars rather than days. A setup that needs four hours on
     * five-minute bars is not a day trade, and the band says so.
     */
    func sizingRules() -> Analysis.SizingRules {
        var rules = Analysis.SizingRules(
            equity: stake,
            riskPctPerTrade: riskPctPerTrade,
            // The whole stake may go into one idea. That is what a day trader does, and
            // the session's loss limit is the real brake — a concentration cap tuned for
            // a whole account would leave every position too small to clear its costs.
            //
            // It also exposes something worth learning rather than hiding: an intraday
            // stop can sit 0.15% away, and risking 1% of the stake at that distance would
            // need a position several times the stake. There is no margin here, so the
            // stake wins and the trade risks less than the rule allows. The board says so
            // on each affected setup, because "why is this risking $5 when I said $50"
            // is the question that teaches what leverage actually is.
            maxPositionPct: 100
        )
        rules.stopScale = 0.9
        rules.targetScale = 0.9
        rules.minRewardToRisk = 1.5
        // Volatility is the point intraday, not a disqualifier — but a name whose
        // five-minute bar covers more than 2% of its price cannot be stopped sanely.
        rules.maxDailyRangePct = 2.0
        rules.minSessions = 2       // bars, not days: ten minutes
        rules.maxSessions = 30      // two and a half hours
        rules.horizonLabel = "intraday"
        return rules
    }
}

/* ------------------------------------------------------------- the live view */

/// One scanned candidate, as the session panel shows it.
struct SessionCandidate: Codable {
    let symbol: String
    let name: String
    let price: Double
    let changePct: Double
    let plan: Analysis.TradePlan
    let conviction: Double
    let regime: String
    /// Average five-minute range as a share of price — the intraday equivalent of
    /// the daily figure everywhere else, and it is not the same number.
    let barRangePct: Double?
    /// Bars expected to resolve it, at this interval.
    let barsToTarget: Double
    /// Set when the stake, not the risk rule, decided the size — which happens
    /// whenever an intraday stop is tight enough that the risk budget would buy more
    /// than the session has. Explained rather than silently applied.
    let sizeNote: String?
    /// Nil when it can be taken. A sentence when it cannot.
    let blocked: String?
}

struct SessionPanel: Codable {
    let session: TradingSession?
    let status: String
    /// Realised plus what the open session positions are currently worth.
    let realised: Double
    let unrealised: Double
    let total: Double
    let totalPct: Double
    let secondsLeft: Double
    let lossLimit: Double
    let lossHeadroom: Double
    let targetAmount: Double
    let dayTradesLeft: Int?
    let candidates: [SessionCandidate]
    let openSymbols: [String]
    let barsAt: Double
    let marketOpen: Bool
    let note: String
}

/* ------------------------------------------------------------------ the rules */

enum SessionEngine {

    /**
     * Instruments a session will look at. Deliberately narrow: a scan every few
     * minutes over a whole board is one request per name per scan, and the ones that matter
     * intraday are the liquid ones.
     *
     * What is tradable is asked per exchange rather than once. Between 09:00 and
     * 15:30 Stockholm time the Swedish board is open and New York is not, which is
     * most of a Swedish morning — a session started then used to offer crypto alone
     * while an entire equity market was trading.
     */
    static func universe(for profile: Profile, at now: Date = Date()) -> [String] {
        let tradable = Universe.all.filter {
            profile.allows($0.symbol)
                && !Universe.benchmarks.contains($0.symbol)
                && MarketCalendar.isSessionOpen(now, venue: $0.venue)
        }
        return Array(tradable.map(\.symbol).prefix(12))
    }

    /**
     * Why a candidate cannot be taken right now. Ordered by which answer is most
     * useful to read: the session's own limits before the market's.
     *
     * Whether a market is open is asked per *symbol*, not passed in: the board
     * spans two exchanges and crypto, so one boolean for "the market" would let a
     * New York name through on a Swedish morning. `now` is injectable so a test can
     * state the hour it means rather than depending on when it is run.
     */
    static func blocker(_ session: TradingSession, plan: Analysis.TradePlan,
                        symbol: String, held: Bool, openRisk: Double,
                        dayTradesLeft: Int?, now: Date = Date()) -> String? {
        if let rejected = plan.rejected { return rejected }
        if held { return "Already open in this session." }
        if session.tradesTaken >= session.maxTrades {
            return "This session's limit of \(session.maxTrades) trades has been reached. The cap is there because the tenth idea of an hour is rarely as good as the first."
        }
        // The loss limit is checked against realised *plus* what is currently at risk,
        // not just realised. A session one trade from its limit that opens another
        // full-size position has already breached it, it just does not know yet.
        let committed = -Swift.min(0, session.realised) + openRisk
        if committed + session.riskPerTrade > session.lossLimit {
            return "Taking this would put more at risk than the session has left. \(money(session.lossLimit)) is the limit, \(money(-Swift.min(0, session.realised))) is already lost and \(money(openRisk)) is at risk in open positions."
        }
        if !MarketCalendar.isOpen(for: symbol, at: now) {
            return MarketCalendar.sessionNote(for: symbol, at: now)
        }
        if let left = dayTradesLeft, left <= 0, Universe.venue(of: symbol).subjectToPDT {
            return "The pattern day trader rule has this account at its limit — no fourth same-session round trip in five business days under $25,000. It is a US rule, so crypto and Stockholm listings are exempt."
        }
        return nil
    }

    /**
     * Whether the session should end, and why.
     *
     * Checked before every scan and after every fill. The order matters: the loss
     * limit is tested first, because a session that hit its limit and its target in
     * the same minute hit its limit.
     */
    static func verdict(_ session: TradingSession, unrealised: Double) -> (SessionStatus, String)? {
        let total = session.realised + unrealised
        if total <= -session.lossLimit {
            return (.hitLossLimit, "The session lost \(money(-total)) against a \(money(session.lossLimit)) limit and is closed to new entries. The limit was set before the session started and cannot be raised while it runs.")
        }
        if total >= session.targetAmount {
            return (.metTarget, "The session made \(money(total)) against a \(money(session.targetAmount)) target and is closed to new entries. The target was set before the session started and cannot be raised while it runs.")
        }
        if session.secondsLeft <= 0 {
            return (.outOfTime, "The session's \(f(session.minutes, 0)) minutes are up.\(session.flatAtEnd ? " Anything it opened has been closed at the current price." : " Positions were left open, so these are no longer day trades.")")
        }
        return nil
    }

    /// The account-level sentence shown above the session panel.
    static func note(_ session: TradingSession?, marketOpen: Bool) -> String {
        guard let session else {
            if marketOpen {
                return "A session commits a set amount of money for a set amount of time and trades it on five-minute bars, against limits that cannot be changed while the clock runs."
            }
            let open = [Venue.us, .stockholm].filter { MarketCalendar.isSessionOpen(venue: $0) }
            if open.isEmpty {
                return "Every equity market on this board is closed, so a session opened now would trade crypto only, which runs continuously and has no closing bell to end a losing run."
            }
            return "\(open.map(\.exchangeName).joined(separator: " and ")) still trading. A session opened now reads what is open, plus crypto."
        }
        if session.status.isOver { return session.endNote ?? session.status.label }
        return "Running for another \(f(session.secondsLeft / 60, 0)) minutes. \(money(session.riskPerTrade)) at risk per trade, \(money(session.lossLimit)) the most this session may lose."
    }
}
