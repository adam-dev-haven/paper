/**
 * Predict.swift — the Polymarket feed, the resolution model, and the bet sizing.
 *
 * Everything else in Paper trades instruments: a thing you own a quantity of, that
 * has a price, a stop and a target, and that you sell to get out of. A prediction
 * market is not that. You buy a contract for somewhere between one cent and ninety-
 * nine cents, it pays exactly one dollar or exactly nothing, and there is no stop
 * to place because there is no path between here and the answer — only the answer.
 *
 * So this does not go through `Portfolio`. It has its own bankroll, its own file
 * and its own accounting, and the screen says so. Commingling binary contracts
 * with FIFO tax lots, share splits and exchange calendars would produce a ledger
 * that is wrong about both.
 *
 * **What the market actually asks.** Polymarket runs a rolling five-minute market
 * on Bitcoin, one per five-minute boundary, at the deterministic slug
 * `btc-updown-5m-<unix start in seconds>`. It resolves *Up* if the Chainlink
 * BTC/USD 60-second TWAP **over** the window is greater than or equal to the price
 * at the **start** of the window — not, as everyone assumes, if the closing price
 * beat the opening one. That difference is the whole model. A spike in the first
 * minute that fully retraces still resolves Up, because the average spent the
 * window above the open. Anything that predicts the close is predicting a
 * different question from the one being paid out on.
 *
 * **Where the prices come from.** Two feeds, both keyless, neither of them
 * Chainlink:
 *
 *   Polymarket Gamma  — which market this window is, what it resolved to, and the
 *                       token ids for each side.
 *   Polymarket CLOB   — the live order book, level by level, so a simulated fill
 *                       walks real depth and pays a real spread instead of
 *                       pretending the midpoint was available.
 *   Yahoo BTC-USD 1m  — the Bitcoin path itself, at one-minute resolution.
 *
 * The third one is an approximation and is labelled as one everywhere it is shown.
 * Chainlink's TWAP stream is the resolution source and Yahoo's spot feed is not
 * it; the two agree closely enough to forecast with and not closely enough to
 * settle with. So nothing here settles from Yahoo: a bet is paid out from
 * Polymarket's own published resolution, and if that has not landed yet the bet
 * stays open and says it is waiting.
 */

import Foundation

/* -------------------------------------------------------------- the window */

/// One five-minute Bitcoin market, identified the way Polymarket identifies it.
struct PredictWindow: Codable, Equatable {
    /// Unix seconds at the start of the five-minute window. This *is* the identity.
    let start: Double
    var end: Double { start + 300 }
    var slug: String { "btc-updown-5m-\(Int(start))" }

    var startMs: Double { start * 1000 }
    var endMs: Double { end * 1000 }

    /// The window containing a given instant, snapped down to the five-minute grid.
    static func containing(_ ms: Double) -> PredictWindow {
        PredictWindow(start: (ms / 1000 / 300).rounded(.down) * 300)
    }

    static func current() -> PredictWindow { containing(nowMs()) }

    func previous(_ n: Int) -> PredictWindow { PredictWindow(start: start - Double(n) * 300) }

    /// `11:40–11:45` in the reader's own clock, because the market's own title is
    /// in New York time and nobody trading this from Stockholm wants to do that
    /// arithmetic in their head every five minutes.
    var label: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: Date(timeIntervalSince1970: start)))–\(f.string(from: Date(timeIntervalSince1970: end)))"
    }
}

/// Which way a window went, or is being bet to go.
enum PredictSide: String, Codable {
    case up = "Up"
    case down = "Down"

    var other: PredictSide { self == .up ? .down : .up }
    /// Index into Polymarket's `outcomes` / `outcomePrices` / `clobTokenIds` arrays,
    /// which are always ordered ["Up", "Down"] on these markets.
    var index: Int { self == .up ? 0 : 1 }
}

/* ------------------------------------------------------------- the raw feed */

/// One side of the book, as the CLOB serves it.
struct BookLevel: Codable, Equatable {
    let price: Double
    let size: Double
}

/**
 * The live book for one side of one window.
 *
 * `asks` are sorted best-first (cheapest), which is *not* how the CLOB returns
 * them — it sends asks descending and bids ascending, so both are re-sorted here
 * once rather than at every call site that has to walk them.
 */
struct PredictBook: Codable {
    let side: PredictSide
    let tokenId: String
    let bids: [BookLevel]
    let asks: [BookLevel]
    let at: Double

    var bestAsk: Double? { asks.first?.price }
    var bestBid: Double? { bids.first?.price }
    var mid: Double? {
        guard let a = bestAsk, let b = bestBid else { return bestAsk ?? bestBid }
        return (a + b) / 2
    }
    var spread: Double? {
        guard let a = bestAsk, let b = bestBid else { return nil }
        return a - b
    }

    /// Total size available at or below a price — what could actually be bought
    /// without walking the book past the point where the edge has gone.
    func depth(upTo limit: Double) -> Double {
        asks.filter { $0.price <= limit + 1e-9 }.reduce(0) { $0 + $1.size }
    }

    /**
     * What a given number of contracts would actually cost, level by level.
     *
     * Returns the volume-weighted fill and how many contracts the book could
     * supply. A partial answer is the honest one: a book with 40 contracts on the
     * offer cannot fill 200, and rounding that up to "filled at the best ask" is
     * the single most flattering lie a simulator can tell about a thin market.
     *
     * **`maxCost` is the one that matters, and it exists because of a real loss.**
     * A contract pays one dollar or nothing, so the money at risk on a position is
     * exactly what was paid for it — there is no leverage here and no way to lose
     * more than the stake. Sizing used to convert a dollar budget into a contract
     * count by dividing it by the *best* ask and then hand that count here, which
     * is only the right number if the whole order fills at the top of the book.
     * When the top of the book was a dust order at a tenth of a cent, $50 asked for
     * fifty thousand contracts, the walk filled thirty-two thousand of them at an
     * average twenty times the best ask, and the position cost $763. Three of the
     * desk's first six bets overspent their cap that way; one run lost $900 against
     * a $200 limit, because every check upstream had been done in dollars the fill
     * then ignored. So the budget is carried into the walk and the walk stops on it,
     * taking a partial level if that is where the money runs out. The share count is
     * still honoured, but it is now the looser of the two constraints by
     * construction: no fill can average below the best ask, so `budget / bestAsk` is
     * already an upper bound on contracts and `maxCost` always binds first.
     */
    func fill(_ wanted: Double, maxPrice: Double = 1,
              maxCost: Double? = nil) -> (shares: Double, price: Double)? {
        guard wanted > 0 else { return nil }
        if let maxCost, maxCost <= 0 { return nil }
        var left = wanted
        var cost = 0.0
        var got = 0.0
        for level in asks {
            guard left > 0 else { break }
            // Walking past this price would buy contracts the model does not think
            // are cheap, using an edge measured at the best offer to justify a fill
            // several cents worse. The order stops here and reports the smaller size.
            guard level.price <= maxPrice + 1e-9 else { break }
            var take = Swift.min(left, level.size)
            if let maxCost {
                guard level.price > 0 else { continue }
                let affordable = (maxCost - cost) / level.price
                // A hair of slack so floating point cannot leave a level one
                // ten-thousandth of a contract short and call the budget spent.
                guard affordable > 1e-9 else { break }
                take = Swift.min(take, affordable)
            }
            cost += take * level.price
            got += take
            left -= take
        }
        guard got > 0 else { return nil }
        return (got, cost / got)
    }
}

