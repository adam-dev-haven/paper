/**
 * Frictions.swift — the four ways a paper account flatters you, made to stop.
 *
 * The README has always been honest that a simulator lies in specific ways: fills
 * happen at the price you asked for, stops never gap through, costs do not exist,
 * and the taxman never calls. Each of those makes simulated results better than
 * real ones for the same person running the same system, and the gap is widest
 * for exactly the style — fast, frequent trading — that looks best on paper.
 *
 * So this file models them:
 *
 *   Spread and slippage — you buy at the ask and sell at the bid, and the
 *     distance between them scales with the instrument's own volatility.
 *   Commission — flat, per-share or percentage, whichever the venue charges.
 *   Gaps — a stop is an instruction, not a guarantee. When a session opens below
 *     it, the fill is the open, and the loss is bigger than the plan said.
 *   Market hours — equities trade for six and a half hours a day. Crypto does not
 *     close, which is a feature until it is 3am and you are still watching.
 *   The pattern day trader rule — under $25,000, a US margin account gets three
 *     day trades in five business days. It exists precisely because of the style
 *     that most wants to ignore it.
 *   Tax — short-term gains are taxed harder than long-term ones, which is a real
 *     and large cost of trading frequently, and one no backtest ever shows you.
 */

import Foundation

struct Frictions: Codable {
    /// Flat charge per executed order.
    var commissionPerTrade: Double
    /// Percentage of notional — how crypto venues and most non-US brokers charge.
    var commissionPctOfValue: Double
    var minCommission: Double
    /// Half-spread plus slippage, as a fraction of the instrument's ATR. Real
    /// spreads scale with volatility far better than they scale with price.
    var slippageAtrFraction: Double
    /// Floor for instruments with no ATR available, as a fraction of price.
    var minSlippagePctOfPrice: Double
    var enforceMarketHours: Bool
    var enforcePDT: Bool
    var shortTermTaxPct: Double
    var longTermTaxPct: Double
    var longTermHoldingDays: Double

    init(commissionPerTrade: Double, commissionPctOfValue: Double, minCommission: Double,
         slippageAtrFraction: Double, minSlippagePctOfPrice: Double,
         enforceMarketHours: Bool, enforcePDT: Bool,
         shortTermTaxPct: Double, longTermTaxPct: Double, longTermHoldingDays: Double) {
        self.commissionPerTrade = commissionPerTrade
        self.commissionPctOfValue = commissionPctOfValue
        self.minCommission = minCommission
        self.slippageAtrFraction = slippageAtrFraction
        self.minSlippagePctOfPrice = minSlippagePctOfPrice
        self.enforceMarketHours = enforceMarketHours
        self.enforcePDT = enforcePDT
        self.shortTermTaxPct = shortTermTaxPct
        self.longTermTaxPct = longTermTaxPct
        self.longTermHoldingDays = longTermHoldingDays
    }

