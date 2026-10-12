/**
 * PredictFeed.swift — the live Bitcoin tape, read from the exchanges themselves.
 *
 * **Why this file exists, stated as the measurement that forced it.**
 *
 * The prediction desk used to read Yahoo's BTC-USD spot endpoint, polled once per
 * ten-second tick. Polymarket settles its five-minute markets on Chainlink's
 * BTC/USD stream. Fitted against published resolutions, the gap between those two
 * feeds ran at ten to eleven basis points — larger than a typical five-minute
 * move — and that number does not appear in the model as a nuisance. It appears as
 * `feedSd`, and `feedSd` is what decides how much of a voice the model gets:
 *
 *     w  =  pathSd²  /  (pathSd² + feedSd²)
 *
 * At a hundred and fifty seconds into a window, with Bitcoin near $100k moving a
 * tenth of a percent a minute, `pathSd` is about $46 and an eleven-basis-point
 * `feedSd` is about $110. The model gets eight percent of the vote, the market
 * gets ninety-two, and the blend needs the two to disagree by more than twenty
 * cents before five cents of edge survives. A thirty-minute run over six windows
 * then buys nothing — not because it malfunctioned, but because that is what the
 * arithmetic says it should do.
 *
 * Polling Yahoo more often does not touch this. More samples shrink `pathSd`,
 * which is already the small term. `feedSd` is not about how often the feed is
 * read; it is about *which feed is being read*. So the fix is not a faster poll of
 * the wrong source, it is the right source.
 *
 * **What Chainlink actually is**, and why this shape rather than another: its
 * BTC/USD aggregator is a *median* of independent node reports, each of which is
 * itself a volume-weighted read across the major spot venues. It is not any one
 * exchange, and it is not an average — the median is what makes it robust to a
 * single venue printing badly. So this reads three USD-quoted venues directly and
 * takes the median of them. Matching the *shape* of the resolver's estimator
 * matters more than matching its exact venue list, which is not public anyway.
 *
 * **USD, not USDT.** Binance is the deepest BTC book in the world and it is not
 * here, because it quotes BTCUSDT and the USDT peg wanders a few basis points
 * against the dollar. Adding a deeper venue at the cost of importing a stablecoin
 * basis into a measurement whose whole purpose is to be accurate to single basis
 * points is a bad trade. Coinbase, Kraken and Bitstamp all quote real dollars.
 *
 * **What this is not.** No key, no account, no order path. Three public trade and
 * ticker streams, read-only, and a Yahoo fallback for when they are unreachable.
 */

import Foundation

/* --------------------------------------------------------------- the venues */

/// One public spot venue, and how to talk to it.
///
/// Each case carries its own subscribe frame and its own price parser because the
/// three protocols have nothing in common beyond being JSON over a socket, and the
/// alternative — a general message shape they are all coerced into — would put the
/// parsing bugs somewhere further from the format they are bugs about.
enum BtcVenue: String, CaseIterable, Codable {
    case coinbase
    case kraken

    /* **Why these two, measured rather than assumed.** Twenty seconds on each
     * candidate stream, counting prints and the gaps between them:
     *
     *     Coinbase ticker            70 prints   p95 gap 915ms    max 1.1s
     *     Kraken ticker (bbo)        83 prints   p95 gap 981ms    max 2.5s
     *     Kraken ticker (default)     5 prints   p95 gap  10.1s   max 10.1s
     *     Bitfinex ticker             3 prints                    max 15.0s
     *     Bitfinex trades            21 prints   p95 gap 6.7s
     *     Gemini v1 trades            1 print
     *     Bitstamp order book       173 prints   p95 gap 207ms    max 0.6s   901KB
     *
     * Two things fell out of that. Kraken's v2 ticker defaults to `event_trigger:
     * trades` and goes ten seconds between prints on a quiet book — it was silently
     * dropping out of the tape, and one word of subscribe frame fixes it. And the
     * trade-driven streams are all unusable as a continuous price: they speak only
     * when someone trades, which on a calm Sunday is not often. That rules out
     * Bitfinex and Gemini outright.
     *
     * **Bitstamp is the one that got away**, and it is worth saying why rather than
     * leaving it looking like an oversight. Its order book is fast enough — faster
     * than either of these — but it costs 45KB a second, because every update
     * carries a hundred levels a side to read two numbers off the top, and under
     * `URLSessionWebSocketTask` the connection dies with `EPROTO` about a second
     * after every connect. The same stream runs for twenty minutes without a hiccup
     * from a Node client, so it is a framing incompatibility on this side rather
     * than anything Bitstamp is doing wrong, and chasing it further was not worth it
     * for a third opinion. It was tried as a standby, connected only while a primary
     * was missing, and the reconnect churn was worse than the robustness it bought.
     *
     * So: two venues, both quote-driven, both quoting real dollars — which is what
     * rules out the deeper USDT books, since the peg wanders a few basis points
     * against the dollar and this is a measurement that matters to single ones.
     * Two is not a median, and `sample` says so and guards it a different way.
     */