/// A window's market as Gamma describes it, including how it resolved if it has.
struct PredictMarket: Codable {
    let window: PredictWindow
    let conditionId: String
    /// Indexed by `PredictSide.index`.
    let tokenIds: [String]
    let question: String
    /// Last traded price per side, 0–1. Gamma's `outcomePrices`, which become
    /// exactly "1" and "0" once the market resolves.
    let outcomePrices: [Double]
    let closed: Bool
    let acceptingOrders: Bool
    let volume: Double
    let liquidity: Double
    let minOrderSize: Double
    let tickSize: Double

    /// The published answer, or nil while the window is still open or still with
    /// the resolver. A closed market whose prices are not a clean 1/0 has not
    /// settled yet, whatever `closed` says.
    var resolved: PredictSide? {
        guard closed, outcomePrices.count == 2 else { return nil }
        if outcomePrices[0] >= 0.99 && outcomePrices[1] <= 0.01 { return .up }
        if outcomePrices[1] >= 0.99 && outcomePrices[0] <= 0.01 { return .down }
        return nil
    }

    func tokenId(_ side: PredictSide) -> String {
        side.index < tokenIds.count ? tokenIds[side.index] : ""
    }
}

/* ------------------------------------------------------------- the BTC tape */

/// One observation of the Bitcoin price, with the instant it was true.
struct TapePoint: Codable {
    let t: Double   // ms
    let p: Double
}

/**
 * A rolling record of what Bitcoin did, to the minute, plus whatever finer
 * samples the desk has taken while it was running.
 *
 * The minute bars are the backbone: Yahoo serves a full day of them and they run
 * about three seconds behind live, which is fine for a five-minute question. The
 * desk's own samples — one every tick — are layered on top so the current window,
 * the only one where sub-minute detail changes an answer, is not being averaged
 * from at most five points.
 */
struct BtcTape {
    private(set) var points: [TapePoint] = []

    mutating func absorb(_ incoming: [TapePoint]) {
        guard !incoming.isEmpty else { return }
        var byTime: [Double: Double] = [:]
        for p in points { byTime[p.t] = p.p }
        for p in incoming where p.p > 0 { byTime[p.t] = p.p }
        // Two hours is four times the longest lookback anything here asks for, and
        // bounds the array at a couple of thousand points however long a run lasts.
        let floor = nowMs() - 2 * 3600 * 1000
        points = byTime.filter { $0.key >= floor }
            .map { TapePoint(t: $0.key, p: $0.value) }
            .sorted { $0.t < $1.t }
    }

    var last: TapePoint? { points.last }

    /// The most recent observation at or before an instant — what the price *was*,
    /// rather than the nearest one in either direction, which would let a later
    /// print leak into an earlier answer.
    func price(at ms: Double) -> Double? {
        var best: TapePoint?
        for p in points where p.t <= ms + 1 { best = p }
        return best?.p
    }

    func points(from: Double, to: Double) -> [TapePoint] {
        points.filter { $0.t >= from && $0.t <= to }
    }

    /**
     * The time-weighted average price over an interval.
     *
     * A step integral, not a mean of the samples: the samples are not evenly
     * spaced — minute bars through most of a window, ten-second samples through
     * the part the desk watched live — and averaging them as if they were would
     * weight the watched part of the window several times too heavily, which is
     * precisely the part where the answer is decided.
     *
     * Each observation is held to be the price until the next one arrives, and the
     * interval is anchored at both ends: `from` takes the last price at or before
     * it, so a window whose first sample lands twenty seconds in is not treated as
     * having begun twenty seconds late.
     */
    func twap(from: Double, to: Double) -> Double? {
        guard to > from else { return price(at: from) }
        var timeline: [TapePoint] = []
        if let opening = price(at: from) { timeline.append(TapePoint(t: from, p: opening)) }
        timeline.append(contentsOf: points(from: from, to: to))
        guard let first = timeline.first else { return nil }
        if first.t > from { timeline.insert(TapePoint(t: from, p: first.p), at: 0) }

        var area = 0.0
        for i in 0..<timeline.count {
            let startAt = timeline[i].t
            let endAt = i + 1 < timeline.count ? timeline[i + 1].t : to
            guard endAt > startAt else { continue }
            area += timeline[i].p * (endAt - startAt)
        }
        let span = to - from
        return span > 0 ? area / span : timeline.last?.p
    }

    /**
     * Per-minute return volatility over a lookback, as a fraction of price.
     *
     * **Measured on a fixed time grid, not from the tape's own points**, and that is
     * not a refinement — the point-to-point version had a failure that took a live
     * run to find.
     *
     * It walked consecutive tape points and skipped any pair less than three seconds
     * apart, to stop a tiny denominator in `/√gap` amplifying microstructure noise
     * into a volatility reading. That was correct for a tape of Yahoo minute bars.
     * Against the live exchange tape, which lands a point every second, it discards
     * *every* pair — and for the first twenty minutes of a run that goes unnoticed,
     * because the minute bars pulled for history are still inside the lookback and
     * carry the estimate on their own. Then they age out, `minuteVol` returns nil,
     * and the desk vetoes every window from there on with "not enough recent Bitcoin
     * data" while a perfectly good tape arrives once a second. Seventeen minutes into
     * the first live run, it went blind and stayed blind.
     *
     * Sampling on a grid fixes both problems at once, because the grid step is chosen
     * rather than inherited. It is never finer than the tape's own typical spacing —
     * which would manufacture zero returns wherever two grid points read the same
     * print, biasing the estimate down — and never coarser than a minute, so twenty
     * minutes always yields enough returns to take a deviation of. Thirty seconds
     * against a dense tape is far enough apart that bid-ask bounce between two venues
     * is negligible beside real movement, which is the concern the old guard existed
     * to answer.
     */
    func minuteVol(lookbackMs: Double = 20 * 60_000, now: Double = nowMs()) -> Double? {
        let from = now - lookbackMs
        let window = points(from: from, to: now)
        guard window.count >= 6 else { return nil }

        var gaps: [Double] = []
        for i in 1..<window.count { gaps.append(window[i].t - window[i - 1].t) }
        gaps.sort()
        let typical = gaps[gaps.count / 2]
        let step = Swift.min(60_000, Swift.max(30_000, typical))

        var returns: [Double] = []
        var previous = price(at: from)
        var at = from + step
        while at <= now {
            let current = price(at: at)
            if let prior = previous, let current, prior > 0, current > 0 {
                // Normalised to one minute, so the estimate means the same thing
                // whatever step the tape's density ended up choosing.
                returns.append(log(current / prior) / sqrt(step / 60_000))
            }
            previous = current ?? previous
            at += step
        }
        guard returns.count >= 4 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        let vol = sqrt(variance)
        return vol.isFinite && vol > 0 ? vol : nil
    }
}

/* ------------------------------------------------------------- the forecast */

