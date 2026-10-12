/**
 * Profile.swift — who is trading, and what that changes.
 *
 * A profile is not a label on an account. It is the set of facts that decide
 * what the engine is allowed to propose: how much can be risked, over what
 * horizon, in which instruments, and — the part most simulators skip — how much
 * of a loss this person could actually absorb.
 *
 * The distinction that drives everything here is between **risk tolerance**, which
 * is what someone says they want, and **risk capacity**, which is what their
 * situation can survive. A salaried saver adding £500 a month can refill a bad
 * quarter. Someone unemployed with a large lump sum cannot: every pound lost is
 * permanent, and no amount of appetite changes that. A real adviser is required to
 * check that before recommending anything, and it is the single biggest reason two
 * people with identical opinions about a stock should take different positions in
 * it. So Paper computes capacity from the facts, caps the stated appetite with it,
 * and always says why it did.
 *
 * Each profile keeps its own ledger. A day trader and a long-term holder sharing
 * one equity curve would make both records meaningless.
 */

import Foundation

/* ------------------------------------------------------------- the axes */

enum TimeHorizon: String, Codable, CaseIterable {
    /// Hours. In and out inside a session.
    case intraday
    /// Days to a couple of weeks.
    case swing
    /// Weeks to months.
    case position
    /// Months to years. Buys businesses, not charts.
    case longTerm = "long-term"

    var label: String {
        switch self {
        case .intraday: return "Intraday"
        case .swing: return "Swing — days to weeks"
        case .position: return "Position — weeks to months"
        case .longTerm: return "Long-term — months to years"
        }
    }

    /**
     * The window a plan is expected to resolve in, in sessions. A setup that needs
     * far longer than this — or resolves far faster — is the wrong trade for this
     * person, however good it is in the abstract.
     *
     * The intraday band is deliberately wider than its name suggests. This engine
     * reads daily bars, and daily bars cannot resolve a trade that opens and closes
     * inside one session. What "intraday" honestly buys here is the tightest stops
     * and the fastest setups the data can support; true day trading needs intraday
     * data this app does not have, and pretending otherwise would be the kind of
     * lie the rest of the simulator exists to avoid.
     */
    var sessionBand: (min: Double, max: Double) {
        switch self {
        case .intraday: return (1, 6)
        case .swing: return (2, 25)
        case .position: return (6, 120)
        case .longTerm: return (15, 500)
        }
    }

    /// True where the horizon is finer than the daily bars the engine reads.
    var outrunsTheData: Bool { self == .intraday }

    /// Stop width in ATR. A shorter horizon cannot afford to sit through a normal
    /// pullback, and a longer one cannot afford to be shaken out by one.
    var stopScale: Double {
        switch self {
        case .intraday: return 0.55
        case .swing: return 0.85
        case .position: return 1.0
        case .longTerm: return 1.45
        }
    }

    var targetScale: Double {
        switch self {
        case .intraday: return 0.5
        case .swing: return 0.8
        case .position: return 1.0
        case .longTerm: return 2.4
        }
    }

    /// What choosing this horizon actually changes about the read, in one line —
    /// so the picker can say why the shortlist is about to be different rather than
    /// only that it will be.
    var emphasis: String {
        switch self {
        case .intraday:
            return "Weights daily range and this week's momentum above everything else. Instruments that barely move are filtered out: they cannot cover the spread inside a session."
        case .swing:
            return "Balances trend, a month of momentum and the quality of the entry. The default read, and the one the engine has always given."
        case .position:
            return "Leans on the trend and a quarter of momentum, and starts asking whether the instrument survives a bad stretch."
        case .longTerm:
            return "Weights durability above almost everything — how deep the drawdowns ran, how rough the ride was, whether it holds its 200-day. Entry price stops mattering much."
        }
    }
}

enum InvestmentGoal: String, Codable, CaseIterable {
    /// Maximum appreciation, drawdown accepted as the cost.
    case growth
    /// Steady, low-volatility compounding.
    case income
    /// Keeping what you have is the objective; upside is secondary.
    case preservation
    /// Asymmetric bets, most of which fail.
    case speculation
    /// Balanced, chosen to teach rather than to win.
    case learning

