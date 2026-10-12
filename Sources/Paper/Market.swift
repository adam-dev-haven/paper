/**
 * Market.swift — the only place that talks to the outside world for prices.
 *
 * Two sources, both keyless:
 *   Yahoo Finance  — quotes, daily bars, headlines, for equities and crypto alike.
 *   CoinGecko      — crypto aggregate stats (total cap, BTC dominance) that Yahoo
 *                    does not expose and that the crypto regime read depends on.
 *
 * Everything is cached in memory with a per-endpoint TTL. Quotes go stale in a
 * minute, daily bars in fifteen, headlines in twenty. This is a simulator: a
 * price a minute old changes nothing about the lesson, and hammering a free
 * endpoint until it blocks us would.
 */

import Foundation

struct Bar: Codable {
    let t: Double
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double
}

struct Quote: Codable {
    let symbol: String
    let price: Double
    let prevClose: Double
    let change: Double
    let changePct: Double
    let dayHigh: Double?
    let dayLow: Double?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let marketCap: Double?
    let currency: String
    let exchange: String
    let asOf: Double
}

struct Headline: Codable {
    let title: String
    let publisher: String
    let url: String
    let published: Double
}

struct CryptoGlobal: Codable {
    let totalMarketCapUsd: Double
    let totalVolumeUsd: Double
    let btcDominance: Double
    let ethDominance: Double
    let marketCapChangePct24h: Double
}

/**
 * A share split, as the feed reports it.
 *
 * Load-bearing for the reconciliation pass. Yahoo restates historical bars for a
 * split retroactively — NVDA's pre-split $1,209 close is served as $120.99 — but
 * a ledger holding that position still has the unadjusted entry, stop and target
 * written down. Replaying restated bars against an unrestated bracket would fire
 * every stop in the book at a price that never existed.
 */
struct Split: Codable {
    let at: Double
    /// Shares after, per share before. A 10:1 split is 10.
    let ratio: Double
    let label: String
}

struct ChartData {
    let bars: [Bar]
    let quote: Quote
    var splits: [Split] = []
}

/// Milliseconds since the epoch — the unit the whole app and its front end speak.
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// `log` lives in Log.swift. It kept the same one-argument shape it has always
// had, so nothing in this file changed; it now writes to a dated file under the
// data directory as well as to standard error, which is what a bundled app
// launched from Finder actually needs.