/// What the model thinks, and every number it thought it from.
struct PredictForecast: Codable {
    let window: PredictWindow
    /// Probability the window resolves Up — the model's own view once the market's
    /// price has been folded into it. This is the number every decision is made on.
    var pUp: Double
    /// Price at the start of the window — the level the TWAP is measured against.
    let openPrice: Double
    /// Bitcoin right now.
    let spot: Double
    /// Time-weighted average so far, over the elapsed part of the window.
    let twapSoFar: Double
    /// Where the window's average lands if the price simply stays here. This is the
    /// headline number: the whole question is whether it finishes above `openPrice`.
    let projectedTwap: Double
    /// Seconds gone, seconds left.
    let elapsed: Double
    let remaining: Double
    /// Per-minute return volatility, as a fraction, over the last twenty minutes.
    let minuteVol: Double
    /// How far the projected average could still be moved by the rest of the path,
    /// in dollars. Uncertainty about what Bitcoin will do.
    let pathSd: Double
    /// How far this feed's reading could be from the one the market settles on, in
    /// dollars. Uncertainty about what Bitcoin already did.
    let feedSd: Double
    /// The two in quadrature. `z` is measured in these.
    let totalSd: Double
    /// How many standard deviations the projected average sits above the open. The
    /// forecast in one number: positive favours Up.
    let z: Double
    /// The share of the window already in the books. 1 means only the feed's own
    /// error is left to be uncertain about.
    let settled: Double
    /// Which reading produced `pUp`, when a promoted policy did rather than the
    /// blend. Nil means the blend, which is the default and the common case.
    var policyId: String?

    /// The signal, in basis points — the readable version of `projectedTwap − open`,
    /// and the headline figure on the screen.
    ///
    /// **Stored, not computed.** Swift's synthesised `Codable` does not encode a
    /// computed property, so as a `var { … }` this arrived at the interface as
    /// `undefined` and the Signal tile quietly rendered an em-dash on a screen where
    /// every other number was correct — which is the worst kind of wrong, because it
    /// looks like missing data rather than a bug.
    let signalBps: Double

    /* What the market thinks, and how much of the final answer is its opinion
     * rather than this model's. Nil until a book has been read. */

    /// The model's own probability, before the market was consulted.
    var pModel: Double = 0
    /// The market's implied probability of Up, with the overround taken out.
    var pMarket: Double?
    /// How much weight the model kept. See `PredictModel.against(market:)`.
    var modelWeight: Double?
    /// Log-odds added by the cross-window model, before the market was consulted.
    /// Zero whenever that model has not earned the right to say anything, which is
    /// its default state — see `PredictRegime.swift`.
    var regimeAdjustment: Double = 0

    var side: PredictSide { pUp >= 0.5 ? .up : .down }
    var confidence: Double { Swift.max(pUp, 1 - pUp) }
}

enum PredictModel {

    /**
     * The only clock gate left, and it is about the tape rather than the market.
     *
     * The desk used to refuse to look at a window until 90 seconds had passed, on
     * the reasoning that "at the open nothing is settled and the model is a coin
     * flip with extra steps". That reasoning is correct and the gate was still
     * redundant, because the model already says so itself: `projected` starts at
     * spot, so the signal starts at zero, and `pathSd` scales with the remaining
     * time to the power of three halves, so the denominator starts at its largest.
     * Both terms push `p` to 50% at the open without being told to. A fixed offset
     * layered on top of that does not add caution — it just declines to look at
     * windows that had already moved far enough to be worth a price, which is
     * exactly the set of windows worth having.
     *
     * What *is* still needed is a few seconds for the live sampler to have taken
     * some samples: `twapSoFar` over a two-second window is one observation and a
     * rounding error, and Yahoo's minute bars run about three seconds behind. This
     * is that, and nothing more. Everything past it is the edge's job.
     */
    static let warmUpSeconds: Double = 15

    /**
     * The stake whose win puts a run back to exactly flat — the recovery rule's
     * whole arithmetic, kept here so it can be argued with by a test.
     *
     * A stake `S` at price `c` buys `S/c` contracts, each paying a dollar, so a win
     * returns `S/c` and profits `S(1 − c)/c`. Setting that equal to the deficit and
     * solving gives what is below. Note what the shape of it says: as `c` falls the
     * required stake falls with it, so the cheaper — which is to say the less
     * likely — the contract, the more affordable erasing the hole looks. That is
     * not a discount. It is the martingale's entire sales pitch, written out.
     */
    static func recoveryStake(deficit: Double, price: Double) -> Double {
        guard deficit > 0 else { return 0 }
        let c = Analysis.clamp(price, 0.01, 0.99)
        return deficit * c / (1 - c)
    }


    /// Φ, to well under a basis point. Abramowitz & Stegun 26.2.17, which is the
    /// standard rational approximation and more than enough precision for a
    /// probability that is about to be compared against a price quoted in cents.
    static func normalCDF(_ z: Double) -> Double {
        guard z.isFinite else { return z > 0 ? 1 : 0 }
        let t = 1 / (1 + 0.2316419 * abs(z))
        let d = 0.3989422804014327 * exp(-z * z / 2)
        let poly = t * (0.319381530 + t * (-0.356563782 + t * (1.781477937
                 + t * (-1.821255978 + t * 1.330274429))))
        let upper = d * poly
        return z >= 0 ? 1 - upper : upper
    }

    /**
     * The probability that a window resolves Up, given what it has done so far.
     *
     * Resolution is `TWAP(window) >= open`, so the quantity to forecast is the
     * window's *final* average. Split it at now: `e` seconds are in the books at an
     * average of `A`, `r` seconds are still to come at an unknown average `B`, and
     *
     *     final TWAP  =  (e·A + r·B) / 300
     *
     * Take `B` to be the current price and that is the projection — where the
     * average lands if nothing else happens. Everything the model does is decide
     * how far that projection could still move, and it can move for two quite
     * different reasons.
     *
     * **What Bitcoin will do.** The remaining path is a driftless random walk from
     * spot. Drift is left out deliberately: five-minute Bitcoin drift is not
     * estimable from twenty minutes of data, and every attempt to put it in is
     * momentum-chasing wearing a statistics costume. The *average* of such a path
     * over `r` seconds is normal about spot with variance σ²r/3 — the third comes
     * from integrating the walk rather than sampling its endpoint, and it is why a
     * TWAP market is meaningfully more forecastable than the close-to-close market
     * everyone assumes this is. Weighted into the final average by `r/300`, this
     * shrinks to nothing as the window runs out.
     *
     * **What Bitcoin already did.** The market settles on Chainlink's TWAP stream
     * and this reads Yahoo's spot feed. Measured against published resolutions they
     * disagree about the sign of a five-minute move often enough that the gap
     * between them is larger than a typical five-minute move — `PredictFidelity`
     * measures it every few minutes and it has run above ten basis points. Unlike
     * the first term this one does **not** shrink as the window closes: watching
     * more carefully does not help you see a feed you are not reading.
     *
     * The second term is usually the bigger one, and leaving it out is the single
     * mistake that would turn this from a simulator into a confident losing
     * strategy — it reports 97% where the honest answer is 70%, and a quarter of
     * Kelly on a 97% call against a 25¢ offer stakes a third of the bankroll.
     */
    /**
     * How long a stretch the resolver's baseline is an average of.
     *
     * Polymarket's own wording: the market resolves Up if "the time-weighted average
     * price (TWAP) of Bitcoin, generated by Chainlink, of the time range specified in
     * the title is greater than or equal to **the price at the beginning of that
     * range**", read from `btc-usd-twap-60s-streams`. The resolution source is a
     * *sixty-second TWAP stream*, so the level at the beginning of the range is not a
     * price at an instant — it is the average of the minute before the window opened.
     */
    static let baselineSeconds: Double = 60

    /**
     * Which definition of the open a shadow window was recorded under.
     *
     * Every number a sample stores — `pModel`, `moveBps` — is measured against the
     * open, so changing the open changes the model being scored. The book is the
     * evidence for how far to trust *this* model, and 251 windows recorded under the
     * instantaneous open had fitted the weight to zero on a model that stopped
     * existing in 4.17.0. The desk was running the corrected model on the old
     * model's verdict. Windows are stamped with this at record time, and only
     * windows under the current rule are fitted; older ones are kept for the record.
     *
     * `nil` (a window written before the stamp existed) is rule 1, the single tick.
     * Bump this whenever `openBaseline` changes meaning.
     */
    static let openRule = 2