    var label: String {
        switch self {
        case .growth: return "Grow the capital"
        case .income: return "Steady, low-volatility compounding"
        case .preservation: return "Preserve what I have"
        case .speculation: return "Asymmetric bets"
        case .learning: return "Learn how this works"
        }
    }

    /// The same objective in the middle of a sentence. Lowercasing `label` turns
    /// "Preserve what I have" into "preserve what i have", which is the kind of small
    /// wrongness that makes generated prose read as generated.
    var phrase: String {
        switch self {
        case .growth: return "growing the capital"
        case .income: return "steady, low-volatility compounding"
        case .preservation: return "preserving what you have"
        case .speculation: return "asymmetric bets"
        case .learning: return "learning how this works"
        }
    }

    /// The minimum reward-to-risk this goal will fund. Preservation demands to be
    /// paid more for the same risk; speculation accepts thinner odds on bigger prizes.
    var minRewardToRisk: Double {
        switch self {
        case .growth: return 1.8
        case .income: return 2.2
        case .preservation: return 2.5
        case .speculation: return 1.5
        case .learning: return 1.5
        }
    }

    /// How much daily movement this goal tolerates, as a percentage of price.
    var maxDailyRangePct: Double? {
        switch self {
        case .growth: return 9
        case .income: return 3.5
        case .preservation: return 2.5
        case .speculation: return nil
        case .learning: return 7
        }
    }
}

enum IncomeStability: String, Codable, CaseIterable {
    /// No income. Nothing replaces what is lost.
    case none
    /// Freelance or commission — arrives, but not on a schedule.
    case irregular
    case salaried
    /// Income comfortably exceeds outgoings.
    case abundant

    var label: String {
        switch self {
        case .none: return "No income right now"
        case .irregular: return "Irregular / freelance"
        case .salaried: return "Steady salary"
        case .abundant: return "Income well above outgoings"
        }
    }

    var capacityScore: Double {
        switch self {
        case .none: return 0
        case .irregular: return 38
        case .salaried: return 72
        case .abundant: return 100
        }
    }
}

enum AssetAppetite: String, Codable, CaseIterable {
    case stocksOnly = "stocks-only"
    case cryptoOnly = "crypto-only"
    case both
    /// Broad index exposure is the point; single names are the exception.
    case indexFirst = "index-first"

    var label: String {
        switch self {
        case .stocksOnly: return "Equities only"
        case .cryptoOnly: return "Crypto only"
        case .both: return "Equities and crypto"
        case .indexFirst: return "Index-first"
        }
    }
}

/* ------------------------------------------------------------ the profile */

struct Profile: Codable, Identifiable {
    var id: String

    /// Ids name files (`ledgers/<id>.json`), so only plain ones are accepted: letters,
    /// digits and dashes, which covers the UUIDs the app generates and nothing that
    /// could climb out of the data folder.
    static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    var name: String
    /// One line in the user's own words about who this account is.
    var note: String

    // --- capital and circumstances
    var startingCapital: Double
    /// Added to the account on the first refresh of each month. Dollar-cost averaging
    /// is the single most common real behaviour a simulator leaves out.
    var monthlyContribution: Double
    var monthlyExpenses: Double
    /// Months of expenses held *outside* this account. The difference between an
    /// investor and a gambler is usually this number.
    var emergencyFundMonths: Double
    var incomeStability: IncomeStability

    // --- objectives
    var goal: InvestmentGoal
    var horizon: TimeHorizon
    var targetAnnualReturnPct: Double

    // --- stated appetite
    var riskPctPerTrade: Double
    var maxPositionPct: Double
    var maxOpenPositions: Int
    /// The largest peak-to-trough fall this person says they would sit through
    /// without abandoning the method. Most people overestimate it.
    var drawdownTolerancePct: Double

