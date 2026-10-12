/**
 * Universe.swift — what Paper is allowed to look at.
 *
 * Everything here is a Yahoo Finance symbol, because using one quote source for
 * equities and crypto means one bar format, one timezone problem, one cache.
 *
 * Three venues, and the differences between them are load-bearing rather than
 * cosmetic:
 *
 *   US equities  — quoted in dollars, 09:30–16:00 New York, ~252 sessions a year,
 *                  and the only venue the pattern-day-trader rule applies to.
 *   Stockholm    — quoted in **kronor**, 09:00–17:30 Stockholm, its own holiday
 *                  calendar, and no PDT rule because it is not a US margin account.
 *   Crypto       — the `-USD` pairs, which trade seven days a week. A 20-day
 *                  average means something different when there are no weekends
 *                  in it, which the analysis layer has to know about.
 *
 * The currency on an instrument is the currency it is **quoted** in, and every
 * price this app computes for it — the moving averages, the ATR, the entry, the
 * stop, the target — is in that currency, because that is the currency an order
 * would carry. Money is a separate question: the ledger settles in dollars and
 * converts at the fill. Prices are native, money is dollars. See Portfolio.swift.
 */

import Foundation

enum AssetClass: String, Codable {
    case equity
    case crypto
}

/// Where an instrument trades, which decides its clock, its holidays, its
/// currency and whether US day-trading rules reach it.
enum Venue: String, Codable, CaseIterable {
    case us
    case stockholm
    case crypto

    var label: String {
        switch self {
        case .us: return "US"
        case .stockholm: return "Stockholm"
        case .crypto: return "Crypto"
        }
    }

    /// The exchange's own name, for the interface to say where a fill happened.
    var exchangeName: String {
        switch self {
        case .us: return "US equity market"
        case .stockholm: return "Nasdaq Stockholm"
        case .crypto: return "Crypto (24/7)"
        }
    }

    var currency: Currency {
        switch self {
        case .us, .crypto: return .usd
        case .stockholm: return .sek
        }
    }

    /// True where a clock applies at all.
    var hasSession: Bool { self != .crypto }

    /// Only a US margin account is subject to the pattern day trader rule.
    var subjectToPDT: Bool { self == .us }
}

struct Instrument: Codable {
    let symbol: String
    let name: String
    let klass: AssetClass
    let sector: String
    /// Rough note on why this is in the training universe at all.
    let note: String
    let venue: Venue
    /**
     * Instruments that are one bet wearing several tickers.
     *
     * Six AI semiconductor names in a shortlist is not six ideas, it is one idea
     * sized six times, and the difference only shows up on the day the idea is
     * wrong. Naming the complex lets the shortlist cap it before the money is
     * allocated rather than warning about it afterwards.
     */
    let complex: String?

    init(symbol: String, name: String, klass: AssetClass, sector: String, note: String,
         venue: Venue = .us, complex: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.klass = klass
        self.sector = sector
        self.note = note
        self.venue = venue
        self.complex = complex
    }

    /// What this instrument's prices are quoted in.
    var currency: Currency { venue.currency }
}

enum Universe {
    static let all: [Instrument] = usEquities + swedishEquities + cryptoPairs + benchmarkInstruments

    /* --------------------------------------------------------- US equities */