    /**
     * The level this window has to beat.
     *
     * **This was a single tick, and it cost about five points of accuracy.**
     * `tape.price(at: window.startMs)` answers "what did Bitcoin print at the
     * boundary", and the resolver is not asking that question. Against a baseline
     * that is a sixty-second average, one print is off by roughly the drift over the
     * preceding half-minute — and unlike the window average, which integrates three
     * hundred seconds and washes its own noise out, that error is a single sample
     * that lands whole on every window and does not shrink.
     *
     * Replayed over the 251 resolved windows on the book to 2026-09-22, calling each
     * window by comparing its average against an instantaneous open was right 83.3%
     * of the time and against a trailing sixty-second open 88.0%, on the same
     * windows and the same prices. Paired, sixteen windows move from wrong to right
     * and four the other way — McNemar χ² = 6.05, p = 0.014.
     *
     * Applying the same smoothing to the *window* average as well, which is the
     * obvious next step and what the resolver's stream literally does, scores 85.7%
     * and is therefore left alone: the stream's smoothing is already inside the five
     * minutes being averaged, and doing it twice pulls a minute of pre-window price
     * into the answer.
     *
     * Falls back to the instantaneous print when the tape does not reach back far
     * enough — at app start, or after a reconnect — which is the old behaviour and
     * the right answer when there is no minute to average.
     */
    static func openBaseline(window: PredictWindow, tape: BtcTape) -> Double? {
        tape.twap(from: window.startMs - baselineSeconds * 1000, to: window.startMs)
            ?? tape.price(at: window.startMs)
    }

    static func forecast(window: PredictWindow, tape: BtcTape, minuteVol: Double,
                         feedNoiseBps: Double = PredictFidelity.assumedBps,
                         now: Double = nowMs(),
                         openPrice: Double? = nil) -> PredictForecast? {
        let clampedNow = Swift.min(Swift.max(now, window.startMs), window.endMs)
        // Both prices are read as of the forecast instant rather than from the end of
        // the tape. That is what makes the calibration's replay honest: asking the
        // model what it would have said three minutes into a window that has since
        // finished must not hand it the price it finished at.
        /* The open is taken from the caller when it has one, and that is not an
         * optimisation. `tape.price(at:)` answers "the last point at or before this
         * instant", and the tape keeps filling in *behind* the present as minute bars
         * arrive — so the same window could be handed a different threshold minutes
         * apart. It was: a window showed a price to beat of $81,248.45 and then
         * $81,242.32 for the same five minutes, because a bar stamped exactly on the
         * boundary turned up after a live sample a fraction of a second earlier had
         * already answered the question. Every number in this model is measured
         * against that level. It has to be decided once. */
        guard let open = openPrice ?? openBaseline(window: window, tape: tape), open > 0,
              let spot = tape.price(at: clampedNow), spot > 0 else { return nil }

        let elapsed = (clampedNow - window.startMs) / 1000
        let remaining = Swift.max(0, 300 - elapsed)
        let twapSoFar = tape.twap(from: window.startMs, to: clampedNow) ?? open

        // Where the average lands if the price simply stays here.
        let projected = (elapsed * twapSoFar + remaining * spot) / 300

        // σ per minute as a fraction → the standard deviation of the average of the
        // remaining path in dollars, spot · σ · √(r/180), weighted into the final
        // average by the share of the window it covers.
        let pathSd = (remaining / 300) * spot * minuteVol * sqrt(remaining / 180)
        let feedSd = spot * (feedNoiseBps / 10_000)
        let total = sqrt(pathSd * pathSd + feedSd * feedSd)
        guard total > 0 else { return nil }

        let z = (projected - open) / total
        let p = Analysis.clamp(normalCDF(z), 0.005, 0.995)
        return PredictForecast(
            window: window, pUp: p,
            openPrice: open, spot: spot, twapSoFar: twapSoFar, projectedTwap: projected,
            elapsed: elapsed, remaining: remaining, minuteVol: minuteVol,
            pathSd: pathSd, feedSd: feedSd, totalSd: total,
            z: z, settled: elapsed / 300,
            signalBps: ((projected - open) / open) * 10_000,
            pModel: p, pMarket: nil, modelWeight: nil
        )
    }

    /**
     * Folds the market's own price into the forecast, and mostly defers to it.
     *
     * This is the correction that stops the whole feature being a slow way to lose
     * money, and it is worth being precise about why, because the naive version
     * looks like it is working right up until it is not.
     *
     * With two minutes left on a window that has clearly gone up, Polymarket prices
     * *Up* at 95¢ and the model above says 70% — so the model sees a 25¢ edge on the
     * *Down* side at 6¢ and buys it. It is wrong, and it is wrong for a reason that
     * no amount of better path mathematics fixes: **the people setting that price
     * are reading the feed the market settles on, and this app is not.** The model's
     * 70% is not a superior opinion about a well-priced market, it is a worse
     * measurement of a quantity the other side can see directly. Treating it as
     * independent evidence and betting the difference is the single most expensive
     * mistake available here, and it aims squarely at the cheap tail, where it loses
     * nineteen times out of twenty and calls it bad luck.
     *
     * So the model keeps only the share of the opinion it has an actual claim to.
     * Its uncertainty comes in two parts: `pathSd`, which is a genuine forecast of
     * what Bitcoin might still do and which the market has no special access to, and
     * `feedSd`, which is nothing but this app's inability to read the resolver. The
     * first is the only part that is *information*, so it gets the weight:
     *
     *     w  =  pathSd²  /  (pathSd² + feedSd²)
     *
     * and the two probabilities are combined in log-odds, which is the right space
     * for averaging beliefs and keeps the result inside (0,1) by construction. The
     * weight falls as the window closes, which is exactly right — late in a window
     * there is nothing left to forecast and everything left to *observe*, and the
     * market is the one doing the observing.
     *
     * **The weight is capped, and the cap is a judgement rather than a derivation.**
     * The formula above rests on a premise that is only partly true: that `pathSd`
     * is uncertainty the market has no special access to. It is not. The people
     * pricing this window are forecasting the remaining path too, and their estimate
     * is not obviously worse than this one — so counting the whole path term as an
     * information advantage double-counts the forecastable part. Taken literally the
     * formula reached 38% weight on a quiet evening with a narrow feed gap, which
     * was enough to manufacture a nine-cent edge on a twenty-four-cent contract:
     * precisely the cheap-tail purchase this whole mechanism exists to prevent,
     * arrived at by a more sophisticated route.
     *
     * What the model can honestly claim over the market is not its path forecast but
     * the possibility that a thin five-minute book is briefly slow. That is real and
     * small and not measurable from here, so the weight is capped — originally at a
     * flat 0.25 stated as the judgement it was.
     *
     * **That cap is now measured.** `PredictShadowBook` writes down every window the
     * desk observes, with the model's probability and the market's price at each
     * offset, and fills in the published answer when it lands. Once a hundred
     * resolved windows are on record it sweeps this weight and keeps whichever value
     * minimises Brier score against those outcomes — betting nothing all session
     * still produces twelve labelled examples an hour, so the evidence accumulates
     * whether or not the desk trades. The fit is held to a ceiling of 0.35 and the
     * panel reports the uncapped answer alongside it, because a cap you cannot see
     * is indistinguishable from a measurement. A fitted weight of zero would be the
     * honest finding that the model never added anything, and the sweep starts there
     * so that answer is reachable.
     *
     * With the cap in force a bet needs the model to disagree with the market by
     * something like twenty cents before five cents of edge survives. That is rare.
     * It should be: an edge over a market that can see more than you is rare, and a
     * desk that found one every five minutes would be measuring its own error.
     */
    /**
     * Shifts the model's own probability by a cross-window reading.
     *
     * Applied **before** `against(market:)` and not after, which is the whole of the
     * safety argument for where this sits. The market can see the last twelve windows
     * as well as this app can — better, since it is reading the settlement feed — so a
     * regime view is not private information and must not bypass the deference to the
     * market. Folding it into the model's own probability first means it is then
     * discounted by exactly the same weight everything else the model thinks is
     * discounted by. A regime signal that disagrees with the price loses, which is the
     * correct outcome for a signal the other side can also compute.
     */
    static func withRegime(_ forecast: PredictForecast, adjustment: Double) -> PredictForecast {
        guard adjustment != 0, forecast.pUp > 0, forecast.pUp < 1 else { return forecast }
        var out = forecast
        let shifted = log(forecast.pUp / (1 - forecast.pUp)) + adjustment
        out.pUp = Analysis.clamp(1 / (1 + exp(-shifted)), 0.005, 0.995)
        out.pModel = out.pUp
        out.regimeAdjustment = adjustment
        return out
    }