    /**
     * Decoded by hand, and this one is load-bearing for a file the ledger rule
     * never covered.
     *
     * `Frictions` sits inside `Profile`, which sits inside `profiles.json`. With
     * the synthesised decoder, adding one cost setting made every existing
     * `Profile` fail to decode, which made `profiles.json` fail to decode, which
     * sent `Desk.openLedgers` down its first-run branch — writing the five presets
     * over the principal's own accounts. The ledgers survive that, but they are
     * keyed by profile id and the new presets have new ids, so every account
     * becomes an orphaned file nothing in the app can reach. Same failure as
     * 2026-09-13, one directory over.
     *
     * Every field defaults to the retail-broker preset, because a cost model with
     * a plausible value is a far smaller error than a profile that no longer
     * exists.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Frictions.retailBroker
        commissionPerTrade = try c.decodeIfPresent(Double.self, forKey: .commissionPerTrade) ?? d.commissionPerTrade
        commissionPctOfValue = try c.decodeIfPresent(Double.self, forKey: .commissionPctOfValue) ?? d.commissionPctOfValue
        minCommission = try c.decodeIfPresent(Double.self, forKey: .minCommission) ?? d.minCommission
        slippageAtrFraction = try c.decodeIfPresent(Double.self, forKey: .slippageAtrFraction) ?? d.slippageAtrFraction
        minSlippagePctOfPrice = try c.decodeIfPresent(Double.self, forKey: .minSlippagePctOfPrice) ?? d.minSlippagePctOfPrice
        enforceMarketHours = try c.decodeIfPresent(Bool.self, forKey: .enforceMarketHours) ?? d.enforceMarketHours
        enforcePDT = try c.decodeIfPresent(Bool.self, forKey: .enforcePDT) ?? d.enforcePDT
        shortTermTaxPct = try c.decodeIfPresent(Double.self, forKey: .shortTermTaxPct) ?? d.shortTermTaxPct
        longTermTaxPct = try c.decodeIfPresent(Double.self, forKey: .longTermTaxPct) ?? d.longTermTaxPct
        longTermHoldingDays = try c.decodeIfPresent(Double.self, forKey: .longTermHoldingDays) ?? d.longTermHoldingDays
    }

    var brief: String {
        var parts: [String] = []
        if commissionPerTrade > 0 { parts.append("$\(f(commissionPerTrade, 2)) per order") }
        if commissionPctOfValue > 0 { parts.append("\(f(commissionPctOfValue, 2))% of notional") }
        if parts.isEmpty { parts.append("commission-free") }
        parts.append("slippage \(f(slippageAtrFraction, 2)) x ATR each way")
        parts.append("tax \(f(shortTermTaxPct, 0))% short-term / \(f(longTermTaxPct, 0))% long-term")
        if enforceMarketHours { parts.append("equity orders only during the session") }
        if enforcePDT { parts.append("pattern-day-trader rule enforced under $25,000") }
        return parts.joined(separator: ", ") + "."
    }

    /// A commission-free US retail broker. Free is not free: the spread is wider
    /// than an institution's, which is where the money actually goes.
    static let retailBroker = Frictions(
        commissionPerTrade: 0, commissionPctOfValue: 0, minCommission: 0,
        slippageAtrFraction: 0.05, minSlippagePctOfPrice: 0.02,
        enforceMarketHours: true, enforcePDT: true,
        shortTermTaxPct: 32, longTermTaxPct: 15, longTermHoldingDays: 365
    )

    /// Direct-access routing: a real per-order charge, a tighter spread. The trade
    /// that makes sense only if you are trading enough for the spread to matter.
    static let activeTrader = Frictions(
        commissionPerTrade: 1.0, commissionPctOfValue: 0, minCommission: 1.0,
        slippageAtrFraction: 0.03, minSlippagePctOfPrice: 0.01,
        enforceMarketHours: true, enforcePDT: true,
        shortTermTaxPct: 32, longTermTaxPct: 15, longTermHoldingDays: 365
    )

    /// Crypto venues charge a percentage and never close.
    static let cryptoExchange = Frictions(
        commissionPerTrade: 0, commissionPctOfValue: 0.25, minCommission: 0,
        slippageAtrFraction: 0.06, minSlippagePctOfPrice: 0.04,
        enforceMarketHours: false, enforcePDT: false,
        shortTermTaxPct: 32, longTermTaxPct: 15, longTermHoldingDays: 365
    )

    /// Someone who trades a handful of times a year and holds through the
    /// long-term threshold, which is where the tax difference actually lands.
    static let longTermInvestor = Frictions(
        commissionPerTrade: 0, commissionPctOfValue: 0, minCommission: 0,
        slippageAtrFraction: 0.04, minSlippagePctOfPrice: 0.02,
        enforceMarketHours: true, enforcePDT: false,
        shortTermTaxPct: 32, longTermTaxPct: 15, longTermHoldingDays: 365
    )

    /**
     * A Swedish retail broker on an ordinary taxable account (a *depå*).
     *
     * Percentage courtage with a floor, which is what Avanza and Nordnet charge and
     * why small Swedish orders are disproportionately expensive. No PDT rule —
     * that is a US regulation and does not reach Nasdaq Stockholm. And a flat 30%
     * on realised capital gains regardless of holding period, which is the part
     * worth noticing: the US long-term rate rewards patience through the tax code,
     * Sweden does not, so the case for holding has to be made on the trade itself.
     *
     * An ISK is taxed differently again — a standing levy on the whole balance
     * rather than on gains — and is not modelled here, because a yearly charge on
     * capital is a different mechanism from a charge on profit and folding it into
     * this table would misrepresent both.
     */
    static let swedishBroker = Frictions(
        commissionPerTrade: 0, commissionPctOfValue: 0.25, minCommission: 1,
        slippageAtrFraction: 0.05, minSlippagePctOfPrice: 0.03,
        enforceMarketHours: true, enforcePDT: false,
        shortTermTaxPct: 30, longTermTaxPct: 30, longTermHoldingDays: 365
    )