    static let usEquities: [Instrument] = [
        // ---- Mega-cap tech: the names every beginner already has an opinion about.
        .init(symbol: "AAPL",  name: "Apple",              klass: .equity, sector: "Technology",       note: "Mega-cap, low beta for tech, heavy buyback support.", complex: "megacap-tech"),
        .init(symbol: "MSFT",  name: "Microsoft",          klass: .equity, sector: "Technology",       note: "Cloud + AI capex cycle, steady compounder.", complex: "megacap-tech"),
        .init(symbol: "NVDA",  name: "NVIDIA",             klass: .equity, sector: "Semiconductors",   note: "The AI capex proxy. High beta, violent drawdowns.", complex: "ai-semis"),
        .init(symbol: "GOOGL", name: "Alphabet",           klass: .equity, sector: "Technology",       note: "Search moat vs AI disruption narrative.", complex: "megacap-tech"),
        .init(symbol: "AMZN",  name: "Amazon",             klass: .equity, sector: "Consumer",         note: "Retail margin story stapled to AWS.", complex: "megacap-tech"),
        .init(symbol: "META",  name: "Meta Platforms",     klass: .equity, sector: "Technology",       note: "Ad cycle sensitivity, capex swings sentiment.", complex: "megacap-tech"),
        .init(symbol: "TSLA",  name: "Tesla",              klass: .equity, sector: "Consumer",         note: "Highest-beta mega-cap. Narrative-driven, brutal for stops."),
        .init(symbol: "AMD",   name: "AMD",                klass: .equity, sector: "Semiconductors",   note: "Second-derivative AI trade, amplifies NVDA moves.", complex: "ai-semis"),
        .init(symbol: "AVGO",  name: "Broadcom",           klass: .equity, sector: "Semiconductors",   note: "Custom silicon + software, steadier than pure GPU.", complex: "ai-semis"),
        .init(symbol: "NFLX",  name: "Netflix",            klass: .equity, sector: "Communication",    note: "Subscription economics, gaps hard on earnings."),

        // ---- Non-tech, so the trainer is not one single correlated bet.
        .init(symbol: "JPM",   name: "JPMorgan Chase",     klass: .equity, sector: "Financials",       note: "Rate-sensitive. Teaches macro linkage.", complex: "us-banks"),
        .init(symbol: "XOM",   name: "Exxon Mobil",        klass: .equity, sector: "Energy",           note: "Commodity beta, often anti-correlated to tech.", complex: "us-energy"),
        .init(symbol: "UNH",   name: "UnitedHealth",       klass: .equity, sector: "Healthcare",       note: "Defensive until regulation headlines say otherwise."),
        .init(symbol: "WMT",   name: "Walmart",            klass: .equity, sector: "Consumer Staples", note: "Low-volatility defensive. A useful boring benchmark."),
        .init(symbol: "COST",  name: "Costco",             klass: .equity, sector: "Consumer Staples", note: "Premium multiple defensive. Punishes late entries."),
        .init(symbol: "LLY",   name: "Eli Lilly",          klass: .equity, sector: "Healthcare",       note: "Single-drug-cycle risk inside a defensive sector."),
        .init(symbol: "PLTR",  name: "Palantir",           klass: .equity, sector: "Technology",       note: "Retail-momentum name. Excellent stop-loss teacher."),
        .init(symbol: "COIN",  name: "Coinbase",           klass: .equity, sector: "Financials",       note: "Equity that trades like crypto beta.", complex: "crypto-beta"),
        .init(symbol: "MSTR",  name: "Strategy (MSTR)",    klass: .equity, sector: "Financials",       note: "Levered bitcoin proxy. Extreme volatility.", complex: "crypto-beta"),
        .init(symbol: "SMCI",  name: "Super Micro",        klass: .equity, sector: "Technology",       note: "Boom-bust case study in momentum unwinding.", complex: "ai-semis"),

        /* ---- The widening.
         *
         * Twenty-two fundable names and one fixed scoring formula is why the same
         * shortlist kept coming back: with a deterministic score over a narrow board,
         * yesterday's top twelve is today's top twelve. These add the two ends the
         * board was missing — genuine low-volatility compounders for a long-horizon
         * read, and genuinely fast instruments for a short one — plus the sectors
         * that behave differently from everything above. */
        .init(symbol: "CAT",   name: "Caterpillar",        klass: .equity, sector: "Industrials",      note: "Global construction cycle. Moves on China and rates, not on tech."),
        .init(symbol: "GE",    name: "GE Aerospace",       klass: .equity, sector: "Industrials",      note: "Post-breakup aerospace pure play. Long order book, slow revisions."),
        .init(symbol: "BA",    name: "Boeing",             klass: .equity, sector: "Industrials",      note: "Headline-driven turnaround. Trades on regulators, not earnings."),
        .init(symbol: "GS",    name: "Goldman Sachs",      klass: .equity, sector: "Financials",       note: "Capital markets cycle. Amplifies whatever rates do.", complex: "us-banks"),
        .init(symbol: "BAC",   name: "Bank of America",    klass: .equity, sector: "Financials",       note: "Deposit franchise, the most rate-sensitive of the big banks.", complex: "us-banks"),
        .init(symbol: "V",     name: "Visa",               klass: .equity, sector: "Financials",       note: "Toll booth on consumer spending. Unusually smooth trend."),
        .init(symbol: "CVX",   name: "Chevron",            klass: .equity, sector: "Energy",           note: "Integrated oil. Dividend support under the drawdowns.", complex: "us-energy"),
        .init(symbol: "OXY",   name: "Occidental",         klass: .equity, sector: "Energy",           note: "Higher-beta crude play. Moves roughly twice Chevron.", complex: "us-energy"),
        .init(symbol: "PFE",   name: "Pfizer",             klass: .equity, sector: "Healthcare",       note: "Patent-cliff pharma. Low multiple, slow base."),
        .init(symbol: "ABBV",  name: "AbbVie",             klass: .equity, sector: "Healthcare",       note: "Dividend pharma. Defensive with a real yield."),
        .init(symbol: "VRTX",  name: "Vertex",             klass: .equity, sector: "Healthcare",       note: "Monopoly franchise plus a binary pipeline."),
        .init(symbol: "MRNA",  name: "Moderna",            klass: .equity, sector: "Healthcare",       note: "Post-boom biotech. Trial results override every chart."),
        .init(symbol: "NEE",   name: "NextEra Energy",     klass: .equity, sector: "Utilities",        note: "Regulated utility with a renewables growth arm. Bond proxy.", complex: "us-utilities"),
        .init(symbol: "DUK",   name: "Duke Energy",        klass: .equity, sector: "Utilities",        note: "Pure regulated utility. About as slow as a US listing gets.", complex: "us-utilities"),
        .init(symbol: "O",     name: "Realty Income",      klass: .equity, sector: "Real Estate",      note: "Monthly-paying net-lease REIT. Trades on the 10-year.", complex: "us-reits"),
        .init(symbol: "PLD",   name: "Prologis",           klass: .equity, sector: "Real Estate",      note: "Industrial REIT. Logistics demand plus rate sensitivity.", complex: "us-reits"),
        .init(symbol: "FCX",   name: "Freeport-McMoRan",   klass: .equity, sector: "Materials",        note: "Copper beta. The cleanest listed read on industrial demand."),
        .init(symbol: "NEM",   name: "Newmont",            klass: .equity, sector: "Materials",        note: "Gold miner. One of the few things that rises when everything falls."),
        .init(symbol: "MU",    name: "Micron",             klass: .equity, sector: "Semiconductors",   note: "Memory cycle. Brutally cyclical, textbook boom and bust.", complex: "ai-semis"),
        .init(symbol: "TSM",   name: "TSMC",               klass: .equity, sector: "Semiconductors",   note: "The foundry everything else depends on. Carries Taiwan risk.", complex: "ai-semis"),
        .init(symbol: "INTC",  name: "Intel",              klass: .equity, sector: "Semiconductors",   note: "Turnaround with state money behind it. Trades on execution."),
        .init(symbol: "DIS",   name: "Disney",             klass: .equity, sector: "Communication",    note: "Parks cash flow funding a streaming war. Range-bound for years."),
        .init(symbol: "UBER",  name: "Uber",               klass: .equity, sector: "Technology",       note: "Reached profitability, now valued on it. Autonomy is the risk."),
        .init(symbol: "NKE",   name: "Nike",               klass: .equity, sector: "Consumer",         note: "Brand in a turnaround. Inventory cycles drive the moves."),
        .init(symbol: "MCD",   name: "McDonald's",         klass: .equity, sector: "Consumer Staples", note: "Defensive franchise economics. Low beta, steady compounding."),
        .init(symbol: "RKLB",  name: "Rocket Lab",         klass: .equity, sector: "Industrials",      note: "Small-cap space. Moves 8% on a launch, either direction."),
        .init(symbol: "HOOD",  name: "Robinhood",          klass: .equity, sector: "Financials",       note: "Retail brokerage. Revenue rises with the speculation it hosts.", complex: "crypto-beta"),
        .init(symbol: "IONQ",  name: "IonQ",               klass: .equity, sector: "Technology",       note: "Pre-revenue quantum. Pure narrative, extreme range."),
    ]

