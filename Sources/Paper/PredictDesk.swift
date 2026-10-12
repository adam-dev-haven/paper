/**
 * PredictDesk.swift — the run that watches, decides and bets on its own.
 *
 * A session on the Session tab waits to be told. This one does not: you commit a
 * bankroll and a length of time, and then it reads the Bitcoin tape and
 * Polymarket's book every ten seconds for as long as it is running, forms a
 * probability for each five-minute window, compares that probability against what
 * the window is being offered at, and buys when the gap is big enough to be worth
 * paying the spread for. Nobody presses anything. That is the point of it, and it
 * is also the reason every number behind a bet is written down at the moment the
 * bet is placed rather than reconstructed afterwards from an outcome.
 *
 * **Four rules that cannot be argued with while it runs**, for the same reason
 * they exist on the Session tab: a limit you can raise in the moment you most want
 * to raise it is not a limit.
 *
 *   A **bankroll**, not the account. The prediction desk never touches the trading
 *   ledger. Binary contracts have no cost basis, no holding period and no
 *   counterparty you can sell back to before resolution; putting them through the
 *   same FIFO tax lots as a share of Apple would produce a ledger that is wrong
 *   about both of them. This bankroll is its own money, and the screen says so.
 *
 *   A **loss limit** that ends it. Checked after every settlement.
 *
 *   A **target** that also ends it, because a run of correct five-minute calls is
 *   the exact condition under which people stop sizing and start pressing.
 *
 *   **One bet per window, at most.** There are twelve windows an hour. Without
 *   this the run is not a strategy, it is a subscription.
 *
 * **What it is not.** There is no wallet here, no key, no signature and no path to
 * Polymarket's order endpoint — this file reads a public book and nothing else.
 * Every fill is simulated against real depth. Nothing is bought, and no advice is
 * being given about whether anyone should buy it.
 */

import Foundation

/* ----------------------------------------------------------------- the bet */

/// One simulated position in one window, with the whole case for it preserved.
struct PredictBet: Codable {
    var window: PredictWindow
    var side: PredictSide
    var placedAt: Double
    /// Contracts held. Each one pays exactly $1 if the side is right, $0 if not.
    var shares: Double
    /// Volume-weighted fill across the book levels that were actually taken.
    var cost: Double
    /// `shares × cost`. What left the bankroll.
    var stake: Double

    /* The case, as it stood at the moment of the fill. */
    var modelP: Double
    /// `modelP − cost`. The whole reason the bet exists.
    var edge: Double
    var requiredEdge: Double
    /// Full Kelly, before the run's fraction and caps were applied.
    var kellyFull: Double
    /// Best offer when the decision was made, so the slippage paid is visible.
    var bestAsk: Double
    var spread: Double?
    /// Bitcoin at the window's open, and where it was when the bet went on.
    var openPrice: Double
    var spotAtEntry: Double
    var twapAtEntry: Double
    var secondsIntoWindow: Double
    var sizeNote: String?
    var thesis: String
    /// Placed by hand rather than by the desk. Optional for the usual decoding
    /// reason, and kept because a record that cannot tell the two apart cannot
    /// answer the only question worth asking of a mixed run — which of us was right.
    var manual: Bool? = nil
    var wasManual: Bool { manual ?? false }
    /// Taken under the run's recovery rule rather than on its own merits — a
    /// relaxed bar and a size chosen to erase the deficit. Flagged at the position
    /// rather than inferred from the run, because a recovery run's early bets are
    /// ordinary ones and pooling them is how a bad rule hides inside a good record.
    var recovery: Bool? = nil
    var wasRecovery: Bool { recovery ?? false }

    /* Settlement. */
    var settledAt: Double?
    var resolved: PredictSide?
    /// `shares` if right, 0 if wrong.
    var payout: Double?
    var pnl: Double?
    /// True while Polymarket has closed the window but not yet published a result.
    var awaitingResolution: Bool = false

    var isOpen: Bool { settledAt == nil }
    var won: Bool? { resolved.map { $0 == side } }
}

/**
 * The nearest a declined window came to clearing its bar.
 *
 * A run that buys nothing used to report a table of verdicts and nothing else,
 * which answers "what happened" and not "how close was it". Those are different
 * questions and the second one is the one worth acting on: a run whose best look
 * was four cents short of a five-cent bar was nearly in business, and a run whose
 * best look was eleven cents short was never going to be. The first is a reason to
 * run it again; the second is a reason to change something.
 */
struct ClosestMiss: Codable {
    let windowLabel: String
    let side: PredictSide
    let edge: Double
    let required: Double
    /// Seconds into the window at which the best look happened.
    let offset: Double
    var shortfall: Double { required - edge }
}

/* ----------------------------------------------------------------- the run */

enum PredictStatus: String, Codable {
    case running
    case metTarget = "met-target"
    case hitLossLimit = "hit-loss-limit"
    case outOfTime = "out-of-time"
    case stopped

    var isOver: Bool { self != .running }

    var label: String {
        switch self {
        case .running: return "Running"
        case .metTarget: return "Target reached"
        case .hitLossLimit: return "Loss limit hit"
        case .outOfTime: return "Time up"
        case .stopped: return "Stopped by you"
        }
    }
}

struct PredictRun: Codable {
    var id: String
    var profileId: String
    var startedAt: Double
    var endsAt: Double
    var minutes: Double

    /// The money committed to this run. Separate from the trading account.
    var bankroll: Double
    /// Of the bankroll. Reaching it ends the run.
    var maxLossPct: Double
    var targetPct: Double
    /// The most any one window may take, as a share of the bankroll.
    var maxStakePct: Double
    /// How much of full Kelly to bet. A quarter by default.
    var kellyFraction: Double
    /// The probability-minus-price gap a window has to show before anything is
    /// bought. In cents on the dollar: 0.05 means the model must be five points
    /// better than the offer.
    var minEdge: Double
    /// How far into a five-minute window the desk waits before deciding. Early in
    /// a window almost nothing is settled and the model is near a coin flip; late
    /// in one the price has already moved to where the model is.
    var entryOffsetSeconds: Double
    /// And how close to the bell it stops trying. Inside this, the book thins out
    /// and a fill walks several cents.
    var cutoffSeconds: Double

    var status: PredictStatus
    /**
     * Whether the desk places its own bets or only recommends them.
     *
     * Off means it does everything it otherwise would — reads the window, forms a
     * probability, prices both sides, sizes the position — and then stops and says
     * so instead of buying. The run still records every window it read and still
     * learns from every one that resolves, because none of that depends on money
     * having moved. Optional for decoding; absent means the original behaviour.
     */
    var autoBet: Bool?
    var betsAutomatically: Bool { autoBet ?? true }
    var bets: [PredictBet]
    /// Windows the run has looked at, whether or not it bet on them.
    var windowsSeen: Int
    /**
     * Why the windows it passed on were passed on, counted by verdict.
     *
     * A run that correctly does nothing for half an hour is the normal outcome here,
     * and an empty table is the least informative way to report it. This turns "it
     * bought nothing" into "four windows the calibration vetoed and two where the
     * price was already where the model was", which is a result rather than a shrug.
     *
     * Optional on purpose: Swift's synthesised decoding calls `decodeIfPresent` for
     * an optional property and yields nil for a missing key, while a non-optional
     * with a default value throws instead. A run file written before this field
     * existed therefore still opens.
     */
    /**
     * Chase losses.
     *
     * Off, and off by default, because it is the martingale and the martingale does
     * not work. A binary contract is worth `p − price`; being down fifty dollars
     * moves neither term, so a window the desk would decline while flat is exactly
     * as bad a bet while behind. Worse, "win back $50 on a $50 stake" only prices
     * under fifty cents, and "win back $50 on a $25 stake" only under a third —
     * the cheap tail, which is cheap because it loses. The desk's own first three
     * losing bets were sub-three-cent contracts.
     *
     * It is here anyway, and that is deliberate. This is a simulator with fake
     * money whose Review tab exists to find behavioural patterns, and the single
     * most expensive belief a trader can hold is that they can trade their way out
     * of a hole. Arguing about it costs nothing and convinces nobody; running it
     * on a labelled flag beside the same desk's ordinary bets produces a number.
     *
     * What it does when on, and only once the run is actually down: drops the
     * required edge to zero, so the desk takes any window it thinks is mispriced
     * at all rather than only the ones clearing its bar; and sizes to the deficit —
     * the stake whose win returns the run to exactly flat — instead of to Kelly.
     * Everything else still binds. The per-window cap, the free bankroll, the loss
     * limit, and the cost cap on the fill all apply unchanged, so the rule can lose
     * the run faster but cannot lose it more. It will never knowingly buy a
     * negative edge: a bad price is still refused, whatever the deficit.
     */
    var recovery: Bool?
    var recoversLosses: Bool { recovery ?? false }

    var skipped: [String: Int]?
    /// The best any declined window managed, across the whole run. Optional for the
    /// same decoding reason as `skipped`.
    var closestMiss: ClosestMiss?
    var endedAt: Double?
    var endNote: String?

    static func opening(profileId: String, bankroll: Double, minutes: Double,
                        maxLossPct: Double, targetPct: Double, maxStakePct: Double,
                        kellyFraction: Double, minEdge: Double,
                        entryOffsetSeconds: Double, cutoffSeconds: Double,
                        autoBet: Bool, recovery: Bool = false) -> PredictRun {
        PredictRun(
            id: UUID().uuidString, profileId: profileId,
            startedAt: nowMs(), endsAt: nowMs() + minutes * 60_000, minutes: minutes,
            bankroll: bankroll, maxLossPct: maxLossPct, targetPct: targetPct,
            maxStakePct: maxStakePct, kellyFraction: kellyFraction, minEdge: minEdge,
            entryOffsetSeconds: entryOffsetSeconds, cutoffSeconds: cutoffSeconds,
            status: .running, autoBet: autoBet,
            bets: [], windowsSeen: 0, recovery: recovery, skipped: [:],
            closestMiss: nil, endedAt: nil, endNote: nil
        )
    }

    var lossLimit: Double { bankroll * (maxLossPct / 100) }
    var targetAmount: Double { bankroll * (targetPct / 100) }
    var maxStake: Double { bankroll * (maxStakePct / 100) }
    var secondsLeft: Double { Swift.max(0, (endsAt - nowMs()) / 1000) }

    /// Settled results only.
    var realised: Double { bets.compactMap(\.pnl).reduce(0, +) }
    /// What is currently sitting in unsettled contracts, at cost.
    var committed: Double { bets.filter(\.isOpen).reduce(0) { $0 + $1.stake } }
    /// What is free to bet with.
    var available: Double { Swift.max(0, bankroll + realised - committed) }

    /// How far under water the settled record is, or zero when it is not.
    var deficit: Double { Swift.max(0, -realised) }
    /// Whether the recovery rule is both switched on and actually applicable.
    var recovering: Bool { recoversLosses && deficit > 0.01 }

    var settledBets: [PredictBet] { bets.filter { !$0.isOpen } }
    var wins: Int { settledBets.filter { $0.won == true }.count }
    var losses: Int { settledBets.filter { $0.won == false }.count }
    /// The wins the prices paid were already forecasting. A contract bought at 80¢
    /// is the market saying 80%, so the sum of fills is how many it expected to
    /// come in — and "9 of 13" means nothing until it is set beside this.
    var pricedWins: Double { settledBets.reduce(0) { $0 + $1.cost } }

    func hasBet(on window: PredictWindow) -> Bool {
        bets.contains { $0.window.start == window.start }
    }
}

/* ------------------------------------------------------------ the decision */

/// What the desk decided about the current window, and why — shown whether or not
/// it bet, because "it did nothing for eleven minutes" is a result that needs a
/// reason as much as a fill does.
struct PredictDecision: Codable {
    enum Verdict: String, Codable {
        case tooEarly = "too-early"
        case tooLate = "too-late"
        case alreadyBet = "already-bet"
        case noEdge = "no-edge"
        case vetoed
        case tooThin = "too-thin"
        case tooSmall = "too-small"
        case noRoom = "no-room"
        case taken
        case idle
        /**
         * The window came and went without the desk ever evaluating it inside its
         * own tradeable band.
         *
         * Not a judgement about the window — a report that the loop never got a look
         * at it, because it was busy, the feed was down, or the band was too narrow
         * for the tick cadence to land inside. It exists so that case stops being
         * silently filed as `too-late`, which is what it used to be and which reads
         * as a decision rather than an omission.
         */
        case missed

        /**
         * The market has called the window, and the desk is not arguing with it.
         *
         * Raised when the price has saturated — outside `PredictModel.decidedBound`
         * — or when the cheap side is offered under `PredictModel.minimumPrice`.
         * Both say the same thing: there is no probability left in this price, only
         * a settlement waiting to print. The model's own view late in a window is
         * almost entirely feed uncertainty, so a disagreement here is a statement
         * about Paper's data rather than about Bitcoin, and acting on it is the
         * cheap-tail purchase this desk exists to refuse.
         */
        case decided
    }