    /// Frictionless, for comparing against the honest version. Not offered as a
    /// preset — it exists so the app can show what the costs were worth.
    static let none = Frictions(
        commissionPerTrade: 0, commissionPctOfValue: 0, minCommission: 0,
        slippageAtrFraction: 0, minSlippagePctOfPrice: 0,
        enforceMarketHours: false, enforcePDT: false,
        shortTermTaxPct: 0, longTermTaxPct: 0, longTermHoldingDays: 365
    )

    /* ------------------------------------------------------------- charges */

    func commission(notional: Double) -> Double {
        let charged = commissionPerTrade + notional * (commissionPctOfValue / 100)
        return charged > 0 ? Swift.max(charged, minCommission) : 0
    }

    /// Half the spread, in price terms. Paid on the way in and again on the way out.
    func slippage(price: Double, atr: Double?) -> Double {
        let fromAtr = (atr ?? 0) * slippageAtrFraction
        let floor = price * (minSlippagePctOfPrice / 100)
        return Swift.max(fromAtr, floor)
    }

    /// You buy at the ask.
    func buyFill(_ price: Double, atr: Double?) -> Double { price + slippage(price: price, atr: atr) }

    /// You sell at the bid.
    func sellFill(_ price: Double, atr: Double?) -> Double {
        Swift.max(0.0001, price - slippage(price: price, atr: atr))
    }
}

/* ------------------------------------------------------- the market clock */

/**
 * Two exchanges, two clocks, two holiday calendars — and one place that knows it.
 *
 * Every function here takes a venue and defaults to `.us`, so a call site that has
 * not been told about Stockholm behaves exactly as it did before. The differences
 * that matter:
 *
 *   Hours      — New York trades 09:30–16:00 local; Stockholm 09:00–17:30 local.
 *                Six and a half hours apart, and they overlap for about two.
 *   Holidays   — barely related. Sweden closes for Epiphany, Easter Monday,
 *                Ascension Day, Midsummer Eve and four days around Christmas;
 *                the US closes for Thanksgiving, Juneteenth and Independence Day.
 *   Weekends   — the NYSE observes a holiday that falls on a Saturday on the
 *                Friday before and a Sunday one on the Monday after. Nasdaq
 *                Stockholm does not substitute: a holiday on a weekend is simply
 *                a weekend.
 *
 * The session key is venue-local on purpose. A Stockholm position opened at 16:00
 * Swedish time and closed at 17:00 is a day trade, and it is also two different
 * New York dates for part of the year. Counting it against a New York calendar
 * would get both the day-trade test and the holding period wrong.
 */
enum MarketCalendar {

    /// What is *not* modelled, stated rather than left to be discovered: occasional
    /// exchange-specific half sessions beyond the two below, and the pre- and
    /// post-market windows. Both are thin enough that pretending you would fill in
    /// them is its own lie.
    static func timeZone(_ venue: Venue) -> TimeZone {
        switch venue {
        case .us: return TimeZone(identifier: "America/New_York") ?? .gmt
        case .stockholm: return TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        case .crypto: return .gmt
        }
    }

