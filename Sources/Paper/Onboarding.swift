/**
 * Onboarding.swift — the first five minutes, for someone who has never traded.
 *
 * The profile screen asks for risk per trade as a percentage of equity, a
 * drawdown tolerance, a maximum single position and a reward-to-risk floor. Those
 * are the right controls and they are also unanswerable by the person this app is
 * supposed to be for. Asked cold, they get guessed, and a guessed risk setting is
 * worse than a default because it carries the authority of having been chosen.
 *
 * So this file asks a different set of questions — how much, what happens if it
 * halves, what is the job situation, when might the money be needed — and derives
 * every trading parameter from the answers. That inversion is the entire idea:
 * circumstances are things a person actually knows about themselves, and every
 * number on the profile screen is downstream of them.
 *
 * Then it does the part a form never does. It looks for combinations that do not
 * hold together — no income and a 40% drawdown tolerance, money needed inside a
 * year and a multi-year horizon, day trading on an account the pattern-day-trader
 * rule will freeze — and says what each one means *for this kind of trading*,
 * specifically, before recommending a setting. Every recommendation can be
 * overridden; a flag that cannot be overruled is a lecture, and this is meant to
 * be a first day at a desk rather than a compliance form.
 *
 * Nothing here is investment advice, and the recommendations are about the shape
 * of a simulation. The suitability arithmetic is the same one Profile.swift runs,
 * deliberately, so the wizard and the profile screen can never disagree.
 */

import Foundation

enum Onboarding {

    /* --------------------------------------------------------- the answers */

    enum Purpose: String, Codable, CaseIterable {
        case learn, grow, active, test
        var label: String {
            switch self {
            case .learn: return "I want to understand how this works"
            case .grow: return "I want to grow money over time"
            case .active: return "I want to try active trading"
            case .test: return "I have a method and want to test it"
            }
        }
        var note: String {
            switch self {
            case .learn: return "Balanced settings, weighted toward explanation over performance."
            case .grow: return "Fewer, larger, longer trades. Most growth comes from contributions."
            case .active: return "More trades, tighter stops, higher costs."
            case .test: return "Your rules, measured including what they cost."
            }
        }
    }

    /**
     * How much the interface explains. Asked separately from `purpose` because
     * they are separate questions: "I want to understand how this works" is about
     * learning, and the other three purposes are about money. Read as one scale,
     * anyone who came here to grow money was never asked whether they wanted the
     * terms explained, and got the answer given by somebody else.
     */
    enum Explaining: String, Codable, CaseIterable {
        case full, onHover, none

        var label: String {
            switch self {
            case .full:    return "Explain the terms where they are used"
            case .onHover: return "Only when I ask"
            case .none:    return "Not at all"
            }
        }
        var note: String {
            switch self {
            case .full:    return "Headings carry a plain line underneath. Every term is underlined."
            case .onHover: return "Nothing is added to the screen. Definitions stay on hover."
            case .none:    return "No underlines and no added lines."
            }
        }
    }

    /// When the money might genuinely be needed for something else. This is the
    /// single most decisive answer in the whole set and almost nobody is asked it.
    enum NeedWindow: String, Codable, CaseIterable {
        case anyTime, withinYear, oneToFive, fivePlus

        var label: String {
            switch self {
            case .anyTime: return "I might need it at any time"
            case .withinYear: return "Possibly within a year"
            case .oneToFive: return "Not for a few years"
            case .fivePlus: return "Not for five years or more"
            }
        }
        var months: Double {
            switch self {
            case .anyTime: return 1
            case .withinYear: return 9
            case .oneToFive: return 36
            case .fivePlus: return 84
            }
        }
    }

    /// The drawdown question, asked as an event rather than as a percentage. People
    /// answer "what would you do" honestly and "what drawdown could you tolerate"
    /// aspirationally, and the difference between those two answers is most of the
    /// gap between a plan and what actually happens.
    enum DropReaction: String, Codable, CaseIterable {
        case sellAll, uncomfortable, holdOn, buyMore

        var label: String {
            switch self {
            case .sellAll: return "I'd get out — I couldn't watch that"
            case .uncomfortable: return "I'd be very uncomfortable but probably hold"
            case .holdOn: return "I'd hold. That's part of it"
            case .buyMore: return "I'd be looking to buy more"
            }
        }
        /// The drawdown the answer actually implies, as opposed to the one people claim.
        var drawdownPct: Double {
            switch self {
            case .sellAll: return 10
            case .uncomfortable: return 20
            case .holdOn: return 30
            case .buyMore: return 45
            }
        }
    }

