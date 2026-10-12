/**
 * Analysis.swift — turns bars into a read, and a read into a trade plan.
 *
 * This is the part that has to be right whether or not a Claude key is present.
 * Claude explains and ranks; the numbers here decide what is even eligible, and
 * every level a recommendation quotes — entry, target, stop, size — is computed
 * from the instrument's own volatility rather than picked to sound good.
 *
 * The doctrine, in one line: risk a fixed slice of the account, place the stop
 * where the thesis is wrong, and only take the trade if the target is far enough
 * past the stop to pay for being wrong more than half the time.
 */

import Foundation

enum Analysis {

    /* ------------------------------------------------------------ primitives */

    static func sma(_ values: [Double], _ period: Int) -> Double? {
        guard values.count >= period, period > 0 else { return nil }
        var sum = 0.0
        for i in (values.count - period)..<values.count { sum += values[i] }
        return sum / Double(period)
    }

    /// Wilder's RSI. Above 70 is stretched, below 30 is washed out — neither is a signal alone.
    static func rsi(_ closes: [Double], _ period: Int = 14) -> Double? {
        guard closes.count >= period + 1 else { return nil }
        var gain = 0.0
        var loss = 0.0
        for i in 1...period {
            let d = closes[i] - closes[i - 1]
            if d >= 0 { gain += d } else { loss -= d }
        }
        gain /= Double(period)
        loss /= Double(period)
        if closes.count > period + 1 {
            for i in (period + 1)..<closes.count {
                let d = closes[i] - closes[i - 1]
                gain = (gain * Double(period - 1) + max(d, 0)) / Double(period)
                loss = (loss * Double(period - 1) + max(-d, 0)) / Double(period)
            }
        }
        if loss == 0 { return 100 }
        let rs = gain / loss
        return 100 - 100 / (1 + rs)
    }

    /**
     * Average True Range — the instrument's normal daily travel, gaps included.
     * Every stop and target downstream is denominated in this, which is the whole
     * reason a 3% stop on Tesla and a 3% stop on Walmart are not the same trade.
     */
    static func atr(_ bars: [Bar], _ period: Int = 14) -> Double? {
        guard bars.count >= period + 1 else { return nil }
        var trs: [Double] = []
        trs.reserveCapacity(bars.count - 1)
        for i in 1..<bars.count {
            let b = bars[i]
            let prevClose = bars[i - 1].c
            trs.append(max(b.h - b.l, abs(b.h - prevClose), abs(b.l - prevClose)))
        }
        var acc = 0.0
        for i in 0..<period { acc += trs[i] }
        var val = acc / Double(period)
        if trs.count > period {
            for i in period..<trs.count {
                val = (val * Double(period - 1) + trs[i]) / Double(period)
            }
        }
        return val
    }