    /**
     * The price at which the market has stopped expressing a probability.
     *
     * `logit` is undefined at zero and one, so the blend has always needed the
     * price held off the ends. What it must not do is fall back to *no blend* when
     * it gets there, and for a long time that is exactly what it did — see the
     * guard rewritten below, and `decide`'s `.decided` verdict for the other half
     * of the answer.
     */
    static let decidedBound: Double = 0.005

    /**
     * The cheapest contract the desk will buy, and the reason is not the price.
     *
     * A contract offered under a cent is the market saying the window is over.
     * Nothing this model knows can outweigh that: late in a window `pathSd` is a
     * few dollars and `feedSd` is ninety, so a disagreement with a settled price is
     * a statement about Paper's feed, not about Bitcoin. `PredictLearning.entryOffset`
     * already refused to *score* a look under a cent — `best.ask > 0.01` — while
     * the live desk was free to take one, which is how the replay came to disagree
     * with the desk about trades the desk had really made.
     */
    static let minimumPrice: Double = 0.01

    /**
     * Folds the market's price into the model's probability.
     *
     * **The guard used to be `pMarket > 0.001, pMarket < 0.999`, and the `else`
     * branch returned the forecast unblended.** Both bounds are reachable: late in a
     * decided window one side of the book empties of offers, `implied` falls back to
     * the one side left — `1 − downMid` with `downMid` at Polymarket's 0.1¢ tick —
     * and lands on exactly 0.999. The comparison is strict, so the deference to the
     * market switched itself off at precisely the moment the market was most certain
     * and the model least able to see. The path model went on believing the window
     * was a 13% proposition while it was offered at a fifth of a cent, reported
     * thirteen cents of edge, and bought thirteen thousand contracts of dust. Five of
     * those in a row took a run to its loss limit on 2026-09-22; every bet Paper has
     * placed under 5¢ was one of these, and not one of them carried the sentence
     * "the market was pricing X%" in its thesis, because `pMarket` was never set.
     *
     * So the price is clamped into the interval the arithmetic can carry rather than
     * used as a reason to ignore it. The forecast keeps the *unclamped* price on the
     * record, because "the market said 99.9%" is the fact, and `decide` reads it to
     * refuse the window outright — at saturation whatever edge survives the clamp is
     * an artefact of the clamp and not a measurement.
     */
    static func against(market pMarket: Double?, _ forecast: PredictForecast,
                        maxWeight: Double = defaultMaxWeight) -> PredictForecast {
        var out = forecast
        out.pModel = forecast.pUp
        guard let pMarket else { return out }

        let pathVar = forecast.pathSd * forecast.pathSd
        let feedVar = forecast.feedSd * forecast.feedSd
        let raw = pathVar + feedVar > 0 ? pathVar / (pathVar + feedVar) : 0
        let w = Swift.min(raw, maxWeight)

        func logit(_ p: Double) -> Double { log(p / (1 - p)) }
        let priced = Analysis.clamp(pMarket, 0.005, 0.995)
        let mixed = w * logit(Analysis.clamp(forecast.pUp, 0.005, 0.995)) + (1 - w) * logit(priced)

        out.pUp = Analysis.clamp(1 / (1 + exp(-mixed)), 0.005, 0.995)
        out.pMarket = pMarket
        out.modelWeight = w
        return out
    }

    /**
     * The probability, under a reading that won its contest against the market.
     *
     * Replaces the blend rather than adjusting it. The blend's whole vocabulary is
     * "how loud is the model against the price", which is one number between zero
     * and one, and that vocabulary has exactly one way to say *the price is
     * slightly wrong in this specific circumstance*: it cannot. So a promoted
     * policy is given the same inputs and allowed to answer in its own terms.
     *
     * `modelWeight` is left reporting what the blend would have used, because the
     * interface prints it as "the share of Paper's doubt that is a forecast" and
     * it remains a true description of the path model's standing. What has changed
     * is that the desk is no longer obliged to use it.
     */
    static func withPolicy(_ forecast: PredictForecast, policy: PredictPolicy,
                           pMarket: Double, moveBps: Double, offset: Double,
                           regime: [Double]) -> PredictForecast {
        guard !policy.isDefault, pMarket > 0.001, pMarket < 0.999 else { return forecast }
        var out = forecast
        // `pModel` is zero only when `against(market:)` never ran, which cannot happen
        // on the live path — it is called immediately before this — but a zero here
        // would be read as a probability rather than as "unset", so the intent the
        // old `?? forecast.pUp` was written for is kept explicitly. It stopped being
        // expressed by `??` when the field became non-optional, and the compiler had
        // been saying so.
        let source = forecast.pModel > 0 ? forecast.pModel : forecast.pUp
        let pModel = Analysis.clamp(source, 0.005, 0.995)
        // Built exactly as `PredictLearner.rows` builds a training row, including
        // the scaling, because a policy fitted on one set of units and evaluated on
        // another is a policy evaluated at random.
        let row = LearnRow(
            window: 0, outcome: 0,
            logitMarket: log(pMarket / (1 - pMarket)),
            logitModel: log(pModel / (1 - pModel)),
            move: Analysis.clamp(moveBps / 50, -4, 4),
            offset: (offset - 150) / 120,
            regime: regime.count == 5 ? regime : [0, 0, 0, 0, 0])
        out.pUp = policy.probability(row)
        out.pMarket = pMarket
        out.policyId = policy.candidateId
        return out
    }