    enum Attention: String, Codable, CaseIterable {
        case rarely, daily, allDay

        var label: String {
            switch self {
            case .rarely: return "A few minutes a week"
            case .daily: return "Once or twice a day"
            case .allDay: return "I can watch it through the day"
            }
        }
    }

    enum Experience: String, Codable, CaseIterable {
        case none, some, experienced

        var label: String {
            switch self {
            case .none: return "None at all"
            case .some: return "I've bought a few things"
            case .experienced: return "I've traded actively before"
            }
        }
    }

    /// Everything the wizard collects. Every money answer is in **dollars**, the
    /// one unit this app keeps, with the person's own currency shown underneath the
    /// field as they type so the figure still means something to them. `currency`
    /// is that reading currency and nothing else — it converts no stored value.
    struct Answers: Codable {
        var currency: Currency = .systemDefault
        var purpose: Purpose = .learn
        var explaining: Explaining = .full
        /// What they would put in, in dollars.
        var amount: Double = 0
        var income: IncomeStability = .salaried
        var monthlyExpenses: Double = 0
        /// Cash held elsewhere, in dollars — not months, because nobody knows
        /// their buffer in months and everybody knows it as an amount.
        var savingsOutside: Double = 0
        var monthlyAdd: Double = 0
        var needWindow: NeedWindow = .oneToFive
        var dropReaction: DropReaction = .uncomfortable
        var attention: Attention = .daily
        var experience: Experience = .none
        var appetite: AssetAppetite = .both
        var name: String = ""
    }

    /* ----------------------------------------------------------- the output */

    enum Severity: String, Codable { case blocking, serious, note, good }

    /// One thing that does not hold together, said plainly and specifically.
    struct Flag: Codable, Identifiable {
        var id: String
        var severity: Severity
        var title: String
        /// Why this matters *for this kind of trading*, not in the abstract.
        var body: String
        /// What the recommendation does about it.
        var consequence: String
    }

    /// One setting where a literal reading of the answers and the recommendation
    /// differ, with the reason. Every one of these is overridable.
    struct Recommendation: Codable, Identifiable {
        var id: String
        var label: String
        /// What the answers, read literally, would give.
        var yours: String
        var recommended: String
        var why: String
    }

    struct Assessment: Codable {
        var profile: Profile
        var flags: [Flag]
        var recommendations: [Recommendation]
        var capacity: Double
        var suitableRiskPct: Double
        var effectiveRiskPct: Double
        /// The whole thing in three or four sentences, for someone who will not read
        /// the panels below it.
        var summary: String
        /// The rates behind the companion figures, for the record.
        var fx: FXRates
        /// The currency the assessment's prose prints alongside its dollar figures.
        var currency: Currency
    }

    /* ------------------------------------------------------------ the logic */

    /// Months of expenses the stated cash buffer actually covers.
    static func bufferMonths(_ a: Answers) -> Double {
        guard a.monthlyExpenses > 0 else { return a.savingsOutside > 0 ? 6 : 0 }
        return Analysis.clamp(a.savingsOutside / a.monthlyExpenses, 0, 24)
    }

    /// Horizon from the two answers that actually constrain it: when the money might
    /// be needed, and how often the person can look at it. Attention alone never
    /// shortens the horizon below what the money can afford — someone who can watch
    /// all day but needs the money in six months is not a swing trader, they are
    /// someone who should not be taking multi-week risk.
    static func horizon(_ a: Answers) -> TimeHorizon {
        switch a.needWindow {
        case .anyTime:    return .swing
        case .withinYear: return a.attention == .allDay ? .swing : .position
        case .oneToFive:  return a.attention == .allDay && a.purpose == .active ? .swing : .position
        case .fivePlus:   return a.purpose == .active ? .position : .longTerm
        }
    }

    static func goal(_ a: Answers) -> InvestmentGoal {
        if a.purpose == .learn { return .learning }
        if a.dropReaction == .sellAll || a.needWindow == .anyTime { return .preservation }
        if a.purpose == .active { return a.dropReaction == .buyMore ? .speculation : .growth }
        if a.purpose == .grow { return a.dropReaction == .buyMore ? .growth : .income }
        return .growth
    }