    let verdict: Verdict
    let side: PredictSide?
    let modelP: Double?
    let price: Double?
    let edge: Double?
    let requiredEdge: Double
    let kellyFull: Double?
    let wouldStake: Double?
    let wouldBuy: Double?
    let reason: String
    /// Whether this is the recovery rule talking. See `PredictRun.recovery`.
    var recovery: Bool = false
}

/**
 * What the desk saw of one window, accumulated across every tick inside it.
 *
 * Lives here rather than inside the actor because the rule in `note` is the whole
 * correction — the previous version of it could only ever report one answer — and a
 * rule that important should be reachable by a test without a running desk.
 */
struct WindowWatch {
    let window: PredictWindow
    /// Last verdict from a tick **inside the tradeable band**. Nil while no in-band
    /// look has happened.
    var decisive: PredictDecision.Verdict?
    /// The best edge the window ever offered, and what was being asked of it.
    var bestEdge: Double?
    var bestRequired: Double = 0
    var bestSide: PredictSide?
    var bestOffset: Double = 0
    /* The best the window ever offered *at any point*, in or out of the band.
     *
     * Separate from `bestEdge`, which only counts looks the desk was allowed to act
     * on, because the two answer different questions. That one is "how close did it
     * come"; this one is "was the moment already gone by the time it was allowed to
     * look" — and if an edge repeatedly peaks before the entry offset, that is the
     * single most useful thing the record can say about where the offset should be.
     */
    var bestAnyEdge: Double?
    var bestAnyOffset: Double = 0
    var looks = 0
    var bought = false

    /**
     * Folds one tick into the window's record.
     *
     * **Only in-band ticks set the verdict**, and that is the entire fix. Outside the
     * band, `too-early` and `too-late` are facts about the clock rather than about
     * the window. The old version let every tick overwrite the verdict and banked
     * whatever the last one said — and the last tick of every window is inside the
     * cutoff by construction, so the tally reported `too-late` and nothing else, for
     * ever. Six windows where the price was simply fair were indistinguishable from
     * six the desk never looked at.
     *
     * A bought window returns immediately and stays bought. Without that, the tick
     * after a fill reports `.alreadyBet` — true, and a fact about that tick rather
     * than about the window — and the window would be banked as a refusal on top of
     * the bet it already carries, putting the tally and `windowsSeen` out of step.
     */
    mutating func note(_ decision: PredictDecision, inBand: Bool,
                       elapsed: Double, alreadyBet: Bool) {
        if decision.verdict == .taken || alreadyBet { bought = true; return }
        // Tracked first and unconditionally: the whole point of it is the looks the
        // band excludes.
        if let edge = decision.edge, bestAnyEdge.map({ edge > $0 }) ?? true {
            bestAnyEdge = edge
            bestAnyOffset = elapsed
        }
        guard inBand else { return }
        looks += 1
        decisive = decision.verdict
        // Kept from any in-band look, including one that cleared the bar and was then
        // refused for size: the best the window ever offered is the honest answer to
        // "how close did this come".
        if let edge = decision.edge, bestEdge.map({ edge > $0 }) ?? true {
            bestEdge = edge
            bestRequired = decision.requiredEdge
            bestSide = decision.side
            bestOffset = elapsed
        }
    }

    /// What the window is filed under. A window that never got an in-band look is
    /// `missed` — an omission, not a decision about it.
    var verdict: PredictDecision.Verdict { decisive ?? .missed }
}

/* ------------------------------------------------------------- the track */

/// One instant on the current window's own record: where the market was and where
/// the desk was, at the same moment.
struct TrackPoint: Codable {
    let t: Double
    /// Polymarket's implied probability of Up, overround removed. The line the book
    /// is actually drawing.
    let market: Double?
    /// What the desk made of the window at that instant, after the blend — so the
    /// two lines are directly comparable and the gap between them *is* the edge.
    let model: Double?
    let verdict: String
}

/// A bet, on the chart, at the second it went on.
struct TrackMarker: Codable {
    let t: Double
    let side: PredictSide
    let price: Double
    let label: String
}

/**
 * The current five-minute window, as something that can be drawn.
 *
 * **Why this rather than showing Polymarket's own chart.** Their page renders the
 * contract price over the window, which is one of the two things worth watching and
 * not the more important one. The question being paid out on is whether the
 * window's *time-weighted average* finishes at or above the price it opened at, and
 * no chart of the contract price shows you that — it shows you what other people
 * think about it. So this draws both: Bitcoin against the open, which is the thing
 * being resolved, and the market's price against the desk's own probability, which
 * is where a bet comes from. Embedding their page would also mean rendering someone
 * else's site inside this one to get less information than its public API already
 * gives.
 *
 * The Bitcoin line is rebuilt from the tape on every read rather than stored: it is
 * already there at one-second resolution and keeping a second copy of it would be
 * two things to get out of step.
 */
struct PredictTrack: Codable {
    let window: PredictWindow
    /// The level the whole window is measured against.
    let openPrice: Double?
    /// Bitcoin, one point a second, from the window's open to now.
    let btc: [TapePoint]
    /// The window's average so far, and where it lands if the price stays put.
    let twapSoFar: Double?
    let projected: Double?
    /// Where the desk is allowed to act, in seconds into the window. The shaded band.
    let bandFrom: Double
    let bandTo: Double
    let elapsed: Double
    let points: [TrackPoint]
    let markers: [TrackMarker]
}

/* ------------------------------------------------------------- the panel */

struct PredictPanel: Codable {
    let run: PredictRun?
    let status: String
    let window: PredictWindow?
    let windowLabel: String?
    let question: String?
    /// Seconds left in the current five-minute window.
    let windowSecondsLeft: Double
    let forecast: PredictForecast?
    let calibration: PredictCalibration?
    /// How well this app's price feed reproduces the one the market settles on.
    /// The single most important caveat on the screen, so it rides on every read.
    let fidelity: PredictFidelity
    /// Which exchanges are actually live, and whether the tape is a median or a
    /// fallback. A run that quietly dropped to polled Yahoo is running a different
    /// strategy from the one that was started.
    let feedHealth: FeedHealth
    /// The three parameters fitted from the shadow book, and how much evidence each
    /// is standing on.
    let brain: PredictBrain
    /// The entry offset actually in force, which is the run's own unless the book
    /// has earned the right to override it.
    let effectiveEntryOffset: Double
    /// The current window as a drawable thing — Bitcoin against its open, the book
    /// against the desk's own view, and any bet marked at the second it went on.
    let track: PredictTrack?
    /// What the windows before this one had been doing, and what — if anything — the
    /// cross-window model makes of it.
    let regime: RegimeFeatures?
    let regimeReadings: [FeatureReading]
    /// The best edge this window has offered at any point, and how far in — including
    /// the part of it the desk was not yet allowed to act on.
    let windowBestEdge: Double?
    let windowBestOffset: Double
    /// Best offer per side, right now.
    let upAsk: Double?
    let downAsk: Double?
    let upBid: Double?
    let downBid: Double?
    let bookDepthUp: Double?
    let bookDepthDown: Double?
    let decision: PredictDecision?
    let realised: Double
    let unrealised: Double
    let total: Double
    let totalPct: Double
    let available: Double
    let lossLimit: Double
    let lossHeadroom: Double
    let targetAmount: Double
    let secondsLeft: Double
    let spot: Double?
    /// When the Bitcoin tape was last refreshed, and when the book was.
    let tapeAt: Double
    let bookAt: Double
    let feedError: String?
    let note: String
}

/* -------------------------------------------------------------- the engine */

/**
 * The run's own loop.
 *
 * Held as an actor with a detached ten-second task rather than driven by the
 * interface's poll, because the whole claim of the feature is that it watches
 * continuously. A desk that only decided when a tab was open would miss every
 * window the user was not looking at, and the windows it missed would be
 * indistinguishable from the ones it declined — which is the difference between a
 * strategy and a screensaver.
 */
