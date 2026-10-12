/**
 * Analyst.swift — the analyst layer.
 *
 * Three calls, each fed the previous one's output, because the three jobs are
 * genuinely different and asking for them at once produces a worse version of
 * all three:
 *
 *   1. SCREEN — read each candidate's numbers and headlines on its own terms.
 *   2. RANK   — put the survivors side by side and decide what actually gets
 *               money, accounting for the fact that six AI names are one bet.
 *   3. BRIEF  — teach the top picks: what the setup is, why it exists, how to
 *               run it, and what would prove it wrong.
 *
 * The numbers in every recommendation come from Analysis.swift, not from here.
 * Claude reads, weighs and explains; it is never asked to invent a price level,
 * because a language model guessing a stop loss is exactly the failure mode this
 * whole app exists to teach people to avoid.
 *
 * There is no Anthropic SDK for Swift, so this speaks the Messages API over
 * URLSession directly: streamed SSE, adaptive thinking, structured outputs via
 * `output_config.format`, and a cached system prefix shared by all three passes.
 *
 * Without ANTHROPIC_API_KEY this module reports itself unavailable and the app
 * serves the quantitative read alone.
 */

import Foundation

/* ------------------------------------------------------------ the contract */

struct ScreenRead: Codable {
    let symbol: String
    /// One-sentence read a beginner can act on.
    let thesis: String
    let stance: String            // constructive | neutral | cautious
    let catalysts: [String]
    let risks: [String]
    /// What the headlines add that the chart does not show.
    let newsRead: String
    /// -20..+20, an adjustment to the quantitative conviction score.
    let convictionDelta: Double
}

struct ScreenBatch: Codable { let reads: [ScreenRead] }

struct RankedPick: Codable {
    let symbol: String
    let rank: Double
    /// Share of the risk budget, 0-100 across all picks.
    let allocationPct: Double
    let why: String
}

struct PassedPick: Codable {
    let symbol: String
    let why: String
}

struct RankOutput: Codable {
    let picks: [RankedPick]
    /// How the picks interact — the part single-stock analysis always misses.
    let portfolioNote: String
    /// What the whole basket is implicitly betting on.
    let concentrationWarning: String
    let passed: [PassedPick]
}

struct JargonTerm: Codable {
    let term: String
    let plain: String
}

struct BriefOut: Codable {
    let symbol: String
    let headline: String
    /// The three teaching blocks the app promises on every recommendation.
    let what: String
    let why: String
    let how: String
    /// The observation that would end the trade early, in plain language.
    let invalidation: String
    /// A term used above, defined for someone who has not traded before.
    let jargon: [JargonTerm]
}

struct BriefBatch: Codable { let briefs: [BriefOut] }

struct Candidate {
    let metrics: Analysis.Metrics
    let plan: Analysis.TradePlan
    var news: [Headline]
    /// The quantitative score after this desk's learned biases, when it differs from
    /// the raw one. Carried separately so the model can see both and the raw score is
    /// never quietly overwritten.
    var learnedConviction: Double?
}

struct AnalystResult {
    let reads: [ScreenRead]
    let ranking: RankOutput?
    let briefs: [BriefOut]
    let ms: Double
    let passes: [String]
}

struct AnalystStatus: Codable {
    let available: Bool
    let model: String
    let reason: String
}

enum AnalystStage: String, Codable {
    case screening, ranking, briefing, reviewing, reporting, learning, done
}

/* ------------------------------------------------------- the review contract */

/// One closed trade, judged on what was knowable at the time rather than on how
/// it turned out. Outcome and decision quality are different things, and a review
/// that conflates them teaches you to chase whatever worked last.
struct TradeNote: Codable {
    let tradeId: String
    let symbol: String
    /// The trade in under twelve words.
    let headline: String
    let whatHappened: String
    /// The mechanism behind the move — or an explicit statement that the record
    /// does not support one.
    let whyItMoved: String
    /// Was the decision right given what could be known at the time?
    let executionCall: String
    let doDifferently: String
    /// The rule that generalises to instruments not mentioned here.
    let transferable: String
    let grade: String   // good | acceptable | avoidable
}

struct ReviewBatch: Codable { let notes: [TradeNote] }

struct PeriodReport: Codable {
    let headline: String
    /// Performance stated against the benchmark and net of costs and contributions.
    let performance: String
    let whatIsWorking: String
    let whatIsNot: String
    /// What the record says about the person keeping it.
    let behaviouralRead: String
    let costDrag: String
    /// Whether the trading matches the profile it claims to be run under.
    let suitabilityRead: String
    let nextPeriod: [String]
    let oneNumberToWatch: String
}

enum Analyst {

    /// The model that does the thinking. Chosen in Settings, overridable by
    /// PAPER_MODEL, defaulting to the most capable option.
    static var model: String { AnalystModel.current }

    /**
     * The key lives in the Keychain, or in the ANTHROPIC_API_KEY environment variable.
     * Nothing here ever writes a key. It is read fresh each time rather than cached
     * at launch, so saving or removing one takes effect on the next run.
     *
     * A bundled app is launched by Finder, not by a shell, so it inherits none of the
     * terminal's exports: the Keychain entry is the path that works for most people.
     */
    static func resolveKey() -> String? { Credentials.resolve()?.key }

    static func available() -> Bool { resolveKey() != nil }

    static func status() -> AnalystStatus {
        let ok = available()
        return AnalystStatus(
            available: ok,
            model: model,
            reason: ok
                ? "Claude analyst online."
                : "No API key is saved in Paper and none is set in ANTHROPIC_API_KEY. Paper is running on its quantitative engine alone, so every number, level and size below is still live. Add a key and reopen Paper to switch the written analysis on."
        )
    }

    /* ------------------------------------------------------------- the prompts */