    /// The risk-per-trade the answers support, before the suitability cap is even
    /// applied. Experience matters here and nowhere else: it does not change what a
    /// situation can absorb, only how likely the person is to follow the plan.
    static func statedRisk(_ a: Answers) -> Double {
        var base: Double
        switch a.dropReaction {
        case .sellAll: base = 0.5
        case .uncomfortable: base = 0.75
        case .holdOn: base = 1.0
        case .buyMore: base = 1.5
        }
        if a.experience == .none { base = Swift.min(base, 1.0) }
        if a.experience == .experienced { base += 0.25 }
        if a.purpose == .learn { base = Swift.min(base, 1.0) }
        return Analysis.clamp(base, 0.25, 3)
    }

    /**
     * The drawdown the account is actually run to.
     *
     * "I'd buy more" is the right instinct and it requires money to act on. Someone
     * with no income and nothing coming in has none, so the same instinct turns into
     * holding a losing position because selling would confirm it — the limit is what
     * stops that, and it is why this is not simply the answer read back.
     */
    static func drawdownLimit(_ a: Answers) -> Double {
        var limit = a.dropReaction.drawdownPct
        if a.dropReaction == .buyMore && a.income == .none && a.monthlyAdd <= 0 {
            limit = Swift.min(limit, 30)
        }
        if a.needWindow == .anyTime { limit = Swift.min(limit, 15) }
        return limit
    }

    /**
     * The costs this account runs under.
     *
     * Keyed off where the account *is* rather than what it holds, which is the way
     * round that matches reality: a Swedish account buying Apple still pays Swedish
     * courtage on it, is not subject to a US day-trading rule, and owes a flat 30%
     * on the gain whether it held for a week or a decade. Reading the currency the
     * principal thinks in is enough to know that, and it is already detected from
     * the Mac's region, so the right answer arrives without asking a question the
     * setup does not otherwise need.
     */
    static func frictions(_ a: Answers) -> Frictions {
        if a.appetite == .cryptoOnly { return .cryptoExchange }
        // A Nordic account is a percentage-courtage account with a flat capital
        // gains rate, whichever board it trades.
        if a.currency == .sek { return .swedishBroker }
        if a.purpose == .active && a.attention == .allDay { return .activeTrader }
        if a.needWindow == .fivePlus || a.purpose == .grow { return .longTermInvestor }
        return .retailBroker
    }

    /**
     * Which exchanges a new account opens on.
     *
     * Everything, for everyone — the Swedish board is not a Swedish-users-only
     * feature, and a US reader is as entitled to a Stockholm idea as the reverse.
     * It exists as a function rather than a constant so the setup has somewhere to
     * put a narrower default if one is ever warranted.
     */
    static func markets(_ a: Answers) -> [Venue] { Venue.allCases }

    /**
     * The whole assessment. Pure: same answers and same rates give the same result,
     * which is what lets the wizard show a live preview as the questions are answered
     * without the recommendation shifting under the user for reasons they cannot see.
     */
    static func assess(_ a: Answers, fx: FXRates) -> Assessment {
        let h = horizon(a)
        let g = goal(a)
        let buffer = bufferMonths(a)

        var p = Profile.preset(.learner)
        p.id = UUID().uuidString
        p.name = a.name.isEmpty ? defaultName(a) : a.name
        p.note = noteFor(a, goal: g, horizon: h)
        p.currency = a.currency
        p.readingMode = readingMode(a)
        // The mode sets the switch; the switch stays independently changeable after.
        p.plainLanguage = p.readingMode.explains
        // The answers are already in the ledger's currency, so nothing is converted
        // on the way in. That is the whole point of asking in dollars: the number
        // stored is the number typed, and it stays that number when the rate moves.
        p.startingCapital = Swift.max(1, a.amount)
        p.monthlyContribution = Swift.max(0, a.monthlyAdd)
        p.monthlyExpenses = Swift.max(0, a.monthlyExpenses)
        p.emergencyFundMonths = buffer
        p.incomeStability = a.income
        p.goal = g
        p.horizon = h
        p.appetite = a.appetite
        p.frictions = frictions(a)
        p.markets = markets(a)
        p.riskPctPerTrade = statedRisk(a)
        p.drawdownTolerancePct = drawdownLimit(a)
        p.targetAnnualReturnPct = targetReturn(g)
        p.maxOpenPositions = a.experience == .none ? 4 : a.purpose == .grow ? 8 : 6
        p.maxPositionPct = a.appetite == .cryptoOnly ? 25 : a.experience == .none ? 15 : 20
        p.onboarding = a
        p.createdAt = nowMs()

        let flags = check(a, profile: p, fx: fx)
        let recs = recommendations(a, profile: p, fx: fx)

        return Assessment(
            profile: p, flags: flags, recommendations: recs,
            capacity: p.riskCapacity,
            suitableRiskPct: p.suitableRiskPct,
            effectiveRiskPct: p.effectiveRiskPct,
            summary: summarise(a, p, flags: flags, fx: fx),
            fx: fx, currency: a.currency
        )
    }