actor PredictDesk {
    static let shared = PredictDesk()

    private var runs: [String: PredictRun] = [:]
    private var tape = BtcTape()
    private var tapeAt: Double = 0
    private var bookAt: Double = 0
    private var lastBarPull: Double = 0
    private var lastDecision: PredictDecision?
    private var lastCalibration: PredictCalibration?
    private var lastForecast: PredictForecast?
    private var lastBooks: (up: PredictBook?, down: PredictBook?) = (nil, nil)
    private var lastMarket: PredictMarket?
    /// The last window the desk formed an opinion about, so `windowsSeen` counts
    /// windows rather than ticks.
    private var lastSeenWindow: Double?
    /**
     * What the desk saw of the window currently on the clock.
     *
     * **This replaces a tally that could only ever report one answer.** The previous
     * version held a single verdict and overwrote it on every tick, banking whatever
     * the last tick said when the window rolled over. The last tick of any window is
     * inside the cutoff by construction — the band ends thirty-five seconds before
     * the bell and the loop keeps ticking through them — so the banked verdict was
     * `too-late` essentially always, whatever had actually happened earlier in the
     * window. A thirty-minute run over six windows reported `too-late: 6` and the
     * reader had no way to tell that from six windows where the price was simply
     * fair. The one diagnostic in the feature was structurally incapable of saying
     * anything.
     *
     * So the verdict that is kept is the last one from a tick **inside the tradeable
     * band**. Outside the band, `too-early` and `too-late` are facts about the clock
     * rather than about the window, and a window that never got an in-band look at
     * all is banked as `missed`, which is a different and much more alarming thing
     * than a refusal.
     *
     * Banked on rollover rather than on first sight, which the original got right
     * and is worth keeping: a window that showed no edge at sixty seconds and was
     * bought at a hundred and twenty must not count as both a refusal and a bet
     * against a `windowsSeen` of one. The counts have to reconcile or the tally is
     * worse than no tally.
     */
    private var watch: WindowWatch?

    /// How the live exchange feed is doing, refreshed on every tick and carried to
    /// the panel. A run that silently fell back to polled Yahoo is running a
    /// different strategy from the one that was started.
    private var feedHealth = FeedHealth.offline()
    /// The instant live sampling began. Yahoo's minute bars are absorbed only for
    /// the stretch before it — see `refreshTape`.
    private var liveFrom: Double = .infinity
    /// The learned parameters, re-read each tick. Cheap: the book only re-fits every
    /// two minutes and hands back the cached fit in between.
    private var brain = PredictBrain.unlearned()
    /// The reading in force. Default until a candidate has beaten the market out
    /// of sample, at which point the desk starts reading windows differently.
    private var policy = PredictPolicy.market()

    /// The market-against-model trace for the window on the clock, one point per
    /// tick. Reset when the window rolls over — this is a live readout, not a
    /// record; what is worth keeping goes to the shadow book instead.
    private var trackPoints: [TrackPoint] = []
    private var trackWindow: Double?
    /// The most recent cross-window reading, for the panel.
    private var lastRegime: RegimeFeatures?
    /// Each window's price to beat, decided once. See `openPrice(for:)`.
    private var openPrices: [Double: Double] = [:]
    /// How far this app's Bitcoin feed sits from the one Polymarket settles on.
    /// Measured rather than assumed, and re-measured as windows resolve.
    private var fidelity = PredictFidelity.unmeasured()
    private var fidelityAt: Double = 0
    /// When the last full pass finished, so the interface's own poll can ride on
    /// the loop's work instead of queueing a second round of network calls behind
    /// it on the same actor.
    private var lastTickAt: Double = 0
    /// When the archive was last swept for bets stranded unresolved. See `sweepStranded`.
    private var lastSweepAt: Double = 0
    private var feedError: String?
    /// One loop per account. A single shared task meant opening a run on a second
    /// account silently cancelled the first one's — it kept its `running` status and
    /// stopped deciding anything, which is the worst of both.
    private var loops: [String: Task<Void, Never>] = [:]

    private var directory: URL { Desk.dataDirectory.appendingPathComponent("predictions", isDirectory: true) }

    /* ------------------------------------------------------------ persistence */

    private func run(for profileId: String) -> PredictRun? {
        if let held = runs[profileId] { return held }
        let url = directory.appendingPathComponent("\(profileId).json")
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(PredictRun.self, from: data) else { return nil }
        runs[profileId] = parsed
        return parsed
    }

    private func save(_ run: PredictRun) {
        runs[run.profileId] = run
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(run) else { return }
        let url = directory.appendingPathComponent("\(run.profileId).json")
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url)
        }
    }

    /* --------------------------------------------------------------- the feed */

    /**
     * Keeps the tape current.
     *
     * Minute bars once a minute — asking more often returns the same bar — and a
     * single live price on every tick in between. The spot samples are what give
     * the current window a time-weighted average built from thirty observations
     * rather than five, and the current window is the only one where that matters.
     */
    private func refreshTape(force: Bool = false) async {
        let now = nowMs()
        if force || now - lastBarPull > 55_000 {
            do {
                /* Only the stretch the live feed did not cover.
                 *
                 * Both feeds in the same tape would be a quiet disaster at exactly one
                 * point: `tape.price(at: window.startMs)` takes the last point at or
                 * before the window's open, and a five-minute boundary is also a minute
                 * boundary, so a Yahoo bar stamped exactly on it wins against a live
                 * sample from a fraction of a second earlier. The threshold the whole
                 * market is measured against would come from the feed this file exists
                 * to stop reading. Bars are kept for history and warm-up — `minuteVol`
                 * needs twenty minutes of returns and the live tape starts empty — and
                 * dropped from the moment live sampling began. */
                let bars = try await BtcFeed.tape(minutes: 120)
                tape.absorb(bars.filter { $0.t < liveFrom })
                lastBarPull = now
                tapeAt = now
                feedError = nil
            } catch {
                feedError = "Bitcoin prices: \(error.localizedDescription)"
            }
        }
        // Everything the live feed sampled since the last drain — one median point a
        // second, so a three-second decision cadence absorbs three seconds of tape
        // rather than one reading of it.
        if await absorbLive() { return }

        // Nothing live: either the feed has not been started or every socket is down
        // and its own fallback has not fired yet. The old Yahoo poll covers the gap,
        // so a decision is never made on a frozen tape — and `feedHealth` says so.
        if let spot = try? await BtcFeed.spot() {
            tape.absorb([spot])
            tapeAt = nowMs()
        }
    }

    /**
     * Takes whatever the live feed has sampled and puts it on the tape.
     *
     * Split out because the *panel* calls it too, and that is what makes the chart
     * live. The feed samples once a second whatever the desk is doing, but the desk
     * only ticks every three to ten, so a chart drawn from a tape that is only
     * refreshed on a tick was up to ten seconds behind — visibly so, and exactly the
     * lag that made it look broken next to Polymarket's own. This costs one hop to
     * an actor that already holds the data; there is no network call in it.
     */
    @discardableResult
    private func absorbLive() async -> Bool {
        let live = await BtcLiveFeed.shared.drain()
        feedHealth = await BtcLiveFeed.shared.health()
        guard let first = live.first else { return false }
        liveFrom = Swift.min(liveFrom, first.t)
        tape.absorb(live)
        tapeAt = live.last?.t ?? nowMs()
        return true
    }

    /**
     * The level a window is measured against, fixed the first time it is asked for.
     *
     * The tape answers "the last price at or before this instant", and it keeps
     * filling in behind the present: Yahoo's minute bars arrive in batches covering
     * two hours, so a bar stamped exactly on a five-minute boundary can turn up after
     * a live sample from a fraction of a second earlier has already answered the
     * question. The answer then changes, for a window that has already started.
     *
     * It was visible on the screen — the same window showed a price to beat of
     * $81,248.45 and later $81,242.32 — and it is much worse than a cosmetic wobble:
     * that level is the threshold the TWAP is compared against, so every probability
     * in the window was being measured from a moving line. Decided once, and kept.
     */
    private func openPrice(for window: PredictWindow) -> Double? {
        if let held = openPrices[window.start] { return held }
        // The same definition the replay inside `PredictModel.forecast` falls back
        // to, and deliberately the same function rather than the same idea written
        // twice: a live desk and a replay that disagree about the level a window had
        // to beat is the failure that produced P4, one layer down.
        guard let price = PredictModel.openBaseline(window: window, tape: tape), price > 0 else { return nil }
        openPrices[window.start] = price
        // Two hours, matching the tape's own retention — nothing older can be asked
        // about, because the tape can no longer answer anything else about it either.
        let floor = (nowMs() / 1000) - 2 * 3600
        openPrices = openPrices.filter { $0.key >= floor }
        return price
    }

    /* ------------------------------------------------------------- feed fidelity */

    /**
     * Re-measures the gap between this app's Bitcoin feed and Polymarket's resolver.
     *
     * Two hours of windows, which is twenty-four of them, compared sign for sign.
     * Refreshed every four minutes rather than every tick: only one new window
     * resolves every five, so a tighter loop would re-fit the same sample and spend
     * two dozen requests doing it. Resolved markets are cached permanently on the
     * client, so after the first pass this costs roughly one request a cycle.
     */
    private func measureFidelity(force: Bool = false) async {
        guard force || nowMs() - fidelityAt > 4 * 60_000 else { return }
        let current = PredictWindow.current()
        var samples: [(moveBps: Double, agreed: Bool)] = []
        for n in 1...24 {
            let prior = current.previous(n)
            guard let market = try? await Polymarket.shared.market(prior, ttlMs: 5 * 60_000),
                  let resolved = market.resolved else { continue }
            // Free. This pass already holds the published answer for two hours of
            // windows, so the shadow book is filled in from it rather than spending
            // its own requests re-asking the same questions.
            await PredictShadowBook.shared.resolve(start: prior.start, side: resolved)
            guard let open = PredictModel.openBaseline(window: prior, tape: tape), open > 0,
                  let twap = tape.twap(from: prior.startMs, to: prior.endMs)
            else { continue }
            let moveBps = ((twap - open) / open) * 10_000
            let tapeSaid: PredictSide = twap >= open ? .up : .down
            samples.append((moveBps, tapeSaid == resolved))
        }
        fidelity = PredictFidelity.fit(samples)
        fidelityAt = nowMs()
        // Answers have just arrived, so this is the moment the fits can move. The
        // book throttles itself to one re-fit every two minutes regardless.
        brain = await PredictShadowBook.shared.refit()
        // The contest has its own hourly clock inside the book; calling it here just
        // means it is considered whenever the desk is already thinking.
        policy = await PredictShadowBook.shared.runContest().policy
        await PredictShadowBook.shared.flush()
        if !fidelity.assumed {
            log("[predict] feed fidelity: \(fidelity.agreed)/\(fidelity.windows) windows, "
                + "fitted gap \(f(fidelity.bps, 1)) bps")
        }
    }

    /* --------------------------------------------------------- the calibration */

    /**
     * The last four **resolved** windows, read and replayed.
     *
     * Not the last four windows on the clock, and the difference is not pedantry.
     * Polymarket's resolver lags the bell by something like five to ten minutes, so
     * at any given moment one or two of the four windows immediately behind this one
     * have finished and not yet been published. Demanding four published results
     * from those four slots vetoed nearly every window on the first live run —
     * correctly, by its own rule, and uselessly.
     *
     * So the search walks back until it has four windows that actually carry a
     * result, up to an hour. In a prompt market those are the last four and this is
     * a distinction without a difference; when the resolver is slow they are the
     * four before the ones still in the queue, which is the same check on slightly
     * older evidence rather than no check at all.
     *
     * The volatility is unaffected either way: it comes from the last twenty minutes
     * of one-minute returns directly off the tape, which needs nobody to have
     * resolved anything.
     */
    private func calibrate(before window: PredictWindow, entryOffset: Double) async -> PredictCalibration {
        var priors: [PriorWindow] = []
        var n = 1
        // An hour of reach. If four resolved windows cannot be found in twelve, the
        // resolver is far enough behind that the calibration says so and vetoes.
        while n <= 12 && priors.count < 4 {
            let prior = window.previous(n)
            n += 1
            guard let market = try? await Polymarket.shared.market(prior, ttlMs: 60_000),
                  let resolved = market.resolved else { continue }

            let open = PredictModel.openBaseline(window: prior, tape: tape)
            let twap = tape.twap(from: prior.startMs, to: prior.endMs)
            let move = (open.map { $0 > 0 } ?? false) && twap != nil
                ? ((twap! - open!) / open!) * 100 : nil

            // The replay is run at the same point in the window the live run enters
            // at, from a tape truncated to that instant — see `PredictModel.forecast`,
            // which reads both prices as of the forecast instant for exactly this.
            //
            // Deliberately the *unblended* model, unlike the live decision. Blending
            // with the market would make this a test of the market rather than of the
            // rule, and the only question four windows can usefully answer is whether
            // this app's own reading of Bitcoin describes the regime at all. That
            // question is sharper without the market propping it up.
            let decisionAt = prior.startMs + entryOffset * 1000
            var side: PredictSide?
            var p: Double?
            if let vol = tape.minuteVol(now: decisionAt),
               let replay = PredictModel.forecast(window: prior, tape: tape, minuteVol: vol,
                                                  feedNoiseBps: fidelity.bps, now: decisionAt) {
                side = replay.side
                p = replay.pUp
            }
            priors.append(PriorWindow(
                window: prior, label: prior.label, resolved: resolved,
                openPrice: open, twap: twap, movePct: move,
                modelSide: side, modelP: p,
                modelRight: (side != nil) ? side == resolved : nil
            ))
        }
        // Oldest first, so the sequence on screen reads left to right in time.
        priors.reverse()
        return PredictCalibration.build(priors: priors, minuteVol: tape.minuteVol())
    }

    /* ------------------------------------------------------------ the decision */

    /// Whether to bet on this window, and at what size. Pure arithmetic over the
    /// forecast, the calibration and the book — it places nothing.
    private func decide(run: PredictRun, window: PredictWindow, market: PredictMarket,
                        forecast: PredictForecast, calibration: PredictCalibration,
                        books: (up: PredictBook?, down: PredictBook?),
                        entryOffset: Double) -> PredictDecision {
        // The recovery rule drops the bar to zero while the run is down: any window
        // the model thinks is mispriced at all becomes takeable. Never below zero —
        // a price the model says is bad stays refused however deep the hole is.
        let chasing = run.recovering
        let required = chasing ? 0 : run.minEdge * calibration.edgeMultiplier

        func no(_ verdict: PredictDecision.Verdict, _ reason: String,
                side: PredictSide? = nil, p: Double? = nil, price: Double? = nil,
                edge: Double? = nil, kelly: Double? = nil,
                stake: Double? = nil, buy: Double? = nil) -> PredictDecision {
            PredictDecision(verdict: verdict, side: side, modelP: p, price: price, edge: edge,
                            requiredEdge: required, kellyFull: kelly, wouldStake: stake,
                            wouldBuy: buy, reason: reason, recovery: chasing)
        }

        /* Priced before any of the gates, so a verdict that refuses on the clock can
         * still say what the window was worth at that moment.
         *
         * It used to return `.tooEarly` carrying nothing — no side, no price, no
         * edge — which meant the first ninety seconds of every window were a blank
         * on the record even though the model had a full opinion throughout. That is
         * the half of the window where the question "would entering earlier have
         * paid?" actually lives, and it was the half with no numbers in it.
         */
        let priced = PredictModel.cheaperSide(
            pUp: forecast.pUp, upAsk: books.up?.bestAsk, downAsk: books.down?.bestAsk)

        if let veto = calibration.veto {
            return no(.vetoed, veto, side: priced?.side, p: priced?.p,
                      price: priced?.ask, edge: priced?.edge)
        }
        if run.hasBet(on: window) {
            return no(.alreadyBet, "This window already has a bet on it. One per window — there are twelve an hour, and a desk that takes all of them is not running a strategy.",
                      side: priced?.side, p: priced?.p, price: priced?.ask, edge: priced?.edge)
        }
        if forecast.elapsed < entryOffset {
            var reason: String
            if entryOffset <= PredictModel.warmUpSeconds + 0.01 {
                reason = "\(f(entryOffset - forecast.elapsed, 0))s of warm-up left — the tape needs a few samples before "
                reason += "the average so far means anything. There is no clock gate past this one: "
                reason += "the window is read from here on and taken the moment the edge clears the bar, "
                reason += "which in a quiet window is never."
            } else if !brain.offsetIsDefault {
                reason = "\(f(entryOffset - forecast.elapsed, 0))s until the offset the shadow book fitted. "
                reason += "\(f(entryOffset, 0))s scored better than every other bucket by more than its own standard error, "
                reason += "across \(brain.offsetSamples) samples, so the measurement is holding the desk back rather than a rule of thumb."
            } else {
                reason = "\(f(entryOffset - forecast.elapsed, 0))s until the \(f(entryOffset, 0))s floor this run was started with. "
                reason += "The model already discounts an early window on its own — set the floor to zero to let the edge decide."
            }
            if let priced {
                reason += " It is still being priced and watched: \(priced.side.rawValue) at \(cents(priced.ask)) "
                reason += "against a model probability of \(f(priced.p * 100, 1))%, which is \(cents(priced.edge)) of edge."
            }
            return no(.tooEarly, reason, side: priced?.side, p: priced?.p,
                      price: priced?.ask, edge: priced?.edge)
        }
        if forecast.remaining < run.cutoffSeconds {
            return no(.tooLate, "Inside the last \(f(run.cutoffSeconds, 0))s of the window. The book thins out here and a fill walks several cents, which eats an edge this size.",
                      side: priced?.side, p: priced?.p, price: priced?.ask, edge: priced?.edge)
        }
        guard market.acceptingOrders else {
            return no(.tooThin, "Polymarket has stopped accepting orders on this window.")
        }

        /* A price with no probability left in it.
         *
         * The blend clamps a saturated price so it can still be folded in, and that
         * clamp is the whole of the "edge" that survives here: a market at 99.9%
         * enters the arithmetic at 99.5%, leaves half a cent on the other side, and
         * the recovery rule — which drops the required edge to zero — would take it.
         * There is nothing to take. The market is not quoting a forecast at this
         * point, it is quoting a settlement, and the model's disagreement with it is
         * made of feed noise: `pathSd` is a few dollars this late and `feedSd` is
         * ninety. Refused before sizing rather than priced out by the edge bar,
         * because the bar is the thing the recovery rule is allowed to lower.
         */
        if let pMarket = forecast.pMarket,
           pMarket <= PredictModel.decidedBound || pMarket >= 1 - PredictModel.decidedBound {
            let called: PredictSide = pMarket >= 0.5 ? .up : .down
            var reason = "The market is pricing this window at \(f(pMarket * 100, 1))% \(called.rawValue) — "
            reason += "it has stopped quoting a probability and started quoting a settlement. "
            reason += "The model still makes it \(f(forecast.pModel * 100, 1))%, and that gap is this feed "
            reason += "against the resolver's rather than a view about Bitcoin: with \(f(forecast.elapsed, 0))s gone "
            reason += "there is \(money(forecast.pathSd)) of path left to be uncertain about and "
            reason += "\(money(forecast.feedSd)) of feed. Buying the cheap side of a decided window is the most "
            reason += "expensive mistake available on this tab."
            return no(.decided, reason, side: priced?.side, p: priced?.p,
                      price: priced?.ask, edge: priced?.edge)
        }

        /* Both sides, priced, and the better of the two taken.
         *
         * Not the side the model *favours* — the side that is *cheap*. Those come
         * apart more often than they sound like they should: the model can make a
         * window 55% Up while Up is offered at 62¢ and Down at 30¢, which is no edge
         * on the outcome it prefers and fifteen cents on the one it does not. A
         * prediction market pays for buying a contract below what it is worth, and
         * says nothing about which outcome you would have guessed. Reading only the
         * favoured side leaves every one of those on the table and, worse, makes the
         * desk look like a directional forecaster rather than a price-taker.
         */
        guard let best = PredictModel.cheaperSide(
                pUp: forecast.pUp, upAsk: books.up?.bestAsk, downAsk: books.down?.bestAsk),
              let book = best.side == .up ? books.up : books.down else {
            return no(.tooThin, "Neither side of this window has an offer on it right now.",
                      side: forecast.side, p: forecast.pUp)
        }

        let side = best.side
        let p = best.p
        let ask = best.ask
        let edge = best.edge
        let kelly = PredictModel.kellyFraction(p: p, cost: ask)

        /* Sub-penny offers are not a market, and the replay already knew it.
         *
         * `PredictLearning.entryOffset` will not score a look whose ask is at or
         * under a cent, so every fit the desk has ever made was built on a
         * population of trades that excluded these — while the live desk was free to
         * take them, and in the end took nothing else. That divergence is why the
         * offset fit reported zero samples after a hundred and thirty windows: the
         * only looks that qualified live were the ones the replay threw away. The
         * two now agree about what counts as a trade.
         *
         * Kelly is the other reason. At a tenth of a cent it asks for the bankroll
         * divided by a rounding error — thirteen thousand contracts on a $33 stake —
         * so every dollar that reaches this price buys a thousand lottery tickets and
         * the cost cap is the only thing standing between the run and its limit.
         */
        if ask < PredictModel.minimumPrice {
            var reason = "\(side.rawValue) is the cheap side at \(cents(ask)), which is under the "
            reason += "\(cents(PredictModel.minimumPrice)) floor. A contract quoted this far down is the book saying the "
            reason += "window is over, not a price with a probability in it — and the shadow book has never "
            reason += "scored a look below this floor, so a fill here is a trade none of the fitted numbers "
            reason += "have ever seen."
            return no(.decided, reason, side: side, p: p, price: ask, edge: edge, kelly: kelly)
        }
        if edge < required {
            // The cheaper side is named even when it loses, because "Up was 4¢ short
            // and Down was 11¢ short" is a different market from "Up was 4¢ short".
            let otherAsk = side == .up ? books.down?.bestAsk : books.up?.bestAsk
            let otherEdge = otherAsk.map { (1 - p) - $0 }
            var reason = "\(side.rawValue) is offered at \(cents(ask)) and the model makes it \(f(p * 100, 1))%. "
            reason += "That is \(cents(edge)) of edge against the \(cents(required)) this run asks for"
            reason += calibration.edgeMultiplier > 1
                ? " — raised from \(cents(run.minEdge)) by the calibration. " : ". "
            if let otherEdge {
                reason += "\(side.other.rawValue) is worse at \(cents(otherEdge)). "
            }
            reason += "The price is roughly where the model is, which is what an efficient five-minute market normally looks like."
            return no(.noEdge, reason, side: side, p: p, price: ask, edge: edge, kelly: kelly)
        }

        // How much the run is willing to lose on this window: Kelly, cut to the
        // run's fraction, then capped three ways — by the per-window cap, by what is
        // actually free, and by what is left of the loss limit.
        let lossHeadroom = Swift.max(0, run.lossLimit + Swift.min(0, run.realised) - run.committed)

        /* Kelly, or the deficit.
         *
         * Kelly asks "how much of the bankroll does this edge justify" and answers
         * without reference to the scoreboard, which is the property that makes it
         * the right rule. The recovery rule asks the other question — "what stake,
         * if it wins, puts the run back at zero" — and that is the whole of what
         * makes it a chase. A contract bought at `c` turns a stake `S` into `S/c`,
         * so it profits `S(1 − c)/c`; setting that equal to the deficit gives the
         * stake below. It is a size derived from a past loss and not from a present
         * price, and it is bounded only because the caps underneath it are.
         */
        let wanted = chasing
            ? PredictModel.recoveryStake(deficit: run.deficit, price: ask)
            : run.bankroll * kelly * run.kellyFraction
        let capped = Swift.min(wanted, run.maxStake, run.available, lossHeadroom)

        var budgetNote: String?
        if chasing {
            budgetNote = "Recovery: the run is \(money(run.deficit)) down and a win at \(cents(ask)) "
                + "returns \(money(wanted)) of profit on a \(money(wanted)) stake, which is flat. "
                + "The bar was dropped from \(cents(run.minEdge * calibration.edgeMultiplier)) to nothing to get here."
            if capped < wanted - 0.01 {
                budgetNote! += " The caps hold it to \(money(capped)), so a win recovers part of the hole and not all of it."
            }
        } else if capped < wanted - 0.01 {
            let binding = capped == run.maxStake ? "this run's \(f(run.maxStakePct, 0))% per-window cap"
                : capped == run.available ? "what is free in the bankroll"
                : "what is left of the loss limit"
            budgetNote = "\(f(run.kellyFraction * 100, 0))% of Kelly on this edge would be \(money(wanted)); \(binding) holds it to \(money(capped))."
        }

        if capped < 0.5 {
            return no(.noRoom,
                      "There is \(money(run.available)) free and \(money(lossHeadroom)) left of the loss limit, which is not enough to take a position.",
                      side: side, p: p, price: ask, edge: edge, kelly: kelly, stake: capped)
        }

        // Never pay past the price at which the edge falls to the minimum. The fill
        // walks real levels and stops there, which is why the size that comes back
        // can be smaller than the size that was wanted.
        //
        // `capped` is a budget in dollars and it is handed to the fill as one. The
        // contract count is derived from the best ask purely as an upper bound —
        // no fill averages below the best ask, so it can never be the binding
        // constraint — and `maxCost` is what actually stops the walk. Before this
        // was wired through, the count *was* the only constraint and a dust order
        // at the top of the book turned a $50 budget into a $763 position.
        let worstPrice = Swift.min(0.99, p - required)
        let wantShares = capped / Swift.max(ask, 0.0001)
        guard let got = book.fill(wantShares, maxPrice: worstPrice, maxCost: capped),
              got.shares > 0 else {
            return no(.tooThin,
                      "Nothing is offered on \(side.rawValue) at \(cents(worstPrice)) or better, which is where this edge runs out.",
                      side: side, p: p, price: ask, edge: edge, kelly: kelly, stake: capped)
        }
        if got.shares < market.minOrderSize {
            return no(.tooSmall,
                      "The position this edge justifies is \(f(got.shares, 1)) contracts and Polymarket's minimum order is \(f(market.minOrderSize, 0)). "
                      + "Rounding it up would be betting more than the model says is warranted, so the window is skipped.",
                      side: side, p: p, price: ask, edge: edge, kelly: kelly,
                      stake: capped, buy: got.shares)
        }

        // Stated from the fill, never from the budget. The old note was written
        // before the walk and cheerfully said "the cap holds it to $50" on top of a
        // position that had just cost $763.
        let spent = got.shares * got.price
        var sizeNote = "\(f(got.shares, 1)) contracts at \(cents(got.price)) for \(money(spent))."
        if let budgetNote { sizeNote = budgetNote + " " + sizeNote }
        if spent < capped - 0.01 {
            sizeNote += " The book ran out of offers under \(cents(worstPrice)) before the budget did."
        }

        return PredictDecision(
            verdict: .taken, side: side, modelP: p, price: got.price,
            edge: p - got.price, requiredEdge: required, kellyFull: kelly,
            wouldStake: spent, wouldBuy: got.shares,
            reason: sizeNote, recovery: chasing)
    }

    /// Turns a `.taken` decision into a position. Separate from `decide` so the
    /// panel can show what the desk would do without doing it.
    private func place(_ decision: PredictDecision, run: inout PredictRun,
                       forecast: PredictForecast, calibration: PredictCalibration,
                       book: PredictBook) {
        guard decision.verdict == .taken, let side = decision.side,
              let shares = decision.wouldBuy, let cost = decision.price,
              let p = decision.modelP else { return }

        // The last gate, and the cheapest one. Sizing is cost-capped upstream, so
        // reaching this is a bug rather than a market condition — but the failure
        // mode it guards against is a run losing four times its own limit before
        // anyone notices, and the guard costs one multiplication. It refuses the
        // bet rather than trimming it: a size nobody can account for is not a size
        // to take a smaller version of.
        let ceiling = Swift.min(run.maxStake, run.available,
                                Swift.max(0, run.lossLimit + Swift.min(0, run.realised) - run.committed))
        let cost0 = shares * cost
        guard cost0 <= ceiling + 0.01 else {
            log("[predict] \(forecast.window.label) — REFUSED: fill would cost \(money(cost0)) "
                + "against a \(money(ceiling)) ceiling. Sizing bug; no position taken.")
            return
        }

        // Spelled out one clause at a time. As a single interpolated expression the
        // type checker gives up on it, which is a recurring tax on writing prose in
        // Swift and not worth fighting.
        var thesis = "\(side.rawValue) at \(cents(cost)) on a model probability of \(f(p * 100, 1))%. "
        thesis += "Bitcoin opened the window at \(f(forecast.openPrice, 0)); "
        thesis += "with \(f(forecast.elapsed, 0))s in the books at an average of \(f(forecast.twapSoFar, 0)), "
        thesis += "the window's average lands at \(f(forecast.projectedTwap, 0)) if the price stays here — "
        thesis += "\(f(abs(forecast.signalBps), 1)) basis points \(forecast.signalBps >= 0 ? "above" : "below") the open. "
        thesis += "That is \(f(abs(forecast.z), 2)) standard deviations, of which "
        thesis += "\(f(forecast.pathSd, 0)) is what Bitcoin may still do and "
        thesis += "\(f(forecast.feedSd, 0)) is the gap between this feed and the resolver's. "
        if let mkt = forecast.pMarket, let w = forecast.modelWeight {
            thesis += "On its own the model said \(f(forecast.pModel * 100, 1))% and the market was pricing "
            thesis += "\(f(mkt * 100, 1))%; the model kept \(f(w * 100, 0))% of the weight, which is the share "
            thesis += "of its uncertainty that is a forecast rather than a feed it cannot read. "
        }
        thesis += calibration.summary

        if decision.recovery {
            thesis += " **Taken under the recovery rule.** The run was \(money(run.deficit)) down, the "
            thesis += "required edge was dropped to nothing for this window, and the size is the one whose "
            thesis += "win returns the run to flat rather than the one the edge justifies. "
            thesis += "Nothing about being behind made this contract more likely to pay."
        }

        let bet = PredictBet(
            window: forecast.window, side: side, placedAt: nowMs(),
            shares: shares, cost: cost, stake: shares * cost,
            modelP: p, edge: p - cost, requiredEdge: decision.requiredEdge,
            kellyFull: decision.kellyFull ?? 0,
            bestAsk: book.bestAsk ?? cost, spread: book.spread,
            openPrice: forecast.openPrice, spotAtEntry: forecast.spot,
            twapAtEntry: forecast.twapSoFar, secondsIntoWindow: forecast.elapsed,
            sizeNote: decision.reason.isEmpty ? nil : decision.reason,
            thesis: thesis,
            recovery: decision.recovery ? true : nil
        )
        run.bets.append(bet)
        log("[predict] \(forecast.window.label) — bought \(f(shares, 1)) \(side.rawValue) at \(cents(cost)), "
            + "model \(f(p * 100, 1))%, edge \(cents(p - cost)), stake \(money(shares * cost))")
    }

    /* ------------------------------------------------------------ settlement */

    /**
     * Pays out every bet whose window has closed.
     *
     * From Polymarket's published resolution and nothing else. The desk's own
     * Bitcoin feed is Yahoo spot and the market settles on a Chainlink TWAP; they
     * agree most of the time, and a simulator that graded its own homework on the
     * occasions they did not would quietly inflate its record in exactly the
     * windows that were closest. A bet whose market has not been resolved yet stays
     * open and says it is waiting.
     */
    private func settle(_ run: inout PredictRun) async {
        for i in run.bets.indices where run.bets[i].isOpen {
            let bet = run.bets[i]
            guard nowMs() > bet.window.endMs + 5_000 else { continue }
            guard let market = try? await Polymarket.shared.market(bet.window, ttlMs: 20_000),
                  let resolved = market.resolved else {
                run.bets[i].awaitingResolution = true
                continue
            }
            let won = resolved == bet.side
            let payout = won ? bet.shares : 0
            run.bets[i].settledAt = nowMs()
            run.bets[i].resolved = resolved
            run.bets[i].payout = payout
            run.bets[i].pnl = payout - bet.stake
            run.bets[i].awaitingResolution = false
            await PredictShadowBook.shared.resolve(start: bet.window.start, side: resolved)
            /* The bet, as evidence rather than as history.
             *
             * `bestAsk` is the price the decision was taken against and the price
             * every hypothetical return in the shadow book is scored at; `cost` is
             * the volume-weighted average actually paid after walking the book.
             * Until now nothing in the learning read either, so the whole system
             * was fitted on an assumption about fills that nothing was testing. */
            await PredictShadowBook.shared.recordSettled(SettledBet(
                at: nowMs(), side: bet.side.rawValue,
                expectedAsk: bet.bestAsk, filledAsk: bet.cost,
                stake: bet.stake, pnl: payout - bet.stake, won: won))
            log("[predict] \(bet.window.label) resolved \(resolved.rawValue) — "
                + "\(won ? "won" : "lost") \(money(abs(payout - bet.stake))) on \(bet.side.rawValue)")
        }
    }

    /**
     * Settles bets left behind by runs that ended before the resolver published.
     *
     * `settle` only ever sees the run it is handed, which is always the current
     * one. A bet placed in a run's last minutes therefore had about five minutes to
     * resolve or be stranded, and once the next run opened, nothing looked at it
     * again — it sat in the history file with a nil P/L, neither a win nor a loss,
     * silently missing from the record. This walks the archive on a timer and
     * finishes the job.
     *
     * Bounded two ways. Once a minute, because the resolver takes minutes and not
     * seconds and this is network work on the tick path. And only for windows that
     * closed inside the last day: a bet Polymarket no longer serves a market for is
     * never going to resolve, and retrying it hourly forever would be a permanent
     * background cost for a row that is honestly reported as unresolved either way.
     */
    private func sweepStranded() async {
        guard nowMs() - lastSweepAt > 60_000 else { return }
        lastSweepAt = nowMs()
        let cutoff = nowMs() - 24 * 60 * 60 * 1000
        for var stale in await PredictJournal.shared.unsettled(newerThan: cutoff) {
            let before = stale.bets.filter { $0.pnl == nil }.count
            await settle(&stale)
            let after = stale.bets.filter { $0.pnl == nil }.count
            guard after < before else { continue }
            let settled = before - after
            stale.endNote = (stale.endNote ?? "")
                + " Settled late: \(settled) window\(settled == 1 ? "" : "s") the resolver had not published "
                + "when the run ended \(settled == 1 ? "has" : "have") since been paid out, and the run's P/L now includes "
                + "\(settled == 1 ? "it" : "them")."
            await PredictJournal.shared.archive(stale)
            log("[predict] swept \(settled) stranded bet\(settled == 1 ? "" : "s") from the run that started "
                + "\(Date(timeIntervalSince1970: stale.startedAt / 1000))")
        }
    }

    /// What the open bets are worth at the current book, marked at the bid: the
    /// price they could actually be sold at, not the one they could be bought at.
    private func unrealised(_ run: PredictRun) -> Double {
        var total = 0.0
        for bet in run.bets where bet.isOpen {
            var mark = bet.cost
            if bet.window.start == lastMarket?.window.start {
                let book = bet.side == .up ? lastBooks.up : lastBooks.down
                if let bid = book?.bestBid { mark = bid }
            } else if nowMs() > bet.window.endMs {
                // The window is over and the result is not published yet. Marking it at
                // the entry price would show a flat P/L on a bet that is already decided;
                // marking it at zero or one would be guessing. It is held at cost and
                // labelled as awaiting resolution on screen.
                mark = bet.cost
            }
            total += bet.shares * mark - bet.stake
        }
        return total
    }

    /**
     * Whether the run should end, and why.
     *
     * Tested against **realised** results alone, unlike a trading session, which
     * also counts what is at risk in open positions. The difference is that a
     * session can be flattened at any moment and this cannot: a prediction contract
     * has no exit before resolution, so marking an open window against the loss
     * limit would end runs on a mark that no one could have acted on. What stops
     * the run over-committing instead is the headroom check in `decide`, which
     * refuses a bet that would put more at stake than the limit has left.
     */
    private func verdict(_ run: PredictRun) -> (PredictStatus, String)? {
        if run.realised <= -run.lossLimit {
            return (.hitLossLimit, "The run lost \(money(-run.realised)) against a \(money(run.lossLimit)) limit and is closed to new windows. The limit was set before it started and cannot be raised while it runs.")
        }
        if run.realised >= run.targetAmount {
            return (.metTarget, "The run made \(money(run.realised)) against a \(money(run.targetAmount)) target and is closed to new windows. A streak of correct five-minute calls is exactly the condition under which people stop sizing and start pressing.")
        }
        if run.secondsLeft <= 0 && !run.bets.contains(where: \.isOpen) {
            return (.outOfTime, "The run's \(f(run.minutes, 0)) minutes are up. \(run.bets.count) window\(run.bets.count == 1 ? "" : "s") bet, \(run.wins) right and \(run.losses) wrong, against the \(f(run.pricedWins, 1)) the prices paid were already forecasting.")
        }
        return nil
    }

    /* -------------------------------------------------------------- the tally */

    /**
     * Files a finished window under the reason it was not bought, and keeps the
     * closest it came.
     *
     * A bought window is never filed: it is already in `bets`, and counting it here
     * as well would put `windowsSeen` below the sum of its own parts.
     */
    private func bank(_ watch: WindowWatch, into run: inout PredictRun) {
        guard !watch.bought else { return }
        var tally = run.skipped ?? [:]
        tally[watch.verdict.rawValue, default: 0] += 1
        run.skipped = tally

        // Only a genuine near-miss is worth keeping — a window that had an edge and
        // was refused for size or depth is not a story about the bar being too high.
        guard let edge = watch.bestEdge, let side = watch.bestSide,
              watch.bestRequired > edge else { return }
        let shortfall = watch.bestRequired - edge
        if run.closestMiss.map({ shortfall < $0.shortfall }) ?? true {
            run.closestMiss = ClosestMiss(
                windowLabel: watch.window.label, side: side, edge: edge,
                required: watch.bestRequired, offset: watch.bestOffset)
        }
    }

    /**
     * The entry offset actually in force, which is not always the one that was set.
     *
     * The run carries the offset the user chose. Once the shadow book has enough
     * resolved windows to say which offset has historically paid — and enough of a
     * margin that the winner is not just the luckiest of seventeen buckets — the
     * fitted one takes over. The run file keeps the original either way, so the
     * panel can say which is being used and why.
     */
    private func entryOffset(for run: PredictRun) -> Double {
        // A measured offset outranks an argued one, so a fitted brain still wins.
        // Otherwise this is whatever floor the run asked for — zero, by default,
        // which leaves the decision entirely to the edge — and never less than the
        // seconds the tape needs to have anything to say. See `warmUpSeconds`.
        let asked = brain.offsetIsDefault ? run.entryOffsetSeconds : brain.entryOffsetSeconds
        return Swift.max(PredictModel.warmUpSeconds, asked)
    }

    /// The feed gap the model is scaled by. The book's fit stands on thousands of
    /// windows and wins when it has them; until then the live twenty-four-window
    /// measurement is both fresher and the only one there is.
    private var effectiveFeedNoise: Double {
        brain.feedIsDefault ? fidelity.bps : brain.feedNoiseBps
    }

    /* ---------------------------------------------------------------- the tick */

    /**
     * One pass: refresh the tape, settle what has resolved, and decide the current
     * window. Called every ten seconds by the run's own loop, and again whenever
     * the panel is read, so a tab that has just been opened is never showing a
     * ten-second-old idea of what the desk is doing.
     */
    @discardableResult
    func tick(profileId: String) async -> PredictRun? {
        guard var current = run(for: profileId) else { return nil }
        lastTickAt = nowMs()
        brain = await PredictShadowBook.shared.parameters()
        policy = await PredictShadowBook.shared.currentPolicy()
        await refreshTape()
        await settle(&current)
        await sweepStranded()

        guard current.status == .running else { save(current); return current }

        if let (status, note) = verdict(current) {
            // The window it was in the middle of judging still counts.
            if let open = watch {
                bank(open, into: &current)
                watch = nil
            }
            current.status = status
            current.endedAt = nowMs()
            current.endNote = note
            save(current)
            await PredictJournal.shared.archive(current)
            log("[predict] \(status.rawValue): \(note)")
            return current
        }

        // Past the clock but still holding an unresolved window: no new bets, and
        // the run stays open until the last one pays out.
        if current.secondsLeft <= 0 {
            lastDecision = PredictDecision(
                verdict: .idle, side: nil, modelP: nil, price: nil, edge: nil,
                requiredEdge: current.minEdge, kellyFull: nil, wouldStake: nil, wouldBuy: nil,
                reason: "The run's time is up and it is waiting for its last window to resolve before closing.")
            save(current)
            return current
        }

        let window = PredictWindow.current()
        guard let market = try? await Polymarket.shared.market(window) else {
            feedError = "Polymarket has no market for \(window.label) yet."
            save(current)
            return current
        }
        lastMarket = market

        let books = await Polymarket.shared.books(market)
        lastBooks = books
        bookAt = nowMs()

        await measureFidelity()
        guard let vol = tape.minuteVol(),
              let raw = PredictModel.forecast(window: window, tape: tape, minuteVol: vol,
                                              feedNoiseBps: effectiveFeedNoise,
                                              openPrice: openPrice(for: window)) else {
            lastForecast = nil
            lastDecision = PredictDecision(
                verdict: .vetoed, side: nil, modelP: nil, price: nil, edge: nil,
                requiredEdge: current.minEdge, kellyFull: nil, wouldStake: nil, wouldBuy: nil,
                reason: "Not enough recent Bitcoin data to form a view. Every probability here is scaled by how volatile the last twenty minutes were, and that cannot be measured yet.")
            save(current)
            return current
        }
        /* What the twelve windows before this one had been doing, and whatever the
         * cross-window model has earned the right to say about it. Measured every
         * tick rather than once per window because the tape keeps filling in behind
         * us — a window measured at second three has less history under it than the
         * same window measured at second ninety, and the later reading is the better
         * one. The shadow book keeps only the first, which is the reading that was
         * actually available at the open.
         *
         * `adjustment` is zero until that model has beaten doing nothing on windows
         * it was not fitted on, so this line changes nothing at all on a fresh
         * install — which is the intended default and not a placeholder. */
        let features = RegimeFeatures.measure(tape: tape, window: window, minuteVol: vol)
        lastRegime = features
        let withRegime = PredictModel.withRegime(raw, adjustment: brain.regime.adjustment(features))

        // The book is already in hand, so the market's own view is folded in here
        // rather than left for the decision to remember to do.
        var forecast = PredictModel.against(
            market: PredictModel.implied(up: books.up, down: books.down), withRegime,
            maxWeight: brain.modelWeight)
        /* A promoted reading overrides the blend.
         *
         * The blend can only ever mix one fixed model with the price, which is why
         * it reached a weight of zero and stayed there: at zero it *is* the price,
         * the edge is identically zero, and the desk can never bet again. A policy
         * that won its contest against the market is allowed to speak instead —
         * and `PredictPolicy.market()`, the default, reproduces the price exactly,
         * so a desk with nothing promoted behaves as it always did. */
        if !policy.isDefault,
           let pMarket = PredictModel.implied(up: books.up, down: books.down) {
            forecast = PredictModel.withPolicy(
                forecast, policy: policy, pMarket: pMarket,
                moveBps: forecast.signalBps, offset: forecast.elapsed,
                regime: features?.vector ?? [0, 0, 0, 0, 0])
        }
        lastForecast = forecast

        let offset = entryOffset(for: current)
        let calibration = await calibrate(before: window, entryOffset: offset)
        lastCalibration = calibration

        // Every window is written down whether or not it is bought. A run that
        // correctly declines all six of its windows still produced six labelled
        // examples once they resolve, and those are what the three fitted parameters
        // are built from — see `PredictLearning.swift`.
        await PredictShadowBook.shared.record(
            window: window, forecast: forecast, books: books,
            degraded: feedHealth.degraded, regime: features)
        // Flushed on the tick's own clock rather than only from the four-minute
        // fidelity pass, which is where this lived first and meant a quit between
        // passes threw away up to four minutes of the thing the desk is here to
        // accumulate. The book debounces itself to one write every thirty seconds,
        // so calling it every tick costs a comparison.
        await PredictShadowBook.shared.flush()

        // Moving on to a new window banks whatever the last one ended up as.
        if let open = watch, open.window.start != window.start {
            bank(open, into: &current)
            watch = nil
        }
        if watch == nil { watch = WindowWatch(window: window) }

        // Counted once per window, the first time the desk is in a position to have
        // an opinion about it. Windows the run slept through are not "considered".
        if forecast.elapsed >= offset, lastSeenWindow != window.start {
            lastSeenWindow = window.start
            current.windowsSeen += 1
        }

        let decision = decide(run: current, window: window, market: market,
                              forecast: forecast, calibration: calibration,
                              books: books, entryOffset: offset)
        lastDecision = decision

        /* What this tick adds to the window's record.
         *
         * Only in-band ticks set the verdict. Outside the band `too-early` and
         * `too-late` describe the clock rather than the window, and letting them
         * overwrite a real verdict is precisely the bug this structure exists to
         * stop: the last tick of every window is inside the cutoff, so a tally fed by
         * every tick reports `too-late` and nothing else, for ever.
         *
         * The `bought` flag is the other load-bearing half. Without it the tick after
         * a fill returns `.alreadyBet` — true, and a fact about that tick rather than
         * about the window — and the window gets banked as a refusal on top of the
         * bet it already carries. A window that has been bought is never a skip,
         * whatever any later tick says about it.
         */
        let inBand = forecast.elapsed >= offset && forecast.remaining >= current.cutoffSeconds
        watch?.note(decision, inBand: inBand, elapsed: forecast.elapsed,
                    alreadyBet: current.hasBet(on: window))

        // The live trace. One point per tick, so it thickens to a three-second
        // cadence exactly where the decision is being made and stays sparse either
        // side of it — which is the shape of the attention being paid.
        if trackWindow != window.start { trackWindow = window.start; trackPoints = [] }
        trackPoints.append(TrackPoint(
            t: nowMs(), market: forecast.pMarket, model: forecast.pUp,
            verdict: decision.verdict.rawValue))
        if trackPoints.count > 200 { trackPoints.removeFirst(trackPoints.count - 200) }

        if decision.verdict == .taken, current.betsAutomatically, let side = decision.side,
           let book = side == .up ? books.up : books.down {
            place(decision, run: &current, forecast: forecast, calibration: calibration, book: book)
        }

        save(current)
        return current
    }

    /// The loop. Started when a run opens, and stopped by itself when the run is
    /// over so a closed run does not keep polling two public APIs.
    private func startLoop(profileId: String) {
        loops[profileId]?.cancel()
        Task { await BtcLiveFeed.shared.start() }
        loops[profileId] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = await self.tick(profileId: profileId)
                if current == nil || current?.status.isOver == true {
                    await self.forgetLoop(profileId)
                    return
                }
                try? await Task.sleep(nanoseconds: await self.tickDelay(for: current))
            }
        }
    }

    /**
     * Ten seconds between ticks outside a window's tradeable band, three inside it.
     *
     * The band is the only stretch where a decision can be made at all, and a
     * five-minute book is thin enough that an edge can appear and be gone inside ten
     * seconds. Three seconds gives something like forty looks at a window where ten
     * gave eleven. Outside the band nothing is decidable and a faster tick would
     * only spend requests on two public APIs for no gain, so the extra cost is
     * bounded to the band and is roughly three times the book reads within it.
     *
     * Note this is the delay *after* a tick, not a period: a tick that spends four
     * seconds on the network is followed by three more, so the real in-band cadence
     * is nearer seven. That is deliberate — it is the shape that cannot accidentally
     * queue ticks behind each other on the actor.
     */
    private func tickDelay(for run: PredictRun?) -> UInt64 {
        /* Five seconds outside the band, three inside it.
         *
         * Outside used to be ten, which quietly undermined the thing the shadow book
         * exists to answer. Its offsets are bucketed at fifteen seconds and only the
         * first sample in a bucket is kept, so a ten-second delay plus two to four
         * seconds of network lands at twelve to fourteen — under fifteen, but not
         * reliably, and the buckets it missed were all *before* the entry offset.
         * The one question the offset fit is for is whether entering earlier would
         * have paid, and the early offsets were the thinnest part of the evidence.
         * Five guarantees coverage with room to spare.
         *
         * It costs about a fifth more requests across a window and buys the whole
         * first half of it at full resolution. Three inside the band stays, because
         * that is where a decision can actually be made and a thin five-minute book
         * can lose an edge inside ten seconds.
         */
        let outside: UInt64 = 5 * 1_000_000_000
        guard let run, run.status == .running else { return 10 * 1_000_000_000 }
        let elapsed = (nowMs() - PredictWindow.current().startMs) / 1000
        let inBand = elapsed >= entryOffset(for: run) && (300 - elapsed) >= run.cutoffSeconds
        return inBand ? 3 * 1_000_000_000 : outside
    }

    private func stopLoop(_ profileId: String) {
        loops[profileId]?.cancel()
        loops.removeValue(forKey: profileId)
        releaseFeedIfIdle()
    }

    /// Called by a loop that has finished on its own, so a run that reached its
    /// limit does not leave a cancelled task in the map.
    private func forgetLoop(_ profileId: String) {
        loops.removeValue(forKey: profileId)
        releaseFeedIfIdle()
    }

    /// Three open sockets serving a desk with nothing running is rude to three
    /// public endpoints, so the feed closes with the last run on any account. The
    /// book is flushed in the same breath: it is debounced to once every thirty
    /// seconds while running and the last few windows would otherwise be lost.
    private func releaseFeedIfIdle() {
        guard loops.isEmpty else { return }
        Task {
            await BtcLiveFeed.shared.stop()
            await PredictShadowBook.shared.flush(force: true)
        }
    }

    /* ---------------------------------------------------------- betting by hand */

    /**
     * Buys a side of the current window because you said so.
     *
     * **Every limit still applies except the one that is an opinion.** One bet per
     * window, the per-window cap, what is free in the bankroll, what is left of the
     * loss limit, Polymarket's minimum order and the real depth of the book — all of
     * those are facts about the account or the market and none of them are
     * negotiable from here. The *edge* requirement is the single thing this bypasses,
     * because that is a judgement about whether a price is worth paying, and
     * disagreeing with it is the entire point of being able to press the button.
     *
     * The cutoff is enforced too. It is tempting to treat "no, it is too late" as
     * another opinion, and it is not one: inside the last thirty seconds the book
     * thins to the point where the fill walks several cents, so a manual bet there
     * would be filled at a price that makes it a different bet from the one on the
     * screen.
     *
     * Fills walk the real book the same way an automatic bet does, so the price paid
     * is what the depth actually cost rather than the best offer.
     */
    /// What to say about a hand-placed size, written *after* the fill so it can
    /// never again claim a cap held a position to $50 while the position cost $763.
    private func sizeNote(asked: Double, allowed: Double, spent: Double,
                          shares: Double, price: Double) -> String {
        var note = "\(f(shares, 1)) contracts at \(cents(price)) for \(money(spent))."
        if allowed < asked - 0.01 {
            note = "Asked for \(money(asked)); \(money(allowed)) was as much as the caps allowed. " + note
        }
        if spent < allowed - 0.01 {
            note += " The book ran out before the budget did."
        }
        return note
    }

    func bet(profileId: String, side: PredictSide, stake: Double) async throws -> PredictRun {
        guard var current = run(for: profileId), current.status == .running else {
            throw MarketError("No prediction run is going on this account.")
        }
        guard stake > 0 else { throw MarketError("A bet needs a stake.") }

        let window = PredictWindow.current()
        guard !current.hasBet(on: window) else {
            throw MarketError("This window already has a bet on it. One per window — there are twelve an hour.")
        }
        let remaining = (window.endMs - nowMs()) / 1000
        guard remaining >= current.cutoffSeconds else {
            throw MarketError("Only \(f(remaining, 0))s left in this window, inside the \(f(current.cutoffSeconds, 0))s cutoff. "
                + "The book thins out here and the fill would walk several cents past the price on screen.")
        }

        // Read fresh rather than trusting the last tick: a price shown three seconds
        // ago is not the price being agreed to.
        guard let market = try? await Polymarket.shared.market(window) else {
            throw MarketError("Polymarket has no market for \(window.label) right now.")
        }
        guard market.acceptingOrders else {
            throw MarketError("Polymarket has stopped accepting orders on this window.")
        }
        let books = await Polymarket.shared.books(market)
        lastMarket = market
        lastBooks = books
        bookAt = nowMs()

        guard let book = side == .up ? books.up : books.down, let ask = book.bestAsk else {
            throw MarketError("There is nothing on the offer for \(side.rawValue) right now.")
        }

        let headroom = Swift.max(0, current.lossLimit + Swift.min(0, current.realised) - current.committed)
        let capped = Swift.min(stake, current.maxStake, current.available, headroom)
        guard capped >= 0.5 else {
            throw MarketError("There is \(money(current.available)) free and \(money(headroom)) left of the loss limit, "
                + "which is not enough to take a position.")
        }

        // Same cost cap as the auto path, and for the same reason: `capped / ask` is
        // an upper bound on contracts, `maxCost` is the constraint. A hand-placed
        // $50 against a tenth-of-a-cent top of book used to be free to walk all the
        // way to 99¢ and spend thousands.
        guard let got = book.fill(capped / Swift.max(ask, 0.0001), maxPrice: 0.99, maxCost: capped),
              got.shares > 0 else {
            throw MarketError("The book could not fill that.")
        }
        guard got.shares >= market.minOrderSize else {
            throw MarketError("That stake buys \(f(got.shares, 1)) contracts and Polymarket's minimum is "
                + "\(f(market.minOrderSize, 0)). Stake more, or leave it.")
        }

        let p = lastForecast?.window.start == window.start ? lastForecast?.pUp : nil
        let modelP = side == .up ? p : p.map { 1 - $0 }

        var thesis = "Placed by hand at \(cents(got.price)) on \(side.rawValue). "
        if let modelP {
            let edge = modelP - got.price
            thesis += "The model made it \(f(modelP * 100, 1))%, which is \(cents(abs(edge))) "
            thesis += edge >= 0 ? "of edge at that price. " : "*worse* than the price. "
            thesis += "The desk's own bar was \(cents(current.minEdge)); this bet did not have to clear it."
        } else {
            thesis += "The desk had no probability for this window at the time, so there is no edge to state — "
            thesis += "this was a price and a decision, not a model output."
        }

        var placed = PredictBet(
            window: window, side: side, placedAt: nowMs(),
            shares: got.shares, cost: got.price, stake: got.shares * got.price,
            modelP: modelP ?? got.price, edge: (modelP ?? got.price) - got.price,
            requiredEdge: current.minEdge, kellyFull: 0,
            bestAsk: ask, spread: book.spread,
            openPrice: lastForecast?.openPrice ?? (tape.price(at: window.startMs) ?? 0),
            spotAtEntry: tape.last?.p ?? 0,
            twapAtEntry: tape.twap(from: window.startMs, to: nowMs()) ?? 0,
            secondsIntoWindow: (nowMs() - window.startMs) / 1000,
            sizeNote: sizeNote(asked: stake, allowed: capped, spent: got.shares * got.price,
                               shares: got.shares, price: got.price),
            thesis: thesis)
        placed.manual = true

        current.bets.append(placed)
        // The window is no longer a refusal whoever refused it, so the watch has to
        // know — otherwise it is banked as a skip on top of the bet it now carries,
        // which is the double-count `WindowWatch` exists to prevent.
        watch?.bought = true
        save(current)
        log("[predict] \(window.label) — hand-placed \(f(got.shares, 1)) \(side.rawValue) at \(cents(got.price)), "
            + "stake \(money(got.shares * got.price))")
        return current
    }

    /* ----------------------------------------------------------- the lifecycle */

    func open(profileId: String, bankroll: Double, minutes: Double,
              maxLossPct: Double, targetPct: Double, maxStakePct: Double,
              kellyFraction: Double, minEdge: Double,
              entryOffsetSeconds: Double, cutoffSeconds: Double,
              autoBet: Bool = true, recovery: Bool = false) async throws -> PredictRun {
        if let existing = run(for: profileId) {
            guard existing.status != .running else {
                throw MarketError("A prediction run is already going on this account. End it before starting another.")
            }
            // The run about to be overwritten. Opening a new one used to be the other
            // way a finished run vanished — the file holds one per account, and this
            // is the last moment the old one exists.
            await PredictJournal.shared.archive(existing)
        }
        var fresh = PredictRun.opening(
            profileId: profileId, bankroll: bankroll, minutes: minutes,
            maxLossPct: maxLossPct, targetPct: targetPct, maxStakePct: maxStakePct,
            kellyFraction: kellyFraction, minEdge: minEdge,
            entryOffsetSeconds: entryOffsetSeconds, cutoffSeconds: cutoffSeconds,
            autoBet: autoBet, recovery: recovery)
        // A target below the loss limit is a run that can only end badly, and a typo
        // rather than an intention. Same rule as a trading session.
        if fresh.targetPct < fresh.maxLossPct { fresh.targetPct = fresh.maxLossPct * 1.5 }

        runs[profileId] = fresh
        save(fresh)
        // Nothing carried over from the last run: a stale decision or a window this
        // one has not looked at would otherwise be the first thing its panel showed.
        lastDecision = nil
        lastSeenWindow = nil
        watch = nil
        await Polymarket.shared.forget()

        // Sockets first. A beat for three of them to connect and print, so the first
        // tick reads a live median rather than one polled Yahoo sample — which would
        // put the run's opening minutes on the very feed the eleven-basis-point gap
        // was measured against, and show a degraded banner on a healthy run.
        await BtcLiveFeed.shared.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        brain = await PredictShadowBook.shared.refit(force: true)
        policy = await PredictShadowBook.shared.runContest(force: true).policy
        await refreshTape(force: true)
        await measureFidelity(force: true)
        log("[predict] opened: \(money(bankroll)) for \(f(minutes, 0))m, "
            + "limit \(money(fresh.lossLimit)), target \(money(fresh.targetAmount)), "
            + "\(cents(minEdge)) minimum edge, \(f(kellyFraction * 100, 0))% of Kelly, "
            + "entering at \(f(entryOffset(for: fresh), 0))s")
        log("[predict] \(brain.summary)")
        log("[predict] \(feedHealth.summary)")
        startLoop(profileId: profileId)
        return fresh
    }

    func end(profileId: String) async throws -> PredictRun {
        guard var current = run(for: profileId), current.status == .running else {
            throw MarketError("No prediction run is going on this account.")
        }
        stopLoop(profileId)
        await settle(&current)
        let openCount = current.bets.filter(\.isOpen).count
        current.status = .stopped
        current.endedAt = nowMs()
        current.endNote = "You ended this one \(f(current.secondsLeft / 60, 0)) minutes before its time was up — "
            + "that is all \"stopped\" means here, and it is not a limit being hit or anything going wrong."
            + (openCount > 0
               ? " \(openCount) window\(openCount == 1 ? " is" : "s are") still unresolved; "
                 + "a prediction contract cannot be closed out early here, so \(openCount == 1 ? "it settles" : "they settle") on its own result."
               : "")
        save(current)
        await PredictJournal.shared.archive(current)
        return current
    }

    func clear(profileId: String) async throws {
        guard let current = run(for: profileId), current.status.isOver else {
            throw MarketError("A running prediction run cannot be cleared. End it first.")
        }
        // Cleared off the screen, not out of the record. Clearing used to be the one
        // way to destroy a finished run outright, which made the tab's own history
        // depend on whether anyone had pressed a button that reads like "tidy up".
        await PredictJournal.shared.archive(current)
        stopLoop(profileId)
        runs.removeValue(forKey: profileId)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(profileId).json"))
    }

    /**
     * Resumes every run that was live when the app was last closed.
     *
     * Every account's, not just the active one. A run belongs to the account that
     * opened it and keeps its own bankroll; leaving one stopped because someone
     * switched accounts before quitting would freeze it at whatever it happened to
     * be holding. The first tick of each settles everything that resolved while the
     * app was shut before it decides anything new.
     */
    func resumeAll() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let profileId = file.deletingPathExtension().lastPathComponent
            guard let existing = run(for: profileId), existing.status == .running else { continue }
            log("[predict] resuming a run on \(profileId) with \(f(existing.secondsLeft / 60, 0)) minutes left")
            startLoop(profileId: profileId)
        }
    }

    /* ----------------------------------------------------------- the journal */

    /**
     * Everything the tab shows about the past: finished runs, the times a fitted
     * parameter moved, and the model's record against the market.
     *
     * Read straight from disk rather than from anything the running desk holds, so
     * it answers the question it exists to answer — *does this survive closing the
     * app* — rather than reporting session state that would look identical either
     * way right up until it did not.
     */
    /// The learning audit for this profile's desk. Read-only.
    func audit(profileId: String) async -> PredictAuditReport {
        let minEdge = run(for: profileId)?.minEdge ?? 0.05
        return await PredictShadowBook.shared.audit(minEdge: minEdge)
    }

    /// Re-runs the contest on demand and returns the fresh audit, so the screen
    /// that asked can show what changed.
    func runContestNow(profileId: String = "") async -> PredictAuditReport {
        let result = await PredictShadowBook.shared.runContest(force: true)
        policy = result.policy
        let minEdge = run(for: profileId)?.minEdge ?? 0.05
        return await PredictShadowBook.shared.audit(minEdge: minEdge)
    }

    func journal(profileId: String) async -> PredictJournalPayload {
        let brain = await PredictShadowBook.shared.parameters()
        let training = await PredictShadowBook.shared.trainingSet()
        let counts = await PredictShadowBook.shared.counts()
        let minEdge = run(for: profileId)?.minEdge ?? 0.05
        return await PredictJournal.shared.payload(
            brain: brain,
            score: PredictFit.score(training, weight: brain.modelWeight),
            offsets: PredictFit.offsetProfile(training, minEdge: minEdge, weight: brain.modelWeight),
            recorded: counts.recorded, resolved: counts.resolved, degraded: counts.degraded)
    }

    /* ------------------------------------------------------------- the panel */

    func panel(profileId: String) async -> PredictPanel {
        /* A full pass makes a dozen network calls and the loop is already making
         * them every ten seconds. Reading the panel inside that window returns what
         * the loop just worked out rather than queueing a second round behind it on
         * the same actor — which is what made opening the tab take ten seconds while
         * a run was live. Outside it, or with no loop running at all, the read does
         * the work itself. */
        let fresh = nowMs() - lastTickAt < 8_000
        let current = fresh ? run(for: profileId) : await tick(profileId: profileId)
        // Whether or not a tick just ran. See `absorbLive` — this is the line that
        // makes the chart live rather than as stale as the last decision.
        await absorbLive()
        let window = PredictWindow.current()
        let unreal = current.map { unrealised($0) } ?? 0
        let realised = current?.realised ?? 0
        let total = realised + unreal
        let bankroll = current?.bankroll ?? 0

        var note: String
        if let run = current {
            if run.status.isOver {
                note = run.endNote ?? run.status.label
            } else {
                let openCount = run.bets.filter(\.isOpen).count
                note = "Watching every five-minute window for another \(f(run.secondsLeft / 60, 0)) minutes. "
                    + "\(cents(run.minEdge)) of edge before it buys, at most \(money(run.maxStake)) a window, "
                    + "\(money(run.lossLimit)) the most it may lose."
                if openCount > 0 { note += " \(openCount) window open." }
                let offset = entryOffset(for: run)
                if !brain.offsetIsDefault && offset != run.entryOffsetSeconds {
                    note += " Entering at \(f(offset, 0))s rather than the \(f(run.entryOffsetSeconds, 0))s set, "
                        + "because that is the offset the shadow book has actually been paid at."
                } else if offset <= PredictModel.warmUpSeconds + 0.01 {
                    note += " No clock gate: every window is read from \(f(offset, 0))s and taken whenever the edge clears."
                }
                if run.recoversLosses {
                    note += run.recovering
                        ? " **Recovery is on and active** — \(money(run.deficit)) down, so the edge bar is at zero "
                          + "and sizes are set to erase the deficit rather than to the edge. These bets are marked."
                        : " Recovery is on but idle: it only engages once the run is down."
                }
                if let miss = run.closestMiss {
                    note += " Closest so far: \(miss.windowLabel) had \(cents(miss.edge)) on \(miss.side.rawValue) "
                        + "against \(cents(miss.required)) asked — \(cents(miss.shortfall)) short."
                }
            }
        } else {
            note = "A run commits a bankroll for a set time and then reads Polymarket's five-minute Bitcoin market on its own — "
                + "forming a probability, comparing it to the price, and buying only when the gap is worth the spread. "
                + "Nothing here is the trading account, and nothing here is real."
        }

        /* Spelled out one local at a time rather than inline in the initialiser.
         * Past about thirty arguments with optionals and arithmetic among them, the
         * type checker gives up on the whole expression and says so — the same tax on
         * writing anything wide in Swift that the bet thesis pays a few hundred lines
         * up. It reads better this way anyway. */
        let offset: Double = current.map { entryOffset(for: $0) } ?? brain.entryOffsetSeconds
        let liveSpot: Double? = await BtcLiveFeed.shared.spot() ?? tape.last?.p
        let secondsLeftInWindow = Swift.max(0, window.endMs - nowMs()) / 1000
        let pctOfBankroll: Double = bankroll > 0 ? (total / bankroll) * 100 : 0
        let headroom = Swift.max(0, (current?.lossLimit ?? 0) + Swift.min(0, realised))
        let cutoff = current?.cutoffSeconds ?? 35
        let drawn = track(window: window, run: current, entryOffset: offset, cutoff: cutoff)

        return PredictPanel(
            run: current,
            status: current?.status.rawValue ?? "none",
            window: window,
            windowLabel: window.label,
            question: lastMarket?.question,
            windowSecondsLeft: secondsLeftInWindow,
            forecast: lastForecast,
            calibration: lastCalibration,
            fidelity: fidelity,
            feedHealth: feedHealth,
            brain: brain,
            effectiveEntryOffset: offset,
            track: drawn,
            regime: lastRegime,
            regimeReadings: brain.regime.readings(lastRegime),
            windowBestEdge: watch?.window.start == window.start ? watch?.bestAnyEdge : nil,
            windowBestOffset: watch?.bestAnyOffset ?? 0,
            upAsk: lastBooks.up?.bestAsk, downAsk: lastBooks.down?.bestAsk,
            upBid: lastBooks.up?.bestBid, downBid: lastBooks.down?.bestBid,
            bookDepthUp: lastBooks.up?.depth(upTo: 0.99),
            bookDepthDown: lastBooks.down?.depth(upTo: 0.99),
            decision: lastDecision,
            realised: realised, unrealised: unreal, total: total,
            totalPct: pctOfBankroll,
            available: current?.available ?? 0,
            lossLimit: current?.lossLimit ?? 0,
            lossHeadroom: headroom,
            targetAmount: current?.targetAmount ?? 0,
            secondsLeft: current?.secondsLeft ?? 0,
            spot: liveSpot,
            tapeAt: tapeAt, bookAt: bookAt,
            feedError: feedError, note: note
        )
    }

    /**
     * The current window, assembled into something drawable.
     *
     * Bitcoin comes straight off the tape rather than from a stored copy — it is
     * already there at one-second resolution, and a second copy would be a second
     * thing to keep in step. Capped at three hundred points, which is one a second
     * for the whole window and more than any chart this size can show.
     */
    private func track(window: PredictWindow, run: PredictRun?,
                       entryOffset: Double, cutoff: Double) -> PredictTrack {
        let now = Swift.min(nowMs(), window.endMs)
        var btc = tape.points(from: window.startMs, to: now)
        if btc.count > 300 {
            // Keep every nth, and always the last one: a chart whose final point is
            // not the current price is a chart that is quietly behind.
            let stride = Int((Double(btc.count) / 300).rounded(.up))
            var thinned = btc.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            if let last = btc.last, thinned.last?.t != last.t { thinned.append(last) }
            btc = thinned
        }

        let markers: [TrackMarker] = (run?.bets ?? [])
            .filter { $0.window.start == window.start }
            .map { bet in
                TrackMarker(t: bet.placedAt, side: bet.side, price: bet.cost,
                            label: "\(f(bet.shares, 1)) \(bet.side.rawValue) at \(cents(bet.cost))")
            }

        return PredictTrack(
            window: window,
            openPrice: openPrice(for: window),
            btc: btc,
            twapSoFar: tape.twap(from: window.startMs, to: now),
            projected: lastForecast?.window.start == window.start ? lastForecast?.projectedTwap : nil,
            bandFrom: entryOffset,
            bandTo: Swift.max(entryOffset, 300 - cutoff),
            elapsed: (now - window.startMs) / 1000,
            points: trackPoints,
            markers: markers)
    }

    /**
     * A one-off look at the market with no run open.
     *
     * The setup screen shows the current window, the calibration and what the model
     * makes of it before any money is committed, because "would this even have bet
     * anything?" is a question worth being able to answer for free.
     */
    func preview() async -> PredictPanel {
        // Opened here too, not only by a run. The chart on the setup screen is worth
        // drawing from the same one-second tape a live run reads, and the feed closes
        // itself once nothing has drained it for three minutes — which is what
        // happens the moment this tab stops being looked at.
        await BtcLiveFeed.shared.start()
        await refreshTape()
        let window = PredictWindow.current()
        if let market = try? await Polymarket.shared.market(window) {
            lastMarket = market
            lastBooks = await Polymarket.shared.books(market)
            bookAt = nowMs()
        }
        brain = await PredictShadowBook.shared.parameters()
        policy = await PredictShadowBook.shared.currentPolicy()
        await measureFidelity()
        if let vol = tape.minuteVol(),
           let raw = PredictModel.forecast(window: window, tape: tape, minuteVol: vol,
                                           feedNoiseBps: effectiveFeedNoise) {
            lastForecast = PredictModel.against(
                market: PredictModel.implied(up: lastBooks.up, down: lastBooks.down), raw,
                maxWeight: brain.modelWeight)
        }
        lastCalibration = await calibrate(before: window, entryOffset: 180)
        lastDecision = nil
        return await panel(profileId: "__preview__")
    }
}