    /**
     * Which side of a window is cheap, given a probability for Up.
     *
     * Not the side the model *favours* — the side that is *underpriced*. Those come
     * apart more often than they sound like they should: a model can make a window
     * 55% Up while Up is offered at 62¢ and Down at 30¢, which is no edge on the
     * outcome it prefers and fifteen cents on the one it does not. A prediction
     * market pays for buying a contract below what it is worth and says nothing
     * about which outcome you would have guessed.
     *
     * Note that the two edges always sum to minus the overround — a book quoting
     * 62/39 leaves `(p − 0.62) + (1 − p − 0.39) = −0.01` however good the model is —
     * so at most one side can be worth buying, and which one is not obvious from the
     * probability alone. That is the entire reason this is a function rather than a
     * glance at `forecast.side`.
     */
    static func cheaperSide(pUp: Double, upAsk: Double?, downAsk: Double?)
        -> (side: PredictSide, p: Double, ask: Double, edge: Double)? {
        var options: [(side: PredictSide, p: Double, ask: Double, edge: Double)] = []
        if let upAsk { options.append((.up, pUp, upAsk, pUp - upAsk)) }
        if let downAsk { options.append((.down, 1 - pUp, downAsk, (1 - pUp) - downAsk)) }
        return options.max { $0.edge < $1.edge }
    }

    /**
     * The market's own probability that a window resolves Up.
     *
     * Both sides' midpoints, normalised. A binary book on Polymarket routinely sums
     * to about 101¢ across the two sides — that overround is the market makers'
     * spread, not a claim that the outcomes add to more than certainty, and dividing
     * it out is what turns two prices into one probability.
     */
    static func implied(up: PredictBook?, down: PredictBook?) -> Double? {
        let upMid = up?.mid
        let downMid = down?.mid
        if let u = upMid, let d = downMid, u + d > 0 { return u / (u + d) }
        if let u = upMid { return u }
        if let d = downMid { return 1 - d }
        return nil
    }

    /**
     * How much of the bankroll a bet is worth, before any of the run's own caps.
     *
     * Kelly, on a contract bought at `cost` that pays one dollar: the fraction of
     * the bankroll is `(p − cost) / (1 − cost)`. Taken at full size that is the
     * growth-optimal bet and also a bet that will, with certainty, put you through
     * drawdowns no one sits through — and it is optimal only if `p` is *right*,
     * which here it is not, because `p` came from a twenty-minute volatility
     * estimate, a two-hour feed-error estimate and a normal approximation. Kelly's
     * sensitivity to an overstated edge is brutally asymmetric: overestimate `p` by
     * a little and you are betting several times the optimal amount.
     *
     * So the run applies a fraction of it, defaulting to a quarter, and the number
     * is on screen rather than buried. Quarter-Kelly keeps about 44% of the growth
     * rate for a quarter of the volatility, which is the trade every serious
     * treatment of this recommends and the one nobody makes when the sizing is
     * hidden.
     */
    /**
     * The most weight the model's own probability may ever carry against the price.
     *
     * A ceiling on `against(market:_:)`, and the one number in this file that is a
     * judgement rather than a measurement. See that function for why the derivation
     * underneath it overstates the case: the market forecasts the remaining path
     * too, so the model's only honest claim over it is that a thin five-minute book
     * is occasionally slow — which is real, small, and not measurable from here.
     *
     * Set deliberately low. The failure mode of setting it too high is a confident
     * purchase of the cheap side of a decided window; the failure mode of setting it
     * too low is a desk that does not trade, which is a much cheaper thing to be
     * wrong about and is anyway the correct answer most of the time.
     */
    static let defaultMaxWeight: Double = 0.25

    /// The starting point, not the setting. `PredictShadowBook` re-fits this by
    /// Brier score over resolved windows once it has a hundred of them, which is
    /// the measurement the paragraph above calls the honest next step. Until then
    /// every caller gets this number, and the panel says which of the two it is on.

    static func kellyFraction(p: Double, cost: Double) -> Double {
        guard cost > 0, cost < 1 else { return 0 }
        return (p - cost) / (1 - cost)
    }
}

/* ------------------------------------------------------------ feed fidelity */

/**
 * How closely the price feed this reads reproduces the one the market settles on.
 *
 * Not a detail. Paper reads Yahoo's BTC-USD spot feed and Polymarket resolves from
 * Chainlink's 60-second BTC/USD TWAP stream, and those are not the same number. On
 * the first two hours measured, the tape's own verdict on a window matched the
 * published resolution eleven times in sixteen — and the misses were not all
 * near-ties: one window the tape had moving up by eleven basis points resolved
 * Down.
 *
 * So the discrepancy is estimated rather than assumed. Model the gap between the
 * two feeds' readings of one window as `ε ~ Normal(0, σ²)`. A window whose
 * measured move was `m` resolves the way the tape says with probability `Φ(|m|/σ)`,
 * which makes the whole sample a one-parameter likelihood:
 *
 *     L(σ) = Σ  log Φ( |mᵢ|/σ )   over windows the tape called right
 *          + Σ  log Φ( −|mᵢ|/σ )  over windows it called wrong
 *
 * There is no closed form, and none is needed — it is one bounded parameter over a
 * few dozen points, so it is solved by scanning. The result goes straight into the
 * forecast as the irreducible term, and onto the screen as a sentence, because
 * "this feed agrees with the resolver 70% of the time on a five-minute move" is the
 * single most important thing to know before betting on one.
 */
struct PredictFidelity: Codable {
    /// The fitted standard deviation of the gap between feeds, in basis points.
    let bps: Double
    /// Windows the fit is built from.
    let windows: Int
    /// How many of those the tape's own verdict got right.
    let agreed: Int
    /// True when there was not enough resolved history to fit, and the conservative
    /// default is in force.
    let assumed: Bool
    let measuredAt: Double
    let summary: String

    /// Used until a measurement exists. Deliberately pessimistic: it is set above
    /// the first figure measured in the wild, because the failure mode of guessing
    /// this too low is a confident bet and the failure mode of guessing it too high
    /// is no bet at all.
    static let assumedBps: Double = 15

    /// A fit cannot claim the feeds are near-identical on a small sample — at four
    /// basis points the model would be reporting 90% on a six-basis-point move.
    static let floorBps: Double = 4
    static let ceilingBps: Double = 60

    static func unmeasured() -> PredictFidelity {
        PredictFidelity(
            bps: assumedBps, windows: 0, agreed: 0, assumed: true, measuredAt: 0,
            summary: "The gap between this app's Bitcoin feed and the one Polymarket settles on has not been measured yet, so a conservative \(f(assumedBps, 0)) basis points is assumed. Until it is measured every probability here is deliberately closer to a coin flip than the price data alone would suggest."
        )
    }

