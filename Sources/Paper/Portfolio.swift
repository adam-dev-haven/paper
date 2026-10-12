/**
 * Portfolio.swift — the fake-money ledger, one per profile.
 *
 * No broker, no order routing, no real asset ever changes hands. What it does
 * model honestly is the part beginners get wrong: that a position has a size,
 * that the size follows from where the stop is, that an exit decided in advance
 * is the only exit that survives contact with a red candle — and that all of it
 * costs money.
 *
 * Every fill here crosses a spread, pays a commission, and lands in a tax lot.
 * Every bracket is checked against the session's *open* as well as its range, so
 * a stop that gapped through fills where the market actually was rather than
 * where the plan hoped. Those are not decorations. They are the difference
 * between a simulator that teaches a method and one that teaches you to trust a
 * number that will not survive contact with a real account.
 *
 * Each profile owns a separate ledger, because a day trader and a long-term
 * holder sharing one equity curve would make both records meaningless.
 */

import Foundation

/**
 * Reading a file that an older build wrote.
 *
 * Swift's synthesised `init(from:)` does **not** fall back to a property's default
 * value when the key is missing — it throws `keyNotFound`. So adding one field with
 * a default to a persisted struct makes every file written before that field
 * unreadable. On 2026-09-13 that is exactly what happened here: three new fields
 * (`lastSweptAt`, `appliedSplits`, `backfilled`) made every existing ledger fail to
 * decode, and the "corrupt ledger is not worth crashing over" fallback then replaced
 * each one with an empty ledger and saved it. Six accounts were destroyed in six
 * milliseconds by what was meant to be a resilience measure.
 *
 * So the persisted types decode by hand, field by field, with `decodeIfPresent` and
 * an explicit default for everything that is not genuinely identifying. A file from
 * any older build reads; a field added tomorrow cannot break a file written today.
 * Only a handful of keys are required, and their absence means the file is not a
 * ledger at all rather than a ledger from a different version.
 *
 * The rule for anyone adding a field: give it a default here, never rely on the
 * synthesised decoder, and never let a read failure write anything.
 */

struct Position: Codable {
    var id: String
    var symbol: String
    var shares: Double
    /// Blended cost per share, including what it cost to get in.
    var avgPrice: Double
    var openedAt: Double
    /// The trading session the first parcel was opened in, for the day-trade count.
    var openedSession: String
    var target: Double?
    var stop: Double?
    /// The reasoning captured at entry, so the review later is honest.
    var thesis: String
    /// Dollars intended to be at risk when the trade was opened.
    var plannedRisk: Double?
    /// Parcels, oldest first. Selling matches them in order.
    var lots: [TaxLot]
    /// The best and worst the position has traded while held, in price terms.
    var highWater: Double
    var lowWater: Double
    /**
     * Units of the instrument's currency per dollar, blended across the parcels
     * that built this position.
     *
     * Every price on this struct — `avgPrice`, `stop`, `target`, the water marks —
     * is in the instrument's own currency, because a stop on Nasdaq Stockholm is a
     * kronor order and drawing it in dollars would move the level every time the
     * krona did. This is the rate that turns those prices into the dollars the
     * ledger settles in, as it stood when the position was opened. Holding it means
     * the profit can be split into the part the stock made and the part the currency
     * made, which is a real division a Swedish account lives with and one no
     * simulator usually shows. 1 for anything quoted in dollars.
     */
    var fxAtOpen: Double

    init(id: String, symbol: String, shares: Double, avgPrice: Double, openedAt: Double,
         openedSession: String, target: Double?, stop: Double?, thesis: String,
         plannedRisk: Double?, lots: [TaxLot], highWater: Double, lowWater: Double,
         fxAtOpen: Double = 1) {
        self.id = id; self.symbol = symbol; self.shares = shares; self.avgPrice = avgPrice
        self.openedAt = openedAt; self.openedSession = openedSession
        self.target = target; self.stop = stop; self.thesis = thesis
        self.plannedRisk = plannedRisk; self.lots = lots
        self.highWater = highWater; self.lowWater = lowWater
        self.fxAtOpen = fxAtOpen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity and size are what make this a position. Everything else can be
        // absent because an older build did not write it yet.
        id = try c.decode(String.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        shares = try c.decode(Double.self, forKey: .shares)
        avgPrice = try c.decode(Double.self, forKey: .avgPrice)
        openedAt = try c.decodeIfPresent(Double.self, forKey: .openedAt) ?? nowMs()
        openedSession = try c.decodeIfPresent(String.self, forKey: .openedSession)
            ?? MarketCalendar.sessionKey(Date(timeIntervalSince1970: openedAt / 1000), for: symbol)
        target = try c.decodeIfPresent(Double.self, forKey: .target)
        stop = try c.decodeIfPresent(Double.self, forKey: .stop)
        thesis = try c.decodeIfPresent(String.self, forKey: .thesis) ?? ""
        plannedRisk = try c.decodeIfPresent(Double.self, forKey: .plannedRisk)
        lots = try c.decodeIfPresent([TaxLot].self, forKey: .lots) ?? []
        highWater = try c.decodeIfPresent(Double.self, forKey: .highWater) ?? avgPrice
        lowWater = try c.decodeIfPresent(Double.self, forKey: .lowWater) ?? avgPrice
        // A position written before Paper knew about foreign listings was a dollar
        // position, and the lots it carries say the same thing.
        fxAtOpen = try c.decodeIfPresent(Double.self, forKey: .fxAtOpen) ?? 1
    }

    /// Blended cost per share in the currency the ledger settles in. Taken from the
    /// parcels where there are any, because each one carries the rate it was filled
    /// at; an older position without parcels falls back to the position's own rate.
    var avgPriceUSD: Double {
        let sharesInLots = lots.reduce(0) { $0 + $1.shares }
        guard sharesInLots > 1e-12 else {
            return avgPrice / (fxAtOpen.isFinite && fxAtOpen > 0 ? fxAtOpen : 1)
        }
        let basis = lots.reduce(0) { $0 + $1.costPerShareUSD * $1.shares }
        return basis / sharesInLots
    }
}

struct Trade: Codable {
    let id: String
    let symbol: String
    let action: String       // "buy" | "sell"
    let shares: Double
    /// What actually filled, after crossing the spread.
    let price: Double
    /// The mid the desk was quoting when the order went in.
    let quotedPrice: Double
    let value: Double
    let at: Double
    let commission: Double
    /// Dollars given up to the spread on this fill.
    let slippage: Double
    /// Present on closes: realised profit or loss, net of costs.
    let pnl: Double?
    /// Present on closes: the result in multiples of the risk taken.
    let rMultiple: Double?
    /// Present on closes: tax owed on the realised gain.
    let taxDue: Double?
    /// True when a bracket filled past its level because the session gapped.
    let gapped: Bool
    let reason: String
    /// How the exit happened, when it was not a manual click.
    let trigger: String?     // "manual" | "target" | "stop"
    /// True when this close opened and shut inside one session.
    let dayTrade: Bool
    /**
     * True when this fill was reconstructed after the fact, from bars covering a
     * window the app was not running for, rather than observed live.
     *
     * Kept distinct on purpose. A reconstructed exit is a weaker claim than a live
     * one: daily bars prove a level was touched, not when inside the session it was
     * touched or — when both legs sat in one bar — which one went first. The record
     * says so rather than quietly presenting the two as the same thing.
     */
    var backfilled: Bool = false