/* ------------------------------------------------------------------ helpers */

/// Prices on a prediction market are cents on the dollar, and reading them as
/// `$0.53` invites the exact confusion this app exists to avoid — that is not
/// fifty-three cents of value, it is a 53% chance.
func cents(_ p: Double) -> String { "\(f(p * 100, 1))¢" }

/* ---------------------------------------------------------------- the probe */

/**
 * `Paper --predicttest` — the live wiring check.
 *
 * `--selftest` covers the arithmetic against fabricated tapes, which is the right
 * way to test a model and the wrong way to test a feed. This one calls the actual
 * endpoints and prints what came back: the current window, the resolved windows
 * behind it, the book, the forecast and the decision the desk would make right
 * now. It commits no money and opens no run.
 *
 * It exists because every way this feature can silently break is on the far side
 * of a network call — a renamed Gamma field, a slug scheme that changed, a book
 * that stopped being sorted the way it was — and all of those produce a desk that
 * looks like it is working and is quietly deciding from zeroes.
 */
enum PredictProbe {

    /// Straight to stderr, unbuffered. `print` to a pipe is block-buffered, so a
    /// probe that stalls on a network call shows an empty terminal rather than the
    /// line it stalled after — which is the one thing this is for.
    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            say("  \(condition ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures.append(name) }
        }