    /// `samples` is one entry per resolved window: the move the tape measured, in
    /// basis points, and whether the published resolution agreed with its sign.
    static func fit(_ samples: [(moveBps: Double, agreed: Bool)]) -> PredictFidelity {
        let usable = samples.filter { $0.moveBps.isFinite }
        guard usable.count >= 6 else { return unmeasured() }

        func logLikelihood(_ sigma: Double) -> Double {
            usable.reduce(0) { total, s in
                let p = Analysis.clamp(PredictModel.normalCDF(abs(s.moveBps) / sigma), 1e-9, 1 - 1e-9)
                return total + log(s.agreed ? p : 1 - p)
            }
        }
        var best = floorBps
        var bestScore = -Double.infinity
        var sigma = floorBps
        while sigma <= ceilingBps {
            let score = logLikelihood(sigma)
            if score > bestScore { bestScore = score; best = sigma }
            sigma += 0.25
        }

        let agreed = usable.filter(\.agreed).count
        let rate = Double(agreed) / Double(usable.count)

        /* **The gap is only meaningful against the size of the move it is measuring.**
         *
         * This sentence used to test `best > 8` and, below that, printed "small enough
         * that the price data is usually decisive". On a quiet morning that produced a
         * four-basis-point gap printed directly beneath a 68% agreement rate and a
         * claim that the data was decisive — which contradicts itself on the face of
         * it, and was wrong in the direction that flatters the model.
         *
         * Both numbers were correct. Four basis points *is* small in absolute terms,
         * and it was also three times the size of a typical move in that sample, which
         * is why the feed only called two windows in three the way the resolver did.
         * An absolute threshold cannot see that, because it is the ratio that decides
         * whether the price data settles anything: a four-basis-point error is nothing
         * during a move of forty and is the whole answer during a move of one.
         */
        let moves = usable.map { abs($0.moveBps) }.sorted()
        let typicalMove = moves.isEmpty ? 0 : moves[moves.count / 2]
        let ratio = typicalMove > 0 ? best / typicalMove : Double.infinity
        let verdict: String
        if ratio > 1.5 {
            verdict = "about \(f(ratio, 1))× the size of a typical move in that sample, which was \(f(typicalMove, 1)) bps. "
                + "The feed error is larger than the thing being measured, and that — rather than the raw number of basis points — "
                + "is why nothing here is ever very confident and why so few windows clear the bar"
        } else if ratio > 0.7 {
            verdict = "roughly the size of a typical move in that sample, which was \(f(typicalMove, 1)) bps. "
                + "The price data leans an answer without settling it"
        } else {
            verdict = "well under a typical move in that sample, which was \(f(typicalMove, 1)) bps, "
                + "so the price data is usually decisive"
        }

        return PredictFidelity(
            bps: best, windows: usable.count, agreed: agreed, assumed: false,
            measuredAt: nowMs(),
            summary: "Across the last \(usable.count) resolved windows this app's Bitcoin feed called \(agreed) of them "
                + "the same way Polymarket's resolver did — \(f(rate * 100, 0))%. Fitting that gives a "
                + "\(f(best, 1)) basis point gap between the two feeds, which is \(verdict)."
        )
    }
}

/* ------------------------------------------------------------ the calibration */

/// How one of the four prior windows went, and what the model would have said.
struct PriorWindow: Codable {
    let window: PredictWindow
    let label: String
    /// What Polymarket published. Nil if the window has not settled.
    let resolved: PredictSide?
    /// Bitcoin at the start of the window, and the TWAP across it.
    let openPrice: Double?
    let twap: Double?
    /// The move across the window, in percent, for the reader to see the size of
    /// what is being predicted rather than only its sign.
    let movePct: Double?
    /// What the model would have said at the same point in the window the run
    /// enters at, replayed against the same data it would have had.
    let modelSide: PredictSide?
    let modelP: Double?
    /// Whether that call was right. Nil when either half is missing.
    let modelRight: Bool?
}

/**
 * The twenty-minute check the run makes before it is allowed to bet.
 *
 * Four windows is not a sample you can estimate a win rate from, and this does not
 * pretend otherwise. What four windows *can* do is three useful things, and the
 * calibration does exactly those three:
 *
 *   **Prove the feed.** Windows that cannot be read — unresolved, or with no price
 *   history — mean the data the model needs is not arriving. That is a veto, and
 *   it is the one that matters, because a model fed a flat line will happily
 *   produce a confident answer.
 *
 *   **Measure the volatility.** The last twenty minutes of one-minute returns are
 *   the σ the forecast is scaled by. This is the calibration's real contribution
 *   and it is continuous rather than a pass/fail.
 *
 *   **Replay the rule.** Run the model at the same offset into each of the four
 *   windows and see whether it was right. With four samples this cannot confirm
 *   anything — but going 0-for-4 or 1-for-4 against a rule that claims 60-70%
 *   confidence is evidence the regime is not one this model reads, and the run
 *   sits the window out. Three or four right does not earn a bigger bet; it only
 *   removes the penalty. The asymmetry is deliberate. A small sample is allowed to
 *   veto and never allowed to encourage.
 */
struct PredictCalibration: Codable {
    let priors: [PriorWindow]
    /// Of the four, how many could be read at all.
    let readable: Int
    /// Of the readable ones, how many the replayed model got right.
    let hits: Int
    let replayed: Int
    /// Per-minute return volatility over the twenty minutes, as a fraction.
    let minuteVol: Double?
    /// Average absolute move across the four windows, in percent — the plain-
    /// language version of the volatility figure.
    let averageMovePct: Double?
    /// How the outcomes ran: "Up Down Down Up".
    let sequence: [String]
    /// What the calibration does to the edge the run demands. 1 means no change.
    let edgeMultiplier: Double
    /// Set when the calibration refuses the window outright.
    let veto: String?
    /// One sentence for the screen.
    let summary: String

    static func build(priors: [PriorWindow], minuteVol: Double?) -> PredictCalibration {
        let readable = priors.filter { $0.resolved != nil && $0.openPrice != nil }.count
        let judged = priors.compactMap(\.modelRight)
        let hits = judged.filter { $0 }.count
        let moves = priors.compactMap(\.movePct).map(abs)
        let avgMove = moves.isEmpty ? nil : moves.reduce(0, +) / Double(moves.count)

        var veto: String?
        var multiplier = 1.0

        if readable < 3 {
            veto = "Only \(readable) recently resolved window\(readable == 1 ? "" : "s") could be read, against the four this asks for. "
                + "Either Polymarket's resolver is a long way behind or the Bitcoin tape has gaps in it; "
                + "the model needs settled windows behind it to size the next one, and without them it is guessing with a decimal point."
        } else if minuteVol == nil {
            veto = "There is not enough recent Bitcoin data to measure how volatile the last twenty minutes were, and every probability here is scaled by that number."
        } else if judged.count >= 3 && hits <= judged.count / 4 {
            veto = "Replayed against the last \(judged.count) settled windows the rule got \(hits) right. "
                + "That is not a win rate — four windows never is — but a rule that claims to read this market "
                + "and then calls \(judged.count - hits) of \(judged.count) wrong is describing a regime it does not understand. Sitting this one out."
        } else if judged.count >= 3 && Double(hits) / Double(judged.count) <= 0.5 {
            // A rule claiming around seventy percent that then goes even over four
            // windows is not being confirmed by them. It is not vetoed either — four
            // is far too few for that — but it pays a higher toll to trade.
            multiplier = 1.5
        }

        let sequence = priors.map { $0.resolved?.rawValue ?? "?" }
        var summary: String
        if let veto {
            summary = veto
        } else {
            summary = "The last \(sequence.count) settled windows went \(sequence.joined(separator: " → ")). "
            if let avgMove { summary += "Average move \(f(avgMove, 3))% a window. " }
            if let v = minuteVol { summary += "Bitcoin is moving \(f(v * 100, 3))% a minute. " }
            if !judged.isEmpty {
                summary += "Replayed over \(judged.count) of them, the rule called \(hits) right"
                summary += multiplier > 1
                    ? ", so this window needs \(f(multiplier, 1))× the usual edge before anything is bought."
                    : "."
            }
        }

        return PredictCalibration(
            priors: priors, readable: readable, hits: hits, replayed: judged.count,
            minuteVol: minuteVol, averageMovePct: avgMove, sequence: sequence,
            edgeMultiplier: multiplier, veto: veto, summary: summary
        )
    }
}

/* ------------------------------------------------------------- the API client */

/**
 * Polymarket, read-only.
 *
 * Two hosts. Gamma is the catalogue — which market a window is, and what it
 * resolved to; the CLOB is the book. Neither needs a key, neither is written to,
 * and nothing in Paper can place a real order: there is no wallet, no signature
 * and no private key anywhere in this file, which is what makes the simulation
 * safe to run unattended.
 *
 * Resolved windows are cached permanently — a settled market cannot change — and
 * live ones for a few seconds, because a run polls every ten and there is no need
 * to ask twice inside one tick.
 */