    static func calendar(_ venue: Venue) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone(venue)
        return c
    }

    /// Open and close, in minutes past local midnight.
    static func hours(_ venue: Venue) -> (open: Int, close: Int) {
        switch venue {
        case .us: return (9 * 60 + 30, 16 * 60)
        // Continuous trading runs to 17:25 and the closing auction to 17:30. An
        // order placed at 17:27 does fill, in the auction, so the later time is the
        // honest boundary.
        case .stockholm: return (9 * 60, 17 * 60 + 30)
        case .crypto: return (0, 24 * 60)
        }
    }

    /// Easter Sunday by the anonymous Gregorian algorithm. Needed by both venues:
    /// Good Friday is the one US market holiday that moves, and half the Swedish
    /// calendar hangs off it.
    private static func easter(_ year: Int) -> DateComponents {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4, e = b % 4
        let g = (8 * b + 13) / 25
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 19 * l) / 433
        let month = (h + l - 7 * m + 90) / 25
        let day = (h + l - 7 * m + 33 * month + 19) % 32
        return DateComponents(year: year, month: month, day: day)
    }

    private static func easterDate(_ year: Int, _ cal: Calendar) -> Date? {
        var e = easter(year)
        e.calendar = cal
        return cal.date(from: e)
    }

    private static func nthWeekday(_ year: Int, _ month: Int, weekday: Int, n: Int, _ cal: Calendar) -> Date? {
        var comps = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n)
        comps.calendar = cal
        return cal.date(from: comps)
    }

    private static func lastWeekday(_ year: Int, _ month: Int, weekday: Int, _ cal: Calendar) -> Date? {
        var comps = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: -1)
        comps.calendar = cal
        return cal.date(from: comps)
    }

    /**
     * Holidays for a year, computed rather than listed so the app does not quietly
     * go wrong the moment a hardcoded table runs out.
     */
    static func holidays(_ year: Int, venue: Venue = .us) -> Set<DateComponents> {
        guard venue != .crypto else { return [] }
        let cal = calendar(venue)
        var days: [Date] = []

        /// A date-in-the-year, with the venue's rule for one that lands on a weekend.
        func fixed(_ month: Int, _ day: Int) {
            guard let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return }
            guard venue == .us else {
                // Nasdaq Stockholm does not substitute. A holiday on a Saturday is a
                // Saturday, and the surrounding weekdays are ordinary sessions.
                days.append(d)
                return
            }
            let weekday = cal.component(.weekday, from: d)
            if weekday == 7 { days.append(cal.date(byAdding: .day, value: -1, to: d) ?? d) }
            else if weekday == 1 { days.append(cal.date(byAdding: .day, value: 1, to: d) ?? d) }
            else { days.append(d) }
        }

        func fromEaster(_ offset: Int) {
            guard let e = easterDate(year, cal),
                  let d = cal.date(byAdding: .day, value: offset, to: e) else { return }
            days.append(d)
        }

        switch venue {
        case .us:
            fixed(1, 1)                                                     // New Year's Day
            fixed(6, 19)                                                    // Juneteenth
            fixed(7, 4)                                                     // Independence Day
            fixed(12, 25)                                                   // Christmas
            if let d = nthWeekday(year, 1, weekday: 2, n: 3, cal) { days.append(d) }   // MLK
            if let d = nthWeekday(year, 2, weekday: 2, n: 3, cal) { days.append(d) }   // Presidents
            if let d = lastWeekday(year, 5, weekday: 2, cal) { days.append(d) }        // Memorial
            if let d = nthWeekday(year, 9, weekday: 2, n: 1, cal) { days.append(d) }   // Labor
            if let d = nthWeekday(year, 11, weekday: 5, n: 4, cal) { days.append(d) }  // Thanksgiving
            fromEaster(-2)                                                  // Good Friday

        case .stockholm:
            fixed(1, 1)                                                     // Nyårsdagen
            fixed(1, 6)                                                     // Trettondedag jul
            fromEaster(-2)                                                  // Långfredagen
            fromEaster(1)                                                   // Annandag påsk
            fixed(5, 1)                                                     // Första maj
            fromEaster(39)                                                  // Kristi himmelsfärdsdag
            fixed(6, 6)                                                     // Sveriges nationaldag
            // Midsommarafton: the Friday that falls between the 19th and 25th of June.
            // It is not a public holiday in law and it is absolutely a closed exchange.
            for day in 19...25 {
                if let d = cal.date(from: DateComponents(year: year, month: 6, day: day)),
                   cal.component(.weekday, from: d) == 6 { days.append(d) }
            }
            fixed(12, 24)                                                   // Julafton
            fixed(12, 25)                                                   // Juldagen
            fixed(12, 26)                                                   // Annandag jul
            fixed(12, 31)                                                   // Nyårsafton

        case .crypto:
            break
        }

        return Set(days.map { cal.dateComponents([.year, .month, .day], from: $0) })
    }

    /**
     * Sessions that end early.
     *
     * Only the two that are reliable year after year are modelled: the US
     * half-session the day after Thanksgiving, and Stockholm's 13:00 close on
     * Maundy Thursday. Exchanges declare other short days occasionally and this
     * does not know about them, which means an order placed in the last hour of
     * one of those would be accepted here and queued in reality. Said out loud
     * rather than left as a surprise.
     */
    static func earlyClose(_ date: Date, venue: Venue = .us) -> Int? {
        guard venue != .crypto else { return nil }
        let cal = calendar(venue)
        let year = cal.component(.year, from: date)
        let key = cal.dateComponents([.year, .month, .day], from: date)

        switch venue {
        case .us:
            // The Friday after Thanksgiving: 13:00 New York.
            guard let thanksgiving = nthWeekday(year, 11, weekday: 5, n: 4, cal),
                  let friday = cal.date(byAdding: .day, value: 1, to: thanksgiving) else { return nil }
            return cal.dateComponents([.year, .month, .day], from: friday) == key ? 13 * 60 : nil
        case .stockholm:
            // Skärtorsdagen, the Thursday before Good Friday: 13:00 Stockholm.
            guard let e = easterDate(year, cal),
                  let maundy = cal.date(byAdding: .day, value: -3, to: e) else { return nil }
            return cal.dateComponents([.year, .month, .day], from: maundy) == key ? 13 * 60 : nil
        case .crypto:
            return nil
        }
    }

    static func isTradingDay(_ date: Date, venue: Venue = .us) -> Bool {
        guard venue != .crypto else { return true }
        let cal = calendar(venue)
        let weekday = cal.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return false }
        let key = cal.dateComponents([.year, .month, .day], from: date)
        return !holidays(cal.component(.year, from: date), venue: venue).contains(key)
    }

    /// The regular session. Pre- and post-market exist, but they are thin enough
    /// that pretending you would fill there is its own lie.
    static func isSessionOpen(_ date: Date = Date(), venue: Venue = .us) -> Bool {
        guard venue != .crypto else { return true }
        guard isTradingDay(date, venue: venue) else { return false }
        let cal = calendar(venue)
        let minutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let h = hours(venue)
        let close = earlyClose(date, venue: venue) ?? h.close
        return minutes >= h.open && minutes < close
    }

    /// Whether the market this *symbol* trades on is open. Crypto always is.
    static func isOpen(for symbol: String, at date: Date = Date()) -> Bool {
        isSessionOpen(date, venue: Universe.venue(of: symbol))
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private static func cityName(_ venue: Venue) -> String {
        venue == .stockholm ? "Stockholm" : "New York"
    }

    /// A short sentence for the interface — what one venue's clock is doing now.
    static func sessionNote(_ date: Date = Date(), venue: Venue = .us) -> String {
        guard venue != .crypto else { return "Crypto trades continuously. There is no close to wait for." }
        let market = venue.exchangeName
        let city = cityName(venue)
        let h = hours(venue)

        if isSessionOpen(date, venue: venue) {
            let close = earlyClose(date, venue: venue) ?? h.close
            let early = earlyClose(date, venue: venue) != nil ? " — a short session today" : ""
            return "\(market) open until \(hhmm(close)) \(city)\(early)."
        }
        if !isTradingDay(date, venue: venue) {
            let cal = calendar(venue)
            let weekday = cal.component(.weekday, from: date)
            return (weekday == 1 || weekday == 7)
                ? "\(market) closed for the weekend. Crypto trades through it."
                : "\(market) closed for a holiday. Crypto trades through it."
        }
        let cal = calendar(venue)
        let minutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return minutes < h.open
            ? "\(market) opens at \(hhmm(h.open)) \(city)."
            : "\(market) closed at \(hhmm(earlyClose(date, venue: venue) ?? h.close)) \(city)."
    }

    /// The same sentence for whichever venue a symbol trades on.
    static func sessionNote(for symbol: String, at date: Date = Date()) -> String {
        sessionNote(date, venue: Universe.venue(of: symbol))
    }

    /**
     * Every venue's clock in one line, because the board now holds instruments on
     * two exchanges and a reader looking at a Swedish name should not be told
     * about New York.
     */
    static func boardNote(_ date: Date = Date()) -> String {
        let parts = [Venue.us, .stockholm].map { venue -> String in
            let state = isSessionOpen(date, venue: venue) ? "open" : "closed"
            let h = hours(venue)
            let close = earlyClose(date, venue: venue) ?? h.close
            return isSessionOpen(date, venue: venue)
                ? "\(venue.exchangeName) open until \(hhmm(close)) \(cityName(venue))"
                : "\(venue.exchangeName) \(state)"
        }
        return parts.joined(separator: ". ") + ". Crypto trades through both."
    }

    /// The trading day a moment belongs to, in the venue's own local time. Used for
    /// counting day trades and for matching a fill to a bar.
    static func sessionKey(_ date: Date, venue: Venue = .us) -> String {
        let c = calendar(venue).dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func sessionKey(_ date: Date, for symbol: String) -> String {
        sessionKey(date, venue: Universe.venue(of: symbol))
    }

    /// Business days between two moments, which is the window the PDT rule uses.
    static func businessDays(from: Date, to: Date, venue: Venue = .us) -> Int {
        guard to > from else { return 0 }
        let cal = calendar(venue)
        var count = 0
        var cursor = cal.startOfDay(for: from)
        let end = cal.startOfDay(for: to)
        while cursor < end {
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? end
            if isTradingDay(cursor, venue: venue) { count += 1 }
        }
        return count
    }

    static func calendarDays(from: Double, to: Double) -> Double {
        (to - from) / 86_400_000
    }
}

/* ------------------------------------------------------------------ tax */

/**
 * One parcel of shares at one cost. Selling matches parcels oldest-first, which
 * is what decides whether a gain is taxed as short- or long-term.
 *
 * `costPerShare` is in the **instrument's own currency**, because that is the
 * currency the fill happened in and the one the chart is drawn in. `fxPerUSD` is
 * the rate that applied at that fill, so the dollar basis the tax is computed on
 * is the dollar basis that was actually paid — not today's rate applied to an old
 * kronor figure, which would quietly rewrite the parcel's cost every time the
 * krona moved. For a dollar-quoted instrument the rate is 1 and nothing changes.
 *
 * Decoded by hand: a synthesised decoder throws on a missing key, so adding
 * `fxPerUSD` with a synthesised one would make every ledger written before today
 * unreadable. See the note at the top of Portfolio.swift.
 */
struct TaxLot: Codable {
    var id: String
    var shares: Double
    /// Per share, in the instrument's currency, including the commission and
    /// slippage paid to acquire it.
    var costPerShare: Double
    var openedAt: Double
    /// Units of the instrument's currency per US dollar at the moment of the fill.
    /// 1 for anything quoted in dollars.
    var fxPerUSD: Double

    /// What this parcel cost, per share, in the currency the ledger settles in.
    var costPerShareUSD: Double {
        let rate = fxPerUSD.isFinite && fxPerUSD > 0 ? fxPerUSD : 1
        return costPerShare / rate
    }

    init(id: String, shares: Double, costPerShare: Double, openedAt: Double, fxPerUSD: Double = 1) {
        self.id = id
        self.shares = shares
        self.costPerShare = costPerShare
        self.openedAt = openedAt
        self.fxPerUSD = fxPerUSD
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        shares = try c.decode(Double.self, forKey: .shares)
        costPerShare = try c.decode(Double.self, forKey: .costPerShare)
        openedAt = try c.decodeIfPresent(Double.self, forKey: .openedAt) ?? nowMs()
        // A parcel written before Paper knew about foreign listings was, by
        // definition, a dollar parcel.
        fxPerUSD = try c.decodeIfPresent(Double.self, forKey: .fxPerUSD) ?? 1
    }
}

/// Decoded by hand, like everything else the ledger holds. See the note above
/// `Contribution` in Portfolio.swift: an array element that refuses to decode
/// takes the whole ledger down with it, whatever care the container took.
struct RealizedGain: Codable {
    var at: Double
    var symbol: String
    var shares: Double
    var proceeds: Double
    var costBasis: Double
    var gain: Double
    var holdingDays: Double
    var longTerm: Bool
    var taxDue: Double

    init(at: Double, symbol: String, shares: Double, proceeds: Double, costBasis: Double,
         gain: Double, holdingDays: Double, longTerm: Bool, taxDue: Double) {
        self.at = at; self.symbol = symbol; self.shares = shares
        self.proceeds = proceeds; self.costBasis = costBasis; self.gain = gain
        self.holdingDays = holdingDays; self.longTerm = longTerm; self.taxDue = taxDue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A realised gain with no instrument is not a realised gain.
        symbol = try c.decode(String.self, forKey: .symbol)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? nowMs()
        shares = try c.decodeIfPresent(Double.self, forKey: .shares) ?? 0
        proceeds = try c.decodeIfPresent(Double.self, forKey: .proceeds) ?? 0
        costBasis = try c.decodeIfPresent(Double.self, forKey: .costBasis) ?? 0
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? (proceeds - costBasis)
        holdingDays = try c.decodeIfPresent(Double.self, forKey: .holdingDays) ?? 0
        longTerm = try c.decodeIfPresent(Bool.self, forKey: .longTerm) ?? false
        taxDue = try c.decodeIfPresent(Double.self, forKey: .taxDue) ?? 0
    }
}

struct TaxSummary: Codable {
    let year: Int
    let shortTermGain: Double
    let longTermGain: Double
    let shortTermTax: Double
    let longTermTax: Double
    let totalTax: Double
    /// Tax as a share of gross realised profit — the number that makes the case
    /// for holding longer better than any lecture does.
    let effectiveRatePct: Double?
    let note: String
}

enum Tax {
    static func summarise(_ gains: [RealizedGain], _ frictions: Frictions, year: Int) -> TaxSummary {
        let cal = Calendar(identifier: .gregorian)
        let inYear = gains.filter { cal.component(.year, from: Date(timeIntervalSince1970: $0.at / 1000)) == year }
        let short = inYear.filter { !$0.longTerm }
        let long = inYear.filter { $0.longTerm }
        let shortGain = short.reduce(0) { $0 + $1.gain }
        let longGain = long.reduce(0) { $0 + $1.gain }
        let shortTax = Swift.max(0, shortGain) * (frictions.shortTermTaxPct / 100)
        let longTax = Swift.max(0, longGain) * (frictions.longTermTaxPct / 100)
        let grossProfit = Swift.max(0, shortGain) + Swift.max(0, longGain)
        let total = shortTax + longTax

        // Sweden taxes a realised gain at one flat rate however long it was held, so
        // every sentence below about what patience would have saved is false there.
        // Said plainly instead: the tax code is not the argument for holding on.
        let ratesDiffer = abs(frictions.shortTermTaxPct - frictions.longTermTaxPct) > 1e-9

        var note: String
        if inYear.isEmpty {
            note = "Nothing realised yet this year. Tax is owed on closed trades, not on unrealised gains."
        } else if !ratesDiffer {
            note = total > 0
                ? "Realised gains are taxed at a flat \(f(frictions.shortTermTaxPct, 0))% whatever the holding period, so this year's \(money(grossProfit)) of profit owes \(money(total)) regardless of how long each position was held. Holding longer saves trading costs here, not tax."
                : "No tax owed this year: realised losses offset the gains. The rate is flat at \(f(frictions.shortTermTaxPct, 0))% whatever the holding period."
        } else if shortGain > 0 && longGain <= 0 {
            note = "Every realised gain this year was short-term, taxed at \(f(frictions.shortTermTaxPct, 0))%. The same profit held past \(Int(frictions.longTermHoldingDays)) days would have been taxed at \(f(frictions.longTermTaxPct, 0))%, keeping \(money(shortGain * (frictions.shortTermTaxPct - frictions.longTermTaxPct) / 100)) more of it."
        } else if longGain > 0 && shortGain <= 0 {
            note = "All of this year's realised gain qualified for the long-term rate. Holding past \(Int(frictions.longTermHoldingDays)) days saved \(money(longGain * (frictions.shortTermTaxPct - frictions.longTermTaxPct) / 100)) against trading the same profit short-term."
        } else if total > 0 {
            note = "Tax is the cost of realising a gain, and frequent trading realises them continuously. Long-term gains held past the threshold are taxed at the lower rate."
        } else {
            note = "No tax owed this year: realised losses offset the gains, and anything an earlier winner had already paid has been refunded to the balance."
        }

        return TaxSummary(
            year: year,
            shortTermGain: shortGain, longTermGain: longGain,
            shortTermTax: shortTax, longTermTax: longTax, totalTax: total,
            effectiveRatePct: grossProfit > 0 ? (total / grossProfit) * 100 : nil,
            note: note
        )
    }
}

/* ------------------------------------------------- the pattern day trader */

struct DayTradeRecord: Codable {
    var symbol: String
    var at: Double
    var session: String

    init(symbol: String, at: Double, session: String) {
        self.symbol = symbol; self.at = at; self.session = session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? nowMs()
        session = try c.decodeIfPresent(String.self, forKey: .session)
            ?? MarketCalendar.sessionKey(Date(timeIntervalSince1970: at / 1000), for: symbol)
    }
}

enum PDT {
    static let equityThreshold: Double = 25_000
    static let allowance = 3

    /**
     * Day trades inside the rolling five-business-day window — counting only the
     * ones the rule actually reaches.
     *
     * The venue filter is the whole point and it was missing. `blocks` correctly
     * refused to apply the rule to a Bitcoin or a Stockholm round trip, then
     * counted those same round trips against the allowance for a US equity: three
     * BTC day trades in a week and the next AAPL exit was refused under a FINRA
     * regulation that does not govern either. The exemption has to hold on both
     * sides of the test or it is not an exemption, it is a discount.
     */
    static func recent(_ records: [DayTradeRecord], now: Date = Date()) -> [DayTradeRecord] {
        records
            .filter { Universe.venue(of: $0.symbol).subjectToPDT }
            .filter { MarketCalendar.businessDays(from: Date(timeIntervalSince1970: $0.at / 1000), to: now, venue: .us) < 5 }
    }

    /**
     * Nil when the trade is allowed, or the reason it is not.
     *
     * The rule is a US regulation applying to a US margin account, so it reaches US
     * equities and nothing else. Crypto is exempt because it is not a security under
     * it, and Stockholm is exempt because Nasdaq Stockholm is not FINRA's to
     * regulate — a Swedish account can round-trip a Swedish listing as often as it
     * likes, and the cost of doing so is the spread and the tax, not a frozen
     * account.
     */
    static func blocks(symbol: String, equity: Double, records: [DayTradeRecord], frictions: Frictions) -> String? {
        guard frictions.enforcePDT, Universe.venue(of: symbol).subjectToPDT else { return nil }
        guard equity < equityThreshold else { return nil }
        let used = recent(records).count
        guard used >= allowance else { return nil }
        return "Pattern day trader rule: this account is under $\(f(equityThreshold, 0)) and has made \(used) day trades in the last five business days. A fourth would freeze the account for ninety days at a real broker, so it is refused here. Hold this position overnight, or wait for the window to roll forward."
    }

    static func remaining(equity: Double, records: [DayTradeRecord], frictions: Frictions) -> Int? {
        guard frictions.enforcePDT, equity < equityThreshold else { return nil }
        return Swift.max(0, allowance - recent(records).count)
    }
}