    var label: String {
        switch self {
        case .coinbase: return "Coinbase"
        case .kraken:   return "Kraken"
        }
    }

    var url: URL {
        switch self {
        case .coinbase: return URL(string: "wss://ws-feed.exchange.coinbase.com")!
        case .kraken:   return URL(string: "wss://ws.kraken.com/v2")!
        }
    }

    /// The frame that has to go up before anything comes down.
    var subscribe: String {
        switch self {
        case .coinbase:
            return #"{"type":"subscribe","product_ids":["BTC-USD"],"channels":["ticker"]}"#
        case .kraken:
            // `event_trigger: bbo` is the load-bearing clause — see the note above.
            // Without it this channel fires on trades and goes ten seconds between
            // prints, which is how it spent the first live probe out of the tape.
            return #"{"method":"subscribe","params":{"channel":"ticker","symbol":["BTC/USD"],"event_trigger":"bbo"}}"#
        }
    }

    /**
     * The price out of one frame, or nil if the frame was not a price.
     *
     * Most frames are not: subscription acknowledgements, heartbeats, status
     * payloads and, on Kraken, a snapshot that arrives before the updates do. All of
     * those return nil and are dropped, which is why this returns an optional rather
     * than throwing — a heartbeat is not an error.
     */
    func price(from text: String) -> Double? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }

        switch self {
        case .coinbase:
            guard let json = any as? [String: Any],
                  json["type"] as? String == "ticker" else { return nil }
            // Coinbase quotes numbers as strings throughout. Reading it as a Double
            // returns nil silently and the venue looks dead rather than misparsed.
            return (json["price"] as? String).flatMap(Double.init)

        case .kraken:
            guard let json = any as? [String: Any],
                  json["channel"] as? String == "ticker",
                  let rows = json["data"] as? [[String: Any]],
                  let last = rows.first?["last"] as? Double else { return nil }
            return last

        }
    }
}

/// The last thing one venue said, and when.
struct VenueTick: Codable {
    let venue: BtcVenue
    let price: Double
    let at: Double
}

/* ----------------------------------------------------------- the consolidated */

/// What the venues collectively said at one instant, with enough detail to judge
/// whether they were agreeing.
struct ConsolidatedTick: Codable {
    let at: Double
    /// The median across venues that had printed recently. This is the price.
    let price: Double
    /// How many venues were fresh enough to count.
    let venues: Int
    /// High minus low across those venues, in basis points of the median. A live
    /// dispersion reading: when this is wide, one venue is printing badly and the
    /// median is the only reason the tape is not.
    let spreadBps: Double
    /// True when no venue was fresh and this came from the Yahoo fallback.
    let degraded: Bool
}

/**
 * How the live tape is doing, for the screen and for the decision.
 *
 * The desk needs to know this and so does the reader: a run that quietly fell back
 * to a ten-second Yahoo poll halfway through is running a different strategy from
 * the one that was started, and the difference is exactly the eleven basis points
 * that make the model inaudible.
 */
struct FeedHealth: Codable {
    let connected: [BtcVenue]
    let stale: [BtcVenue]
    /// Consolidated samples taken in the last minute. At full health this is 60.
    let samplesPerMinute: Int
    /// Median venue dispersion over the last minute, in basis points.
    let dispersionBps: Double
    let degraded: Bool
    let summary: String

    static func offline() -> FeedHealth {
        FeedHealth(
            connected: [], stale: BtcVenue.allCases, samplesPerMinute: 0,
            dispersionBps: 0, degraded: true,
            summary: "The live exchange feed is not running. Prices are coming from Yahoo's "
                + "polled spot endpoint, which is the feed the resolver gap was measured against — "
                + "expect the model to have very little voice against the market until it reconnects.")
    }
}

/* ------------------------------------------------------------------ the feed */