    /* ---------------------------------------------------- Swedish equities */

    /**
     * The OMXS30 large caps, quoted in kronor on Nasdaq Stockholm.
     *
     * This is a different market rather than a translated version of the US one.
     * It opens six and a half hours earlier, it is far more concentrated in banks
     * and industrials, its index is thirty names rather than five hundred, and the
     * krona moves against the dollar underneath all of it. A Swedish industrial
     * having a good year while US tech has a bad one is a real and frequent
     * occurrence, and it is invisible to a board that only holds one of them.
     */
    static let swedishEquities: [Instrument] = [
        // ---- Banks. Four names, one interest-rate bet.
        .init(symbol: "SEB-A.ST",    name: "SEB",                klass: .equity, sector: "Financials",       note: "Corporate bank, the most cyclical of the four.", venue: .stockholm, complex: "se-banks"),
        .init(symbol: "SWED-A.ST",   name: "Swedbank",           klass: .equity, sector: "Financials",       note: "Mortgage-heavy. Swedish housing shows up here first.", venue: .stockholm, complex: "se-banks"),
        .init(symbol: "SHB-A.ST",    name: "Handelsbanken",      klass: .equity, sector: "Financials",       note: "The conservative one. Lowest beta of the Swedish banks.", venue: .stockholm, complex: "se-banks"),
        .init(symbol: "NDA-SE.ST",   name: "Nordea",             klass: .equity, sector: "Financials",       note: "Pan-Nordic. Dividend-led, less exposed to Sweden alone.", venue: .stockholm, complex: "se-banks"),

        // ---- Industrials. What Sweden actually sells to the world.
        .init(symbol: "ATCO-A.ST",   name: "Atlas Copco",        klass: .equity, sector: "Industrials",      note: "Compressors and vacuum. Semiconductor capex reaches Sweden here.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "VOLV-B.ST",   name: "Volvo",              klass: .equity, sector: "Industrials",      note: "Trucks, not cars. A direct read on the freight cycle.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "SAND.ST",     name: "Sandvik",            klass: .equity, sector: "Industrials",      note: "Mining and cutting tools. Commodity capex, one step removed.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "SKF-B.ST",    name: "SKF",                klass: .equity, sector: "Industrials",      note: "Bearings. Turns with global manufacturing and little else.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "ALFA.ST",     name: "Alfa Laval",         klass: .equity, sector: "Industrials",      note: "Heat transfer and separation. Marine and energy transition.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "ABB.ST",      name: "ABB",                klass: .equity, sector: "Industrials",      note: "Electrification and robotics. Dual-listed, so watch the spread.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "ASSA-B.ST",   name: "Assa Abloy",         klass: .equity, sector: "Industrials",      note: "Locks and access. Serial acquirer, unusually steady trend.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "HEXA-B.ST",   name: "Hexagon",            klass: .equity, sector: "Technology",       note: "Measurement and design software wrapped in an industrial.", venue: .stockholm, complex: "se-industrials"),
        .init(symbol: "SAAB-B.ST",   name: "Saab",               klass: .equity, sector: "Industrials",      note: "Defence. Re-rated on European rearmament rather than on earnings.", venue: .stockholm),
        .init(symbol: "NIBE-B.ST",   name: "NIBE Industrier",    klass: .equity, sector: "Industrials",      note: "Heat pumps. A boom that reversed hard — a destocking case study.", venue: .stockholm),
        .init(symbol: "GETI-B.ST",   name: "Getinge",            klass: .equity, sector: "Healthcare",       note: "Medical technology. Recall headlines dominate the chart.", venue: .stockholm),

        // ---- Telecom, consumer, gaming, property.
        .init(symbol: "ERIC-B.ST",   name: "Ericsson",           klass: .equity, sector: "Communication",    note: "Network equipment. Carrier capex cycles are long and lumpy.", venue: .stockholm),
        .init(symbol: "TELIA.ST",    name: "Telia",              klass: .equity, sector: "Communication",    note: "Incumbent telco. Yield instrument, minimal growth.", venue: .stockholm),
        .init(symbol: "TEL2-B.ST",   name: "Tele2",              klass: .equity, sector: "Communication",    note: "Challenger telco. Steadier than Telia, same rate sensitivity.", venue: .stockholm),
        .init(symbol: "HM-B.ST",     name: "H&M",                klass: .equity, sector: "Consumer",         note: "Fast fashion under margin pressure. Monthly sales move it.", venue: .stockholm),
        .init(symbol: "EVO.ST",      name: "Evolution",          klass: .equity, sector: "Consumer",         note: "Live casino. Extraordinary margins, permanent regulatory risk.", venue: .stockholm),
        .init(symbol: "AZN.ST",      name: "AstraZeneca",        klass: .equity, sector: "Healthcare",       note: "The Stockholm line of a UK pharma. Defensive, FX-exposed.", venue: .stockholm),
        .init(symbol: "ESSITY-B.ST", name: "Essity",             klass: .equity, sector: "Consumer Staples", note: "Hygiene products. About as defensive as Stockholm offers.", venue: .stockholm),
        .init(symbol: "ELUX-B.ST",   name: "Electrolux",         klass: .equity, sector: "Consumer",         note: "White goods. Operationally geared — small revenue moves, large profit moves.", venue: .stockholm),
        .init(symbol: "BOL.ST",      name: "Boliden",            klass: .equity, sector: "Materials",        note: "Zinc and copper mining. Sweden's commodity beta.", venue: .stockholm),
        .init(symbol: "SCA-B.ST",    name: "SCA",                klass: .equity, sector: "Materials",        note: "Forestry. Owns the land, so the cycle is slower than the pulp price.", venue: .stockholm),
        .init(symbol: "INVE-B.ST",   name: "Investor",           klass: .equity, sector: "Financials",       note: "Wallenberg holding company. Owns much of this list at a discount.", venue: .stockholm),
        .init(symbol: "EQT.ST",      name: "EQT",                klass: .equity, sector: "Financials",       note: "Private equity manager. Earnings arrive in lumps on exits.", venue: .stockholm),
        .init(symbol: "KINV-B.ST",   name: "Kinnevik",           klass: .equity, sector: "Financials",       note: "Growth investment company. Traded at a wide, moving discount.", venue: .stockholm),
        .init(symbol: "SINCH.ST",    name: "Sinch",              klass: .equity, sector: "Technology",       note: "Messaging infrastructure. A roll-up that de-rated hard.", venue: .stockholm),
        .init(symbol: "SBB-B.ST",    name: "SBB",                klass: .equity, sector: "Real Estate",      note: "Leveraged property. The clearest lesson in what rising rates do to debt.", venue: .stockholm),
    ]

    /* ---------------------------------------------------------- crypto */

    static let cryptoPairs: [Instrument] = [
        .init(symbol: "BTC-USD",  name: "Bitcoin",   klass: .crypto, sector: "Crypto", note: "The market beta. Everything else is a leveraged bet on it.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "ETH-USD",  name: "Ethereum",  klass: .crypto, sector: "Crypto", note: "Smart-contract platform beta, ~1.3x BTC swings.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "SOL-USD",  name: "Solana",    klass: .crypto, sector: "Crypto", note: "High-beta L1. Rips in risk-on, halves in risk-off.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "XRP-USD",  name: "XRP",       klass: .crypto, sector: "Crypto", note: "Event/legal-driven. Ignores technicals on news.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "DOGE-USD", name: "Dogecoin",  klass: .crypto, sector: "Crypto", note: "Pure sentiment. Included as a cautionary instrument.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "ADA-USD",  name: "Cardano",   klass: .crypto, sector: "Crypto", note: "Large-cap alt, slower cycles than SOL.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "LINK-USD", name: "Chainlink", klass: .crypto, sector: "Crypto", note: "Infrastructure alt, correlates with ETH.", venue: .crypto, complex: "crypto-beta"),
        .init(symbol: "AVAX-USD", name: "Avalanche", klass: .crypto, sector: "Crypto", note: "High-beta alt. Deep drawdowns between cycles.", venue: .crypto, complex: "crypto-beta"),
    ]

    /* ------------------------------------------------------- benchmarks */

    /// Held out of recommendations, used as the yardstick. One per venue that has
    /// a market of its own — comparing a Stockholm pick to the S&P 500 measures
    /// the krona as much as it measures the stock.
    static let benchmarkInstruments: [Instrument] = [
        .init(symbol: "SPY", name: "S&P 500 ETF",     klass: .equity, sector: "Index", note: "The benchmark you must beat to justify stock picking."),
        .init(symbol: "QQQ", name: "Nasdaq 100 ETF",  klass: .equity, sector: "Index", note: "Growth/tech regime gauge."),
        .init(symbol: "^OMX", name: "OMXS30",         klass: .equity, sector: "Index", note: "The thirty largest Stockholm listings. The yardstick for anything bought in kronor.", venue: .stockholm),
    ]

    static let benchmarks: Set<String> = ["SPY", "QQQ", "^OMX"]

    /// The benchmark a given instrument should actually be measured against.
    static func benchmark(for symbol: String) -> String {
        switch venue(of: symbol) {
        case .crypto: return "BTC-USD"
        case .stockholm: return "^OMX"
        case .us: return "SPY"
        }
    }

    static let bySymbol: [String: Instrument] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.symbol, $0) }
    )

    static let symbols: [String] = all.map(\.symbol)

    static func isCrypto(_ symbol: String) -> Bool {
        bySymbol[symbol]?.klass == .crypto || symbol.hasSuffix("-USD")
    }

    /// Where a symbol trades. Unknown symbols are treated as US, which is what the
    /// app did before venues existed and is the safe default: it applies the
    /// stricter clock and the PDT rule rather than waiving both.
    static func venue(of symbol: String) -> Venue {
        if let inst = bySymbol[symbol] { return inst.venue }
        if isCrypto(symbol) { return .crypto }
        if symbol.hasSuffix(".ST") { return .stockholm }
        return .us
    }

    /// The currency a symbol's prices are quoted in. Not the currency the ledger
    /// settles in, which is always dollars.
    static func currency(of symbol: String) -> Currency { venue(of: symbol).currency }

    /// True where a price in this symbol is not already a dollar figure.
    static func needsConversion(_ symbol: String) -> Bool { currency(of: symbol) != .usd }

    /// The correlation group a symbol belongs to, when it belongs to one.
    static func complex(of symbol: String) -> String? { bySymbol[symbol]?.complex }

    static func symbols(in venue: Venue) -> [String] {
        all.filter { $0.venue == venue }.map(\.symbol)
    }

    /// Trading periods in a year. Crypto never closes; exchanges get ~252 sessions.
    static func periodsPerYear(_ symbol: String) -> Double {
        isCrypto(symbol) ? 365 : 252
    }
}