    /**
     * Where this account opens and how much it explains, from the two answers that
     * decide it. An explicit request for explanation wins over everything else,
     * including an answer of "I've traded actively before" — a stated preference
     * beats one inferred from experience.
     */
    static func readingMode(_ a: Answers) -> ReadingMode {
        if a.explaining == .full { return .guided }
        if a.purpose == .test { return .configurable }
        if a.explaining == .none { return .dense }
        if a.purpose == .active { return .diagnostic }
        return .instrument
    }

    private static func targetReturn(_ g: InvestmentGoal) -> Double {
        switch g {
        case .growth: return 12
        case .income: return 8
        case .preservation: return 5
        case .speculation: return 30
        case .learning: return 10
        }
    }

    private static func defaultName(_ a: Answers) -> String {
        switch a.purpose {
        case .learn: return "My first account"
        case .grow: return "Growing it slowly"
        case .active: return "Active account"
        case .test: return "Testing a method"
        }
    }

    private static func noteFor(_ a: Answers, goal: InvestmentGoal, horizon: TimeHorizon) -> String {
        let when: String
        switch a.needWindow {
        case .anyTime: when = "money that might be needed at short notice"
        case .withinYear: when = "money that could be needed inside a year"
        case .oneToFive: when = "money that can sit for a few years"
        case .fivePlus: when = "money with no call on it for years"
        }
        return "\(goal.label). \(horizon.label.components(separatedBy: " —").first ?? "") horizon, \(when)."
    }

    /* ------------------------------------------------------------- the flags */