/**
 * Three sockets, one median, sampled once a second.
 *
 * **Why one second rather than every print.** Bitcoin prints hundreds of trades a
 * second across three venues and the question being answered is a five-minute
 * time-weighted average. Storing every print would put a hundred thousand points
 * in a window to compute a number that three hundred resolve to the same value, and
 * would weight the busy seconds more heavily than the quiet ones — which is exactly
 * the bias a *time*-weighted average exists to avoid. So the sampler ticks on a
 * clock, not on the trades: each second records what the median was at that second,
 * and the step integral in `BtcTape.twap` then weights every second equally, which
 * is what the market's own definition does.
 *
 * **Why the desk drains rather than the feed pushing.** The desk is an actor and
 * so is this; a push would mean a cross-actor hop per sample, sixty a minute, to
 * deliver data that is only read when a decision is made. The desk takes everything
 * new on each tick instead, in one hop, and the tape ends up identical.
 */
actor BtcLiveFeed {
    static let shared = BtcLiveFeed()

    /**
     * A venue's print is worth counting for this long.
     *
     * Ten seconds, which is roughly ten times the p95 gap measured on both primary
     * streams and four times the worst gap seen. The first cut used two seconds, on
     * the reasoning that these books trade constantly — and the live probe showed
     * both non-Coinbase venues falling out of the median on a calm Sunday, because
     * they do not.
     *
     * The margin is affordable because **staleness and volatility are
     * anti-correlated**: a venue goes quiet precisely when nothing is happening, and
     * when the price is actually moving every one of these streams prints several
     * times a second. The case the margin does not cover — a venue that hangs
     * *during* a move, and so is stale and wrong at once — is caught by the outlier
     * check in `sample` rather than by the freshness window, which is the right
     * place for it.
     */
    private static let freshnessMs: Double = 10_000

    /// How far a venue may sit from the last consolidated price before it is treated
    /// as a bad print rather than news, when there is no third venue to outvote it.
    /// Generous on purpose: a real move takes both venues with it, so both deviate
    /// together and neither is dropped. Only a venue moving *alone* trips this.
    private static let outlierBps: Double = 30

    /**
     * Sockets close if nobody has taken a sample for this long.
     *
     * The feed is opened by a run and also by simply looking at the Predict tab,
     * because the chart there is worth drawing at one-second resolution before
     * anything is committed. A run closes it when it ends; a tab does not — the
     * browser just stops polling, silently, and there is no event for "stopped
     * looking". So the feed notices on its own: the desk drains it on every tick and
     * the panel drains it on every read, and three minutes without either means
     * nobody is listening.
     */
    private static let idleTimeoutMs: Double = 180_000



    /// One second between consolidated samples. See the note above.
    private static let sampleIntervalNs: UInt64 = 1_000_000_000

    /// Two hours, matching `BtcTape`'s own retention, so nothing is kept here that
    /// the tape would have dropped anyway.
    private static let retentionMs: Double = 2 * 3600 * 1000

    private var sockets: [BtcVenue: URLSessionWebSocketTask] = [:]
    private var readers: [BtcVenue: Task<Void, Never>] = [:]
    private var latest: [BtcVenue: VenueTick] = [:]
    private var sampler: Task<Void, Never>?

    /// Consolidated samples not yet handed to the desk. Drained, not copied, so a
    /// long-running desk does not re-absorb the same second sixty times.
    private var pending: [ConsolidatedTick] = []
    /// A short trailing record kept past the drain, purely so `health()` can say
    /// how many samples a minute are actually arriving.
    private var recent: [ConsolidatedTick] = []

    private var running = false
    /// When Yahoo was last used to cover a gap, so the fallback is not hammered on
    /// every sample while the sockets are down.
    private var lastFallbackAt: Double = 0
    /// When anyone last took the samples. See `idleTimeoutMs`.
    private var lastDrainAt: Double = 0


    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /* ------------------------------------------------------------- lifecycle */

    /// Opens every socket and starts the sampler. Safe to call repeatedly — a run
    /// opening while another is already live must not tear down its feed.
    func start() {
        lastDrainAt = nowMs()
        guard !running else { return }
        running = true
        for venue in BtcVenue.allCases { connect(venue) }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BtcLiveFeed.sampleIntervalNs)
                guard let self else { return }
                await self.sample()
            }
        }
        log("[predict] live feed: opening \(BtcVenue.allCases.map(\.label).joined(separator: ", "))")
    }

    /// Closes everything. Called when the last run ends, because three open sockets
    /// for a tab nobody is looking at is rude to three public endpoints.
    func stop() {
        running = false
        sampler?.cancel()
        sampler = nil
        for (venue, task) in readers { task.cancel(); readers[venue] = nil }
        for (venue, socket) in sockets {
            socket.cancel(with: .goingAway, reason: nil)
            sockets[venue] = nil
        }
        latest.removeAll()
        pending.removeAll()
        recent.removeAll()
    }

    private func connect(_ venue: BtcVenue) {
        readers[venue]?.cancel()
        sockets[venue]?.cancel(with: .goingAway, reason: nil)

        let socket = session.webSocketTask(with: venue.url)
        sockets[venue] = socket
        socket.resume()
        socket.send(.string(venue.subscribe)) { error in
            if let error { log("[predict] \(venue.label) subscribe failed: \(error.localizedDescription)", .warn, "predict") }
        }

        // The socket is handed to the reader rather than looked up inside it, so the
        // loop never has to re-enter the actor just to find out where to read from.
        readers[venue] = Task { [weak self] in
            await self?.read(venue, socket: socket)
        }
    }

    /**
     * One venue's receive loop.
     *
     * Reconnects on failure with a flat five-second wait rather than a backoff. The
     * usual argument for exponential backoff is protecting a server from a thundering
     * herd; there is one client here, the endpoints are public streaming feeds built
     * for persistent connections, and a run is thirty minutes long. A backoff that
     * reaches a two-minute wait during a run has effectively dropped the venue for
     * the rest of it, which costs more than the reconnects save.
     */
    private nonisolated func read(_ venue: BtcVenue, socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8)
                @unknown default:    text = nil
                }
                /* **Parsed here, off the actor, and that is not a micro-optimisation.**
                 *
                 * This loop was actor-isolated at first, which put a JSON parse of
                 * every frame inside the same serial queue as the one-second sampler,
                 * the desk's drains and the other venues' loops. Bitstamp's book
                 * channel sends five kilobytes nine times a second; parsing that on
                 * the actor meant `receive()` was not called again promptly, the
                 * socket's own buffer backed up, and URLSession killed the connection
                 * with a protocol error roughly a second after every connect. It
                 * reconnected, so the feed limped, and the reason was nowhere near the
                 * error message.
                 *
                 * So the frame is decoded on whatever thread delivered it and the
                 * actor is entered only to store a `Double`. */
                if let text, let price = venue.price(from: text), price > 0 {
                    await store(venue, price: price)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await reconnect(venue, after: error)
                return
            }
        }
    }

    private func store(_ venue: BtcVenue, price: Double) {
        if latest[venue] == nil { log("[predict] \(venue.label) live at \(f(price, 2))") }
        latest[venue] = VenueTick(venue: venue, price: price, at: nowMs())
    }

    /// Waits, then reopens — unless the feed has been stopped meanwhile, or this was
    /// the standby and the supervisor let it go while the wait was running.
    private func reconnect(_ venue: BtcVenue, after error: Error) async {
        guard running, sockets[venue] != nil else { return }
        let ns = error as NSError
        log("[predict] \(venue.label) dropped: \(error.localizedDescription) "
            + "[\(ns.domain) \(ns.code)] — reconnecting")
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        guard running, sockets[venue] != nil else { return }
        connect(venue)
    }

    /* --------------------------------------------------------- consolidation */

    /// Venues that have printed inside the freshness window, newest reading each.
    private func freshVenues(now: Double) -> [VenueTick] {
        latest.values
            .filter { now - $0.at <= BtcLiveFeed.freshnessMs }
            .sorted { $0.price < $1.price }
    }

    /**
     * One consolidated sample.
     *
     * The median of the fresh venues — the middle one of three, the mean of two,
     * the only one of one. Two is not a median and saying so in the code is worth
     * more than pretending the mean of two is robust: with two venues a bad print
     * moves the tape by half its error, and the `venues` count on every sample is
     * what lets the desk know that.
     */
    private func sample() {
        let now = nowMs()
        if now - lastDrainAt > BtcLiveFeed.idleTimeoutMs {
            log("[predict] live feed: nobody has read a sample in three minutes — closing")
            stop()
            return
        }
        var fresh = freshVenues(now: now)

        guard !fresh.isEmpty else {
            coverFromFallback(now: now)
            return
        }

        /* **Two venues are not a median**, and this is what stands in for one.
         *
         * The mean of two moves by half of whatever one of them got wrong, so a venue
         * that has wandered away from the last consolidated price *on its own* is
         * dropped for this sample and the other one carries it.
         *
         * The threshold is deliberately far wider than any real second-to-second
         * move, because a genuine move carries both venues with it: they deviate
         * together, the difference between their deviations stays small, and neither
         * trips. What trips is one venue moving while the other does not, which is
         * not news about Bitcoin. */
        if fresh.count == 2, let anchor = recent.last(where: { !$0.degraded })?.price, anchor > 0,
           now - (recent.last(where: { !$0.degraded })?.at ?? 0) < BtcLiveFeed.freshnessMs {
            let drift = fresh.map { abs($0.price - anchor) / anchor * 10_000 }
            if let worst = drift.max(), let best = drift.min(),
               worst - best > BtcLiveFeed.outlierBps {
                let keep = drift[0] < drift[1] ? fresh[0] : fresh[1]
                log("[predict] \(fresh[drift[0] < drift[1] ? 1 : 0].venue.label) printed "
                    + "\(f(worst - best, 1)) bps away from the tape on its own — dropped for this sample")
                fresh = [keep]
            }
        }

        let prices = fresh.map(\.price).sorted()
        let median: Double = prices.count % 2 == 1
            ? prices[prices.count / 2]
            : (prices[prices.count / 2 - 1] + prices[prices.count / 2]) / 2
        let spreadBps = median > 0 && prices.count > 1
            ? ((prices.last! - prices.first!) / median) * 10_000 : 0

        record(ConsolidatedTick(at: now, price: median, venues: prices.count,
                                spreadBps: spreadBps, degraded: false))
    }

    /**
     * Cover a socket outage from Yahoo, at most once every ten seconds.
     *
     * Marked `degraded` all the way through to the screen. This is the old feed and
     * it carries the old eleven-basis-point gap; a run that silently ran on it while
     * claiming to be live would be reporting a model weight it had not earned.
     */
    private func coverFromFallback(now: Double) {
        guard now - lastFallbackAt > 10_000 else { return }
        lastFallbackAt = now
        Task { [weak self] in
            guard let point = try? await BtcFeed.spot() else { return }
            await self?.record(ConsolidatedTick(at: point.t, price: point.p, venues: 0,
                                                spreadBps: 0, degraded: true))
        }
    }

    private func record(_ tick: ConsolidatedTick) {
        pending.append(tick)
        recent.append(tick)
        let floor = nowMs() - BtcLiveFeed.retentionMs
        if pending.count > 8_000 { pending.removeFirst(pending.count - 8_000) }
        recent.removeAll { $0.at < floor }
    }

    /* -------------------------------------------------------------- the drain */

    /// Everything sampled since the last call, as tape points, and empties the
    /// buffer. The desk calls this once per tick.
    func drain() -> [TapePoint] {
        lastDrainAt = nowMs()
        let out = pending.map { TapePoint(t: $0.at, p: $0.price) }
        pending.removeAll(keepingCapacity: true)
        return out
    }

    /// The price right now, without waiting for the next sample. Used for the
    /// panel's spot reading between ticks.
    func spot() -> Double? {
        let fresh = freshVenues(now: nowMs())
        guard !fresh.isEmpty else { return recent.last?.price }
        let prices = fresh.map(\.price)
        return prices.count % 2 == 1
            ? prices[prices.count / 2]
            : (prices[prices.count / 2 - 1] + prices[prices.count / 2]) / 2
    }

    /* ------------------------------------------------------------- the health */

    func health() -> FeedHealth {
        guard running else { return .offline() }
        let now = nowMs()
        let fresh = Set(freshVenues(now: now).map(\.venue))
        let connected = BtcVenue.allCases.filter { fresh.contains($0) }
        let stale = BtcVenue.allCases.filter { !fresh.contains($0) }

        let lastMinute = recent.filter { now - $0.at <= 60_000 }
        let live = lastMinute.filter { !$0.degraded }
        let dispersions = live.map(\.spreadBps).sorted()
        let dispersion = dispersions.isEmpty ? 0 : dispersions[dispersions.count / 2]
        // Degraded the moment the median stops being a median. With one venue there
        // is nothing to be robust against, which is materially the old situation.
        let degraded = connected.count < 2

        var summary: String
        if connected.isEmpty {
            summary = "No exchange is reachable, so the tape is falling back to Yahoo's polled spot price — "
                + "the feed the resolver gap was measured against. The model will have almost no voice against the market until this recovers."
        } else {
            summary = "\(connected.map(\.label).joined(separator: ", ")) live at "
                + "\(live.count) samples a minute, \(f(dispersion, 1)) bps apart. "
            if stale.isEmpty {
                summary += "Both venues reporting, and neither has wandered from the other."
            } else {
                summary += "\(stale.map(\.label).joined(separator: " and ")) is out, so this is one exchange rather than a consolidated price — "
                    + "there is nothing left to outvote a bad print, and the cross-venue check that normally catches one has nothing to check against."
            }
        }

        return FeedHealth(
            connected: connected, stale: stale,
            samplesPerMinute: live.count, dispersionBps: dispersion,
            degraded: degraded, summary: summary)
    }
}
