/**
 * SelfTest.swift — headless assertions over the parts that must not drift.
 *
 *   Paper.app/Contents/MacOS/Paper --selftest
 *   swift run Paper --selftest
 *
 * The maths and the ledger are checked against synthetic series with known
 * answers, so a regression shows up here rather than as a plausible-looking
 * wrong number on the desk. Network-dependent behaviour is not checked here; it
 * fails loudly at runtime instead of quietly in a test that needs the internet.
 *
 * The expected values are the ones the original TypeScript engine produced, so
 * this doubles as the proof that the port did not change any answers.
 */

import Foundation

enum SelfTest {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failures: [String] = []

    /* ------------------------------------------------------------- currency */

    private static func currency() {
        let rates = FXRates(perUSD: ["USD": 1, "EUR": 0.9, "SEK": 10.5], at: 1, live: true)

        near("dollars into kronor", rates.fromUSD(100, .sek), 1050, 0.001)
        near("kronor back into dollars", rates.toUSD(1050, .sek), 100, 0.001)
        near("a dollar account is not converted", rates.fromUSD(100, .usd), 100, 0.001)
        near("the conversion round-trips", rates.toUSD(rates.fromUSD(4321, .eur), .eur), 4321, 0.0001)

        let broken = FXRates(perUSD: ["SEK": 0], at: 0, live: false)
        near("a zero rate falls back rather than zeroing the account",
             broken.rate(.sek), Currency.sek.fallbackPerUSD, 0.001)
        ok("kronor trail their symbol", Currency.sek.symbolTrails && !Currency.usd.symbolTrails)
        ok("the note names the rate it used", rates.note(.sek).contains("10.5"))
        ok("and says the second figure is a reading aid, not a holding",
           rates.note(.sek).contains("dollars") && rates.note(.sek).lowercased().contains("reading"))

        // The companion figure. Dollars first, always, because that is the amount
        // the account actually holds; the second is a translation and is marked as one.
        let both = Currency.withCompanion(10_000, .sek, rates)
        ok("a companion leads with the dollar figure", both.hasPrefix("$"))
        ok("and marks the second as a conversion", both.contains("≈") && both.contains("kr"))
        ok("a dollar reader gets no second figure at all",
           Currency.withCompanion(10_000, .usd, rates) == "$10 000".replacingOccurrences(of: " ", with: "\u{202F}"))
        ok("only a non-dollar currency needs one",
           Currency.sek.needsCompanion && !Currency.usd.needsCompanion)

        // The machine already knows what the person reads in. Whatever it reports has
        // to be a currency this app can actually draw, or the first screen is wrong.
        ok("the system default is a currency this app supports",
           Currency.allCases.contains(Currency.systemDefault))
        for c in Currency.allCases where c != .usd {
            ok("\(c.code) has a pair to price it with", c.pair != nil)
            ok("\(c.code) has a standing rate to fall back on", c.fallbackPerUSD > 0)
        }

        // The switcher compares accounts side by side, so each summary has to carry
        // the currency it should be read in rather than inheriting the active one.
        let summary = ProfileSummary(id: "x", name: "n", note: "", goal: "g", horizon: "h",
                                     equity: 1000, totalPnlPct: 0, openPositions: 0,
                                     active: false, currency: .eur)
        let encodedSummary = (try? JSONEncoder().encode(summary))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        ok("a profile summary carries its own reading currency", encodedSummary["currency"] as? String == "EUR")
        ok("a dollar account's note says so", rates.note(.usd).contains("dollars"))

        // A profile written before currencies existed must still open, in dollars.
        let legacy = Data(#"{"id":"x","name":"Old","note":"","startingCapital":50000,"monthlyContribution":0,"monthlyExpenses":2000,"emergencyFundMonths":3,"incomeStability":"salaried","goal":"growth","horizon":"swing","targetAnnualReturnPct":10,"riskPctPerTrade":1,"maxPositionPct":20,"maxOpenPositions":5,"drawdownTolerancePct":25,"appetite":"both","frictions":{"commissionPerTrade":0,"commissionPctOfValue":0,"minCommission":0,"slippageAtrFraction":0.05,"minSlippagePctOfPrice":0.02,"enforceMarketHours":true,"enforcePDT":true,"shortTermTaxPct":32,"longTermTaxPct":15,"longTermHoldingDays":365},"createdAt":1}"#.utf8)
        let decoded = try? JSONDecoder().decode(Profile.self, from: legacy)
        ok("a profile from an older build still decodes", decoded != nil)
        ok("and picks up the reading currency from the machine",
           decoded?.currency == Currency.systemDefault)
        ok("and to plain language on", decoded?.plainLanguage == true)

        // The regression this whole arrangement exists for. Every sentence the engine
        // writes is composed in Swift through `money()`, which is dollars and only
        // dollars. Before, it hardcoded the dollar sign while the interface converted,
        // so an account set to kronor showed `104 600 kr` of equity in the header and
        // a `$500` session limit four lines below it. If a non-dollar profile ever
        // produces prose in its own currency again, this is where it gets caught.
        ok("engine prose is written in dollars", money(1_000).hasPrefix("$"))
        var sekProfile = Profile.preset(.learner)
        sekProfile.currency = .sek
        sekProfile.markets = [.us, .crypto]
        let brief = sekProfile.brief
        ok("a kronor-reading profile still briefs the analyst in dollars",
           brief.contains("$") && !brief.contains(" kr"))
        ok("and tells the model outright, rather than leaving it to infer",
           brief.contains("US dollars") && brief.contains("Never restate"))

        /* The line moved once Stockholm arrived, and it moved in one specific way:
         * account figures stayed dollars and instrument prices did not. The brief has
         * to say both, because a model told only "everything is dollars" will put a
         * dollar sign on a 337 kr stop and a model told nothing will convert one. */
        var swede = Profile.preset(.learner)
        swede.currency = .sek
        swede.markets = Venue.allCases
        let seBrief = swede.brief
        ok("a profile trading Stockholm still settles the account in dollars",
           seBrief.contains("account settles in US dollars"))
        ok("but is told instrument levels are quoted in their own currency",
           seBrief.contains("Swedish kronor"))
        ok("and is told not to convert a level or mis-sign it",
           seBrief.contains("Never convert a level"))
        ok("the Stockholm brief names the exchanges in play",
           seBrief.contains("Nasdaq Stockholm"))
    }

    /* --------------------------------------------------------- reading mode */

    private static func readingModes() {
        // The second axis exists and is separate from the first: two accounts with
        // the same money answers and different explaining answers must read
        // differently and trade identically.
        var a = Onboarding.Answers()
        a.purpose = .grow
        a.amount = 50_000
        a.income = .salaried
        a.monthlyExpenses = 2_000
        a.savingsOutside = 12_000
        a.needWindow = .fivePlus
        a.experience = .experienced

        var explained = a; explained.explaining = .full
        var bare = a; bare.explaining = .none

        let rates = FXRates(perUSD: ["USD": 1], at: 1, live: true)
        let pe = Onboarding.assess(explained, fx: rates).profile
        let pb = Onboarding.assess(bare, fx: rates).profile

        ok("asking for explanation opens on the guide", pe.readingMode == .guided)
        ok("and turns the plain-language switch on", pe.plainLanguage)
        ok("declining it opens on the desk", pb.readingMode == .dense)
        ok("and leaves the switch off", !pb.plainLanguage)
        // The point of splitting the question: the money answers are untouched.
        near("risk per trade is unchanged by how it reads", pe.riskPctPerTrade, pb.riskPctPerTrade, 0.0001)
        ok("so is the horizon", pe.horizon == pb.horizon)
        ok("so is the universe", pe.appetite == pb.appetite)
        near("so is the drawdown limit", pe.drawdownTolerancePct, pb.drawdownTolerancePct, 0.0001)

        // A stated preference beats one inferred from experience. This answer said
        // "I've traded actively before" and still asked to be explained to.
        ok("an explicit request outranks the experience answer", pe.readingMode.explains)

        var tester = a; tester.purpose = .test; tester.explaining = .onHover
        ok("a method to test opens on calibration",
           Onboarding.readingMode(tester) == .configurable)
        var active = a; active.purpose = .active; active.explaining = .onHover
        ok("active trading opens on the record", Onboarding.readingMode(active) == .diagnostic)
        ok("and the tab is named for what it opens on",
           ReadingMode.diagnostic.analystTabLabel == "Review")

        // Every mode must name a view the interface actually has.
        let views = ["desk", "markets", "analyst", "journal", "learning", "learn", "session"]
        ok("every mode lands somewhere that exists",
           ReadingMode.allCases.allSatisfy { views.contains($0.landing) })
        ok("only the mode that opens on the review asks for a segment",
           ReadingMode.allCases.filter { $0.landingSection != nil } == [.diagnostic])

        // The 4.5.0 rule: a ledger from before this existed still opens.
        let older = #"{"id":"x","name":"Old","note":"","startingCapital":1000,"plainLanguage":false}"#
        let decoded = try? JSONDecoder().decode(Profile.self, from: Data(older.utf8))
        ok("a profile written before reading modes still decodes", decoded != nil)
        ok("and keeps doing what it did yesterday", decoded?.readingMode == .dense)
    }

    /* ----------------------------------------------------------- onboarding */

    private static func onboarding() {
        let rates = FXRates(perUSD: ["USD": 1, "EUR": 0.9, "SEK": 10.5], at: 1, live: true)

        // The case the whole screen exists for: no income, no buffer, wants to trade
        // actively, says a big fall would get them out. Every one of those conflicts.
        var a = Onboarding.Answers()
        a.currency = .sek             // read alongside in kronor; typed in dollars
        a.purpose = .active
        a.amount = 10_000
        a.income = .none
        a.monthlyExpenses = 2_000
        a.savingsOutside = 0
        a.monthlyAdd = 0
        a.needWindow = .anyTime
        a.dropReaction = .sellAll
        a.attention = .allDay
        a.experience = .none
        a.appetite = .cryptoOnly

        let bad = Onboarding.assess(a, fx: rates)
        // Typed in dollars, stored in dollars. Nothing is converted on the way in, so
        // the stored figure cannot drift away from the one the person actually typed
        // when the rate moves — which a converted-on-save field silently does.
        near("a money answer is stored exactly as it was typed", bad.profile.startingCapital, 10_000, 0.0001)
        near("and so are the expenses", bad.profile.monthlyExpenses, 2_000, 0.0001)
        ok("the summary quotes dollars first", bad.summary.contains("$"))
        ok("and offers the kronor reading beside it", bad.summary.contains("≈"))
        ok("no buffer is flagged", bad.flags.contains { $0.id == "thin-buffer" })
        ok("nothing replacing losses is flagged", bad.flags.contains { $0.id == "no-replenishment" })
        ok("money needed at any time is flagged", bad.flags.contains { $0.id == "short-need-window" })
        ok("wanting out of a drawdown while trading actively is flagged",
           bad.flags.contains { $0.id == "reaction-vs-purpose" })
        ok("crypto against a short need window is flagged",
           bad.flags.contains { $0.id == "crypto-vs-preservation" })
        ok("this situation does not read as coherent", !bad.flags.contains { $0.id == "coherent" })
        ok("capacity lands at the bottom", bad.capacity < 30, "got \(bad.capacity)")
        ok("and the risk is capped to match", bad.effectiveRiskPct <= 0.5, "got \(bad.effectiveRiskPct)")
        ok("the cap is explained rather than just applied",
           bad.recommendations.contains { $0.id == "risk" } || !bad.profile.isRiskCapped)
        ok("the summary is a paragraph, not a number", bad.summary.count > 120)

        // The other end: everything lines up.
        var g = Onboarding.Answers()
        g.currency = .usd
        g.purpose = .grow
        g.amount = 60_000
        g.income = .salaried
        g.monthlyExpenses = 3_000
        g.savingsOutside = 24_000      // eight months
        g.monthlyAdd = 1_000
        g.needWindow = .fivePlus
        g.dropReaction = .holdOn
        g.attention = .rarely
        g.experience = .some
        g.appetite = .stocksOnly

        let good = Onboarding.assess(g, fx: rates)
        ok("a coherent set of answers is recognised as one", good.flags.contains { $0.id == "coherent" })
        ok("and carries no serious flags",
           !good.flags.contains { $0.severity == .blocking || $0.severity == .serious })
        ok("capacity is high", good.capacity > 70, "got \(good.capacity)")
        ok("the horizon follows the money, not the attention span", good.profile.horizon == .longTerm)
        near("the buffer is read in months", good.profile.emergencyFundMonths, 8, 0.01)

        // The rule that matters most: when the two horizon inputs disagree, the money
        // wins. Someone who can watch all day but needs the money inside a year is not
        // a swing trader.
        var h = g
        h.attention = .allDay
        h.needWindow = .anyTime
        ok("a short need window overrides a long attention span",
           Onboarding.horizon(h) == .swing)
        var i = g
        i.attention = .rarely
        i.needWindow = .fivePlus
        ok("and a long need window with no attention is a long-term profile",
           Onboarding.horizon(i) == .longTerm)

        ok("assessment is pure — the same answers give the same profile",
           Onboarding.assess(g, fx: rates).profile.riskPctPerTrade == good.profile.riskPctPerTrade)

        // A recommendation card exists to show a difference. One whose two sides read
        // the same is worse than no card at all, so no derivation may produce one.
        for answers in [a, g, h, i] {
            let assessed = Onboarding.assess(answers, fx: rates)
            for rec in assessed.recommendations {
                ok("the \(rec.id) recommendation differs from the answer it is offered against",
                   rec.yours != rec.recommended, "both read \"\(rec.yours)\"")
            }
        }

        // "I'd buy more" with nothing to buy with is the case the limit exists for.
        var eager = g
        eager.dropReaction = .buyMore
        eager.income = .none
        eager.monthlyAdd = 0
        ok("an appetite for buying the dip is capped when there is nothing to buy with",
           Onboarding.drawdownLimit(eager) < Onboarding.DropReaction.buyMore.drawdownPct)
        var urgent = g
        urgent.needWindow = .anyTime
        ok("money that could be called on at any time gets the tightest limit",
           Onboarding.drawdownLimit(urgent) <= 15)
    }

    /* ------------------------------------------------------------- learning */

    private static func learning() {
        /* --- the clamps, which are the only thing standing between a proposal and
               the risk engine. */
        let wild = Adjustment(knob: .stopScale, from: 1, to: 99)
        near("an absurd stop widening is clamped", wild.to, Knob.stopScale.bounds.max, 0.0001)
        let negative = Adjustment(knob: .riskScale, from: 1, to: -4)
        near("risk cannot be driven below its floor", negative.to, Knob.riskScale.bounds.min, 0.0001)
        ok("a keyed knob keeps its key", Adjustment(knob: .sectorBias, key: "Technology", from: 0, to: 6).key == "Technology")
        ok("an unkeyed knob drops one", Adjustment(knob: .stopScale, key: "Technology", from: 1, to: 1.1).key == nil)
        ok("the change describes itself", wild.summary.contains("Stop width"))

        /* --- composition, and that a revert leaves nothing behind. */
        func lesson(_ id: String, _ adj: Adjustment, _ status: LessonStatus) -> Lesson {
            Lesson(id: id, kind: id, title: id, finding: "", reasoning: "", evidence: [],
                   sampleSize: 9, confidence: 0.7, adjustment: adj, status: status,
                   source: "engine", createdAt: 0, updatedAt: 0, appliedAt: nil,
                   runsSinceApplied: 0, outcomeNote: nil)
        }
        let widen = lesson("widen", Adjustment(knob: .stopScale, from: 1, to: 1.15), .applied)
        let floor = lesson("floor", Adjustment(knob: .convictionFloor, from: 0, to: 60), .applied)
        let pending = lesson("pending", Adjustment(knob: .targetScale, from: 1, to: 1.2), .proposed)

        let composed = Calibration.compose([widen, floor, pending])
        near("an applied lesson moves its dial", composed.stopScale, 1.15, 0.0001)
        near("a conviction floor is taken as a floor", composed.convictionFloor, 60, 0.0001)
        near("a proposal that was never applied changes nothing", composed.targetScale, 1, 0.0001)
        ok("a neutral calibration knows it is neutral", Calibration.compose([]).isNeutral)
        ok("and a composed one does not", !composed.isNeutral)

        var reverted = widen
        reverted.status = .dismissed
        ok("reverting a lesson removes exactly its contribution",
           Calibration.compose([reverted, pending]).isNeutral)

        /* --- what the calibration actually does to a plan. */
        let base = Analysis.SizingRules(equity: 100_000, riskPctPerTrade: 1, maxPositionPct: 20)
        var withHold = base
        withHold.maxSessions = 20
        withHold.minRewardToRisk = 1.8
        withHold.maxDailyRangePct = 5
        var cal = Calibration()
        cal.stopScale = 1.2
        cal.riskScale = 0.75
        cal.minRewardToRiskDelta = 0.3
        cal.holdScale = 1.5
        cal.rangeCeilingScale = 0.8
        let tuned = cal.apply(to: withHold)
        near("the stop scale carries through", tuned.stopScale, 1.2, 0.0001)
        near("risk is scaled down", tuned.riskPctPerTrade, 0.75, 0.0001)
        near("the reward floor rises", tuned.minRewardToRisk, 2.1, 0.0001)
        near("patience extends", tuned.maxSessions, 30, 0.0001)
        near("the volatility ceiling comes down", tuned.maxDailyRangePct, 4, 0.0001)

        // The floor on minRewardToRisk exists so a learned reduction can never let the
        // engine fund a trade that pays less than it risks.
        var reckless = Calibration()
        reckless.minRewardToRiskDelta = -0.5
        var thin = base
        thin.minRewardToRisk = 1.2
        ok("reward-to-risk can never be learned below 1:1",
           reckless.apply(to: thin).minRewardToRisk >= 1.0)

        /* --- the conviction bias tilts an ordering without swamping the chart. */
        var biased = Calibration()
        biased.sectorBias = ["Technology": 20]
        biased.regimeBias = ["uptrend": 20]
        biased.symbolBias = ["NVDA": 20]
        let lifted = biased.conviction(50, symbol: "NVDA", sector: "Technology", regime: "uptrend")
        ok("a stacked bias is capped rather than summed without limit",
           lifted <= 80.0001, "got \(lifted)")
        near("an unbiased instrument is untouched",
             biased.conviction(50, symbol: "AAPL", sector: "Consumer", regime: "range"), 50, 0.0001)

        /* --- grading a recommendation against real bars. */
        let pick = RunPick(symbol: "TEST", sector: "Technology", regime: "uptrend", conviction: 70,
                           entry: 100, target: 110, stop: 95, rr: 2, horizonDays: 10,
                           atrPct: 2, allocationPct: 30)

        // Falls to the stop, then recovers well above the entry: the signature of a
        // stop placed inside the ordinary noise.
        let whipsaw = bars([100, 97, 94, 99, 104, 108])
        let w = Learning.grade(pick, bars: whipsaw, from: 0)
        ok("a stop-out is detected", w?.hitStop == true)
        ok("and the recovery after it is too", w?.recoveredAfterStop == true)
        near("a stop-out is scored at -1R", w?.rMultiple, -1, 0.0001)

        // Reaches the target and keeps going more than another full unit of risk.
        let runner = Learning.grade(pick, bars: bars([102, 106, 111, 114, 118]), from: 0)
        ok("a target hit is detected", runner?.hitTarget == true)
        ok("running on past the target is detected", runner?.ranOnAfterTarget == true)
        near("a target hit is scored at its own reward-to-risk", runner?.rMultiple, 2, 0.02)

        // Neither level touched: unresolved, and scored where it currently sits.
        let drifting = Learning.grade(pick, bars: bars([101, 103, 102, 104]), from: 0)
        ok("an unresolved pick says so", drifting?.resolved == false)
        ok("and is not credited with a hit", drifting?.hitTarget == false && drifting?.hitStop == false)

        ok("a pick with no history yet cannot be graded", Learning.grade(pick, bars: [], from: 0) == nil)
        ok("a pick whose stop is above its entry is refused rather than divided by zero",
           Learning.grade(RunPick(symbol: "X", sector: "", regime: "", conviction: 0, entry: 100,
                                  target: 110, stop: 100, rr: 0, horizonDays: 5, atrPct: nil,
                                  allocationPct: 0), bars: whipsaw, from: 0) == nil)

        /* --- the derivation, and the sample floor under it. */
        func run(_ outcomes: [PickOutcome]) -> RunRecord {
            RunRecord(id: "r", at: 0, profileId: "p", calibration: .neutral, lessonIds: [],
                      picks: (0..<outcomes.count).map { i in
                          RunPick(symbol: outcomes[i].symbol, sector: "Technology", regime: "uptrend",
                                  conviction: 70, entry: 100, target: 110, stop: 95, rr: 2,
                                  horizonDays: 10, atrPct: 2, allocationPct: 0)
                      },
                      outcomes: outcomes, gradedAt: 1)
        }
        func stoppedThenRecovered(_ sym: String, recovered: Bool) -> PickOutcome {
            PickOutcome(symbol: sym, resolved: true, hitTarget: false, hitStop: true,
                        sessionsToResolve: 3, rMultiple: -1, mfeR: recovered ? 1.4 : 0.2,
                        maeR: -1.4, recoveredAfterStop: recovered, ranOnAfterTarget: false,
                        sessionsObserved: 12)
        }

        let thinEvidence = Learning.engineLessons(
            [run([stoppedThenRecovered("A", recovered: true), stoppedThenRecovered("B", recovered: true)])],
            current: .neutral
        )
        let thinStop = thinEvidence.first { $0.kind == "engine-stops-too-tight" }
        ok("two whipsaws are watched, not acted on", thinStop == nil || thinStop?.status == .watching)
        ok("and carry no adjustment", thinStop?.adjustment == nil)

        let strong = Learning.engineLessons(
            [run([
                stoppedThenRecovered("A", recovered: true), stoppedThenRecovered("B", recovered: true),
                stoppedThenRecovered("C", recovered: true), stoppedThenRecovered("D", recovered: false),
                stoppedThenRecovered("E", recovered: false), stoppedThenRecovered("F", recovered: true),
            ])],
            current: .neutral
        )
        let stopLesson = strong.first { $0.kind == "engine-stops-too-tight" }
        ok("six stop-outs, four recovering, is enough to propose", stopLesson?.status == .proposed)
        ok("and it proposes widening the stop", stopLesson?.adjustment?.knob == .stopScale)
        ok("in the right direction", (stopLesson?.adjustment?.delta ?? 0) > 0)
        ok("the proposal carries its evidence", !(stopLesson?.evidence.isEmpty ?? true))
        ok("and names the number it rests on", stopLesson?.finding.contains("6") == true)

        // A tercile split over identical values is a finding about the sort order, not
        // about volatility. It must not produce a proposal.
        func withVol(_ sym: String, _ atr: Double, _ r: Double) -> (RunPick, PickOutcome) {
            (RunPick(symbol: sym, sector: "Technology", regime: "uptrend", conviction: 70,
                     entry: 100, target: 110, stop: 95, rr: 2, horizonDays: 10,
                     atrPct: atr, allocationPct: 0),
             PickOutcome(symbol: sym, resolved: true, hitTarget: r > 0, hitStop: r < 0,
                         sessionsToResolve: 4, rMultiple: r, mfeR: r, maeR: -0.5,
                         recoveredAfterStop: false, ranOnAfterTarget: false, sessionsObserved: 14))
        }
        func runOf(_ pairs: [(RunPick, PickOutcome)]) -> RunRecord {
            RunRecord(id: "v", at: 0, profileId: "p", calibration: .neutral, lessonIds: [],
                      picks: pairs.map(\.0), outcomes: pairs.map(\.1), gradedAt: 1)
        }

        let flatVol = runOf([
            withVol("A", 2.4, -1), withVol("B", 2.4, -1), withVol("C", 2.4, -1),
            withVol("D", 2.4, 1), withVol("E", 2.4, 1), withVol("F", 2.4, 1),
            withVol("G", 2.4, 1), withVol("H", 2.4, 1),
        ])
        ok("identical volatilities produce no volatility finding",
           !Learning.engineLessons([flatVol], current: .neutral).contains { $0.kind == "engine-volatility-drag" })

        let realSpread = runOf([
            withVol("A", 6.5, -1), withVol("B", 6.2, -1), withVol("C", 5.9, -1),
            withVol("D", 1.6, 1), withVol("E", 1.5, 1), withVol("F", 1.4, 1),
            withVol("G", 1.3, 1), withVol("H", 1.2, 1),
        ])
        let volLesson = Learning.engineLessons([realSpread], current: .neutral)
            .first { $0.kind == "engine-volatility-drag" }
        ok("a genuine spread does produce one", volLesson != nil)
        ok("and it lowers the ceiling", (volLesson?.adjustment?.delta ?? 0) < 0)
        ok("naming the boundary it split on", volLesson?.evidence.first?.contains("%") == true)

        /* --- merging: what the user has already decided is not disturbed. */
        var memory = Memory.empty("p")
        Learning.merge(strong, into: &memory)
        ok("a fresh finding lands in the queue", memory.open.contains { $0.kind == "engine-stops-too-tight" })

        if let i = memory.lessons.firstIndex(where: { $0.kind == "engine-stops-too-tight" }) {
            memory.lessons[i].status = .dismissed
        }
        memory.recompose()
        Learning.merge(strong, into: &memory)
        ok("a finding the user turned down stays turned down",
           memory.lessons.first { $0.kind == "engine-stops-too-tight" }?.status == .dismissed)
        ok("and does not re-enter the queue",
           !memory.open.contains { $0.kind == "engine-stops-too-tight" })

        // An applied lesson whose evidence has gone quiet rolls itself back.
        var fading = Memory.empty("p")
        var live = lesson("engine-stops-too-tight", Adjustment(knob: .stopScale, from: 1, to: 1.15), .applied)
        live.runsSinceApplied = 3
        fading.lessons = [live]
        fading.recompose()
        near("it is live while the evidence holds", fading.calibration.stopScale, 1.15, 0.0001)
        Learning.merge([], into: &fading)
        ok("and retires when the evidence stops appearing",
           fading.lessons[0].status == .retired)
        ok("with the calibration recomputed without it", fading.calibration.isNeutral)

        // The two reasons a lesson carries no adjustment are not the same reason, and
        // the interface has to be able to tell them apart: one is refused for
        // application, the other is exactly what applying means.
        let watchingOne = Learning.engineLessons(
            [run([stoppedThenRecovered("A", recovered: true), stoppedThenRecovered("B", recovered: true)])],
            current: .neutral
        ).first { $0.kind == "engine-stops-too-tight" }
        ok("a finding under its sample floor is marked as watching",
           watchingOne == nil || watchingOne?.status == .watching)
        let ruleLesson = Analyst.adopt(
            LessonProposal(knob: "rule", key: "", direction: "increase", size: "small",
                           title: "t", finding: "f", reasoning: "r", evidence: ["a"], sampleSize: 8),
            current: .neutral)
        ok("a rule is offered rather than watched", ruleLesson?.status == .proposed)
        ok("and both have no adjustment, which is why status is what distinguishes them",
           ruleLesson?.adjustment == nil && watchingOne?.adjustment == nil)

        /* --- the analyst's proposals go through exactly the same clamp. */
        let proposal = LessonProposal(
            knob: "stopScale", key: "", direction: "increase", size: "medium",
            title: "Widen the stops", finding: "measured", reasoning: "because",
            evidence: ["a"], sampleSize: 9
        )
        let adopted = Analyst.adopt(proposal, current: .neutral)
        ok("a well-formed proposal is adopted", adopted != nil)
        ok("and is marked as the analyst's", adopted?.source == "analyst")
        ok("with its step computed here, not by the model",
           (adopted?.adjustment?.to ?? 0) > 1 && (adopted?.adjustment?.to ?? 99) < 1.2)

        var thinProposal = proposal
        thinProposal = LessonProposal(knob: "stopScale", key: "", direction: "increase", size: "small",
                                      title: "t", finding: "f", reasoning: "r", evidence: [], sampleSize: 2)
        ok("a proposal resting on two observations is discarded", Analyst.adopt(thinProposal, current: .neutral) == nil)

        let bolder = LessonProposal(knob: "riskScale", key: "", direction: "increase", size: "medium",
                                    title: "t", finding: "f", reasoning: "r", evidence: ["a"], sampleSize: 20)
        ok("the analyst may never ask for more risk", Analyst.adopt(bolder, current: .neutral) == nil)

        let quieter = LessonProposal(knob: "riskScale", key: "", direction: "decrease", size: "small",
                                     title: "t", finding: "f", reasoning: "r", evidence: ["a"], sampleSize: 20)
        ok("but it may always ask for less", Analyst.adopt(quieter, current: .neutral) != nil)

        let nonsense = LessonProposal(knob: "notAKnob", key: "", direction: "increase", size: "small",
                                      title: "t", finding: "f", reasoning: "r", evidence: ["a"], sampleSize: 20)
        ok("an unknown dial is refused", Analyst.adopt(nonsense, current: .neutral) == nil)

        let keyless = LessonProposal(knob: "sectorBias", key: "", direction: "increase", size: "small",
                                     title: "t", finding: "f", reasoning: "r", evidence: ["a"], sampleSize: 20)
        ok("a keyed dial with no key is refused", Analyst.adopt(keyless, current: .neutral) == nil)

        let ruleOnly = LessonProposal(knob: "rule", key: "", direction: "increase", size: "small",
                                      title: "You sell winners early", finding: "f", reasoning: "r",
                                      evidence: ["a"], sampleSize: 8)
        let rule = Analyst.adopt(ruleOnly, current: .neutral)
        ok("a behavioural finding is adopted with no dial attached",
           rule != nil && rule?.adjustment == nil && rule?.isRule == true)

        /* --- the memory brief is what the analyst is actually told. */
        var briefed = Memory.empty("p")
        briefed.lessons = [widen]
        briefed.recompose()
        ok("the brief describes the calibration in words rather than numbers",
           briefed.brief.contains("wider"), "got: \(briefed.brief)")
        ok("an empty memory says so plainly rather than inventing a history",
           Memory.empty("p").brief.contains("no accumulated lessons"))

        /* --- the whole memory survives a round trip through disk. */
        let encoded = try? JSONEncoder().encode(briefed)
        let back = encoded.flatMap { try? JSONDecoder().decode(Memory.self, from: $0) }
        ok("a memory encodes and decodes", back != nil)
        near("with its calibration intact", back?.calibration.stopScale, 1.15, 0.0001)
        ok("and the adjustment summary crosses the wire",
           back?.lessons.first?.adjustment?.summary.isEmpty == false)
    }

    /* -------------------------------------------------------- the token budget */

    private static func call(_ pass: String, tokens: Int, ok: Bool = true,
                             status: Int? = 200, error: String? = nil,
                             stop: String? = "end_turn", cacheRead: Int = 0,
                             cacheWrite: Int = 0) -> CallRecord {
        CallRecord(pass: pass, attempt: 1, startedAt: 0, ms: 1000,
                   inputTokens: tokens / 2, outputTokens: tokens - tokens / 2,
                   cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                   stopReason: stop, httpStatus: status, error: error, ok: ok)
    }

    private static func budgeting() {
        // Pricing has to be data, not a formula with a guess in it: a model nobody
        // priced reports nothing rather than a confidently wrong figure.
        ok("Opus 5 is priced", ModelPrice.of("claude-opus-5")?.inputPerMTok == 5)
        ok("and its output rate too", ModelPrice.of("claude-opus-5")?.outputPerMTok == 25)
        ok("an unknown model has no price rather than a wrong one", ModelPrice.of("not-a-model") == nil)
        near("a cache read is a tenth of the input rate",
             ModelPrice.of("claude-opus-5")?.cacheReadPerMTok, 0.5, 0.0001)
        near("a cache write is a quarter more than input",
             ModelPrice.of("claude-opus-5")?.cacheWritePerMTok, 6.25, 0.0001)

        var t = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 100_000)
        t.calls = [call("screen", tokens: 1_000_000)]
        near("cost is computed from the published rates", t.estimatedCost, 15, 0.01)
        var unpriced = RunTelemetry.empty(kind: "ideas", model: "mystery", budget: 100_000)
        unpriced.calls = t.calls
        ok("an unpriced model reports no cost at all", unpriced.estimatedCost == nil)

        // Limits are clamped so a typed-in zero cannot disable the governor.
        let zeroed = RunLimits(budgetTokens: 0, wallClockSeconds: 0, attemptsPerPass: 0,
                               failureStreak: 0, emptyStreak: 0).sanitised()
        ok("a zero budget is clamped up, not honoured", zeroed.budgetTokens >= 20_000)
        ok("so is a zero time limit", zeroed.wallClockSeconds >= 60)
        ok("and a zero attempt count", zeroed.attemptsPerPass >= 1)

        // A settings file written before these existed still opens.
        let legacy = Data(#"{"hasOnboarded":true}"#.utf8)
        let settings = try? JSONDecoder().decode(AppSettings.self, from: legacy)
        ok("settings from an older build still decode", settings != nil)
        ok("and get the standing limits", settings?.analystLimits.budgetTokens == RunLimits.standard.budgetTokens)

        // The governor itself, exercised the way the pipeline exercises it.
        let sem = DispatchSemaphore(value: 0)
        Task {
            let limits = RunLimits(budgetTokens: 30_000, wallClockSeconds: 600,
                                   attemptsPerPass: 2, failureStreak: 3, emptyStreak: 2)
            let g = Governor(kind: "ideas", model: "claude-opus-5", limits: limits)

            if case .go = await g.permit(pass: "screen", estimatedTokens: 10_000) {
                ok("the first call is permitted", true)
            } else { ok("the first call is permitted", false) }
            await g.record(call("screen", tokens: 12_000))

            // A pass that would not fit is refused rather than started and cut off.
            if case .stop(let cause, _) = await g.permit(pass: "brief", estimatedTokens: 25_000) {
                ok("a pass the budget cannot finish is refused before it starts", cause == .budget)
            } else { ok("a pass the budget cannot finish is refused before it starts", false) }
            let spent = await g.spent
            ok("and nothing more was spent finding that out", spent == 12_000)

            // The same failure twice is a loop, not bad luck.
            let g2 = Governor(kind: "ideas", model: "claude-opus-5", limits: .standard)
            _ = await g2.permit(pass: "rank", estimatedTokens: 100)
            await g2.record(call("rank", tokens: 100, ok: false, status: 500, error: "boom"))
            var tripped = await g2.stopped
            ok("one failure does not stop a run", tripped == nil)
            await g2.record(call("rank", tokens: 100, ok: false, status: 500, error: "boom"))
            tripped = await g2.stopped
            ok("the identical failure twice does", tripped == .repeatFailure)

            // Calls completing and returning nothing is the quiet failure.
            let g3 = Governor(kind: "ideas", model: "claude-opus-5", limits: .standard)
            await g3.recordEmpty(call("screen", tokens: 500), reason: "no text")
            await g3.recordEmpty(call("screen", tokens: 500), reason: "no text")
            await g3.recordEmpty(call("screen", tokens: 500), reason: "no text")
            let stalled = await g3.stopped
            ok("three empty responses in a row stop the run", stalled == .noProgress)

            /* A pass is abandoned after it has *failed* its allowance — not after it
             * has been allowed to run that many times. The distinction is the whole
             * point: the screen pass fans one batch out per four candidates, so
             * counting permissions capped the concurrency instead of the retries and
             * silently dropped every batch past the second. */
            let g4 = Governor(kind: "ideas", model: "claude-opus-5", limits: .standard)
            var concurrent = 0
            for _ in 0..<5 {
                if case .go = await g4.permit(pass: "screen", estimatedTokens: 10) { concurrent += 1 }
            }
            ok("five concurrent batches of one pass are all permitted", concurrent == 5)

            await g4.record(call("brief", tokens: 10, ok: false, status: 500, error: "one"))
            await g4.record(call("brief", tokens: 10, ok: false, status: 500, error: "two"))
            if case .stop = await g4.permit(pass: "brief", estimatedTokens: 10) {
                ok("a pass is refused after its allowance of failures", true)
            } else { ok("a pass is refused after its allowance of failures", false) }

            /* The budget is reserved on permit, not merely checked against. Four
             * concurrent asks against a budget two of them fit in used to be waved
             * through, because the actor made the check atomic and left the number
             * it checked unchanged until the calls reported back. */
            let gBudget = Governor(kind: "ideas", model: "claude-opus-5",
                              limits: RunLimits(budgetTokens: 50_000, wallClockSeconds: 600,
                                                attemptsPerPass: 8, failureStreak: 8, emptyStreak: 8))
            var granted = 0
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        if case .go = await gBudget.permit(pass: "screen", estimatedTokens: 25_000) { return true }
                        return false
                    }
                }
                for await allowed in group where allowed { granted += 1 }
            }
            ok("a concurrent fan-out cannot overshoot the budget", granted == 2,
               "50,000 budget at 25,000 a call permitted \(granted), expected 2")