    /**
     * Combinations that do not hold together.
     *
     * Each one names the specific mechanism rather than gesturing at risk, because
     * "this is risky" teaches nothing and "the pattern day trader rule will freeze
     * this account after three round trips" teaches the actual constraint.
     */
    static func check(_ a: Answers, profile p: Profile, fx: FXRates) -> [Flag] {
        var flags: [Flag] = []
        let cur = a.currency
        let show = { (usd: Double) in Currency.withCompanion(usd, cur, fx) }
        let buffer = bufferMonths(a)

        // --- the money should not be here at all
        if a.monthlyExpenses > 0 && a.amount > 0 && a.savingsOutside < a.monthlyExpenses * 3 {
            flags.append(Flag(
                id: "thin-buffer",
                severity: a.savingsOutside < a.monthlyExpenses ? .blocking : .serious,
                title: buffer < 1 ? "There is no cash set aside outside this account" : "The cash set aside covers about \(f(buffer, 1)) months",
                body: "Three to six months of expenses held somewhere reachable is the conventional floor before putting any of this money at risk. Position sizes here assume a loss is inconvenient rather than catastrophic. If a bad month means selling positions to pay rent, the sale happens at whatever price the market is at.",
                consequence: p.isRiskCapped
                    ? "The suitability cap holds risk per trade at \(f(p.effectiveRiskPct, 2))% instead of the \(f(p.riskPctPerTrade, 2))% these answers would otherwise support. Nothing is blocked; the figure is smaller and the reason is shown on every trade."
                    : "Risk per trade is already at \(f(p.effectiveRiskPct, 2))%, the floor of the range, so the suitability cap has nothing further to remove."
            ))
        }

        // --- no income and nothing coming in
        if a.income == .none && a.monthlyAdd <= 0 {
            flags.append(Flag(
                id: "no-replenishment", severity: .serious,
                title: "Nothing replaces what this account loses",
                body: "With no income and no monthly contribution, nothing replaces what is lost here. An account that is topped up recovers from a bad run partly through deposits; this one can recover only through trading, using the same method that just lost.",
                consequence: "Risk capacity is computed at \(f(p.riskCapacity, 0))/100 and the per-trade risk is capped accordingly."
            ))
        }

        // --- money needed soon, in a market
        if a.needWindow == .anyTime || a.needWindow == .withinYear {
            flags.append(Flag(
                id: "short-need-window",
                severity: a.needWindow == .anyTime ? .blocking : .serious,
                title: a.needWindow == .anyTime ? "This money might be needed at any time" : "This money could be needed within a year",
                body: "A market can stay down for a year while behaving normally. The S&P 500 has spent multiple stretches below where it was twelve months earlier. Money claimed inside that window may have to be sold during one of those stretches, whatever the analysis said.",
                consequence: "The recommendation shortens the horizon to \(p.horizon.label.components(separatedBy: " —").first ?? "") and sets the objective to \(p.goal.phrase), which raises the reward a setup has to offer before it is funded."
            ))
        }

        // --- would sell everything, yet here for active trading
        if a.dropReaction == .sellAll && (a.purpose == .active || a.appetite == .cryptoOnly) {
            flags.append(Flag(
                id: "reaction-vs-purpose", severity: .serious,
                title: "The plan and the reaction to a drawdown do not match",
                body: "You said a large fall would get you out, and also that you want to trade actively. Active trading produces losing streaks routinely: a method that is right 45% of the time at a 2:1 payoff is a good method and will still lose five in a row. Exiting during a streak ends the method rather than the streak, and the costs paid up to that point return nothing.",
                consequence: "Risk per trade is set at the bottom of the range and the drawdown limit at \(f(p.drawdownTolerancePct, 0))%, which also caps total open risk at \(f(p.maxPortfolioHeatPct, 1))% of equity."
            ))
        }

        // --- the PDT rule
        if a.purpose == .active, p.startingCapital < 25_000, p.frictions.enforcePDT, a.appetite != .cryptoOnly {
            flags.append(Flag(
                id: "pdt", severity: .note,
                title: "Under \(show(25_000)) the pattern day trader rule applies",
                body: "A US margin account under $25,000 is allowed three day trades in any five business days. A fourth freezes the account for ninety days. This is a real rule, enforced here rather than left to be discovered on a real platform.",
                consequence: "A fourth same-session round trip in five business days is refused. Crypto is exempt, which is a real difference rather than an omission."
            ))
        }

        // --- crypto only, preservation
        if a.appetite == .cryptoOnly && (a.dropReaction == .sellAll || a.needWindow == .anyTime) {
            flags.append(Flag(
                id: "crypto-vs-preservation", severity: .serious,
                title: "Crypto only, with money that cannot take a drawdown",
                body: "Bitcoin has had four separate falls of more than 70% from a high, each taking years to recover. Nothing on the equity side of this universe moves like that. Crypto as the only universe, with a short need window or a low tolerance for a fall, makes a forced sale during an ordinary crypto drawdown the likely outcome.",
                consequence: "The volatility ceiling this objective sets refuses most of the crypto universe, so the board will often be nearly empty."
            ))
        }

        // --- a very small account
        if a.monthlyExpenses > 0 && a.amount < a.monthlyExpenses {
            flags.append(Flag(
                id: "tiny-account", severity: .note,
                title: "This is a small amount relative to the monthly costs given",
                body: "At this size the fixed costs matter more than the analysis. A dollar of commission each way is a rounding error on a $10,000 position and a real drag on a $200 one, and a position risking half a percent of the account is too small to move the total.",
                consequence: "Nothing is restricted. The costs panel shows the drag, which at this size is most of the result."
            ))
        }

        // --- everything actually lines up
        if flags.isEmpty {
            flags.append(Flag(
                id: "coherent", severity: .good,
                title: "These answers hold together",
                body: "There is a buffer outside the account, the money has time, and the reaction to a drawdown matches the amount of risk being taken. The settings below are derived from those answers rather than defaulted.",
                consequence: "Risk per trade is set at \(f(p.effectiveRiskPct, 2))% of equity, inside what the situation supports."
            ))
        }

        return flags
    }

    /* --------------------------------------------------- the recommendations */