    // --- universe
    var appetite: AssetAppetite
    /**
     * Which exchanges this account trades on.
     *
     * Separate from `appetite`, which is about asset class. Someone in Stockholm may
     * want equities and crypto but only the listings they can actually buy before
     * dinner; someone else wants both boards. Empty is read as "all", so a profile
     * written before Stockholm existed keeps seeing everything it saw yesterday and
     * gains the new names rather than losing the old ones.
     */
    var markets: [Venue] = Venue.allCases

    // --- frictions
    var frictions: Frictions

    // --- presentation
    /// The currency the principal *reads* in — not the one the account is kept in.
    ///
    /// The ledger, the prices, the entry fields and every sentence this app writes
    /// about money are dollars, always, because that is what these instruments are
    /// quoted and traded in and because one unit is the only arrangement where a
    /// figure cannot disagree with the paragraph beside it. What this buys is a
    /// second, smaller figure printed next to the dollar one, so an amount can be
    /// read in the currency the person actually thinks in without any part of the
    /// system pretending that is what it holds.
    ///
    /// Defaults to whatever the Mac's region says, so the first screen is already
    /// right rather than defaulting to dollars and waiting to be corrected.
    var currency: Currency = .systemDefault
    /// Plain-language mode: the interface explains its own terms as it uses them.
    /// On by default for anyone who did not tell the setup they had traded before.
    var plainLanguage: Bool = true
    /// Where the app opens and how much it explains. Separate from every setting
    /// above it: those decide how this account trades, this decides how it reads.
    var readingMode: ReadingMode = .guided

    /// The answers this profile was built from, kept so the setup can be revisited
    /// and re-derived rather than re-guessed.
    var onboarding: Onboarding.Answers?

    var createdAt: Double

    /* ---------------------------------------------------------------- coding */