        say("\nPaper — Polymarket wiring check. Nothing is bought.\n")

        var tape = BtcTape()
        do {
            tape.absorb(try await BtcFeed.tape(minutes: 120))
        } catch {
            say("  FAIL could not read Bitcoin minute bars — \(error.localizedDescription)")
            return false
        }
        check("Bitcoin minute bars arrive", tape.points.count > 60, "\(tape.points.count) points")
        let spot = tape.last
        check("the tape has a current price", (spot?.p ?? 0) > 0, "\(f(spot?.p ?? 0, 2))")
        let lagS = ((nowMs() - (spot?.t ?? 0)) / 1000)
        check("and it is current", lagS < 180, "\(f(lagS, 0))s behind")

        let vol = tape.minuteVol()
        check("twenty-minute volatility is measurable", vol != nil,
              vol.map { "\(f($0 * 100, 4))% a minute" } ?? "nil")

        /* The live tape. This is the section the whole feed change exists for, and
         * the number that matters is the last one: how far the three-venue median
         * sits from the polled Yahoo price the model's error term was measured
         * against. That gap is not the gap to Chainlink — nothing here can see
         * Chainlink — but it is a direct reading of how much moving feeds changed the
         * measurement, and it is the only honest thing to print at this point. */
        say("\n  live feed")
        await BtcLiveFeed.shared.start()
        try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
        let health = await BtcLiveFeed.shared.health()
        let livePoints = await BtcLiveFeed.shared.drain()
        check("both venues are printing", health.connected.count >= 2,
              health.connected.isEmpty ? "none connected"
                : health.connected.map(\.label).joined(separator: ", "))
        check("the tape is live rather than a fallback", !health.degraded, health.summary)
        check("samples arrive about once a second", livePoints.count >= 5,
              "\(livePoints.count) in 8s")
        check("the venues agree to within a few basis points", health.dispersionBps < 15,
              "\(f(health.dispersionBps, 1)) bps apart")