    /// Where the recommendation differs from a literal reading of the answers, and
    /// why. These are the ones the reality-check screen lets you overrule.
    static func recommendations(_ a: Answers, profile p: Profile, fx: FXRates) -> [Recommendation] {
        var out: [Recommendation] = []

        if p.isRiskCapped {
            out.append(Recommendation(
                id: "risk",
                label: "Risk per trade",
                yours: "\(f(p.riskPctPerTrade, 2))% of the account",
                recommended: "\(f(p.effectiveRiskPct, 2))% of the account",
                why: "Appetite is what you would like to risk; capacity is what your circumstances survive. The engine sizes on the smaller of the two and states which on every trade. Raising the stated figure leaves the cap in place."
            ))
        }

        let literalHorizon: TimeHorizon = a.attention == .allDay ? .swing : a.attention == .daily ? .position : .longTerm
        if literalHorizon != p.horizon {
            out.append(Recommendation(
                id: "horizon",
                label: "How long a trade runs",
                yours: literalHorizon.label,
                recommended: p.horizon.label,
                why: "How often you can look sets how fast a trade can be run. When the money might be needed sets how long a trade can be held. Where the two disagree, the shorter one applies."
            ))
        }

        if a.dropReaction.drawdownPct != p.drawdownTolerancePct {
            out.append(Recommendation(
                id: "drawdown",
                label: "Drawdown limit",
                yours: "\(f(a.dropReaction.drawdownPct, 0))%",
                recommended: "\(f(p.drawdownTolerancePct, 0))%",
                why: a.needWindow == .anyTime
                    ? "Money that could be called on at any time cannot sit through a long fall. A tighter limit holds less at risk across every position at once, so a bad stretch does not force a sale."
                    : "Buying into a fall requires cash to buy with. With no income behind the account there is none, so the position is held rather than added to. The limit is what bounds that."
            ))
        }

        if a.experience == .none && p.maxOpenPositions > 4 {
            out.append(Recommendation(
                id: "positions",
                label: "How many positions at once",
                yours: "\(p.maxOpenPositions)",
                recommended: "4",
                why: "Four is enough to see how a basket behaves and few enough to know why each one is there. Positions in one sector do not diversify, and more of them makes it harder to identify which decision mattered."
            ))
        }

        if a.appetite == .both && a.experience == .none {
            out.append(Recommendation(
                id: "universe",
                label: "What can be traded",
                yours: "Equities and crypto",
                recommended: "Equities and crypto, with the volatility ceiling on",
                why: "Nothing is removed. The objective sets a ceiling on how much an instrument may move on an average day, which refuses the most volatile crypto names and leaves the rest available, each with a stated reason."
            ))
        }

        return out
    }

    /* ------------------------------------------------------------ the summary */

    static func summarise(_ a: Answers, _ p: Profile, flags: [Flag], fx: FXRates) -> String {
        let cur = a.currency
        let capital = Currency.withCompanion(p.startingCapital, cur, fx)
        let risk = Currency.withCompanion(p.startingCapital * p.effectiveRiskPct / 100, cur, fx)
        let serious = flags.filter { $0.severity == .blocking || $0.severity == .serious }

        var lines: [String] = []
        lines.append("You are starting with \(capital) of simulated money, held to a \(p.horizon.label.components(separatedBy: " —").first?.lowercased() ?? "") horizon, with \(p.goal.phrase) as the objective.")
        lines.append("Each trade will risk about \(risk), \(f(p.effectiveRiskPct, 2))% of the account. Position size is worked backwards from that figure rather than from the amount invested.")
        if p.isRiskCapped {
            lines.append("That is below the \(f(p.riskPctPerTrade, 2))% these answers asked for, because your circumstances cap it: risk capacity comes out at \(f(p.riskCapacity, 0)) out of 100.")
        }
        if serious.isEmpty {
            lines.append("Nothing in the answers contradicts anything else.")
        } else {
            lines.append("There \(serious.count == 1 ? "is one thing" : "are \(serious.count) things") to read below before starting: \(serious.map { $0.title.lowercased() }.joined(separator: "; ")).")
        }
        return lines.joined(separator: " ")
    }
}

extension Currency {
    /// Money in this currency, for prose. The interface has its own formatter; this
    /// one exists so the Swift-side explanations quote the same figures — grouped,
    /// because "50000 kr" in the middle of a sentence reads as a serial number.
    static func format(_ amount: Double, _ currency: Currency) -> String {
        let n = grouped.string(from: NSNumber(value: amount.rounded())) ?? f(amount, 0)
        return currency.symbolTrails ? "\(n) \(currency.symbol)" : "\(currency.symbol)\(n)"
    }

    /**
     * A dollar figure with the reading currency in brackets after it.
     *
     * The dollar amount always comes first and is always the real one; the second
     * figure is a translation and is written so it cannot be mistaken for anything
     * else. When the two currencies are the same there is no second figure, because
     * printing "$10,000 ($10,000)" is the kind of detail that makes a person stop
     * trusting the rest of the sentence.
     */
    static func withCompanion(_ usd: Double, _ home: Currency, _ fx: FXRates) -> String {
        let dollars = format(usd, .usd)
        guard home.needsCompanion else { return dollars }
        return "\(dollars) (≈ \(format(fx.fromUSD(usd, home), home)))"
    }

    private static let grouped: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        nf.groupingSeparator = "\u{202F}"   // a narrow space, which reads in every locale here
        return nf
    }()
}