    init(id: String, symbol: String, action: String, shares: Double, price: Double,
         quotedPrice: Double, value: Double, at: Double, commission: Double,
         slippage: Double, pnl: Double?, rMultiple: Double?, taxDue: Double?,
         gapped: Bool, reason: String, trigger: String?, dayTrade: Bool,
         backfilled: Bool = false) {
        self.id = id; self.symbol = symbol; self.action = action; self.shares = shares
        self.price = price; self.quotedPrice = quotedPrice; self.value = value; self.at = at
        self.commission = commission; self.slippage = slippage
        self.pnl = pnl; self.rMultiple = rMultiple; self.taxDue = taxDue
        self.gapped = gapped; self.reason = reason; self.trigger = trigger
        self.dayTrade = dayTrade; self.backfilled = backfilled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        action = try c.decode(String.self, forKey: .action)
        shares = try c.decodeIfPresent(Double.self, forKey: .shares) ?? 0
        price = try c.decodeIfPresent(Double.self, forKey: .price) ?? 0
        quotedPrice = try c.decodeIfPresent(Double.self, forKey: .quotedPrice) ?? price
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? (shares * price)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? nowMs()
        commission = try c.decodeIfPresent(Double.self, forKey: .commission) ?? 0
        slippage = try c.decodeIfPresent(Double.self, forKey: .slippage) ?? 0
        pnl = try c.decodeIfPresent(Double.self, forKey: .pnl)
        rMultiple = try c.decodeIfPresent(Double.self, forKey: .rMultiple)
        taxDue = try c.decodeIfPresent(Double.self, forKey: .taxDue)
        gapped = try c.decodeIfPresent(Bool.self, forKey: .gapped) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        dayTrade = try c.decodeIfPresent(Bool.self, forKey: .dayTrade) ?? false
        backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
    }
}

/**
 * The four small types below are inside the ledger, and they decode by hand for
 * exactly the same reason the big ones do.
 *
 * `decodeIfPresent` on `PortfolioState` guards a missing **key**, not a malformed
 * **value**: `decodeIfPresent([EquityPoint].self, forKey: .equityCurve)` returns
 * nil when the key is absent and *throws* when the key is there and one element
 * will not decode. So a field added to `EquityPoint` made every existing ledger
 * unreadable even though `PortfolioState` itself was careful — the rule at the top
 * of this file was written for the containers and never carried into the things
 * they contain. Quarantine now stops that destroying an account, but the account
 * still goes read-only, which is not a fix, it is a better failure.
 *
 * `SchemaGate.swift` enforces this from the self-test: every persisted type
 * is round-tripped with each key dropped in turn, and any key that is not
 * genuinely identifying failing the decode is a build failure.
 */
struct Contribution: Codable {
    var at: Double
    var amount: Double
    var note: String