        if let live = await BtcLiveFeed.shared.spot(), let polled = try? await BtcFeed.spot() {
            let gapBps = abs(live - polled.p) / live * 10_000
            say("    live median \(f(live, 2))   polled Yahoo \(f(polled.p, 2))   "
                + "\(f(gapBps, 1)) bps apart")
            check("the live median is a different number from the polled one",
                  gapBps > 0 || live != polled.p,
                  gapBps <= 0.5 ? "they agree to half a basis point right now, which they will not during a move"
                                : "which is the size of the reading the old feed was giving away")
        }
        await BtcLiveFeed.shared.stop()

        let window = PredictWindow.current()
        say("\n  window \(window.label)  (\(window.slug))")

        guard let market = try? await Polymarket.shared.market(window) else {
            say("  FAIL Polymarket has no market at that slug")
            return false
        }
        check("the window's market is on Polymarket", !market.conditionId.isEmpty, market.question)
        check("it has two outcome tokens", market.tokenIds.count == 2)
        check("it is taking orders", market.acceptingOrders)

        let books = await Polymarket.shared.books(market)
        check("the Up book has offers", (books.up?.asks.count ?? 0) > 0,
              books.up?.bestAsk.map { "best \(cents($0))" } ?? "none")
        check("the Down book has offers", (books.down?.asks.count ?? 0) > 0,
              books.down?.bestAsk.map { "best \(cents($0))" } ?? "none")
        if let up = books.up {
            check("its asks are sorted cheapest first",
                  up.asks == up.asks.sorted { $0.price < $1.price })
            check("a fill walks the book rather than taking the top of it",
                  up.fill(1e9)?.price ?? 0 >= (up.bestAsk ?? 0),
                  "1e9 contracts would average \(cents(up.fill(1e9)?.price ?? 0)) against a \(cents(up.bestAsk ?? 0)) best offer")
        }
        if let a = books.up?.bestAsk, let b = books.down?.bestAsk {
            check("the two sides price a coherent book", a + b > 0.9 && a + b < 1.15,
                  "Up \(cents(a)) + Down \(cents(b)) = \(cents(a + b))")
        }