actor Polymarket {
    static let shared = Polymarket()

    private var marketCache: [String: (at: Double, market: PredictMarket)] = [:]
    private var settled: [String: PredictMarket] = [:]

    private static let gamma = "https://gamma-api.polymarket.com"
    private static let clob = "https://clob.polymarket.com"

    /// Cleared between runs so a long-lived process does not carry an unbounded map
    /// of every window it has ever seen.
    func forget() {
        marketCache.removeAll()
        if settled.count > 200 { settled.removeAll() }
    }

    func market(_ window: PredictWindow, ttlMs: Double = 8_000) async throws -> PredictMarket {
        if let done = settled[window.slug] { return done }
        if let hit = marketCache[window.slug], nowMs() - hit.at < ttlMs { return hit.market }

        let json = try await Net.json("\(Self.gamma)/events?slug=\(Net.esc(window.slug))")
        guard let events = json as? [[String: Any]], let event = events.first,
              let markets = event["markets"] as? [[String: Any]], let m = markets.first
        else { throw MarketError("Polymarket has no five-minute Bitcoin market for \(window.label).") }

        // Gamma serves these two as JSON *strings* containing JSON arrays, not as
        // arrays. Decoding them as arrays returns nil and the market silently looks
        // like it has no sides.
        func nested(_ key: String) -> [Any] {
            if let direct = m[key] as? [Any] { return direct }
            guard let raw = m[key] as? String, let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
            return parsed
        }

        let prices = nested("outcomePrices").map { value -> Double in
            if let d = value as? Double { return d }
            return Double(value as? String ?? "") ?? 0
        }
        let market = PredictMarket(
            window: window,
            conditionId: m["conditionId"] as? String ?? "",
            tokenIds: nested("clobTokenIds").compactMap { $0 as? String },
            question: m["question"] as? String ?? (event["title"] as? String ?? window.slug),
            outcomePrices: prices,
            closed: (m["closed"] as? Bool) ?? false,
            acceptingOrders: (m["acceptingOrders"] as? Bool) ?? false,
            volume: Double(m["volume"] as? String ?? "") ?? (m["volume"] as? Double ?? 0),
            liquidity: Double(m["liquidity"] as? String ?? "") ?? (m["liquidity"] as? Double ?? 0),
            minOrderSize: (m["orderMinSize"] as? Double) ?? 5,
            tickSize: (m["orderPriceMinTickSize"] as? Double) ?? 0.01
        )
        if market.resolved != nil { settled[window.slug] = market }
        marketCache[window.slug] = (nowMs(), market)
        return market
    }

    /// The live book for one side. Levels are re-sorted best-first on the way in.
    func book(_ market: PredictMarket, side: PredictSide) async throws -> PredictBook {
        let token = market.tokenId(side)
        guard !token.isEmpty else { throw MarketError("No \(side.rawValue) token for \(market.window.label).") }
        let json = try await Net.json("\(Self.clob)/book?token_id=\(token)")
        guard let d = json as? [String: Any] else { throw MarketError("The order book came back empty.") }

        func levels(_ key: String) -> [BookLevel] {
            ((d[key] as? [[String: Any]]) ?? []).compactMap {
                guard let p = Double($0["price"] as? String ?? ""),
                      let s = Double($0["size"] as? String ?? ""), s > 0 else { return nil }
                return BookLevel(price: p, size: s)
            }
        }
        return PredictBook(
            side: side, tokenId: token,
            bids: levels("bids").sorted { $0.price > $1.price },
            asks: levels("asks").sorted { $0.price < $1.price },
            at: nowMs()
        )
    }

    /// Both books at once. A decision needs the price of each side, and fetching
    /// them in series doubles the age of the first one for no reason.
    func books(_ market: PredictMarket) async -> (up: PredictBook?, down: PredictBook?) {
        async let up = try? book(market, side: .up)
        async let down = try? book(market, side: .down)
        return (await up, await down)
    }
}

/* --------------------------------------------------------- the Bitcoin feed */

enum BtcFeed {
    /**
     * One-minute Bitcoin bars for the last day.
     *
     * Deliberately not routed through `Market.shared.chart`, which caches on a
     * forty-five-second leash keyed by range and interval — correct for the desk,
     * wrong here, where the point is to sample the same minute repeatedly as it
     * fills in. This asks directly, with a cache-buster, the same way the live
     * price path does and for the same measured reason.
     *
     * Each bar contributes two points: its open stamped at the bar's own time, and
     * its close stamped a minute later. The opens are what make the window's start
     * price exact rather than "the close of the minute before", which on a 300-
     * second TWAP question is the difference between the right threshold and one
     * that is a full minute stale.
     */
    static func tape(minutes: Int = 120) async throws -> [TapePoint] {
        let json = try await Net.json(
            "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD?range=1d&interval=1m&_=\(Int(nowMs()))")
        guard let result = ((json as? [String: Any])?["chart"] as? [String: Any])?["result"] as? [[String: Any]],
              let first = result.first,
              let ts = first["timestamp"] as? [Double]
        else { throw MarketError("No Bitcoin minute data came back.") }

        let q = ((first["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first ?? [:]
        let closes = q["close"] as? [Any] ?? []
        let opens = q["open"] as? [Any] ?? []

        var out: [TapePoint] = []
        let cutoff = nowMs() - Double(minutes) * 60_000
        for i in 0..<ts.count {
            let at = ts[i] * 1000
            guard at >= cutoff else { continue }
            // Yahoo pads gaps with nulls; a null minute is skipped rather than
            // carried forward, so the tape never invents a print that did not happen.
            if i < opens.count, let o = opens[i] as? Double, o > 0 {
                out.append(TapePoint(t: at, p: o))
            }
            if i < closes.count, let c = closes[i] as? Double, c > 0 {
                out.append(TapePoint(t: at + 60_000, p: c))
            }
        }
        guard !out.isEmpty else { throw MarketError("No usable Bitcoin minute data.") }

        // The last bar's close is stamped a minute into the future by the rule above.
        // Pulling it back to now keeps `tape.last` meaning "the price now" instead of
        // a point the clock has not reached.
        let ceiling = nowMs()
        return out.map { $0.t > ceiling ? TapePoint(t: ceiling, p: $0.p) : $0 }
    }

    /**
     * The single live price, for the ten-second samples between minute bars.
     *
     * The spark endpoint rather than the chart one. Both carry
     * `meta.regularMarketPrice`, but the chart request also hauls back a full day of
     * one-minute bars — the better part of a hundred kilobytes, every ten seconds,
     * to read one number that is also in a payload a fiftieth of the size.
     *
     * The trailing cache-buster is load-bearing for the same measured reason it is
     * on the desk's live price path: Yahoo's CDN caches this URL and ignores
     * `Cache-Control`, so a repeated identical request quietly returns a payload
     * whose timestamp drifts further behind on every call.
     */
    static func spot() async throws -> TapePoint {
        let json = try await Net.json(
            "https://query1.finance.yahoo.com/v7/finance/spark?symbols=BTC-USD&range=1d&interval=5m&_=\(Int(nowMs()))")
        guard let result = ((json as? [String: Any])?["spark"] as? [String: Any])?["result"] as? [[String: Any]],
              let meta = (result.first?["response"] as? [[String: Any]])?.first?["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double, price > 0
        else { throw MarketError("No live Bitcoin price.") }
        return TapePoint(t: nowMs(), p: price)
    }
}