    init(at: Double, amount: Double, note: String) {
        self.at = at; self.amount = amount; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? nowMs()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct EquityPoint: Codable {
    var t: Double
    var equity: Double
    var cash: Double
    var invested: Double
    /// Capital paid in to date, so the curve can separate growth from deposits.
    var contributed: Double

    init(t: Double, equity: Double, cash: Double, invested: Double, contributed: Double) {
        self.t = t; self.equity = equity; self.cash = cash
        self.invested = invested; self.contributed = contributed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A point with no timestamp cannot be placed on a curve, so it is the one
        // field worth refusing over.
        t = try c.decode(Double.self, forKey: .t)
        equity = try c.decodeIfPresent(Double.self, forKey: .equity) ?? 0
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        invested = try c.decodeIfPresent(Double.self, forKey: .invested) ?? Swift.max(0, equity - cash)
        contributed = try c.decodeIfPresent(Double.self, forKey: .contributed) ?? 0
    }
}

struct PortfolioState: Codable {
    var profileId: String
    var cash: Double
    var positions: [Position]
    var trades: [Trade]
    var equityCurve: [EquityPoint]
    var createdAt: Double
    var realizedGains: [RealizedGain]
    var dayTrades: [DayTradeRecord]
    var contributions: [Contribution]
    /// "2026-09" — so a month's contribution lands exactly once.
    var lastContributionMonth: String
    var startingCapital: Double
    var totalContributed: Double
    var totalCommission: Double
    var totalSlippage: Double
    var totalTax: Double
    /**
     * The last moment brackets were swept against real bars.
     *
     * Everything between this and now is unexamined market the ledger has not yet
     * been held to account for. Zero on a ledger written before reconciliation
     * existed, which the sweep reads as "start from the oldest open position".
     */
    var lastSweptAt: Double = 0
    /// Splits already applied, keyed `SYMBOL@timestamp`, so a restated position is
    /// never restated twice across two launches.
    var appliedSplits: [String] = []
    /// Tax withheld per calendar year, so a later loss can claw back what an
    /// earlier gain paid. Capital losses offset gains within the year; withholding
    /// each sale gross and never refunding would overstate the cost of trading.
    var taxWithheldByYear: [String: Double] = [:]

    init(profileId: String, cash: Double, positions: [Position], trades: [Trade],
         equityCurve: [EquityPoint], createdAt: Double, realizedGains: [RealizedGain],
         dayTrades: [DayTradeRecord], contributions: [Contribution],
         lastContributionMonth: String, startingCapital: Double, totalContributed: Double,
         totalCommission: Double, totalSlippage: Double, totalTax: Double,
         lastSweptAt: Double = 0, appliedSplits: [String] = [],
         taxWithheldByYear: [String: Double] = [:]) {
        self.profileId = profileId; self.cash = cash; self.positions = positions
        self.trades = trades; self.equityCurve = equityCurve; self.createdAt = createdAt
        self.realizedGains = realizedGains; self.dayTrades = dayTrades
        self.contributions = contributions; self.lastContributionMonth = lastContributionMonth
        self.startingCapital = startingCapital; self.totalContributed = totalContributed
        self.totalCommission = totalCommission; self.totalSlippage = totalSlippage
        self.totalTax = totalTax; self.lastSweptAt = lastSweptAt
        self.appliedSplits = appliedSplits; self.taxWithheldByYear = taxWithheldByYear
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /* `profileId` is the only required key. Its absence means this file is not a
         * ledger — which is a real error worth reporting — whereas a missing
         * `lastSweptAt` just means the file predates that field. Conflating the two is
         * what cost six accounts. */
        profileId = try c.decode(String.self, forKey: .profileId)
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        positions = try c.decodeIfPresent([Position].self, forKey: .positions) ?? []
        trades = try c.decodeIfPresent([Trade].self, forKey: .trades) ?? []
        equityCurve = try c.decodeIfPresent([EquityPoint].self, forKey: .equityCurve) ?? []
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? nowMs()
        realizedGains = try c.decodeIfPresent([RealizedGain].self, forKey: .realizedGains) ?? []
        dayTrades = try c.decodeIfPresent([DayTradeRecord].self, forKey: .dayTrades) ?? []
        contributions = try c.decodeIfPresent([Contribution].self, forKey: .contributions) ?? []
        lastContributionMonth = try c.decodeIfPresent(String.self, forKey: .lastContributionMonth) ?? ""
        startingCapital = try c.decodeIfPresent(Double.self, forKey: .startingCapital) ?? cash
        totalContributed = try c.decodeIfPresent(Double.self, forKey: .totalContributed) ?? 0
        totalCommission = try c.decodeIfPresent(Double.self, forKey: .totalCommission) ?? 0
        totalSlippage = try c.decodeIfPresent(Double.self, forKey: .totalSlippage) ?? 0
        totalTax = try c.decodeIfPresent(Double.self, forKey: .totalTax) ?? 0
        lastSweptAt = try c.decodeIfPresent(Double.self, forKey: .lastSweptAt) ?? 0
        appliedSplits = try c.decodeIfPresent([String].self, forKey: .appliedSplits) ?? []
        taxWithheldByYear = try c.decodeIfPresent([String: Double].self, forKey: .taxWithheldByYear) ?? [:]
    }
}

/// The price facts a fill or an exit decision needs. A `Quote` supplies most of
/// them; the bars supply the session open and the ATR.
struct MarkPrice {
    let price: Double
    var prevClose: Double?
    var dayHigh: Double?
    var dayLow: Double?
    /// Where the session opened. A stop below this filled at the stop; a stop
    /// *above* it means the market gapped through and the fill is the open.
    var dayOpen: Double?
    /// Drives the spread. Volatile instruments cost more to trade, always.
    var atr: Double?
    /**
     * Units of this instrument's quote currency per US dollar, right now.
     *
     * Every other field on this struct is in the instrument's own currency. This is
     * the one number that turns them into the dollars the ledger keeps, and it is
     * 1 for everything quoted in dollars — which is every instrument Paper followed
     * before Stockholm was added, and why nothing about a US fill changed.
     */
    var fxPerUSD: Double = 1

    /// The rate, guarded. A zero or a NaN arriving from a failed FX fetch must not
    /// silently turn a position's value into infinity.
    var safeFX: Double { fxPerUSD.isFinite && fxPerUSD > 0 ? fxPerUSD : 1 }

    /// A native price, in the currency the ledger settles in.
    func usd(_ nativePrice: Double) -> Double { nativePrice / safeFX }

    init(price: Double, prevClose: Double? = nil, dayHigh: Double? = nil,
         dayLow: Double? = nil, dayOpen: Double? = nil, atr: Double? = nil,
         fxPerUSD: Double = 1) {
        self.price = price
        self.prevClose = prevClose
        self.dayHigh = dayHigh
        self.dayLow = dayLow
        self.dayOpen = dayOpen
        self.atr = atr
        self.fxPerUSD = fxPerUSD
    }

    init(_ q: Quote, dayOpen: Double? = nil, atr: Double? = nil, fxPerUSD: Double = 1) {
        self.price = q.price
        self.prevClose = q.prevClose
        self.dayHigh = q.dayHigh
        self.dayLow = q.dayLow
        self.dayOpen = dayOpen
        self.atr = atr
        self.fxPerUSD = fxPerUSD
    }
}

struct ValuedPosition: Codable {
    let id: String
    let symbol: String
    let shares: Double
    let avgPrice: Double
    let openedAt: Double
    let target: Double?
    let stop: Double?
    let thesis: String
    let plannedRisk: Double?
    let price: Double
    let value: Double
    let pnl: Double
    let pnlPct: Double
    /// The currency the prices above are quoted in. "USD" for almost everything;
    /// "SEK" for a Stockholm listing, whose entry, stop and target are kronor.
    let currency: String
    /// Of the profit, how much the exchange rate accounts for rather than the
    /// instrument. Nil where there is no exchange rate involved.
    let fxPnl: Double?
    /// Where price sits between the stop and the target, 0–1.
    let bracketProgress: Double?
    let toTargetPct: Double?
    let toStopPct: Double?
    /// What closing at the stop would cost from here — the live risk, not the planned one.
    let openRisk: Double?
    let holdingDays: Double
    /// True once the position has been held long enough for the lower tax rate.
    let longTermQualified: Bool
    /// How far the position ran in your favour, and against you, while held.
    let excursionUpPct: Double
    let excursionDownPct: Double
}

struct Valued: Codable {
    let cash: Double
    let invested: Double
    let equity: Double
    let totalPnl: Double
    let totalPnlPct: Double
    let dayPnl: Double
    /// Growth only — what the account made on top of everything paid into it.
    let netOfContributions: Double
    let totalContributed: Double
    let positions: [ValuedPosition]
    /// Total money at risk across every open stop, and what that is as a share of equity.
    let openRisk: Double
    let heatPct: Double
    let costsToDate: Double
}

struct Scorecard: Codable {
    let closedTrades: Int
    let wins: Int
    let losses: Int
    let winRate: Double?
    let avgWin: Double?
    let avgLoss: Double?
    let profitFactor: Double?
    let expectancyR: Double?
    let bestTrade: Trade?
    let worstTrade: Trade?
    let stoppedOut: Int
    let targetsHit: Int
    let manualExits: Int
    let gappedExits: Int
    /// Exits rebuilt from bars after the fact rather than observed live. Reported
    /// separately because they are a weaker claim, and burying them in the total
    /// would be the record quietly overstating what it actually saw.
    var backfilledExits: Int = 0
    let dayTrades: Int
    let totalCommission: Double
    let totalSlippage: Double
    let totalTax: Double
    /// What the account would have made with no spread, commission or tax. The
    /// gap between this and the real figure is what frequency actually costs.
    let pnlBeforeCosts: Double?
    /// The lesson the numbers are currently teaching, in one sentence.
    let verdict: String
}

final class Portfolio {
    private(set) var state: PortfolioState
    private let url: URL
    /// Owned by the caller and kept current — frictions and sizing come from it.
    var profile: Profile

    /**
     * Set when the file on disk existed but could not be read.
     *
     * While this is set the ledger **never writes**. That is the whole point: the
     * previous version of this class answered an unreadable file by constructing an
     * empty ledger and immediately saving it over the top, which turned every
     * read-time problem into permanent deletion and did exactly that to six accounts.
     * An account that cannot be read is a problem to be shown to someone, not a
     * problem to be solved by overwriting the evidence.
     */
    private(set) var loadError: String?

    /// Where the unreadable file was preserved, for the interface to name.
    private(set) var quarantinedAt: URL?

    init(profile: Profile, url: URL) {
        self.profile = profile
        self.url = url

        guard let data = try? Data(contentsOf: url) else {
            // No file at all is a genuinely new account, and writing one is correct.
            state = Portfolio.empty(profile)
            persist()
            return
        }

        do {
            state = try JSONDecoder().decode(PortfolioState.self, from: data)
        } catch {
            // The bytes are kept, twice: the original file is left exactly where it is,
            // and a copy is set aside under a name nothing else will reach for.
            state = Portfolio.empty(profile)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
            try? data.write(to: aside)
            quarantinedAt = aside
            loadError = "This account\u{2019}s ledger could not be read, so nothing will be written to it. "
                + "The file has not been changed, and a copy is at \(aside.lastPathComponent). "
                + "Reason: \(error)"
            // The highest-severity thing this app can say about itself: an account
            // exists, cannot be read, and is now deliberately not being written.
            log("[ledger] REFUSING TO WRITE \(profile.name): \(error)", .error, "ledger")
            log("[ledger] the file is untouched; a copy is at \(aside.path)", .error, "ledger")
        }
    }

    static func empty(_ profile: Profile) -> PortfolioState {
        PortfolioState(
            profileId: profile.id,
            cash: profile.startingCapital,
            positions: [], trades: [],
            equityCurve: [EquityPoint(t: nowMs(), equity: profile.startingCapital,
                                      cash: profile.startingCapital, invested: 0, contributed: 0)],
            createdAt: nowMs(),
            realizedGains: [], dayTrades: [], contributions: [],
            lastContributionMonth: Portfolio.monthKey(Date()),
            startingCapital: profile.startingCapital,
            totalContributed: 0, totalCommission: 0, totalSlippage: 0, totalTax: 0,
            taxWithheldByYear: [:]
        )
    }

    private static func monthKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private func persist() {
        // An account whose file could not be read is never written over. See `loadError`.
        guard loadError == nil else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        // Write beside the file and rename, so a crash mid-write cannot leave a half-ledger.
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url)
        }
    }