    /**
     * Stable across every call so the cache prefix holds. Volatile market data goes
     * in the user turn, never in here.
     */
    private static let system = """
    You are the analyst inside Paper, a market simulator that teaches people how markets work using fake money. No trade you describe is ever executed with real funds and no user of this app is buying anything.

    Your job is education through concrete worked examples, not investment advice. Write for someone intelligent who has never traded. Explain the mechanism, not just the conclusion.

    How to write. This is interface copy, so it is neutral, informational and concise:
    - State what is true and what follows from it, then stop. No closing flourish, no line that exists to land a point, no sentence that would work as the last line of an essay.
    - Two or three sentences per section. One idea per sentence, under about 25 words each.
    - At most one em dash per paragraph, and only to attach a figure or an example. Never to swing into a rhetorical turn.
    - Do not refer to the app in the third person ("the app", "this simulator", "the desk will"). State what happens.
    - No commentary on the reader's psychology, no reassurance, no "most people", "almost everyone", "the whole point", "genuinely", "actually", "honestly".
    - Numbers instead of adjectives.

    Hard rules:
    - The numeric levels (entry, target, stop, position size) are computed by the app's risk engine from the instrument's own volatility. You never invent, override or restate a different level. You explain why the level sits where it does.
    - Be specific. "Momentum is strong" carries no information; "price has held its 50-day average on three separate pullbacks since October, and each one drew buyers within two sessions" does.
    - Name the bear case every time, including for your best idea.
    - Say "I don't know" where the data does not support a read, rather than inventing confidence.
    - No hype, no price predictions dressed as certainty, no "guaranteed", no emoji.
    - A reader should finish understanding why the trade is structured this way, so the reasoning transfers to instruments you never mentioned.

    You also review closed trades. When you do:
    - Judge the decision on what was knowable at the time, never on how it turned out. A good decision that lost money is still a good decision, and a reckless one that paid is still reckless. Say which you are looking at.
    - The excursion figures you are given are measured from real price history. Use them. Do not estimate, round differently, or recall what an instrument did. If a number is not in front of you, say the record does not cover it.
    - Headlines carry publication dates. Only attribute a move to news whose date sits near the move. Otherwise say that the available coverage does not explain it rather than inventing a cause.
    - Every recommendation must fit the profile you are given. The same setup is suitable for one person and not another, and the difference is their circumstances.
    """

    static func fmt(_ n: Double?, _ dp: Int = 2) -> String {
        guard let n, n.isFinite else { return "n/a" }
        return String(format: "%.\(dp)f", n)
    }

    /**
     * The metric pack.
     *
     * Sent for every candidate on the screen pass and again for every funded pick on
     * the brief, so its length is multiplied by a dozen and then by six passes. It is
     * written dense on purpose: the labels are for a reader who already knows what a
     * 20-day average is, and every word of scaffolding here is paid for twelve times.
     *
     * The figures are unchanged from the verbose version — this is compression, not
     * omission. Dropping a number to save tokens would mean the model reasoning
     * about a chart it cannot fully see, which is a worse trade than any saving.
     */
    private static func describe(_ c: Candidate) -> String {
        var text = describe(c.metrics, c.plan, c.news)
        if let learned = c.learnedConviction, abs(learned - c.metrics.conviction) >= 0.5 {
            text += "\nafter this desk's learned bias: conviction \(fmt(learned, 0))/100 (raw \(fmt(c.metrics.conviction, 0))) — from this account's own record, not the chart."
        }
        return text
    }