    /// Annualised realised volatility from daily log returns.
    static func realisedVol(_ closes: [Double], _ symbol: String, _ lookback: Int = 30) -> Double? {
        guard closes.count >= lookback + 1 else { return nil }
        var rets: [Double] = []
        for i in (closes.count - lookback)..<closes.count {
            rets.append(log(closes[i] / closes[i - 1]))
        }
        let mean = rets.reduce(0, +) / Double(rets.count)
        let variance = rets.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rets.count - 1)
        return variance.squareRoot() * Universe.periodsPerYear(symbol).squareRoot() * 100
    }

    static func pctChange(_ closes: [Double], _ back: Int) -> Double? {
        guard closes.count > back else { return nil }
        let then = closes[closes.count - 1 - back]
        let now = closes[closes.count - 1]
        return then != 0 ? ((now - then) / then) * 100 : nil
    }

    /// Maximum peak-to-trough loss over the window, as a positive percentage.
    static func maxDrawdown(_ closes: [Double]) -> Double {
        var peak = closes.first ?? 0
        var worst = 0.0
        for c in closes {
            if c > peak { peak = c }
            if peak > 0 { worst = min(worst, (c - peak) / peak) }
        }
        return abs(worst) * 100
    }

    /**
     * Swing pivots: bars that are the highest (or lowest) point within `width` bars
     * either side. These are the levels a chart actually respects, as opposed to
     * round numbers, which it respects only by coincidence.
     */
    static func pivots(_ bars: [Bar], _ width: Int = 5) -> (highs: [Double], lows: [Double]) {
        var highs: [Double] = []
        var lows: [Double] = []
        guard bars.count > width * 2 else { return (highs, lows) }
        for i in width..<(bars.count - width) {
            var isHigh = true
            var isLow = true
            for j in (i - width)...(i + width) where j != i {
                if bars[j].h >= bars[i].h { isHigh = false }
                if bars[j].l <= bars[i].l { isLow = false }
            }
            if isHigh { highs.append(bars[i].h) }
            if isLow { lows.append(bars[i].l) }
        }
        return (highs, lows)
    }

    /* -------------------------------------------------------------- the read */

    enum Regime: String, Codable {
        case strongUptrend = "strong-uptrend"
        case uptrend
        case range
        case downtrend
        case strongDowntrend = "strong-downtrend"
    }

    /**
     * The six axes a read is built from, kept separate so the interface can show
     * *which* leg of a case is weak rather than one opaque number — and so the
     * weighting can change with what the trade is for.
     *
     * `range` and `durability` are the two that were missing, and their absence is
     * why every shortlist looked the same. A day trade needs an instrument that
     * actually moves far enough in a session to pay for the spread; a position held
     * for two years needs one that survives being held. Those are close to opposite
     * requirements, and a single fixed formula answers neither.
     */
    struct Scores: Codable {
        let trend: Double
        let momentum: Double
        let entry: Double
        let risk: Double
        /// Whether there is enough daily movement to trade quickly. High is good for
        /// a fast horizon and irrelevant to a slow one.
        let range: Double
        /// Whether this would survive being held through a bad year.
        let durability: Double

        init(trend: Double, momentum: Double, entry: Double, risk: Double,
             range: Double = 50, durability: Double = 50) {
            self.trend = trend; self.momentum = momentum
            self.entry = entry; self.risk = risk
            self.range = range; self.durability = durability
        }

        /// Decoded leniently so a cache written before the two new axes existed
        /// still reads rather than throwing the whole analysis away.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trend = try c.decodeIfPresent(Double.self, forKey: .trend) ?? 50
            momentum = try c.decodeIfPresent(Double.self, forKey: .momentum) ?? 50
            entry = try c.decodeIfPresent(Double.self, forKey: .entry) ?? 50
            risk = try c.decodeIfPresent(Double.self, forKey: .risk) ?? 50
            range = try c.decodeIfPresent(Double.self, forKey: .range) ?? 50
            durability = try c.decodeIfPresent(Double.self, forKey: .durability) ?? 50
        }
    }

    /**
     * How much each axis counts, for what this trade is actually for.
     *
     * These are the weights that make the same board produce four different
     * shortlists. Read down a column and you can see the argument: an intraday read
     * barely cares where the 200-day sits and cares enormously whether the thing
     * moves; a long-term read inverts both and adds survivability, which nothing
     * shorter looks at.
     *
     * Every row sums to 1, which is asserted in the self-test rather than trusted.
     */
    struct AxisWeights {
        let trend: Double
        let momentum: Double
        let entry: Double
        let risk: Double
        let range: Double
        let durability: Double

        var sum: Double { trend + momentum + entry + risk + range + durability }

        func score(_ s: Scores) -> Double {
            clamp(s.trend * trend + s.momentum * momentum + s.entry * entry
                  + s.risk * risk + s.range * range + s.durability * durability)
        }

        static func of(_ style: TimeHorizon) -> AxisWeights {
            switch style {
            // Fast money is paid for movement and for timing, and a 200-day average
            // is not going to resolve inside the trade.
            case .intraday:
                return .init(trend: 0.10, momentum: 0.28, entry: 0.26, risk: 0.06, range: 0.30, durability: 0)
            // Close to the weighting this engine always used, with room made for the
            // range axis. A swing trade wants a trend and a good price in it.
            case .swing:
                return .init(trend: 0.26, momentum: 0.26, entry: 0.24, risk: 0.10, range: 0.14, durability: 0)
            case .position:
                return .init(trend: 0.34, momentum: 0.20, entry: 0.18, risk: 0.12, range: 0.04, durability: 0.12)
            // Over years the entry price stops mattering much and whether the thing
            // survives starts mattering more than anything else.
            case .longTerm:
                return .init(trend: 0.32, momentum: 0.08, entry: 0.10, risk: 0.08, range: 0, durability: 0.42)
            }
        }
    }

    struct Metrics: Codable {
        let symbol: String
        let price: Double
        let sma20: Double?
        let sma50: Double?
        let sma200: Double?
        let rsi14: Double?
        let atr14: Double?
        let atrPct: Double?
        let vol30: Double?
        let ret1d: Double?
        let ret5d: Double?
        let ret1mo: Double?
        let ret3mo: Double?
        let ret6mo: Double?
        let ret1y: Double?
        let drawdown1y: Double
        let fromHigh52: Double?
        let fromLow52: Double?
        let volumeTrend: Double?
        let support: Double?
        let resistance: Double?
        let regime: Regime
        /// 0–100, weighted for the style this read was computed for. Not a price
        /// target, and not comparable across styles: an 80 for a day trade and an 80
        /// for a ten-year hold are answers to different questions.
        let conviction: Double
        let scores: Scores
        let bars: Int
        /// The horizon this read was weighted for. Carried so nothing downstream has
        /// to guess which question the conviction figure answers.
        let style: String

        init(symbol: String, price: Double, sma20: Double?, sma50: Double?, sma200: Double?,
             rsi14: Double?, atr14: Double?, atrPct: Double?, vol30: Double?,
             ret1d: Double?, ret5d: Double?, ret1mo: Double?, ret3mo: Double?,
             ret6mo: Double?, ret1y: Double?, drawdown1y: Double,
             fromHigh52: Double?, fromLow52: Double?, volumeTrend: Double?,
             support: Double?, resistance: Double?, regime: Regime,
             conviction: Double, scores: Scores, bars: Int, style: String) {
            self.symbol = symbol; self.price = price
            self.sma20 = sma20; self.sma50 = sma50; self.sma200 = sma200
            self.rsi14 = rsi14; self.atr14 = atr14; self.atrPct = atrPct; self.vol30 = vol30
            self.ret1d = ret1d; self.ret5d = ret5d; self.ret1mo = ret1mo
            self.ret3mo = ret3mo; self.ret6mo = ret6mo; self.ret1y = ret1y
            self.drawdown1y = drawdown1y
            self.fromHigh52 = fromHigh52; self.fromLow52 = fromLow52
            self.volumeTrend = volumeTrend
            self.support = support; self.resistance = resistance
            self.regime = regime; self.conviction = conviction
            self.scores = scores; self.bars = bars; self.style = style
        }

        /// Lenient for the same reason `Scores` is: this is written into a cache, and
        /// a cache from yesterday's build should reopen rather than be discarded.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try c.decode(String.self, forKey: .symbol)
            price = try c.decode(Double.self, forKey: .price)
            sma20 = try c.decodeIfPresent(Double.self, forKey: .sma20)
            sma50 = try c.decodeIfPresent(Double.self, forKey: .sma50)
            sma200 = try c.decodeIfPresent(Double.self, forKey: .sma200)
            rsi14 = try c.decodeIfPresent(Double.self, forKey: .rsi14)
            atr14 = try c.decodeIfPresent(Double.self, forKey: .atr14)
            atrPct = try c.decodeIfPresent(Double.self, forKey: .atrPct)
            vol30 = try c.decodeIfPresent(Double.self, forKey: .vol30)
            ret1d = try c.decodeIfPresent(Double.self, forKey: .ret1d)
            ret5d = try c.decodeIfPresent(Double.self, forKey: .ret5d)
            ret1mo = try c.decodeIfPresent(Double.self, forKey: .ret1mo)
            ret3mo = try c.decodeIfPresent(Double.self, forKey: .ret3mo)
            ret6mo = try c.decodeIfPresent(Double.self, forKey: .ret6mo)
            ret1y = try c.decodeIfPresent(Double.self, forKey: .ret1y)
            drawdown1y = try c.decodeIfPresent(Double.self, forKey: .drawdown1y) ?? 0
            fromHigh52 = try c.decodeIfPresent(Double.self, forKey: .fromHigh52)
            fromLow52 = try c.decodeIfPresent(Double.self, forKey: .fromLow52)
            volumeTrend = try c.decodeIfPresent(Double.self, forKey: .volumeTrend)
            support = try c.decodeIfPresent(Double.self, forKey: .support)
            resistance = try c.decodeIfPresent(Double.self, forKey: .resistance)
            regime = try c.decodeIfPresent(Regime.self, forKey: .regime) ?? .range
            conviction = try c.decodeIfPresent(Double.self, forKey: .conviction) ?? 50
            scores = try c.decodeIfPresent(Scores.self, forKey: .scores)
                ?? Scores(trend: 50, momentum: 50, entry: 50, risk: 50)
            bars = try c.decodeIfPresent(Int.self, forKey: .bars) ?? 0
            style = try c.decodeIfPresent(String.self, forKey: .style) ?? TimeHorizon.swing.rawValue
        }
    }

    static func clamp(_ n: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double {
        Swift.max(lo, Swift.min(hi, n))
    }

    private static func classifyRegime(
        price: Double,
        s20: Double?, s50: Double?, s200: Double?,
        slope: Double,
        atrVal: Double?
    ) -> Regime {
        // The moving-average stack says direction; the 50-day slope says conviction.
        let above20 = s20 != nil && price > s20!
        let above50 = s50 != nil && price > s50!
        let above200 = s200 != nil && price > s200!
        let stacked = s20 != nil && s50 != nil && s200 != nil && s20! > s50! && s50! > s200!
        let inverted = s20 != nil && s50 != nil && s200 != nil && s20! < s50! && s50! < s200!

        /* Before any direction is called, the averages have to actually be apart.
         * Measured in ATR, like every other distance in this engine: if the 50- and
         * 200-day sit within half a day's range of each other, price is simply
         * oscillating around them, and which side it closed on is noise. Without this
         * test a flat chop reads as a downtrend, which then widens stops and suppresses
         * setups on a market that is not going anywhere. */
        var separation = 0.0
        if let s50, let s200, let a = atrVal, a != 0 { separation = abs(s50 - s200) / a }
        if separation < 0.5 { return .range }

        let FLAT = 0.02 // percent per session — a dead zone around a flat 50-day

        if stacked && above20 && slope > 0.12 { return .strongUptrend }
        if above50 && above200 && slope > FLAT { return .uptrend }
        if inverted && !above20 && slope < -0.12 { return .strongDowntrend }
        if !above50 && !above200 && slope < -FLAT { return .downtrend }
        return .range
    }

    /**
     * Read an instrument, for a particular kind of trade.
     *
     * `style` is not decoration and it is not only a weighting. It moves the
     * momentum window (five days for a day trade, a year for a long hold), the
     * moving average an entry is judged as stretched against, and how euphoric an
     * RSI has to get before it disqualifies rather than confirms. Two of those
     * change which instruments come out on top, not merely their order.
     *
     * It defaults to `.swing`, which reproduces what this engine always did.
     */
    static func analyse(_ symbol: String, _ bars: [Bar], livePrice: Double? = nil,
                        style: TimeHorizon = .swing) -> Metrics {
        let closes = bars.map(\.c)
        let price = livePrice ?? closes[closes.count - 1]
        let s20 = sma(closes, 20)
        let s50 = sma(closes, 50)
        let s200 = sma(closes, 200)
        let a14 = atr(bars, 14)
        let atrPct: Double? = (a14 != nil && price != 0) ? (a14! / price) * 100 : nil

        // Slope of the 50-day average over the last 20 sessions, in percent per session.
        var slope = 0.0
        if closes.count >= 70 {
            let prev50 = sma(Array(closes[0..<(closes.count - 20)]), 50)
            if let prev50, let s50, prev50 != 0 { slope = ((s50 - prev50) / prev50) * 100 / 20 }
        }

        let yearWindow = Swift.min(bars.count, Universe.isCrypto(symbol) ? 365 : 252)
        let yearBars = Array(bars.suffix(yearWindow))
        let hi52 = yearBars.map(\.h).max() ?? 0
        let lo52 = yearBars.map(\.l).min() ?? 0

        let (highs, lows) = pivots(Array(bars.suffix(120)), 5)
        // Overhead supply that actually matters is the first pivot *meaningfully* above
        // price. In an uptrend the nearest pivot high is usually a level price has
        // already broken and retested, and treating that as a ceiling makes every trend
        // trade look like it has nowhere left to go. One ATR of clearance is the filter.
        let clearance = a14 ?? price * 0.02
        let resistance: Double? = highs.filter { $0 > price + clearance }.sorted().first
            ?? (hi52 > price + clearance ? hi52 : nil)
        let support: Double? = lows.filter { $0 < price }.sorted(by: >).first
            ?? (lo52 < price ? lo52 : nil)

        let recentVol = sma(bars.suffix(20).map(\.v), 20)
        let baseVol = sma(bars.suffix(60).map(\.v), 60)
        var volumeTrend: Double?
        if let recentVol, let baseVol, baseVol != 0 { volumeTrend = (recentVol / baseVol - 1) * 100 }

        let regime = classifyRegime(price: price, s20: s20, s50: s50, s200: s200, slope: slope, atrVal: a14)
        let r14 = rsi(closes, 14)
        // Hoisted out of the return so the durability axis can read it. Annualised
        // realised volatility is the cleanest single answer to "how rough was
        // holding this", which is the question a long horizon is actually asking.
        let vol30Value = realisedVol(closes, symbol, 30)

        /* --- scoring ---------------------------------------------------------
         * Six axes, deliberately kept separate so the interface can show a user
         * *which* leg of the case is weak rather than one opaque number — and so
         * the weighting can follow what the trade is for. The axes themselves are
         * computed the same way every time; only the emphasis moves.
         */
        var trend = 50.0
        if let s200 { trend += price > s200 ? 15 : -15 }
        if let s50 { trend += price > s50 ? 10 : -10 }
        if let s20 { trend += price > s20 ? 8 : -8 }
        if let s20, let s50 { trend += s20 > s50 ? 7 : -7 }
        trend += clamp(slope * 40, -10, 10)
        trend = clamp(trend)

        /* Momentum, over the window the trade will actually live in.
         *
         * This is the change that most moves *which* names surface rather than
         * their order. A stock up 40% over the year and flat for a fortnight scores
         * well for a long hold and badly for a swing; a stock up 6% this week off a
         * flat year is the reverse. One fixed blend of 21/63/5 days answered neither
         * question and returned the same middle-of-the-road names to both. */
        let windows: [(back: Int, weight: Double)] = {
            switch style {
            case .intraday:  return [(2, 0.7), (5, 1.1), (10, 0.5)]
            case .swing:     return [(5, 0.4), (21, 0.8), (63, 0.35)]
            case .position:  return [(21, 0.5), (63, 0.6), (126, 0.3)]
            case .longTerm:  return [(63, 0.22), (126, 0.26), (252, 0.16)]
            }
        }()
        var mom = 50.0
        for w in windows { mom += (pctChange(closes, w.back) ?? 0) * w.weight }
        mom = clamp(mom)

        /* Entry quality: buying strength is fine, buying *euphoria* is not.
         *
         * "Stretched" is measured against the average the horizon actually trades
         * around. Two percent above the 20-day is late for a day trade and
         * irrelevant to a position held for a year, which is judged against the
         * 200-day instead. */
        let anchor: Double? = {
            switch style {
            case .intraday: return sma(closes, 10)
            case .swing:    return s20
            case .position: return s50
            case .longTerm: return s200 ?? s50
            }
        }()
        // How hard being far from the anchor is punished, and how hot an RSI has to
        // get to disqualify. A fast trade is allowed to buy a hot tape; a slow one
        // has no reason to pay up.
        let (stretchPenalty, hotRSI): (Double, Double) = {
            switch style {
            case .intraday: return (2.6, 78)
            case .swing:    return (1.8, 72)
            case .position: return (1.2, 70)
            case .longTerm: return (0.5, 68)
            }
        }()

        var entry = 50.0
        if let r14 {
            if r14 >= 45 && r14 <= 65 { entry += 20 }
            else if r14 > 65 && r14 <= hotRSI { entry += 5 }
            else if r14 > hotRSI { entry -= 25 }
            else if r14 < 30 { entry += 10 } // washed out: good risk, needs a turn to confirm
            else { entry += 8 }
        }
        if let anchor, price > 0, anchor != 0 {
            let stretch = ((price - anchor) / anchor) * 100
            entry -= clamp(abs(stretch) * stretchPenalty, 0, 28) // far from the mean = late
        }
        entry = clamp(entry)

        // Risk: high vol and deep drawdowns are not disqualifying, they are expensive.
        let dd = maxDrawdown(Array(closes.suffix(252)))
        var risk = 50.0
        if let atrPct { risk -= clamp((atrPct - 2) * 8, -15, 30) }
        risk -= clamp((dd - 25) * 0.5, -10, 25)
        risk = clamp(risk)

        /* Range: is there enough movement here to trade quickly at all?
         *
         * The axis the board was missing, and the reason low-volatility mega-caps
         * used to win every shortlist including the day-trading one. An instrument
         * that travels 0.6% on an average day offers a day trader nothing: the
         * spread and the commission consume the whole move before the idea has been
         * right or wrong. Above roughly 7% the opposite problem — a position sized
         * to survive the noise is too small to matter, and the stop is a coin toss.
         * So this peaks in the middle and falls away at both ends. */
        var range = 50.0
        if let atrPct {
            let ideal = 3.2
            let distance = abs(atrPct - ideal)
            range = 50 + 34 - clamp(distance * 11, 0, 60)
            if atrPct < 1.0 { range -= (1.0 - atrPct) * 30 }  // too quiet to pay for the spread
        } else {
            range = 40
        }
        // Participation confirms the movement is real rather than a thin-tape artefact.
        if let volumeTrend { range += clamp(volumeTrend * 0.25, -8, 8) }
        range = clamp(range)

        /* Durability: would this have survived being held?
         *
         * Only a long horizon asks. It is the difference between an instrument that
         * fell 22% at its worst and recovered and one that fell 70% and has not,
         * and no momentum or entry figure distinguishes them — both can be above
         * their 50-day this morning. */
        var durability = 50.0
        durability -= clamp((dd - 20) * 0.9, -12, 34)
        if let v = vol30Value { durability -= clamp((v - 28) * 0.45, -10, 24) }
        if let s200 { durability += price > s200 ? 12 : -14 }
        if let y = pctChange(closes, Universe.isCrypto(symbol) ? 365 : 252) {
            durability += clamp(y * 0.18, -14, 16)
        }
        // A short history is not a virtue when the question is what happens over
        // years. Under two years of bars there is not enough record to answer it.
        if bars.count < 400 { durability -= 8 }
        durability = clamp(durability)

        let scores = Scores(trend: trend, momentum: mom, entry: entry,
                            risk: risk, range: range, durability: durability)
        let conviction = AxisWeights.of(style).score(scores)

        return Metrics(
            symbol: symbol,
            price: price,
            sma20: s20, sma50: s50, sma200: s200,
            rsi14: r14,
            atr14: a14,
            atrPct: atrPct,
            vol30: vol30Value,
            ret1d: pctChange(closes, 1),
            ret5d: pctChange(closes, 5),
            ret1mo: pctChange(closes, 21),
            ret3mo: pctChange(closes, 63),
            ret6mo: pctChange(closes, 126),
            ret1y: pctChange(closes, Universe.isCrypto(symbol) ? 365 : 252),
            drawdown1y: dd,
            fromHigh52: hi52 != 0 ? ((price - hi52) / hi52) * 100 : nil,
            fromLow52: lo52 != 0 ? ((price - lo52) / lo52) * 100 : nil,
            volumeTrend: volumeTrend,
            support: support,
            resistance: resistance,
            regime: regime,
            conviction: conviction,
            scores: scores,
            bars: bars.count,
            style: style.rawValue
        )
    }

    /* ---------------------------------------------------------- the trade plan */

    enum Side: String, Codable { case long, avoid }
    enum EntryKind: String, Codable { case market, pullback }
    enum SizedBy: String, Codable { case risk, concentration }

    struct TradePlan: Codable {
        let symbol: String
        let side: Side
        let entry: Double
        let entryKind: EntryKind
        /// True when the default trend stop was pulled in to make the ratio work.
        let tightStop: Bool
        let target: Double
        let stop: Double
        let targetPct: Double
        let stopPct: Double
        /// Reward divided by risk. Below 1.5 and the plan is rejected outright.
        let rr: Double
        /// The risk the rules allowed for this trade — the intended budget.
        let riskBudget: Double
        /// What is actually at risk once sizing is done. Lower than the budget whenever
        /// the concentration cap binds, which it does on low-volatility names.
        let riskTaken: Double
        /// Which rule ended up deciding the size.
        let sizedBy: SizedBy
        let shares: Double
        let cost: Double
        let horizonDays: Double
        /// Break-even win rate implied by the R:R. Teaches why R:R matters more than accuracy.
        let breakevenWinRate: Double
        let rejected: String?
    }

    /**
     * The rules a plan is built under.
     *
     * The first three are the classic sizing inputs. The rest are the profile
     * speaking: how wide a stop this person's horizon can afford, how much reward
     * their objective demands for a given risk, how much daily movement they will
     * tolerate, and how long a trade may take before it is simply the wrong trade
     * for them however good the setup is. The defaults are neutral, so a plan built
     * without a profile behaves exactly as it always did.
     */
    struct SizingRules {
        let equity: Double
        /// Percent of equity to lose if the stop fills. 1% is the textbook default.
        /// Mutable because a learned calibration may scale it down — never up.
        var riskPctPerTrade: Double
        /// Hard ceiling on any single position as a share of equity.
        var maxPositionPct: Double

        var stopScale: Double = 1
        var targetScale: Double = 1
        var minRewardToRisk: Double = 1.5
        /// Refuse instruments whose average day moves more than this share of price.
        var maxDailyRangePct: Double?
        /// Sessions the trade is expected to need. Outside this band it is a
        /// different person's trade.
        var minSessions: Double?
        var maxSessions: Double?
        var horizonLabel: String = ""
        /**
         * Whether the first overhead level caps the target.
         *
         * True for every horizon that trades *to* a level, which is most of them: the
         * pivot where earlier buyers get back to break-even is where a move stalls,
         * and a target set past it is a target that does not get hit.
         *
         * False for a multi-year hold, and the difference is not cosmetic. Capping a
         * five-year target at a level three percent overhead produced a plan that
         * reached its target in six sessions, which the session band then refused as
         * too fast for the horizon — so the engine rejected two dozen perfectly good
         * long-term candidates for being good short-term ones. Over years the
         * relevant question is not which level is nearest; it is whether the trend
         * survives, and every pivot between here and there is expected to break.
         */
        var capTargetAtResistance: Bool = true

        init(equity: Double, riskPctPerTrade: Double, maxPositionPct: Double) {
            self.equity = equity
            self.riskPctPerTrade = riskPctPerTrade
            self.maxPositionPct = maxPositionPct
        }
    }

    static let defaultSizing = SizingRules(equity: 100_000, riskPctPerTrade: 1, maxPositionPct: 20)

    /**
     * Build the concrete "put $X into Y, exit at Z" plan.
     *
     * Stop distance scales with regime: a strong trend earns a wider stop because
     * pullbacks inside it are normal, while a range gets a tight one because there
     * is no trend to give it the benefit of the doubt. The stop is then pushed just
     * beneath the nearest real support, since a stop sitting inside an obvious level
     * is a donation.
     */
    static func buildPlan(_ m: Metrics, _ rules: SizingRules = Analysis.defaultSizing) -> TradePlan {
        let atrVal = m.atr14 ?? m.price * 0.02

        // The regime sets the shape; the profile's horizon scales it. An intraday
        // trader cannot afford to sit through a normal pullback, and a multi-year
        // holder cannot afford to be shaken out by one — same chart, different trade.
        let baseStop: Double = m.regime == .strongUptrend ? 2.6 : m.regime == .uptrend ? 2.2 : m.regime == .range ? 1.8 : 2.0
        let baseTarget: Double = m.regime == .strongUptrend ? 5.5 : m.regime == .uptrend ? 4.5 : m.regime == .range ? 3.0 : 3.0
        let stopMult = baseStop * rules.stopScale
        let targetMult = baseTarget * rules.targetScale

        // Entry: chase nothing. If price is stretched above the 20-day, wait for it.
        let stretch: Double = (m.sma20 != nil && m.sma20! != 0) ? ((m.price - m.sma20!) / m.sma20!) * 100 : 0
        let wantsPullback = stretch > 6 && (m.rsi14 ?? 50) > 68
        let entry = (wantsPullback && m.sma20 != nil) ? (m.price + m.sma20!) / 2 : m.price
        let entryKind: EntryKind = wantsPullback ? .pullback : .market

        var stop = entry - atrVal * stopMult
        if let support = m.support, support < entry, support > stop * 0.9 {
            stop = Swift.min(stop, support - atrVal * 0.35) // sit under the level, not on it
        }
        stop = Swift.max(stop, entry * 0.55) // never risk more than 45% on one idea

        var target = entry + atrVal * targetMult
        // Near the highs there is no overhead supply — nobody above is waiting to sell
        // at break-even — so a breakout keeps its full measured target. Otherwise the
        // first target sits just under the level where the move is likely to stall.
        let nearHighs = m.fromHigh52 != nil && m.fromHigh52! > -4
        if rules.capTargetAtResistance, !nearHighs,
           let resistance = m.resistance, resistance > entry + atrVal * 2 {
            target = Swift.min(target, resistance - atrVal * 0.3)
        }

        var riskPerShare = entry - stop
        var rewardPerShare = target - entry
        var rr = riskPerShare > 0 ? rewardPerShare / riskPerShare : 0

        /* A wide trend-following stop is the default, not a law. When a capped target
         * leaves the ratio too thin, ask the other question a trader would ask: how
         * tight would the stop have to be for this to be worth taking? If that stop is
         * still outside the instrument's daily noise, take the trade on the tighter
         * stop and say so. If it falls inside the noise, the trade genuinely is not
         * available — that is a real answer, and refusing it is the entire point. */
        var tightened = false
        let noiseFloor = atrVal * 1.2
        if rr > 0 && rr < rules.minRewardToRisk {
            let stopForRR = entry - rewardPerShare / (rules.minRewardToRisk * 1.2)
            if entry - stopForRR >= noiseFloor {
                stop = stopForRR
                tightened = true
                riskPerShare = entry - stop
                rewardPerShare = target - entry
                rr = rewardPerShare / riskPerShare
            }
        }

        let riskBudget = rules.equity * (rules.riskPctPerTrade / 100)
        var shares = riskPerShare > 0 ? riskBudget / riskPerShare : 0
        let maxCost = rules.equity * (rules.maxPositionPct / 100)
        var sizedBy: SizedBy = .risk
        if shares * entry > maxCost {
            // The concentration cap wins. On a low-volatility name with a tight stop the
            // risk maths alone would buy half the account, which is correct arithmetic
            // and a bad idea.
            shares = maxCost / entry
            sizedBy = .concentration
        }
        if !Universe.isCrypto(m.symbol) { shares = (shares * 10_000).rounded(.down) / 10_000 }

        // What is actually at stake after sizing — never the budget, which is only what
        // the rules would have allowed.
        let riskTaken = shares * riskPerShare

        let cost = shares * entry
        let dailyMove = m.atrPct ?? 2
        let horizonDays = Swift.max(3, ((rewardPerShare / entry) * 100 / Swift.max(dailyMove * 0.45, 0.2)).rounded())

        // Why the plan can be refused. A trainer that never says "no trade" teaches
        // the single most expensive habit in the market.
        var rejected: String?
        if rr < rules.minRewardToRisk {
            rejected = "Reward-to-risk is \(f(rr, 2)):1, against the \(f(rules.minRewardToRisk, 2)):1 this profile funds. Overhead supply caps the target, and pulling the stop in far enough to fix the ratio would put it inside \(m.symbol)'s daily noise, where an ordinary session would reach it."
        } else if m.regime == .strongDowntrend {
            rejected = "Price is below a falling 20/50/200 stack. Long setups in this regime fail more often than they pay."
        } else if (m.rsi14 ?? 50) > 80 {
            rejected = "RSI is \(f(m.rsi14 ?? 0, 0)). Entries this extended usually get a better price within days."
        } else if m.bars < 60 {
            rejected = "Not enough price history to size the risk."
        } else if let cap = rules.maxDailyRangePct, let atrPct = m.atrPct, atrPct > cap {
            rejected = "\(m.symbol) moves \(f(atrPct, 1))% on an average day, against the \(f(cap, 1))% ceiling this profile sets. A position sized to survive that range would be too small to affect the account."
        } else if let maxS = rules.maxSessions, horizonDays > maxS {
            rejected = "This plan needs roughly \(f(horizonDays, 0)) sessions to reach its target, and \(article(rules.horizonLabel)) horizon does not hold trades that long."
        } else if let minS = rules.minSessions, horizonDays < minS {
            rejected = "This plan resolves in about \(f(horizonDays, 0)) sessions, which is too fast for \(article(rules.horizonLabel)) horizon. It would pay the spread and the short-term tax rate for a move this account does not need."
        }

        return TradePlan(
            symbol: m.symbol,
            side: rejected != nil ? .avoid : .long,
            entry: entry,
            entryKind: entryKind,
            tightStop: tightened,
            target: target,
            stop: stop,
            targetPct: ((target - entry) / entry) * 100,
            stopPct: ((stop - entry) / entry) * 100,
            rr: rr,
            riskBudget: riskBudget,
            riskTaken: riskTaken,
            sizedBy: sizedBy,
            shares: shares,
            cost: cost,
            horizonDays: horizonDays,
            breakevenWinRate: rr > 0 ? (1 / (1 + rr)) * 100 : 100,
            rejected: rejected
        )
    }

    /* ------------------------------------------------------------ market regime */

    struct MarketRegime: Codable {
        enum Label: String, Codable { case bull, bear, chop }
        let label: Label
        let headline: String
        /// The two halves of the headline, so the topbar can drop the state and keep
        /// the name when there is not room for both. The dot already carries the state.
        let what: String
        let state: String
        let detail: String
        let breadthPct: Double?
    }

    /**
     * A market-wide read, computed the same way for equities and crypto: where the
     * benchmark sits against its own 200-day, plus how much of the sector is above
     * its 50-day. Breadth is the part beginners never look at and the part that
     * turns first.
     */
    static func marketRegime(_ benchmark: Metrics?, _ members: [Metrics], _ kind: String) -> MarketRegime {
        let above50 = members.filter { $0.sma50 != nil && $0.price > $0.sma50! }.count
        let breadthPct: Double? = members.isEmpty ? nil : (Double(above50) / Double(members.count)) * 100
        let b = benchmark
        var aboveLong: Bool?
        if let s200 = b?.sma200, let price = b?.price { aboveLong = price > s200 }
        let mom = b?.ret3mo ?? 0

        var label: MarketRegime.Label = .chop
        if aboveLong == true && mom > 2 && (breadthPct ?? 50) > 55 { label = .bull }
        else if aboveLong == false && mom < -2 && (breadthPct ?? 50) < 45 { label = .bear }

        // Named per market rather than per asset class. Two equity reads both
        // headed "Equities" is a pill you cannot tell apart from the one beside it,
        // and measuring a Stockholm pick against the S&P measures the krona as much
        // as it measures the stock.
        let what: String
        let bench: String
        switch kind {
        case "crypto":  what = "Crypto";    bench = "Bitcoin"
        case "sweden":  what = "Stockholm"; bench = "the OMXS30"
        default:        what = "US equities"; bench = "the S&P 500"
        }
        let state = label == .bull ? "risk-on"
            : label == .bear ? "risk-off"
            : "no clear trend"
        let headline = "\(what): \(state)"

        let breadthText = breadthPct != nil ? f(breadthPct!, 0) : "—"
        let detail: String
        switch label {
        case .bull:
            detail = "\(bench) is above its 200-day average with \(breadthText)% of names above their 50-day. Trend-following works here, and pullbacks are bought more often than not."
        case .bear:
            detail = "\(bench) is below its 200-day average and only \(breadthText)% of names hold their 50-day. Rallies fail more often than they extend, so sizes are smaller here."
        case .chop:
            detail = "\(bench) is near its 200-day with \(breadthText)% breadth. Direction is unresolved, which is the condition trend systems perform worst in."
        }

        return MarketRegime(label: label, headline: headline, what: what, state: state, detail: detail, breadthPct: breadthPct)
    }
}

/// "an intraday horizon", "a swing horizon" — the label is interpolated into the
/// refusal, so the article has to be chosen rather than hardcoded.
func article(_ label: String) -> String {
    let lower = label.lowercased()
    return "aeiou".contains(lower.first ?? "x") ? "an \(lower)" : "a \(lower)"
}

/**
 * A price, at a sensible number of decimals for its magnitude.
 *
 * `f(x, 2)` turns a $0.0899 stop into "0.09", which is not a level anyone could
 * act on. The interface already scales decimals to price; the sentences the engine
 * writes have to do the same or they quote a number that does not exist.
 */
func priceText(_ n: Double) -> String {
    guard n.isFinite else { return "n/a" }
    let a = abs(n)
    let dp = a >= 1000 ? 0 : a >= 10 ? 2 : a >= 1 ? 3 : 4
    return f(n, dp)
}

/// `toFixed` — the same rounding the TypeScript engine's prose used, so the
/// sentences a user reads are byte-identical to the ones it produced.
func f(_ n: Double, _ dp: Int) -> String {
    guard n.isFinite else { return "n/a" }
    return String(format: "%.\(dp)f", n)
}