    private func newId() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in alphabet.randomElement()! })
            + String(Int(nowMs()), radix: 36).suffix(4)
    }

    /* ---------------------------------------------------------- contributions */

    /// Pays in the monthly contribution the first time the desk refreshes in a new
    /// month. Most real accounts grow far more from deposits than from trading,
    /// and a simulator that hides that teaches the wrong lesson about where
    /// returns come from.
    @discardableResult
    func applyContribution(now: Date = Date()) -> [Contribution] {
        guard profile.monthlyContribution > 0 else { return [] }
        let key = Portfolio.monthKey(now)
        guard key != state.lastContributionMonth else { return [] }

        /* Every month between the last one paid and this one, not just this one.
         * The old behaviour paid in once however long the desk had been shut, so an
         * account left alone for a quarter came back one deposit heavier instead of
         * three — understating both the balance and, more importantly, the share of
         * the equity curve that came from deposits rather than from trading. That is
         * the single most flattering thing a simulator can get wrong about returns. */
        let cal = Calendar(identifier: .gregorian)
        var due: [Date] = []
        if let last = Portfolio.monthDate(state.lastContributionMonth),
           let thisMonth = Portfolio.monthDate(key) {
            // Compared as dates, not as keys. `monthKey` does not zero-pad, so
            // "2026-10" sorts *before* "2026-9" as a string and the walk either stops
            // a month early or runs away — which is exactly the class of bug this
            // whole pass exists to stop, so it does not get to live here either.
            var cursor = last
            while let next = cal.date(byAdding: .month, value: 1, to: cursor),
                  next <= thisMonth, due.count < 600 {
                due.append(next)
                cursor = next
            }
        }
        if due.isEmpty { due = [now] }

        var paid: [Contribution] = []
        for month in due {
            // Dated to the month it belongs to, so the equity curve steps where the
            // money actually arrived.
            let at = min(month.timeIntervalSince1970 * 1000, now.timeIntervalSince1970 * 1000)
            let c = Contribution(
                at: at, amount: profile.monthlyContribution,
                note: "Monthly contribution paid in. The equity curve reports growth from deposits separately from growth from trading."
            )
            state.cash += c.amount
            state.totalContributed += c.amount
            state.contributions.insert(c, at: 0)
            paid.append(c)
        }
        state.lastContributionMonth = key
        persist()
        return paid
    }

    /// `"2026-9"` back to a date, for walking the months a closed desk missed.
    static func monthDate(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /* -------------------------------------------------------------- valuation */

    func value(_ prices: [String: MarkPrice]) -> Valued {
        var invested = 0.0
        var dayPnl = 0.0
        var openRisk = 0.0
        let today = Calendar.current.startOfDay(for: Date())

        let positions: [ValuedPosition] = state.positions.map { p in
            let q = prices[p.symbol]
            // Prices are in the instrument's own currency; money is in dollars. The
            // rate is the only thing that crosses between them, and it is applied
            // here rather than scattered through the arithmetic below.
            let price = q?.price ?? p.avgPrice
            let fxNow = q?.safeFX ?? (p.fxAtOpen.isFinite && p.fxAtOpen > 0 ? p.fxAtOpen : 1)
            let val = (price * p.shares) / fxNow
            invested += val
            // A position opened today has not lived through the session, so its day P/L
            // runs from what you paid — not from a previous close you were never exposed
            // to. Otherwise the desk reports a loss on a trade placed a minute ago.
            let openedToday = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: p.openedAt / 1000)) == today
            let dayBasis = openedToday ? p.avgPrice : q?.prevClose
            if let dayBasis { dayPnl += ((price - dayBasis) * p.shares) / fxNow }

            /* Profit, in dollars, against what the parcels actually cost in dollars.
             *
             * For a Stockholm holding this is two things at once: what the stock did
             * in kronor, and what the krona did against the dollar. Both are real —
             * an account that settles in dollars and holds a kronor asset carries the
             * currency whether it wanted to or not — so the total is reported as the
             * profit and the currency's share of it is reported beside it rather than
             * hidden inside. */
            let costUSD = p.avgPriceUSD * p.shares
            let pnl = val - costUSD
            // What the same stock move would have earned had the rate not budged.
            let fxPnl: Double? = {
                guard Universe.needsConversion(p.symbol) else { return nil }
                let atOpenRate = p.fxAtOpen.isFinite && p.fxAtOpen > 0 ? p.fxAtOpen : fxNow
                let withoutFX = ((price - p.avgPrice) * p.shares) / atOpenRate
                return pnl - withoutFX
            }()
            var span: Double?
            if let t = p.target, let s = p.stop { span = t - s }
            var progress: Double?
            if let span, span > 0, let s = p.stop { progress = Swift.max(0, Swift.min(1, (price - s) / span)) }

            // Live risk: what closing at the stop would cost from here, floored at
            // zero. A stop trailed above the current price means the trade can no
            // longer lose, and the floor is deliberate — heat is a measure of
            // exposure, and a position with none contributes nothing rather than
            // subtracting from the risk another position is genuinely carrying.
            var risk: Double?
            if let s = p.stop {
                risk = Swift.max(0, ((price - s) * p.shares) / fxNow)
                openRisk += risk ?? 0
            }

            let held = MarketCalendar.calendarDays(from: p.openedAt, to: nowMs())
            let high = Swift.max(p.highWater, price)
            let low = Swift.min(p.lowWater, price)

            return ValuedPosition(
                id: p.id, symbol: p.symbol, shares: p.shares, avgPrice: p.avgPrice,
                openedAt: p.openedAt, target: p.target, stop: p.stop,
                thesis: p.thesis, plannedRisk: p.plannedRisk,
                price: price, value: val, pnl: pnl,
                // Return on what was actually paid, in the unit the account is kept
                // in. Identical to the price move for a dollar instrument, and
                // deliberately not identical for a foreign one.
                pnlPct: costUSD != 0 ? (pnl / costUSD) * 100 : 0,
                currency: Universe.currency(of: p.symbol).code,
                fxPnl: fxPnl,
                bracketProgress: progress,
                toTargetPct: p.target.map { (($0 - price) / price) * 100 },
                toStopPct: p.stop.map { (($0 - price) / price) * 100 },
                openRisk: risk,
                holdingDays: held,
                longTermQualified: held >= profile.frictions.longTermHoldingDays,
                excursionUpPct: p.avgPrice != 0 ? ((high - p.avgPrice) / p.avgPrice) * 100 : 0,
                excursionDownPct: p.avgPrice != 0 ? ((low - p.avgPrice) / p.avgPrice) * 100 : 0
            )
        }

        let equity = state.cash + invested
        let paidIn = state.startingCapital + state.totalContributed
        let costs = state.totalCommission + state.totalSlippage + state.totalTax

        return Valued(
            cash: state.cash,
            invested: invested,
            equity: equity,
            totalPnl: equity - state.startingCapital,
            totalPnlPct: state.startingCapital != 0 ? ((equity - state.startingCapital) / state.startingCapital) * 100 : 0,
            dayPnl: dayPnl,
            netOfContributions: equity - paidIn,
            totalContributed: state.totalContributed,
            positions: positions,
            openRisk: openRisk,
            heatPct: equity > 0 ? (openRisk / equity) * 100 : 0,
            costsToDate: costs
        )
    }

    /* ----------------------------------------------------------------- orders */

    enum OrderResult {
        case ok(Trade)
        case failed(String)
    }

    /// Checks that have to pass before an order exists at all. Refusing a trade
    /// for a rule the market really enforces is more useful than filling it.
    func gate(symbol: String, equity: Double, closing: Bool) -> String? {
        // Each instrument answers to its own exchange. Stockholm has been shut for
        // two hours by the time New York opens, and a board holding both cannot ask
        // one clock about the other.
        if profile.frictions.enforceMarketHours, !MarketCalendar.isOpen(for: symbol) {
            return "\(MarketCalendar.sessionNote(for: symbol)) Orders queue until the open at a real broker, so filling one now at a stale price is not simulated."
        }
        if closing, let reason = PDT.blocks(symbol: symbol, equity: equity, records: state.dayTrades, frictions: profile.frictions) {
            return reason
        }
        return nil
    }

    func buy(symbol: String, shares: Double, mark: MarkPrice,
             target: Double? = nil, stop: Double? = nil,
             thesis: String? = nil, plannedRisk: Double? = nil,
             skipGate: Bool = false) -> OrderResult {
        guard shares > 0, shares.isFinite else { return .failed("Share count must be positive.") }
        guard mark.price > 0 else { return .failed("No live price for that symbol.") }

        let equity = value([:]).equity
        if !skipGate, let blocked = gate(symbol: symbol, equity: equity, closing: false) {
            return .failed(blocked)
        }

        /* You buy at the ask, not the mid.
         *
         * The fill, the spread and the notional are all in the instrument's own
         * currency, because that is the currency the order carries. The commission
         * is a dollar charge on a dollar notional — the presets are written that way
         * — so the notional crosses first and everything from there is money. */
        let fx = mark.safeFX
        let fill = profile.frictions.buyFill(mark.price, atr: mark.atr)
        let slip = ((fill - mark.price) * shares) / fx
        let notionalNative = shares * fill
        let notional = notionalNative / fx
        let commission = profile.frictions.commission(notional: notional)
        let cost = notional + commission

        if cost > state.cash + 1e-6 {
            return .failed("Not enough cash. That order costs $\(f(cost, 2)) once the spread and $\(f(commission, 2)) of commission are paid; you hold $\(f(state.cash, 2)).")
        }

        state.cash -= cost
        state.totalCommission += commission
        state.totalSlippage += slip

        /* The cost basis carries the commission, exactly as a real one does — which
         * is why a small position pays a bigger percentage to get in.
         *
         * Held in the instrument's currency so it can be compared against the chart,
         * with the rate that applied at this fill stored alongside it. Deriving the
         * dollar basis from today's rate instead would rewrite what the parcel cost
         * every time the currency moved, and a ledger that edits its own past is
         * worse than one that is merely narrow. */
        let basisPerShare = ((notional + commission) * fx) / shares
        let lot = TaxLot(id: newId(), shares: shares, costPerShare: basisPerShare,
                         openedAt: nowMs(), fxPerUSD: fx)

        if let idx = state.positions.firstIndex(where: { $0.symbol == symbol }) {
            // Averaging in: the new average price is the blended cost, which is also the
            // moment most people quietly move their stop and stop having a plan.
            let totalShares = state.positions[idx].shares + shares
            state.positions[idx].avgPrice =
                (state.positions[idx].avgPrice * state.positions[idx].shares + basisPerShare * shares) / totalShares
            // The blended rate, weighted the same way the blended price is.
            state.positions[idx].fxAtOpen =
                (state.positions[idx].fxAtOpen * state.positions[idx].shares + fx * shares) / totalShares
            state.positions[idx].shares = totalShares
            state.positions[idx].lots.append(lot)
            if let target { state.positions[idx].target = target }
            if let stop { state.positions[idx].stop = stop }
            if let thesis, !thesis.isEmpty { state.positions[idx].thesis = thesis }
        } else {
            state.positions.append(Position(
                id: newId(), symbol: symbol, shares: shares, avgPrice: basisPerShare,
                openedAt: nowMs(), openedSession: MarketCalendar.sessionKey(Date(), for: symbol),
                target: target, stop: stop, thesis: thesis ?? "",
                plannedRisk: plannedRisk, lots: [lot],
                highWater: mark.price, lowWater: mark.price,
                fxAtOpen: fx
            ))
        }

        let trade = Trade(
            id: newId(), symbol: symbol, action: "buy", shares: shares,
            price: fill, quotedPrice: mark.price, value: notional, at: nowMs(),
            commission: commission, slippage: slip,
            pnl: nil, rMultiple: nil, taxDue: nil, gapped: false,
            reason: thesis ?? "Manual entry", trigger: nil, dayTrade: false
        )
        state.trades.insert(trade, at: 0)
        persist()
        return .ok(trade)
    }

    /**
     * `asOf` is what lets an exit be booked on the day it actually happened rather
     * than the day it was discovered. It is not cosmetic: the holding period decides
     * which tax rate the parcel pays, the session key decides whether the close
     * counts as a day trade against the PDT rule, and the calendar year decides
     * which year's liability the withholding lands in. Stamping a reconstructed exit
     * with `now` gets all three wrong, and gets them wrong in the flattering
     * direction — a loss taken in a closed window would otherwise arrive with a
     * longer hold, a lower rate, and no day-trade mark against it.
     */
    func sell(symbol: String, shares requested: Double? = nil, mark: MarkPrice,
              reason: String? = nil, trigger: String? = nil,
              fillOverride: Double? = nil, gapped: Bool = false,
              skipGate: Bool = false, asOf: Double? = nil,
              backfilled: Bool = false) -> OrderResult {
        let at = asOf ?? nowMs()
        let when = Date(timeIntervalSince1970: at / 1000)
        guard let idx = state.positions.firstIndex(where: { $0.symbol == symbol }) else {
            return .failed("No open position in \(symbol).")
        }
        let pos = state.positions[idx]
        let shares = Swift.min(requested ?? pos.shares, pos.shares)
        guard shares > 0, shares.isFinite else { return .failed("Share count must be positive.") }
        guard mark.price > 0 else { return .failed("No live price for that symbol.") }

        let isDayTrade = pos.openedSession == MarketCalendar.sessionKey(when, for: symbol)
        if !skipGate, isDayTrade,
           let blocked = PDT.blocks(symbol: symbol, equity: value([:]).equity,
                                    records: state.dayTrades, frictions: profile.frictions) {
            return .failed(blocked)
        }

        // A bracket fill has already been decided by where the market opened; a
        // discretionary sell crosses the spread like any other.
        let raw = fillOverride ?? mark.price
        let fill = fillOverride != nil ? raw : profile.frictions.sellFill(raw, atr: mark.atr)
        // Prices are native; from the proceeds down, everything is dollars.
        let fx = mark.safeFX
        let slip = fillOverride != nil ? 0 : ((raw - fill) * shares) / fx

        let grossProceeds = (shares * fill) / fx
        let commission = profile.frictions.commission(notional: grossProceeds)
        let netProceeds = grossProceeds - commission

        // Match parcels oldest first and realise each one separately, because the
        // tax rate depends on how long that particular parcel was held.
        var remaining = shares
        var costBasis = 0.0
        var taxDue = 0.0
        var weightedHoldDays = 0.0
        var lots = pos.lots
        var consumed: [(shares: Double, basis: Double, held: Double)] = []

        while remaining > 1e-12, !lots.isEmpty {
            var lot = lots[0]
            let take = Swift.min(remaining, lot.shares)
            let held = MarketCalendar.calendarDays(from: lot.openedAt, to: at)
            // The dollar basis this parcel was actually bought at, using the rate
            // that applied on the day rather than today's.
            let basis = lot.costPerShareUSD * take
            consumed.append((take, basis, held))
            costBasis += basis
            weightedHoldDays += held * take
            remaining -= take
            lot.shares -= take
            if lot.shares <= 1e-12 { lots.removeFirst() } else { lots[0] = lot }
        }

        /* Shares with no parcel behind them.
         *
         * A ledger written before tax lots existed has positions with `shares` and
         * an `avgPrice` and an empty `lots` array, and the loop above matches none
         * of them. Left there, `costBasis` stays at zero and the sale books the
         * entire proceeds as profit — a 100-share position bought at $150 and sold
         * at $160 reported $16,000 of gain instead of $1,000, then withheld tax on
         * it. The position's own blended cost is the honest fallback: it is what
         * the ledger actually knows, and a basis derived from it is right to the
         * precision the file carries rather than wrong by the whole notional.
         *
         * Dated to the position's open, which is the only holding period on
         * record, so the parcel still lands in the correct tax band. */
        if remaining > 1e-12 {
            let basis = pos.avgPriceUSD * remaining
            let held = MarketCalendar.calendarDays(from: pos.openedAt, to: at)
            consumed.append((remaining, basis, held))
            costBasis += basis
            weightedHoldDays += held * remaining
            log("[ledger] \(symbol): \(f(remaining, 4)) share(s) had no tax lot; "
                + "basis taken from the position's blended cost instead", .warn, "ledger")
            remaining = 0
        }

        // Commission on the way out reduces the proceeds attributed to each parcel.
        let proceedsPerShare = netProceeds / shares
        for parcel in consumed {
            let parcelProceeds = proceedsPerShare * parcel.shares
            let gain = parcelProceeds - parcel.basis
            let longTerm = parcel.held >= profile.frictions.longTermHoldingDays
            let rate = longTerm ? profile.frictions.longTermTaxPct : profile.frictions.shortTermTaxPct
            state.realizedGains.insert(RealizedGain(
                at: at, symbol: symbol, shares: parcel.shares,
                proceeds: parcelProceeds, costBasis: parcel.basis, gain: gain,
                holdingDays: parcel.held, longTerm: longTerm,
                taxDue: Swift.max(0, gain) * (rate / 100)
            ), at: 0)
        }

        /* What is actually withheld is the change in the year's liability, not the
         * tax on this sale in isolation. Losses offset gains inside a tax year, so
         * a losing trade after a winning one claws back part of what the winner
         * paid — and `taxDue` on this trade can legitimately be negative. Charging
         * every gain gross and never refunding would overstate the cost of trading
         * by exactly the amount of every loss taken afterwards. */
        taxDue = withholdTax(asOf: when)

        let pnl = netProceeds - costBasis
        // R multiple: profit measured in units of the risk originally accepted. The
        // only P/L number that compares a Walmart trade to a Solana trade fairly.
        var rMultiple: Double?
        if let stop = pos.stop, pos.avgPrice - stop > 0 {
            rMultiple = (fill - pos.avgPrice) / (pos.avgPrice - stop)
        }

        // Tax is withheld at the moment of realisation. Real accounts settle it in
        // April, but leaving it in the balance would let the desk compound money it
        // does not own, which is the single most flattering error a simulator makes.
        state.cash += netProceeds - taxDue
        state.totalCommission += commission
        state.totalSlippage += slip

        state.positions[idx].shares -= shares
        state.positions[idx].lots = lots
        if state.positions[idx].shares <= 1e-9 {
            state.positions.removeAll { $0.id == pos.id }
        }

        if isDayTrade {
            state.dayTrades.insert(DayTradeRecord(symbol: symbol, at: at,
                                                  session: MarketCalendar.sessionKey(when, for: symbol)), at: 0)
            state.dayTrades = Array(state.dayTrades.prefix(60))
        }

        let trade = Trade(
            id: newId(), symbol: symbol, action: "sell", shares: shares,
            price: fill, quotedPrice: mark.price, value: grossProceeds, at: at,
            commission: commission, slippage: slip,
            pnl: pnl, rMultiple: rMultiple, taxDue: taxDue, gapped: gapped,
            reason: reason ?? "Manual exit", trigger: trigger ?? "manual",
            dayTrade: isDayTrade, backfilled: backfilled
        )
        state.trades.insert(trade, at: 0)
        persist()
        return .ok(trade)
    }

    /**
     * Reconciles the year's tax position and returns what this sale actually
     * withheld — negative when a loss has clawed back an earlier payment.
     *
     * Short- and long-term gains are netted within their own category first, which
     * is how the rules work and why holding one winner past the threshold can be
     * worth more than it looks: it moves that gain into a pool taxed at the lower
     * rate rather than into the one soaking up short-term losses.
     */
    private func withholdTax(asOf: Date = Date()) -> Double {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: asOf)
        let key = String(year)
        let thisYear = state.realizedGains.filter {
            cal.component(.year, from: Date(timeIntervalSince1970: $0.at / 1000)) == year
        }
        let short = thisYear.filter { !$0.longTerm }.reduce(0) { $0 + $1.gain }
        let long = thisYear.filter(\.longTerm).reduce(0) { $0 + $1.gain }
        let owed = Swift.max(0, short) * (profile.frictions.shortTermTaxPct / 100)
                 + Swift.max(0, long) * (profile.frictions.longTermTaxPct / 100)

        let alreadyHeld = state.taxWithheldByYear[key] ?? 0
        let delta = owed - alreadyHeld
        state.taxWithheldByYear[key] = owed
        state.totalTax = state.taxWithheldByYear.values.reduce(0, +)
        return delta
    }

    func setBracket(symbol: String, target: Double?, stop: Double?) -> Bool {
        guard let idx = state.positions.firstIndex(where: { $0.symbol == symbol }) else { return false }
        state.positions[idx].target = target
        state.positions[idx].stop = stop
        persist()
        return true
    }

    /**
     * Walk open brackets against the session and close anything that was touched.
     *
     * Two rules that most simulators get wrong, and that cost real money:
     *
     * A stop is an instruction to sell at the market once a price trades, not a
     * promise of that price. When the session *opened* through the level, the fill
     * is the open — which on a gap down is materially worse than the stop, and is
     * exactly the scenario that turns a planned 1R loss into a 3R one. The same
     * applies in your favour on an upward gap through a target.
     *
     * And when both legs sit inside one bar, the stop is assumed to have filled
     * first, because assuming the good outcome is how backtests lie.
     */
    /**
     * Which leg fired, where it filled, and whether the session gapped through it.
     *
     * Pulled out of the live sweep so the reconciliation pass cannot drift from it.
     * Two engines deciding what a stop does — one for prices seen live, one for
     * prices seen late — is how a ledger ends up with two standards of evidence and
     * no way to tell which one a given trade was judged under.
     */
    struct BracketDecision {
        let useStop: Bool
        let level: Double
        let fill: Double
        let gapped: Bool
    }

    /// Nil when the bar never touched either level.
    static func decideBracket(stop: Double?, target: Double?,
                              high: Double, low: Double, open: Double?) -> BracketDecision? {
        let stopHit = stop != nil && low <= stop!
        let targetHit = target != nil && high >= target!
        guard stopHit || targetHit else { return nil }

        let useStop = stopHit // pessimistic when both legs are inside one bar
        let level = useStop ? stop! : target!

        // Did the session open through the level? Then that is the fill.
        var fill = level
        var gapped = false
        if let open {
            if useStop && open < level { fill = open; gapped = true }
            if !useStop && open > level { fill = open; gapped = true }
        }
        return BracketDecision(useStop: useStop, level: level, fill: fill, gapped: gapped)
    }

    /**
     * The sentence a fired bracket writes into the record.
     *
     * The levels are quoted in the instrument's own currency and the shortfall in
     * dollars, which is the split the whole ledger runs on: a stop is a level on an
     * exchange, and what it cost you is money in the account.
     */
    func bracketReason(_ d: BracketDecision, position pos: Position, backfilled: Bool) -> String {
        let rate = pos.fxAtOpen.isFinite && pos.fxAtOpen > 0 ? pos.fxAtOpen : 1
        let planned = pos.stop.map { ((pos.avgPrice - $0) * pos.shares) / rate }
        let actual = ((pos.avgPrice - d.fill) * pos.shares) / rate
        let level = quoted(d.level, pos.symbol)
        let fill = quoted(d.fill, pos.symbol)
        let base: String
        if d.useStop && d.gapped {
            let extra = planned.map { Swift.max(0, actual - $0) } ?? 0
            base = "Stop at \(level) gapped through: the session opened at \(fill) and filled there, \(money(extra)) worse than the plan. A stop is an instruction to sell once a price trades, not a guarantee of that price."
        } else if d.useStop {
            base = "Stop at \(fill) was touched. The plan set this level as the point the idea was wrong, so the position closed there."
        } else if d.gapped {
            base = "Target at \(level) gapped through and filled at \(fill), better than the plan. Gaps run in both directions."
        } else {
            base = "Target at \(fill) was reached and the plan\u{2019}s exit fired."
        }
        guard backfilled else { return base }
        return base + " Reconstructed from the daily bar for that session — Paper was not running when this level was reached, so the exit is dated to the day it happened rather than the day it was found."
    }

    /**
     * Walk open brackets against the session and close anything that was touched.
     *
     * Two rules that most simulators get wrong, and that cost real money:
     *
     * A stop is an instruction to sell at the market once a price trades, not a
     * promise of that price. When the session *opened* through the level, the fill
     * is the open — which on a gap down is materially worse than the stop, and is
     * exactly the scenario that turns a planned 1R loss into a 3R one. The same
     * applies in your favour on an upward gap through a target.
     *
     * And when both legs sit inside one bar, the stop is assumed to have filled
     * first, because assuming the good outcome is how backtests lie.
     *
     * This is the *live* sweep, and it only ever sees the session in front of it.
     * Everything that happened while the app was shut is `Reconcile`'s job.
     */
    @discardableResult
    func sweepBrackets(_ data: [String: MarkPrice]) -> [Trade] {
        var fired: [Trade] = []

        // Keep the running high and low first, so the review later knows how much
        // heat a position took before it resolved.
        for i in state.positions.indices {
            guard let q = data[state.positions[i].symbol] else { continue }
            state.positions[i].highWater = Swift.max(state.positions[i].highWater, q.dayHigh ?? q.price)
            state.positions[i].lowWater = Swift.min(state.positions[i].lowWater, q.dayLow ?? q.price)
        }

        for pos in state.positions {
            guard let q = data[pos.symbol] else { continue }
            guard let decision = Portfolio.decideBracket(
                stop: pos.stop, target: pos.target,
                high: q.dayHigh ?? q.price, low: q.dayLow ?? q.price, open: q.dayOpen
            ) else { continue }

            // Brackets fire regardless of the session gate: at a real broker the
            // order is already resting with the exchange.
            if case .ok(let trade) = sell(symbol: pos.symbol, mark: q,
                                          reason: bracketReason(decision, position: pos, backfilled: false),
                                          trigger: decision.useStop ? "stop" : "target",
                                          fillOverride: decision.fill, gapped: decision.gapped,
                                          skipGate: true) {
                fired.append(trade)
            }
        }
        return fired
    }

    /* --------------------------------------------------- reconciliation seams */

    /**
     * Restate a held position for a share split.
     *
     * The feed serves split-adjusted history the moment a split happens: the bars
     * for a $1,200 stock that went 10:1 come back as $120 all the way back. The
     * ledger, meanwhile, still has the position at $1,200 with a stop at $1,100.
     * Replaying one against the other closes the position at the first bar, at a
     * catastrophic loss, on a price move that never happened. So the position is
     * restated first — shares up, every per-share number down — and the sweep runs
     * against numbers that are denominated the same way as the bars.
     *
     * Idempotent by split identity, because two launches must not restate twice.
     *
     * And never applied to a position that was opened *after* the split. The feed
     * serves a year of corporate actions with every chart, so a split from eight
     * months ago arrives alongside a position opened last week — whose entry, stop
     * and target were already quoted in post-split money, because that is what the
     * market was showing when the order went in. Restating it divides a price that
     * had already been divided: a 10:1 split turned a $100 entry with a $90 stop
     * into a $10 entry with a $9 stop, and the next sweep closed the position at a
     * catastrophic loss on a move that never happened. The split is real; it is
     * just not this position's.
     */
    @discardableResult
    func applySplit(symbol: String, ratio: Double, at: Double, label: String) -> Bool {
        let key = "\(symbol)@\(Int(at))"
        guard ratio > 0, ratio != 1, !state.appliedSplits.contains(key),
              let idx = state.positions.firstIndex(where: { $0.symbol == symbol })
        else { return false }

        /* The position has to predate the split to be affected by it. Compared
         * against the oldest parcel rather than `openedAt`, because averaging in
         * across a split is a real sequence: the parcels bought before it need
         * restating and the ones bought after do not, and the position as a whole
         * is only untouched when every parcel is younger than the split.
         *
         * Not recorded in `appliedSplits`. Nothing was restated, so claiming
         * otherwise would leave a lie in the file — and the replay asks about the
         * same split on every session it walks, so this returns quietly rather
         * than narrating a non-event once per day. */
        let oldestParcel = state.positions[idx].lots.map(\.openedAt).min()
            ?? state.positions[idx].openedAt
        guard oldestParcel < at else { return false }

        state.positions[idx].shares *= ratio
        state.positions[idx].avgPrice /= ratio
        state.positions[idx].target = state.positions[idx].target.map { $0 / ratio }
        state.positions[idx].stop = state.positions[idx].stop.map { $0 / ratio }
        state.positions[idx].highWater /= ratio
        state.positions[idx].lowWater /= ratio
        // plannedRisk is denominated in dollars, not per share, so a split leaves it alone.
        for i in state.positions[idx].lots.indices {
            state.positions[idx].lots[i].shares *= ratio
            state.positions[idx].lots[i].costPerShare /= ratio
        }
        state.appliedSplits.append(key)
        persist()
        log("[reconcile] \(symbol) restated for a \(label) split: entry and bracket divided by \(f(ratio, 2))")
        return true
    }

    /// Extend a position's excursion marks across bars nobody was watching, so the
    /// review's MAE/MFE is not quietly flattered by the days the app was shut.
    func recordWater(symbol: String, high: Double, low: Double) {
        guard let i = state.positions.firstIndex(where: { $0.symbol == symbol }) else { return }
        state.positions[i].highWater = Swift.max(state.positions[i].highWater, high)
        state.positions[i].lowWater = Swift.min(state.positions[i].lowWater, low)
    }

    /// How far the sweep has been carried. Everything after it is unexamined market.
    func markSwept(_ at: Double) {
        state.lastSweptAt = Swift.max(state.lastSweptAt, at)
        persist()
    }

    /// An equity point dated to a past session, for redrawing a curve across a gap.
    /// Unlike `snapshot` this does not throttle — the whole point is one point per
    /// missed session, so a week the account was shut for draws its real shape
    /// instead of a straight line between the last two times anyone looked.
    func backfillEquityPoint(at: Double, equity: Double, cash: Double, invested: Double) {
        guard !state.equityCurve.contains(where: { abs($0.t - at) < 60_000 }) else { return }
        let point = EquityPoint(t: at, equity: equity, cash: cash,
                                invested: invested, contributed: state.totalContributed)
        let idx = state.equityCurve.firstIndex { $0.t > at } ?? state.equityCurve.count
        state.equityCurve.insert(point, at: idx)
    }

    /* ------------------------------------------------------------ test seams */

    /* The replay's whole job is to get dates right, and a date-sensitive rule —
     * the long-term holding threshold, the day-trade session, the tax year — cannot
     * be tested without a position that is genuinely old. These two exist so the
     * self-test can age a ledger rather than wait a year for one. Nothing in the
     * app calls them. */

    /// Move a position and its parcels back in time.
    func backdateForTesting(symbol: String, openedAt: Double) {
        guard let i = state.positions.firstIndex(where: { $0.symbol == symbol }) else { return }
        state.positions[i].openedAt = openedAt
        state.positions[i].openedSession = MarketCalendar.sessionKey(
            Date(timeIntervalSince1970: openedAt / 1000), for: symbol)
        for j in state.positions[i].lots.indices {
            state.positions[i].lots[j].openedAt = openedAt
        }
        persist()
    }

    /// Pretend the last contribution was paid in a given month.
    func rewindContributionMonthForTesting(to date: Date) {
        state.lastContributionMonth = Portfolio.monthKey(date)
        persist()
    }

    /// One equity point per hour at most — enough to draw a curve, not a log file.
    func snapshot(equity: Double, cash: Double, invested: Double) {
        if let last = state.equityCurve.last, nowMs() - last.t < 60 * 60_000 {
            let i = state.equityCurve.count - 1
            state.equityCurve[i].equity = equity
            state.equityCurve[i].cash = cash
            state.equityCurve[i].invested = invested
            state.equityCurve[i].contributed = state.totalContributed
            state.equityCurve[i].t = nowMs()
        } else {
            state.equityCurve.append(EquityPoint(t: nowMs(), equity: equity, cash: cash,
                                                 invested: invested, contributed: state.totalContributed))
        }
        if state.equityCurve.count > 5000 {
            state.equityCurve = Array(state.equityCurve.suffix(5000))
        }
        persist()
    }

    /* ------------------------------------------------------------- scorecard */

    func scorecard() -> Scorecard {
        let closed = state.trades.filter { $0.action == "sell" && $0.pnl != nil }
        let wins = closed.filter { $0.pnl! > 0 }
        let losses = closed.filter { $0.pnl! <= 0 }
        let grossWin = wins.reduce(0.0) { $0 + $1.pnl! }
        let grossLoss = abs(losses.reduce(0.0) { $0 + $1.pnl! })
        let rs = closed.compactMap(\.rMultiple)

        let winRate: Double? = closed.isEmpty ? nil : (Double(wins.count) / Double(closed.count)) * 100
        // JSON has no infinity, so an unbroken run of winners reports "no reading yet"
        // rather than a number the front end would have to invent a meaning for.
        let profitFactor: Double? = grossLoss > 0 ? grossWin / grossLoss : nil
        let expectancyR: Double? = rs.isEmpty ? nil : rs.reduce(0, +) / Double(rs.count)

        let netPnl = closed.reduce(0.0) { $0 + $1.pnl! }
        let costs = state.totalCommission + state.totalSlippage + state.totalTax

        var verdict = "No closed trades yet. The scorecard fills in once a position is exited."
        if closed.count > 0 && closed.count < 5 {
            verdict = "\(closed.count) closed trade\(closed.count == 1 ? "" : "s"), too few to read anything into. An edge shows up over dozens of trades."
        } else if let e = expectancyR {
            if netPnl <= 0 && netPnl + costs > 0 {
                verdict = "Before costs this method made money; after spread, commission and tax it did not. The gap grows with the number of trades."
            } else if e > 0.2 && (winRate ?? 0) < 50 {
                verdict = "Positive expectancy on a sub-50% win rate: more trades lose than win, and the winners are large enough to cover them."
            } else if e > 0.2 {
                verdict = "Expectancy of \(f(e, 2))R per trade. The exits are working; the size rules that produced it are worth keeping."
            } else if e < -0.2 && (winRate ?? 0) > 50 {
                verdict = "Winning most trades and still down: the losers are larger than the winners. Profits are being cut early while losses run."
            } else {
                verdict = "Expectancy of \(f(e, 2))R, roughly break-even before costs. The setup selection rather than the sizing is what needs work."
            }
        }

        let byPnl = closed.sorted { $0.pnl! > $1.pnl! }
        return Scorecard(
            closedTrades: closed.count,
            wins: wins.count,
            losses: losses.count,
            winRate: winRate,
            avgWin: wins.isEmpty ? nil : grossWin / Double(wins.count),
            avgLoss: losses.isEmpty ? nil : -grossLoss / Double(losses.count),
            profitFactor: profitFactor,
            expectancyR: expectancyR,
            bestTrade: byPnl.first,
            worstTrade: byPnl.last,
            stoppedOut: closed.filter { $0.trigger == "stop" }.count,
            targetsHit: closed.filter { $0.trigger == "target" }.count,
            manualExits: closed.filter { $0.trigger == "manual" }.count,
            gappedExits: closed.filter(\.gapped).count,
            backfilledExits: closed.filter(\.backfilled).count,
            dayTrades: closed.filter(\.dayTrade).count,
            totalCommission: state.totalCommission,
            totalSlippage: state.totalSlippage,
            totalTax: state.totalTax,
            pnlBeforeCosts: closed.isEmpty ? nil : netPnl + costs,
            verdict: verdict
        )
    }

    func taxSummary() -> TaxSummary {
        Tax.summarise(state.realizedGains, profile.frictions,
                      year: Calendar(identifier: .gregorian).component(.year, from: Date()))
    }

    @discardableResult
    func reset() -> PortfolioState {
        state = Portfolio.empty(profile)
        persist()
        return state
    }

    /// Applied when the profile's capital or costs change under an existing ledger.
    func adoptProfile(_ updated: Profile) {
        profile = updated
        persist()
    }
}