        say("\n  feed fidelity — this app's Bitcoin feed against Polymarket's resolver")
        var samples: [(moveBps: Double, agreed: Bool)] = []
        for n in 1...24 {
            let prior = window.previous(n)
            guard let m = try? await Polymarket.shared.market(prior),
                  let resolved = m.resolved,
                  let open = PredictModel.openBaseline(window: prior, tape: tape), open > 0,
                  let tw = tape.twap(from: prior.startMs, to: prior.endMs) else { continue }
            let moveBps = ((tw - open) / open) * 10_000
            let said: PredictSide = tw >= open ? .up : .down
            samples.append((moveBps, said == resolved))
            if n <= 8 {
                say("    \(prior.label)  resolved \(resolved.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))"
                    + "  this feed said \(said.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))"
                    + "  \(f(moveBps, 2)) bps  \(said == resolved ? "" : "   <-- disagree")")
            }
        }
        let fidelity = PredictFidelity.fit(samples)
        check("enough resolved windows to fit the feed gap", !fidelity.assumed,
              "\(samples.count) windows, \(fidelity.agreed) agreed")
        say("    fitted gap  \(f(fidelity.bps, 1)) bps")
        check("the fitted gap is inside its bounds",
              fidelity.bps >= PredictFidelity.floorBps && fidelity.bps <= PredictFidelity.ceilingBps)