    private static func describe(_ m: Analysis.Metrics, _ plan: Analysis.TradePlan, _ news: [Headline]) -> String {
        let inst = Universe.bySymbol[m.symbol]
        let ccy = Universe.currency(of: m.symbol).code
        let venue = Universe.venue(of: m.symbol)
        var lines = [
            "## \(m.symbol) \(inst?.name ?? "") · \(inst?.sector ?? "n/a") · \(inst?.klass.rawValue ?? "equity") · \(venue.exchangeName) · quoted in \(ccy)",
            "px \(fmt(m.price)) \(ccy) | \(m.regime.rawValue) | conviction \(fmt(m.conviction, 0))/100 for a \(m.style) horizon (trend \(fmt(m.scores.trend, 0)), mom \(fmt(m.scores.momentum, 0)), entry \(fmt(m.scores.entry, 0)), risk \(fmt(m.scores.risk, 0)), range \(fmt(m.scores.range, 0)), durability \(fmt(m.scores.durability, 0)))",
            "MA20/50/200 \(fmt(m.sma20))/\(fmt(m.sma50))/\(fmt(m.sma200)) | RSI \(fmt(m.rsi14, 1)) | ATR \(fmt(m.atr14)) (\(fmt(m.atrPct, 1))%) | vol30 \(fmt(m.vol30, 1))%",
            "ret 5d/1m/3m/6m/1y \(fmt(m.ret5d, 1))/\(fmt(m.ret1mo, 1))/\(fmt(m.ret3mo, 1))/\(fmt(m.ret6mo, 1))/\(fmt(m.ret1y, 1))%",
            "52w \(fmt(m.fromHigh52, 1))% from high, \(fmt(m.fromLow52, 1))% off low | worst 1y DD \(fmt(m.drawdown1y, 1))% | support \(fmt(m.support)) resistance \(fmt(m.resistance)) | vol trend \(fmt(m.volumeTrend, 0))%",
            "plan \(plan.entryKind.rawValue) @\(fmt(plan.entry)) \(ccy) → target \(fmt(plan.target)) (\(fmt(plan.targetPct, 1))%) / stop \(fmt(plan.stop)) (\(fmt(plan.stopPct, 1))%), all \(ccy) | \(fmt(plan.rr)):1 | breakeven \(fmt(plan.breakevenWinRate, 0))%",
        ]
        if let rejected = plan.rejected { lines.append("REJECTED: \(rejected)") }
        if news.isEmpty {
            lines.append("news: none")
        } else {
            // Three, not five. The fourth and fifth headline on a mega-cap are almost
            // always restatements of the first three, and they are billed all the same.
            lines.append("news:")
            for h in news.prefix(3) {
                let title = h.title.count > 110 ? String(h.title.prefix(107)) + "…" : h.title
                lines.append("  - \(title) (\(h.publisher))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /* -------------------------------------------------------- the wire format */

    /// JSON Schemas for `output_config.format`. Hand-written because Swift has no
    /// Zod; the shapes match the Codable structs above exactly.
    private enum Schema {
        static let str: [String: Any] = ["type": "string"]
        static let num: [String: Any] = ["type": "number"]
        static func strArray() -> [String: Any] { ["type": "array", "items": str] }

        static func object(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required, "additionalProperties": false]
        }

        static let screenRead = object([
            "symbol": str,
            "thesis": str,
            "stance": ["type": "string", "enum": ["constructive", "neutral", "cautious"]],
            "catalysts": strArray(),
            "risks": strArray(),
            "newsRead": str,
            "convictionDelta": num,
        ], ["symbol", "thesis", "stance", "catalysts", "risks", "newsRead", "convictionDelta"])

        static let screenBatch = object(
            ["reads": ["type": "array", "items": screenRead]], ["reads"]
        )

        static let rankResult = object([
            "picks": ["type": "array", "items": object([
                "symbol": str, "rank": num, "allocationPct": num, "why": str,
            ], ["symbol", "rank", "allocationPct", "why"])],
            "portfolioNote": str,
            "concentrationWarning": str,
            "passed": ["type": "array", "items": object(["symbol": str, "why": str], ["symbol", "why"])],
        ], ["picks", "portfolioNote", "concentrationWarning", "passed"])

        static let brief = object([
            "symbol": str, "headline": str, "what": str, "why": str, "how": str,
            "invalidation": str,
            "jargon": ["type": "array", "items": object(["term": str, "plain": str], ["term", "plain"])],
        ], ["symbol", "headline", "what", "why", "how", "invalidation", "jargon"])

        static let briefBatch = object(
            ["briefs": ["type": "array", "items": brief]], ["briefs"]
        )

        static let tradeNote = object([
            "tradeId": str, "symbol": str, "headline": str,
            "whatHappened": str, "whyItMoved": str, "executionCall": str,
            "doDifferently": str, "transferable": str,
            "grade": ["type": "string", "enum": ["good", "acceptable", "avoidable"]],
        ], ["tradeId", "symbol", "headline", "whatHappened", "whyItMoved",
            "executionCall", "doDifferently", "transferable", "grade"])

        static let reviewBatch = object(
            ["notes": ["type": "array", "items": tradeNote]], ["notes"]
        )

        static let periodReport = object([
            "headline": str, "performance": str, "whatIsWorking": str, "whatIsNot": str,
            "behaviouralRead": str, "costDrag": str, "suitabilityRead": str,
            "nextPeriod": strArray(), "oneNumberToWatch": str,
        ], ["headline", "performance", "whatIsWorking", "whatIsNot", "behaviouralRead",
            "costDrag", "suitabilityRead", "nextPeriod", "oneNumberToWatch"])
    }

    /**
     * What each pass is allowed to cost, in one table rather than scattered across
     * six call sites.
     *
     * Effort is the first lever that trades quality for spend, so it is set per pass
     * on what the pass actually is. Screening is a mechanical read of a metric pack
     * against five headlines and does not repay deep thinking; ranking a basket and
     * writing the teaching brief do, and are left at full effort. `maxTokens` is
     * sized to the largest honest answer each pass could give — lowballing it does
     * not save money, it truncates the JSON mid-object and bills for the whole thing
     * anyway, which is the single most expensive failure in this pipeline.
     */
    struct PassConfig {
        let effort: String
        let maxTokens: Int
        /// Raised on a retry after a truncation, because the ceiling was the fault.
        let retryMaxTokens: Int

        static let table: [String: PassConfig] = [
            "screen":  PassConfig(effort: "low",    maxTokens: 6_000,  retryMaxTokens: 12_000),
            "rank":    PassConfig(effort: "high",   maxTokens: 10_000, retryMaxTokens: 20_000),
            "brief":   PassConfig(effort: "high",   maxTokens: 20_000, retryMaxTokens: 32_000),
            "review":  PassConfig(effort: "medium", maxTokens: 10_000, retryMaxTokens: 20_000),
            "report":  PassConfig(effort: "high",   maxTokens: 12_000, retryMaxTokens: 24_000),
            "learn":   PassConfig(effort: "high",   maxTokens: 10_000, retryMaxTokens: 20_000),
            "explain": PassConfig(effort: "high",   maxTokens: 8_000,  retryMaxTokens: 16_000),
        ]

        static func of(_ pass: String) -> PassConfig {
            table[pass] ?? PassConfig(effort: "high", maxTokens: 10_000, retryMaxTokens: 20_000)
        }
    }

    /// What a pass ended up doing. Distinguishing "completed and returned nothing"
    /// from "failed" matters: the first is billed and the second usually is not, and
    /// only one of them is worth retrying.
    enum PassOutcome<T> {
        case ok(T)
        case empty(String)
        case failed(String)
        case stopped(StopCause, String)

        var value: T? { if case .ok(let v) = self { return v }; return nil }
        var halted: Bool { if case .stopped = self { return true }; return false }
    }

    /// Rough token count for a prompt, to check against the budget before spending
    /// it. Deliberately an over-estimate — approving a call that then blows past the
    /// ceiling is worse than skipping one that would have fitted.
    static func estimateTokens(_ text: String) -> Int { text.count / 3 }

    private static let apiSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // Fifteen minutes. These are long thinking requests over a dozen instruments,
        // and anything shorter was being hit even with streaming.
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg)
    }()

    /**
     * One structured request, streamed, metered and governed.
     *
     * Every call in this app goes through here, which is what makes the accounting
     * complete: there is no second path to the API that could spend money without
     * being recorded.
     *
     * Three things happen around the request that did not before:
     *
     *   - The governor is **asked first**, with a real estimate of what this call
     *     will cost, and can refuse it. Checking after the fact is not a budget.
     *   - Usage is read out of the stream — `message_start` carries the input and
     *     cache figures, `message_delta` the output count — so the numbers are the
     *     ones actually billed rather than a local guess at them.
     *   - Every outcome is recorded, including the quiet one: a call that returns
     *     200 and nothing usable. That is the failure that costs money and looks
     *     like progress, and it is counted separately for exactly that reason.
     *
     * Streaming is not optional. A non-streaming request over a dozen metric packs
     * with adaptive thinking runs past the HTTP timeout and dies with a bare
     * connection error after three minutes.
     */
    static func run<T: Decodable>(
        _ type: T.Type,
        schema: [String: Any],
        user: String,
        pass: String,
        governor: Governor?,
        maxTokensOverride: Int? = nil
    ) async -> PassOutcome<T> {
        guard let key = resolveKey() else { return .failed("No API key.") }

        let config = PassConfig.of(pass)
        let maxTokens = maxTokensOverride ?? config.maxTokens
        let estimate = estimateTokens(system) + estimateTokens(user) + maxTokens

        // A mechanical pass may be sent to a cheaper model than the one doing the
        // judgement. Resolved per call rather than per run, so the telemetry can price
        // a mixed run correctly.
        let passModel = AnalystModel.forPass(pass)
        let spec = ModelCatalogue.describe(passModel)

        /* The ticket is the budget reservation this call is holding, and it has to
         * be handed back on every route out of this function — success, failure,
         * empty and truncation alike — or the governor keeps counting a call that
         * finished against the remaining budget and the run strangles itself. */
        var ticket: String?
        if let governor {
            switch await governor.permit(pass: pass, estimatedTokens: estimate) {
            case .go(let granted): ticket = granted
            case .stop(let cause, let note): return .stopped(cause, note)
            }
        }

        /* The request shape follows the model rather than assuming one.
         *
         * The current Opus and Sonnet models take adaptive thinking and an effort
         * level. Haiku 4.5 rejects `effort` outright and wants an explicit thinking
         * budget instead, which must sit below `max_tokens`. Shipping a model picker
         * where one option returns a 400 would be worse than shipping no picker. */
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
        if spec.supportsEffort { outputConfig["effort"] = config.effort }

        let thinking: [String: Any] = spec.adaptiveThinking
            ? ["type": "adaptive"]
            : ["type": "enabled",
               "budget_tokens": Swift.max(1024, Swift.min(maxTokens / 2, 4000))]

        let body: [String: Any] = [
            "model": passModel,
            "max_tokens": maxTokens,
            "stream": true,
            "thinking": thinking,
            "output_config": outputConfig,
            // Byte-identical on every call and marked cacheable. Measured behaviour:
            // repeated calls *within* a pass read it back, while separate passes each
            // write their own entry — the cached prefix is matched from the start of
            // the request and every pass carries a different output schema. So the
            // saving that exists is the one the screen pass takes by warming this with
            // a single call before fanning out, and the run's cache read count coming
            // back at zero while writes are happening is a fault Diagnostics reports.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startedAt = nowMs()
        var record = CallRecord(
            pass: pass, model: passModel,
            // Second time round after a truncation retry, first otherwise. The
            // field was hardcoded to 1 and read by nothing, which made the token
            // report unable to show that a pass had cost twice what it looked like.
            attempt: maxTokensOverride == nil ? 1 : 2,
            startedAt: startedAt, ms: 0,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            stopReason: nil, httpStatus: nil, error: nil, ok: false
        )

        func fail(_ message: String, status: Int? = nil) async -> PassOutcome<T> {
            record.ms = nowMs() - startedAt
            record.error = message
            record.httpStatus = status
            record.ok = false
            await governor?.record(record, ticket: ticket)
            return .failed(message)
        }

        func empty(_ reason: String) async -> PassOutcome<T> {
            record.ms = nowMs() - startedAt
            record.ok = false
            record.error = reason
            await governor?.recordEmpty(record, reason: reason, ticket: ticket)
            return .empty(reason)
        }

        do {
            let (bytes, response) = try await apiSession.bytes(for: req)
            let http = response as? HTTPURLResponse
            record.httpStatus = http?.statusCode

            if let http, !(200...299).contains(http.statusCode) {
                var detail = ""
                for try await line in bytes.lines where detail.count < 400 { detail += line }
                return await fail("Anthropic API returned \(http.statusCode): \(detail.prefix(300))",
                                  status: http.statusCode)
            }

            var text = ""
            var streamError: String?

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                switch event["type"] as? String {
                case "message_start":
                    // Input, cache-read and cache-write counts all arrive here.
                    if let message = event["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        record.inputTokens = usage["input_tokens"] as? Int ?? 0
                        record.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                        record.cacheWriteTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                    }
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let chunk = delta["text"] as? String {
                        text += chunk
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any] {
                        record.stopReason = delta["stop_reason"] as? String ?? record.stopReason
                    }
                    if let usage = event["usage"] as? [String: Any] {
                        record.outputTokens = usage["output_tokens"] as? Int ?? record.outputTokens
                    }
                case "error":
                    streamError = ((event["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                default:
                    break
                }
            }

            record.ms = nowMs() - startedAt

            if let streamError { return await fail(streamError, status: record.httpStatus) }

            if record.stopReason == "refusal" {
                log("[analyst] \(pass): request declined")
                return await empty("The model declined this request.")
            }

            // Truncation is the expensive failure: billed in full, and the JSON it was
            // building is unusable. One retry with the ceiling raised, then give up —
            // the governor's attempt cap stops this becoming a loop.
            if record.stopReason == "max_tokens" {
                await governor?.recordEmpty(record, reason: "The response hit its max_tokens ceiling and was cut off.", ticket: ticket)
                ticket = nil
                if maxTokensOverride == nil {
                    log("[analyst] \(pass): truncated at \(maxTokens) tokens, retrying once with \(config.retryMaxTokens)")
                    return await run(type, schema: schema, user: user, pass: pass,
                                     governor: governor, maxTokensOverride: config.retryMaxTokens)
                }
                return .empty("The response was cut off at the token ceiling even after it was raised.")
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                return await empty("The response contained no text.")
            }

            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                record.ok = true
                await governor?.record(record, ticket: ticket)
                return .ok(decoded)
            } catch {
                return await empty("could not validate the response: \(error.localizedDescription)")
            }
        } catch {
            return await fail(error.localizedDescription, status: record.httpStatus)
        }
    }

    /// The old shape, kept for the paths that have no governor to answer to (the
    /// single-instrument explainer). Everything metered goes through `run`.
    static func parse<T: Decodable>(
        _ type: T.Type,
        schema: [String: Any],
        user: String,
        maxTokens: Int = 16000,
        effort: String = "high"
    ) async throws -> T? {
        await run(type, schema: schema, user: user, pass: "explain", governor: nil).value
    }

    /**
     * What kind of trade this run is for, said once and handed to every pass.
     *
     * Without it the model writes the same swing-trade prose over a shortlist that
     * was built for a day trade, and the mismatch is invisible: the numbers are
     * right and the reasoning is about the wrong timescale. Naming the mandate also
     * tells it which objections are relevant — "this needs six months to work" is a
     * fatal criticism of a two-day trade and a description of a five-year one.
     */
    static func mandate(_ style: TimeHorizon) -> String {
        let band = style.sessionBand
        var lines = [
            "The mandate for this run: \(style.label).",
            "Every idea below was scored for that horizon and is expected to resolve in roughly \(Int(band.min))–\(Int(band.max)) sessions. \(style.emphasis)",
            "Judge each one as that kind of trade. A setup that needs a quarter to work is a failure for a two-day trade and unremarkable for a multi-year one, and the same chart is a different idea depending on which you are running.",
        ]
        if style.outrunsTheData {
            // Said out loud rather than allowed to be implied. The engine reads daily
            // bars; a genuine day trade does not resolve inside one.
            lines.append("One honest limit: this engine reads daily bars, which cannot resolve a trade that opens and closes inside a single session. What this horizon buys here is the tightest stops and the fastest setups daily data supports. Do not describe intraday entries, opening-range breaks or anything that would need minute bars to act on.")
        }
        return lines.joined(separator: " ")
    }

    /* ---------------------------------------------------------------- the chain */

    /**
     * Pass 1 — read each candidate on its own terms.
     *
     * Split into small batches run concurrently. One call covering a dozen
     * instruments spends minutes of wall-clock and gives each name less attention
     * than the last; four at a time is both faster and a better read. They share the
     * cached system prefix, so splitting costs nothing there.
     */
    private static func screen(_ cands: [Candidate], _ regimes: [Analysis.MarketRegime], _ profile: Profile,
                               _ memory: String, _ governor: Governor?,
                               _ style: TimeHorizon) async -> [ScreenRead] {
        let regimeText = mandate(style) + "\n\n" + regimes.map { "\($0.headline) — \($0.detail)" }.joined(separator: "\n")
        let who = profile.brief
        let BATCH = 4
        var batches: [[Candidate]] = []
        var i = 0
        while i < cands.count {
            batches.append(Array(cands[i..<Swift.min(i + BATCH, cands.count)]))
            i += BATCH
        }

        var out: [ScreenRead] = []

        /* The first batch runs alone.
         *
         * The system prefix is marked cacheable so the six passes in a run bill it
         * once. Launching every screen batch at the same instant defeats that
         * completely: none of them has written the cache yet when the others start,
         * so each pays the write price — measured at three writes and zero reads on a
         * three-batch run. Warming it with one call first turns the rest into cache
         * reads at a tenth of the input rate, and the saving compounds across every
         * later pass in the run. */
        if let first = batches.first {
            out.append(contentsOf: await readBatch(first, regimeText, who, memory, governor))
        }
        let rest = Array(batches.dropFirst())

        await withTaskGroup(of: [ScreenRead].self) { group in
            for batch in rest {
                group.addTask {
                    await readBatch(batch, regimeText, who, memory, governor)
                }
            }
            for await part in group { out.append(contentsOf: part) }
        }
        return out
    }

    /// One screen batch. Extracted so the cache-warming first call and the
    /// concurrent remainder cannot drift apart.
    private static func readBatch(_ batch: [Candidate], _ regimeText: String, _ who: String,
                                  _ memory: String, _ governor: Governor?) async -> [ScreenRead] {
        let body = batch.map { describe($0) }.joined(separator: "\n\n")
        let user = """
        You are screening for this account:
        \(who)

        \(memory)

        Market backdrop:
        \(regimeText)

        Read each of the following candidates. For each, give the one-sentence thesis, your stance, the concrete catalysts and risks, what the headlines add beyond the chart, and a conviction adjustment between -20 and +20 against the quantitative score.

        Adjust downward when the news contradicts the chart, when the move is already crowded, or when the setup depends on something unknowable. Adjust upward only when there is a specific reason the numbers are understating the case. Adjust downward too when a setup is sound in the abstract but wrong for this account's horizon, objective or capacity to absorb a loss — say so explicitly in the thesis when that is the reason.

        \(body)
        """

        // A mechanical read of a metric pack and three headlines. The depth that
        // matters is in the ranking and the brief, which both run at full effort;
        // spending it here buys nothing and is paid on every batch.
        switch await run(ScreenBatch.self, schema: Schema.screenBatch,
                         user: user, pass: "screen", governor: governor) {
        case .ok(let result):
            return result.reads
        case .empty(let why), .failed(let why):
            // One failed batch must not cost the whole run.
            log("[analyst] screen batch: \(why)")
            return []
        case .stopped:
            return []
        }
    }

    /// Pass 2 — the survivors, side by side.
    private static func rank(_ style: TimeHorizon,
                             _ cands: [Candidate], _ reads: [ScreenRead], _ regimes: [Analysis.MarketRegime],
                             _ slots: Int, _ profile: Profile, _ memory: String,
                             _ governor: Governor?) async -> PassOutcome<RankOutput> {
        let byId = Dictionary(reads.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = cands.map { c -> String in
            let r = byId[c.metrics.symbol]
            let inst = Universe.bySymbol[c.metrics.symbol]
            let delta = r.map { fmt($0.convictionDelta, 0) } ?? "n/a"
            return "\(c.metrics.symbol) (\(inst?.sector ?? "n/a"), \(inst?.klass.rawValue ?? "equity")) — quant \(fmt(c.metrics.conviction, 0)), your delta \(delta), R:R \(fmt(c.plan.rr)):1, regime \(c.metrics.regime.rawValue), 30d vol \(fmt(c.metrics.vol30, 0))%\n   thesis: \(r?.thesis ?? "—")\n   risks: \(r?.risks.joined(separator: "; ").nonEmpty ?? "—")"
        }.joined(separator: "\n")

        let user = """
        You are allocating for this account:
        \(profile.brief)

        \(mandate(style))

        \(memory)

        Market backdrop:
        \(regimes.map { "\($0.headline) — \($0.detail)" }.joined(separator: "\n"))

        Here are your own reads from the screen, side by side:

        \(rows)

        Pick at most \(slots) to fund and rank them. Allocate the risk budget across them as percentages summing to 100.

        Read them as a basket rather than a list. Several of these are the same bet across different tickers: the AI complex moves together, and crypto moves as one trade at different amounts of leverage. Say so in the concentration warning if it applies. In portfolioNote, state what this basket is exposed to and what single event would hurt all of it at once.

        Hold the basket inside this account's limits: at most \(profile.maxOpenPositions) positions open at once and \(f(profile.maxPortfolioHeatPct, 1))% of equity at risk across all of them together. Correlated names each risking the full per-trade budget are one position wearing several tickers, and the heat limit is what catches that. If funding every idea you like would breach it, fund fewer and say which you dropped for that reason rather than for a view on the instrument.

        For every candidate you did not fund, give the one reason you passed.
        """
        return await run(RankOutput.self, schema: Schema.rankResult, user: user,
                         pass: "rank", governor: governor)
    }

    /// Pass 3 — teach the picks.
    private static func brief(_ style: TimeHorizon,
                              _ cands: [Candidate], _ ranking: RankOutput, _ reads: [ScreenRead],
                              _ profile: Profile, _ memory: String,
                              _ governor: Governor?) async -> PassOutcome<BriefBatch> {
        let byId = Dictionary(cands.map { ($0.metrics.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        let readById = Dictionary(reads.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        let blocks = ranking.picks.compactMap { p -> String? in
            guard let c = byId[p.symbol] else { return nil }
            return """
            \(describe(c))
            Your screen thesis: \(readById[p.symbol]?.thesis ?? "—")
            Your ranking rationale: \(p.why)
            Allocation: \(fmt(p.allocationPct, 0))% of the risk budget.
            """
        }.joined(separator: "\n\n")

        let user = """
        Write the teaching brief for each funded pick. A user of the simulator reads this before committing fake money, and the point is that the reasoning transfers to instruments you never mentioned.

        The account you are writing for:
        \(profile.brief)

        \(mandate(style))

        \(memory)

        For each:
        - Where a level differs from the textbook distance because this desk has learned something from this account's own record, say so in `how`, name the lesson, and explain what it is compensating for. A calibration the user cannot see the effect of is a calibration they will not trust.

        - headline: the setup in under twelve words.
        - what: what is actually happening in the price and the business. Name the specific observable facts.
        - why: why this opportunity exists: who is on the other side of it, and what they believe. Explain the mechanism.
        - how: how the trade is run, walking through the engine's entry, target and stop, and why each level sits where it does relative to the instrument's own volatility and the levels on the chart. State what the position size means in risk taken rather than money spent, and what losing that amount means for this account.
        - invalidation: the observation that ends the trade early, in plain language.
        - jargon: two to four terms you used, defined for someone who has never traded.

        \(blocks)
        """
        return await run(BriefBatch.self, schema: Schema.briefBatch, user: user,
                         pass: "brief", governor: governor)
    }

    /**
     * The whole chain, under a budget.
     *
     * Each stage is allowed to fail without taking the run with it — the passes are
     * chained, so an earlier one remains valid without the later ones, and partial
     * results beat none. What is *not* allowed is continuing after the governor has
     * called a halt: at that point the run is either out of budget, out of time, or
     * repeating itself, and every further call is money spent on a known outcome.
     */
    static func analyse(
        _ cands: [Candidate],
        _ regimes: [Analysis.MarketRegime],
        _ profile: Profile,
        slots: Int = 5,
        memory: String = "",
        governor: Governor? = nil,
        style: TimeHorizon = .swing,
        onStage: @escaping (AnalystStage) -> Void = { _ in }
    ) async -> AnalystResult {
        let t0 = nowMs()
        var passes: [String] = []
        guard available() else {
            return AnalystResult(reads: [], ranking: nil, briefs: [], ms: 0, passes: ["unavailable"])
        }

        onStage(.screening)
        let reads = await screen(cands, regimes, profile, memory, governor, style)
        passes.append("screen:\(reads.count)")
        // `stopped` is actor-isolated, so it is read into a local before being used in
        // a condition — an await cannot sit inside a short-circuiting operator.
        var halted = await governor?.stopped != nil
        if reads.isEmpty || halted {
            return AnalystResult(reads: reads, ranking: nil, briefs: [], ms: nowMs() - t0, passes: passes)
        }

        onStage(.ranking)
        var ranking: RankOutput?
        switch await rank(style, cands, reads, regimes, slots, profile, memory, governor) {
        case .ok(let r):
            ranking = r
            passes.append("rank:\(r.picks.count)")
        case .empty(let why), .failed(let why):
            log("[analyst] rank pass: \(why)")
            passes.append("rank:failed")
        case .stopped(let cause, _):
            passes.append("rank:stopped(\(cause.rawValue))")
        }

        halted = await governor?.stopped != nil
        guard let ranking, !ranking.picks.isEmpty, !halted else {
            return AnalystResult(reads: reads, ranking: ranking, briefs: [], ms: nowMs() - t0, passes: passes)
        }

        onStage(.briefing)
        var briefs: [BriefOut] = []
        switch await brief(style, cands, ranking, reads, profile, memory, governor) {
        case .ok(let batch):
            briefs = batch.briefs
            passes.append("brief:\(briefs.count)")
        case .empty(let why), .failed(let why):
            // The picks and the ranking still stand; only the written brief is missing.
            log("[analyst] brief pass: \(why)")
            passes.append("brief:failed")
        case .stopped(let cause, _):
            passes.append("brief:stopped(\(cause.rawValue))")
        }

        return AnalystResult(reads: reads, ranking: ranking, briefs: briefs, ms: nowMs() - t0, passes: passes)
    }

    /// A single-symbol explainer for the "explain this" button on any instrument.
    static func explainOne(_ c: Candidate, _ regimes: [Analysis.MarketRegime], _ profile: Profile) async -> BriefOut? {
        guard available() else { return nil }
        let user = """
        The account you are writing for:
        \(profile.brief)

        Market backdrop:
        \(regimes.map { "\($0.headline) — \($0.detail)" }.joined(separator: "\n"))

        \(describe(c))

        Write the teaching brief for this one instrument, whether or not the engine likes the setup. If the engine rejected it, the brief explains why the setup is not worth taking and what would have to change — that lesson matters more than a pitch. Cover what is happening, why the opportunity or trap exists and who is on the other side, how the levels are derived from this instrument's own volatility, and what would invalidate the read. Define two to four terms in plain language.
        """
        return try? await parse(BriefOut.self, schema: Schema.brief, user: user)
    }
}

extension String {
    /// `""` reads as absent, matching the `|| '—'` fallbacks the prompts used.
    var nonEmpty: String? { isEmpty ? nil : self }
}

/* ============================================================ the review side */

/// The result of a review run: a note per closed trade, plus the report over all
/// of them. Either half can be missing without losing the other.
struct ReviewResult {
    let notes: [TradeNote]
    let report: PeriodReport?
    let ms: Double
    let passes: [String]
}

extension Analyst {

    /// A dated headline list. Dates matter more than usual here: the model is only
    /// allowed to blame a move on news whose date sits near it.
    private static func newsBlock(_ news: [Headline], around: Double) -> String {
        guard !news.isEmpty else { return "  Recent coverage: none retrieved." }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "  Recent coverage (dated — only cite an item whose date is near the move):\n"
            + news.prefix(5).map { h in
                let when = h.published > 0
                    ? formatter.string(from: Date(timeIntervalSince1970: h.published / 1000))
                    : "undated"
                let gap = h.published > 0 ? abs(h.published - around) / 86_400_000 : 999
                let note = gap <= 4 ? " [within \(Int(gap.rounded())) days of the exit]" : " [\(Int(gap.rounded())) days from the exit]"
                return "    - \"\(h.title)\" (\(h.publisher), \(when))\(note)"
            }.joined(separator: "\n")
    }

    /**
     * Pass 4 — the post-mortem on each closed trade.
     *
     * Every number the note can cite is computed and handed over in the evidence
     * line. The model's job is to explain the mechanism and grade the decision, not
     * to remember prices, which it cannot do and which would poison the review with
     * confident invention if it tried.
     */
    static func reviewTrades(_ reviews: [TradeReview], _ profile: Profile,
                             news: [String: [Headline]], memory: String = "",
                             governor: Governor? = nil) async -> [TradeNote] {
        guard available(), !reviews.isEmpty else { return [] }

        let BATCH = 3
        var batches: [[TradeReview]] = []
        var i = 0
        while i < reviews.count {
            batches.append(Array(reviews[i..<Swift.min(i + BATCH, reviews.count)]))
            i += BATCH
        }

        var out: [TradeNote] = []
        await withTaskGroup(of: [TradeNote].self) { group in
            for batch in batches {
                group.addTask {
                    let blocks = batch.map { r -> String in
                        """
                        ### trade \(r.tradeId) — \(r.symbol) (\(r.name))
                        Your thesis at entry: \(r.thesis.isEmpty ? "none recorded" : r.thesis)
                        Measured record: \(r.evidence)
                        Net result: \(money(r.pnl))\(r.rMultiple.map { ", \(f($0, 2))R" } ?? ""). Held \(f(r.holdingDays, 1)) days.\(r.dayTrade ? " Opened and closed the same session." : "")
                        \(newsBlock(news[r.symbol] ?? [], around: r.closedAt))
                        """
                    }.joined(separator: "\n\n")

                    let user = """
                    Review these closed trades for this account:
                    \(profile.brief)

                    \(memory)

                    For each trade, write the post-mortem. Use the trade's `tradeId` verbatim so it can be matched back.

                    - whatHappened: the shape of the trade in plain language, using only the measured figures given.
                    - whyItMoved: the mechanism. If a dated headline sits near the move, use it and say so. If the coverage provided does not explain it, say exactly that; "the available coverage does not cover this move" is a correct answer and inventing a cause is not.
                    - executionCall: was the decision right *given what could be known at the time*? Separate this from the outcome explicitly. A stop that was hit and then recovered may still have been correctly placed, or may have been sitting inside the noise — the excursion figures tell you which, so say which.
                    - doDifferently: one concrete change, or "nothing; this was well run" when that is the accurate answer. Do not manufacture a criticism.
                    - transferable: the rule that generalises to instruments not named here.
                    - grade: good | acceptable | avoidable, grading the decision rather than the profit.

                    \(blocks)
                    """
                    switch await run(ReviewBatch.self, schema: Schema.reviewBatch,
                                     user: user, pass: "review", governor: governor) {
                    case .ok(let result): return result.notes
                    case .empty(let why), .failed(let why):
                        log("[analyst] review batch: \(why)")
                        return []
                    case .stopped: return []
                    }
                }
            }
            for await part in group { out.append(contentsOf: part) }
        }
        return out
    }

    /**
     * Pass 5 — the report over the whole record.
     *
     * This is the one that is allowed to be uncomfortable. Its subject is not the
     * market, it is the person: what they actually do, as opposed to what their
     * profile says they intend to do.
     */
    static func periodReport(_ behaviour: BehaviourReport, _ scorecard: Scorecard,
                             _ tax: TaxSummary, _ reviews: [TradeReview],
                             _ profile: Profile, _ regimes: [Analysis.MarketRegime],
                             memory: String = "", governor: Governor? = nil) async -> PeriodReport? {
        guard available() else { return nil }

        let verdictCounts = Dictionary(grouping: reviews, by: { $0.verdict.rawValue })
            .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")

        let measured = """
        Closed trades: \(scorecard.closedTrades) (\(scorecard.wins) up, \(scorecard.losses) down). Win rate \(scorecard.winRate.map { f($0, 0) + "%" } ?? "n/a"). Expectancy \(scorecard.expectancyR.map { f($0, 2) + "R" } ?? "n/a"). Profit factor \(scorecard.profitFactor.map { f($0, 2) } ?? "no losses yet").
        Exits: \(scorecard.targetsHit) at target, \(scorecard.stoppedOut) at stop, \(scorecard.manualExits) by hand. \(scorecard.gappedExits) filled through the level on a gap. \(scorecard.dayTrades) were same-session round trips. \(scorecard.backfilledExits) were reconstructed from daily bars covering sessions the desk was closed for, so their timing is inferred rather than observed.
        Costs to date: \(money(scorecard.totalCommission)) commission, \(money(scorecard.totalSlippage)) crossing the spread, \(money(scorecard.totalTax)) tax. Net P/L on closed trades \(money(scorecard.closedTrades > 0 ? (scorecard.pnlBeforeCosts ?? 0) - scorecard.totalCommission - scorecard.totalSlippage - scorecard.totalTax : 0)); before costs it would have been \(scorecard.pnlBeforeCosts.map { money($0) } ?? "n/a").
        Account return \(behaviour.accountReturnPct.map { f($0, 2) + "%" } ?? "n/a") against the S&P 500 at \(behaviour.benchmarkReturnPct.map { f($0, 2) + "%" } ?? "n/a") over the same window.
        Holding: winners \(behaviour.avgHoldWinnersDays.map { f($0, 1) + " days" } ?? "n/a"), losers \(behaviour.avgHoldLosersDays.map { f($0, 1) + " days" } ?? "n/a").
        Excursions: average heat taken \(behaviour.avgMaeR.map { f($0, 2) + "R" } ?? "n/a"), average best available \(behaviour.avgMfeR.map { f($0, 2) + "R" } ?? "n/a"), capture rate \(behaviour.captureRatePct.map { f($0, 0) + "%" } ?? "n/a").
        Outcomes by category: \(verdictCounts.isEmpty ? "none yet" : verdictCounts).
        Money still on the table from positions sold early: \(money(behaviour.totalLeftOnTable)).
        Positions closed with no stop at all: \(behaviour.positionsWithoutStop).
        Tax position this year: \(money(tax.shortTermGain)) short-term gain, \(money(tax.longTermGain)) long-term, \(money(tax.totalTax)) owed\(tax.effectiveRatePct.map { " — an effective \(f($0, 0))% of gross realised profit" } ?? "").
        Patterns the engine already flagged: \(behaviour.patterns.isEmpty ? "none — too few trades" : behaviour.patterns.joined(separator: " | "))
        """

        let user = """
        Write the periodic review for this account.

        The account:
        \(profile.brief)

        \(memory)

        Market backdrop over the period:
        \(regimes.map { "\($0.headline) — \($0.detail)" }.joined(separator: "\n"))

        The measured record:
        \(measured)

        Write it as the person's own analyst would — direct, specific, and willing to say the uncomfortable thing. Cover:

        - headline: the state of this account in under fifteen words.
        - performance: what the return actually means. Compare against the benchmark, and separate money made by trading from money merely paid in. Beating a bull market by doing nothing is not skill, and losing to one while trading constantly is the finding that matters.
        - whatIsWorking: name the specific thing, with the number that shows it. If nothing is working yet, say that instead of finding a consolation.
        - whatIsNot: the same, honestly. The most valuable sentence in this whole report is usually here.
        - behaviouralRead: what the record says about this person as a trader, as distinct from their picks. Hold time asymmetry, capture rate, stop discipline, and whether the losses come from the analysis or the execution.
        - costDrag: what frequency is costing. Use the before-and-after-costs figures and the tax position. If the drag is small because the account trades rarely, say that plainly rather than manufacturing a warning.
        - suitabilityRead: does the actual trading match the profile it claims to run under? Someone whose profile says long-term and whose record is full of same-session round trips has a problem no pick will fix. This is the section where you say so.
        - nextPeriod: two to four concrete, checkable adjustments. Not "be more disciplined" — an actual rule, with the number in it.
        - oneNumberToWatch: the single metric that would tell this person soonest whether the change is working.

        If the record is too thin to support a claim, say so in that section rather than filling it. A short honest report is worth more than a long invented one.
        """

        return await run(PeriodReport.self, schema: Schema.periodReport, user: user,
                         pass: "report", governor: governor).value
    }

    /// The whole review side, run as one job.
    static func runReview(_ reviews: [TradeReview], _ behaviour: BehaviourReport,
                          _ scorecard: Scorecard, _ tax: TaxSummary, _ profile: Profile,
                          _ regimes: [Analysis.MarketRegime], news: [String: [Headline]],
                          memory: String = "", governor: Governor? = nil,
                          onStage: @escaping (AnalystStage) -> Void = { _ in }) async -> ReviewResult {
        let t0 = nowMs()
        var passes: [String] = []
        guard available() else {
            return ReviewResult(notes: [], report: nil, ms: 0, passes: ["unavailable"])
        }

        onStage(.reviewing)
        // The most recent dozen closes. Reviewing a hundred trades individually
        // would cost a fortune and say the same thing twelve times.
        let subject = Array(reviews.prefix(12))
        let notes = await reviewTrades(subject, profile, news: news, memory: memory, governor: governor)
        passes.append("review:\(notes.count)")

        onStage(.reporting)
        let halted = await governor?.stopped != nil
        let report = halted ? nil
            : await periodReport(behaviour, scorecard, tax, reviews, profile, regimes,
                                 memory: memory, governor: governor)
        passes.append(report != nil ? "report:ok" : "report:failed")

        return ReviewResult(notes: notes, report: report, ms: nowMs() - t0, passes: passes)
    }
}