    /**
     * Decoded field by field so a ledger written by an older build still opens.
     * Swift's synthesised decoder fails the whole profile on one missing key, which
     * would turn every added setting into a wiped account.
     */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Account"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        startingCapital = try c.decodeIfPresent(Double.self, forKey: .startingCapital) ?? 100_000
        monthlyContribution = try c.decodeIfPresent(Double.self, forKey: .monthlyContribution) ?? 0
        monthlyExpenses = try c.decodeIfPresent(Double.self, forKey: .monthlyExpenses) ?? 0
        emergencyFundMonths = try c.decodeIfPresent(Double.self, forKey: .emergencyFundMonths) ?? 3
        incomeStability = try c.decodeIfPresent(IncomeStability.self, forKey: .incomeStability) ?? .salaried
        goal = try c.decodeIfPresent(InvestmentGoal.self, forKey: .goal) ?? .learning
        horizon = try c.decodeIfPresent(TimeHorizon.self, forKey: .horizon) ?? .swing
        targetAnnualReturnPct = try c.decodeIfPresent(Double.self, forKey: .targetAnnualReturnPct) ?? 12
        riskPctPerTrade = try c.decodeIfPresent(Double.self, forKey: .riskPctPerTrade) ?? 1
        maxPositionPct = try c.decodeIfPresent(Double.self, forKey: .maxPositionPct) ?? 20
        maxOpenPositions = try c.decodeIfPresent(Int.self, forKey: .maxOpenPositions) ?? 6
        drawdownTolerancePct = try c.decodeIfPresent(Double.self, forKey: .drawdownTolerancePct) ?? 25
        appetite = try c.decodeIfPresent(AssetAppetite.self, forKey: .appetite) ?? .both
        let decodedMarkets = try c.decodeIfPresent([Venue].self, forKey: .markets) ?? []
        markets = decodedMarkets.isEmpty ? Venue.allCases : decodedMarkets
        frictions = try c.decodeIfPresent(Frictions.self, forKey: .frictions) ?? .retailBroker
        currency = try c.decodeIfPresent(Currency.self, forKey: .currency) ?? .systemDefault
        plainLanguage = try c.decodeIfPresent(Bool.self, forKey: .plainLanguage) ?? true
        // A ledger written before reading modes existed opens on the desk with its
        // own plain-language setting intact, which is what it did yesterday.
        readingMode = try c.decodeIfPresent(ReadingMode.self, forKey: .readingMode)
            ?? (plainLanguage ? .guided : .dense)
        onboarding = try c.decodeIfPresent(Onboarding.Answers.self, forKey: .onboarding)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? nowMs()
    }

    init(id: String, name: String, note: String, startingCapital: Double,
         monthlyContribution: Double, monthlyExpenses: Double, emergencyFundMonths: Double,
         incomeStability: IncomeStability, goal: InvestmentGoal, horizon: TimeHorizon,
         targetAnnualReturnPct: Double, riskPctPerTrade: Double, maxPositionPct: Double,
         maxOpenPositions: Int, drawdownTolerancePct: Double, appetite: AssetAppetite,
         frictions: Frictions, createdAt: Double, markets: [Venue] = Venue.allCases,
         currency: Currency = .systemDefault, plainLanguage: Bool = true,
         readingMode: ReadingMode = .guided,
         onboarding: Onboarding.Answers? = nil) {
        self.id = id; self.name = name; self.note = note
        self.startingCapital = startingCapital
        self.monthlyContribution = monthlyContribution
        self.monthlyExpenses = monthlyExpenses
        self.emergencyFundMonths = emergencyFundMonths
        self.incomeStability = incomeStability
        self.goal = goal; self.horizon = horizon
        self.targetAnnualReturnPct = targetAnnualReturnPct
        self.riskPctPerTrade = riskPctPerTrade
        self.maxPositionPct = maxPositionPct
        self.maxOpenPositions = maxOpenPositions
        self.drawdownTolerancePct = drawdownTolerancePct
        self.appetite = appetite
        self.markets = markets.isEmpty ? Venue.allCases : markets
        self.frictions = frictions
        self.currency = currency
        self.plainLanguage = plainLanguage
        self.readingMode = readingMode
        self.onboarding = onboarding
        self.createdAt = createdAt
    }

    /* --------------------------------------------------------- suitability */

    /**
     * Risk capacity, 0–100, from circumstances alone — never from opinion.
     *
     * Four facts decide it: whether income replaces losses, how fast contributions
     * refill the account, whether there is a cash buffer so this money is not needed
     * next month, and whether the horizon is long enough to sit through a bad year.
     */
    var riskCapacity: Double {
        let income = incomeStability.capacityScore

        // How much of the account a year of contributions would replace.
        let replenishment = startingCapital > 0
            ? Analysis.clamp((monthlyContribution * 12 / startingCapital) * 400, 0, 100)
            : 0

        // Six months of expenses set aside is the conventional full buffer.
        let buffer = Analysis.clamp((emergencyFundMonths / 6) * 100, 0, 100)

        let horizonScore: Double = {
            switch horizon {
            case .intraday: return 30
            case .swing: return 45
            case .position: return 70
            case .longTerm: return 100
            }
        }()

        return Analysis.clamp(income * 0.34 + replenishment * 0.2 + buffer * 0.28 + horizonScore * 0.18)
    }

    /// The largest risk-per-trade this situation supports, whatever the appetite says.
    var suitableRiskPct: Double {
        let c = riskCapacity
        var ceiling: Double
        switch c {
        case ..<20: ceiling = 0.5
        case ..<40: ceiling = 0.75
        case ..<60: ceiling = 1.0
        case ..<80: ceiling = 1.5
        default: ceiling = 2.0
        }

        // The hard case the whole idea exists for: no income and no buffer means
        // losses are permanent, and no stated appetite changes that.
        if incomeStability == .none && emergencyFundMonths < 3 {
            ceiling = Swift.min(ceiling, 0.5)
        }
        if goal == .preservation { ceiling = Swift.min(ceiling, 0.75) }
        return ceiling
    }

    /// What the engine actually risks: the appetite, capped by the capacity.
    var effectiveRiskPct: Double {
        Swift.min(riskPctPerTrade, suitableRiskPct)
    }

    var isRiskCapped: Bool { riskPctPerTrade > suitableRiskPct + 1e-9 }

    /// Said plainly, because a cap the user cannot see is a cap they will resent.
    var suitabilityNote: String {
        guard isRiskCapped else {
            return "Your stated risk of \(f(riskPctPerTrade, 2))% per trade is inside what this situation supports (\(f(suitableRiskPct, 2))%), so the engine uses it as written."
        }
        var why: [String] = []
        if incomeStability == .none { why.append("no income is replacing what this account loses") }
        else if incomeStability == .irregular { why.append("income arrives irregularly, so a drawdown cannot be timed against it") }
        if emergencyFundMonths < 3 { why.append("there is under three months of expenses set aside outside this account") }
        if monthlyContribution <= 0 { why.append("nothing is being added, so losses are not refilled") }
        if horizon == .intraday { why.append("an intraday horizon gives a bad run no time to recover") }
        if goal == .preservation { why.append("preservation is the stated objective") }
        if why.isEmpty { why.append("the circumstances on this profile do not support it") }

        return "You asked to risk \(f(riskPctPerTrade, 2))% per trade. The engine is using \(f(effectiveRiskPct, 2))% instead, because \(why.joined(separator: ", and ")). This is a suitability limit rather than a view on the trades: appetite is what you want, capacity is what your circumstances survive, and sizing follows the smaller of the two."
    }

    /// Total open risk allowed at once. Several positions each risking 1% is a 5%
    /// bet on one correlated market, which is the mistake position sizing alone
    /// never catches.
    var maxPortfolioHeatPct: Double {
        Swift.min(effectiveRiskPct * Double(maxOpenPositions), drawdownTolerancePct * 0.5)
    }

    /// The instruments this profile is allowed to be shown. Two independent
    /// filters: what kind of asset, and which exchange.
    func allows(_ symbol: String) -> Bool {
        guard trades(Universe.venue(of: symbol)) else { return false }
        let isCrypto = Universe.isCrypto(symbol)
        switch appetite {
        case .stocksOnly: return !isCrypto
        case .cryptoOnly: return isCrypto
        case .both: return true
        case .indexFirst: return true
        }
    }

    func trades(_ venue: Venue) -> Bool {
        markets.isEmpty || markets.contains(venue)
    }

    /// The venues this profile actually has instruments on, for the interface to
    /// name rather than list every exchange Paper knows about.
    var activeVenues: [Venue] { Venue.allCases.filter { trades($0) } }

    /// Benchmarks are normally held out of recommendations, but an index-first
    /// profile is precisely the person who *should* be shown them.
    var fundsBenchmarks: Bool { appetite == .indexFirst }

    /// Everything the plan builder needs to produce *this person's* version of a
    /// setup rather than a generic one.
    /**
     * `style` overrides the profile's own horizon for one scan.
     *
     * The profile's horizon is what this account normally does. It is not always
     * what is being asked: the same capital, circumstances and risk limits can be
     * pointed at a day trade or at a two-year hold, and the interesting question is
     * what changes when they are. Passing a style here builds the plan for that
     * question while every limit that protects the account stays exactly where the
     * profile set it — the stop widens, the risk per trade does not.
     */
    func sizingRules(equity: Double, style: TimeHorizon? = nil) -> Analysis.SizingRules {
        let h = style ?? horizon
        var rules = Analysis.SizingRules(
            equity: equity,
            riskPctPerTrade: effectiveRiskPct,
            maxPositionPct: maxPositionPct
        )
        rules.stopScale = h.stopScale
        rules.targetScale = h.targetScale
        rules.minRewardToRisk = goal.minRewardToRisk
        rules.maxDailyRangePct = goal.maxDailyRangePct
        rules.minSessions = h.sessionBand.min
        rules.maxSessions = h.sessionBand.max
        rules.horizonLabel = h.label.components(separatedBy: " —").first ?? h.rawValue
        // A multi-year holding is not trading to the next pivot, and pretending it is
        // caps the target so close that the plan then reads as too fast for its own
        // horizon and gets refused.
        rules.capTargetAtResistance = h != .longTerm
        return rules
    }

    /// A compact description for the analyst's prompts — the model needs the
    /// circumstances, not just the numbers, to write advice that fits the person.
    var brief: String {
        var lines = [
            "Profile: \(name) — \(note)",
            "Objective: \(goal.label). Horizon: \(horizon.label). Target return: \(f(targetAnnualReturnPct, 0))% a year.",
            "Capital: \(money(startingCapital)) simulated. Contributing \(money(monthlyContribution)) a month. Monthly expenses \(money(monthlyExpenses)).",
            "Circumstances: \(incomeStability.label). \(f(emergencyFundMonths, 1)) months of expenses held outside this account.",
            "Risk capacity \(f(riskCapacity, 0))/100. Stated risk \(f(riskPctPerTrade, 2))% per trade; engine is using \(f(effectiveRiskPct, 2))%\(isRiskCapped ? " (capped for suitability)" : "").",
            "Limits: at most \(maxOpenPositions) open positions, \(f(maxPositionPct, 0))% of equity in any one, \(f(maxPortfolioHeatPct, 1))% total open risk, \(f(drawdownTolerancePct, 0))% stated drawdown tolerance.",
            "Universe: \(appetite.label). Minimum reward-to-risk this profile funds: \(f(goal.minRewardToRisk, 2)):1.",
        ]
        if let cap = goal.maxDailyRangePct {
            lines.append("Refuses instruments whose average day moves more than \(f(cap, 1))% of price.")
        }
        lines.append("Markets: \(activeVenues.map(\.exchangeName).joined(separator: ", ")).")
        lines.append("Costs: \(frictions.brief)")
        // Said explicitly rather than left to be inferred from the dollar signs. A
        // model that decides mid-answer that the account is denominated in the
        // reader's local currency starts quoting stops in it, and a stop is the one
        // number that has to be in the currency the order would carry.
        /* The currency instruction, which is now two rules rather than one.
         *
         * Money and prices have come apart, and the model has to be told exactly
         * where the line is or it will quote a Swedish stop with a dollar sign — the
         * one error that turns a teaching example into a number nobody could act on.
         * Account figures are dollars, always. An instrument's levels are whatever
         * that instrument is quoted in, which the metric pack states per name. */
        if activeVenues.contains(.stockholm) {
            lines.append("Currency: the account settles in US dollars, so every balance, limit, risk figure and profit above and in your answer is dollars. Instrument prices are a separate matter: each one is quoted in its own currency, stated beside it in the metric pack, and every entry, stop and target you discuss for that instrument is in that currency. Stockholm listings are in Swedish kronor (SEK). Never convert a level, and never put a dollar sign on a kronor price.")
        } else {
            lines.append("Currency: every figure above, and every figure you write back, is US dollars. The instruments are quoted in dollars and the ledger settles in dollars. Never restate an amount in another currency.")
        }
        return lines.joined(separator: "\n")
    }

    /* ------------------------------------------------------------ presets */

    static func preset(_ kind: PresetKind) -> Profile {
        var p = Profile(
            id: UUID().uuidString, name: "", note: "",
            startingCapital: 100_000, monthlyContribution: 0, monthlyExpenses: 2_500,
            emergencyFundMonths: 3, incomeStability: .salaried,
            goal: .learning, horizon: .swing, targetAnnualReturnPct: 12,
            riskPctPerTrade: 1, maxPositionPct: 20, maxOpenPositions: 6,
            drawdownTolerancePct: 25, appetite: .both,
            frictions: .retailBroker, createdAt: nowMs()
        )

        switch kind {
        case .dayTrader:
            p.name = "Day trader"
            p.note = "In and out inside the session. Small edge, many repetitions, brutal on costs."
            p.startingCapital = 30_000
            p.monthlyContribution = 500
            p.monthlyExpenses = 2_800
            p.emergencyFundMonths = 2
            p.incomeStability = .irregular
            p.goal = .speculation
            p.horizon = .intraday
            p.targetAnnualReturnPct = 40
            p.riskPctPerTrade = 1
            p.maxPositionPct = 30
            p.maxOpenPositions = 4
            p.drawdownTolerancePct = 30
            p.appetite = .stocksOnly
            p.frictions = .activeTrader

        case .longTermGrower:
            p.name = "Long-term grower"
            p.note = "Buying businesses and leaving them alone. Contributions do most of the work."
            p.startingCapital = 60_000
            p.monthlyContribution = 1_200
            p.monthlyExpenses = 3_200
            p.emergencyFundMonths = 6
            p.incomeStability = .salaried
            p.goal = .growth
            p.horizon = .longTerm
            p.targetAnnualReturnPct = 10
            p.riskPctPerTrade = 1.5
            p.maxPositionPct = 25
            p.maxOpenPositions = 8
            p.drawdownTolerancePct = 40
            p.appetite = .stocksOnly
            p.frictions = .longTermInvestor

        case .cryptoNative:
            p.name = "Crypto native"
            p.note = "One market, high beta, no weekends. Position sizing is the only brake."
            p.startingCapital = 25_000
            p.monthlyContribution = 400
            p.monthlyExpenses = 2_200
            p.emergencyFundMonths = 3
            p.incomeStability = .salaried
            p.goal = .speculation
            p.horizon = .swing
            p.targetAnnualReturnPct = 60
            p.riskPctPerTrade = 2
            p.maxPositionPct = 35
            p.maxOpenPositions = 5
            p.drawdownTolerancePct = 50
            p.appetite = .cryptoOnly
            p.frictions = .cryptoExchange

        case .capitalToProtect:
            p.name = "Capital to protect"
            p.note = "A large sum, no income behind it. Losing it is not recoverable."
            p.startingCapital = 400_000
            p.monthlyContribution = 0
            p.monthlyExpenses = 3_500
            p.emergencyFundMonths = 1.5
            p.incomeStability = .none
            p.goal = .preservation
            p.horizon = .position
            p.targetAnnualReturnPct = 6
            p.riskPctPerTrade = 2      // deliberately over the cap, so the app explains itself
            p.maxPositionPct = 12
            p.maxOpenPositions = 8
            p.drawdownTolerancePct = 12
            p.appetite = .indexFirst
            p.frictions = .longTermInvestor

        case .learner:
            p.name = "Learning the ropes"
            p.note = "Here to understand the mechanism, not to win. Balanced on purpose."
            p.startingCapital = 100_000
            p.monthlyContribution = 0
            p.monthlyExpenses = 2_500
            p.emergencyFundMonths = 6
            p.incomeStability = .salaried
            p.goal = .learning
            p.horizon = .swing
            p.targetAnnualReturnPct = 12
            p.appetite = .both
            p.frictions = .retailBroker
        }
        return p
    }

    enum PresetKind: String, Codable, CaseIterable {
        case dayTrader = "day-trader"
        case longTermGrower = "long-term-grower"
        case cryptoNative = "crypto-native"
        case capitalToProtect = "capital-to-protect"
        case learner
    }
}

/**
 * Money, in the one currency this app keeps.
 *
 * Every figure the engine writes into a sentence — a session limit, a stop that
 * gapped, what a year of costs came to, the numbers the analyst is briefed on —
 * is dollars, because the ledger is dollars and there is no second denomination
 * for anything to be accidentally expressed in. This used to be the single worst
 * bug in the app: it hardcoded the dollar sign while the interface converted, so
 * an account set to kronor read `104 600 kr` in the header and `$500` in the
 * sentence four lines below it. Both were true of different quantities, which is
 * the least useful thing a number can be.
 *
 * No separators, so the analyst's model reads the figure rather than parsing it.
 */
func money(_ n: Double) -> String { "$" + f(n, 0) }