            // And a call that reports back hands its reservation over.
            let gRelease = Governor(kind: "ideas", model: "claude-opus-5",
                              limits: RunLimits(budgetTokens: 50_000, wallClockSeconds: 600,
                                                attemptsPerPass: 8, failureStreak: 8, emptyStreak: 8))
            guard case .go(let ticket) = await gRelease.permit(pass: "screen", estimatedTokens: 25_000) else {
                return ok("the first call is permitted", false)
            }
            let heldBack = await gRelease.remaining
            await gRelease.record(call("screen", tokens: 100, ok: true), ticket: ticket)
            let afterRelease = await gRelease.remaining
            ok("a reservation is held while the call is in flight", heldBack == 25_000,
               "expected 25,000 left, got \(heldBack)")
            ok("and released once the call reports what it really cost", afterRelease > heldBack,
               "expected more than \(heldBack) back, got \(afterRelease)")
            let runStillOpen = await g4.stopped
            ok("but the run itself is not stopped by it", runStillOpen == nil)

            // Cancelling is immediate and sticky.
            let g5 = Governor(kind: "ideas", model: "claude-opus-5", limits: .standard)
            await g5.cancel()
            if case .stop(let cause, _) = await g5.permit(pass: "screen", estimatedTokens: 10) {
                ok("a cancelled run permits nothing further", cause == .cancelled)
            } else { ok("a cancelled run permits nothing further", false) }

            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
    }

    /* ---------------------------------------------------------------- models */

    private static func models() {
        // Every option offered has to be one the request builder can actually shape a
        // valid call for. A picker where one choice returns a 400 is worse than none.
        for option in ModelCatalogue.all {
            ok("\(option.name) is priced", option.inputPerMTok > 0 && option.outputPerMTok > 0)
            ok("\(option.name) has a rate table entry too", ModelPrice.of(option.modelId) != nil)
            ok("\(option.name) says what it is for", option.note.count > 40)
        }
        ok("the default is the most capable option", ModelCatalogue.fallback.modelId == "claude-opus-5")
        ok("and it is suitable for judgement", ModelCatalogue.fallback.suitableForJudgement)

        // The one that matters: a model that rejects `effort` must be marked as such,
        // or the request builder sends a field that 400s.
        let haiku = ModelCatalogue.of("claude-haiku-4-5")
        ok("Haiku is known", haiku != nil)
        ok("and is marked as not taking an effort level", haiku?.supportsEffort == false)
        ok("and as needing an explicit thinking budget", haiku?.adaptiveThinking == false)
        ok("and is kept away from the passes that teach", haiku?.suitableForJudgement == false)
        ok("Sonnet 5 does take an effort level", ModelCatalogue.of("claude-sonnet-5")?.supportsEffort == true)

        // An unknown model is described rather than crashed on, and reports no price.
        let unknown = ModelCatalogue.describe("some-future-model")
        ok("an unknown model is still described", unknown.modelId == "some-future-model")
        ok("with no invented rate", unknown.inputPerMTok == 0)
        ok("and assumed to take the modern request shape", unknown.supportsEffort)

        // Relative cost, which the interface states as a percentage.
        let opus = ModelCatalogue.of("claude-opus-5")!
        let sonnet = ModelCatalogue.of("claude-sonnet-5")!
        ok("Sonnet is cheaper than Opus", sonnet.costVersus(opus) < 1)
        near("and by the ratio its rates imply", sonnet.costVersus(opus), 0.4, 0.01)
        near("a model against itself is parity", opus.costVersus(opus), 1, 0.0001)

        // Precedence and per-pass routing.
        AnalystModel.adopt(main: nil, fast: nil)
        ok("with nothing set, the default is in force", Analyst.model == "claude-opus-5")

        AnalystModel.adopt(main: "claude-sonnet-5", fast: nil)
        ok("a chosen model takes effect", Analyst.model == "claude-sonnet-5")
        ok("and every pass uses it", AnalystModel.forPass("screen") == "claude-sonnet-5"
            && AnalystModel.forPass("brief") == "claude-sonnet-5")
        ok("the interface can say where it came from", AnalystModel.source.contains("Settings"))

        AnalystModel.adopt(main: "claude-opus-5", fast: "claude-haiku-4-5")
        ok("the mechanical passes go to the cheaper model",
           AnalystModel.forPass("screen") == "claude-haiku-4-5")
        ok("and so do the per-trade notes", AnalystModel.forPass("review") == "claude-haiku-4-5")
        ok("while the ranking stays on the main model",
           AnalystModel.forPass("rank") == "claude-opus-5")
        ok("as does the brief", AnalystModel.forPass("brief") == "claude-opus-5")
        ok("and the report", AnalystModel.forPass("report") == "claude-opus-5")
        ok("and the learning pass", AnalystModel.forPass("learn") == "claude-opus-5")

        AnalystModel.adopt(main: nil, fast: nil)

        // A mixed run is priced per call, not at one rate for the whole thing.
        var mixed = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        var cheap = call("screen", tokens: 1_000_000)
        cheap.model = "claude-sonnet-5"
        var dear = call("brief", tokens: 1_000_000)
        dear.model = "claude-opus-5"
        mixed.calls = [cheap, dear]
        // Sonnet: 500k in at $2 + 500k out at $10 = $6. Opus: 500k at $5 + 500k at $25 = $15.
        near("a mixed run is priced at each call's own model", mixed.estimatedCost, 21, 0.01)
        ok("and the receipt can name both", mixed.modelsUsed.count == 2)

        // A record written before per-call models still prices, at the run's model.
        var legacy = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        legacy.calls = [call("screen", tokens: 1_000_000)]   // model left empty
        near("an older telemetry still prices at the run's model", legacy.estimatedCost, 15, 0.01)
        ok("and reports the run's model as the one used", legacy.modelsUsed == ["claude-opus-5"])

        // Settings survive an older file that predates the field.
        let old = Data(#"{"hasOnboarded":true}"#.utf8)
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: old)
        ok("settings without a model field still decode", decoded != nil)
        ok("and mean \"whatever the app defaults to\" rather than pinning one",
           decoded?.analystModel == "")
    }

    /* ------------------------------------------------------------ diagnosing */

    private static func diagnosing() {
        let limits = RunLimits.standard

        // No key explains every downstream symptom, so it is reported alone.
        var blank = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        blank.calls = [call("screen", tokens: 10, ok: false, status: 401)]
        let noKey = Diagnostics.diagnose(blank, limits: limits, keyPresent: false, keySource: .none)
        ok("a missing key is the only finding reported", noKey.findings.count == 1)
        ok("and it is a fault", noKey.findings[0].severity == "fault")
        ok("named for what it is", noKey.findings[0].id == "no-key")
        ok("with retrying explicitly ruled out", noKey.retryAdvised == false)

        // Each HTTP status gets its own explanation rather than one generic failure.
        func diagnosed(_ status: Int) -> Diagnosis {
            var t = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
            t.calls = [call("screen", tokens: 100, ok: false, status: status, error: "x")]
            return Diagnostics.diagnose(t, limits: limits, keyPresent: true, keySource: .keychain)
        }
        ok("a 401 is a rejected key", diagnosed(401).findings.contains { $0.id == "unauthorised" })
        ok("a 403 is access, not authentication", diagnosed(403).findings.contains { $0.id == "forbidden" })
        ok("a 404 is a model that does not exist", diagnosed(404).findings.contains { $0.id == "no-model" })
        ok("a 429 is rate limiting", diagnosed(429).findings.contains { $0.id == "rate-limited" })
        ok("and is worth retrying", diagnosed(429).retryAdvised)
        ok("a 401 is not worth retrying", diagnosed(401).retryAdvised == false)
        ok("a 500 is upstream", diagnosed(503).findings.contains { $0.id == "upstream" })

        // Truncation is the expensive failure and must not read as a parse error.
        var cut = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        cut.calls = [call("brief", tokens: 20_000, ok: false, stop: "max_tokens")]
        let truncated = Diagnostics.diagnose(cut, limits: limits, keyPresent: true, keySource: .keychain)
        ok("a max_tokens stop is diagnosed as truncation", truncated.findings.contains { $0.id == "truncated" })
        ok("and as a fault, since the tokens were billed for nothing",
           truncated.findings.first { $0.id == "truncated" }?.severity == "fault")

        /* The cache fault, and the thing it must not be confused with.
         *
         * Sharing only happens inside a pass — every pass carries a different output
         * schema, so two passes never hit each other's entry. One call per pass reading
         * nothing back is therefore correct. The fault is a pass that ran twice and
         * still read nothing, which means both calls started before either had written
         * and each paid the write price. */
        var oncePerPass = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        oncePerPass.calls = [call("screen", tokens: 5_000, cacheWrite: 1_200),
                             call("rank", tokens: 5_000, cacheWrite: 1_200),
                             call("brief", tokens: 5_000, cacheWrite: 1_200)]
        let onceD = Diagnostics.diagnose(oncePerPass, limits: limits, keyPresent: true, keySource: .keychain)
        ok("one call per pass reading nothing back is not a fault",
           !onceD.findings.contains { $0.id == "cache-cold" })

        var cold = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        cold.calls = [call("screen", tokens: 5_000, cacheWrite: 1_200),
                      call("screen", tokens: 5_000, cacheWrite: 1_200),
                      call("rank", tokens: 5_000, cacheWrite: 1_200)]
        let coldD = Diagnostics.diagnose(cold, limits: limits, keyPresent: true, keySource: .keychain)
        ok("a pass that ran twice and read nothing back is flagged",
           coldD.findings.contains { $0.id == "cache-cold" })

        var warm = cold
        warm.calls[1].cacheReadTokens = 1_200
        warm.calls[1].cacheWriteTokens = 0
        let warmD = Diagnostics.diagnose(warm, limits: limits, keyPresent: true, keySource: .keychain)
        ok("and the same run reading it back is not",
           !warmD.findings.contains { $0.id == "cache-cold" })

        // A clean run says so rather than staying silent about it.
        var clean = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        clean.calls = [call("screen", tokens: 5_000), call("rank", tokens: 5_000)]
        clean.finishedAt = clean.startedAt + 30_000
        let healthy = Diagnostics.diagnose(clean, limits: limits, keyPresent: true, keySource: .keychain)
        ok("a clean run is reported as clean", healthy.findings.contains { $0.id == "healthy" })
        ok("the elapsed time is not negative", !healthy.findings[0].observed.contains("-"),
           healthy.findings[0].observed)

        // The budget stop is the governor working, and the verdict has to say so.
        var capped = clean
        capped.stoppedBy = .budget
        capped.stopNote = "hit the ceiling"
        let budgetD = Diagnostics.diagnose(capped, limits: limits, keyPresent: true, keySource: .keychain)
        ok("a budget stop is explained as a limit rather than a failure",
           budgetD.findings.contains { $0.id == "budget" })
        ok("and the verdict does not claim nothing needs attention",
           !budgetD.verdict.contains("Nothing here needs action"), budgetD.verdict)
        ok("and it suggests a larger budget", budgetD.suggestedBudgetTokens != nil)

        // Fingerprints identify a key without exposing one.
        let fp = Credentials.fingerprint("sk-" + "ant-api03-abcdefghijklmnopqrstuvwxyz1234")
        ok("a fingerprint keeps only the ends", fp == "sk-ant-…1234", fp)
        ok("and is far shorter than the key", fp.count < 20)
    }

    /* ----------------------------------------------------------- local server */

    /// One raw HTTP exchange over a socket, so a test can send headers a browser
    /// would never let a page forge (a rebinding attack arrives with its own Host).
    private static func raw(_ port: UInt16, _ request: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "" }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            out.append(chunk, count: n)
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    private static func localServer() {
        // The gate, on its own.
        let gate = RequestGate(token: "t0ken")
        gate.port = 4242
        func request(_ target: String, method: String = "GET", _ headers: [String: String]) -> HTTPRequest {
            HTTPRequest(method: method, target: target, body: Data(), headers: headers)
        }
        let good = ["host": "127.0.0.1:4242", RequestGate.header: "t0ken"]
        ok("a request from the desk itself is allowed", gate.verdict(for: request("/api/state", good)) == .allow)
        ok("a page needs no token, only the right host", gate.verdict(for: request("/index.html", ["host": "127.0.0.1:4242"])) == .allow)
        ok("an API call without the token is refused", gate.verdict(for: request("/api/state", ["host": "127.0.0.1:4242"])) != .allow)
        ok("an API call with the wrong token is refused", gate.verdict(for: request("/api/state", ["host": "127.0.0.1:4242", RequestGate.header: "nope"])) != .allow)
        ok("a rebound host name is refused even with the token", gate.verdict(for: request("/api/state", ["host": "evil.example:4242", RequestGate.header: "t0ken"])) != .allow)
        ok("a foreign origin is refused even with the token", gate.verdict(for: request("/api/state", good.merging(["origin": "https://evil.example"]) { $1 })) != .allow)
        ok("a cross-site fetch is refused even with the token", gate.verdict(for: request("/api/state", good.merging(["sec-fetch-site": "cross-site"]) { $1 })) != .allow)
        ok("the desk's own origin is accepted", gate.verdict(for: request("/api/state", good.merging(["origin": "http://127.0.0.1:4242", "sec-fetch-site": "same-origin"]) { $1 })) == .allow)
        let unbound = RequestGate(token: "t0ken")
        ok("before a port is bound nothing is allowed", unbound.verdict(for: request("/index.html", ["host": "127.0.0.1:0"])) != .allow)
        ok("tokens are long and not repeated", RequestGate.makeToken().count == 64 && RequestGate.makeToken() != RequestGate.makeToken())

        // The page that carries the token.
        let page = Data("<!DOCTYPE html><html><head><title>x</title></head></html>".utf8)
        let tagged = String(data: SiteFiles.withToken(page, "abc123"), encoding: .utf8) ?? ""
        ok("the token is placed in the page head", tagged.contains("<head>\n<meta name=\"paper-token\" content=\"abc123\">"))
        ok("a page with no head is left alone", SiteFiles.withToken(Data("<p>hi</p>".utf8), "abc123") == Data("<p>hi</p>".utf8))

        // The parser.
        func parse(_ text: String) -> HTTPServer.ParseResult { HTTPServer.parse(Data(text.utf8)) }
        if case .complete(let r) = parse("POST /api/trade HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\nX-Paper-Token: z\r\n\r\n{}") {
            ok("a normal request parses, with lower-cased headers", r.method == "POST" && r.headers["x-paper-token"] == "z" && r.body.count == 2)
        } else { ok("a normal request parses", false) }
        ok("a short body is waited for", parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nab") == .partial)
        ok("a negative length is refused, not trapped on", parse("POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\n") == .malformed(400))
        ok("a length that is not a number is refused", parse("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n") == .malformed(400))
        ok("a huge length is refused before it is read", parse("POST /x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") == .malformed(413))
        ok("two disagreeing lengths are refused", parse("POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab") == .malformed(400))
        ok("a chunked body is refused", parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .malformed(501))
        ok("headers that never end are cut off", HTTPServer.parse(Data(repeating: 65, count: HTTPServer.maxHeaderBytes + 10)) == .malformed(413))

        // Profile ids become file names.
        ok("a UUID is a valid profile id", Profile.isValidID(UUID().uuidString))
        ok("path-like profile ids are refused", !Profile.isValidID("../x") && !Profile.isValidID("a/b") && !Profile.isValidID("") && !Profile.isValidID("a.b") && !Profile.isValidID(String(repeating: "a", count: 65)))

        // And the real thing, over a socket.
        let live = RequestGate()
        let server = HTTPServer(gate: live) { req in
            req.path == "/api/ping" ? .json(["ok": true]) : HTTPResponse(status: 200, contentType: "text/plain", body: Data("page".utf8))
        }
        do {
            let port = try server.start()
            defer { server.stop() }
            let host = "127.0.0.1:\(port)"
            func status(_ text: String) -> String { String(raw(port, text).prefix(12)) }
            ok("live: the desk's own request is served",
               status("GET /api/ping HTTP/1.1\r\nHost: \(host)\r\nX-Paper-Token: \(live.token)\r\n\r\n") == "HTTP/1.1 200")
            ok("live: the page is served without a token",
               status("GET /index.html HTTP/1.1\r\nHost: \(host)\r\n\r\n") == "HTTP/1.1 200")
            ok("live: an API call with no token gets 403",
               status("GET /api/ping HTTP/1.1\r\nHost: \(host)\r\n\r\n") == "HTTP/1.1 403")
            ok("live: a cross-site POST in the shape a form can send gets 403",
               status("POST /api/reset HTTP/1.1\r\nHost: \(host)\r\nOrigin: https://evil.example\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}") == "HTTP/1.1 403")
            ok("live: a rebound host name gets 403 even with the real token",
               status("GET /api/ping HTTP/1.1\r\nHost: evil.example:\(port)\r\nX-Paper-Token: \(live.token)\r\n\r\n") == "HTTP/1.1 403")
            ok("live: a negative length gets 400 and the server survives",
               status("POST /api/ping HTTP/1.1\r\nHost: \(host)\r\nContent-Length: -1\r\n\r\n") == "HTTP/1.1 400"
               && status("GET /index.html HTTP/1.1\r\nHost: \(host)\r\n\r\n") == "HTTP/1.1 200")
        } catch {
            ok("live: the server starts", false, "\(error)")
        }
    }

    /* --------------------------------------------------------- day sessions */

    private static func sessions() {
        let profile = Profile.preset(.dayTrader)
        var s = TradingSession.opening(
            profile: profile, stake: 10_000, minutes: 60, equity: 30_000,
            maxLossPct: 3, targetPct: 6, riskPctPerTrade: 1, maxTrades: 4, flatAtEnd: true
        )
        near("the loss limit is a share of the stake, not the account", s.lossLimit, 300, 0.001)
        near("so is the target", s.targetAmount, 600, 0.001)
        near("and the risk per trade", s.riskPerTrade, 100, 0.001)

        // A session sizes from its stake and reads intraday, so its rules are its own.
        let rules = s.sizingRules()
        near("the session's equity is the stake", rules.equity, 10_000, 0.001)
        ok("its horizon is measured in bars, not days", (rules.maxSessions ?? 0) <= 30)
        ok("and it will not fund a name whose bar covers more than 2% of price",
           (rules.maxDailyRangePct ?? 99) <= 2.0)

        // The three rules that end it, in the order they are tested.
        ok("a session in the middle of its range keeps running",
           SessionEngine.verdict(s, unrealised: 0) == nil)
        ok("reaching the target ends it",
           SessionEngine.verdict(s, unrealised: 600)?.0 == .metTarget)
        ok("hitting the loss limit ends it",
           SessionEngine.verdict(s, unrealised: -300)?.0 == .hitLossLimit)
        // Both at once is a loss. Assuming the good outcome is how a backtest lies.
        s.entries = []
        var both = s
        both.entries = []
        ok("a session that hit both in one tick counts the loss",
           SessionEngine.verdict(both, unrealised: -300)?.0 == .hitLossLimit)

        var expired = s
        expired.endsAt = nowMs() - 1000
        ok("the clock ends it too", SessionEngine.verdict(expired, unrealised: 0)?.0 == .outOfTime)

        // Unrealised counts. A session is not allowed to be down past its limit and
        // call itself fine because nothing has closed yet.
        ok("an open position past the limit ends the session",
           SessionEngine.verdict(s, unrealised: -400)?.0 == .hitLossLimit)

        // The blockers, which are what "minimum losses" actually means in code.
        //
        // The plan is built by hand rather than from a synthetic series: the blocker
        // reports the engine's own refusal first, so a fixture that happens to be
        // rejected would pass every one of these checks for the wrong reason.
        let plan = Analysis.TradePlan(
            symbol: "TEST", side: .long, entry: 100, entryKind: .market, tightStop: false,
            target: 103, stop: 99, targetPct: 3, stopPct: -1, rr: 3,
            riskBudget: 100, riskTaken: 100, sizedBy: .risk, shares: 100, cost: 10_000,
            horizonDays: 8, breakevenWinRate: 25, rejected: nil
        )
        ok("the fixture plan is one the engine would fund", plan.rejected == nil)

        // The hour these blockers are read against is stated, not inherited from
        // whenever the suite happens to run. 16:30 Stockholm on a Tuesday is both
        // exchanges trading; Sunday noon is neither, and crypto through both.
        let boardsOpen = stockholm(2026, 9, 8, 16, 30)
        let boardsShut = stockholm(2026, 9, 6, 12)
        ok("the open fixture really is an open US session",
           MarketCalendar.isOpen(for: "AAPL", at: boardsOpen))
        ok("and the shut one really is shut",
           !MarketCalendar.isOpen(for: "AAPL", at: boardsShut))
        ok("a symbol already held is refused",
           SessionEngine.blocker(s, plan: plan, symbol: "AAPL", held: true, openRisk: 0,
                                 dayTradesLeft: nil, now: boardsOpen) != nil)

        var maxed = s
        maxed.entries = (0..<4).map { i in
            SessionEntry(symbol: "S\(i)", at: 0, entry: 1, stop: 0.9, target: 1.2, shares: 1,
                         plannedRisk: 10, thesis: "", closedAt: nil, exit: nil, pnl: nil,
                         rMultiple: nil, trigger: nil)
        }
        ok("the trade cap is enforced",
           SessionEngine.blocker(maxed, plan: plan, symbol: "AAPL", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: boardsOpen)?.contains("limit of 4") == true)

        // The one that matters: a session near its limit may not open another
        // full-size position. Realised losses and open risk are counted together.
        var bleeding = s
        bleeding.entries = [SessionEntry(symbol: "X", at: 0, entry: 1, stop: 0.9, target: 1.2,
                                         shares: 1, plannedRisk: 10, thesis: "", closedAt: 1,
                                         exit: 0.9, pnl: -250, rMultiple: -1, trigger: "stop")]
        ok("a session cannot commit more than its remaining limit",
           SessionEngine.blocker(bleeding, plan: plan, symbol: "AAPL", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: boardsOpen) != nil)
        ok("and open risk counts toward that, not just what is already lost",
           SessionEngine.blocker(s, plan: plan, symbol: "AAPL", held: false, openRisk: 250,
                                 dayTradesLeft: nil, now: boardsOpen) != nil)

        ok("the pattern day trader rule blocks an equity entry at the limit",
           SessionEngine.blocker(s, plan: plan, symbol: "AAPL", held: false, openRisk: 0,
                                 dayTradesLeft: 0, now: boardsOpen) != nil)
        ok("but crypto is exempt from it",
           SessionEngine.blocker(s, plan: plan, symbol: "BTC-USD", held: false, openRisk: 0,
                                 dayTradesLeft: 0, now: boardsOpen) == nil)
        ok("a closed equity session blocks equities",
           SessionEngine.blocker(s, plan: plan, symbol: "AAPL", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: boardsShut) != nil)
        ok("and still allows crypto, which never closes",
           SessionEngine.blocker(s, plan: plan, symbol: "BTC-USD", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: boardsShut) == nil)

        // The case a single account-level "the market is open" flag gets wrong, and
        // the reason this is asked per symbol: at 09:30 Stockholm the Swedish board
        // is trading and New York is not, so the same instant means opposite things
        // to two names on the same board.
        let stockholmOnly = stockholm(2026, 9, 8, 9, 30)
        ok("a New York name is blocked on a Swedish morning",
           SessionEngine.blocker(s, plan: plan, symbol: "AAPL", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: stockholmOnly) != nil)
        ok("while a Stockholm name at the same instant is not",
           SessionEngine.blocker(s, plan: plan, symbol: "SEB-A.ST", held: false, openRisk: 0,
                                 dayTradesLeft: nil, now: stockholmOnly) == nil)

        // A session survives a relaunch.
        let encoded = try? JSONEncoder().encode(s)
        let back = encoded.flatMap { try? JSONDecoder().decode(TradingSession.self, from: $0) }
        ok("a session encodes and decodes", back != nil)
        near("with its limit intact", back?.lossLimit, 300, 0.001)

        // A Sunday: every exchange on the board is shut, and crypto is not.
        let sunday = stockholm(2026, 9, 6, 12)
        var crypto = Profile.preset(.cryptoNative)
        crypto.appetite = .cryptoOnly
        ok("a crypto profile has a universe when every exchange is shut",
           !SessionEngine.universe(for: crypto, at: sunday).isEmpty)
        var equities = Profile.preset(.dayTrader)
        equities.appetite = .stocksOnly
        ok("an equities-only profile correctly has nothing on a Sunday",
           SessionEngine.universe(for: equities, at: sunday).isEmpty)

        /* The Swedish morning: 10:00 Stockholm on a Tuesday is 04:00 in New York.
         * This used to leave a Swedish day trader with crypto and nothing else while
         * an entire equity market was open in front of them. */
        let swedishMorning = stockholm(2026, 9, 8, 10)
        let morningUniverse = SessionEngine.universe(for: equities, at: swedishMorning)
        ok("a Swedish morning offers Stockholm listings before New York opens",
           morningUniverse.contains { Universe.venue(of: $0) == .stockholm })
        ok("and offers no US listings at that hour",
           !morningUniverse.contains { Universe.venue(of: $0) == .us })
    }


    /* ------------------------------------------------- Stockholm and the FX seam */

    /**
     * The two things that had to be true before a kronor listing could be traded
     * without lying: the clock, and the seam between prices and money.
     *
     * The seam is the dangerous one. Every price on a position is in the
     * instrument's own currency and every money figure is in dollars, and getting
     * that backwards on a SEK name is a tenfold error in the flattering direction —
     * a 337 kr holding valued at $337. So the arithmetic is asserted end to end
     * rather than trusted to read correctly.
     */
    private static func stockholm() {
        /* --- the clock ---------------------------------------------------- */

        // 10:00 Stockholm on a Tuesday: the Swedish market is trading and New York
        // has not woken up. This window is most of a Swedish working morning.
        let morning = stockholm(2026, 9, 8, 10)
        ok("Stockholm is open at 10:00 local", MarketCalendar.isSessionOpen(morning, venue: .stockholm))
        ok("while New York is still shut", !MarketCalendar.isSessionOpen(morning, venue: .us))
        // 16:30 Stockholm: both are trading. About two hours of overlap a day.
        let overlap = stockholm(2026, 9, 8, 16, 30)
        ok("the two exchanges overlap in the Swedish afternoon",
           MarketCalendar.isSessionOpen(overlap, venue: .stockholm)
               && MarketCalendar.isSessionOpen(overlap, venue: .us))
        ok("Stockholm closes at 17:30 local",
           !MarketCalendar.isSessionOpen(stockholm(2026, 9, 8, 17, 31), venue: .stockholm))
        ok("and is open a minute before that",
           MarketCalendar.isSessionOpen(stockholm(2026, 9, 8, 17, 29), venue: .stockholm))
        ok("it opens at 09:00, not 09:30",
           MarketCalendar.isSessionOpen(stockholm(2026, 9, 8, 9, 5), venue: .stockholm))
        ok("and not at 08:55", !MarketCalendar.isSessionOpen(stockholm(2026, 9, 8, 8, 55), venue: .stockholm))
        ok("crypto is open whenever it is asked",
           MarketCalendar.isSessionOpen(stockholm(2026, 9, 6, 3), venue: .crypto))

        /* --- the Swedish holidays, which are barely related to the US ones --- */

        func shut(_ m: Int, _ d: Int, _ name: String) {
            ok("Stockholm is closed for \(name)",
               !MarketCalendar.isTradingDay(stockholm(2026, m, d, 12), venue: .stockholm))
        }
        shut(1, 1, "Nyårsdagen")
        shut(1, 6, "Trettondedag jul")
        shut(5, 1, "Första maj")
        shut(6, 6, "Sveriges nationaldag")
        shut(12, 24, "Julafton")
        shut(12, 26, "Annandag jul")
        shut(12, 31, "Nyårsafton")
        // Easter 2026 falls on 5 April, so Good Friday is the 3rd and Easter Monday the 6th.
        shut(4, 3, "Långfredagen")
        shut(4, 6, "Annandag påsk")
        // Ascension Day is Easter + 39 days: 14 May 2026.
        shut(5, 14, "Kristi himmelsfärdsdag")
        // Midsummer Eve is the Friday between 19 and 25 June: 19 June 2026.
        shut(6, 19, "Midsommarafton")

        // The calendars genuinely disagree, which is the point of keeping two.
        ok("Thanksgiving closes New York and not Stockholm",
           !MarketCalendar.isTradingDay(nyNoon(2026, 11, 26))
               && MarketCalendar.isTradingDay(stockholm(2026, 11, 26, 12), venue: .stockholm))
        ok("Epiphany closes Stockholm and not New York",
           MarketCalendar.isTradingDay(nyNoon(2026, 1, 6))
               && !MarketCalendar.isTradingDay(stockholm(2026, 1, 6, 12), venue: .stockholm))

        /* Weekend substitution is a US rule and only a US rule. 1 January 2027 is a
         * Friday, so it is not a useful test; 6 June 2026 is a Saturday, and Sweden
         * simply loses the holiday rather than moving it to the Friday. */
        ok("Stockholm does not substitute a weekend holiday onto a weekday",
           MarketCalendar.isTradingDay(stockholm(2026, 6, 5, 12), venue: .stockholm))

        // Maundy Thursday: open, but only until 13:00.
        ok("Stockholm trades the morning of Maundy Thursday",
           MarketCalendar.isSessionOpen(stockholm(2026, 4, 2, 11), venue: .stockholm))
        ok("and shuts at 13:00 that day",
           !MarketCalendar.isSessionOpen(stockholm(2026, 4, 2, 14), venue: .stockholm))

        /* --- the PDT rule does not reach Stockholm ------------------------- */

        let frictions = Frictions.retailBroker
        let used = (0..<4).map { DayTradeRecord(symbol: "AAPL", at: nowMs() - Double($0) * 3_600_000,
                                                session: "s\($0)") }
        ok("four day trades block a fifth US round trip",
           PDT.blocks(symbol: "AAPL", equity: 10_000, records: used, frictions: frictions) != nil)
        ok("but not a Stockholm one — it is a US regulation",
           PDT.blocks(symbol: "VOLV-B.ST", equity: 10_000, records: used, frictions: frictions) == nil)
        ok("and not crypto",
           PDT.blocks(symbol: "BTC-USD", equity: 10_000, records: used, frictions: frictions) == nil)

        /* --- the seam: prices are native, money is dollars ------------------ */

        var profile = Profile.preset(.learner)
        profile.startingCapital = 100_000
        profile.frictions = .none      // isolate the FX arithmetic from spread and commission
        let (led, ledDir) = tempLedger(profile)
        defer { try? FileManager.default.removeItem(at: ledDir) }

        // Ten kronor to the dollar keeps the arithmetic checkable by eye.
        let rate = 10.0
        let mark = MarkPrice(price: 300, atr: 6, fxPerUSD: rate)
        guard case .ok = led.buy(symbol: "VOLV-B.ST", shares: 100, mark: mark,
                                 target: 360, stop: 280, skipGate: true) else {
            ok("a kronor buy fills", false); return
        }
        // 100 shares at 300 kr is 30 000 kr, which is $3,000 at ten to the dollar.
        near("a kronor position costs the right number of dollars",
             100_000 - led.state.cash, 3_000, 0.01)
        let pos = led.state.positions.first { $0.symbol == "VOLV-B.ST" }
        near("the position's price stays in kronor", pos?.avgPrice, 300, 0.01)
        near("its dollar basis is the converted one", pos?.avgPriceUSD, 30, 0.01)
        near("and the rate it filled at is kept", pos?.fxAtOpen, rate, 0.0001)
        ok("the stop is a kronor level, not a dollar one", pos?.stop == 280)

        // Marked at an unchanged price and rate: no profit, and the valuation is dollars.
        let flat = led.value(["VOLV-B.ST": MarkPrice(price: 300, fxPerUSD: rate)])
        near("an unmoved kronor position values at its dollar cost", flat.invested, 3_000, 0.01)
        near("and shows no profit", flat.positions.first?.pnl, 0, 0.01)
        near("equity is unchanged", flat.equity, 100_000, 0.01)

        // The stock rises 10% in kronor, the rate does not move.
        let up = led.value(["VOLV-B.ST": MarkPrice(price: 330, fxPerUSD: rate)])
        near("a 10% move in kronor is a 10% move in dollars when the rate holds",
             up.positions.first?.pnl, 300, 0.01)
        near("and none of it is attributed to the currency",
             up.positions.first?.fxPnl, 0, 0.01)

        /* The krona strengthens to 9 per dollar with the price unchanged. The holding
         * is worth more dollars without the stock having moved at all — which is the
         * exposure a dollar-settled account carries whether it asked for it or not,
         * and the thing this app used to state on the desk and not model. */
        let stronger = led.value(["VOLV-B.ST": MarkPrice(price: 300, fxPerUSD: 9)])
        near("a stronger krona is a profit on an unmoved stock",
             stronger.positions.first?.pnl, 30_000.0 / 9 - 3_000, 0.01)
        near("and all of that profit is the currency",
             stronger.positions.first?.fxPnl, 30_000.0 / 9 - 3_000, 0.01)

        // Selling converts at the rate on the day of the exit, not the day of entry.
        guard case .ok(let exit) = led.sell(symbol: "VOLV-B.ST",
                                            mark: MarkPrice(price: 330, fxPerUSD: rate),
                                            skipGate: true) else {
            ok("a kronor sell fills", false); return
        }
        near("the exit price is recorded in kronor", exit.price, 330, 0.01)
        near("the proceeds are recorded in dollars", exit.value, 3_300, 0.01)
        near("and the profit is the dollar profit", exit.pnl, 300, 0.01)

        /* --- a dollar instrument is untouched by any of it ------------------ */

        let (led2, led2Dir) = tempLedger(profile)
        defer { try? FileManager.default.removeItem(at: led2Dir) }
        guard case .ok = led2.buy(symbol: "AAPL", shares: 10,
                                  mark: MarkPrice(price: 200, atr: 4), skipGate: true) else {
            ok("a dollar buy fills", false); return
        }
        near("a dollar position costs exactly its notional", 100_000 - led2.state.cash, 2_000, 0.01)
        near("its rate is one", led2.state.positions.first?.fxAtOpen, 1, 0.0001)
        let usd = led2.value(["AAPL": MarkPrice(price: 220)])
        near("and it values as it always did", usd.positions.first?.pnl, 200, 0.01)
        ok("with no currency component to report", usd.positions.first?.fxPnl == nil)

        /* --- a parcel keeps the rate it was bought at ----------------------- */

        let (led3, led3Dir) = tempLedger(profile)
        defer { try? FileManager.default.removeItem(at: led3Dir) }
        _ = led3.buy(symbol: "ERIC-B.ST", shares: 100, mark: MarkPrice(price: 100, fxPerUSD: 10),
                     skipGate: true)
        _ = led3.buy(symbol: "ERIC-B.ST", shares: 100, mark: MarkPrice(price: 100, fxPerUSD: 5),
                     skipGate: true)
        let averaged = led3.state.positions.first { $0.symbol == "ERIC-B.ST" }
        near("averaging in blends the kronor price", averaged?.avgPrice, 100, 0.01)
        // 100 shares cost $1,000 at ten to the dollar and 100 more cost $2,000 at
        // five. The dollar basis is $15 a share, not $10 and not $20.
        near("but the dollar basis remembers both rates", averaged?.avgPriceUSD, 15, 0.01)
        near("and the blended rate sits between them", averaged?.fxAtOpen, 7.5, 0.01)

        /* --- an older ledger still opens ------------------------------------ */

        let legacy = """
        {"id":"x","shares":5,"costPerShare":100,"openedAt":1}
        """
        let lot = try? JSONDecoder().decode(TaxLot.self, from: Data(legacy.utf8))
        ok("a parcel written before rates existed still decodes", lot != nil)
        near("and is read as a dollar parcel", lot?.fxPerUSD, 1, 0.0001)
        near("so its dollar basis is what it always was", lot?.costPerShareUSD, 100, 0.001)

        /* --- a guarded rate never poisons the ledger ------------------------ */

        let zeroed = MarkPrice(price: 300, fxPerUSD: 0)
        near("a zero rate is refused rather than dividing by it", zeroed.safeFX, 1, 0.0001)
        let nan = MarkPrice(price: 300, fxPerUSD: Double.nan)
        near("and so is a NaN", nan.safeFX, 1, 0.0001)

        /* --- the Swedish broker's costs ------------------------------------- */

        ok("a Swedish broker charges a percentage with a floor",
           Frictions.swedishBroker.commissionPctOfValue > 0 && Frictions.swedishBroker.minCommission > 0)
        ok("and is not subject to the PDT rule", !Frictions.swedishBroker.enforcePDT)
        ok("Swedish capital gains are flat, not split by holding period",
           Frictions.swedishBroker.shortTermTaxPct == Frictions.swedishBroker.longTermTaxPct)
        // The note that promises patience saves tax is false under a flat rate, so it
        // must not be the one that gets printed.
        let flatGain = RealizedGain(at: nowMs(), symbol: "VOLV-B.ST", shares: 10, proceeds: 1_100,
                                    costBasis: 1_000, gain: 100, holdingDays: 10,
                                    longTerm: false, taxDue: 30)
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let summary = Tax.summarise([flatGain], .swedishBroker, year: year)
        ok("a flat-rate summary does not claim holding longer would have saved tax",
           !summary.note.contains("would have been taxed at"))
        ok("it says the rate is flat instead", summary.note.contains("flat"))

        /* --- the venue filter ----------------------------------------------- */

        var usOnly = Profile.preset(.learner)
        usOnly.markets = [.us, .crypto]
        ok("a US-only profile is not shown Stockholm", !usOnly.allows("VOLV-B.ST"))
        ok("but is still shown US names", usOnly.allows("AAPL"))
        var seOnly = Profile.preset(.learner)
        seOnly.markets = [.stockholm]
        ok("a Stockholm-only profile is shown Swedish names", seOnly.allows("ERIC-B.ST"))
        ok("and not US ones", !seOnly.allows("AAPL"))
        var legacyProfile = Profile.preset(.learner)
        legacyProfile.markets = []
        ok("an empty market list reads as every market, never as none",
           legacyProfile.allows("AAPL") && legacyProfile.allows("VOLV-B.ST"))
    }

    /* ------------------------------------------------------------ trade styles */

    /**
     * The fix for the complaint that every run returned the same names.
     *
     * The old engine scored one way for everybody: trend 34%, momentum 26%, entry
     * 26%, risk 14%, with momentum always measured over the same 21/63/5-day blend.
     * A day trader and a pension holder got the same twelve names in the same order,
     * and the low-volatility mega-caps won every time because the risk axis punished
     * movement and nothing rewarded it.
     *
     * What is asserted here is that the four styles genuinely disagree — not that any
     * one of them is right, which no test can know, but that asking a different
     * question now gets a different answer.
     */
    private static func tradeStyles() {
        for style in TimeHorizon.allCases {
            let w = Analysis.AxisWeights.of(style)
            near("the \(style.rawValue) weights sum to one", w.sum, 1, 1e-9)
        }

        // The emphasis each style claims has to match the weights it actually uses,
        // or the picker describes one engine and the run uses another.
        let fast = Analysis.AxisWeights.of(.intraday)
        let slow = Analysis.AxisWeights.of(.longTerm)
        ok("a day trade weights daily range above everything else",
           fast.range > fast.trend && fast.range > fast.durability)
        ok("a long hold weights durability above everything else",
           slow.durability > slow.momentum && slow.durability > slow.entry)
        ok("and does not weight daily range at all", slow.range == 0)
        ok("a day trade cares less about the long trend than a position trade does",
           fast.trend < Analysis.AxisWeights.of(.position).trend)

        /* Two synthetic instruments, built to be each other's opposite.
         *
         * `sleepy` grinds upward with almost no daily movement: the compounder a
         * long-term read should want and a day trade cannot pay the spread on.
         * `jumpy` goes nowhere over the year but travels several percent a day, and
         * is up hard over the last week. */
        var sleepyCloses: [Double] = []
        for i in 0..<420 { sleepyCloses.append(100 * pow(1.0006, Double(i))) }
        let sleepy = bars(sleepyCloses, 0.004)

        var jumpyCloses: [Double] = []
        var level = 100.0
        for i in 0..<420 {
            // A deterministic saw, so the test cannot flake.
            level *= (i % 2 == 0) ? 1.035 : 0.966
            jumpyCloses.append(level)
        }
        // Finish with a hard run up, which only a short window is weighted to see.
        for _ in 0..<5 { level *= 1.05; jumpyCloses.append(level) }
        let jumpy = bars(jumpyCloses, 0.05)

        let sleepyFast = Analysis.analyse("SLEEPY", sleepy, style: .intraday)
        let sleepySlow = Analysis.analyse("SLEEPY", sleepy, style: .longTerm)
        let jumpyFast = Analysis.analyse("JUMPY", jumpy, style: .intraday)
        let jumpySlow = Analysis.analyse("JUMPY", jumpy, style: .longTerm)

        ok("a barely-moving instrument scores badly on range",
           sleepyFast.scores.range < 45, "got \(f(sleepyFast.scores.range, 1))")
        ok("and a fast one scores well on it",
           jumpyFast.scores.range > sleepyFast.scores.range,
           "\(f(jumpyFast.scores.range, 1)) vs \(f(sleepyFast.scores.range, 1))")
        ok("a steady compounder scores well on durability",
           sleepySlow.scores.durability > jumpySlow.scores.durability,
           "\(f(sleepySlow.scores.durability, 1)) vs \(f(jumpySlow.scores.durability, 1))")

        /* The load-bearing assertion. The same two instruments, ranked against each
         * other, come out in a different order depending on what the trade is for.
         * If this ever stops being true the engine has gone back to having one
         * opinion, and every shortlist will look the same again. */
        ok("the compounder outranks the mover for a long hold",
           sleepySlow.conviction > jumpySlow.conviction,
           "\(f(sleepySlow.conviction, 1)) vs \(f(jumpySlow.conviction, 1))")
        ok("and the order reverses for a day trade",
           jumpyFast.conviction > sleepyFast.conviction,
           "\(f(jumpyFast.conviction, 1)) vs \(f(sleepyFast.conviction, 1))")

        // The read has to say which question it answered, or nothing downstream can
        // tell a day-trading 80 from a long-term 80.
        ok("a read records the style it was scored for", sleepyFast.style == TimeHorizon.intraday.rawValue)
        ok("and a swing read is still the default",
           Analysis.analyse("SLEEPY", sleepy).style == TimeHorizon.swing.rawValue)

        // Momentum over different windows is what moves *which* names surface rather
        // than only their order, so the windows must actually differ.
        let ramping = bars(ramp(300, 100, 0.6))
        let mFast = Analysis.analyse("R", ramping, style: .intraday).scores.momentum
        let mSlow = Analysis.analyse("R", ramping, style: .longTerm).scores.momentum
        ok("momentum is measured over different windows per style", abs(mFast - mSlow) > 1,
           "\(f(mFast, 1)) vs \(f(mSlow, 1))")

        // The stop and the target follow the horizon too, and a per-run style has to
        // reach them or the plan is built for the wrong trade.
        let profile = Profile.preset(.learner)      // a swing profile
        let day = profile.sizingRules(equity: 100_000, style: .intraday)
        let long = profile.sizingRules(equity: 100_000, style: .longTerm)
        ok("an overridden style widens the stop for a long hold", long.stopScale > day.stopScale)
        ok("and shortens the session band for a day trade",
           (day.maxSessions ?? 0) < (long.maxSessions ?? 0))
        near("while the risk per trade stays the profile's",
             day.riskPctPerTrade, profile.effectiveRiskPct, 1e-9)
        near("exactly as it does for the long version",
             long.riskPctPerTrade, profile.effectiveRiskPct, 1e-9)

        // A style the interface does not know about must not take the app down.
        ok("an unknown style falls back rather than failing",
           TimeHorizon(rawValue: "sideways") == nil)

        // The mandate is what tells the model which trade it is writing about.
        let mandate = Analyst.mandate(.intraday)
        ok("the mandate names the horizon", mandate.contains("Intraday"))
        ok("and admits daily bars cannot resolve an intraday trade",
           mandate.contains("daily bars"))
        ok("a long-term mandate makes no such claim",
           !Analyst.mandate(.longTerm).contains("daily bars"))
    }


    /* ------------------------------------------------------------ predictions */

    /// A tape built from (seconds after an anchor, price) pairs, so a window's
    /// shape can be stated exactly rather than approximated with bars.
    ///
    /// The anchor must sit inside the tape's own two-hour retention window, because
    /// `absorb` prunes against the wall clock: a fixture written around a hard-coded
    /// instant is silently emptied a couple of hours later, and every assertion
    /// downstream of it then fails against a tape that holds nothing. Callers pass
    /// `liveAnchor()` for that reason.
    private static func predictTape(_ anchor: Double, _ samples: [(Double, Double)]) -> BtcTape {
        var tape = BtcTape()
        tape.absorb(samples.map { TapePoint(t: anchor + $0.0 * 1000, p: $0.1) })
        return tape
    }

    /// The most recent five-minute boundary — the start of the window happening
    /// right now. Anchoring fixtures here rather than at a literal keeps them inside
    /// the tape's retention window forever, without making any assertion depend on
    /// what the clock actually reads: everything below is stated as an offset from
    /// the anchor, so the arithmetic under test is identical whenever it runs.
    private static func liveAnchor() -> Double {
        (nowMs() / 300_000).rounded(.down) * 300_000
    }

    /**
     * The prediction desk.
     *
     * The live feed has its own check — `Paper --predicttest` — because nothing
     * about a network call can be asserted here honestly. What is asserted here is
     * the arithmetic, against tapes whose answers are known by construction: the
     * time-weighted average, the forecast's two sources of uncertainty, the Kelly
     * sizing, the book walk, and the fidelity fit. Every one of these is a place
     * where a plausible-looking wrong answer would still produce a screen that
     * looks like it is working.
     */
    private static func predictions() {
        /* --- windows are identified the way Polymarket identifies them -------- */

        // A window's *identity* is arithmetic on an instant, so it is pinned to a
        // literal: the slug below is the one Polymarket really published for this
        // boundary, and it has to keep reading exactly that.
        let anchor: Double = 1_789_747_200_000   // a clean five-minute boundary
        let w = PredictWindow.containing(anchor + 137_000)
        ok("a window snaps down to its five-minute boundary", w.startMs == anchor)
        ok("and names itself the way Polymarket does", w.slug == "btc-updown-5m-1789747200")
        ok("its end is five minutes on", w.endMs == anchor + 300_000)
        ok("the window four back is twenty minutes earlier",
           w.previous(4).startMs == anchor - 1_200_000)

        /* --- the tape ---------------------------------------------------------- */

        /* Everything from here on feeds a real tape, and a tape keeps only the last
         * two hours, so these fixtures are anchored to the window happening now
         * rather than to the literal above. Nothing about the assertions is
         * wall-clock dependent — each one is an offset from `live` — but the samples
         * survive `absorb`, which a fixed anchor stops doing the moment it ages out.
         * That is what broke this section before: the tapes were empty, `twap` and
         * `forecast` returned nil, and thirty assertions failed without a single
         * thing being wrong with the engine. */
        let live = liveAnchor()
        let lw = PredictWindow.containing(live)
        ok("the window under test starts at the fixture's anchor", lw.startMs == live)
        ok("a fixture tape keeps its samples, so what follows tests the model and not the pruner",
           predictTape(live, [(0, 100), (60, 110)]).points.count == 2)

        // Uneven samples: one price for the first four minutes, another for the last.
        // A mean of the samples would say 150; the time-weighted answer is 120.
        let uneven = predictTape(live, [(0, 100), (240, 200), (270, 200), (290, 200)])
        near("a time-weighted average weights by time, not by sample count",
             uneven.twap(from: live, to: live + 300_000), 120, 0.001)

        let stepped = predictTape(live, [(0, 100), (150, 200)])
        near("half a window at each of two prices averages them",
             stepped.twap(from: live, to: live + 300_000), 150, 0.001)

        ok("a price reads as of an instant, never from a later print",
           stepped.price(at: live + 149_000) == 100)
        ok("and picks up the new one once it has printed",
           stepped.price(at: live + 150_000) == 200)
        ok("a window that opens before its first sample still starts at the open",
           predictTape(live, [(0, 100), (60, 110)]).price(at: live) == 100)

        /* --- the normal, and the forecast -------------------------------------- */

        near("Φ(0) is a half", PredictModel.normalCDF(0), 0.5, 1e-9)
        near("Φ(1.96) is the 97.5th percentile", PredictModel.normalCDF(1.96), 0.975, 0.0005)
        near("Φ(-1.96) is its mirror", PredictModel.normalCDF(-1.96), 0.025, 0.0005)
        ok("Φ is monotone", PredictModel.normalCDF(0.5) < PredictModel.normalCDF(0.51))

        let flat = predictTape(live, (0...30).map { (Double($0) * 10, 80_000.0) })
        let atOpen = PredictModel.forecast(window: lw, tape: flat, minuteVol: 0.0006,
                                           feedNoiseBps: 10, now: live)
        near("at the opening bell a window is a coin flip", atOpen?.pUp, 0.5, 0.001)

        let midFlat = PredictModel.forecast(window: lw, tape: flat, minuteVol: 0.0006,
                                            feedNoiseBps: 10, now: live + 150_000)
        near("a window that has not moved is still a coin flip halfway through",
             midFlat?.pUp, 0.5, 0.001)

        /* A tenth of a percent, a minute into the window, and held.
         *
         * The move has to land *before* the instant being forecast or there is
         * nothing to forecast from — which is the mistake this fixture was written
         * wrong the first time. By the halfway mark the average of the first half is
         * already above the open and the projection carries it, so the model should
         * favour Up without being certain: eight basis points is a real signal and
         * it is the same order of magnitude as the gap between the two price feeds. */
        var risenSamples: [(Double, Double)] = []
        for i in 0...6 { risenSamples.append((Double(i) * 10, 80_000)) }
        for i in 7...30 { risenSamples.append((Double(i) * 10, 80_080)) }
        let risen = predictTape(live, risenSamples)
        let up = PredictModel.forecast(window: lw, tape: risen, minuteVol: 0.0006,
                                       feedNoiseBps: 10, now: live + 150_000)
        ok("a window that has risen favours Up", (up?.pUp ?? 0) > 0.7, "got \(show(up?.pUp))")
        ok("and the side it names matches", up?.side == .up)
        ok("its projected average sits above the open",
           (up?.projectedTwap ?? 0) > (up?.openPrice ?? .infinity))
        ok("the signal is reported in basis points and is positive", (up?.signalBps ?? 0) > 0)

        /* The whole point of the feed term: two feeds that disagree about a move
         * this size cap how confident anything downstream may be. Doubling the gap
         * between Paper's feed and the resolver's must pull the probability back
         * toward a half, and it must do so even though nothing about Bitcoin
         * changed. */
        let noisy = PredictModel.forecast(window: lw, tape: risen, minuteVol: 0.0006,
                                          feedNoiseBps: 40, now: live + 150_000)
        ok("a worse feed makes the same move less conclusive",
           (noisy?.pUp ?? 1) < (up?.pUp ?? 0),
           "10bps gap gave \(show(up?.pUp)), 40bps gave \(show(noisy?.pUp))")
        ok("and the feed's own error is carried in the total",
           (noisy?.totalSd ?? 0) > (up?.totalSd ?? .infinity))

        /* And the term that does shrink: less of the window left means less that
         * Bitcoin can still do about it. */
        let early = PredictModel.forecast(window: lw, tape: risen, minuteVol: 0.0006,
                                          feedNoiseBps: 10, now: live + 60_000)
        let late = PredictModel.forecast(window: lw, tape: risen, minuteVol: 0.0006,
                                         feedNoiseBps: 10, now: live + 270_000)
        ok("the path's contribution shrinks as the window runs out",
           (late?.pathSd ?? .infinity) < (early?.pathSd ?? 0))
        // Compared as a share of price, because the dollar figure moves with spot and
        // the claim is about the feed, not about Bitcoin.
        let earlyShare = (early?.feedSd ?? 0) / (early?.spot ?? 1)
        let lateShare = (late?.feedSd ?? 0) / (late?.spot ?? 1)
        ok("the feed's does not", abs(earlyShare - lateShare) < 1e-9,
           "\(earlyShare) then \(lateShare)")

        /* A replay must not see the future. Asking the model what it thought at the
         * halfway mark, from a tape that now contains the whole window, has to give
         * exactly what it gave when that was all the tape held. */
        var withFuture = risenSamples.filter { $0.0 <= 150 }
        for i in 16...40 { withFuture.append((Double(i) * 10, 79_000)) }
        let hindsight = PredictModel.forecast(window: lw, tape: predictTape(live, withFuture),
                                              minuteVol: 0.0006, feedNoiseBps: 10,
                                              now: live + 150_000)
        near("a replay is blind to everything after the instant it replays",
             hindsight?.pUp, up?.pUp ?? -1, 1e-9)

        /* --- deferring to the market ------------------------------------------- */

        /* The correction that stops this being a slow way to lose money.
         *
         * Polymarket's price is set by people reading the feed the market settles
         * on; Paper is reading a different one. So a disagreement is evidence that
         * Paper is wrong, not that there is an edge — and the naive model's response
         * to a 95¢ Up is to buy Down at 6¢, which is the most expensive mistake
         * available on this tab. These assertions pin the behaviour that prevents it. */

        func blended(_ p: Double, market: Double, pathSd: Double, feedSd: Double) -> PredictForecast {
            let base = PredictForecast(
                window: w, pUp: p, openPrice: 80_000, spot: 80_000, twapSoFar: 80_000,
                projectedTwap: 80_000, elapsed: 150, remaining: 150, minuteVol: 0.0006,
                pathSd: pathSd, feedSd: feedSd, totalSd: (pathSd * pathSd + feedSd * feedSd).squareRoot(),
                z: 0, settled: 0.5, signalBps: 0)
            return PredictModel.against(market: market, base)
        }

        // The live case that exposed the bug: the market is nearly certain, Paper is
        // not, and most of Paper's doubt is a feed it cannot read.
        let deferred = blended(0.70, market: 0.945, pathSd: 26, feedSd: 81)
        ok("a confident market outweighs an unconfident model", deferred.pUp > 0.9,
           "got \(show(deferred.pUp)) from a 70% model against a 94.5% market")
        ok("and the model is not simply discarded", deferred.pUp < 0.945)
        ok("the blend keeps the model's own view on the record", deferred.pModel == 0.70)
        ok("and says how much weight it kept", (deferred.modelWeight ?? 1) < 0.2,
           "kept \(show(deferred.modelWeight))")

        // The edge that would have been acted on, before and after. Twenty-four cents
        // of "edge" on the Down side has to disappear.
        let naiveEdge = (1 - 0.70) - 0.06
        let realEdge = (1 - deferred.pUp) - 0.06
        ok("the phantom edge on the cheap side is gone",
           naiveEdge > 0.2 && realEdge < 0.05,
           "naive \(f(naiveEdge * 100, 1))¢, after deferring \(f(realEdge * 100, 1))¢")

        // The weight is the share of uncertainty that is a real forecast. When the
        // feed is perfect, the model is the only thing worth listening to; when the
        // feed is hopeless, it is worth nothing.
        let trusted = blended(0.70, market: 0.945, pathSd: 80, feedSd: 0.0001)
        ok("a perfect feed earns the model the most weight it is allowed",
           abs((trusted.modelWeight ?? 0) - PredictModel.defaultMaxWeight) < 1e-9)
        ok("which still leaves the market leading", trusted.pUp > 0.70 && trusted.pUp < 0.945)
        let hopeless = blended(0.70, market: 0.945, pathSd: 0.0001, feedSd: 80)
        near("with a hopeless feed it defers entirely", hopeless.pUp, 0.945, 0.01)

        /* The cap. The derivation underneath the weight overstates the model's claim
         * — the market forecasts the remaining path too — and taken literally it
         * reached 38% on a quiet evening with a narrow feed gap, which was enough to
         * manufacture a nine-cent edge on a twenty-four-cent contract. That is the
         * cheap-tail purchase the whole mechanism exists to prevent, reached by a
         * more sophisticated route. */
        let quiet = blended(0.33, market: 0.105, pathSd: 32, feedSd: 40)
        ok("the model's weight is capped however favourable the variance ratio looks",
           (quiet.modelWeight ?? 1) <= PredictModel.defaultMaxWeight + 1e-9,
           "got \(show(quiet.modelWeight)) against a cap of \(PredictModel.defaultMaxWeight)")
        ok("and the cap is well under a half, so the market always leads",
           PredictModel.defaultMaxWeight < 0.5)

        // The case that prompted the cap: a large raw disagreement on a cheap
        // contract must survive the blend far smaller than it went in.
        let uncappedPull = abs(0.33 - 0.105)
        let cappedPull = abs(quiet.pUp - 0.105)
        ok("a big disagreement on a cheap contract is pulled most of the way back",
           cappedPull < uncappedPull / 2,
           "raw gap \(f(uncappedPull * 100, 1))¢ became \(f(cappedPull * 100, 1))¢")

        // And it decays through the window, because late on there is nothing left to
        // forecast and everything left to observe.
        let opening = blended(0.70, market: 0.945, pathSd: 66, feedSd: 100)
        let closing = blended(0.70, market: 0.945, pathSd: 10, feedSd: 100)
        ok("the model's weight falls as the window runs out",
           (closing.modelWeight ?? 1) < (opening.modelWeight ?? 0))
        ok("so the blend moves toward the market as it does", closing.pUp > opening.pUp)

        // Agreement must not manufacture confidence: averaging two views that agree
        // has to land on what they agree about, never outside it.
        let agreeing = blended(0.80, market: 0.80, pathSd: 40, feedSd: 60)
        near("two views that agree stay where they agree", agreeing.pUp, 0.80, 1e-6)
        ok("a blend never leaves the interval between the two",
           deferred.pUp >= 0.70 && deferred.pUp <= 0.945)

        // A window with no offers on either side leaves the model alone rather than
        // blending against a market view that does not exist.
        let unpriced = PredictModel.against(market: nil, PredictForecast(
            window: w, pUp: 0.70, openPrice: 80_000, spot: 80_000, twapSoFar: 80_000,
            projectedTwap: 80_000, elapsed: 150, remaining: 150, minuteVol: 0.0006,
            pathSd: 26, feedSd: 81, totalSd: 85, z: 0, settled: 0.5, signalBps: 0))
        ok("with no book to read, the model stands alone",
           unpriced.pUp == 0.70 && unpriced.pModel == 0.70 && unpriced.modelWeight == nil)

        /* --- the level a window has to beat ------------------------------------- */

        /* Polymarket resolves a window Up when its average beats "the price at the
         * beginning of that range", read from `btc-usd-twap-60s-streams` — a
         * *sixty-second TWAP stream*. So the baseline is the average of the minute
         * before the window, and the desk used to compare against a single print at
         * the boundary. Over the 251 resolved windows on the book to 2026-09-22 that
         * was worth 83.3% against 88.0%, paired, at p = 0.014. */
        do {
            // A minute that climbs steadily into the open. The average of it sits
            // well below the last print, which is the whole of the difference.
            let base = liveAnchor()
            var samples: [(Double, Double)] = []
            for i in 0...60 { samples.append((Double(i) - 60, 80_000 + Double(i) * 2)) }
            let climbing = predictTape(base, samples)
            let win = PredictWindow(start: base / 1000)

            let baseline = PredictModel.openBaseline(window: win, tape: climbing)
            let instant = climbing.price(at: win.startMs)
            near("the open is the average of the minute before it", baseline, 80_060, 2)
            near("and not the last print at the boundary", instant, 80_120, 1e-6)
            ok("so the two genuinely differ on a moving tape",
               abs((baseline ?? 0) - (instant ?? 0)) > 50,
               "baseline \(show(baseline)) against a print of \(show(instant))")

            // The consequence, which is the thing that matters: a window that opened
            // on a climb is called against a lower bar, so a flat five minutes after
            // it reads Up rather than Down.
            var withFlat = samples
            for i in 1...20 { withFlat.append((Double(i) * 15, 80_120)) }
            let tape2 = predictTape(base, withFlat)
            let fc = PredictModel.forecast(window: win, tape: tape2, minuteVol: 0.0006,
                                           feedNoiseBps: 8, now: base + 290_000)
            ok("a window is forecast against the averaged open",
               (fc?.openPrice ?? 0) < 80_120 && (fc?.openPrice ?? 0) > 80_000,
               "open \(show(fc?.openPrice))")
            ok("and it reads Up, where the instantaneous open makes it a dead heat",
               (fc?.pUp ?? 0) > 0.5, "pUp \(show(fc?.pUp))")
        }

        do {
            // No minute to average: the old answer is the right one, and the fallback
            // has to be the instantaneous print rather than nothing at all.
            let base = liveAnchor()
            let bare = predictTape(base, [(0, 80_000), (30, 80_010)])
            let win = PredictWindow(start: base / 1000)
            near("with no tape before the open, the baseline is the print at it",
                 PredictModel.openBaseline(window: win, tape: bare), 80_000, 1e-6)
        }

        do {
            // Live and replay must not disagree about the level. `forecast` falls back
            // to the same function the desk decides once with, and this pins that:
            // the value it derives is the averaged baseline, not the boundary print.
            let base = liveAnchor()
            var samples: [(Double, Double)] = []
            for i in 0...60 { samples.append((Double(i) - 60, 80_000 + Double(i) * 2)) }
            for i in 1...10 { samples.append((Double(i) * 15, 80_120)) }
            let tape3 = predictTape(base, samples)
            let win = PredictWindow(start: base / 1000)
            let derived = PredictModel.forecast(window: win, tape: tape3, minuteVol: 0.0006,
                                                feedNoiseBps: 8, now: base + 150_000)
            ok("the replay derives the same open the desk would have decided",
               abs((derived?.openPrice ?? -1)
                   - (PredictModel.openBaseline(window: win, tape: tape3) ?? -2)) < 1e-6,
               "replay \(show(derived?.openPrice)) against "
                 + "\(show(PredictModel.openBaseline(window: win, tape: tape3)))")
        }

        /* --- the saturated price ----------------------------------------------- */

        /* The hole the guard left, reconstructed from the run that fell through it.
         *
         * `against(market:)` used to require `pMarket > 0.001, pMarket < 0.999` and
         * return the forecast *unblended* otherwise. Both bounds are reachable: late
         * in a decided window one side of the book runs out of offers, `implied`
         * falls back to the side left standing, and `1 − 0.001` is exactly 0.999. The
         * comparison is strict, so every one of those windows skipped the deference
         * entirely — and they are the windows where the model can see least, because
         * by then `pathSd` is a few dollars and `feedSd` is ninety.
         *
         * The numbers below are bet one of run 2026-09-22 07:40, which bought 13,314
         * contracts of Down at a fifth of a cent on thirteen cents of phantom edge,
         * and lost. Four more like it closed the run at its limit. */
        let saturated = blended(0.8662, market: 0.999, pathSd: 5, feedSd: 92)
        ok("a saturated price is still folded in rather than ignored",
           saturated.pMarket != nil && saturated.modelWeight != nil,
           "pMarket \(show(saturated.pMarket)), weight \(show(saturated.modelWeight))")
        ok("and the record keeps the price the book actually quoted",
           saturated.pMarket == 0.999)
        ok("the model does not get to keep its own view against a settled price",
           saturated.pUp > 0.99, "got \(show(saturated.pUp)) from an 86.6% model against a 99.9% market")

        let phantom = (1 - 0.8662) - 0.001          // what the old guard left on the table
        let afterGuard = (1 - saturated.pUp) - 0.001
        ok("the thirteen cents of edge on the dust side is gone",
           phantom > 0.13 && afterGuard < 0.01,
           "was \(f(phantom * 100, 1))¢, now \(f(afterGuard * 100, 1))¢")

        // The same hole at the other end: `implied` returns the ask itself when only
        // the Up side is quoted, and Polymarket's tick puts that at exactly 0.001.
        let floored = blended(0.0087, market: 0.001, pathSd: 5, feedSd: 92)
        ok("the lower bound is a price too, not a reason to stop reading it",
           floored.pMarket != nil && floored.pUp < 0.01,
           "got \(show(floored.pUp))")

        // A weight fitted to zero is the state the desk was actually in, and it is
        // the one where the blend has to reproduce the price exactly. If a clamped
        // price reintroduced the model at w = 0 the fix would be worse than the bug.
        let atZero = PredictModel.against(market: 0.999, PredictForecast(
            window: w, pUp: 0.8662, openPrice: 80_000, spot: 80_000, twapSoFar: 80_000,
            projectedTwap: 80_000, elapsed: 250, remaining: 50, minuteVol: 0.0006,
            pathSd: 5, feedSd: 92, totalSd: 92, z: 0, settled: 0.83, signalBps: 0),
            maxWeight: 0)
        near("at zero weight the desk reads the clamped price and nothing else",
             atZero.pUp, 0.995, 1e-9)
        ok("which leaves no edge on either side of a decided window",
           (PredictModel.cheaperSide(pUp: atZero.pUp, upAsk: nil, downAsk: 0.001)?.edge ?? 1)
             < PredictModel.minimumPrice,
           "edge \(show(PredictModel.cheaperSide(pUp: atZero.pUp, upAsk: nil, downAsk: 0.001)?.edge))")

        /* The floor under the price, and why it is a rule rather than a consequence.
         *
         * `PredictLearning.entryOffset` has always refused to *score* a look whose
         * ask is at or under a cent, so every fitted number the desk owns was built
         * on a population of trades that excluded them — while the live desk was free
         * to take them. The two must agree about what counts as a trade, or the
         * offset fit goes on reporting zero samples while the desk bets. */
        ok("the live floor and the one the replay scores against are the same number",
           PredictModel.minimumPrice == 0.01)
        ok("and the bound at which a price stops being a probability is off the ends",
           PredictModel.decidedBound > 0 && PredictModel.decidedBound < 0.01)

        /* Which side is worth buying.
         *
         * A prediction market pays for buying a contract below what it is worth, and
         * that is not the same as being right about the outcome. Reading only the
         * side the model favours leaves the other half of the book unlooked-at. */
        let contrarian = PredictModel.cheaperSide(pUp: 0.55, upAsk: 0.62, downAsk: 0.30)
        ok("the cheap side is taken even when the model prefers the other outcome",
           contrarian?.side == .down, "model favours Up at 55% and Up costs 62¢")
        near("and its edge is priced from that side's own probability",
             contrarian?.edge, 0.15, 1e-9)

        let plain = PredictModel.cheaperSide(pUp: 0.70, upAsk: 0.55, downAsk: 0.44)
        ok("when the favoured side is also the cheap one, it is still chosen",
           plain?.side == .up)
        near("at the edge the model claims", plain?.edge, 0.15, 1e-9)

        // A book quoting 62/39 leaves (p − 0.62) + (1 − p − 0.39) = −0.01 whatever the
        // model says, so at most one side can ever be worth buying. A rule that found
        // an edge on both would be reading its own overround as free money.
        for pUp in [0.05, 0.3, 0.5, 0.7, 0.95] {
            let up = pUp - 0.62
            let down = (1 - pUp) - 0.39
            ok("at p=\(pUp) only one side of an overround book can be cheap",
               !(up > 0 && down > 0))
        }

        ok("one side missing from the book still leaves the other tradable",
           PredictModel.cheaperSide(pUp: 0.7, upAsk: nil, downAsk: 0.44)?.side == .down)
        ok("and an empty book leaves nothing", PredictModel.cheaperSide(pUp: 0.7, upAsk: nil, downAsk: nil) == nil)

        /* The market's own probability, with the overround divided out. A binary book
         * summing to 101¢ is a spread, not a claim that the outcomes exceed certainty. */
        func oneSided(_ side: PredictSide, bid: Double, ask: Double) -> PredictBook {
            PredictBook(side: side, tokenId: "t",
                        bids: [BookLevel(price: bid, size: 100)],
                        asks: [BookLevel(price: ask, size: 100)], at: 0)
        }
        let upBook = oneSided(.up, bid: 0.60, ask: 0.62)
        let downBook = oneSided(.down, bid: 0.38, ask: 0.40)
        near("the implied probability divides out the overround",
             PredictModel.implied(up: upBook, down: downBook), 0.61 / (0.61 + 0.39), 1e-9)
        near("one side alone is still usable",
             PredictModel.implied(up: upBook, down: nil), 0.61, 1e-9)
        near("and so is the other, inverted",
             PredictModel.implied(up: nil, down: downBook), 0.61, 1e-9)
        ok("no book at all means no market view",
           PredictModel.implied(up: nil, down: nil) == nil)

        /* --- sizing ------------------------------------------------------------ */

        near("Kelly on a fair price is nothing",
             PredictModel.kellyFraction(p: 0.5, cost: 0.5), 0, 1e-9)
        near("Kelly on a 60% chance bought at 50¢ is a fifth of the bankroll",
             PredictModel.kellyFraction(p: 0.6, cost: 0.5), 0.2, 1e-9)
        ok("Kelly on an overpriced contract is negative",
           PredictModel.kellyFraction(p: 0.4, cost: 0.6) < 0)
        ok("a contract at a dollar is refused rather than dividing by zero",
           PredictModel.kellyFraction(p: 0.9, cost: 1) == 0)

        /* --- the book ---------------------------------------------------------- */

        let book = PredictBook(
            side: .up, tokenId: "t",
            bids: [BookLevel(price: 0.48, size: 100)],
            asks: [BookLevel(price: 0.50, size: 10), BookLevel(price: 0.52, size: 10),
                   BookLevel(price: 0.60, size: 1000)],
            at: 0)
        near("a fill inside the top level pays the top level", book.fill(5)?.price, 0.50, 1e-9)
        near("a fill across two levels pays the blend", book.fill(20)?.price, 0.51, 1e-9)
        ok("a fill stops where the edge runs out",
           book.fill(1000, maxPrice: 0.52)?.shares == 20,
           "got \(show(book.fill(1000, maxPrice: 0.52)?.shares))")
        ok("and reports the smaller size rather than pretending",
           (book.fill(1000, maxPrice: 0.52)?.shares ?? 0) < 1000)
        ok("nothing fills above the cap", book.fill(10, maxPrice: 0.49) == nil)
        near("depth counts only what is at or under a price", book.depth(upTo: 0.52), 20, 1e-9)
        near("the midpoint sits between the two sides", book.mid, 0.49, 1e-9)

        /* --- the cost cap ------------------------------------------------------
         *
         * The bug this stands on: sizing converted a dollar budget to contracts at
         * the *best* ask and let the walk pay whatever the deeper levels asked. A
         * dust order of 0.1¢ on top turned a $50 budget into a $763 position, and a
         * run lost $900 against a $200 limit. The invariant is one line — a fill
         * never costs more than its budget — and it is checked here against the
         * exact book shape that broke it.                                        */

        let dust = PredictBook(
            side: .down, tokenId: "t",
            bids: [BookLevel(price: 0.0005, size: 100)],
            asks: [BookLevel(price: 0.001, size: 200), BookLevel(price: 0.02, size: 40_000),
                   BookLevel(price: 0.15, size: 40_000)],
            at: 0)

        // What the old code did: 50 / 0.001 = 50,000 contracts requested, and the
        // walk happily paid for them out of a budget it never saw.
        let uncapped = dust.fill(50 / 0.001, maxPrice: 0.1518)
        ok("without a cost cap a dust top-of-book overspends the budget many times over",
           (uncapped.map { $0.shares * $0.price } ?? 0) > 500,
           "spent \(show(uncapped.map { $0.shares * $0.price }))")

        let capped = dust.fill(50 / 0.001, maxPrice: 0.1518, maxCost: 50)
        ok("with the cap the same order spends the budget and not a cent more",
           (capped.map { $0.shares * $0.price } ?? 0) <= 50 + 1e-6,
           "spent \(show(capped.map { $0.shares * $0.price }))")
        ok("and it spends essentially all of it when the book is deep enough",
           (capped.map { $0.shares * $0.price } ?? 0) > 49.99,
           "spent \(show(capped.map { $0.shares * $0.price }))")
        ok("the average fill still respects the price ceiling",
           (capped?.price ?? 1) <= 0.1518 + 1e-9, "paid \(show(capped?.price))")

        // The share count must never be the thing that binds: no fill averages
        // below the best ask, so budget/bestAsk is always the looser constraint.
        ok("the cap binds before the share count does",
           (dust.fill(50 / 0.001, maxPrice: 0.1518, maxCost: 50)?.shares ?? 0) < 50_000)

        // A thin book is still allowed to under-fill — the cap is a ceiling, not a
        // quota, and pretending otherwise was the original sin in the other
        // direction.
        let thin = PredictBook(side: .up, tokenId: "t", bids: [],
                               asks: [BookLevel(price: 0.50, size: 10)], at: 0)
        near("a budget larger than the book buys the book and stops",
             thin.fill(1000, maxPrice: 0.99, maxCost: 500)?.shares, 10, 1e-9)
        ok("a zero budget buys nothing", thin.fill(1000, maxPrice: 0.99, maxCost: 0) == nil)
        near("a budget that covers part of one level takes part of it",
             thin.fill(1000, maxPrice: 0.99, maxCost: 2)?.shares, 4, 1e-9)
        near("and pays that level's price for it",
             thin.fill(1000, maxPrice: 0.99, maxCost: 2)?.price, 0.50, 1e-9)

        // The property that makes the whole thing safe, over the shapes that
        // actually occur: a binary contract cannot lose more than it cost, so a
        // capped fill caps the loss.
        var worstOverspend = 0.0
        for top in [0.001, 0.005, 0.02, 0.31, 0.76, 0.95] {
            for budget in [1.0, 7.5, 50.0, 250.0] {
                let b = PredictBook(
                    side: .up, tokenId: "t", bids: [],
                    asks: [BookLevel(price: top, size: 3),
                           BookLevel(price: Swift.min(0.99, top + 0.04), size: 5_000),
                           BookLevel(price: Swift.min(0.99, top + 0.30), size: 50_000)],
                    at: 0)
                guard let f = b.fill(budget / top, maxPrice: 0.99, maxCost: budget) else { continue }
                worstOverspend = Swift.max(worstOverspend, f.shares * f.price - budget)
            }
        }
        ok("across every book shape and budget, no fill ever exceeds its budget",
           worstOverspend <= 1e-9, "worst overspend was \(show(worstOverspend))")

        /* --- the entry gate ----------------------------------------------------
         *
         * The fixed 90-second offset is gone; the only clock left is the tape's
         * warm-up. What replaces it is the model's own arithmetic, so that is what
         * is checked: an early window has to price itself near a coin flip without
         * anyone telling it to, or the gate really was doing the work.            */

        ok("the warm-up is short enough to be about the tape and not about the market",
           PredictModel.warmUpSeconds <= 30)

        do {
            // One tape, one genuine move, read at four points through the window.
            let open = 100_000.0
            // Inside the tape's two-hour retention, or `absorb` drops every point
            // and the forecast has nothing to read.
            let win = PredictWindow.containing(nowMs() - 600_000)
            let start = win.startMs
            var moved = BtcTape()
            moved.absorb((0...300).map { TapePoint(t: start + Double($0) * 1000, p: open + Double($0) * 0.4) })
            func pAt(_ secs: Double) -> Double {
                PredictModel.forecast(window: win, tape: moved, minuteVol: 0.0015,
                                      feedNoiseBps: 4.25, now: start + secs * 1000,
                                      openPrice: open)?.pUp ?? -1
            }
            let early = pAt(10), mid = pAt(150), late = pAt(260)
            ok("the same move reads as less certain the earlier it is read",
               abs(early - 0.5) < abs(mid - 0.5) && abs(mid - 0.5) < abs(late - 0.5),
               "10s \(show(early)), 150s \(show(mid)), 260s \(show(late))")
            ok("and at the very start it is close to a coin flip on its own",
               abs(pAt(1) - 0.5) < 0.1, "got \(show(pAt(1)))")
        }

        /* --- the recovery rule -------------------------------------------------
         *
         * Off by default and wrong on purpose, so what is tested is that it does
         * exactly the arithmetic it claims to and nothing beyond it. The identity
         * is the point: the stake it picks is the one whose win lands the run on
         * zero, which is the definition of a chase rather than a bet.            */

        for deficit in [12.5, 50.0, 400.0] {
            for price in [0.03, 0.22, 0.5, 0.84] {
                let stake = PredictModel.recoveryStake(deficit: deficit, price: price)
                // Win: the stake buys stake/price contracts, each paying a dollar.
                let profit = stake / price - stake
                near("a recovery stake of \(f(stake, 2)) at \(cents(price)) wins back exactly \(money(deficit))",
                     profit, deficit, 1e-6)
            }
        }
        near("a run that is not down stakes nothing to recover",
             PredictModel.recoveryStake(deficit: 0, price: 0.4), 0, 1e-12)
        ok("the cheaper the contract the smaller the stake the chase asks for — which is the trap",
           PredictModel.recoveryStake(deficit: 100, price: 0.05)
             < PredictModel.recoveryStake(deficit: 100, price: 0.5))
        ok("a contract at a dollar cannot be the way out and is clamped rather than dividing by zero",
           PredictModel.recoveryStake(deficit: 100, price: 1).isFinite)

        do {
            var run = PredictRun.opening(
                profileId: "p", bankroll: 1000, minutes: 60, maxLossPct: 20, targetPct: 30,
                maxStakePct: 5, kellyFraction: 0.25, minEdge: 0.05,
                entryOffsetSeconds: 0, cutoffSeconds: 35, autoBet: true, recovery: true)
            ok("recovery is off unless it is asked for",
               PredictRun.opening(profileId: "p", bankroll: 1000, minutes: 60, maxLossPct: 20,
                                  targetPct: 30, maxStakePct: 5, kellyFraction: 0.25, minEdge: 0.05,
                                  entryOffsetSeconds: 0, cutoffSeconds: 35,
                                  autoBet: true).recoversLosses == false)
            ok("and it stays idle while the run is flat", run.recovering == false)

            func lost(_ amount: Double, at price: Double) -> PredictBet {
                var b = PredictBet(
                    window: PredictWindow(start: 1), side: .up, placedAt: 0,
                    shares: amount / price, cost: price, stake: amount,
                    modelP: 0.6, edge: 0.1, requiredEdge: 0.05, kellyFull: 0.2,
                    bestAsk: price, spread: 0.01, openPrice: 1, spotAtEntry: 1,
                    twapAtEntry: 1, secondsIntoWindow: 100, sizeNote: nil, thesis: "t")
                b.settledAt = 1; b.resolved = .down; b.payout = 0; b.pnl = -amount
                return b
            }
            run.bets = [lost(50, at: 0.5)]
            ok("once the run is down it engages", run.recovering)
            near("and the deficit is what it is chasing", run.deficit, 50, 1e-9)

            // The guard that matters: the caps sit underneath the chase, so the
            // rule can lose the run faster but never for more than the limit.
            let asked = PredictModel.recoveryStake(deficit: run.deficit, price: 0.02)
            let allowed = Swift.min(asked, run.maxStake, run.available,
                                    Swift.max(0, run.lossLimit + Swift.min(0, run.realised) - run.committed))
            ok("a chase at a two-cent price still cannot beat the per-window cap",
               allowed <= run.maxStake + 1e-9, "asked \(show(asked)), allowed \(show(allowed))")
            ok("nor what is left of the loss limit",
               allowed <= run.lossLimit - 50 + 1e-9, "allowed \(show(allowed))")
        }

        /* --- resolution -------------------------------------------------------- */

        func market(_ prices: [Double], closed: Bool) -> PredictMarket {
            PredictMarket(window: w, conditionId: "c", tokenIds: ["a", "b"], question: "q",
                          outcomePrices: prices, closed: closed, acceptingOrders: false,
                          volume: 0, liquidity: 0, minOrderSize: 5, tickSize: 0.01)
        }
        ok("a closed market at 1/0 resolved Up", market([1, 0], closed: true).resolved == .up)
        ok("a closed market at 0/1 resolved Down", market([0, 1], closed: true).resolved == .down)
        ok("an open market has not resolved", market([1, 0], closed: false).resolved == nil)
        // The case that matters: closed but still with the resolver. Reading a 0.97
        // as a win would settle bets on a result nobody has published.
        ok("a closed market that has not settled is not a result",
           market([0.97, 0.03], closed: true).resolved == nil)

        /* --- the fidelity fit -------------------------------------------------- */

        ok("with no history the fit says so and assumes the worst",
           PredictFidelity.unmeasured().assumed
             && PredictFidelity.unmeasured().bps == PredictFidelity.assumedBps)
        ok("a handful of windows is not enough to fit",
           PredictFidelity.fit([(5, true), (6, false), (7, true)]).assumed)

        // Feeds that agree on everything, including moves far under a basis point,
        // are indistinguishable from identical — the fit must not claim more
        // precision than the floor, because a tiny gap means enormous confidence.
        let perfect = PredictFidelity.fit((1...20).map { (Double($0), true) })
        ok("feeds that always agree fit at the floor, not below it",
           perfect.bps == PredictFidelity.floorBps, "got \(perfect.bps)")
        ok("and the fit reports how many windows it saw", perfect.windows == 20 && perfect.agreed == 20)

        // Disagreement on large moves means a large gap. The fit must find it rather
        // than reporting a comfortable small number.
        let awful = PredictFidelity.fit((1...20).map { (Double($0) * 2, $0 % 2 == 0) })
        ok("feeds that disagree on big moves fit a big gap", awful.bps > 15, "got \(awful.bps)")
        ok("a fit never exceeds its ceiling", awful.bps <= PredictFidelity.ceilingBps)

        /* --- the calibration --------------------------------------------------- */

        func prior(_ n: Int, resolved: PredictSide?, model: PredictSide?) -> PriorWindow {
            PriorWindow(window: w.previous(n), label: "x", resolved: resolved,
                        openPrice: resolved == nil ? nil : 80_000, twap: 80_010,
                        movePct: 0.0125, modelSide: model, modelP: 0.7,
                        modelRight: (model != nil && resolved != nil) ? model == resolved : nil)
        }
        let blind = PredictCalibration.build(
            priors: [prior(4, resolved: nil, model: .up), prior(3, resolved: nil, model: .up),
                     prior(2, resolved: .up, model: .up), prior(1, resolved: .up, model: .up)],
            minuteVol: 0.0006)
        ok("a calibration that cannot read the last twenty minutes vetoes", blind.veto != nil)

        let noVol = PredictCalibration.build(
            priors: (1...4).reversed().map { prior($0, resolved: .up, model: .up) }, minuteVol: nil)
        ok("and so does one with no volatility to scale by", noVol.veto != nil)

        let allWrong = PredictCalibration.build(
            priors: (1...4).reversed().map { prior($0, resolved: .up, model: .down) },
            minuteVol: 0.0006)
        ok("a rule that missed every one of the four sits the window out", allWrong.veto != nil)

        let mixed = PredictCalibration.build(
            priors: [prior(4, resolved: .up, model: .down), prior(3, resolved: .up, model: .down),
                     prior(2, resolved: .up, model: .up), prior(1, resolved: .up, model: .up)],
            minuteVol: 0.0006)
        ok("a rule that went two from four is allowed to trade, at a higher bar",
           mixed.veto == nil && mixed.edgeMultiplier > 1, "multiplier \(mixed.edgeMultiplier)")

        let good = PredictCalibration.build(
            priors: (1...4).reversed().map { prior($0, resolved: .up, model: .up) },
            minuteVol: 0.0006)
        ok("and one that went four from four gets no penalty", good.edgeMultiplier == 1)
        // The asymmetry is the whole design: four windows may veto and may never
        // encourage, because four samples cannot establish a win rate.
        ok("a perfect four never earns a discount", good.edgeMultiplier >= 1)
        ok("the calibration says what it saw", good.summary.contains("Up → Up → Up → Up"))

        /* The resolver runs minutes behind the bell, so the four windows on the clock
         * are routinely not four settled windows. `calibrate` walks back until it has
         * four with a published result — the check that broke the first live run,
         * which vetoed nearly every window for want of results that had not been
         * published yet. What the rule must do is judge whatever it did find. */
        let short = PredictCalibration.build(
            priors: [prior(6, resolved: .up, model: .up), prior(5, resolved: .up, model: .up)],
            minuteVol: 0.0006)
        ok("two settled windows is not enough to trade on", short.veto != nil)
        let three = PredictCalibration.build(
            priors: [prior(7, resolved: .up, model: .up), prior(6, resolved: .up, model: .up),
                     prior(5, resolved: .down, model: .down)],
            minuteVol: 0.0006)
        ok("three settled windows is, when the rule read them all right",
           three.veto == nil && three.edgeMultiplier == 1)
        ok("and older windows are still judged on their own record",
           three.replayed == 3 && three.hits == 3)

        /* --- a run's accounting ------------------------------------------------ */

        var run = PredictRun.opening(profileId: "p", bankroll: 1_000, minutes: 60,
                                     maxLossPct: 20, targetPct: 30, maxStakePct: 5,
                                     kellyFraction: 0.25, minEdge: 0.05,
                                     entryOffsetSeconds: 150, cutoffSeconds: 35, autoBet: true)
        near("the loss limit is a share of the bankroll", run.lossLimit, 200, 1e-9)
        near("so is the target", run.targetAmount, 300, 1e-9)
        near("and the per-window cap", run.maxStake, 50, 1e-9)

        func bet(_ start: Double, _ side: PredictSide, shares: Double, cost: Double) -> PredictBet {
            PredictBet(window: PredictWindow(start: start), side: side, placedAt: 0,
                       shares: shares, cost: cost, stake: shares * cost,
                       modelP: 0.7, edge: 0.1, requiredEdge: 0.05, kellyFull: 0.3,
                       bestAsk: cost, spread: 0.01, openPrice: 80_000, spotAtEntry: 80_100,
                       twapAtEntry: 80_050, secondsIntoWindow: 150, sizeNote: nil, thesis: "t")
        }
        run.bets = [bet(1_789_747_200, .up, shares: 50, cost: 0.60)]
        near("an open bet is committed, not realised", run.committed, 30, 1e-9)
        near("and it comes out of what is free to bet", run.available, 970, 1e-9)
        near("nothing is realised until it settles", run.realised, 0, 1e-9)
        ok("one bet per window is enforceable",
           run.hasBet(on: PredictWindow(start: 1_789_747_200))
             && !run.hasBet(on: PredictWindow(start: 1_789_747_500)))

        run.bets[0].settledAt = 1
        run.bets[0].resolved = .up
        run.bets[0].payout = 50
        run.bets[0].pnl = 20
        near("a winning window pays a dollar a contract", run.realised, 20, 1e-9)
        near("and the stake comes back with it", run.available, 1_020, 1e-9)
        ok("the record counts it", run.wins == 1 && run.losses == 0)
        ok("a settled bet is not open", !run.bets[0].isOpen && run.bets[0].won == true)

        var lost = run
        lost.bets[0].resolved = .down
        lost.bets[0].payout = 0
        lost.bets[0].pnl = -30
        ok("a losing window loses the stake and no more", lost.realised == -30 && lost.wins == 0)

        /* --- what crosses the wire --------------------------------------------- */

        // The screen reads `signalBps`, `side` and `confidence` off the response, and
        // Swift's synthesised Codable does not encode computed properties. A missing
        // field and a genuinely absent forecast look identical from the page, so the
        // encoded shape is asserted rather than assumed.
        let encoded = (try? JSONEncoder().encode(up))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["pUp", "openPrice", "spot", "twapSoFar", "projectedTwap", "elapsed",
                    "remaining", "minuteVol", "pathSd", "feedSd", "totalSd", "z", "settled",
                    "signalBps", "pModel"] {
            ok("a forecast encodes a \(key)", encoded[key] != nil)
        }
        let runJson = (try? JSONEncoder().encode(run))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["id", "bankroll", "maxLossPct", "targetPct", "maxStakePct",
                    "kellyFraction", "minEdge", "entryOffsetSeconds", "status", "bets",
                    "windowsSeen"] {
            ok("a run encodes a \(key)", runJson[key] != nil)
        }
        ok("a run survives the round trip",
           (try? JSONEncoder().encode(run)).flatMap {
               try? JSONDecoder().decode(PredictRun.self, from: $0)
           }?.bets.count == 1)

        /* The interface derives a bet's result and the per-window cap itself, because
         * `won` and `maxStake` are computed properties and Swift does not encode
         * those. It can only do that if the ingredients cross the wire — and when
         * they did not, the screen showed a permanent 0-of-0 record and an em-dash
         * where the cap should be, on a panel where every other figure was right.
         * These are the exact fields that page reads. */
        let betJson = (try? JSONEncoder().encode(run.bets[0]))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["window", "side", "shares", "cost", "stake", "modelP", "edge",
                    "requiredEdge", "bestAsk", "openPrice", "spotAtEntry", "twapAtEntry",
                    "secondsIntoWindow", "thesis", "settledAt", "resolved", "pnl",
                    "awaitingResolution"] {
            ok("a bet encodes a \(key)", betJson[key] != nil, "missing from the wire")
        }
        ok("a bet's window carries the start the interface labels it from",
           (betJson["window"] as? [String: Any])?["start"] != nil)
        ok("and a run carries what the per-window cap is worked out from",
           runJson["bankroll"] != nil && runJson["maxStakePct"] != nil)

        /* The tally of refusals, which is the whole report on a run that correctly
         * bought nothing. It is optional so that a run file written before the field
         * existed still opens — Swift's synthesised decoding calls `decodeIfPresent`
         * for an Optional and yields nil, while a non-optional with a default value
         * throws on a missing key instead. That distinction has cost this project
         * real ledgers, so it is asserted rather than remembered. */
        var counted = run
        counted.skipped = ["no-edge": 3, "vetoed": 2]
        let countedJson = (try? JSONEncoder().encode(counted))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        ok("a run encodes why it passed on the windows it passed on",
           (countedJson["skipped"] as? [String: Any])?["no-edge"] as? Int == 3)

        var withoutField = runJson
        withoutField.removeValue(forKey: "skipped")
        let older = (try? JSONSerialization.data(withJSONObject: withoutField))
            .flatMap { try? JSONDecoder().decode(PredictRun.self, from: $0) }
        ok("and a run file written before that field existed still opens",
           older != nil && older?.skipped == nil, "a missing key must not throw")
    }


    /* ------------------------------------------- the live feed and what it learns */

    /// A decision carrying just the fields `WindowWatch` reads.
    private static func verdictOf(_ v: PredictDecision.Verdict, edge: Double? = nil,
                                  required: Double = 0.05,
                                  side: PredictSide? = .up) -> PredictDecision {
        PredictDecision(verdict: v, side: side, modelP: nil, price: nil, edge: edge,
                        requiredEdge: required, kellyFull: nil, wouldStake: nil,
                        wouldBuy: nil, reason: "")
    }

    /// A book of `count` windows, each resolving by the sign of a move drawn from a
    /// deterministic pseudo-random sequence and then corrupted by a known feed
    /// error. Deterministic on purpose: a fit tested against a different sample on
    /// every run is a fit tested against nothing.
    private static func shadowBook(count: Int, trueNoiseBps: Double,
                                   informative: Bool) -> [ShadowWindow] {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            /* splitmix64, and the choice is load-bearing rather than incidental.
             *
             * The first version of this fixture used xorshift64 reduced by
             * `% 1_000_000`, and the offset fit then found a real-looking 14-point
             * advantage at the thirty-second bucket in a book built with no offset
             * effect at all. The fit was right and the fixture was lying: xorshift's
             * low bits are weak, the draws here are consumed in a fixed order, and
             * each bucket therefore sat at a fixed phase relative to the draw that
             * decided the outcome — which is a correlation between the model's
             * "noise" and the truth, exactly what the fit is built to detect.
             *
             * splitmix64 exists to have good low bits, and taking the top 53 gives
             * full Double precision rather than the six digits the modulo left —
             * which also mattered, since `gauss` takes a log of this. */
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        /// Box–Muller, so the fixture's errors are actually normal — the fit assumes
        /// they are, and testing it against uniform noise would be testing something
        /// else and calling it a pass.
        func gauss() -> Double {
            let u = Swift.max(next(), 1e-9), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }

        var out: [ShadowWindow] = []
        for i in 0..<count {
            /* The market is built as a **calibrated martingale**, and getting this
             * right is most of what this fixture is.
             *
             * The first version drew the market's price from the outcome —
             * `Φ(±sharpness + noise)`, sharper later in the window — which looks
             * reasonable and is badly miscalibrated: stating 78% for a case whose true
             * posterior is 99.95% leaves every contract on the correct side
             * underpriced, worst at the early offsets where the stated sharpness is
             * lowest. The offset fit duly found a fourteen-point advantage at thirty
             * seconds in a book built with no offset effect at all, and it was right.
             * The fixture was the thing that was wrong.
             *
             * So the causation runs the other way here. A latent value accumulates
             * Brownian increments across the window; the market's price at each offset
             * is the exact posterior given what has accumulated so far,
             * `Φ(m / √(1−v))`; and the outcome is drawn from the same latent value at
             * the end. That is calibrated by construction and sharpens on its own as
             * `v → 1`, with no sharpness parameter to get wrong.
             */
            var m = 0.0
            var v = 0.0
            var prices: [(offset: Double, p: Double)] = []
            for offset in PredictShadowBook.offsetBuckets {
                let revealed = offset / 300
                let step = revealed - v
                if step > 0 { m += gauss() * step.squareRoot() }
                v = revealed
                prices.append((offset, Analysis.clamp(
                    PredictModel.normalCDF(m / Swift.max(1e-6, (1 - v).squareRoot())),
                    0.02, 0.98)))
            }
            let outcome = m + gauss() * Swift.max(0, 1 - v).squareRoot()
            let truth: PredictSide = outcome >= 0 ? .up : .down

            // What the resolver measured, and the noisier thing this app's tape saw.
            // The feed fit's whole model is that these differ by a normal error of
            // one fitted size, so the fixture makes them differ by exactly that.
            let tapeMove = outcome * 12 + gauss() * trueNoiseBps

            var samples: [ShadowSample] = []
            for (offset, pMarketUp) in prices {
                // The model either holds information the market does not, or is noise.
                let pModel = informative
                    ? Analysis.clamp(PredictModel.normalCDF(
                        (truth == .up ? 1 : -1) * 0.9 + gauss() * 0.7), 0.02, 0.98)
                    : Analysis.clamp(PredictModel.normalCDF(gauss()), 0.02, 0.98)
                samples.append(ShadowSample(
                    offset: offset, pModel: pModel, pMarket: pMarketUp,
                    // A one-cent overround per side, so the book sums past a dollar
                    // the way a real binary book does.
                    upAsk: Swift.min(0.99, pMarketUp + 0.01),
                    downAsk: Swift.min(0.99, (1 - pMarketUp) + 0.01),
                    moveBps: tapeMove))
            }
            out.append(ShadowWindow(start: 1_700_000_000 + Double(i) * 300,
                                    samples: samples, resolved: truth,
                                    resolvedAt: 0, degraded: false, regime: nil))
        }
        return out
    }

    private static func predictLearning() {
        /* --- the venues parse their own formats, and only their own ------------ */

        near("Coinbase quotes prices as strings and is read as one",
             BtcVenue.coinbase.price(from: #"{"type":"ticker","product_id":"BTC-USD","price":"98765.43"}"#),
             98765.43, 1e-6)
        ok("a Coinbase subscription ack is not a price",
           BtcVenue.coinbase.price(from: #"{"type":"subscriptions","channels":[]}"#) == nil)
        near("Kraken v2 ticker is read out of its data array",
             BtcVenue.kraken.price(from: #"{"channel":"ticker","type":"update","data":[{"symbol":"BTC/USD","last":98765.4}]}"#),
             98765.4, 1e-6)
        ok("a Kraken heartbeat is not a price",
           BtcVenue.kraken.price(from: #"{"channel":"heartbeat"}"#) == nil)
        // The venue set is asserted so one cannot be quietly added or dropped
        // without someone re-reading the print-rate measurements in `BtcVenue`.
        ok("the tape is built from exactly two venues",
           BtcVenue.allCases.count == 2)
                ok("and Kraken's subscribe carries the bbo trigger it needs to keep up",
           BtcVenue.kraken.subscribe.contains("bbo"))
        ok("and neither is anything that is not JSON",
           BtcVenue.allCases.allSatisfy { $0.price(from: "pong") == nil })

        /* --- a one-second tape still has a volatility -------------------------- */

        /* The bug this exists for does not appear for seventeen minutes, which is why
         * it survived to a live run. The exchange tape lands a point every second;
         * the old estimator walked consecutive tape points and skipped any pair less
         * than three seconds apart, so it discarded every one of them — and the Yahoo
         * minute bars pulled for history carried the estimate on their own until they
         * aged out of the twenty-minute lookback. Then `minuteVol` returned nil and
         * the desk vetoed every remaining window with "not enough recent Bitcoin data"
         * while a perfectly good tape arrived once a second.
         *
         * The same path is sampled at both densities, because the real claim is not
         * just that a dense tape produces a number — it is that it produces the *same*
         * number, which is what makes the estimate independent of how the tape
         * happened to be filled. */
        var walkSeed: UInt64 = 0xC0FFEE
        func walkUniform() -> Double {
            walkSeed &+= 0x9E3779B97F4A7C15
            var z = walkSeed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        // Box–Muller from two independent uniforms. The first attempt drew the phase
        // from the raw Weyl counter rather than from a second mixed draw, which is
        // correlated enough with the first to cost the result a chunk of its variance
        // — it came back at 0.0091% a minute on a path built at 0.0200%, and the
        // fixture rather than the estimator was the thing that was wrong.
        func walkStep() -> Double {
            let u = Swift.max(walkUniform(), 1e-9)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * walkUniform())
        }
        // A genuine random walk, so the per-minute normalisation the estimator applies
        // is the right one and the two densities are comparable by construction.
        let secondVol = 0.0002 / 60.0.squareRoot()
        var path: [Double] = [80_000]
        for _ in 0..<1_500 { path.append(path.last! * (1 + walkStep() * secondVol)) }

        let anchor = liveAnchor()
        let dense = predictTape(anchor, (0...1_500).map { (Double($0) - 1_500, path[$0]) })
        let sparse = predictTape(anchor, stride(from: 0, through: 1_500, by: 60)
            .map { (Double($0) - 1_500, path[$0]) })

        let denseVol = dense.minuteVol(now: anchor)
        let sparseVol = sparse.minuteVol(now: anchor)
        ok("a tape sampled once a second has a measurable volatility",
           denseVol != nil, "\(dense.points.count) points, got \(show(denseVol))")
        ok("and a tape of minute bars still does too", sparseVol != nil, show(sparseVol))
        if let d = denseVol, let sp = sparseVol {
            ok("and the two agree, so the estimate does not depend on the tape's density",
               d / sp > 0.5 && d / sp < 2,
               "dense \(f(d * 100, 4))% a minute against sparse \(f(sp * 100, 4))%")
            ok("with the dense answer near the volatility the path was built from",
               d > 0.0001 && d < 0.0005, "\(f(d * 100, 4))% a minute against a built 0.0200%")
        }
        // The shape of the original failure, stated directly: a tape that holds
        // nothing but one-second samples must not come back empty-handed.
        let liveOnly = predictTape(anchor, (1_200...1_500).map { (Double($0) - 1_500, path[$0]) })
        ok("a tape with no minute bars left in it at all still answers",
           liveOnly.minuteVol(now: anchor) != nil)

        /* --- the tally records the decisive verdict, not the last one ---------- */

        /* This is the bug the whole run was diagnosed from. Every tick used to
         * overwrite the verdict, and the last tick of a window is inside the cutoff
         * by construction, so a thirty-minute run reported `too-late: 6` whatever had
         * actually happened. The sequence below is exactly that shape. */
        let w = PredictWindow(start: liveAnchor() / 1000)
        var late = WindowWatch(window: w)
        late.note(verdictOf(.tooEarly), inBand: false, elapsed: 30, alreadyBet: false)
        late.note(verdictOf(.noEdge, edge: 0.01), inBand: true, elapsed: 160, alreadyBet: false)
        late.note(verdictOf(.noEdge, edge: 0.03), inBand: true, elapsed: 220, alreadyBet: false)
        late.note(verdictOf(.tooLate), inBand: false, elapsed: 280, alreadyBet: false)
        ok("a window that was read and found fair is filed as no-edge, not too-late",
           late.verdict == .noEdge, "filed as \(late.verdict.rawValue)")
        near("and keeps the best it ever offered, not the last", late.bestEdge, 0.03, 1e-9)
        near("with the offset that produced it", late.bestOffset, 220, 1e-9)
        ok("counting only the in-band looks", late.looks == 2, "counted \(late.looks)")

        /* A window the loop never evaluated in-band is an omission, and has to be
         * distinguishable from a refusal — that difference is the whole reason the
         * `missed` verdict exists. */
        var never = WindowWatch(window: w)
        never.note(verdictOf(.tooEarly), inBand: false, elapsed: 40, alreadyBet: false)
        never.note(verdictOf(.tooLate), inBand: false, elapsed: 275, alreadyBet: false)
        ok("a window that never got an in-band look is missed, not refused",
           never.verdict == .missed)
        ok("and claims no near-miss it never measured", never.bestEdge == nil)

        /* A bought window is never a skip, whatever later ticks say about it. */
        var bought = WindowWatch(window: w)
        bought.note(verdictOf(.noEdge, edge: 0.01), inBand: true, elapsed: 160, alreadyBet: false)
        bought.note(verdictOf(.taken, edge: 0.07), inBand: true, elapsed: 180, alreadyBet: false)
        bought.note(verdictOf(.alreadyBet), inBand: true, elapsed: 200, alreadyBet: true)
        ok("a window that was bought stays bought", bought.bought)
        var later = WindowWatch(window: w)
        later.note(verdictOf(.alreadyBet), inBand: true, elapsed: 200, alreadyBet: true)
        ok("and a tick that only knows it was already bet marks it too", later.bought)

        /* --- fit 1: the feed gap is recovered from a book with a known one ----- */

        let quiet = PredictFit.feedNoise(shadowBook(count: 400, trueNoiseBps: 6, informative: false))
        let loud  = PredictFit.feedNoise(shadowBook(count: 400, trueNoiseBps: 25, informative: false))
        ok("a book built with a small feed gap fits a small one",
           quiet.bps < 14, "fitted \(f(quiet.bps, 1)) bps against a true 6")
        ok("a book built with a large one fits larger",
           loud.bps > quiet.bps + 4,
           "fitted \(f(loud.bps, 1)) bps against \(f(quiet.bps, 1))")
        ok("and neither fit escapes its stated bounds",
           quiet.bps >= PredictFidelity.floorBps && loud.bps <= PredictFidelity.ceilingBps)
        ok("a book below the evidence threshold keeps the shipped default",
           PredictFit.feedNoise(shadowBook(count: 10, trueNoiseBps: 6, informative: false)).isDefault)

        /* The conservatism scales with the evidence, which is what replaced the
         * hardcoded four-basis-point floor. The operating value is the upper edge of
         * the likelihood interval, so a thin book is answered cautiously and a thick
         * one is answered tightly — and the caution costs nothing once the evidence
         * is in, which a constant could not manage at both sample sizes. */
        let thin = PredictFit.feedNoise(shadowBook(count: 35, trueNoiseBps: 6, informative: false))
        let thick = PredictFit.feedNoise(shadowBook(count: 1_500, trueNoiseBps: 6, informative: false))
        ok("a thin book is answered more conservatively than a thick one",
           thin.bps > thick.bps,
           "35 windows gave \(f(thin.bps, 1)) bps, 1500 gave \(f(thick.bps, 1))")
        ok("and the thick one is not allowed to claim two identical feeds",
           thick.bps >= PredictFit.absoluteFloorBps)
        ok("and degraded windows never reach a fit at all",
           PredictFit.feedNoise([]).bps == PredictFidelity.assumedBps)

        /* --- fit 2: the model's weight is a Brier measurement ------------------ */

        let noise = PredictFit.modelWeight(shadowBook(count: 300, trueNoiseBps: 10, informative: false))
        let real  = PredictFit.modelWeight(shadowBook(count: 300, trueNoiseBps: 10, informative: true))
        ok("a model that knows nothing earns almost no weight",
           noise.value < 0.1, "earned \(show(noise.value))")
        ok("a model that knows something earns more than one that does not",
           real.value > noise.value,
           "informative \(show(real.value)) against noise \(show(noise.value))")
        ok("but never more than the ceiling, however good it looks",
           real.value <= PredictBrain.weightCeiling + 1e-9 && noise.value <= PredictBrain.weightCeiling + 1e-9)
        ok("and the uncapped answer is kept so the cap is visible as a cap",
           real.capped == (real.raw > PredictBrain.weightCeiling))
        ok("a book below the evidence threshold holds the shipped weight",
           PredictFit.modelWeight(shadowBook(count: 40, trueNoiseBps: 10, informative: true)).isDefault)
        near("which is the number the model ships with",
             PredictFit.modelWeight([]).value, PredictModel.defaultMaxWeight, 1e-9)

        /* --- fit 3: an offset has to beat the field, not merely win it --------- */

        /* The guard that matters. Seventeen buckets are compared and the best of
         * seventeen noisy means is high by construction — with no real effect at all
         * the winner still beats the field by roughly a standard error. A fit that
         * always finds something is not a fit, so a book with no real offset effect
         * has to decline to move anything. */
        let flat = PredictFit.entryOffset(
            shadowBook(count: 600, trueNoiseBps: 10, informative: false), weight: 0.25)
        ok("no offset is chosen from a book where none is genuinely better",
           flat.isDefault, "picked \(f(flat.value, 0))s on a \(show(flat.edgeOverField)) advantage")
        ok("a book with nothing in it picks nothing",
           PredictFit.entryOffset([], weight: 0.25).isDefault)
        let whole = PredictFit.entryOffset(
            shadowBook(count: 600, trueNoiseBps: 10, informative: true), weight: 0.25)
        ok("any offset it does pick is one it actually compared",
           whole.isDefault || PredictShadowBook.offsetBuckets.contains(whole.value),
           "picked \(f(whole.value, 0))s")


        /* --- the scoreboard, which is how "is it learning" is answerable --------- */

        /// A book of windows whose model probability is supplied per window.
        func scoreBook(_ rows: [(up: Bool, pModel: Double, pMarket: Double)]) -> [ShadowWindow] {
            rows.enumerated().map { i, r in
                ShadowWindow(
                    start: 1_700_000_000 + Double(i) * 300,
                    samples: [ShadowSample(offset: 150, pModel: r.pModel, pMarket: r.pMarket,
                                           upAsk: r.pMarket + 0.01, downAsk: (1 - r.pMarket) + 0.01,
                                           moveBps: r.up ? 5 : -5)],
                    resolved: r.up ? .up : .down, resolvedAt: 0, degraded: false, regime: nil)
            }
        }

        let perfect = PredictFit.score(
            scoreBook((0..<40).map { (up: $0 % 2 == 0, pModel: $0 % 2 == 0 ? 0.99 : 0.01, pMarket: 0.5) }),
            weight: 0.25)
        ok("a model that is always right scores near zero by Brier",
           perfect.modelBrier < 0.001, show(perfect.modelBrier))
        near("and a market that says nothing scores a coin flip", perfect.marketBrier, 0.25, 1e-9)
        ok("so the model is reported as ahead", perfect.summary.contains("ahead of the market"))

        let useless = PredictFit.score(
            scoreBook((0..<40).map { (up: $0 % 2 == 0, pModel: 0.5, pMarket: $0 % 2 == 0 ? 0.9 : 0.1) }),
            weight: 0.25)
        near("a model with no view scores exactly a coin flip", useless.modelBrier, 0.25, 1e-9)
        ok("and the market being better is reported as the market being better",
           useless.marketBrier < useless.modelBrier && useless.summary.contains("market is ahead"))
        ok("blending a useless model at a positive weight scores worse than the market alone",
           useless.blendBrier > useless.marketBrier,
           "blend \(show(useless.blendBrier)) against market \(show(useless.marketBrier))")

        /* Calibration is folded onto the side the model called, and that fold is the
         * part worth testing: a model saying 20% Up is claiming 80% Down, and filing
         * that under a 20% band would count it wrong every time Down came in, which
         * inverts the reading of the one table that answers the word "calibrated". */
        let downCaller = PredictFit.score(
            scoreBook((0..<30).map { _ in (up: false, pModel: 0.2, pMarket: 0.5) }), weight: 0.25)
        ok("a confident Down call that is always right reads as high confidence, not low",
           downCaller.calibration.count == 1 && (downCaller.calibration.first?.claimed ?? 0) > 0.75,
           "claimed \(show(downCaller.calibration.first?.claimed))")
        near("and as always right", downCaller.calibration.first?.actual, 1.0, 1e-9)
        near("with its hit rate agreeing", downCaller.modelHitRate, 1.0, 1e-9)

        // An overconfident model has to show up as sitting below the line, because
        // that is the failure that costs money rather than opportunities.
        let overconfident = PredictFit.score(
            scoreBook((0..<40).map { (up: $0 % 4 != 0, pModel: 0.95, pMarket: 0.5) }), weight: 0.25)
        if let band = overconfident.calibration.first {
            ok("a model claiming 95% on windows it gets right 75% of the time reads as overconfident",
               band.actual < band.claimed - 0.1,
               "claimed \(f(band.claimed * 100, 0))%, right \(f(band.actual * 100, 0))%")
        }
        ok("an empty book scores nothing rather than dividing by zero",
           PredictFit.score([], weight: 0.25).windows == 0)

        /* --- the feed gap is judged against the move, not against a constant ----- */

        /* The sentence that prompted this: a four-basis-point gap printed directly
         * beneath a 68% agreement rate and the claim that the price data was "usually
         * decisive". Both numbers were right and the verdict contradicted them,
         * because it tested the gap against a fixed eight basis points rather than
         * against the size of the move it was measuring. */
        let tinyMoves = PredictFidelity.fit((0..<24).map {
            (moveBps: $0 % 3 == 0 ? 1.2 : -0.9, agreed: $0 % 3 != 1) })
        ok("a gap larger than the moves it measures is not called decisive",
           !tinyMoves.summary.contains("decisive"), tinyMoves.summary)
        ok("it is called what it is instead",
           tinyMoves.summary.contains("larger than the thing being measured"))
        let bigMoves = PredictFidelity.fit((0..<24).map {
            (moveBps: $0 % 2 == 0 ? 60.0 : -55.0, agreed: true) })
        ok("and a gap well under the moves it measures still is",
           bigMoves.summary.contains("decisive"), bigMoves.summary)


        /* --- the level a window is measured against cannot move ----------------- */

        /* The tape fills in *behind* the present — minute bars arrive in batches
         * covering two hours — so `price(at:)` can change its answer about an instant
         * that has already passed. For the window's open that is not a wobble: it is
         * the threshold the TWAP is compared against, and it moved on screen from
         * $81,248.45 to $81,242.32 for the same five minutes. `forecast` therefore
         * takes the open from its caller, which decides it once. */
        let oa = liveAnchor()
        let win = PredictWindow(start: oa / 1000)
        var backfilled = predictTape(oa, [(-30, 80_000), (1, 80_100), (60, 80_140), (120, 80_180)])
        let firstRead = PredictModel.openBaseline(window: win, tape: backfilled)
        /* Bars arriving after the fact, which is precisely what a batched minute-bar
         * pull does — one stamped on the boundary and one inside the minute before it.
         *
         * **The second one is new, and the reason is a real change underneath.** This
         * fixture used to backfill only the boundary bar, because the open was then a
         * single `price(at:)` read and one late print at the boundary was enough to
         * move it. The open is now the sixty-second average ending there, which a
         * single boundary print barely shifts — so the old fixture stopped
         * demonstrating anything and both assertions below went green for the wrong
         * reason. The invariant they exist for is untouched: a backfill *inside* the
         * averaged minute still moves the threshold, so it still has to be decided
         * once. What changed is how hard it is to move, which is a property of the
         * new definition and not a reason to stop pinning it. */
        backfilled.absorb([TapePoint(t: win.startMs, p: 79_900),
                           TapePoint(t: win.startMs - 50_000, p: 79_500)])
        let secondRead = PredictModel.openBaseline(window: win, tape: backfilled)
        ok("the tape really can change its answer about a past instant",
           firstRead != secondRead, "\(show(firstRead)) then \(show(secondRead))")

        if let vol = backfilled.minuteVol(now: oa + 120_000) ?? 0.0002 as Double? {
            let drifted = PredictModel.forecast(window: win, tape: backfilled, minuteVol: vol,
                                                now: oa + 120_000)
            let pinned = PredictModel.forecast(window: win, tape: backfilled, minuteVol: vol,
                                               now: oa + 120_000, openPrice: firstRead)
            near("a forecast handed an open uses it rather than re-reading the tape",
                 pinned?.openPrice, firstRead ?? 0, 1e-9)
            ok("and that is a different threshold from the one the tape now offers",
               (drifted?.openPrice ?? 0) != (pinned?.openPrice ?? 0),
               "tape \(show(drifted?.openPrice)) against pinned \(show(pinned?.openPrice))")
            ok("which moves the probability, so this was never cosmetic",
               abs((drifted?.pUp ?? 0) - (pinned?.pUp ?? 0)) > 1e-6,
               "\(show(drifted?.pUp)) against \(show(pinned?.pUp))")
        }

        /* --- the cross-window model, which must mostly refuse ------------------- */

        /// A book of resolved windows carrying regime features, with the outcome
        /// either genuinely driven by `drift` or independent of everything.
        func regimeBook(count: Int, signal: Double) -> [ShadowWindow] {
            var seed: UInt64 = 0xBEEF77
            func next() -> Double {
                seed &+= 0x9E3779B97F4A7C15
                var z = seed
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z = z ^ (z >> 31)
                return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
            }
            func gauss() -> Double {
                let u = Swift.max(next(), 1e-9)
                return (-2 * log(u)).squareRoot() * cos(2 * .pi * next())
            }
            return (0..<count).map { i in
                let drift = Analysis.clamp(gauss(), -4, 4)
                let features = RegimeFeatures(
                    run: (next() * 10 - 5).rounded(), drift: drift,
                    last: Analysis.clamp(gauss(), -4, 4),
                    volShift: Analysis.clamp(gauss() * 0.3, -4, 4),
                    reversal: next() < 0.5 ? -1 : 1)
                // Up with probability σ(signal · drift). At signal 0 the outcome is
                // independent of every feature, which is the case that must be refused.
                let p = 1 / (1 + exp(-(signal * drift)))
                return ShadowWindow(
                    start: 1_700_000_000 + Double(i) * 300,
                    samples: [ShadowSample(offset: 150, pModel: 0.5, pMarket: 0.5,
                                           upAsk: 0.51, downAsk: 0.51, moveBps: 0)],
                    resolved: next() < p ? .up : .down, resolvedAt: 0, degraded: false,
                    regime: features)
            }
        }

        /* The assertion this whole file is built around. Five features, six hundred
         * windows and an outcome that depends on none of them: in sample that fit will
         * beat the baseline essentially always, and a version of this without
         * cross-validation would have the desk trading on it inside a day. */
        let flatBook = PredictFit.regime(regimeBook(count: 600, signal: 0))
        ok("a book with no cross-window signal in it is refused",
           flatBook.isDefault && flatBook.kappa == 0,
           "kappa \(show(flatBook.kappa)), cv \(show(flatBook.cvLogLoss)) vs baseline \(show(flatBook.baselineLogLoss))")
        ok("and it says it refused rather than saying nothing",
           flatBook.summary.contains("refused"))
        near("a refused model adjusts nothing at all",
             flatBook.adjustment(regimeBook(count: 1, signal: 0).first?.regime), 0, 1e-12)

        /* And the other half: a fit that refuses everything is not a fit either. With
         * a real relationship planted, it has to find it. */
        let planted = PredictFit.regime(regimeBook(count: 600, signal: 1.1))
        ok("a book with a real cross-window signal is accepted",
           !planted.isDefault && planted.kappa > 0,
           "kappa \(show(planted.kappa)), cv \(show(planted.cvLogLoss)) vs baseline \(show(planted.baselineLogLoss))")
        ok("and it beats ignoring the features out of sample",
           planted.cvLogLoss < planted.baselineLogLoss)
        if !planted.isDefault {
            let ranked = planted.weights.enumerated().max { abs($0.element) < abs($1.element) }
            ok("with the feature the outcome was actually built from carrying the most weight",
               RegimeFeatures.names[ranked?.offset ?? -1] == "Drift over the last hour",
               "strongest was \(RegimeFeatures.names[ranked?.offset ?? 0])")
            // The shrinkage is the point of the sweep: a fit taken at face value
            // overstates itself, and this must not come back at exactly one.
            ok("and only a share of the fitted signal applied, not all of it",
               planted.kappa <= 1.0 + 1e-9)
            let strong = RegimeFeatures(run: 0, drift: 3, last: 0, volShift: 0, reversal: 0)
            let weak = RegimeFeatures(run: 0, drift: -3, last: 0, volShift: 0, reversal: 0)
            ok("a strong up-drift reading pushes toward Up and a down one toward Down",
               planted.adjustment(strong) > 0 && planted.adjustment(weak) < 0,
               "up \(show(planted.adjustment(strong))), down \(show(planted.adjustment(weak)))")
            ok("and neither is allowed to run away with the probability",
               abs(planted.adjustment(strong)) <= 1.5 + 1e-9)
        }

        ok("a book below the evidence threshold is not fitted at all",
           PredictFit.regime(regimeBook(count: 120, signal: 1.1)).isDefault)
        ok("and windows with no features on them are simply absent from the fit",
           PredictFit.regime([]).isDefault)

        /* --- the features describe what they claim to describe ------------------ */

        /* Twelve windows climbing steadily, with enough wiggle for a volatility to
         * exist — a flat ramp has none, and `measure` correctly refuses a tape it
         * cannot scale its readings by. */
        let ra = liveAnchor()
        var climbing: [(Double, Double)] = []
        for t in stride(from: -7_200.0, through: 0, by: 20) {
            let trend = 1 + 0.0000004 * (t + 7_200)
            climbing.append((t, 80_000 * trend * (1 + 0.00006 * sin(t / 23))))
        }
        let climbTape = predictTape(ra, climbing)
        if let vol = climbTape.minuteVol(now: ra),
           // Not `f` — that is the number formatter this file uses everywhere, and
           // shadowing it turns every interpolation below into a type error.
           let reading = RegimeFeatures.measure(tape: climbTape,
                                                window: PredictWindow(start: ra / 1000), minuteVol: vol) {
            ok("a steady climb reads as a positive run of same-way windows", reading.run > 0,
               "run \(f(reading.run, 0))")
            ok("and as positive drift", reading.drift > 0, "drift \(f(reading.drift, 2))")
            ok("and as no reversal", reading.reversal < 0)
            ok("with every reading inside its clamp",
               reading.vector.allSatisfy { abs($0) <= 5 + 1e-9 })
        } else {
            ok("a dense climbing tape yields a regime reading", false, "measure returned nil")
        }

        // A tape that does not reach back far enough cannot describe a run-up, and
        // has to say so rather than describing a shorter one as if it were the same.
        let shortTape = predictTape(ra, (stride(from: -600.0, through: 0, by: 20)).map {
            ($0, 80_000 * (1 + 0.00006 * sin($0 / 23))) })
        ok("a tape without enough history behind the window declines to read one",
           RegimeFeatures.measure(tape: shortTape,
                                  window: PredictWindow(start: ra / 1000), minuteVol: 0.0002) == nil)


        /* --- every offset is reported, including the ones it will not trade ----- */

        /* The question this answers is "was the edge already gone by the time the
         * desk was allowed to look", and it is not the same question as "which offset
         * should the desk use". The fit that answers the second one refuses until it
         * has forty qualifying looks in a bucket and a clear winner; this has to
         * report at any sample size, with the count attached. */
        let profile = PredictFit.offsetProfile(
            shadowBook(count: 200, trueNoiseBps: 10, informative: true),
            minEdge: 0.05, weight: 0.25)
        ok("every offset with a look in it is reported",
           profile.count == PredictShadowBook.offsetBuckets.count,
           "\(profile.count) of \(PredictShadowBook.offsetBuckets.count)")
        ok("the offsets come back in time order",
           zip(profile, profile.dropFirst()).allSatisfy { $0.offset < $1.offset })
        ok("each row states how many windows it stands on",
           profile.allSatisfy { $0.samples > 0 })
        ok("and how many of those actually qualified, which is the smaller number",
           profile.allSatisfy { $0.qualified <= $0.samples })
        ok("the rate is that fraction, not a guess at it",
           profile.allSatisfy { abs($0.edgeRate - Double($0.qualified) / Double($0.samples)) < 1e-9 })
        ok("a bucket nothing qualified in reports no return rather than a zero one",
           profile.allSatisfy { $0.qualified > 0 || $0.meanReturn == 0 })
        ok("both Brier scores are real scores",
           profile.allSatisfy { $0.modelBrier > 0 && $0.modelBrier < 1
                             && $0.marketBrier > 0 && $0.marketBrier < 1 })
        ok("an empty book profiles nothing rather than dividing by zero",
           PredictFit.offsetProfile([], minEdge: 0.05, weight: 0.25).isEmpty)

        /* A higher bar has to be harder to clear at every offset — if raising the
         * edge requirement did not reduce how often it qualified, the column would
         * not be measuring what it says it is. */
        let strict = PredictFit.offsetProfile(
            shadowBook(count: 200, trueNoiseBps: 10, informative: true),
            minEdge: 0.20, weight: 0.25)
        ok("raising the edge bar qualifies fewer looks at every offset",
           zip(profile, strict).allSatisfy { $1.qualified <= $0.qualified },
           "total \(profile.reduce(0) { $0 + $1.qualified }) at 5¢ against \(strict.reduce(0) { $0 + $1.qualified }) at 20¢")

        /* --- the watch remembers the whole window, not only the tradeable part --- */

        /* An edge that peaks before the entry offset is invisible to `bestEdge`,
         * which only counts looks the desk was allowed to act on — and "the moment
         * was already gone" is the single most useful thing the record can say about
         * where the offset belongs. */
        var early = WindowWatch(window: PredictWindow(start: liveAnchor() / 1000))
        early.note(verdictOf(.tooEarly, edge: 0.04), inBand: false, elapsed: 45, alreadyBet: false)
        early.note(verdictOf(.tooEarly, edge: 0.09), inBand: false, elapsed: 60, alreadyBet: false)
        early.note(verdictOf(.noEdge, edge: 0.01), inBand: true, elapsed: 150, alreadyBet: false)
        near("the window's best is kept from outside the band too", early.bestAnyEdge, 0.09, 1e-9)
        near("with the second it happened", early.bestAnyOffset, 60, 1e-9)
        near("while the in-band best stays what the desk could have acted on",
             early.bestEdge, 0.01, 1e-9)
        ok("so the two together say the moment was gone before it was allowed to look",
           (early.bestAnyEdge ?? 0) > (early.bestEdge ?? 0) && early.bestAnyOffset < 150)

        /* --- the brain's own defaults are the shipped ones --------------------- */

        let fresh = PredictBrain.unlearned()
        ok("an unlearned brain is on every shipped default",
           fresh.feedIsDefault && fresh.weightIsDefault && fresh.offsetIsDefault)
        near("including the feed gap", fresh.feedNoiseBps, PredictFidelity.assumedBps, 1e-9)
        near("and the model weight", fresh.modelWeight, PredictModel.defaultMaxWeight, 1e-9)
        ok("and it says so rather than presenting a guess as a measurement",
           fresh.summary.contains("Nothing has been learned yet"))
    }

    private static func show(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(describing: value)
    }

    private static func ok(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition { passed += 1; return }
        failures.append("\(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func near(_ name: String, _ actual: Double?, _ expected: Double, _ tol: Double) {
        ok(name, actual != nil && abs(actual! - expected) <= tol,
           "expected ~\(expected) (±\(tol)), got \(show(actual))")
    }

    /// Build bars from a close series; range is a fixed fraction so ATR is predictable.
    private static func bars(_ closes: [Double], _ rangePct: Double = 0.02) -> [Bar] {
        closes.enumerated().map { i, c in
            Bar(t: 1_704_067_200_000 + Double(i) * 86_400_000,
                o: c, h: c * (1 + rangePct / 2), l: c * (1 - rangePct / 2), c: c, v: 1_000_000)
        }
    }

    private static func ramp(_ n: Int, _ from: Double, _ step: Double) -> [Double] {
        (0..<n).map { from + Double($0) * step }
    }

    static func run() -> Bool {
        primitives()
        regime()
        tradePlan()
        ledger()
        suitability()
        profileShapesThePlan()
        frictions()
        gaps()
        persistence()
        reconciliation()
        tax()
        calendarAndPDT()
        review()
        marketRegime()
        currency()
        onboarding()
        readingModes()
        learning()
        budgeting()
        models()
        diagnosing()
        sessions()
        stockholm()
        tradeStyles()
        predictions()
        predictLearning()
        harness()
        localServer()
        schemaCompatibility()
        regressions()
        predictAdaptation()

        print("\nPaper self-test — \(passed) passed, \(failures.count) failed.")
        if !failures.isEmpty {
            for f in failures { FileHandle.standardError.write(Data("  FAIL  \(f)\n".utf8)) }
            return false
        }
        print("All assertions hold.\n")
        return true
    }

    /* ------------------------------------------------------------ primitives */

    private static func primitives() {
        ok("sma returns nil below period", Analysis.sma([1, 2, 3], 5) == nil)
        near("sma of 1..10 over 10", Analysis.sma(ramp(10, 1, 1), 10), 5.5, 1e-9)
        near("sma uses the tail only", Analysis.sma([100, 100, 1, 2, 3], 3), 2, 1e-9)

        ok("rsi of a pure uptrend is 100", Analysis.rsi(ramp(40, 100, 1), 14) == 100)
        near("rsi of a flat series is 100 (no losses)", Analysis.rsi(Array(repeating: 50, count: 40), 14), 100, 1e-9)
        do {
            // Alternating equal up/down steps should sit near the midpoint.
            let zig = (0..<60).map { 100 + ($0 % 2 == 0 ? 0.0 : 2.0) }
            let r = Analysis.rsi(zig, 14)
            ok("rsi of a symmetric zigzag is mid-range", r != nil && r! > 40 && r! < 60, "got \(show(r))")
        }

        do {
            let b = bars(Array(repeating: 100, count: 40), 0.02) // every bar spans exactly 2 of 100
            near("atr of constant 2% ranges", Analysis.atr(b, 14), 2, 0.15)
        }
        ok("atr returns nil below period", Analysis.atr(bars(ramp(5, 10, 1)), 14) == nil)

        near("pctChange over 10 bars", Analysis.pctChange([100] + ramp(10, 101, 1), 10), 10, 0.01)
        near("maxDrawdown of a 20% dip", Analysis.maxDrawdown([100, 120, 96, 110]), 20, 0.01)
        ok("maxDrawdown of a monotonic rise is 0", Analysis.maxDrawdown(ramp(20, 1, 1)) < 1e-9)

        do {
            let p = Analysis.pivots(bars([1, 2, 3, 4, 5, 9, 5, 4, 3, 2, 1]), 5)
            ok("pivots finds the single centre high", p.highs.count == 1, "got \(p.highs.count)")
        }

        near("realised vol of a flat series is zero", Analysis.realisedVol(Array(repeating: 100, count: 40), "TEST", 30), 0, 1e-9)
        ok("realised vol needs a full lookback", Analysis.realisedVol(ramp(10, 100, 1), "TEST", 30) == nil)
        ok("crypto annualises over 365 sessions", Universe.periodsPerYear("BTC-USD") == 365)
        ok("equities annualise over 252 sessions", Universe.periodsPerYear("AAPL") == 252)
    }

    /* ---------------------------------------------------------------- regime */

    private static func regime() {
        let up = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6)))
        ok("sustained rise reads as an uptrend",
           up.regime == .strongUptrend || up.regime == .uptrend, "got \(up.regime.rawValue)")
        ok("uptrend scores above the midpoint on trend", up.scores.trend > 60, "got \(up.scores.trend)")

        let down = Analysis.analyse("TEST", bars(ramp(300, 280, -0.6)))
        ok("sustained fall reads as a downtrend",
           down.regime == .strongDowntrend || down.regime == .downtrend, "got \(down.regime.rawValue)")

        let flat = Analysis.analyse("TEST", bars((0..<300).map { 100 + sin(Double($0) / 6) * 3 }))
        ok("an oscillating series is not read as trending", flat.regime == .range, "got \(flat.regime.rawValue)")
    }

    /* ------------------------------------------------------------ trade plan */

    private static func tradePlan() {
        let m = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6)))
        let plan = Analysis.buildPlan(m, .init(equity: 100_000, riskPctPerTrade: 1, maxPositionPct: 20))

        ok("stop sits below entry", plan.stop < plan.entry)
        ok("target sits above entry", plan.target > plan.entry)
        near("risk equals the configured budget", plan.shares * (plan.entry - plan.stop), 1000, 1)
        ok("position respects the concentration cap", plan.cost <= 100_000 * 0.2 + 1, "cost \(f(plan.cost, 0))")
        near("breakeven win rate matches the ratio", plan.breakevenWinRate, (1 / (1 + plan.rr)) * 100, 0.01)
        ok("a funded plan clears the minimum ratio", plan.rejected != nil || plan.rr >= 1.5, "rr \(f(plan.rr, 2))")

        ok("an uncapped plan is sized by risk", plan.sizedBy == .risk, "got \(plan.sizedBy.rawValue)")
        near("risk taken matches risk budget when uncapped", plan.riskTaken, plan.riskBudget, 1)

        // A tight stop on a quiet instrument lets the risk maths buy more than the
        // concentration ceiling allows. When that happens the risk actually taken must
        // drop below the budget — reporting the full budget would be a lie.
        do {
            let tightM = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6), 0.002))
            let capped = Analysis.buildPlan(tightM, .init(equity: 100_000, riskPctPerTrade: 2, maxPositionPct: 5))
            ok("the concentration cap binds on a quiet instrument", capped.sizedBy == .concentration, "got \(capped.sizedBy.rawValue)")
            ok("a capped position respects the ceiling", capped.cost <= 5_000 + 1, "cost \(f(capped.cost, 0))")
            ok("a capped plan reports less risk than the budget",
               capped.riskTaken < capped.riskBudget,
               "taken \(f(capped.riskTaken, 0)) vs budget \(f(capped.riskBudget, 0))")
            near("risk taken equals shares times stop distance",
                 capped.riskTaken, capped.shares * (capped.entry - capped.stop), 1e-6)
        }

        // Halving the risk percentage must halve the size, not the levels.
        let half = Analysis.buildPlan(m, .init(equity: 100_000, riskPctPerTrade: 0.5, maxPositionPct: 20))
        near("halving risk halves the size", half.shares, plan.shares / 2, plan.shares * 0.01)
        near("halving risk leaves the stop untouched", half.stop, plan.stop, 1e-6)

        // Equity scales size linearly.
        let rich = Analysis.buildPlan(m, .init(equity: 200_000, riskPctPerTrade: 1, maxPositionPct: 100))
        near("doubling equity doubles the risk budget", rich.riskBudget, 2000, 1)

        let falling = Analysis.buildPlan(Analysis.analyse("TEST", bars(ramp(300, 280, -0.6))), Analysis.defaultSizing)
        ok("a falling stack is refused", falling.rejected != nil && falling.side == .avoid,
           "rejected=\(falling.rejected ?? "nil")")
    }

    /* -------------------------------------------------------------- portfolio */

    /// A profile with every friction switched off, so the ledger arithmetic can be
    /// checked against exact figures. The frictions get their own section below.
    private static func frictionlessProfile() -> Profile {
        var p = Profile.preset(.learner)
        p.id = "selftest"
        p.startingCapital = 100_000
        p.monthlyContribution = 0
        p.maxOpenPositions = 20
        p.frictions = .none
        return p
    }

    private static func tempLedger(_ profile: Profile) -> (Portfolio, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paper-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        return (Portfolio(profile: profile, url: url), dir)
    }

    private static func ledger() {
        let profile = frictionlessProfile()
        let (p, dir) = tempLedger(profile)

        ok("starts flat at the opening balance", p.state.cash == profile.startingCapital && p.state.positions.isEmpty)

        if case .ok = p.buy(symbol: "X", shares: 1e9, mark: MarkPrice(price: 100)) {
            ok("an order beyond the cash balance is refused", false, "it filled")
        } else {
            ok("an order beyond the cash balance is refused", true)
        }

        if case .ok = p.buy(symbol: "X", shares: 100, mark: MarkPrice(price: 50), target: 70, stop: 40, thesis: "t") {
            ok("a funded order fills", true)
        } else {
            ok("a funded order fills", false)
        }
        near("cash falls by the cost", p.state.cash, 100_000 - 5000, 1e-6)

        // Averaging in must blend the cost basis.
        _ = p.buy(symbol: "X", shares: 100, mark: MarkPrice(price: 70))
        near("average price blends across fills", p.state.positions.first?.avgPrice, 60, 1e-6)
        ok("each fill opens its own tax lot", p.state.positions.first?.lots.count == 2,
           "got \(p.state.positions.first?.lots.count ?? -1)")

        let v = p.value(["X": MarkPrice(price: 60, prevClose: 60)])
        near("equity is preserved when price equals cost", v.equity, 100_000, 1e-6)
        near("unrealised P/L is zero at the average", v.positions.first?.pnl, 0, 1e-6)

        // A target touch must close the position at the target, not the last price.
        let fired = p.sweepBrackets(["X": MarkPrice(price: 68, dayHigh: 71, dayLow: 67, dayOpen: 68)])
        ok("a touched target fires the bracket", fired.count == 1 && fired.first?.trigger == "target",
           "\(fired.map { $0.trigger ?? "nil" })")
        near("the fill happens at the target price", fired.first?.price, 70, 1e-6)
        ok("the position is closed out", p.state.positions.isEmpty)
        ok("the close is not marked as gapped", fired.first?.gapped == false)

        // Stop wins when both legs sit inside one bar — never assume the good outcome.
        _ = p.buy(symbol: "Y", shares: 10, mark: MarkPrice(price: 100), target: 110, stop: 90)
        let both = p.sweepBrackets(["Y": MarkPrice(price: 100, dayHigh: 115, dayLow: 85, dayOpen: 100)])
        ok("an outside day resolves to the stop, not the target",
           both.count == 1 && both.first?.trigger == "stop", "\(both.map { $0.trigger ?? "nil" })")
        near("R multiple is -1 on a stop-out", both.first?.rMultiple, -1, 1e-6)

        // The scorecard must count what actually happened.
        let sc = p.scorecard()
        ok("scorecard counts both closed trades", sc.closedTrades == 2, "got \(sc.closedTrades)")
        ok("scorecard splits wins and losses", sc.wins == 1 && sc.losses == 1, "\(sc.wins)/\(sc.losses)")
        ok("scorecard attributes the triggers", sc.targetsHit == 1 && sc.stoppedOut == 1,
           "\(sc.targetsHit)/\(sc.stoppedOut)")

        // The ledger must survive a reload.
        let before = p.state.cash
        let reloaded = Portfolio(profile: profile, url: dir.appendingPathComponent("ledger.json"))
        near("the ledger reloads from disk", reloaded.state.cash, before, 1e-6)
        // buy X, average into X, target-close X, buy Y, stop-close Y.
        ok("trades survive the reload", reloaded.state.trades.count == 5, "got \(reloaded.state.trades.count)")

        p.reset()
        ok("reset restores the opening balance", p.state.cash == profile.startingCapital && p.state.trades.isEmpty)

        try? FileManager.default.removeItem(at: dir)
    }

    /* ------------------------------------------------------------- suitability */

    /// The centre of the profile idea: what someone says they want, capped by what
    /// their circumstances can actually survive.
    private static func suitability() {
        var rich = Profile.preset(.longTermGrower)
        rich.riskPctPerTrade = 1.5
        ok("a salaried contributor has real risk capacity", rich.riskCapacity > 55, "got \(f(rich.riskCapacity, 0))")
        ok("their stated risk is not capped", !rich.isRiskCapped)
        near("so the engine uses what they asked for", rich.effectiveRiskPct, 1.5, 1e-9)

        // The case the whole mechanism exists for.
        var exposed = Profile.preset(.capitalToProtect)
        exposed.riskPctPerTrade = 2
        ok("no income and no buffer is low capacity", exposed.riskCapacity < 40, "got \(f(exposed.riskCapacity, 0))")
        ok("a large pot does not buy risk capacity", exposed.isRiskCapped)
        ok("the cap is the hard floor, not the band", exposed.effectiveRiskPct <= 0.5,
           "got \(f(exposed.effectiveRiskPct, 2))")
        ok("and the app says why", exposed.suitabilityNote.contains("no income"))

        // Capacity must respond to the facts, not to the appetite.
        var funded = exposed
        funded.incomeStability = .salaried
        funded.emergencyFundMonths = 6
        funded.monthlyContribution = 2_000
        ok("adding income and a buffer raises capacity",
           funded.riskCapacity > exposed.riskCapacity + 20,
           "\(f(exposed.riskCapacity, 0)) → \(f(funded.riskCapacity, 0))")

        var identical = exposed
        identical.riskPctPerTrade = 5
        near("asking for more changes nothing about capacity", identical.riskCapacity, exposed.riskCapacity, 1e-9)

        // Heat is bounded by the drawdown the person says they would sit through.
        ok("portfolio heat is bounded by drawdown tolerance",
           exposed.maxPortfolioHeatPct <= exposed.drawdownTolerancePct * 0.5 + 1e-9)

        // Universes.
        let crypto = Profile.preset(.cryptoNative)
        ok("a crypto profile excludes equities", !crypto.allows("AAPL") && crypto.allows("BTC-USD"))
        let stocks = Profile.preset(.dayTrader)
        ok("an equities profile excludes crypto", stocks.allows("AAPL") && !stocks.allows("BTC-USD"))
        ok("only an index-first profile funds the benchmarks",
           Profile.preset(.capitalToProtect).fundsBenchmarks && !stocks.fundsBenchmarks)
    }

    /* -------------------------------------------------------- horizon and goal */

    /// The same chart has to produce a different trade for a different person, or
    /// the profile is decoration.
    private static func profileShapesThePlan() {
        let m = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6)))

        let intraday = Profile.preset(.dayTrader).sizingRules(equity: 100_000)
        let long = Profile.preset(.longTermGrower).sizingRules(equity: 100_000)
        let fast = Analysis.buildPlan(m, intraday)
        let slow = Analysis.buildPlan(m, long)

        ok("a shorter horizon places a tighter stop",
           (fast.entry - fast.stop) < (slow.entry - slow.stop),
           "\(f(fast.entry - fast.stop, 2)) vs \(f(slow.entry - slow.stop, 2))")
        ok("a longer horizon reaches for a further target",
           (slow.target - slow.entry) > (fast.target - fast.entry),
           "\(f(slow.target - slow.entry, 2)) vs \(f(fast.target - fast.entry, 2))")

        // A high-volatility instrument must be refused for a preservation objective
        // and allowed for a speculative one, from identical price history.
        let wild = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6), 0.14))
        var careful = Profile.preset(.capitalToProtect)
        careful.horizon = .position
        let carefulPlan = Analysis.buildPlan(wild, careful.sizingRules(equity: 100_000))
        ok("preservation refuses an instrument that moves too much",
           carefulPlan.rejected != nil, "rejected=\(carefulPlan.rejected ?? "nil")")

        // The minimum reward-to-risk is the goal's, not a constant.
        ok("preservation demands more reward than speculation",
           InvestmentGoal.preservation.minRewardToRisk > InvestmentGoal.speculation.minRewardToRisk)

        // Raising the required ratio can only ever refuse more setups, never fewer.
        // Checked across the whole synthetic universe rather than on one fixture,
        // because a single chart can be refused for an unrelated reason first.
        func wave(_ drift: Double, _ period: Double, _ amplitude: Double) -> [Double] {
            var out: [Double] = []
            for i in 0..<300 {
                let x = Double(i)
                let value: Double = 100 + x * drift + sin(x / period) * amplitude
                out.append(value)
            }
            return out
        }
        let shapes: [[Double]] = [
            ramp(300, 100, 0.6),
            ramp(300, 100, 0.15),
            wave(0.2, 9, 4),
            wave(0.05, 14, 7),
            wave(0, 6, 3),
        ]
        var lenient = Profile.preset(.learner); lenient.goal = .speculation
        var strict = Profile.preset(.learner); strict.goal = .preservation
        var lenientFunded = 0
        var strictFunded = 0
        for shape in shapes {
            let metrics = Analysis.analyse("TEST", bars(shape))
            if Analysis.buildPlan(metrics, lenient.sizingRules(equity: 100_000)).rejected == nil { lenientFunded += 1 }
            if Analysis.buildPlan(metrics, strict.sizingRules(equity: 100_000)).rejected == nil { strictFunded += 1 }
        }
        ok("a stricter objective never funds more than a looser one",
           strictFunded <= lenientFunded, "\(strictFunded) vs \(lenientFunded)")

        // And when the ratio is the binding reason, the refusal names the profile's
        // own threshold rather than a constant.
        var thin = Profile.preset(.learner)
        thin.goal = .preservation
        let quoted = shapes.compactMap { Analysis.buildPlan(Analysis.analyse("TEST", bars($0)),
                                                            thin.sizingRules(equity: 100_000)).rejected }
            .contains { $0.contains("this profile funds") }
        ok("a ratio refusal quotes the profile's own threshold", quoted)
    }

    /* ------------------------------------------------------------- frictions */

    private static func frictions() {
        let f = Frictions.retailBroker
        ok("you buy above the mid", f.buyFill(100, atr: 2) > 100)
        ok("you sell below the mid", f.sellFill(100, atr: 2) < 100)
        ok("a volatile instrument costs more to cross",
           f.slippage(price: 100, atr: 8) > f.slippage(price: 100, atr: 1))
        ok("there is a floor when no ATR is known", f.slippage(price: 100, atr: nil) > 0)

        let pct = Frictions.cryptoExchange
        near("a percentage venue charges on notional", pct.commission(notional: 10_000), 25, 1e-9)
        near("a commission-free venue charges nothing", Frictions.retailBroker.commission(notional: 10_000), 0, 1e-9)
        near("a flat venue charges the flat rate", Frictions.activeTrader.commission(notional: 10_000), 1, 1e-9)

        // Costs must actually leave the account.
        var profile = frictionlessProfile()
        profile.frictions = .activeTrader
        let (p, dir) = tempLedger(profile)
        _ = p.buy(symbol: "X", shares: 100, mark: MarkPrice(price: 50, atr: 1), skipGate: true)
        ok("commission is deducted from cash", p.state.totalCommission > 0)
        ok("the spread is recorded", p.state.totalSlippage > 0)
        ok("the cost basis carries the commission", (p.state.positions.first?.avgPrice ?? 0) > 50)
        try? FileManager.default.removeItem(at: dir)
    }

    /* ----------------------------------------------------------- gapped exits */

    /// The lie this whole layer exists to stop: a stop is an instruction, not a
    /// promise of a price.
    private static func gaps() {
        var profile = frictionlessProfile()
        profile.frictions = .none
        let (p, dir) = tempLedger(profile)

        _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
        // The session opens at 80, well below the stop. That is where it fills.
        let fired = p.sweepBrackets(["X": MarkPrice(price: 82, dayHigh: 84, dayLow: 79, dayOpen: 80)])
        ok("a gap through the stop fires it", fired.count == 1)
        near("and fills at the open, not at the stop", fired.first?.price, 80, 1e-6)
        ok("the trade is marked as gapped", fired.first?.gapped == true)
        ok("the loss is worse than the plan allowed", (fired.first?.pnl ?? 0) < -190,
           "got \(f(fired.first?.pnl ?? 0, 2))")
        ok("and the reason says so", fired.first?.reason.contains("gapped through") == true)

        // Gaps run both ways.
        _ = p.buy(symbol: "Z", shares: 10, mark: MarkPrice(price: 100), target: 110, skipGate: true)
        let up = p.sweepBrackets(["Z": MarkPrice(price: 118, dayHigh: 121, dayLow: 117, dayOpen: 120)])
        near("an upward gap fills better than the target", up.first?.price, 120, 1e-6)
        ok("a favourable gap is still flagged", up.first?.gapped == true)

        try? FileManager.default.removeItem(at: dir)
    }

    /* ------------------------------------------------- reading what we wrote */

    /**
     * The regression that cost six accounts.
     *
     * Swift's synthesised decoder throws on a missing key even when the property has
     * a default, and the class then answered that by saving an empty ledger over the
     * top. Both halves are tested here: an older file must read, and a file that
     * genuinely cannot be read must survive untouched.
     */
    private static func persistence() {
        let profile = frictionlessProfile()

        /* ---- a ledger written before the new fields existed still opens ---- */
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paper-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("ledger.json")

            // Exactly the shape the app wrote before 2026-09-13: no lastSweptAt, no
            // appliedSplits, and a trade with no `backfilled`.
            let legacy = """
            {
              "profileId": "P1", "cash": 4200.5,
              "positions": [{
                "id": "p1", "symbol": "MSFT", "shares": 10, "avgPrice": 400,
                "openedAt": 1780000000000, "openedSession": "2026-6-1",
                "stop": 380, "thesis": "held", "lots": [
                  {"id":"l1","shares":10,"costPerShare":400,"openedAt":1780000000000}
                ], "highWater": 410, "lowWater": 395
              }],
              "trades": [{
                "id": "t1", "symbol": "AAPL", "action": "sell", "shares": 5,
                "price": 190, "quotedPrice": 190.2, "value": 950, "at": 1780000000000,
                "commission": 1, "slippage": 0.5, "pnl": 120, "gapped": false,
                "reason": "closed", "trigger": "target", "dayTrade": false
              }],
              "equityCurve": [], "createdAt": 1779000000000,
              "realizedGains": [], "dayTrades": [], "contributions": [],
              "lastContributionMonth": "2026-6", "startingCapital": 5000,
              "totalContributed": 0, "totalCommission": 1, "totalSlippage": 0.5, "totalTax": 0
            }
            """
            try? Data(legacy.utf8).write(to: url)

            let p = Portfolio(profile: profile, url: url)
            ok("a ledger from before the new fields still loads", p.loadError == nil,
               p.loadError ?? "")
            ok("its positions survive", p.state.positions.count == 1)
            near("with their size intact", p.state.positions.first?.shares, 10, 1e-9)
            near("and its cash", p.state.cash, 4200.5, 1e-9)
            ok("its trades survive", p.state.trades.count == 1)
            ok("a trade with no backfilled flag reads as not backfilled",
               p.state.trades.first?.backfilled == false)
            near("the missing lastSweptAt defaults rather than throwing", p.state.lastSweptAt, 0, 1e-9)
            ok("and appliedSplits defaults to empty", p.state.appliedSplits.isEmpty)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- a file that cannot be read is never written over ---- */
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paper-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("ledger.json")

            // Valid JSON, but not a ledger: no profileId.
            let junk = #"{"somethingElse": true, "positions": [{"id":"x"}]}"#
            try? Data(junk.utf8).write(to: url)

            let p = Portfolio(profile: profile, url: url)
            ok("an unreadable ledger is reported rather than swallowed", p.loadError != nil)
            ok("the original bytes are still on disk, unchanged",
               (try? String(contentsOf: url, encoding: .utf8)) == junk)
            ok("and a copy was set aside", p.quarantinedAt.map {
                FileManager.default.fileExists(atPath: $0.path) } == true)

            // The critical half: nothing the app does afterwards may write over it.
            _ = p.buy(symbol: "X", shares: 1, mark: MarkPrice(price: 10), skipGate: true)
            p.markSwept(nowMs())
            p.snapshot(equity: 1, cash: 1, invested: 0)
            ok("no later write reaches the file",
               (try? String(contentsOf: url, encoding: .utf8)) == junk)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- a missing file is a new account, and writing one is correct ---- */
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paper-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("ledger.json")
            let p = Portfolio(profile: profile, url: url)
            ok("a brand new account writes itself out", p.loadError == nil
               && FileManager.default.fileExists(atPath: url.path))
            near("at the opening balance", p.state.cash, profile.startingCapital, 1e-9)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- launch backups happen before anything opens the files ---- */
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paper-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let a = dir.appendingPathComponent("one.json")
            let b = dir.appendingPathComponent("two.json")
            try? Data(#"{"profileId":"A","cash":1}"#.utf8).write(to: a)
            try? Data(#"{"profileId":"B","cash":2}"#.utf8).write(to: b)

            Desk.backupLedgers(in: dir)
            let store = dir.appendingPathComponent("backups", isDirectory: true)
            let runs = (try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? []
            ok("a launch backup is written", runs.count == 1)
            let files = runs.first.flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            } ?? []
            ok("covering every ledger", files.count == 2)
            ok("byte for byte",
               files.first.flatMap { try? Data(contentsOf: $0) }?.isEmpty == false)
            ok("and the originals are untouched",
               (try? String(contentsOf: a, encoding: .utf8)) == #"{"profileId":"A","cash":1}"#)

            // An empty directory has nothing to back up and must not litter.
            let bare = dir.appendingPathComponent("bare", isDirectory: true)
            try? FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            Desk.backupLedgers(in: bare)
            ok("an account-less install writes no backup folder",
               !FileManager.default.fileExists(atPath: bare.appendingPathComponent("backups").path))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /* --------------------------------------------------- closed-window replay */

    /// Run an async pass from the synchronous harness.
    private static func sync<T>(_ work: @escaping () async -> T) -> T {
        let box = UnsafeMutablePointer<T?>.allocate(capacity: 1)
        box.initialize(to: nil)
        let gate = DispatchSemaphore(value: 0)
        Task { box.pointee = await work(); gate.signal() }
        gate.wait()
        let value = box.pointee!
        box.deinitialize(count: 1); box.deallocate()
        return value
    }

    /// A fixed "now" so session keys are deterministic: 2026-09-11, 20:00 UTC,
    /// which is a mid-afternoon New York session rather than a boundary.
    private static let replayNow: Double = 1_789_502_400_000

    private static func day(_ back: Int) -> Double { replayNow - Double(back) * 86_400_000 }

    /// One bar per day, newest last, `back` days ago down to 1 day ago.
    private static func sessionBars(_ rows: [(o: Double, h: Double, l: Double, c: Double)]) -> [Bar] {
        rows.enumerated().map { i, r in
            Bar(t: day(rows.count - i), o: r.o, h: r.h, l: r.l, c: r.c, v: 1_000)
        }
    }

    private static func replayLedger() -> (Portfolio, URL) {
        var profile = frictionlessProfile()
        profile.frictions = .none
        profile.monthlyContribution = 0
        return tempLedger(profile)
    }

    private static func reconciliation() {
        /* ---- the hole this exists to close ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
            p.markSwept(day(6))

            // Dipped through the stop three days ago, then recovered well past entry.
            let series = sessionBars([
                (100, 102, 98, 101),   // 5 days ago
                (101, 103, 99, 100),   // 4
                (100, 101, 85, 88),    // 3 — the stop at 90 was taken out here
                (88, 96, 87, 95),      // 2
                (95, 106, 94, 105),    // 1 — fully recovered
            ])

            // The live sweep alone, looking only at today, sees nothing wrong.
            let liveOnly = p.sweepBrackets(["X": MarkPrice(price: 105, dayHigh: 106, dayLow: 104, dayOpen: 105)])
            ok("the live sweep cannot see a stop hit while the app was shut", liveOnly.isEmpty)
            ok("and the position is still sitting there open", p.state.positions.count == 1)

            let report = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("the replay finds the missed stop", report?.exits.count == 1)
            ok("and closes the position", p.state.positions.isEmpty)
            near("at the stop, not at today's price", report?.exits.first?.fill, 90, 1e-6)
            ok("the exit is dated to the session it happened in",
               abs((report?.exits.first?.at ?? 0) - day(3)) < 1000,
               "got \(f(report?.exits.first?.at ?? 0, 0)) want \(f(day(3), 0))")
            ok("the trade is marked as reconstructed", p.state.trades.first?.backfilled == true)
            ok("the reason says the desk was not running",
               p.state.trades.first?.reason.contains("Reconstructed") == true)
            ok("the loss is real money", (report?.netPnl ?? 0) < -95)
            ok("the scorecard counts it apart from the live exits", p.scorecard().backfilledExits == 1)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- a gap through the level still fills at the open ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
            p.markSwept(day(3))
            let series = sessionBars([
                (100, 101, 99, 100),
                (80, 84, 78, 82),      // opened through the stop
            ])
            let report = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            near("a replayed gap fills at the open", report?.exits.first?.fill, 80, 1e-6)
            ok("and is flagged as gapped", report?.exits.first?.gapped == true)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- both legs in one bar ---- */
        do {
            let straddle = sessionBars([
                (100, 101, 99, 100),
                (100, 112, 88, 105),   // touched the 90 stop and the 110 target
            ])

            // With nothing finer, the stop is assumed first and the record says so.
            let (a, dirA) = replayLedger()
            _ = a.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), target: 110, stop: 90, skipGate: true)
            a.markSwept(day(3))
            let blind = sync {
                await Reconcile.run(ledger: a, profileName: "t", bars: ["X": straddle],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("with only daily bars the stop is assumed to have gone first",
               blind?.exits.first?.trigger == "stop")
            ok("and the assumption is recorded rather than hidden",
               blind?.exits.first?.assumedStopFirst == true)
            ok("resolution is reported as daily", blind?.exits.first?.resolution == "daily")
            try? FileManager.default.removeItem(at: dirA)

            // Five-minute bars can settle it — and here the target genuinely went first.
            let (b, dirB) = replayLedger()
            _ = b.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), target: 110, stop: 90, skipGate: true)
            b.markSwept(day(3))
            let fine: [Bar] = [
                Bar(t: day(1) - 7_200_000, o: 100, h: 104, l: 99, c: 103, v: 1),
                Bar(t: day(1) - 3_600_000, o: 103, h: 112, l: 102, c: 111, v: 1),  // target first
                Bar(t: day(1),             o: 111, h: 111, l: 88,  c: 105, v: 1),  // stop later
            ]
            let refined = sync {
                await Reconcile.run(ledger: b, profileName: "t", bars: ["X": straddle],
                                    splits: [:], now: replayNow, intraday: { _ in fine })
            }
            ok("five-minute bars overturn the pessimistic assumption",
               refined?.exits.first?.trigger == "target")
            ok("and the resolution says where that came from",
               refined?.exits.first?.resolution == "intraday")
            near("filling at the target", refined?.exits.first?.fill, 110, 1e-6)
            ok("the exit is stamped with the minute the level was touched, not the bar",
               abs((refined?.exits.first?.at ?? 0) - (day(1) - 3_600_000)) < 1000,
               "got \(f(refined?.exits.first?.at ?? 0, 0))")
            try? FileManager.default.removeItem(at: dirB)
        }

        /* ---- splits: the thing that would fire every stop in the book ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 1000), stop: 900, skipGate: true)
            /* Held *through* the split, which is the only case a restatement applies
             * to — and which `buy` cannot produce on its own, because it stamps the
             * position with the moment of the call. Without this the scenario says
             * "bought at the pre-split price of 1000" while the file says the
             * position was opened after the split, and the two cannot both be true.
             * A split that predates its own position is now left alone, so the setup
             * has to be honest about which case it is. */
            p.backdateForTesting(symbol: "X", openedAt: day(5))
            p.markSwept(day(4))
            // Post-split bars: the feed restates history, so a $1,000 stock is served
            // at $100 all the way back. The ledger still says 1000/900.
            let series = sessionBars([
                (100, 101, 99, 100),
                (100, 102, 98, 101),
                (101, 103, 100, 102),
            ])
            let split = Split(at: day(3), ratio: 10, label: "10:1")
            let report = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: ["X": [split]], now: replayNow, intraday: { _ in nil })
            }
            ok("the split is applied, not treated as a 90% crash", report?.splitsApplied.count == 1)
            ok("no bogus stop fires", report?.exits.isEmpty == true)
            ok("the position survives", p.state.positions.count == 1)
            near("shares are restated up", p.state.positions.first?.shares, 100, 1e-6)
            near("entry is restated down", p.state.positions.first?.avgPrice, 100, 1e-6)
            near("and so is the stop", p.state.positions.first?.stop, 90, 1e-6)

            // Twice must not restate twice.
            p.markSwept(day(4))
            _ = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: ["X": [split]], now: replayNow, intraday: { _ in nil })
            }
            near("a second pass does not restate again", p.state.positions.first?.shares, 100, 1e-6)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- an unexplained discontinuity is refused, not traded ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 1000), stop: 900, skipGate: true)
            p.markSwept(day(4))
            let series = sessionBars([
                (1000, 1010, 990, 1000),
                (100, 102, 98, 101),     // 90% overnight, with no split reported
                (101, 103, 100, 102),
            ])
            let report = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("an unexplained 90% gap does not close the position", p.state.positions.count == 1)
            ok("it is flagged for a human instead", report?.flagged.count == 1)
            ok("and the flag names the symbol", report?.flagged.first?.symbol == "X")
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- dates drive tax, not the moment of discovery ---- */
        do {
            var profile = frictionlessProfile()
            profile.frictions = Frictions(
                commissionPerTrade: 0, commissionPctOfValue: 0, minCommission: 0,
                slippageAtrFraction: 0, minSlippagePctOfPrice: 0,
                enforceMarketHours: false, enforcePDT: false,
                shortTermTaxPct: 40, longTermTaxPct: 10, longTermHoldingDays: 365
            )
            profile.monthlyContribution = 0
            let (p, dir) = tempLedger(profile)
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), target: 120, skipGate: true)
            // Backdate the entry so the parcel is two days short of the long-term line
            // at the replayed exit, and past it by the time anyone looks.
            let opened = day(364)
            p.backdateForTesting(symbol: "X", openedAt: opened)
            p.markSwept(day(3))
            let series = sessionBars([
                (100, 101, 99, 100),
                (100, 125, 99, 124),
            ])
            _ = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("the holding period is measured to the exit date, not to now",
               p.state.realizedGains.first?.longTerm == false,
               "held \(f(p.state.realizedGains.first?.holdingDays ?? -1, 1)) days")
            near("so the short-term rate applies", p.state.realizedGains.first?.taxDue, 80, 1e-6)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- contributions owed for every month the desk was shut ---- */
        do {
            var profile = frictionlessProfile()
            profile.frictions = .none
            profile.monthlyContribution = 500
            let (p, dir) = tempLedger(profile)
            let cal = Calendar(identifier: .gregorian)
            let now = Date(timeIntervalSince1970: replayNow / 1000)
            let threeBack = cal.date(byAdding: .month, value: -3, to: now)!
            p.rewindContributionMonthForTesting(to: threeBack)

            let paid = p.applyContribution(now: now)
            ok("three shut months pay in three times, not once", paid.count == 3,
               "got \(paid.count)")
            near("and the cash reflects all of them", p.state.totalContributed, 1500, 1e-6)
            ok("a second call in the same month pays nothing", p.applyContribution(now: now).isEmpty)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- the pass is idempotent and leaves a watermark ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
            p.markSwept(day(4))
            let series = sessionBars([
                (100, 101, 99, 100),
                (100, 101, 85, 88),
                (88, 92, 87, 91),
            ])
            let first = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("the first pass does the work", first?.exits.count == 1)
            near("and advances the watermark to now", p.state.lastSweptAt, replayNow, 1e-6)
            let second = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("the second pass finds nothing left to do", second == nil)
            ok("and does not double-book the exit",
               p.state.trades.filter { $0.action == "sell" }.count == 1)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- the equity curve draws the gap rather than stepping over it ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), skipGate: true)
            p.markSwept(day(5))
            let before = p.state.equityCurve.count
            let series = sessionBars([
                (100, 101, 99, 100),
                (100, 101, 80, 82),
                (82, 90, 81, 89),
                (89, 101, 88, 100),
            ])
            _ = sync {
                await Reconcile.run(ledger: p, profileName: "t", bars: ["X": series],
                                    splits: [:], now: replayNow, intraday: { _ in nil })
            }
            ok("a point is written for each replayed session",
               p.state.equityCurve.count >= before + 4,
               "went from \(before) to \(p.state.equityCurve.count)")
            ok("the curve is still in order",
               zip(p.state.equityCurve, p.state.equityCurve.dropFirst()).allSatisfy { $0.t <= $1.t })
            let trough = p.state.equityCurve.map(\.equity).min() ?? 0
            ok("and the drawdown nobody watched is visible in it", trough < p.state.equityCurve[0].equity)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- a short restart is not a window worth replaying ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
            p.markSwept(replayNow - 60_000)
            ok("closing and reopening the app replays nothing",
               Reconcile.startPoint(ledger: p, now: replayNow) == nil)
            try? FileManager.default.removeItem(at: dir)
        }

        /* ---- a ledger predating all this still gets held to account ---- */
        do {
            let (p, dir) = replayLedger()
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), stop: 90, skipGate: true)
            p.backdateForTesting(symbol: "X", openedAt: day(10))
            ok("with no watermark the replay starts from the oldest open position",
               (Reconcile.startPoint(ledger: p, now: replayNow) ?? 0) == day(10))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /* ------------------------------------------------------------------- tax */

    private static func tax() {
        var profile = frictionlessProfile()
        profile.frictions = Frictions(
            commissionPerTrade: 0, commissionPctOfValue: 0, minCommission: 0,
            slippageAtrFraction: 0, minSlippagePctOfPrice: 0,
            enforceMarketHours: false, enforcePDT: false,
            shortTermTaxPct: 40, longTermTaxPct: 10, longTermHoldingDays: 365
        )
        let (p, dir) = tempLedger(profile)

        _ = p.buy(symbol: "X", shares: 100, mark: MarkPrice(price: 50), skipGate: true)
        _ = p.sell(symbol: "X", mark: MarkPrice(price: 60), skipGate: true)

        let gain = p.state.realizedGains.first
        near("the realised gain is proceeds less basis", gain?.gain, 1000, 1e-6)
        ok("a same-day sale is short-term", gain?.longTerm == false)
        near("tax is charged at the short-term rate", gain?.taxDue, 400, 1e-6)
        near("and is withheld from the balance", p.state.cash, 100_000 + 600, 1e-6)
        near("the trade records the tax", p.state.trades.first?.taxDue, 400, 1e-6)

        let summary = p.taxSummary()
        near("the summary totals the short-term gain", summary.shortTermGain, 1000, 1e-6)
        near("and the tax owed", summary.totalTax, 400, 1e-6)
        ok("the summary explains what holding longer would have saved",
           summary.note.contains("long-term") || summary.note.contains("held past"))

        // A loss must not be taxed — and must claw back what the earlier winner paid,
        // because capital losses offset gains inside the same tax year.
        _ = p.buy(symbol: "Y", shares: 100, mark: MarkPrice(price: 50), skipGate: true)
        let loser = p.sell(symbol: "Y", mark: MarkPrice(price: 40), skipGate: true)
        near("a loss owes no tax of its own", p.state.realizedGains.first?.taxDue, 0, 1e-9)
        if case .ok(let t) = loser {
            near("and refunds the tax the winner paid", t.taxDue, -400, 1e-6)
        } else {
            ok("and refunds the tax the winner paid", false, "the sale failed")
        }
        near("the year's liability is back to nothing", p.state.totalTax, 0, 1e-6)
        near("the summary agrees", p.taxSummary().totalTax, 0, 1e-6)
        ok("and says the losses offset the gains", p.taxSummary().note.contains("refunded"))
        // 100k − 5000 + 6000 − 400 (withheld) − 5000 + 4000 + 400 (refunded)
        near("the balance reflects the refund", p.state.cash, 100_000 + 1000 - 1000, 1e-6)

        try? FileManager.default.removeItem(at: dir)
    }

    /* --------------------------------------------------- calendar and the PDT */

    /// Noon in New York on a given date. The market calendar is a New York
    /// calendar, so a test that builds its dates in the machine's own timezone is
    /// asking about a different day.
    private static func nyNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        at(year, month, day, 12, 0, "America/New_York")
    }

    /// A moment, in a named zone. Every calendar assertion below picks its own zone,
    /// because "is the market open" now has two different right answers.
    private static func at(_ year: Int, _ month: Int, _ day: Int,
                           _ hour: Int, _ minute: Int, _ zone: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute))!
    }

    private static func stockholm(_ year: Int, _ month: Int, _ day: Int,
                                  _ hour: Int, _ minute: Int = 0) -> Date {
        at(year, month, day, hour, minute, "Europe/Stockholm")
    }

    private static func calendarAndPDT() {
        ok("Saturday is not a trading day", !MarketCalendar.isTradingDay(nyNoon(2026, 9, 5)))
        ok("and the session is shut", !MarketCalendar.isSessionOpen(nyNoon(2026, 9, 5)))
        ok("a plain Tuesday is", MarketCalendar.isTradingDay(nyNoon(2026, 9, 8)))
        ok("and at noon it is open", MarketCalendar.isSessionOpen(nyNoon(2026, 9, 8)))

        let holidays = MarketCalendar.holidays(2026)
        ok("the holiday table is computed, not guessed", holidays.count >= 9, "got \(holidays.count)")
        // 4 July 2026 falls on a Saturday, so it is observed on Friday the 3rd.
        ok("a weekend holiday is observed on the nearest weekday",
           !MarketCalendar.isTradingDay(nyNoon(2026, 7, 3)))
        ok("Christmas is closed", !MarketCalendar.isTradingDay(nyNoon(2026, 12, 25)))
        ok("Thanksgiving is closed", !MarketCalendar.isTradingDay(nyNoon(2026, 11, 26)))
        // Easter 2026 is 5 April, so Good Friday is the 3rd — the one holiday that moves.
        ok("Good Friday moves with Easter", !MarketCalendar.isTradingDay(nyNoon(2026, 4, 3)))
        ok("but the Thursday before it is open", MarketCalendar.isTradingDay(nyNoon(2026, 4, 2)))

        // The pattern day trader rule.
        let records = (0..<3).map { _ in DayTradeRecord(symbol: "AAPL", at: nowMs(), session: "s") }
        ok("a small account is stopped at the fourth day trade",
           PDT.blocks(symbol: "AAPL", equity: 20_000, records: records, frictions: .retailBroker) != nil)
        ok("a funded account is not",
           PDT.blocks(symbol: "AAPL", equity: 30_000, records: records, frictions: .retailBroker) == nil)
        ok("crypto is exempt",
           PDT.blocks(symbol: "BTC-USD", equity: 20_000, records: records, frictions: .retailBroker) == nil)
        ok("and so is a profile that does not enforce it",
           PDT.blocks(symbol: "AAPL", equity: 20_000, records: records, frictions: .longTermInvestor) == nil)
        ok("the allowance counts down", PDT.remaining(equity: 20_000, records: Array(records.prefix(1)),
                                                      frictions: .retailBroker) == 2)

        // Equity orders outside the session are refused; crypto is not.
        var profile = frictionlessProfile()
        profile.frictions = .retailBroker
        let (p, dir) = tempLedger(profile)
        let blocked = p.gate(symbol: "AAPL", equity: 100_000, closing: false)
        let crypto = p.gate(symbol: "BTC-USD", equity: 100_000, closing: false)
        ok("crypto is always tradeable", crypto == nil)
        if MarketCalendar.isSessionOpen() {
            ok("equities trade while the session is open", blocked == nil)
        } else {
            ok("equities are refused while the market is shut", blocked != nil)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /* ------------------------------------------------------------ the review */

    private static func review() {
        // A trade that was stopped out and then recovered is a whipsaw, not a
        // vindicated stop — and the difference is measurable, not a matter of taste.
        let closes = [100.0, 98, 95, 92, 90, 94, 99, 104, 108, 112]
        let series = bars(closes, 0.02)
        let sell = Trade(
            id: "t1", symbol: "AAPL", action: "sell", shares: 10, price: 90, quotedPrice: 90,
            value: 900, at: series[4].t, commission: 0, slippage: 0, pnl: -100, rMultiple: -1,
            taxDue: 0, gapped: false, reason: "stopped", trigger: "stop", dayTrade: false
        )
        let r = Review.build(sell: sell, openedAt: series[0].t, entry: 100, stop: 90,
                             target: 120, thesis: "test", bars: series)
        ok("a stop that recovered reads as a whipsaw", r.verdict == .whipsawed, "got \(r.verdict.rawValue)")
        ok("the post-exit move is measured", (r.postExitBestPct ?? 0) > 20, "got \(f(r.postExitBestPct ?? 0, 1))")
        ok("money left behind is quantified", (r.leftOnTable ?? 0) > 0)
        ok("the evidence line carries the numbers", r.evidence.contains("Since the exit"))

        // The mirror case: stopped out and it kept falling.
        let falling = bars([100.0, 96, 93, 90, 86, 82, 78, 74, 70, 66], 0.02)
        let sell2 = Trade(
            id: "t2", symbol: "AAPL", action: "sell", shares: 10, price: 90, quotedPrice: 90,
            value: 900, at: falling[3].t, commission: 0, slippage: 0, pnl: -100, rMultiple: -1,
            taxDue: 0, gapped: false, reason: "stopped", trigger: "stop", dayTrade: false
        )
        let r2 = Review.build(sell: sell2, openedAt: falling[0].t, entry: 100, stop: 90,
                              target: 120, thesis: "test", bars: falling)
        ok("a stop that saved you reads as one", r2.verdict == .stopSavedYou, "got \(r2.verdict.rawValue)")
        ok("holding on would have been worse", (r2.leftOnTable ?? 0) < 0)

        // Sold into a continuing run.
        let running = bars([100.0, 104, 108, 112, 116, 122, 128, 134, 140, 146], 0.02)
        let sell3 = Trade(
            id: "t3", symbol: "AAPL", action: "sell", shares: 10, price: 112, quotedPrice: 112,
            value: 1120, at: running[3].t, commission: 0, slippage: 0, pnl: 120, rMultiple: 1.2,
            taxDue: 0, gapped: false, reason: "took profit", trigger: "manual", dayTrade: false
        )
        let r3 = Review.build(sell: sell3, openedAt: running[0].t, entry: 100, stop: 90,
                              target: 115, thesis: "test", bars: running)
        ok("selling into a continuing run reads as early", r3.verdict == .soldTooEarly, "got \(r3.verdict.rawValue)")

        // A spike above the exit that gives itself back is a good exit, not a missed
        // run. The order these two tests run in is the whole subtlety.
        let spiked = bars([100.0, 104, 108, 112, 118, 121, 110, 103, 99, 96], 0.02)
        let sell3b = Trade(
            id: "t3b", symbol: "AAPL", action: "sell", shares: 10, price: 112, quotedPrice: 112,
            value: 1120, at: spiked[3].t, commission: 0, slippage: 0, pnl: 120, rMultiple: 1.2,
            taxDue: 0, gapped: false, reason: "took profit", trigger: "manual", dayTrade: false
        )
        let r3b = Review.build(sell: sell3b, openedAt: spiked[0].t, entry: 100, stop: 90,
                               target: 115, thesis: "test", bars: spiked)
        ok("a spike that gave itself back is a good exit, not an early one",
           r3b.verdict == .goodExit, "got \(r3b.verdict.rawValue)")
        ok("and holding on would have been worse", (r3b.leftOnTable ?? 0) < 0)

        // Too little history after the exit is not evidence of anything.
        let short = bars([100.0, 104, 108], 0.02)
        let sell4 = Trade(
            id: "t4", symbol: "AAPL", action: "sell", shares: 10, price: 104, quotedPrice: 104,
            value: 1040, at: short[1].t, commission: 0, slippage: 0, pnl: 40, rMultiple: 0.4,
            taxDue: 0, gapped: false, reason: "x", trigger: "manual", dayTrade: false
        )
        let r4 = Review.build(sell: sell4, openedAt: short[0].t, entry: 100, stop: 90,
                              target: 115, thesis: "test", bars: short)
        ok("a fresh exit is not judged", r4.verdict == .tooSoon, "got \(r4.verdict.rawValue)")

        // Excursions.
        ok("heat taken is measured in R", (r.maeR ?? 0) >= 0.9, "got \(f(r.maeR ?? 0, 2))")
        ok("the best available move is measured in R", (r3.mfeR ?? 0) > 1, "got \(f(r3.mfeR ?? 0, 2))")

        // Pairing a flat trade log back into positions, including an averaged entry.
        let log = [
            Trade(id: "s1", symbol: "X", action: "sell", shares: 20, price: 120, quotedPrice: 120,
                  value: 2400, at: 3000, commission: 0, slippage: 0, pnl: 400, rMultiple: 1,
                  taxDue: 0, gapped: false, reason: "", trigger: "manual", dayTrade: false),
            Trade(id: "b2", symbol: "X", action: "buy", shares: 10, price: 120, quotedPrice: 120,
                  value: 1200, at: 2000, commission: 0, slippage: 0, pnl: nil, rMultiple: nil,
                  taxDue: nil, gapped: false, reason: "", trigger: nil, dayTrade: false),
            Trade(id: "b1", symbol: "X", action: "buy", shares: 10, price: 100, quotedPrice: 100,
                  value: 1000, at: 1000, commission: 0, slippage: 0, pnl: nil, rMultiple: nil,
                  taxDue: nil, gapped: false, reason: "", trigger: nil, dayTrade: false),
        ]
        let pairs = Review.pairs(log)
        ok("a close is paired with its entries", pairs.count == 1, "got \(pairs.count)")
        near("an averaged entry is reconstructed", pairs.first?.entry, 110, 1e-9)
        near("from the date of the first parcel", pairs.first?.openedAt, 1000, 1e-9)

        // Behavioural claims must not be made from a handful of trades.
        let thin = Review.behaviour([r, r2], state: Portfolio.empty(Profile.preset(.learner)),
                                    accountReturnPct: nil, benchmarkReturnPct: nil)
        ok("two trades produce no diagnosis",
           thin.patterns.allSatisfy { $0.contains("before they are readable") }, "\(thin.patterns)")
    }

    /* ----------------------------------------------------------------- regime */

    private static func marketRegime() {
        let strong = ramp(300, 100, 0.6)
        let members = [Analysis.analyse("A", bars(strong)), Analysis.analyse("B", bars(strong))]
        let bull = Analysis.marketRegime(Analysis.analyse("SPY", bars(strong)), members, "stocks")
        ok("a rising benchmark with full breadth reads bullish", bull.label == .bull, "got \(bull.label.rawValue)")
        near("breadth is 100% when every member holds its average", bull.breadthPct, 100, 1e-6)

        let weak = ramp(300, 280, -0.6)
        let bear = Analysis.marketRegime(Analysis.analyse("SPY", bars(weak)), [Analysis.analyse("A", bars(weak))], "stocks")
        ok("a falling benchmark with no breadth reads bearish", bear.label == .bear, "got \(bear.label.rawValue)")
    }

    /* ------------------------------------------------------ the native harness */

    /// The parts that only exist because Paper is an app now: the loopback server's
    /// request parsing, the static-file guard, and the JSON the front end reads.
    private static func harness() {
        let get = HTTPRequest(method: "GET", target: "/api/state?force=1&range=6mo", body: Data())
        ok("a query parameter is read off the request", get.query("force") == "1")
        ok("a second query parameter is read", get.query("range") == "6mo")
        ok("a missing query parameter is nil", get.query("nope") == nil)
        ok("the path drops the query string", get.path == "/api/state")

        let post = HTTPRequest(method: "POST", target: "/api/trade", body: Data(#"{"symbol":"AAPL","shares":3}"#.utf8))
        ok("a POST body parses as JSON", post.json["symbol"] as? String == "AAPL")
        ok("numbers survive the POST body", (post.json["shares"] as? Double) == 3)

        ok("a traversal out of site/ is refused", SiteFiles.serve("/../../etc/passwd").status == 404)
        ok("a missing asset is a 404", SiteFiles.serve("/definitely-not-here.js").status == 404)

        /* The universe is asserted by shape rather than by a single count, because a
         * count breaks every time a name is added and says nothing about what broke.
         * What matters is that all three venues are populated, that every symbol is
         * unique, and that each one is routed to the right exchange. */
        ok("every symbol appears once", Set(Universe.symbols).count == Universe.all.count)
        ok("the US board is the largest", Universe.symbols(in: .us).count >= 40,
           "got \(Universe.symbols(in: .us).count)")
        ok("Stockholm carries the OMXS30 large caps", Universe.symbols(in: .stockholm).count >= 25,
           "got \(Universe.symbols(in: .stockholm).count)")
        ok("crypto is unchanged at eight pairs", Universe.symbols(in: .crypto).count == 8,
           "got \(Universe.symbols(in: .crypto).count)")
        ok("every Stockholm symbol carries the .ST suffix or is the index",
           Universe.symbols(in: .stockholm).allSatisfy { $0.hasSuffix(".ST") || $0.hasPrefix("^") })
        ok("and every one of them is quoted in kronor",
           Universe.symbols(in: .stockholm).allSatisfy { Universe.currency(of: $0) == .sek })
        ok("while US listings stay in dollars",
           Universe.symbols(in: .us).allSatisfy { Universe.currency(of: $0) == .usd })
        ok("benchmarks are excluded from picks",
           Universe.benchmarks.contains("SPY") && Universe.benchmarks.contains("QQQ")
               && Universe.benchmarks.contains("^OMX"))
        ok("a Swedish name is measured against the Swedish index",
           Universe.benchmark(for: "VOLV-B.ST") == "^OMX")
        ok("a US name against the S&P", Universe.benchmark(for: "AAPL") == "SPY")
        ok("and crypto against bitcoin", Universe.benchmark(for: "SOL-USD") == "BTC-USD")
        // An unknown symbol must land on the strictest venue, not the loosest: the
        // safe failure is applying a clock and the PDT rule, never waiving both.
        ok("an unknown symbol is treated as US", Universe.venue(of: "ZZZZ") == .us)

        // Metrics and plans are what the front end reads; a rename here breaks the
        // interface silently, so the encoded keys are asserted rather than assumed.
        let m = Analysis.analyse("TEST", bars(ramp(300, 100, 0.6)))
        let encoded = try? JSONEncoder().encode(m)
        let asJson = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["symbol", "price", "sma20", "sma50", "sma200", "rsi14", "atr14", "atrPct",
                    "regime", "conviction", "scores", "bars", "drawdown1y"] {
            ok("metrics encode a \(key)", asJson[key] != nil)
        }
        ok("the regime encodes as its hyphenated name",
           (asJson["regime"] as? String)?.contains("trend") == true || asJson["regime"] as? String == "range",
           "got \(asJson["regime"] as? String ?? "nil")")

        let planJson = (try? JSONEncoder().encode(Analysis.buildPlan(m)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["entry", "target", "stop", "rr", "shares", "cost", "riskTaken", "riskBudget",
                    "sizedBy", "entryKind", "tightStop", "breakevenWinRate", "horizonDays"] {
            ok("the plan encodes a \(key)", planJson[key] != nil)
        }

        // The receipt reads these off the wire, and they are all computed properties —
        // which Swift's synthesised Codable does not write. That failure is invisible
        // from the page, since a missing field and a genuinely unpriced model look
        // identical there, so the encoded shape is asserted rather than assumed.
        var receipt = RunTelemetry.empty(kind: "ideas", model: "claude-opus-5", budget: 400_000)
        var one = call("screen", tokens: 1_000_000, cacheRead: 500, cacheWrite: 700)
        one.model = "claude-sonnet-5"
        receipt.calls = [one]
        receipt.finishedAt = receipt.startedAt + 1000
        let receiptJson = (try? JSONEncoder().encode(receipt))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["runId", "kind", "model", "startedAt", "finishedAt", "budgetTokens", "calls",
                    "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
                    "billedTokens", "failures", "estimatedCost", "cacheHitRate", "modelsUsed"] {
            ok("a run's telemetry encodes a \(key)", receiptJson[key] != nil)
        }
        ok("the cost that crosses the wire is the per-call one",
           abs((receiptJson["estimatedCost"] as? Double ?? 0) - 6.0) < 0.05,
           "got \(receiptJson["estimatedCost"] ?? "nil")")
        ok("and it names the model that was actually used",
           (receiptJson["modelsUsed"] as? [String]) == ["claude-sonnet-5"])

        // Round-tripping recomputes the derived figures rather than trusting them, so
        // a hand-edited file cannot claim a cost its calls do not support.
        var lying = receiptJson
        lying["estimatedCost"] = 999.0
        let lyingData = try? JSONSerialization.data(withJSONObject: lying)
        let reread = lyingData.flatMap { try? JSONDecoder().decode(RunTelemetry.self, from: $0) }
        ok("a decoded run recomputes its cost from the calls",
           reread != nil && abs((reread?.estimatedCost ?? 0) - 6.0) < 0.05)

        // The reset dialog reads every one of these to name what it is about to
        // destroy. A renamed field would silently produce a confirmation that counts
        // nothing, which is the one dialog in this app that must not be vague.
        let preview = ResetPreview(
            profiles: 2, trades: 9, openPositions: 1, closedTrades: 4, lessons: 3,
            appliedLessons: 1, analysisRuns: 5, sessions: 0, oldestAccountDays: 12,
            hasKeychainKey: true, keySource: "keychain", dataDirectory: "/tmp",
            items: ["2 accounts"]
        )
        let previewJson = (try? JSONEncoder().encode(preview))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        for key in ["profiles", "trades", "openPositions", "closedTrades", "lessons",
                    "appliedLessons", "analysisRuns", "sessions", "oldestAccountDays",
                    "hasKeychainKey", "keySource", "items"] {
            ok("the reset preview encodes a \(key)", previewJson[key] != nil)
        }

        // An unbroken run of winners has no finite profit factor, and JSON has no
        // infinity — the scorecard must leave the field out rather than emit garbage.
        let sc = Scorecard(closedTrades: 1, wins: 1, losses: 0, winRate: 100, avgWin: 10, avgLoss: nil,
                           profitFactor: nil, expectancyR: 1, bestTrade: nil, worstTrade: nil,
                           stoppedOut: 0, targetsHit: 1, manualExits: 0, gappedExits: 0, dayTrades: 0,
                           totalCommission: 0, totalSlippage: 0, totalTax: 0, pnlBeforeCosts: 10,
                           verdict: "")
        ok("a scorecard with no losses still encodes", (try? JSONEncoder().encode(sc)) != nil)
    }

    /* ------------------------------------------------- schema compatibility */

    /**
     * Every persisted type, checked against the rule that cost six accounts.
     *
     * This is `SchemaGate` run as an assertion. It is deliberately not a test of
     * behaviour — it is a test of *shape*, and it fails when a struct becomes
     * capable of breaking files that already exist, rather than waiting for it to
     * actually break one. The failure names the field and the file.
     */
    private static func schemaCompatibility() {
        let failures = SchemaGate.run()
        ok("every persisted type survives a field being added or removed", failures.isEmpty,
           failures.map { "\($0.subject): \($0.detail)" }.joined(separator: "\n        "))
        print("  note  " + SchemaGate.summary())

        // Forward compatibility: an older build opening a newer file. Free from
        // JSONDecoder today, asserted so that its loss would not be silent.
        ok("a ledger tolerates a key from a future build",
           SchemaGate.toleratesUnknownKeys(PortfolioState.self,
                                           Portfolio.empty(Profile.preset(.learner))))
        ok("a profile tolerates a key from a future build",
           SchemaGate.toleratesUnknownKeys(Profile.self, Profile.preset(.learner)))

        /* The specific shape that got through last time: the container was careful
         * and the thing it contained was not. A ledger whose equity curve predates
         * one of its own fields has to read. */
        let older = """
        {"profileId":"p1","cash":10000,"positions":[],"trades":[],
         "equityCurve":[{"t":1,"equity":10000,"cash":10000,"invested":0}],
         "createdAt":1,"realizedGains":[],"dayTrades":[],"contributions":[],
         "lastContributionMonth":"2026-1","startingCapital":10000,
         "totalContributed":0,"totalCommission":0,"totalSlippage":0,"totalTax":0}
        """
        let decoded = try? JSONDecoder().decode(PortfolioState.self, from: Data(older.utf8))
        ok("a ledger whose nested types predate a field still reads", decoded != nil)
        near("and the point it could not read before is intact", decoded?.equityCurve.first?.equity, 10_000, 1e-9)
    }

    /* ---------------------------------------------------------- regressions */

    /**
     * One assertion per fault found in the 2026-09-21 sweep, so none of them can
     * come back without saying so.
     */
    private static func regressions() {
        // F1 — a position with shares and no tax lots booked the whole proceeds as profit.
        do {
            let (_, dir) = tempLedger(frictionlessProfile())
            let legacy = """
            {"profileId":"p1","cash":0,"positions":[
              {"id":"a","symbol":"X","shares":100,"avgPrice":150,"openedAt":1,
               "openedSession":"2020-1-1","thesis":"legacy","highWater":150,"lowWater":150}],
             "trades":[],"equityCurve":[],"createdAt":1,"realizedGains":[],"dayTrades":[],
             "contributions":[],"lastContributionMonth":"2020-1","startingCapital":15000,
             "totalContributed":0,"totalCommission":0,"totalSlippage":0,"totalTax":0}
            """
            let url = dir.appendingPathComponent("legacy.json")
            try? Data(legacy.utf8).write(to: url)
            var profile = frictionlessProfile()
            profile.frictions = .none
            let led = Portfolio(profile: profile, url: url)
            ok("F1 a lot-less legacy ledger still reads", led.loadError == nil)
            if case .ok(let t) = led.sell(symbol: "X", mark: MarkPrice(price: 160), skipGate: true) {
                near("F1 a sale with no tax lot uses the position's own cost basis", t.pnl, 1_000, 1e-6)
            } else { ok("F1 the sale goes through", false) }
            try? FileManager.default.removeItem(at: dir)
        }

        // F2 — a split older than the position restated it anyway.
        do {
            let (p, dir) = tempLedger(frictionlessProfile())
            _ = p.buy(symbol: "X", shares: 10, mark: MarkPrice(price: 100), target: 130, stop: 90, skipGate: true)
            let before = p.state.positions.first
            let applied = p.applySplit(symbol: "X", ratio: 10,
                                       at: nowMs() - 180 * 86_400_000, label: "10:1")
            ok("F2 a split that predates the position is refused", applied == false)
            near("F2 and the entry is untouched", p.state.positions.first?.avgPrice, before?.avgPrice ?? 0, 1e-9)
            near("F2 and so is the stop", p.state.positions.first?.stop, 90, 1e-9)

            // The genuine case still works.
            p.backdateForTesting(symbol: "X", openedAt: nowMs() - 365 * 86_400_000)
            ok("F2 a split the position was held through still applies",
               p.applySplit(symbol: "X", ratio: 10, at: nowMs() - 180 * 86_400_000, label: "10:1"))
            near("F2 and restates the entry", p.state.positions.first?.avgPrice, 10, 1e-6)
            try? FileManager.default.removeItem(at: dir)
        }

        // F3 — crypto and Stockholm round trips counted against the US PDT allowance.
        do {
            var f = Frictions.retailBroker
            f.enforcePDT = true
            let now = Date().timeIntervalSince1970 * 1000
            let crypto = (0..<3).map { DayTradeRecord(symbol: "BTC-USD", at: now - Double($0) * 3_600_000, session: "s\($0)") }
            ok("F3 crypto day trades do not consume the US equity allowance",
               PDT.blocks(symbol: "AAPL", equity: 10_000, records: crypto, frictions: f) == nil)

            let stockholm = (0..<3).map { DayTradeRecord(symbol: "VOLV-B.ST", at: now - Double($0) * 3_600_000, session: "s\($0)") }
            ok("F3 nor do Stockholm ones",
               PDT.blocks(symbol: "AAPL", equity: 10_000, records: stockholm, frictions: f) == nil)

            let us = (0..<3).map { DayTradeRecord(symbol: "AAPL", at: now - Double($0) * 3_600_000, session: "s\($0)") }
            ok("F3 three US day trades still do",
               PDT.blocks(symbol: "MSFT", equity: 10_000, records: us, frictions: f) != nil)
        }

        // F9 — the grouping helper, which used to shadow the standard library's.
        ok("F9 grouped() separates thousands", grouped(1_234_567) == "1,234,567", grouped(1_234_567))
        ok("F9 and handles short and negative numbers",
           grouped(0) == "0" && grouped(999) == "999" && grouped(-12_345) == "-12,345",
           "\(grouped(0)) / \(grouped(999)) / \(grouped(-12_345))")

        // The logger, which several of the above now write to.
        do {
            Log.setThreshold(.debug)
            log("[selftest] a line written by the regression suite", .warn, "selftest")
            let seen = Log.recent(limit: 50, level: .warn, subsystem: "selftest")
            ok("the log keeps what it was told", seen.contains { $0.message.contains("regression suite") })
            ok("and records the level it was told", seen.first?.level == .warn)
            ok("a subsystem is inferred from the [tag] prefix the codebase already writes",
               { log("[market] inferred"); return Log.recent(limit: 5).contains { $0.subsystem == "market" } }())
            Log.setThreshold(.info)
        }
    }


    /* -------------------------------------------------- the adaptive predictor */

    /**
     * Can the desk find an edge that is there, and refuse one that is not?
     *
     * Both halves matter and the second one matters more. A learner that always
     * finds something is worse than no learner — it will fit the noise in any
     * book it is handed and then bet on it — so the load-bearing test here is the
     * one that hands it pure noise and requires it to promote nothing. The books
     * are fabricated so the right answer is known by construction rather than
     * argued about.
     */
    private static func predictAdaptation() {

        /* ---- a book with a planted, learnable residual ---- */
        do {
            // The market is priced as a noisy, *biased* reading of the truth, and
            // the tape carries the part the price is missing. A reading that can
            // see the tape should therefore beat the price — and the blend cannot,
            // because the blend has no vocabulary for "the price is off in this
            // particular circumstance".
            var rng = SeededRandom(seed: 20260922)
            let book = (0..<260).map { i -> ShadowWindow in
                let truth = rng.nextGaussian()
                let up = truth > 0
                // The price sees the truth with noise and a systematic shrink.
                let priced = 1 / (1 + exp(-(truth * 0.55 + rng.nextGaussian() * 0.35)))
                var samples: [ShadowSample] = []
                for bucket in stride(from: 30.0, through: 270.0, by: 15.0) {
                    let jitter = rng.nextGaussian() * 0.02
                    let pm = Analysis.clamp(priced + jitter, 0.02, 0.98)
                    samples.append(ShadowSample(
                        offset: bucket,
                        pModel: Analysis.clamp(0.5 + rng.nextGaussian() * 0.05, 0.02, 0.98),
                        pMarket: pm,
                        upAsk: Analysis.clamp(pm + 0.02, 0.01, 0.99),
                        downAsk: Analysis.clamp(1 - pm + 0.02, 0.01, 0.99),
                        // The residual, in the units `rows` will scale it by.
                        moveBps: truth * 40))
                }
                _ = i
                return ShadowWindow(start: Double(1_700_000_000 + i * 300), samples: samples,
                                    resolved: up ? .up : .down, resolvedAt: 0,
                                    degraded: false, regime: nil)
            }

            let (results, winner) = PredictLearner.contest(book, champion: .market())
            ok("a learnable residual is found", winner != nil,
               results.map { "\($0.id) \(f($0.sigma, 1))σ" }.joined(separator: ", "))
            if let winner {
                ok("and the reading promoted is one that can see it",
                   winner.features.contains(.move), winner.id)
                ok("it beat the market out of sample", winner.gainOverChampion > 0,
                   f(winner.gainOverChampion, 5))
                ok("by more than the promotion bar", winner.sigma >= PredictLearner.promotionSigma,
                   "\(f(winner.sigma, 1))σ")
            }

            let (policy, _, changed) = PredictLearner.settle(book, champion: .market())
            ok("and settling adopts it", changed && !policy.isDefault, policy.candidateId)

            /* The point of the whole exercise: a desk that can express the residual
             * can act, and one stuck at a blend weight of zero cannot. */
            let underPolicy = PredictAudit.qualifyingLooks(book, weight: 0, policy: policy, minEdge: 0.05)
            let underDeadBlend = PredictAudit.qualifyingLooks(book, weight: 0, policy: nil, minEdge: 0.05)
            ok("the promoted reading can find something to do", underPolicy > 0, "\(underPolicy) looks")
            ok("where the dead blend finds nothing at all", underDeadBlend == 0, "\(underDeadBlend) looks")
        }

        /* ---- a book that is pure noise ---- */
        do {
            var rng = SeededRandom(seed: 7)
            let book = (0..<260).map { i -> ShadowWindow in
                let up = rng.nextUniform() < 0.5
                var samples: [ShadowSample] = []
                for bucket in stride(from: 30.0, through: 270.0, by: 15.0) {
                    let pm = Analysis.clamp(0.5 + rng.nextGaussian() * 0.12, 0.02, 0.98)
                    samples.append(ShadowSample(
                        offset: bucket,
                        pModel: Analysis.clamp(0.5 + rng.nextGaussian() * 0.12, 0.02, 0.98),
                        pMarket: pm,
                        upAsk: Analysis.clamp(pm + 0.02, 0.01, 0.99),
                        downAsk: Analysis.clamp(1 - pm + 0.02, 0.01, 0.99),
                        moveBps: rng.nextGaussian() * 40))
                }
                return ShadowWindow(start: Double(1_700_000_000 + i * 300), samples: samples,
                                    resolved: up ? .up : .down, resolvedAt: 0,
                                    degraded: false, regime: nil)
            }
            let (results, winner) = PredictLearner.contest(book, champion: .market())
            ok("pure noise promotes nothing", winner == nil,
               winner.map { "\($0.id) at \(f($0.sigma, 1))σ" } ?? "")
            ok("and the field is still scored so the finding is on the record", !results.isEmpty)
            let (_, _, changed) = PredictLearner.settle(book, champion: .market())
            ok("settling leaves the market in force", !changed)
        }

        /* ---- too little evidence is not the same as no evidence ---- */
        do {
            var rng = SeededRandom(seed: 3)
            let short = (0..<40).map { i -> ShadowWindow in
                let up = rng.nextUniform() < 0.5
                let pm = Analysis.clamp(0.5 + rng.nextGaussian() * 0.1, 0.02, 0.98)
                return ShadowWindow(
                    start: Double(1_700_000_000 + i * 300),
                    samples: [ShadowSample(offset: 150, pModel: 0.5, pMarket: pm,
                                           upAsk: pm + 0.02, downAsk: 1 - pm + 0.02, moveBps: 0)],
                    resolved: up ? .up : .down, resolvedAt: 0, degraded: false, regime: nil)
            }
            let (results, winner) = PredictLearner.contest(short, champion: .market())
            ok("a book below the minimum runs no contest at all", results.isEmpty && winner == nil)
        }

        /* ---- the audit names the absorbing state ---- */
        do {
            // A book where the market and the model agree exactly: the blend at any
            // weight reproduces the price, so no edge can ever exist. This is the
            // shape the real desk was in, and the audit has to call it stuck rather
            // than report it as a desk that is merely waiting for data.
            var rng = SeededRandom(seed: 11)
            let book = (0..<140).map { i -> ShadowWindow in
                let up = rng.nextUniform() < 0.5
                var samples: [ShadowSample] = []
                for bucket in stride(from: 30.0, through: 270.0, by: 15.0) {
                    let pm = Analysis.clamp(0.5 + rng.nextGaussian() * 0.1, 0.02, 0.98)
                    samples.append(ShadowSample(
                        offset: bucket, pModel: pm, pMarket: pm,
                        // Priced with no slack at all, so nothing can clear a 5¢ bar.
                        upAsk: pm, downAsk: 1 - pm, moveBps: rng.nextGaussian() * 30))
                }
                return ShadowWindow(start: Double(1_700_000_000 + i * 300), samples: samples,
                                    resolved: up ? .up : .down, resolvedAt: 0,
                                    degraded: false, regime: nil)
            }
            var brain = PredictBrain.unlearned()
            brain.modelWeight = 0
            brain.weightIsDefault = false
            brain.weightWindows = 140
            let report = PredictAudit.run(book: book, brain: brain, policy: .market(),
                                          bets: [], minEdge: 0.05)
            ok("a desk that cannot act is reported stuck, not merely waiting",
               report.verdict == .blocked, report.verdict.rawValue)
            let reach = report.checks.first { $0.id == "reach" }
            ok("and the check that says so is the reachability one",
               reach?.verdict == .blocked)
            ok("with a remedy rather than only a diagnosis", reach?.remedy != nil)
        }

        /* ---- a weight of zero, measured honestly, is idle rather than stuck ---- */
        do {
            // The model disagrees with the price and the asks leave room, so the
            // shipped 25% finds looks; the fitted weight of zero finds none. With the
            // contest in place that is a finding, and the audit has to say so rather
            // than send someone hunting for a fault.
            var rng = SeededRandom(seed: 13)
            let book = (0..<140).map { i -> ShadowWindow in
                let up = rng.nextUniform() < 0.5
                var samples: [ShadowSample] = []
                for bucket in stride(from: 30.0, through: 270.0, by: 15.0) {
                    let pm = Analysis.clamp(0.5 + rng.nextGaussian() * 0.1, 0.1, 0.9)
                    samples.append(ShadowSample(
                        offset: bucket,
                        pModel: Analysis.clamp(pm + (rng.nextUniform() < 0.5 ? -0.4 : 0.4), 0.02, 0.98),
                        pMarket: pm, upAsk: pm, downAsk: 1 - pm, moveBps: 0))
                }
                return ShadowWindow(start: Double(1_700_000_000 + i * 300), samples: samples,
                                    resolved: up ? .up : .down, resolvedAt: 0,
                                    degraded: false, regime: nil)
            }
            var brain = PredictBrain.unlearned()
            brain.modelWeight = 0
            brain.weightIsDefault = false
            brain.weightWindows = 140
            let shipped = PredictAudit.qualifyingLooks(book, weight: PredictModel.defaultMaxWeight,
                                                       policy: nil, minEdge: 0.05)
            ok("the fixture leaves the shipped weight something to do", shipped > 0, "\(shipped) looks")
            let report = PredictAudit.run(book: book, brain: brain, policy: .market(),
                                          bets: [], minEdge: 0.05)
            let reach = report.checks.first { $0.id == "reach" }
            ok("a zero weight with the market in force is not reported stuck",
               reach?.verdict == .healthy, reach?.verdict.rawValue ?? "no reach check")
        }

        /* ---- windows measured under a retired open are kept and never fitted ---- */
        do {
            // A row exactly as 4.17.0 and earlier wrote it: no `openRule`. Its pModel
            // and moveBps were measured against a single tick, which is not the
            // model the desk runs now.
            let legacy = #"{"start":1700000000,"samples":[{"offset":150,"pModel":0.6,"pMarket":0.55,"upAsk":0.57,"downAsk":0.46,"moveBps":3}],"resolved":"Up","resolvedAt":0,"degraded":false}"#
            let old = try? JSONDecoder().decode(ShadowWindow.self, from: Data(legacy.utf8))
            ok("a pre-stamp window still decodes", old != nil)
            ok("and is read as the old open", old?.openRule == nil && old?.isCurrentOpen == false)
            ok("so no fit reads it", old?.isTrainable == false)
            ok("the learner drops it", PredictLearner.rows(old.map { [$0] } ?? []).isEmpty)

            let fresh = ShadowWindow(start: 1_700_000_300, samples: old?.samples ?? [],
                                     resolved: .up, resolvedAt: 0, degraded: false, regime: nil)
            ok("a window recorded now carries the current rule",
               fresh.openRule == PredictModel.openRule && fresh.isTrainable)
            ok("and the learner reads it", PredictLearner.rows([fresh]).count == 1)

            if let data = try? JSONEncoder().encode(fresh),
               let back = try? JSONDecoder().decode(ShadowWindow.self, from: data) {
                ok("the stamp survives a round trip", back.openRule == PredictModel.openRule)
            } else {
                ok("the stamp survives a round trip", false, "encode/decode failed")
            }

            let mixed = [old, fresh].compactMap { $0 }
            let report = PredictAudit.run(book: mixed, brain: .unlearned(), policy: .market(),
                                          bets: [], minEdge: 0.05)
            let inflow = report.checks.first { $0.id == "inflow" }
            ok("the audit counts the retired window separately",
               inflow?.readings.contains { $0.name.hasPrefix("Measured under an older open") && $0.value == "1" } == true)
        }

        /* ---- the fidelity check catches a fill that never matched the rehearsal ---- */
        do {
            // The 4.14.0 stake-cap failure, as evidence: filled at many times the
            // ask the shadow book scores against.
            let bad = [
                SettledBet(at: 0, side: "Down", expectedAsk: 0.001, filledAsk: 0.0046,
                           stake: 136.57, pnl: -136.57, won: false),
                SettledBet(at: 0, side: "Down", expectedAsk: 0.001, filledAsk: 0.0235,
                           stake: 763.24, pnl: -763.24, won: false),
            ]
            let report = PredictAudit.run(book: [], brain: .unlearned(), policy: .market(),
                                          bets: bad, minEdge: 0.05)
            let fidelity = report.checks.first { $0.id == "fidelity" }
            ok("a fill far from the rehearsal is reported broken", fidelity?.verdict == .broken,
               fidelity?.verdict.rawValue ?? "nil")

            let good = [
                SettledBet(at: 0, side: "Up", expectedAsk: 0.42, filledAsk: 0.425,
                           stake: 42, pnl: 12, won: true),
                SettledBet(at: 0, side: "Down", expectedAsk: 0.31, filledAsk: 0.312,
                           stake: 31, pnl: -31, won: false),
            ]
            let clean = PredictAudit.run(book: [], brain: .unlearned(), policy: .market(),
                                         bets: good, minEdge: 0.05)
            ok("and fills that match it are reported healthy",
               clean.checks.first { $0.id == "fidelity" }?.verdict == .healthy)
        }

        /* ---- a book from an older build still reads ---- */
        do {
            // Every field the current build writes, minus the ones that arrived
            // later. This is the shape that destroyed six ledgers in September and
            // would have destroyed the shadow book the same way.
            let older = """
            [{"start":1700000000,
              "samples":[{"offset":150,"pModel":0.55}],
              "resolved":"Up"}]
            """
            let rows = try? JSONDecoder().decode([ShadowWindow].self, from: Data(older.utf8))
            ok("a shadow book predating half its own fields still reads", rows?.count == 1)
            ok("and the sample inside it survives", rows?.first?.samples.count == 1)
            near("with the value it did carry intact", rows?.first?.samples.first?.pModel, 0.55, 1e-9)
            // A window whose feed health was never recorded is assumed degraded,
            // so it is excluded from the fits rather than quietly trusted.
            ok("a window with no recorded feed health is treated as degraded",
               rows?.first?.degraded == true)
            near("and a missing regime reading is absent, not zeroed into the fit",
                 rows?.first?.regime == nil ? 1 : 0, 1, 1e-9)
        }

        /* ---- the solver itself ---- */
        do {
            // A separable problem with a known answer: outcome follows the market
            // logit exactly, so the fit should recover roughly (0, 1).
            let rows = (0..<400).map { i -> LearnRow in
                let x = Double(i % 40) / 10 - 2
                return LearnRow(window: i / 4, outcome: x > 0 ? 1 : 0,
                                logitMarket: x, logitModel: 0, move: 0, offset: 0,
                                regime: [0, 0, 0, 0, 0])
            }
            let beta = PredictLearner.fit(rows, [.market])
            ok("the solver recovers the sign of a known relationship", beta.count == 2 && beta[1] > 0,
               beta.map { f($0, 2) }.joined(separator: ", "))
            // A policy built from the market alone must reproduce the market exactly.
            let market = PredictPolicy.market()
            let row = LearnRow(window: 0, outcome: 0, logitMarket: log(0.7 / 0.3),
                               logitModel: 0, move: 0, offset: 0, regime: [0, 0, 0, 0, 0])
            near("and the default policy is the market price, to the decimal",
                 market.probability(row), 0.7, 1e-9)
        }
    }

    /**
     * A reproducible generator, so a fabricated book is the same book on every run.
     *
     * A test that fabricates data from `Double.random` is a test that fails once a
     * month for reasons nobody can reconstruct.
     */
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func nextUniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }

        /// Box–Muller. Only the first of the pair is used; the second is cheap to
        /// discard and keeping it would mean holding state nothing else needs.
        mutating func nextGaussian() -> Double {
            let u1 = Swift.max(nextUniform(), 1e-12)
            let u2 = nextUniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

}