struct MarketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Raw JSON fetching, deliberately outside the cache actor: a request in flight
/// must not hold the actor, or every symbol fetch would queue behind the one before it.
enum Net {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    static func json(_ urlString: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw MarketError("bad url \(urlString)") }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarketError("\(http.statusCode) for \(urlString)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Percent-encoding that leaves nothing to chance — Yahoo symbols carry `-`
    /// and `^`, and a comma-joined batch must stay one query value.
    static func esc(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

actor Market {
    static let shared = Market()

    private struct CacheEntry {
        let at: Double
        let value: Any
    }

    private var cache: [String: CacheEntry] = [:]

    private func cached<T>(_ key: String, _ ttlMs: Double, _ load: () async throws -> T) async throws -> T {
        let hit = cache[key]
        if let hit, nowMs() - hit.at < ttlMs, let value = hit.value as? T { return value }
        do {
            let value = try await load()
            cache[key] = CacheEntry(at: nowMs(), value: value)
            return value
        } catch {
            // A stale answer beats a broken page. Serve the old value if we have one,
            // however old it is, and only fail when the cache is genuinely empty. Say so
            // out loud — silently serving a stale price is worse than an error.
            if let hit, let value = hit.value as? T {
                log("[market] \(key) failed, serving a value \(Int((nowMs() - hit.at) / 1000))s old: \(error.localizedDescription)", .warn, "market")
                return value
            }
            throw error
        }
    }

    /// Drop a cache entry so the next read goes to the network.
    func bust(_ prefix: String) {
        for k in cache.keys where k.hasPrefix(prefix) { cache.removeValue(forKey: k) }
    }

    /* ------------------------------------------------------------------ bars */

    /**
     * Daily bars plus the quote metadata Yahoo bundles with them. One request buys
     * both, which is why nothing here calls the separate quote endpoint — that one
     * demands a crumb/cookie handshake and breaks without warning.
     */
    func chart(_ symbol: String, range: String = "1y", interval: String = "1d",
               ttlMs: Double? = nil) async throws -> ChartData {
        // Daily bars barely move inside a session and are held for a quarter of an
        // hour. Intraday bars are the opposite — a five-minute bar is stale the moment
        // the next one prints — so the caller sets the leash.
        let ttl = ttlMs ?? (interval.hasSuffix("m") || interval.hasSuffix("h") ? 45_000 : 15 * 60_000)
        return try await cached("chart:\(symbol):\(range):\(interval)", ttl) {
            // `events=split` is not decoration: the reconciliation pass cannot tell a
            // 10:1 split from a 90% crash without it, and guesses the wrong one.
            let json = try await Net.json("https://query1.finance.yahoo.com/v8/finance/chart/\(Net.esc(symbol))?range=\(Net.esc(range))&interval=\(Net.esc(interval))&events=split")
            guard let result = ((json as? [String: Any])?["chart"] as? [String: Any])?["result"] as? [[String: Any]],
                  let first = result.first
            else { throw MarketError("no chart data for \(symbol)") }

            let meta = first["meta"] as? [String: Any] ?? [:]
            let ts = first["timestamp"] as? [Double] ?? []
            let q = ((first["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first ?? [:]
            let closes = q["close"] as? [Any] ?? []
            let opens = q["open"] as? [Any] ?? []
            let highs = q["high"] as? [Any] ?? []
            let lows = q["low"] as? [Any] ?? []
            let vols = q["volume"] as? [Any] ?? []

            var bars: [Bar] = []
            bars.reserveCapacity(ts.count)
            for i in 0..<ts.count {
                // Yahoo pads holidays and half-sessions with nulls.
                guard i < closes.count, let c = closes[i] as? Double else { continue }
                bars.append(Bar(
                    t: ts[i] * 1000,
                    o: (i < opens.count ? opens[i] as? Double : nil) ?? c,
                    h: (i < highs.count ? highs[i] as? Double : nil) ?? c,
                    l: (i < lows.count ? lows[i] as? Double : nil) ?? c,
                    c: c,
                    v: (i < vols.count ? vols[i] as? Double : nil) ?? 0
                ))
            }
            if bars.isEmpty { throw MarketError("no usable bars for \(symbol)") }

            let price = meta["regularMarketPrice"] as? Double ?? bars[bars.count - 1].c
            // The previous close is the second-to-last *bar*, never meta.chartPreviousClose:
            // that field is the close before the requested window opened, so on a 1y range
            // it turns the day change into the year change.
            let prevClose = bars.count >= 2 ? bars[bars.count - 2].c : (meta["previousClose"] as? Double ?? bars[bars.count - 1].c)
            let quote = Quote(
                symbol: symbol,
                price: price,
                prevClose: prevClose,
                change: price - prevClose,
                changePct: prevClose != 0 ? ((price - prevClose) / prevClose) * 100 : 0,
                dayHigh: meta["regularMarketDayHigh"] as? Double,
                dayLow: meta["regularMarketDayLow"] as? Double,
                fiftyTwoWeekHigh: meta["fiftyTwoWeekHigh"] as? Double,
                fiftyTwoWeekLow: meta["fiftyTwoWeekLow"] as? Double,
                marketCap: meta["marketCap"] as? Double,
                currency: meta["currency"] as? String ?? "USD",
                exchange: (meta["fullExchangeName"] as? String) ?? (meta["exchangeName"] as? String) ?? "",
                asOf: (meta["regularMarketTime"] as? Double).map { $0 * 1000 } ?? nowMs()
            )
            var splits: [Split] = []
            if let events = first["events"] as? [String: Any],
               let raw = events["splits"] as? [String: Any] {
                for (_, value) in raw {
                    guard let entry = value as? [String: Any],
                          let at = entry["date"] as? Double,
                          let num = entry["numerator"] as? Double,
                          let den = entry["denominator"] as? Double,
                          den > 0, num > 0
                    else { continue }
                    splits.append(Split(
                        at: at * 1000,
                        ratio: num / den,
                        label: (entry["splitRatio"] as? String) ?? "\(Int(num)):\(Int(den))"
                    ))
                }
                splits.sort { $0.at < $1.at }
            }
            return ChartData(bars: bars, quote: quote, splits: splits)
        }
    }

    /**
     * Live prices for the whole board in a single request.
     *
     * This is the endpoint that makes the desk feel live. Pulling a year of bars per
     * symbol is expensive and those bars barely move intraday, but the *price* has
     * to be current — so bars are cached for a quarter of an hour while this runs on
     * a fifteen-second leash. One request covers every symbol, which is the only
     * reason a short TTL is affordable against a free endpoint.
     *
     * The payload carries the day's high and low as well, so bracket sweeps test
     * against the real session range rather than only the prices we happened to
     * sample.
     */
    func livePrices(_ symbols: [String], ttlMs: Double = 15_000) async throws -> [String: Quote] {
        try await cached("spark:\(symbols.joined(separator: ","))", ttlMs) {
            // Yahoo rejects the request outright somewhere above twenty symbols — a flat
            // 400, no partial result — so the universe goes out in chunks. Fifteen keeps
            // a comfortable margin and keeps the whole board inside a handful of requests.
            let CHUNK = 15
            var chunks: [[String]] = []
            var i = 0
            while i < symbols.count {
                chunks.append(Array(symbols[i..<Swift.min(i + CHUNK, symbols.count)]))
                i += CHUNK
            }

            var results: [[String: Any]] = []
            await withTaskGroup(of: [[String: Any]].self) { group in
                for chunk in chunks {
                    group.addTask {
                        // The trailing cache-buster is load-bearing. Yahoo's CDN caches this URL and
                        // ignores Cache-Control: no-cache, so a repeated request quietly returns a
                        // payload whose timestamps drift further behind on every call — measured at
                        // 3s, then 16s, then 29s stale across three identical requests, while the
                        // same request with a unique parameter stayed at 2-3s throughout. Without
                        // this the desk silently shows minutes-old prices and calls them live.
                        let url = "https://query1.finance.yahoo.com/v7/finance/spark?symbols=\(Net.esc(chunk.joined(separator: ",")))&range=1d&interval=5m&_=\(Int(nowMs()))"
                        do {
                            let json = try await Net.json(url)
                            return ((json as? [String: Any])?["spark"] as? [String: Any])?["result"] as? [[String: Any]] ?? []
                        } catch {
                            log("[market] live price chunk failed (\(chunk.count) symbols): \(error.localizedDescription)", .warn, "market")
                            return []
                        }
                    }
                }
                for await part in group { results.append(contentsOf: part) }
            }

            var out: [String: Quote] = [:]
            for r in results {
                guard let response = r["response"] as? [[String: Any]],
                      let meta = response.first?["meta"] as? [String: Any],
                      let price = meta["regularMarketPrice"] as? Double,
                      let symbol = (r["symbol"] as? String) ?? (meta["symbol"] as? String)
                else { continue }

                // On a 1-day range chartPreviousClose really is the prior session's close,
                // unlike the long-range request where it predates the window entirely.
                let prevClose = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? price
                out[symbol] = Quote(
                    symbol: symbol,
                    price: price,
                    prevClose: prevClose,
                    change: price - prevClose,
                    changePct: prevClose != 0 ? ((price - prevClose) / prevClose) * 100 : 0,
                    dayHigh: meta["regularMarketDayHigh"] as? Double,
                    dayLow: meta["regularMarketDayLow"] as? Double,
                    fiftyTwoWeekHigh: meta["fiftyTwoWeekHigh"] as? Double,
                    fiftyTwoWeekLow: meta["fiftyTwoWeekLow"] as? Double,
                    marketCap: nil,
                    currency: meta["currency"] as? String ?? "USD",
                    exchange: (meta["fullExchangeName"] as? String) ?? (meta["exchangeName"] as? String) ?? "",
                    asOf: (meta["regularMarketTime"] as? Double).map { $0 * 1000 } ?? nowMs()
                )
            }
            if out.isEmpty { throw MarketError("no live prices returned") }
            return out
        }
    }

    /* -------------------------------------------------------------- headlines */

    func headlines(_ symbol: String, count: Int = 6) async throws -> [Headline] {
        try await cached("news:\(symbol):\(count)", 20 * 60_000) {
            let q = symbol.replacingOccurrences(of: "-USD", with: "")
            let json = try await Net.json("https://query1.finance.yahoo.com/v1/finance/search?q=\(Net.esc(q))&newsCount=\(count)&quotesCount=0")
            let news = (json as? [String: Any])?["news"] as? [[String: Any]] ?? []
            return news.prefix(count).compactMap { n -> Headline? in
                let title = (n["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return Headline(
                    title: title,
                    publisher: n["publisher"] as? String ?? "unknown",
                    url: n["link"] as? String ?? "",
                    published: (n["providerPublishTime"] as? Double ?? 0) * 1000
                )
            }
        }
    }

    /* ------------------------------------------------------- crypto aggregate */

    /// Aggregate stats are a nice-to-have; the regime read degrades without them,
    /// so a failure here is swallowed rather than cached as a negative result.
    func cryptoGlobal() async -> CryptoGlobal? {
        try? await cached("cg:global", 10 * 60_000) {
            let json = try await Net.json("https://api.coingecko.com/api/v3/global")
            guard let d = (json as? [String: Any])?["data"] as? [String: Any] else {
                throw MarketError("no crypto aggregate payload")
            }
            let caps = d["market_cap_percentage"] as? [String: Any] ?? [:]
            return CryptoGlobal(
                totalMarketCapUsd: (d["total_market_cap"] as? [String: Any])?["usd"] as? Double ?? 0,
                totalVolumeUsd: (d["total_volume"] as? [String: Any])?["usd"] as? Double ?? 0,
                btcDominance: caps["btc"] as? Double ?? 0,
                ethDominance: caps["eth"] as? Double ?? 0,
                marketCapChangePct24h: d["market_cap_change_percentage_24h_usd"] as? Double ?? 0
            )
        }
    }
}