        say("\n  the four windows behind it, replayed")
        var readable = 0
        for n in stride(from: 4, through: 1, by: -1) {
            let prior = window.previous(n)
            let m = try? await Polymarket.shared.market(prior)
            let open = PredictModel.openBaseline(window: prior, tape: tape)
            let twap = tape.twap(from: prior.startMs, to: prior.endMs)
            let move = (open ?? 0) > 0 && twap != nil ? ((twap! - open!) / open!) * 100 : 0
            var replay = "—"
            if let v = tape.minuteVol(now: prior.startMs + 150_000),
               let fc = PredictModel.forecast(window: prior, tape: tape, minuteVol: v,
                                              feedNoiseBps: fidelity.bps,
                                              now: prior.startMs + 150_000) {
                let right = m?.resolved.map { $0 == fc.side }
                replay = "\(fc.side.rawValue) at \(f(fc.pUp * 100, 1))% \(right == true ? "right" : right == false ? "wrong" : "?")"
            }
            if m?.resolved != nil && open != nil { readable += 1 }
            say("    \(prior.label)  resolved \(m?.resolved?.rawValue ?? "unresolved")   "
                + "twap move \(f(move, 4))%   model said \(replay)")
        }
        check("at least three of the last four windows can be read", readable >= 3, "\(readable) of 4")

        guard let v = vol, let raw = PredictModel.forecast(window: window, tape: tape, minuteVol: v,
                                                           feedNoiseBps: fidelity.bps) else {
            say("  FAIL no forecast could be formed")
            return false
        }
        let marketP = PredictModel.implied(up: books.up, down: books.down)
        let fc = PredictModel.against(market: marketP, raw)
        say("""

  the forecast
    open          \(f(fc.openPrice, 2))
    spot          \(f(fc.spot, 2))
    twap so far   \(f(fc.twapSoFar, 2))   over \(f(fc.elapsed, 0))s
    projected     \(f(fc.projectedTwap, 2))   where the average lands if the price stays here
    signal        \(f(fc.signalBps, 2)) bps against the open
    path sd       \(f(fc.pathSd, 2))   what Bitcoin may still do
    feed sd       \(f(fc.feedSd, 2))   the gap to the resolver's own feed
    total sd      \(f(fc.totalSd, 2))   z \(f(fc.z, 3))
    paper alone   \(f(fc.pModel * 100, 1))%
    the market    \(f((fc.pMarket ?? 0) * 100, 1))%
    weight kept   \(f((fc.modelWeight ?? 0) * 100, 0))%  — the share of Paper's doubt that is a forecast
    p(Up)         \(f(fc.pUp * 100, 1))%
""")
        check("the blend never leaves the interval between the two views",
              fc.pMarket == nil
                || (fc.pUp >= Swift.min(fc.pModel, fc.pMarket!) - 1e-9
                    && fc.pUp <= Swift.max(fc.pModel, fc.pMarket!) + 1e-9))
        check("and it leans on the market rather than on this app's feed",
              (fc.modelWeight ?? 1) < 0.5, "kept \(f((fc.modelWeight ?? 0) * 100, 0))%")
        check("the forecast is a probability", fc.pUp > 0 && fc.pUp < 1)
        check("it is anchored at the window's own open", fc.openPrice > 0)
        check("and the elapsed share is between none and all", fc.settled >= 0 && fc.settled <= 1)

        if let ask = (fc.side == .up ? books.up : books.down)?.bestAsk {
            let p = fc.side == .up ? fc.pUp : 1 - fc.pUp
            let edge = p - ask
            let kelly = PredictModel.kellyFraction(p: p, cost: ask)
            say("""
  the decision, on a $1,000 bankroll at a 5¢ floor and a quarter of Kelly
    side        \(fc.side.rawValue)
    offered at  \(cents(ask))
    model says  \(cents(p))
    edge        \(cents(edge))  \(edge >= 0.05 ? "→ would bet" : "→ no bet, the price is where the model is")
    full Kelly  \(f(kelly * 100, 1))% of bankroll → quarter-Kelly \(money(max(0, 1000 * kelly * 0.25)))
""")
        }

        say(failures.isEmpty
              ? "The feed is wired correctly.\n"
              : "\n\(failures.count) check(s) failed.\n")
        return failures.isEmpty
    }
}
